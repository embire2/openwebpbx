-- Internal engine operation: refresh only one extension's assigned queue agents.
local domain,number=argv[1],argv[2]
local function uuid(v) return type(v)=='string' and v:match('^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$')~=nil end
if not uuid(domain) or not number or not number:match('^%d%d%d*$') or #number>10 then if stream then stream:write('-ERR Invalid phone status request.\n') end;return end
local Database=require 'resources.functions.database'
local json=require 'resources.functions.lunajson'
local P=loadfile(scripts_dir..'/app/pbx_setup/policy.lua')()
local db=Database.new('system')
local api=freeswitch.API()
local config,allowed
-- A suspended tenant cannot reactivate its old call-center agent by a delayed job.
db:query([[select r.config,(d.domain_enabled='true' and not exists(
 select 1 from v_pbx_services s join v_pbx_tenants t using(tenant_uuid)
 where s.domain_uuid=d.domain_uuid and not t.enabled)) as allowed
 from v_pbx_restore r join v_domains d using(domain_uuid) where r.domain_uuid=:domain]],{domain=domain},function(r)
    config=json.decode(r.config);allowed=r.allowed=='t' or r.allowed=='true' or r.allowed==true
end)
local u=config and config.users and config.users[number]
local success=true
if u then
    local function clock(zone)
        local raw=api:execute('strftime_tz',(zone or 'Africa/Johannesburg')..' %w_%H:%M_%Y-%m-%d')
        local d,t,date=raw:match('^(%d)_(%d%d:%d%d)_(%d%d%d%d%-%d%d%-%d%d)')
        return tonumber(d),t,date
    end
    local profile=P.profile(config,number,clock)
    local reserved=false
    db:query("select 1 as ok from v_pbx_jobs where domain_uuid=:domain and agent_number=:number and state in ('starting','calling')",{domain=domain,number=number},function() reserved=true end)
    for _,q in ipairs(config.queues or {}) do for _,m in ipairs(q.members or {}) do
        if tostring(m.number)==number and uuid(m.agent_uuid) then
            local owned=false
            db:query('select 1 as ok from v_call_center_agents where domain_uuid=:domain and call_center_agent_uuid=:agent',{domain=domain,agent=m.agent_uuid},function() owned=true end)
            if owned then
                local enabled=allowed and u.enabled
                local status=not enabled and 'Logged Out' or ((reserved or m.supervisor_break) and 'On Break' or (u.queue_status=='LoggedIn' and m.status=='LoggedIn' and profile.queue_status~='0' and 'Available' or 'Logged Out'))
                -- Setting status preserves native ready_time, wrap-up, current bridge
                -- and call counters. Never unload a queue or reset an agent state.
                local result=api:execute('callcenter_config',"agent set status "..m.agent_uuid.." '"..status.."'")
                if not result:match('^%+OK') then success=false end
            else success=false end
        end
    end end
end
db:release()
if stream then stream:write(success and '+OK Phone status refreshed.\n' or '-ERR Assigned agent is unavailable.\n') end
