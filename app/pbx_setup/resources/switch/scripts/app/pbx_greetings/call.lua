-- Dispatched only from the private greeting worker. No inbound feature number accepts this action.
require 'resources.functions.config'
local Database=require 'resources.functions.database'
local json=require 'resources.functions.lunajson'
local db=Database.new('system');local api=freeswitch.API()
local P=loadfile(scripts_dir..'/app/pbx_setup/policy.lua')()
local registered=loadfile(scripts_dir..'/app/pbx_setup/registered.lua')()
local realms=loadfile(scripts_dir..'/app/xml_handler/resources/scripts/directory/contact_realms.lua')()
local recorder=loadfile(scripts_dir..'/app/pbx_greetings/recording.lua')()
local id=argv and argv[1] or ''
local function uuid(v)return type(v)=='string' and #v==36 and v:match('^[a-f0-9%-]+$')end
if not uuid(id) then db:release();return end
local greeting,config,call,partial,finished
local function q(sql,args,callback)return db:query(sql,args,callback)end
local function fail(message)
    if greeting then q([[update v_pbx_greetings set state='failed',last_result=:message,lease_until=null,updated_at=now()
      where greeting_uuid=:id and domain_uuid=:domain and call_uuid=:call and state='calling']],
      {message=message,id=id,domain=greeting.domain_uuid,call=greeting.call_uuid}) end
end
local function run()
    q([[select g.*,r.config from v_pbx_greetings g join v_pbx_restore r using(domain_uuid) join v_domains d using(domain_uuid)
      join v_users u on u.user_uuid=g.created_by where g.greeting_uuid=:id and g.state='calling' and g.source='phone'
      and g.lease_until>now() and d.domain_enabled='true' and u.user_enabled='true'
      and not exists(select 1 from v_pbx_services s join v_pbx_tenants t using(tenant_uuid) where s.domain_uuid=g.domain_uuid and not t.enabled)]],
      {id=id},function(row)greeting=row;config=json.decode(row.config)end)
    if not greeting or not uuid(greeting.domain_uuid) or not uuid(greeting.call_uuid) then return end
    if not P.realm_config(config,realms.realms(db,greeting.domain_uuid,config.realm)) then fail('The PBX address needs review.');return end
    local target=greeting.target_number;local owner=config.users[greeting.caller_extension]
    if not owner or not owner.enabled then fail('The calling extension is unavailable.');return end
    local contact
    local user=config.users[target]
    if user then
        if not user.enabled then fail('The recording extension is disabled.');return end
        contact=registered(db,api,P,greeting.domain_uuid,user,config.realm)
        if contact then contact='[domain_uuid='..greeting.domain_uuid..',domain_name='..config.realm..',rtp_secure_media=optional:AES_CM_128_HMAC_SHA1_80,origination_caller_id_name=Greetings,origination_caller_id_number='..owner.number..']'..contact end
    elseif type(target)=='string' and target:match('^%+?%d+$') and #target>=7 and #target<=19 then
        local rule=P.outbound(config,target,greeting.caller_extension)
        if rule then
            for _,route in ipairs(rule.routes or {}) do
                local trunk=config.trunks[tostring(route.trunk_id)];local native
                if trunk and uuid(trunk.gateway_uuid) then
                    q([[select enabled,register,from_domain,from_user,username,proxy,outbound_proxy,register_transport,profile from v_gateways where domain_uuid=:domain and gateway_uuid=:id]],
                      {domain=greeting.domain_uuid,id=trunk.gateway_uuid},function(row)native=row end)
                    if native and P.gateway_available(native,api:execute('sofia','status gateway '..trunk.gateway_uuid)) then
                        contact=P.outbound_leg(trunk,route,target,owner,greeting.caller_extension,greeting.domain_uuid,config.realm,native,config)
                        if contact then break end
                    end
                end
            end
        end
    end
    if not contact or contact:sub(1,1)~='[' then fail('The recording phone is offline or its outside-call route is unavailable.');return end
    contact=contact:gsub('^%[','[origination_uuid='..greeting.call_uuid..',leg_timeout=45,ignore_early_media=true,',1)
    call=freeswitch.Session(contact)
    if not call:ready() then fail('The recording phone did not answer.');return end
    if call:getVariable('uuid')~=greeting.call_uuid then fail('The recording call identity changed.');return end
    local active=false
    q("select 1 from v_pbx_greetings where greeting_uuid=:id and domain_uuid=:domain and call_uuid=:call and state='calling'",{id=id,domain=greeting.domain_uuid,call=greeting.call_uuid},function()active=true end)
    if not active then return end
    call:setVariable('domain_uuid',greeting.domain_uuid);call:setVariable('domain_name',config.realm)
    call:setVariable('recording_follow_transfer','false');call:setVariable('openweb_greeting_recording',id)
    call:setVariable('record_sample_rate','16000')
    local legacy=storage_dir..'/openwebpbx/'..greeting.domain_uuid..'/greetings/'..id
    local root=legacy
    if package.config:sub(1,1)=='\\' then
        local state=(os.getenv('ProgramData') or 'C:/ProgramData'):gsub('\\','/')..'/OpenWebPBX'
        root=state..'/storage/greetings/'..greeting.domain_uuid..'/greetings/'..id
        local function instructions(directory)
            for _,name in ipairs({'instruction.wav','replay.wav','saved.wav'}) do
                local f=io.open(directory..'/'..name,'rb');if not f then return false end;f:close()
            end
            return true
        end
        -- Requests prepared before this default changed retain their original audio.
        if not instructions(root) and instructions(legacy) then root=legacy end
    end
    partial=root..'/recording.partial.wav';local final=root..'/audio.wav'
    local paths={instruction=root..'/instruction.wav',replay=root..'/replay.wav',saved=root..'/saved.wav',partial=partial}
    for _,path in ipairs({paths.instruction,paths.replay,paths.saved}) do local f=io.open(path,'rb');if not f then fail('The Keoma recording instructions are unavailable.');return end;f:close() end
    local saved,message=recorder.record(call,paths,function()
        local existing=io.open(final,'rb');if existing then existing:close();error('A saved greeting already exists.') end
        if not os.rename(partial,final) then error('The recording could not be committed.') end
        q('BEGIN')
        local ok,problem=pcall(function()
            local valid=false
            q([[select 1 from v_pbx_greetings where greeting_uuid=:id and domain_uuid=:domain and call_uuid=:call and state='calling' for update]],{id=id,domain=greeting.domain_uuid,call=greeting.call_uuid},function()valid=true end)
            if not valid then error('The recording request changed.') end
            q([[insert into v_pbx_media(media_uuid,domain_uuid,category,source_path,file_path,title,created_at)
              select greeting_uuid,domain_uuid,'prompts',:source,:path,name,now() from v_pbx_greetings where greeting_uuid=:id and domain_uuid=:domain]],
              {source='greetings/'..id,path=final,id=id,domain=greeting.domain_uuid})
            q([[insert into v_recordings(recording_uuid,domain_uuid,recording_filename,recording_name)
              select gen_random_uuid(),domain_uuid,:path,name from v_pbx_greetings where greeting_uuid=:id and domain_uuid=:domain]],
              {path=final,id=id,domain=greeting.domain_uuid})
            q([[update v_pbx_greetings set state='ready',media_uuid=greeting_uuid,lease_until=null,last_result='Recorded, replayed and saved',updated_at=now()
              where greeting_uuid=:id and domain_uuid=:domain and call_uuid=:call and state='calling']],{id=id,domain=greeting.domain_uuid,call=greeting.call_uuid})
        end)
        if not ok then q('ROLLBACK');os.rename(final,partial);error(problem) end
        q('COMMIT');finished=true
    end)
    if not saved then fail(message) end
end
local ok=pcall(run)
if not ok then fail('The greeting could not be saved. No existing greetings were changed. Choose Retry.') end
if call and call:ready() then call:hangup() end
if partial and not finished then os.remove(partial) end
db:release()
