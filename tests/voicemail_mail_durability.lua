-- Actual producer and named-SQL binding; all paths/accounts are disposable fixtures.
local root,folder,hostname=arg[1],arg[2],arg[3]
package.path=root..'/app/switch/resources/scripts/?.lua;'..package.path
package.preload['resources.functions.config']=function()database={backend='fixture'};return true end
package.preload['resources.functions.cache']=function()return{settings=true}end
local statements,mode,errors={},'ok',{}
package.preload['resources.functions.database.fixture']=function()
 local B={};B.__index=B
 function B.new()return setmetatable({},B)end
 function B:query(sql,callback)
  if sql:match('^WITH durable') or sql:lower():match('^insert into')then
   statements[#statements+1]=sql
   if mode=='throw'then error('controlled unavailable database')end
   if mode=='false'then return false end
   if callback then callback({email_queue_uuid=sql:match("'([0-9a-f]+%-[0-9a-f%-]+)'%s*,")})end
  end
  return true
 end
 return B
end
local sequence=0
freeswitch={consoleLog=function(level,message)if level=='err'then errors[#errors+1]=message end end,
 API=function()return{execute=function(_,command,value)assert(command=='sql_escape');return value:gsub("'","''")end,
 executeString=function(_,command)if command=='hostname'then return hostname end;assert(command=='create_uuid');sequence=sequence+1;return string.format('00000000-0000-4000-8000-%012d',sequence)end}end}
debug={sql=false};domain_name='fixture.invalid';domain_uuid='00000000-0000-4000-8000-000000000100'
local Database=require'resources.functions.database';dbh=Database.new('system')
local send_mail=require'resources.functions.send_mail';require'resources.functions.base64'
local uuid='00000000-0000-4000-8000-000000000101'
local headers={['X-FusionPBX-Domain-UUID']=domain_uuid,['X-FusionPBX-Domain-Name']=domain_name,
 ['X-FusionPBX-Call-UUID']=uuid,['X-FusionPBX-Email-Type']='voicemail',['X-FusionPBX-local_after_email']='false',
 ['X-OpenWebPBX-Voicemail-Attachment']='required'}
local f=assert(io.open(folder..'/msg_'..uuid..'.wav','rb'));local bytes=f:read('*a');f:close()
local output={}
local function call(name,path,encoded,wanted,backend)
 statements={};sequence=0;errors={};mode=backend or'ok'
 local queued,err=send_mail(headers,nil,'sink@example.invalid',{name,'Owned fixture voicemail'},path,encoded)
 assert((queued~=nil)==wanted,name)
 if not wanted then assert(type(err)=='string' and #errors==1,name..' must report preservation')end
 output[name]={sql=statements,queued=queued~=nil,refused=err~=nil}
end
call('atomic',folder..'/msg_'..uuid..'.wav',nil,true)
assert(#output.atomic.sql==1 and output.atomic.sql[1]:match('^WITH durable'))
call('fallback',folder..'/absent.wav',base64.encode(bytes),true)
call('missing',folder..'/missing.wav',nil,false)
call('empty',folder..'/empty.wav',nil,false)
call('oversized',folder..'/oversized.wav',nil,false)
call('invalid_base64',folder..'/missing.wav','****',false)
call('query_false',folder..'/msg_'..uuid..'.wav',nil,false,'false')
call('query_throw',folder..'/msg_'..uuid..'.wav',nil,false,'throw')
-- Exact original two-statement producer is retained as a real race control.
headers['X-OpenWebPBX-Voicemail-Attachment']=nil
statements={};sequence=0;errors={};mode='ok'
send_mail(headers,nil,'sink@example.invalid',{'legacy','Owned fixture'},folder..'/msg_'..uuid..'.wav')
assert(#statements==2);output.legacy={sql=statements}
headers['X-OpenWebPBX-Voicemail-Attachment']='none';headers['X-FusionPBX-local_after_email']='true'
statements={};sequence=0
send_mail(headers,nil,'sink@example.invalid',{'link','Owned link-only fixture'},nil,nil)
assert(#statements==1 and not statements[1]:find('voicemail-attachment-v1',1,true));output.link={sql=statements}
print(require('resources.functions.lunajson').encode(output))
