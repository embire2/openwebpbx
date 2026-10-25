-- South African time with immediate speech and a signal every fifteen seconds.
local M={CADENCE_MS=15000,VERSION='1.0.3'}
function M.next_signal(now_ms)
    return (math.floor(now_ms/M.CADENCE_MS)+1)*M.CADENCE_MS
end
function M.time_parts(epoch_ms)
    local seconds=math.floor(epoch_ms/1000)+7200
    return math.floor(seconds/3600)%24,math.floor(seconds/60)%60,seconds%60
end
function M.sentence(target,durations)
    local hour,minute,second=M.time_parts(target)
    local base='openwebpbx/talking-clock-1.0.3-'
    local paths={'openwebpbx/talking-clock-1.0.3-signal.wav'}
    local function add(path) paths[#paths+1]=path end
    local function number(value)
        local folder='en/us/callie/digits/8000/'
        if value<=20 or value%10==0 then add(folder..value..'.wav')
        else add(folder..(math.floor(value/10)*10)..'.wav');add(folder..(value%10)..'.wav') end
    end
    number(hour);add(base..(hour==1 and 'hour.wav' or 'hours.wav'));number(minute);add(base..(minute==1 and 'minute.wav' or 'minutes.wav'))
    add(base..'and.wav');number(second);add(base..'seconds.wav')
    add('openwebpbx/talking-clock-1.0.3-exactly.wav')
    local total=0
    for _,path in ipairs(paths)do total=total+assert(durations[path],'Missing clock duration')end
    return paths,total,hour,minute,second
end
function M.run(session,api,root)
    if type(root)~='string' or root=='' then session:hangup('NORMAL_TEMPORARY_FAILURE');return end
    local durations=require 'app.pbx_services.clock_prompts'
    local base='openwebpbx/talking-clock-1.0.3-'
    -- Validate every runtime dependency before answering, including the wait tick.
    for path,duration in pairs(durations)do
        if type(duration)~='number' or duration<=0 then session:hangup('NORMAL_TEMPORARY_FAILURE');return end
        local f=io.open(root..'/'..path,'rb')
        if not f then session:hangup('NORMAL_TEMPORARY_FAILURE');return end
        f:close()
    end
    local function now()
        local value=tonumber(api:getTime()) -- native epoch milliseconds
        assert(value and value>=0 and value<1e16,'Clock unavailable')
        return value
    end
    local function play(path)
        if not session:ready() then return false end
        local result=session:streamFile(root..'/'..path)
        if result==0 or result==false then
            if session:ready() then error('Clock playback failed')end
            return false
        end
        return session:ready()
    end
    local ok=pcall(function()
        session:answer();session:setVariable('playback_terminators','none')
        session:setVariable('timezone','Etc/GMT-2');session:setVariable('openweb_clock_version',M.VERSION)
        -- The native channel owns this timer and removes it when the caller leaves.
        session:execute('sched_hangup','+1800 NORMAL_CLEARING')
        local limit=now()+1800000
        if not play(base..'welcome.wav')then return end
        session:setVariable('openweb_clock_welcome_completed_ms',tostring(now()))
        local count=0
        while session:ready() and now()<limit do
            local start=now();local target=M.next_signal(start)
            local paths,total,hour,minute,second
            repeat
                paths,total,hour,minute,second=M.sentence(target,durations)
                assert(total+300<M.CADENCE_MS,'Clock announcement exceeds cadence')
                if start+total+300<=target then break end
                target=target+M.CADENCE_MS
            until false
            if target>=limit then break end
            count=count+1
            session:setVariable('openweb_clock_announcement_target_ms',tostring(target))
            session:setVariable('openweb_clock_announcement_ms',tostring(now()))
            session:setVariable('openweb_clock_hour',tostring(hour))
            session:setVariable('openweb_clock_minute',tostring(minute))
            session:setVariable('openweb_clock_second',tostring(second))
            session:setVariable('openweb_clock_announcements',tostring(count))
            -- Speech starts now, including on the first cycle. Never wait silently
            -- for a minute boundary before telling the caller the upcoming time.
            local previous=start
            for _,path in ipairs(paths)do if not play(path)then return end end
            while session:ready() and now()<target and now()<limit do
                local current=now();local remaining=target-current
                -- A backward wall-clock adjustment starts a fresh announcement.
                -- A valid first target can be more than one cadence ahead.
                if current<previous then break end
                previous=current
                if remaining>=durations[base..'tick.wav'] then if not play(base..'tick.wav')then return end
                else session:execute('playback','silence_stream://'..math.max(1,math.floor(remaining)))end
            end
            local lateness=now()-target
            -- Late speech or clock adjustments never produce a stale time signal.
            if session:ready() and now()<limit and lateness>=0 and lateness<250 then
                session:setVariable('openweb_clock_target_ms',tostring(target))
                session:setVariable('openweb_clock_signal_ms',tostring(now()))
                session:execute('playback','tone_stream://%(200,0,1000)')
            end
        end
        if session:ready()then session:hangup('NORMAL_CLEARING')end
    end)
    if not ok and session:ready()then
        session:setVariable('openweb_clock_error','unavailable')
        session:hangup('NORMAL_TEMPORARY_FAILURE')
    end
end
return M
