-- OpenWeb PBX: restored V20 calling behavior. No customer settings belong in this file.
local args=...
if not session or not session:ready() then return end
local Database=require 'resources.functions.database'
local json=require 'resources.functions.lunajson'
local P=loadfile(scripts_dir..'/app/pbx_setup/policy.lua')()
local db=Database.new('system')
local api=freeswitch.API()
local domain=session:getVariable('domain_uuid') or ''
local config
db:query('select config from v_pbx_restore where domain_uuid=:domain',{domain=domain},function(row) config=json.decode(row.config) end)
if not config then db:release();session:hangup('UNALLOCATED_NUMBER');return end
local realm=config.realm
local mode,key=args[2],args[3]
local caller=session:getVariable('effective_caller_id_number') or session:getVariable('caller_id_number') or ''
local auth=session:getVariable('sip_auth_username') or session:getVariable('user_name')
local authenticated_user=false
for number,u in pairs(config.users) do if u.auth_id==auth then caller=number;authenticated_user=true;break end end
local internal=authenticated_user and mode~='incoming'
if mode=='record_user' then internal=session:getVariable('openweb_call_internal')=='true' end
local function clock(zone)
    local result=api:execute('strftime_tz',(zone or 'Africa/Johannesburg')..' %w_%H:%M_%Y-%m-%d')
    local day,time,date=result:match('^(%d)_(%d%d:%d%d)_(%d%d%d%d%-%d%d%-%d%d)')
    if not day then error('Office-hours clock unavailable') end
    return tonumber(day),time,date
end
local depth=tonumber(session:getVariable('openweb_route_depth') or '0')
session:setVariable('openweb_route_depth',tostring(depth+1))
if depth>=20 then db:release();session:hangup('EXCHANGE_ROUTING_ERROR');return end
session:setVariable('domain_name',realm)
session:setVariable('hangup_after_bridge','false')
session:setVariable('continue_on_fail','true')
local route,run_user,run_group,run_queue,run_ivr,run_outbound
local function hotel_room(number)
    local room
    db:query('select occupied,do_not_disturb from v_pbx_hotel_rooms where domain_uuid=:domain and number=:number',{domain=domain,number=tostring(number)},function(r) room=r end)
    return room
end
local function voicemail(number,check)
    local u=config.users[tostring(number)]
    if not u or not u.voicemail_enabled then session:hangup('NO_ANSWER');return end
    local room=hotel_room(number)
    if room and room.occupied~='t' and room.occupied~='true' then session:hangup('CALL_REJECTED');return end
    session:answer();session:setVariable('voicemail_id',tostring(number))
    session:setVariable('voicemail_action',check and 'check' or 'leave')
    session:execute('lua','app.lua voicemail')
end
local function record(u)
    if not u.record_calls or session:getVariable('openweb_recording')=='true' then return end
    if u.record_external_only and internal then return end
    local id=session:getVariable('uuid')
    if not id or not id:match('^[a-f0-9%-]+$') then return end
    local dir=storage_dir..'/openwebpbx/'..domain
    session:setVariable('openweb_recording','true');session:setVariable('record_path',dir)
    session:setVariable('record_name',id..'.wav');session:setVariable('record_stereo','true')
    local path=dir..'/'..id..'.wav'
    session:execute('record_session',path)
    db:query([[insert into v_pbx_media(media_uuid,domain_uuid,category,source_path,file_path,title,owner_number,created_at)
        values(:id,:domain,'recordings',:source,:path,:title,:owner,now()) on conflict do nothing]],
        {id=id,domain=domain,source='calls/'..id..'.wav',path=path,title='Call '..tostring(u.number),owner=tostring(u.number)})
end
local function outbound_contact(number,rule_route)
    local t=config.trunks[tostring(rule_route.trunk_id)]
    if not t then return nil end
    local enabled=false
    db:query('select enabled from v_gateways where gateway_uuid=:id and domain_uuid=:domain',{id=t.gateway_uuid,domain=domain},function(row) enabled=row.enabled=='true' or row.enabled=='t' end)
    if not enabled then return nil end
    return 'sofia/gateway/'..t.gateway_uuid..'/'..rule_route.prepend..number:sub(rule_route.strip+1)
end
local function user_contact(u,timeout)
    local variables='leg_timeout='..timeout..',domain_uuid='..domain..',domain_name='..realm..',openweb_call_internal='..tostring(internal)
    if u.record_calls and not (u.record_external_only and internal) then
        variables=variables..",execute_on_answer='lua app.lua pbx_setup record_user "..u.number.."'"
    end
    return '['..variables..']user/'..u.auth_id..'@'..realm
end
run_outbound=function(number)
    local room=hotel_room(caller)
    if room and room.occupied~='t' and room.occupied~='true' then session:hangup('CALL_REJECTED');return end
    if not number:match('^%+?[%d*#]+$') then session:hangup('UNALLOCATED_NUMBER');return end
    local rule=P.outbound(config,number,caller)
    if not rule then session:hangup('CALL_REJECTED');return end
    for _,r in ipairs(rule.routes) do
        local contact=outbound_contact(number,r)
        if contact then
            local trunk=config.trunks[tostring(r.trunk_id)]
            local cid=r.caller_id~='' and r.caller_id or (config.users[tostring(caller)] or {}).outbound_caller_id
            cid=cid~='' and cid or trunk.caller_id
            if cid and cid:match('^%+?%d+$') then session:setVariable('effective_caller_id_number',cid) end
            if config.users[tostring(caller)] then record(config.users[tostring(caller)]) end
            session:execute('bridge',contact)
            local cause=session:getVariable('originate_disposition')
            if not session:ready() or cause=='SUCCESS' then return end
        end
    end
    session:hangup('NORMAL_TEMPORARY_FAILURE')
end
route=function(destination,owner)
    if not session:ready() then return end
    destination=destination or {type='None'}
    local kind=destination.type
    local number=destination.number~='' and destination.number or owner
    if kind=='VoiceMail' then voicemail(number,false)
    elseif kind=='External' or kind=='Boomerang' then run_outbound(destination.external~='' and destination.external or (config.users[tostring(owner)] or {}).mobile or '')
    elseif kind=='None' or kind=='EndCall' then session:hangup('NORMAL_CLEARING')
    elseif number and tostring(number):match('^[%d*SPQCB]+$') then session:transfer(tostring(number),'XML',realm)
    else session:hangup('UNALLOCATED_NUMBER') end
end
run_user=function(number)
    local u=config.users[tostring(number)]
    if not u or not u.enabled then session:hangup('UNALLOCATED_NUMBER');return end
    local room=hotel_room(number)
    if room and (room.do_not_disturb=='t' or room.do_not_disturb=='true') then voicemail(number,false);return end
    local special=P.object_destination(config,u,clock)
    if special then route(special,number);return end
    local profile=P.profile(config,number,clock)
    local open=P.office(config,number,clock)
    if next(profile.away or {}) then route(P.forward(profile,'NoAnswer',internal,open),number);return end
    local contact=api:execute('sofia_contact',u.auth_id..'@'..realm)
    if contact:sub(1,4)=='-ERR' then route(P.forward(profile,'NotRegistered',internal,open),number);return end
    session:setVariable('call_timeout',tostring(profile.timeout));session:setVariable('origination_callee_id_name',u.name)
    session:setVariable('origination_callee_id_number',tostring(number));record(u)
    local bridge='[leg_timeout='..profile.timeout..']user/'..u.auth_id..'@'..realm
    if profile.ring_mobile and u.mobile~='' then
        local rule=P.outbound(config,u.mobile,caller)
        if rule and rule.routes[1] then local mobile=outbound_contact(u.mobile,rule.routes[1]);if mobile then bridge=bridge..',[leg_timeout='..profile.timeout..']'..mobile end end
    end
    session:execute('bridge',bridge)
    if not session:ready() then return end
    local cause=session:getVariable('originate_disposition') or ''
    if cause=='SUCCESS' then session:hangup('NORMAL_CLEARING');return end
    local reason=(cause=='USER_BUSY' or cause=='CALL_REJECTED') and 'Busy' or 'NoAnswer'
    route(P.forward(profile,reason,internal,open),number)
end
run_group=function(number)
    local group=P.find(config.ring_groups,number)
    if not group then session:hangup('UNALLOCATED_NUMBER');return end
    local special=P.object_destination(config,group,clock);if special then route(special,number);return end
    local contacts={}
    for _,m in ipairs(group.members) do
        local u=config.users[tostring(m.number)]
        if u and u.enabled then local profile=P.profile(config,m.number,clock)
            if not profile.disable_ring_groups then table.insert(contacts,user_contact(u,group.timeout)) end
        end
    end
    session:setVariable('ring_group_uuid',group.uuid)
    if #contacts>0 then session:execute('bridge',table.concat(contacts,',')) end
    if session:ready() and session:getVariable('originate_disposition')~='SUCCESS' then route(group.destination,number) end
end
run_queue=function(number)
    local q=P.find(config.queues,number)
    if not q then session:hangup('UNALLOCATED_NUMBER');return end
    local special=P.object_destination(config,q,clock);if special then route(special,number);return end
    api:execute('callcenter_config','queue load '..number..'@'..realm)
    for _,m in ipairs(q.members) do
        local u=config.users[tostring(m.number)]
        local profile=P.profile(config,m.number,clock)
        local reserved=false
        db:query("select 1 as ok from v_pbx_jobs where domain_uuid=:domain and agent_number=:number and state in ('starting','calling')",{domain=domain,number=tostring(m.number)},function() reserved=true end)
        local status=reserved and 'On Break' or (m.status=='LoggedIn' and u.queue_status=='LoggedIn' and u.enabled and profile.queue_status~='0' and 'Available' or 'Logged Out')
        api:execute('callcenter_config','agent set contact '..m.agent_uuid..' '..user_contact(u,q.ring_timeout))
        api:execute('callcenter_config','agent set status '..m.agent_uuid..' '..status)
    end
    session:answer();session:setVariable('call_center_queue_uuid',q.uuid)
    session:setVariable('queue_extension',tostring(number))
    if q.intro~='' then session:streamFile(q.intro) end
    local callback_mode=q.callback_mode or 'disabled'
    local callback_valid=caller:match('^%+?%d+$') and #caller<=32
    local started=os.time()
    local offered=false
    local function request_callback()
        if not callback_valid then return false end
        local stored=false
        db:query([[insert into v_pbx_jobs(job_uuid,domain_uuid,kind,queue_number,target_number,internal_target,request_key,max_attempts)
          select :id,:domain,'callback',:queue,:target,cast(:internal as boolean),:request,:attempts
          where (select count(*) from v_pbx_jobs where domain_uuid=:domain and kind='callback' and state in ('waiting','starting','calling'))<1000
          on conflict do nothing returning job_uuid]],
          {id=api:execute('create_uuid',''):gsub('%s+$',''),domain=domain,queue=tostring(number),target=caller,internal=tostring(internal),request='call/'..session:getVariable('uuid'),attempts=q.callback_attempts or 3},function() stored=true end)
        if not stored then db:query("select 1 as ok from v_pbx_jobs where domain_uuid=:domain and kind='callback' and queue_number=:queue and target_number=:target and state in ('waiting','starting','calling')",{domain=domain,queue=tostring(number),target=caller},function() stored=true end) end
        if stored then session:execute('phrase','openweb_callback_saved');session:hangup('NORMAL_CLEARING');return true end
        return false
    end
    if callback_mode~='disabled' and callback_valid then session:execute('phrase','openweb_callback_intro') end
    repeat
        session:setVariable('cc_exit_keys',callback_mode~='disabled' and callback_valid and '2' or '')
        session:setVariable('cc_exit_key','');session:setVariable('cc_agent_bridged','false')
        session:setVariable('cc_base_score',tostring(os.time()-started))
        session:execute('callcenter',number..'@'..realm)
        if not session:ready() or session:getVariable('cc_agent_bridged')=='true' then break end
        if callback_mode~='disabled' and callback_valid and session:getVariable('cc_exit_key')=='2' then if request_callback() then return end end
        if not offered and callback_valid and (callback_mode=='automatic' or callback_mode=='offer') and os.time()-started>=(q.callback_after or 600) then
            offered=true
            if callback_mode=='automatic' then if request_callback() then return end
            else
                local digit=session:playAndGetDigits(1,1,1,7000,'','phrase:openweb_callback_offer','silence_stream://100','[12]',2000)
                if digit=='2' and request_callback() then return end
            end
        end
        if callback_mode=='disabled' or callback_mode=='request' then break end
    until os.time()-started>=q.timeout
    session:setVariable('cc_exit_keys','')
    if session:ready() and session:getVariable('cc_agent_bridged')~='true' then route(q.destination,number) end
end
run_ivr=function(number)
    local ivr=P.find(config.receptionists,number)
    if not ivr then session:hangup('UNALLOCATED_NUMBER');return end
    local special=P.object_destination(config,ivr,clock);if special then route(special,number);return end
    session:answer();session:setVariable('ivr_menu_uuid',ivr.uuid)
    local digit=session:playAndGetDigits(1,1,1,ivr.timeout*1000,'',ivr.prompt~='' and ivr.prompt or 'silence_stream://100','silence_stream://100','[0-9*#]',2000)
    for _,o in ipairs(ivr.options) do if o.digit==digit then route(o.destination,number);return end end
    route(ivr.timeout_destination,number)
end
local function run()
    if authenticated_user and mode~='record_user' and mode~='incoming' then record(config.users[tostring(caller)]) end
    if mode=='user' then run_user(key)
    elseif mode=='group' then run_group(key)
    elseif mode=='queue' then run_queue(key)
    elseif mode=='ivr' then run_ivr(key)
    elseif mode=='outbound' then run_outbound(session:getVariable('destination_number') or '')
    elseif mode=='record_user' then local u=config.users[tostring(key)];if u then record(u) end
    elseif mode=='group_timeout' then route(P.find(config.ring_groups,key).destination,key)
    elseif mode=='queue_timeout' then route(P.find(config.queues,key).destination,key)
    elseif mode=='incoming' then
        local rule
        for _,r in ipairs(config.inbound_rules) do if r.rule_id==key then rule=r;break end end
        if not rule or not rule.enabled then session:hangup('CALL_REJECTED');return end
        local trunk=config.trunks[tostring(rule.trunk_id)]
        local ip=session:getVariable('sip_network_ip') or session:getVariable('network_addr') or ''
        local accepted=false
        for _,allowed in ipairs(trunk.allowed_ips or {}) do if allowed==ip then accepted=true end end
        local enabled=false
        db:query('select enabled from v_gateways where domain_uuid=:domain and gateway_uuid=:id',{domain=domain,id=trunk.gateway_uuid},function(row) enabled=row.enabled=='true' or row.enabled=='t' end)
        if not accepted or not enabled then session:hangup('CALL_REJECTED');return end
        session:setVariable('call_direction','inbound');internal=false
        local destination=rule.office
        local open,_,holiday=P.office(config,destination.number,clock)
        if rule.hours.type~='OfficeHours' then local d,t=clock(config.timezone);open=P.in_hours(rule.hours,d,t) end
        if holiday and rule.use_holiday then destination=rule.holiday elseif not open and rule.use_outside then destination=rule.outside end
        route(destination)
    elseif mode=='script' then
        local s=P.find(config.scripts,key)
        if not s or s.kind~='pin_menu' then session:hangup('SERVICE_UNAVAILABLE');return end
        session:answer()
        for _=1,s.attempts do
            local pin=session:playAndGetDigits(0,12,1,s.timeout*1000,'#','phrase:voicemail_enter_pass','silence_stream://100','[0-9]+',s.interdigit_timeout*1000)
            if s.pin_map[pin] then route({type='Extension',number=s.pin_map[pin]},key);return end
            if not session:ready() then return end
        end
        session:hangup('CALL_REJECTED')
    elseif mode=='voicemail_login' then
        if internal then voicemail(caller,true) else session:hangup('CALL_REJECTED') end
    elseif mode=='park' then session:execute('valet_park',realm..' '..key:sub(3))
    else session:hangup('UNALLOCATED_NUMBER') end
end
local ok=pcall(run)
db:release()
if not ok then freeswitch.consoleLog('ERR','[OpenWeb PBX] Call handling failed for domain '..domain..'\n');if session:ready() then session:hangup('NORMAL_TEMPORARY_FAILURE') end end
