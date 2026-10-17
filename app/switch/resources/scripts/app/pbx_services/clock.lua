-- GMT+2 has no daylight-saving transition. Targets are absolute minute boundaries.
local M={}
function M.next_minute(now_ms)
    return (math.floor(now_ms/60000)+1)*60000
end
function M.time_parts(epoch_ms)
    local local_minutes=math.floor(epoch_ms/60000)+120
    local hour=math.floor(local_minutes/60)%24
    return hour%12==0 and 12 or hour%12,local_minutes%60,hour>=12 and 'p-m' or 'a-m'
end
function M.run(session,api,root)
    if type(root)~='string' or root=='' then session:hangup('NORMAL_TEMPORARY_FAILURE');return end
    local durations=require 'app.pbx_services.clock_prompts'
    local base='openwebpbx/talking-clock-1.0.1-'
    local voice='en/us/callie/'
    local function play(path) if session:ready() then session:streamFile(root..'/'..path) end end
    local function sentence(target)
        local hour,minute,period=M.time_parts(target)
        local paths={base..'signal.wav'}
        local function add(path) paths[#paths+1]=path end
        local function number(n)
            if n<=20 or n%10==0 then add(voice..'digits/8000/'..n..'.wav')
            else add(voice..'digits/8000/'..(math.floor(n/10)*10)..'.wav');add(voice..'digits/8000/'..(n%10)..'.wav') end
        end
        number(hour)
        if minute==0 then add(voice..'time/8000/oclock.wav')
        else if minute<10 then add(voice..'time/8000/oh.wav') end;number(minute) end
        add(voice..'time/8000/'..period..'.wav');add(base..'exactly.wav')
        local total=0;for _,path in ipairs(paths) do total=total+assert(durations[path]) end
        return paths,total
    end
    local function now() return tonumber(api:getTime()) end -- native epoch milliseconds
    local function wait_until(target)
        while session:ready() do
            local remaining=target-now()
            if remaining<=0 then return -remaining end
            session:sleep(math.max(1,math.min(1000,math.floor(remaining))))
        end
    end
    -- Refuse missing assets rather than announcing incomplete or misleading time.
    for path in pairs(durations) do
        local f=io.open(root..'/'..path,'rb');if not f then session:hangup('NORMAL_TEMPORARY_FAILURE');return end;f:close()
    end
    session:answer();session:setVariable('playback_terminators','none')
    session:setVariable('timezone','Etc/GMT-2')
    play(base..'welcome.wav')
    local limit=now()+1800000 -- caller-local maximum of thirty minutes
    while session:ready() and now()<limit do
        local target=M.next_minute(now())
        local paths,total=sentence(target)
        if now()+total+300>target then target=target+60000;paths,total=sentence(target) end
        wait_until(target-total-300)
        if not session:ready() then break end
        for _,path in ipairs(paths) do play(path) end
        local lateness=wait_until(target)
        -- A delayed announcement or wall-clock step must never produce a stale signal.
        if session:ready() and lateness and lateness<250 then
            session:setVariable('openweb_clock_target_ms',tostring(target))
            session:setVariable('openweb_clock_signal_ms',tostring(now()))
            session:execute('playback','tone_stream://%(200,0,1000)')
        end
    end
    if session:ready() then session:hangup('NORMAL_CLEARING') end
end
return M
