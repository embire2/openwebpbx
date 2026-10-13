-- Initialize missing native queue records without reloading active queues.
-- queue load replaces the queue and resets all agents from XML, including
-- agents serving another caller. Native tier add loads a missing queue under
-- the module mutex and leaves existing queue/agent state and metrics intact.
local M={}
function M.ensure(api,config,queue,domain,contact)
    if type(domain)~='string' or #domain~=36 or not domain:match('^[a-f0-9%-]+$')
      or not tostring(queue.number):match('^%d%d%d*$') or #tostring(queue.number)>10
      or type(config.realm)~='string' or #config.realm>253 or not config.realm:match('^[a-z0-9][a-z0-9%.%-]+$') then error('Invalid native queue scope') end
    local name=tostring(queue.number)..'@'..config.realm
    local created={}
    local function command(value,already)
        local result=(api:execute('callcenter_config',value) or ''):gsub('%s+$','')
        if result:sub(1,3)=='+OK' or (already and result==already) then return end
        error('Native queue initialization unavailable')
    end
    for position,member in ipairs(queue.members or {}) do
        local id=member.agent_uuid
        if type(id)~='string' or #id~=36 or not id:match('^[a-f0-9%-]+$') then error('Invalid queue agent identity') end
        local details=api:execute('callcenter_config','agent list '..id) or ''
        local exists=false
        for line in details:gmatch('[^\r\n]+') do if line:sub(1,#id+1)==id..'|' then exists=true;break end end
        local user=config.users[tostring(member.number)]
        if not exists then
            local added=api:execute('callcenter_config','agent add '..id..' callback') or ''
            if added:sub(1,3)=='+OK' then
                created[id]=true
                for key,value in pairs({wrap_up_time=queue.wrap_up or 2,
                    max_no_answer=0,reject_delay_time=2,busy_delay_time=2,no_answer_delay_time=2}) do
                    command('agent set '..key..' '..id..' '..tonumber(value))
                end
                if user and user.enabled then
                    command('agent set contact '..id..' '..contact(user))
                end
            elseif added:gsub('%s+$','')~='-ERR Agent already exist!' then error('Native agent initialization unavailable') end
        end
        command('tier add '..name..' '..id..' Ready 1 '..position,'-ERR Tier already exist!')
    end
    return created
end
return M
