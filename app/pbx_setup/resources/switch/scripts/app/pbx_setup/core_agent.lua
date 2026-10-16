-- Internal loopback application. A selected queue agent never forwards to voicemail.
require 'resources.functions.config'
if not session or not session:ready() then return end
local Database=require 'resources.functions.database';local json=require 'resources.functions.lunajson'
local P=loadfile(scripts_dir..'/app/pbx_setup/policy.lua')();local registered=loadfile(scripts_dir..'/app/pbx_setup/registered.lua')()
local mobile_wake=loadfile(scripts_dir..'/app/pbx_setup/mobile_wake.lua')()
local mobile_contact=loadfile(scripts_dir..'/app/pbx_setup/mobile_contact.lua')()
local contact_realms=loadfile(scripts_dir..'/app/xml_handler/resources/scripts/directory/contact_realms.lua')()
local db=Database.new('system');local api=freeswitch.API()
local function uuid(v)return type(v)=='string' and #v==36 and v:match('^[a-f0-9%-]+$')end
local domain=session:getVariable('domain_uuid');local number=session:getVariable('openweb_agent_number');local queue=session:getVariable('openweb_queue_number');local config
local function run()
    if not uuid(domain) or not number or not number:match('^%d%d%d*$') or #number>10 or not queue or not queue:match('^%d%d%d*$') or #queue>10
      or session:getVariable('loopback_leg')~='B' then return end
    local other=session:getVariable('other_loopback_leg_uuid')
    if not uuid(other) or api:execute('uuid_getvar',other..' domain_uuid'):gsub('%s+$','')~=domain then return end
    db:query([[select r.config from v_pbx_restore r join v_domains d using(domain_uuid) where r.domain_uuid=:d and d.domain_enabled='true'
      and not exists(select 1 from v_pbx_services s join v_pbx_tenants t using(tenant_uuid) where s.domain_uuid=r.domain_uuid and not t.enabled)]],{d=domain},function(r)config=json.decode(r.config)end)
    local u=config and config.users[number];local q=config and P.find(config.queues,queue)
    if not u or not u.enabled or not q then return end
    local owned_realms=contact_realms.realms(db,domain,config.realm)
    if not P.realm_config(config,owned_realms) then return end
    local assigned
    for _,m in ipairs(q.members or {}) do if tostring(m.number)==number and m.status=='LoggedIn' and not m.supervisor_break then assigned=m end end
    if not assigned then return end
    local function clock(zone)
        local raw=api:execute('strftime_tz',(zone or 'UTC')..' %w_%H:%M_%Y-%m-%d');local d,t,date=raw:match('^(%d)_(%d%d:%d%d)_(%d%d%d%d%-%d%d%-%d%d)')
        if not d then error('Clock unavailable') end;return tonumber(d),t,date
    end
    local profile=P.profile(config,number,clock)
    if P.queue_member_status(u,assigned,profile,false)~='Available' then return end
    local source=session:getVariable('cc_member_session_uuid') or session:getVariable('openweb_queue_source');local job=session:getVariable('openweb_callback_job');local allowed=false
    if uuid(job) then
        db:query([[select 1 as ok from v_pbx_jobs where job_uuid=:id and domain_uuid=:d and queue_number=:q
          and agent_number=:n and kind='callback' and state='calling' and lease_until>now() and expires_at>now()]],{id=job,d=domain,q=queue,n=number},function()allowed=true end)
    elseif uuid(source) and api:execute('uuid_exists',source):gsub('%s+$','')=='true' and api:execute('uuid_getvar',source..' domain_uuid'):gsub('%s+$','')==domain
      and api:execute('uuid_getvar',source..' queue_extension'):gsub('%s+$','')==queue then allowed=true end
    if not allowed then return end
    if (profile.busy_detection or 'UsePBXStatus')=='UsePBXStatus' then
        local ok,channels=pcall(json.decode,api:execute('show','channels as json'))
        if not ok then return end
        -- A callback's own loopback A/B legs already carry the selected
        -- identity; they do not constitute an unrelated busy conversation.
        if type(channels)=='table' and type(channels.rows)=='table' then
            local rows={}
            for _,row in ipairs(channels.rows) do if row.uuid~=other then rows[#rows+1]=row end end
            channels.rows=rows
        end
        if P.user_busy(channels,u,config.realm,session:getVariable('uuid'),owned_realms)~=false then return end
    end
    local scope_origin=uuid(source) and api:execute('uuid_getvar',source..' openweb_scope_origin'):gsub('%s+$','') or number
    if not config.users[scope_origin] then scope_origin='' end
    session:setVariable('openweb_scope_origin',scope_origin);session:setVariable('openweb_scope_target',number)
    session:setVariable('domain_name',config.realm);session:setVariable('hangup_after_bridge','true');session:setVariable('continue_on_fail','false')
    mobile_wake(db,api,P,session,domain,{u})
    if not session:ready() then return end
    local phone=registered(db,api,P,domain,u,config.realm)
    local answer=uuid(source) and 'lua app/pbx_setup/core_queue_answer.lua '..domain..' '..queue..' '..source..' '..number or nil
    local mobile=mobile_contact.available(db,api,P,domain,config,u,profile)
      and mobile_contact.dial(domain,config.realm,u,q.ring_timeout,session:getVariable('uuid'),session:getVariable('openweb_call_internal')=='true',answer)
    if not phone and not mobile then return end
    local vars='extension_uuid='..u.extension_uuid..',openweb_scope_origin='..scope_origin..',openweb_scope_target='..number..',sip_h_X-OpenWeb-Push-ID='..session:getVariable('uuid')..',domain_uuid='..domain..',domain_name='..config.realm..',rtp_secure_media=optional:AES_CM_128_HMAC_SHA1_80,leg_timeout='..q.ring_timeout
    if uuid(source) then vars=vars..",api_on_answer='lua app/pbx_setup/core_queue_answer.lua "..domain..' '..queue..' '..source..' '..number.."'" end
    if uuid(source) and u.record_calls and not (u.record_external_only and session:getVariable('openweb_call_internal')=='true') then
        vars=vars..',openweb_call_internal='..tostring(session:getVariable('openweb_call_internal')=='true')..",execute_on_answer='lua app.lua pbx_setup record_user "..number.."'"
    end
    local dial=phone and '['..vars..']user/'..u.auth_id..'@'..config.realm or nil
    if mobile then
        session:setVariable('ignore_early_media','true')
        dial=dial and dial..','..mobile or mobile
    end
    session:setVariable('call_timeout',tostring(q.ring_timeout))
    session:setVariable('originate_timeout',tostring(q.ring_timeout))
    session:setVariable('progress_timeout',tostring(q.ring_timeout))
    session:execute('bridge',dial)
end
local ok=pcall(run);db:release()
if not ok then freeswitch.consoleLog('ERR','[OpenWeb PBX] Selected queue phone delivery failed.\n') end
if session:ready() then session:hangup('NO_ANSWER') end
