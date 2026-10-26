-- QA-only native Windows enqueue; no calls, configuration changes or other tenants.
local function norm(path) return (path:gsub('\\','/'):gsub('/+$','')) end
local function guid(value) return type(value)=='string' and #value==36 and value:match('^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$') end
assert(package.config:sub(1,1)=='\\' and freeswitch and stream,'Native Windows Lua fixture required')
local path=assert(argv and argv[1]);local file=assert(io.open(path,'rb'));local raw=file:read(16385);file:close();assert(#raw<=16384)
local json=require'resources.functions.lunajson';local f=json.decode(raw)
assert(f.tag=='openweb-native-windows-voicemail-delete-v1' and type(f.scope)=='string' and #f.scope==24 and f.scope:match('^%x+$'))
for _,key in ipairs{'domain','mailbox','message','queue','attachment'} do assert(guid(f[key]),'Owned UUID required') end
local state=norm(assert(os.getenv('ProgramData')))..'/OpenWebPBX/native-qualification/'..f.scope
assert(norm(path):lower()==(state..'/delete-mail-'..f.queue..'.private.json'):lower(),'Owned producer path required')
local prefix=type(f.realm)=='string' and f.realm:match('^pbx%-(%x+)%.');assert(prefix and #prefix==12)
assert(f.service_name=='Fictional Native '..f.scope and f.hostname:lower()==assert(freeswitch.getGlobalVariable('hostname')):lower())
local storage=norm(assert(os.getenv('ProgramData')))..'/OpenWebPBX/storage'
assert(norm(f.audio):lower()==(storage..'/voicemail/default/'..f.realm..'/8103/msg_'..f.message..'.wav'):lower(),'Owned copied recording required')
local helper=assert(package.searchpath('resources.functions.voicemail_mail_queue',package.path))
assert(norm(helper):lower()==norm(f.helper):lower() and not package.loaded['resources.functions.voicemail_mail_queue'],'Fresh installed atomic helper required')
local Database=require'resources.functions.database';local db=Database.new('system');assert(db:connected() and db:backend_name()=='native')
local identity=assert(db:first_row("select current_database() as name,host(inet_server_addr()) as address,inet_server_port()::text as port"))
assert(identity.name=='fusionpbx' and identity.address=='127.0.0.1' and identity.port=='5433','Disposable native database required')
local row=assert(db:first_row([[select d.domain_name,s.service_name,v.voicemail_id,v.voicemail_local_after_email::text as keep,v.voicemail_file
 from v_domains d join v_pbx_services s using(domain_uuid) join v_voicemails v using(domain_uuid)
 join v_voicemail_messages m using(domain_uuid,voicemail_uuid)
 where d.domain_uuid=:domain and v.voicemail_uuid=:mailbox and m.voicemail_message_uuid=:message]],f))
assert(row.domain_name==f.realm and row.service_name==f.service_name and row.voicemail_id=='8103' and row.keep=='false' and row.voicemail_file=='attach','Owned delete mailbox required')
assert(db:first_value('select count(*)::text from v_email_queue where email_queue_uuid=:queue',{queue=f.queue})=='0')
local enqueue=require'resources.functions.voicemail_mail_queue'.enqueue
assert(enqueue(db,{queue=f.queue,attachment=f.attachment,domain=f.domain,hostname=f.hostname,sender='Native Windows Fixture <tenant@example.invalid>',recipient='sink@example.invalid',subject='Owned Windows delete voicemail',body='Fictional native voicemail',message=f.message,after='delete'},f.audio)==f.queue,'Actual native atomic enqueue refused')
db:release();stream:write(json.encode({schema=1,state='queued',actual_native_dbh=true,installed_atomic_helper=true}))
