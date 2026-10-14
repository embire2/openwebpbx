-- SPDX-License-Identifier: AGPL-3.0-or-later
local audio=assert(loadfile('app/switch/resources/scripts/resources/functions/windows_audio.lua'))()
local base=os.tmpname();os.remove(base);assert(os.execute('mkdir '..base)==true)
local count=0
local function check(value)assert(value);count=count+1 end
local function wav(path,rate,frames)
 local fmt=string.pack('<I2I2I4I4I2I2',1,1,rate,rate*2,2,16)
 local data=string.rep(string.pack('<i2',1234),frames)
 local f=assert(io.open(path,'wb'));f:write('RIFF'..string.pack('<I4',36+#data)..'WAVEfmt '..string.pack('<I4',16)..fmt..'data'..string.pack('<I4',#data)..data);f:close()
end
local a,b,out=base..'/a.wav',base..'/b.wav',base..'/out.wav'
wav(a,8000,100);wav(b,8000,200);check(audio.kind(a)=='wav');check(audio.concat(a,b,out))
local f=assert(io.open(out,'rb'));local bytes=f:read('*a');f:close();check(#bytes==644);check(string.unpack('<I4',bytes,41)==600);check(bytes:sub(45)==string.rep(string.pack('<i2',1234),300))
wav(b,16000,200);check(not pcall(audio.concat,a,b,out))
f=assert(io.open(b,'wb'));f:write('RIFF'..string.pack('<I4',99999999)..'WAVEdata'..string.pack('<I4',99999999));f:close();check(not pcall(audio.concat,a,b,out))
f=assert(io.open(b,'wb'));f:write('ID3fixture');f:close();check(audio.kind(b)=='mp3');check(not pcall(audio.concat,a,b,out));check(audio.kind(base..'/missing')==nil)
local before=package.config;package.config='\\\n;\n?\n!\n-';freeswitch={API=function()return {}end};local execute=os.execute;local captured;os.execute=function(cmd)captured=cmd;return true end
assert(loadfile('app/switch/resources/scripts/resources/functions/mkdir.lua'))()
mkdir('C:/Program Files/OpenWebPBX/FreeSWITCH/storage/default/fictional.invalid/8100');check(captured:find('C:/Program Files/',1,true)~=nil)
for _,path in ipairs({'relative/path','C:/unsafe%ENV%/path','C:/unsafe&command','C:/../outside','C:/line\nbreak','C:/quote"'})do check(not pcall(mkdir,path))end
os.execute=execute;package.config=before
for _,path in ipairs({a,b,out})do os.remove(path)end;assert(os.execute('rmdir '..base)==true)
print('PASS '..count..' portable Windows WAV/storage checks (Windows command branch captured; no native OS claim)')
