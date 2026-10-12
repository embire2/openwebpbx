-- Internal loopback application. A selected queue agent never forwards to voicemail.
require 'resources.functions.config'
if not session or not session:ready() then return end
local Database=require 'resources.functions.database';local json=require 'resources.functions.lunajson'
local P=loadfile(scripts_dir..'/app/pbx_setup/policy.lua')();local registered=loadfile(scripts_dir..'/app/pbx_setup/registered.lua')()
local mobile_wake=loadfile(scripts_dir..'/app/pbx_setup/mobile_wake.lua')()
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
    local assigned
    for _,m in ipairs(q.members or {}) do if tostring(m.number)==number and m.status=='LoggedIn' and not m.supervisor_break then assigned=m end end
    if not assigned or u.queue_status~='LoggedIn' then return end
    local function clock(zone)
        local raw=api:execute('strftime_tz',(zone or 'UTC')..' %w_%H:%M_%Y-%m-%d');local d,t,date=raw:match('^(%d)_(%d%d:%d%d)_(%d%d%d%d%-%d%d%-%d%d)')
        if not d then error('Clock unavailable') end;return tonumber(d),t,date
    end
    local profile=P.profile(config,number,clock)
    if profile.queue_status=='0' or next(profile.away or {}) then return end
    local source=session:getVariable('cc_member_session_uuid') or session:getVariable('openweb_queue_source');local job=session:getVariable('openweb_callback_job');local allowed=false
    if uuid(job) then
        db:query([[select 1 as ok from v_pbx_jobs where job_uuid=:id and domain_uuid=:d and queue_number=:q
          and agent_number=:n and kind='callback' and state='calling' and lease_until>now() and expires_at>now()]],{id=job,d=domain,q=queue,n=number},function()allowed=true end)
    elseif uuid(source) and api:execute('uuid_exists',source):gsub('%s+$','')=='true' and api:execute('uuid_getvar',source..' domain_uuid'):gsub('%s+$','')==domain
      and api:execute('uuid_getvar',source..' queue_extension'):gsub('%s+$','')==queue then allowed=true end
    if not allowed then return end
    session:setVariable('domain_name',config.realm);session:setVariable('hangup_after_bridge','true');session:setVariable('continue_on_fail','false')
    mobile_wake(db,api,P,session,domain,{u})
    if not session:ready() or not registered(db,api,P,domain,u,config.realm) then return end
    local vars='sip_h_X-OpenWeb-Push-ID='..session:getVariable('uuid')..',domain_uuid='..domain..',domain_name='..config.realm..',rtp_secure_media=optional:AES_CM_128_HMAC_SHA1_80,leg_timeout='..q.ring_timeout
    if uuid(source) then vars=vars..",api_on_answer='lua app/pbx_setup/core_queue_answer.lua "..domain..' '..queue..' '..source.."'" end
    if uuid(source) and u.record_calls and not (u.record_external_only and session:getVariable('openweb_call_internal')=='true') then
        vars=vars..',openweb_call_internal='..tostring(session:getVariable('openweb_call_internal')=='true')..",execute_on_answer='lua app.lua pbx_setup record_user "..number.."'"
    end
    session:execute('bridge','['..vars..']user/'..u.auth_id..'@'..config.realm)
end
local ok=pcall(run);db:release()
if not ok then freeswitch.consoleLog('ERR','[OpenWeb PBX] Selected queue phone delivery failed.\n') end
if session:ready() then session:hangup('NO_ANSWER') end
