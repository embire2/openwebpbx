package.path='app/switch/resources/scripts/?.lua;'..package.path
local M=require 'app.pbx_services.clock'
local durations=require 'app.pbx_services.clock_prompts'
local count=0
local function check(value,message)assert(value,message);count=count+1 end
-- Independent UTC calendar conversion checks all seconds and midnight rollover.
for second=0,86399 do
    local h,m,s=M.time_parts(second*1000)
    local expected=os.date('!%H:%M:%S',second+7200)
    check(string.format('%02d:%02d:%02d',h,m,s)==expected,'GMT+2 time/seconds mismatch')
end
local longest=0
for second=0,86399,15 do
    local target=second*1000
    local paths,total,h,m,s=M.sentence(target,durations)
    check(total+300<M.CADENCE_MS,'A spoken time cannot fit its cadence')
    check(paths[1]=='openwebpbx/talking-clock-1.0.1-signal.wav'and paths[#paths]=='openwebpbx/talking-clock-1.0.1-exactly.wav','Exact-signal statement changed')
    check(M.next_signal(target-1)==target,'Signal boundary changed')
    longest=math.max(longest,total)
end
local open=io.open;io.open=function()return{close=function()end}end
local function run(options)
    options=options or{}
    local now=options.start or 1792245412345;local started=now;local alive=true;local tones={};local vars={};local speech={};local ticks=0;local scheduled=false;local cause;local step=options.step;local jumped=false;local statements={};local backward_target;local forward_target
    local session={ready=function()return alive end,answer=function()check(not options.missing,'Missing files answered')end,
        setVariable=function(_,key,value)
            vars[key]=value
            if key=='openweb_clock_announcements'then local target=tonumber(vars.openweb_clock_announcement_target_ms);statements[target]=(statements[target]or 0)+1 end
        end,
        hangup=function(_,value)cause=value;alive=false end,
        streamFile=function(_,path)
            local key=path:sub(#'/sounds/'+1);check(durations[key]~=nil,'Unsealed prompt played')
            if key:find('tick.wav',1,true)then
                ticks=ticks+1
                if options.backward and not jumped then backward_target=tonumber(vars.openweb_clock_announcement_target_ms);now=now-60000;jumped=true end
            else speech[#speech+1]={path=key,at=now,target=vars.openweb_clock_announcement_target_ms}end
            now=now+durations[key]
            if options.backward_speech and not jumped and key:find('exactly.wav',1,true)then backward_target=tonumber(vars.openweb_clock_announcement_target_ms);now=now-60000;jumped=true end
            if step and key:find('exactly.wav',1,true)then forward_target=tonumber(vars.openweb_clock_announcement_target_ms);now=now+step;step=nil end
            if options.fail and key:find('signal.wav',1,true)then return 0 end
            if options.early and#speech==1 then alive=false end
            if options.expire and#speech==1 then now=started+1800001 end
            return 1
        end,
        execute=function(_,app,data)
            if app=='sched_hangup'then check(data=='+1800 NORMAL_CLEARING');scheduled=true;return end
            check(app=='playback','Clock used a non-media wait')
            if data:find('silence_stream://',1,true)==1 then
                local delay=tonumber(data:match('(%d+)$'));check(delay>=1 and delay<durations['openwebpbx/talking-clock-1.0.2-tick.wav'],'Long silent playback gap');now=now+delay;return
            end
            check(data=='tone_stream://%(200,0,1000)','Unexpected exact time signal')
            local target=tonumber(vars.openweb_clock_target_ms)
            check(now==target,'Signal did not match its spoken time')
            local h,m,s=M.time_parts(target)
            check(tonumber(vars.openweb_clock_hour)==h and tonumber(vars.openweb_clock_minute)==m and tonumber(vars.openweb_clock_second)==s,'Spoken time metadata does not match signal')
            tones[#tones+1]=target;now=now+200
            if#tones==3 then alive=false end
        end}
    local api={getTime=function()return options.invalid and'invalid'or tostring(now)end}
    M.run(session,api,'/sounds')
    check(scheduled,'Native channel lifetime cap absent')
    if options.fail or options.invalid then check(cause=='NORMAL_TEMPORARY_FAILURE','Media/time failure did not close safely');return end
    if options.expire then check(cause=='NORMAL_CLEARING'and#tones==0,'Thirty-minute boundary extended a call');return end
    if options.early then check(#speech==1 and#tones==0,'Caller hangup continued playback');return end
    check(#tones==3,'Expected three completed announcements')
    check(tones[2]-tones[1]==M.CADENCE_MS and tones[3]-tones[2]==M.CADENCE_MS,'Announcements did not keep fifteen-second cadence')
    check(speech[1].path:find('welcome.wav',1,true)~=nil,'Short welcome absent')
    check(speech[2].path:find('signal.wav',1,true)~=nil and speech[2].at==started+durations[speech[1].path],'First time statement waited after welcome')
    check(speech[3].at-started<4000,'Caller waited too long to hear the hour')
    check(ticks>0,'Wait intervals did not provide audible media')
    check(vars.openweb_clock_version=='1.0.2','Runtime version absent')
    if options.backward or options.backward_speech then check(jumped and tones[1]<backward_target,'A real backward step did not select a fresh earlier target')
    elseif options.step then check(forward_target and tones[1]>forward_target,'A stale pre-forward-step signal was emitted')
    else
        local total=0;for _,n in pairs(statements)do check(n==1,'A monotonic first target was spoken more than once');total=total+n end
        check(total==3,'Three valid signals must have exactly three spoken statements')
    end
    if options.first_target then check(tones[1]==options.first_target,'Boundary control selected a different first target')end
end
for _,offset in ipairs({0,1,125,999,1345,7234,14999})do run({start=1792245405000+offset})end
-- Native fresh17 reproduction: the next-quarter sentence plus 300ms cannot
-- fit, but the following target initially leaves a legitimate >15s wait.
for _,case in ipairs({{5300,1792342215000},{5847,1792342230000},{6200,1792342230000}})do
    run({start=1792342200000+case[1]-durations['openwebpbx/talking-clock-1.0.2-welcome.wav'],first_target=case[2]})
end
run({step=20000});run({backward=true});run({backward_speech=true});run({early=true});run({fail=true});run({invalid=true});run({expire=true})
io.open=function()return nil end
local answered=false;local failure
M.run({answer=function()answered=true end,hangup=function(_,cause)failure=cause end},{},'/sounds')
check(not answered and failure=='NORMAL_TEMPORARY_FAILURE','Missing asset did not refuse before answer')
io.open=open
print('PASS '..count..' GMT+2 seconds, immediate speech, media-filled waits, native cap and failure controls; maximum sealed statement '..longest..'ms')
