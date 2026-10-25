local module=assert(loadfile('app/pbx_setup/resources/switch/scripts/app/pbx_greetings/recording.lua'))()
local checks=0
local function check(v,name)if not v then error(name)end;checks=checks+1 end
local path=os.tmpname();local committed=0
local function wave(channels,bits,rate,frames)
    channels=channels or 1;bits=bits or 16;rate=rate or 8000;frames=frames or 2000
    local bytes=string.rep(string.char(30,15),frames*channels)
    return 'RIFF'..string.pack('<I4',36+#bytes)..'WAVEfmt '..string.pack('<I4I2I2I4I4I2I2',16,1,channels,rate,rate*channels*bits//8,channels*bits//8,bits)..'data'..string.pack('<I4',#bytes)..bytes
end
local function write(bytes)local f=assert(io.open(path,'wb'));f:write(bytes);f:close()end
local function fixture(options)
    options=options or {};local call={alive=true,steps={}}
    function call:ready()return self.alive end
    function call:streamFile(file)
        self.steps[#self.steps+1]=file
        if file=='instruction' and options.before_hash then self.queued_digit='#' end
        if file=='replay' and options.replay_hash then check(self.callback==nil,'Recording callback is removed before replay keypad input')end
        if options.disconnect_at==file then self.alive=false end
    end
    function call:flushDigits()self.flushed=true;self.queued_digit=nil end
    function call:setInputCallback(name)self.callback=name end
    function call:unsetInputCallback()self.callback=nil end
    function call:recordFile(file,length,threshold,silence)
        check(file==path and length==300 and threshold==0 and silence==0,'Bounded phone recording contract')
        check(self.flushed==true,'Old keypad digits cleared before recording')
        check(self.queued_digit==nil,'Hash pressed before recording is discarded')
        if options.record_error then error('Owned record failure')end
        write(options.bytes or wave())
        local result=_G[self.callback](self,'dtmf',{digit=options.digit or '#'})
        if options.digit=='1' then check(result==nil,'Other digits do not finish recording')else check(result=='break','Hash stops recording')end
        if options.disconnect_at=='record' then self.alive=false end
    end
    return call
end
local paths={instruction='instruction',replay='replay',saved='saved',partial=path}
local function run(options)
    local call=fixture(options)
    local yes,message=module.record(call,paths,function()committed=committed+1;call.steps[#call.steps+1]='commit' end)
    return yes,message,call
end
local ok,problem=pcall(function()
    write(wave());check(module.valid_wave(path),'Valid mono PCM accepted')
    for _,bytes in ipairs({'',string.rep('\0',3000),wave(2),wave(1,8),wave(1,16,44100),wave():sub(1,-2),wave()..'extra'}) do
        write(bytes);check(not module.valid_wave(path),'Malformed, stereo or unsupported WAV refused')
    end
    local yes,_,call=run();check(yes and committed==1,'Hash records and saves exactly once')
    check(call.callback==nil and _G.openwebGreetingInput==nil,'No recording input handler survives normal completion')
    check(table.concat(call.steps,',')=='instruction,tone_stream://%(500,0,1000),replay,'..path..',commit,saved','Replay completes before the recording is committed')
    for _,options in ipairs({{digit='1'},{before_hash=true,digit='1'},{disconnect_at='instruction'},{disconnect_at='record'},{disconnect_at=path},{bytes=string.rep('\0',3000)}})do
        local before=committed;local saved,message=run(options)
        check(not saved and type(message)=='string' and committed==before,'Interrupted, unfinished or invalid recording cannot replace audio')
    end
    local before=committed;local replaySaved=run({replay_hash=true});check(replaySaved and committed==before+1,'Hash during replay cannot save a second greeting')
    local broken=fixture({record_error=true});local success=pcall(function()module.record(broken,paths,function()error('Must not commit')end)end)
    check(not success and broken.callback==nil and _G.openwebGreetingInput==nil,'Record exceptions remove the callback before exiting')
    write(wave());local f=assert(io.open(path,'ab'));f:write('tamper');f:close();check(not module.valid_wave(path),'Trailing bytes violate the complete WAV length')
    print('PASS: '..checks..' phone recording, hash, replay-before-save, duration, WAV and disconnect controls')
end)
os.remove(path)
if not ok then error(problem)end
