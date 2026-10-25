-- Opt-in engine-side DBh proof. Only an owned disposable Unix-socket cluster is admitted.
local path=argv and argv[1]
assert(type(path)=='string' and path:match('^/tmp/openweb%-voicemail%-durable%-[%w_%-]+/native%-fixture%.json$'),'Owned native voicemail fixture required')
local f=assert(io.open(path,'rb'));local raw=f:read('*a');f:close();assert(#raw<8192)
local fixture=require('resources.functions.lunajson').decode(raw)
assert(fixture.tag=='openweb-owned-voicemail-mail-dbh-v1')
assert(type(fixture.socket)=='string' and fixture.socket:match('^/tmp/openweb%-voicemail%-durable%-[%w_%-]+/socket$'))
assert(type(fixture.port)=='number' and fixture.port>=1024 and fixture.port<=65535)
assert(type(fixture.code)=='string' and fixture.code==fixture.socket:gsub('/socket$','/native-sources'))
assert(type(fixture.audio)=='string' and fixture.audio==fixture.socket:gsub('/socket$','/audio/msg_00000000-0000-4000-8000-000000000101.wav'))
assert(not package.loaded['resources.functions.config'] and not package.loaded['resources.functions.database'],'Fresh isolated Lua environment required')
package.preload['resources.functions.config']=function()database={backend='native'};return true end
package.preload['resources.functions.database_handle']=function()
 database_handle=function(name)
  assert(name=='owned-voicemail-mail-fixture')
  return freeswitch.Dbh("pgsql://host='"..fixture.socket.."' port='"..fixture.port.."' dbname='postgres' user='postgres' application_name='owned-native-voicemail-mail'")
 end
 return true
end
package.path=fixture.code..'/?.lua;'..package.path
local Database=require'resources.functions.database'
local db=Database.new('owned-voicemail-mail-fixture')
assert(db:backend_name()=='native' and db:connected())
local identity=assert(db:first_row([[select current_setting('data_directory') as data_directory,
 current_database() as database,coalesce(inet_server_addr()::text,'local') as address]]))
assert(identity.data_directory==fixture.socket:gsub('/socket$','/cluster') and identity.database=='postgres' and identity.address=='local','Disposable local database identity refused')
local enqueue=require'resources.functions.voicemail_mail_queue'.enqueue
local values={queue='00000000-0000-4000-8000-000000000200',attachment='00000000-0000-4000-8000-000000000201',domain='00000000-0000-4000-8000-000000000100',
 hostname='owned-native-fixture',sender='',recipient='sink@example.invalid',subject='Owned native DBh proof',body='Fictional voicemail',message='00000000-0000-4000-8000-000000000202',after='delete'}
assert(enqueue(db,values,fixture.audio)==values.queue,'Native DBh callback did not acknowledge atomic queue')
local row=assert(db:first_row('select email_action_before from v_email_queue where email_queue_uuid=:queue',{queue=values.queue}))
assert(row.email_action_before=='voicemail-attachment-v1')
assert(db:query('alter table v_email_queue_attachments rename to owned_attachment_temporarily_unavailable'))
values.queue='00000000-0000-4000-8000-000000000300';values.attachment='00000000-0000-4000-8000-000000000301'
local queued,err=enqueue(db,values,fixture.audio)
assert(not queued and type(err)=='string','Native schema refusal did not preserve voicemail')
assert(db:query('alter table owned_attachment_temporarily_unavailable rename to v_email_queue_attachments'))
assert(db:first_value('select count(*)::text as count from v_email_queue where email_queue_uuid=:queue',{queue=values.queue})=='0','Native schema refusal committed a header')
db:release()
stream:write(require('resources.functions.lunajson').encode({native_dbh=true,disposable_database_identity=true,success_callback=true,schema_failure_atomic=true}))
