package.path='app/switch/resources/scripts/?.lua;'..package.path
local M=require 'app.pbx_services.clock'
local count=0
local function check(v)assert(v);count=count+1 end
local function parts(ms,h,m,p)local a,b,c=M.time_parts(ms);check(a==h and b==m and c==p)end
parts(0,2,0,'a-m');parts(46800000+3420000,3,57,'p-m')
parts(79200000,12,0,'a-m');parts(36000000,12,0,'p-m')
for minute=0,1439 do
    local h,m,p=M.time_parts(minute*60000)
    check(h>=1 and h<=12 and m==minute%60 and (p=='a-m' or p=='p-m'))
    check(M.next_minute(minute*60000+59999)==(minute+1)*60000)
end
-- Execute the real scheduler using the actual sealed prompt durations.
local durations=require 'app.pbx_services.clock_prompts'
local open=io.open;io.open=function()return {close=function()end}end
local function run(step)
    local now=1792245412345;local alive=true;local tones={};local vars={};local said={}
    local session={ready=function()return alive end,answer=function()end,
      setVariable=function(_,k,v)vars[k]=v end,
      hangup=function()alive=false end,
      sleep=function(_,ms)now=now+ms end,
      streamFile=function(_,path)
        local key=path:sub(#'/sounds/'+1);check(durations[key]~=nil);said[#said+1]=key;now=now+durations[key]
        if step and key:find('exactly',1,true) then now=now+step;step=nil end
      end,
      execute=function(_,app,data)
        check(app=='playback' and data=='tone_stream://%(200,0,1000)')
        check(now%60000==0);check(tonumber(vars.openweb_clock_target_ms)==now)
        tones[#tones+1]=now;now=now+200;if #tones==2 then alive=false end
      end}
    M.run(session,{getTime=function()return tostring(now)end},'/sounds')
    check(#tones==2 and tones[2]-tones[1]==60000)
    check(said[1]:find('welcome',1,true)~=nil)
end
run();run(2000) -- late speech skips its expired signal, then returns to a correct boundary
io.open=open
print('PASS '..count..' GMT+2 clock rollover and scheduler controls')
