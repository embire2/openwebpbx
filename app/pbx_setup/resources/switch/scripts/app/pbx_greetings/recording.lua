-- The record/replay contract is also exercised with isolated call-session fixtures.
local M={}
local function uint(s,p,n)
    local value=0
    for i=n-1,0,-1 do local b=s:byte(p+i);if not b then return nil end;value=value*256+b end
    return value
end
function M.valid_wave(path)
    local file=io.open(path,'rb');if not file then return false end
    local size=file:seek('end');file:seek('set',0)
    if not size or size<1644 or size>32000000 then file:close();return false end
    local header=file:read(12)
    if not header or header:sub(1,4)~='RIFF' or header:sub(9,12)~='WAVE' or uint(header,5,4)+8~=size then file:close();return false end
    local format,rate,align,data=false,nil,nil,nil
    while file:seek()<size do
        local chunk=file:read(8);if not chunk or #chunk~=8 then break end
        local length=uint(chunk,5,4);local position=file:seek()
        if length>size-position then break end
        if chunk:sub(1,4)=='fmt ' then
            local bytes=file:read(math.min(length,40))
            if #bytes>=16 then
                rate=uint(bytes,5,4);align=uint(bytes,13,2)
                format=uint(bytes,1,2)==1 and uint(bytes,3,2)==1 and uint(bytes,15,2)==16 and align==2 and (rate==8000 or rate==16000 or rate==32000 or rate==48000)
            end
        elseif chunk:sub(1,4)=='data' then data=length end
        file:seek('set',position+length+(length%2))
    end
    file:close()
    return format and data and data>=1600 and data%align==0 and data/(rate*align)>=0.1 and data/(rate*align)<=301 or false
end
function M.record(call,paths,on_complete)
    if not call:ready() then return false,'The recording phone disconnected.' end
    call:streamFile(paths.instruction)
    if not call:ready() then return false,'The recording phone disconnected before the tone.' end
    call:flushDigits()
    call:streamFile('tone_stream://%(500,0,1000)')
    local finished=false;local recording=true
    _G.openwebGreetingInput=function(_,kind,input)
        if recording and kind=='dtmf' and input.digit=='#' then finished=true;return 'break' end
    end
    call:setInputCallback('openwebGreetingInput','')
    local recorded,problem=pcall(function()call:recordFile(paths.partial,300,0,0)end)
    recording=false
    call:unsetInputCallback()
    _G.openwebGreetingInput=nil
    if not recorded then error(problem) end
    if not finished then return false,'Press # after the greeting to save it. No greeting was saved.' end
    if not call:ready() then return false,'The recording phone disconnected before replay.' end
    if not M.valid_wave(paths.partial) then return false,'The recording was empty or incomplete. No greeting was saved.' end
    call:streamFile(paths.replay)
    call:streamFile(paths.partial)
    if not call:ready() then return false,'The recording phone disconnected during replay. No greeting was saved.' end
    on_complete()
    call:streamFile(paths.saved)
    return true,'Recorded, replayed and saved'
end
return M
