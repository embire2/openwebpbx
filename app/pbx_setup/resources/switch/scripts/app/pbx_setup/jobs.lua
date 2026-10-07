-- Durable callback and hotel wake-up delivery. Invoked only through the local call engine.
require 'resources.functions.config'
local Database=require 'resources.functions.database'
local json=require 'resources.functions.lunajson'
local P=loadfile(scripts_dir..'/app/pbx_setup/policy.lua')()
local db=Database.new('system')
local api=freeswitch.API()
local id=argv and argv[1] or ''
if not id:match('^[a-f0-9%-]+$') or #id~=36 then db:release();return end
local job,config,call,reserved_user,reserved_queue
local function internal_target() return job.internal_target=='true' or job.internal_target=='t' end
local function query(sql,params,callback) return db:query(sql,params,callback) end
local function clock(zone)
    local value=api:execute('strftime_tz',(zone or 'UTC')..' %w_%H:%M_%Y-%m-%d')
    local d,t,date=value:match('^(%d)_(%d%d:%d%d)_(%d%d%d%d%-%d%d%-%d%d)')
    if not d then error('Clock unavailable') end
    return tonumber(d),t,date
end
local function finish(state,result,delay)
    query([[update v_pbx_jobs set state=:state,last_result=:result,due_at=now()+(:delay * interval '1 second'),
      lease_until=null,agent_number=null,updated_at=now() where job_uuid=:id and call_uuid=:call and state in ('starting','calling')]],
      {state=state,result=result,delay=delay or 60,id=id,call=job.call_uuid})
end
local function retry(result,delay)
    finish(tonumber(job.attempts)>=tonumber(job.max_attempts) and 'failed' or 'waiting',result,delay or 60)
end
local function active()
    local yes=false
    query("select 1 as ok from v_pbx_jobs where job_uuid=:id and call_uuid=:call and state='calling'",{id=id,call=job.call_uuid},function() yes=true end)
    return yes
end
local function user_free(u)
    if not u or not u.enabled or not P.contact(api:execute('sofia_contact',u.auth_id..'@'..config.realm)) then return false end
    local ok,channels=pcall(json.decode,api:execute('show','channels as json'))
    if not ok then return false end
    for _,c in ipairs(channels.rows or {}) do
        if c.presence_id==u.auth_id..'@'..config.realm or c.presence_id==u.number..'@'..config.realm then return false end
    end
    return true
end
local function outbound(number,agent,q)
    if internal_target() then
        local u=config.users[number]
        if u and u.enabled then
            return P.contact(api:execute('sofia_contact',u.auth_id..'@'..config.realm))
        end
        return nil
    end
    -- An inbound caller ID must never be able to reach an internal extension or feature code.
    number=(q.callback_prefix or '')..number
    if not number:match('^%+?%d+$') then return nil end
    local rule=P.outbound(config,number,agent)
    if not rule then return nil end
    for _,r in ipairs(rule.routes) do
        local trunk=config.trunks[tostring(r.trunk_id)]
        local enabled=false
        if trunk then query("select 1 as ok from v_gateways where domain_uuid=:domain and gateway_uuid=:id and enabled='true'",{domain=job.domain_uuid,id=trunk.gateway_uuid},function() enabled=true end) end
        if enabled then return 'sofia/gateway/'..trunk.gateway_uuid..'/'..r.prepend..number:sub(r.strip+1),r.caller_id~='' and r.caller_id or trunk.caller_id end
    end
end
local function deliver()
    query([[select j.*,r.config from v_pbx_jobs j join v_pbx_restore r using(domain_uuid)
      join v_domains d using(domain_uuid) where j.job_uuid=:id and j.state='starting' and j.expires_at>now() and d.domain_enabled='true'
      and not exists(select 1 from v_pbx_services s join v_pbx_tenants t using(tenant_uuid) where s.domain_uuid=j.domain_uuid and not t.enabled)]],{id=id},function(r) job=r;config=json.decode(r.config) end)
    if not job then return end
    local q,agent,contact,cid
    if job.kind=='callback' then
        q=P.find(config.queues,job.queue_number)
        if not q or (q.callback_mode or ((tonumber(q.callback) or -1)>=0 and 'request' or 'disabled'))=='disabled' then finish('cancelled','Queue callbacks are off');return end
        if not P.callback_open(config,q,clock) then retry('Waiting for office hours',60);return end
        api:execute('callcenter_config','queue load '..q.number..'@'..config.realm)
        -- Keep live callers ahead of callbacks. Callbacks are claimed in their original request order.
        local members=api:execute('callcenter_config','queue list members '..q.number..'@'..config.realm)
        if members:sub(1,4)=='-ERR' or members:find('|Waiting|',1,true) or members:find('|Trying|',1,true) then retry('Waiting for an agent',15);return end
        for _,m in ipairs(q.members) do
            local u=config.users[tostring(m.number)]
            local profile=u and P.profile(config,m.number,clock)
            if u and m.status=='LoggedIn' and u.queue_status=='LoggedIn' and profile.queue_status~='0' and not next(profile.away or {}) and user_free(u) then
                local details=api:execute('callcenter_config','agent list '..m.agent_uuid)
                if P.agent_available(details,m.agent_uuid,os.time()) then
                    contact,cid=outbound(job.target_number,tostring(m.number),q)
                    if contact then agent=u;break end
                end
            end
        end
        if not agent then retry('Waiting for an available agent and call route',30);return end
    else
        local room
        query('select occupied from v_pbx_hotel_rooms where domain_uuid=:domain and number=:number',{domain=job.domain_uuid,number=job.target_number},function(r) room=r end)
        if not room or (room.occupied~='t' and room.occupied~='true') then finish('cancelled','Room is checked out');return end
        agent=config.users[job.target_number]
        if not user_free(agent) then retry('Room phone unavailable',60);return end
    end
    local claimed=false
    query([[update v_pbx_jobs set state='calling',agent_number=:agent,attempts=attempts+1,lease_until=now()+interval '5 minutes',updated_at=now()
      where job_uuid=:id and call_uuid=:call and state='starting' and not exists
      (select 1 from v_pbx_jobs other where other.domain_uuid=:domain and other.agent_number=:agent and other.state in ('starting','calling') and other.job_uuid<>:id)
      returning attempts]],{agent=agent.number,id=id,call=job.call_uuid,domain=job.domain_uuid},function(r) job.attempts=r.attempts;claimed=true end)
    if not claimed then retry('Waiting for an agent',15);return end
    reserved_user=agent;reserved_queue=q
    for _,queue in ipairs(config.queues) do for _,m in ipairs(queue.members) do
        if tostring(m.number)==tostring(agent.number) then api:execute('callcenter_config','agent set status '..m.agent_uuid..' On Break') end
    end end
    -- Each registered device needs its own call UUID. Assigning a common originate UUID
    -- to multiple contacts makes the second device fail before it can ring.
    local vars='originate_timeout=30,domain_uuid='..job.domain_uuid..',domain_name='..config.realm..',ignore_early_media=true,origination_caller_id_name='..(job.kind=='callback' and 'Queue Callback' or 'Wake-up Call')..',origination_caller_id_number='..(q and q.number or agent.number)
    -- Resolve the current registration at delivery time. A cached directory dial-string
    -- may still point to a phone's previous port after it reconnects.
    local live_contact=P.contact(api:execute('sofia_contact',agent.auth_id..'@'..config.realm))
    if not live_contact then retry('Phone reconnected; retrying');return end
    vars=vars..',presence_id='..agent.auth_id..'@'..config.realm..',sip_invite_domain='..config.realm
    call=freeswitch.Session('{'..vars..'}'..live_contact)
    if not call:ready() then retry(job.kind=='callback' and 'Agent did not answer' or 'Room did not answer');return end
    local answered_uuid=call:getVariable('uuid')
    query("update v_pbx_jobs set call_uuid=:new where job_uuid=:id and call_uuid=:old and state='calling'",{new=answered_uuid,id=id,old=job.call_uuid})
    job.call_uuid=answered_uuid
    if not active() then call:hangup();return end
    if job.kind=='wakeup' then
        local digit=call:playAndGetDigits(1,1,3,7000,'','phrase:openweb_wakeup','silence_stream://100','1',2000)
        if digit=='1' then finish('completed','Wake-up confirmed') else retry('Wake-up was not confirmed') end
    else
        call:setVariable('hangup_after_bridge','false');call:setVariable('continue_on_fail','true')
        call:setVariable('openweb_call_internal',internal_target() and 'true' or 'false')
        call:execute('lua','app.lua pbx_setup record_user '..agent.number)
        call:setVariable('call_timeout','45')
        if cid and cid:match('^%+?%d+$') then call:setVariable('effective_caller_id_number',cid) end
        call:execute('bridge','[leg_timeout=45,domain_uuid='..job.domain_uuid..',domain_name='..config.realm..',origination_caller_id_name=Queue Callback]'..contact)
        if call:getVariable('originate_disposition')=='SUCCESS' then finish('completed','Connected') else retry('Caller did not answer') end
    end
    if call:ready() then call:hangup() end
end
local ok=pcall(deliver)
if not ok then
    if call and call:ready() then call:hangup() end
    if job then retry('Call could not be completed') end
    freeswitch.consoleLog('ERR','[OpenWeb PBX] Background call failed; request retained.\n')
end
-- Release the agent after wrap-up, even when a call failed or was cancelled.
if config and reserved_user then
    -- Reload current settings: an administrator may have changed status during this call.
    query('select config from v_pbx_restore where domain_uuid=:domain',{domain=job.domain_uuid},function(r) config=json.decode(r.config) end)
    local u=config.users[tostring(reserved_user.number)]
    for _,q in ipairs(config.queues) do for _,m in ipairs(q.members) do
        if tostring(m.number)==tostring(reserved_user.number) then
            local p=u and P.profile(config,m.number,clock)
            local available=u and u.enabled and u.queue_status=='LoggedIn' and m.status=='LoggedIn' and p.queue_status~='0'
            api:execute('callcenter_config','agent set ready_time '..m.agent_uuid..' '..(os.time()+(reserved_queue and reserved_queue.wrap_up or 2)))
            api:execute('callcenter_config','agent set status '..m.agent_uuid..' '..(available and 'Available' or 'Logged Out'))
        end
    end end
end
db:release()
