-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Exercise actual binary I/O through a Windows-path adapter, without cmd.exe.
local original_config,original_open,original_execute=package.config,io.open,os.execute
local base=os.tmpname();os.remove(base)
assert(os.execute('mkdir '..base)==true)
local source,destination=base..'/source',base..'/destination'
local bytes=string.rep('RIFF\0\255\26\r\nWAVE\128\0',12000)
local f=assert(io.open(source,'wb'));assert(f:write(bytes));assert(f:close())
local windows_source='C:/Program Files/FreeSWITCH/storage/default/fictional.invalid/8103/msg_original.wav'
local windows_destination='C:/Program Files/FreeSWITCH/storage/default/fictional.invalid/8102/msg_forwarded.wav'
local opened={};local removed={};local original_remove=os.remove
local checks=0
local function check(value)assert(value);checks=checks+1 end
package.config='\\\n;\n?\n!\n-'
io.open=function(path,mode)
 opened[#opened+1]={path=path,mode=mode}
 if path==windows_source then return original_open(source,mode) end
 if path==windows_destination then return original_open(destination,mode) end
 return nil,'Expected fixture-open failure'
end
os.execute=function()error('Windows binary copy must never invoke a shell')end
os.remove=function(path)removed[#removed+1]=path;if path==windows_destination then return original_remove(destination)end end
assert(loadfile('app/switch/resources/scripts/resources/functions/copy.lua'))()
check(copy(windows_source:gsub('/','\\'),windows_destination))
check(opened[1].path==windows_source and opened[1].mode=='rb')
check(opened[2].path==windows_destination and opened[2].mode=='wb')
f=assert(original_open(destination,'rb'));check(f:read('*a')==bytes);assert(f:close())
check(copy(windows_source,windows_destination)) -- Existing saved greeting can be replaced.
f=assert(original_open(destination,'rb'));check(f:read('*a')==bytes);assert(f:close())
for _,path in ipairs({'relative/file','\\\\server\\share\\file','C:/../outside','C:/./outside','C:/NUL.wav','C:/con','C:/COM1.txt','C:/LPT9','C:/file:stream','C:/trailing.','C:/trailing ','C:/line\nbreak','C:/bad?file','C:/quote"file'})do
 check(not pcall(copy,path,windows_destination))
end
check(not pcall(copy,windows_source,windows_source:upper()))
local before_alias=#opened
check(not pcall(copy,windows_source,windows_source:gsub('/','//')))
check(#opened==before_alias) -- Refuse before opening the destination for write.
check(not pcall(copy,'C:/missing.wav',windows_destination))
f=assert(original_open(destination,'rb'));check(f:read('*a')==bytes);assert(f:close())
check(not pcall(copy,windows_source,'C:/missing-parent/file.wav'))
local input_closed,output_closed=false,false
io.open=function(path,mode)
 if mode=='rb' then return {read=function()return 'bytes'end,close=function()input_closed=true;return true end}end
 return {write=function()return nil,'Expected fixture-write failure'end,close=function()output_closed=true;return true end}
end
check(not pcall(copy,windows_source,windows_destination))
check(input_closed and output_closed and removed[#removed]==windows_destination)
package.config=original_config;io.open=original_open;os.remove=original_remove
local command;os.execute=function(value)command=value;return true end
check(copy('/tmp/original.wav','/tmp/forwarded.wav')=='cp "/tmp/original.wav" "/tmp/forwarded.wav"')
check(command=='cp "/tmp/original.wav" "/tmp/forwarded.wav"')
os.execute=original_execute
os.remove(source);os.remove(destination);assert(os.execute('rmdir '..base)==true)
print('PASS '..checks..' Windows binary-copy/path/refusal checks; Linux command unchanged, no native Windows claim')
