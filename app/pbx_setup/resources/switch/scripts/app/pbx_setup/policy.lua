-- Pure call decisions, shared by the call runtime and deterministic restore checks.
local P = {}
function P.find(rows, number)
    for _, row in ipairs(rows or {}) do if tostring(row.number)==tostring(number) then return row end end
end
function P.department(config, number)
    local fallback
    for _, department in ipairs(config.departments or {}) do
        for _, member in ipairs(department.members or {}) do
            if tostring(member.number)==tostring(number) then
                if member.primary then return department end
                fallback=fallback or department
            end
        end
    end
    return fallback
end
function P.in_hours(hours, day, time)
    if not hours or hours.type=='AllHours' then return true end
    for _, period in ipairs(hours.periods or {}) do
        if tonumber(period.day)==tonumber(day) and time>=period.start and time<period['end'] then return true end
    end
    return false
end
function P.office(config, number, clock)
    local department=P.department(config,number)
    if not department then return true,false,false end
    local day,time,date=clock(department.timezone or config.timezone)
    local holiday=false
    for _, h in ipairs(department.holidays or {}) do if h.date==date then holiday=true end end
    local break_now=#(department.breaks.periods or {})>0 and P.in_hours(department.breaks,day,time)
    return P.in_hours(department.hours,day,time) and not break_now and not holiday,break_now,holiday
end
function P.profile(config, number, clock)
    local user=config.users[tostring(number)]
    local status=user.profile
    if tonumber(user.auto_status or '0')%2==1 then
        local open,break_now=P.office(config,number,clock)
        if not open then status=break_now and 'Away' or 'Out of office' end
    end
    return user.profiles[status] or user.profiles[user.profile]
end
function P.forward(profile,reason,internal,open)
    if next(profile.away or {}) then
        local rule=profile.away[internal and 'Internal' or 'External']
        if not rule then return {type='None'} end
        return not open and not rule.outside_inactive and rule.outside or rule.all
    end
    local rule=profile.available[reason]
    if not rule then return {type='None'} end
    return internal and not rule.internal_inactive and rule.internal or rule.all
end
function P.route_string(value)
    local kind,number,external=(value or ''):match('^([A-Za-z]+)%.([^.]*)%.(.*)$')
    if not kind or kind=='ProceedWithNoExceptions' then return nil end
    return {type=kind,number=number,external=external}
end
function P.object_destination(config,object,clock)
    local schedule=object.hours
    if not schedule then return nil end
    local open,break_now,holiday=P.office(config,object.number,clock)
    if schedule.hours.type~='OfficeHours' and schedule.hours.type~='OutOfOfficeHours' then
        local d,t=clock((P.department(config,object.number) or {}).timezone or config.timezone)
        open=P.in_hours(schedule.hours,d,t)
    elseif schedule.hours.type=='OutOfOfficeHours' then open=not open end
    if holiday then return P.route_string(schedule.holiday) end
    if break_now then return P.route_string(schedule['break']) end
    if not open then return P.route_string(schedule.outside) end
end
local function member_allowed(config,rule,caller)
    if #(rule.ranges or {})==0 and #(rule.departments or {})==0 then return true end
    for _, range in ipairs(rule.ranges or {}) do
        local c,f,t=tonumber(caller),tonumber(range.from),tonumber(range.to)
        if c and f and t and c>=f and c<=t then return true end
    end
    for _, name in ipairs(rule.departments or {}) do
        for _, department in ipairs(config.departments or {}) do
            if department.name==name then
                for _, member in ipairs(department.members or {}) do if tostring(member.number)==tostring(caller) then return true end end
            end
        end
    end
    return false
end
function P.outbound(config,number,caller)
    for _, rule in ipairs(config.outbound_rules or {}) do
        local prefix_ok=rule.prefix==''
        for prefix in (rule.prefix..','):gmatch('(.-),') do
            prefix=prefix:match('^%s*(.-)%s*$')
            if prefix~='' and number:sub(1,#prefix)==prefix then prefix_ok=true end
        end
        local length_ok=rule.lengths==''
        for part in (rule.lengths..','):gmatch('(.-),') do
            local f,t=part:match('^%s*(%d+)%s*%-%s*(%d+)%s*$')
            if f and #number>=tonumber(f) and #number<=tonumber(t) then length_ok=true end
            if tonumber(part)==#number then length_ok=true end
        end
        if prefix_ok and length_ok and member_allowed(config,rule,caller) then return rule end
    end
end
return P
