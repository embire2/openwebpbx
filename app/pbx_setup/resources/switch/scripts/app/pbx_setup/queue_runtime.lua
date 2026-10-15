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
    local levels={}
    for position,member in ipairs(queue.members or {}) do
        local id=member.agent_uuid
        if type(id)~='string' or #id~=36 or not id:match('^[a-f0-9%-]+$') then error('Invalid queue agent identity') end
        -- PHP (int) accepts a leading decimal/exponent number and maps other
        -- imported SkillGroup text (including empty text) to zero.
        local skill=member.skill
        if type(skill)=='string' then
            local prefix,rest=skill:match('^%s*([%+%-]?%d+%.?%d*)(.*)$')
            if not prefix then prefix,rest=skill:match('^%s*([%+%-]?%.%d+)(.*)$') end
            if prefix then prefix=prefix..(rest:match('^[eE][%+%-]?%d+') or '') end
            skill=tonumber(prefix) or 0
        elseif skill==nil then skill=0
        elseif type(skill)~='number' then error('Invalid queue agent priority') end
        local level=math.max(1,math.floor(skill)+1)
        if skill~=skill or skill==math.huge or skill==-math.huge or level>2147483647 then error('Invalid queue agent priority') end
        levels[position]=level
    end
    local function command(value,already)
        local result=(api:execute('callcenter_config',value) or ''):gsub('%s+$','')
        if result:sub(1,3)=='+OK' or (already and result==already) then return result end
        error('Native queue initialization unavailable')
    end
    local tiers
    local function existing_tier(id)
        if not tiers or not tiers[id] then
            local text=api:execute('callcenter_config','queue list tiers '..name) or ''
            if #text>1048576 then error('Native queue tiers unavailable') end
            tiers={};local columns,width;local lines=0
            for line in text:gmatch('[^\r\n]+') do
                lines=lines+1;if lines>4098 then error('Native queue tiers unavailable') end
                if line~='+OK' then
                    local values={};for value in (line..'|'):gmatch('(.-)|') do values[#values+1]=value end
                    if #values>64 then error('Native queue tiers unavailable') end
                    if not columns then
                        columns={};width=#values
                        for index,key in ipairs(values) do
                            if not key:match('^[a-z_]+$') or columns[key] then error('Native queue tiers unavailable') end
                            columns[key]=index
                        end
                        for _,key in ipairs({'queue','agent','level','position'}) do if not columns[key] then error('Native queue tiers unavailable') end end
                    else
                        if #values~=width then error('Native queue tiers unavailable') end
                        local queue_name,agent=values[columns.queue],values[columns.agent]
                        if queue_name==name then
                            if tiers[agent] then error('Native queue tiers unavailable') end
                            tiers[agent]={level=values[columns.level],position=values[columns.position]}
                        end
                    end
                end
            end
        end
        if not tiers[id] then error('Native queue tier unavailable') end
        return tiers[id]
    end
    for position,member in ipairs(queue.members or {}) do
        local id=member.agent_uuid
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
        -- The CLI supplies Ready itself; its remaining arguments are numeric
        -- level and position, matching the authoritative PHP tier insertion.
        local level=levels[position]
        local result=command('tier add '..name..' '..id..' '..level..' '..position,'-ERR Tier already exist!')
        if result=='-ERR Tier already exist!' then
            local tier=existing_tier(id)
            -- Older calls supplied "Ready 1 <position>", which atoi parsed
            -- as level 0 / position 1. Repair only that owned malformed pair.
            if tier.level=='0' and tier.position=='1' then
                command('tier set level '..name..' '..id..' '..level)
                if position~=1 then command('tier set position '..name..' '..id..' '..position) end
            end
        end
    end
    return created
end
return M
