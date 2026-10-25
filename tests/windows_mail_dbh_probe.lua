-- Disposable hosted Windows, owned database and WAVs only; no sessions/calls/mail delivery.
local input=assert(argv and argv[1]);assert(package.config:sub(1,1)=='\\' and freeswitch and stream)
local function norm(s)return(s:gsub('\\','/'):gsub('/+$','')):lower()end
assert(input:match('^[A-Za-z]:/ProgramData/OpenWebPBX/mail%-dbh%-diagnostic/[a-f0-9]+/fixture%.private%.json$'))
local open=io.open;local f=assert(open(input,'rb'));local raw=f:read(32769);f:close();assert(#raw<=32768)
local json=require'resources.functions.lunajson';local p=json.decode(raw)
assert(p.tag=='openweb-owned-windows-mail-dbh-v1' and p.scope:match('^[a-f0-9]+$') and #p.scope==24)
local root=norm(assert(os.getenv('ProgramData')))..'/openwebpbx/mail-dbh-diagnostic/'..p.scope
assert(norm(input)==root..'/fixture.private.json' and norm(p.progress)==root..'/progress.safe.json')
assert(p.database=='maildbh_'..p.scope and p.password:match('^[A-Za-z0-9_-]+$'))
assert(not package.loaded['resources.functions.database'] and not package.loaded['resources.functions.config'])
package.path=p.code..'/?.lua;'..package.path
package.preload['resources.functions.config']=function()database={backend='native'};return true end
package.preload['resources.functions.database_handle']=function()
 database_handle=function(name)
  assert(name=='owned-windows-mail-dbh')
  return freeswitch.Dbh("pgsql://host='127.0.0.1' port='5433' dbname='"..p.database.."' user='postgres' password='"..p.password.."' application_name='owned-mail-dbh-"..p.scope.."'")
 end;return true
end
local api=freeswitch.API();local start=assert(tonumber(api:getTime()));local events={};local current='setup'
local result={schema=1,state='running',case='setup',phase='database',events=events,event_count=0,completed_cases=0,actual_native_dbh=false,private_database_identity=false,callbacks=0}
local function mark(phase,bytes)
 result.event_count=result.event_count+1;assert(result.event_count<100000);if #events==64 then table.remove(events,1)end;local elapsed=tonumber(api:getTime())-start
 assert(elapsed>=0 and elapsed<240000 and (bytes or 0)>=0 and (bytes or 0)<=2097152)
 result.case=current;result.phase=phase;events[#events+1]={case=current,phase=phase,bytes=bytes or 0,elapsed_ms=elapsed}
 local payload=json.encode(result);assert(#payload<=65536);local file=assert(open(p.progress,'wb'));assert(file:write(payload));assert(file:flush());file:close()
end
local db
local ok=pcall(function()
 mark('database_begin');local Database=require'resources.functions.database';db=Database.new('owned-windows-mail-dbh')
 assert(db:backend_name()=='native' and db:connected());result.actual_native_dbh=true
 local row=assert(db:first_row("select current_database() as name,inet_server_addr()::text as address,inet_server_port()::text as port,current_setting('data_directory') as directory"))
 assert(row.name==p.database and row.address=='127.0.0.1' and row.port=='5433' and norm(row.directory)==norm(assert(os.getenv('ProgramData'))..'/OpenWebPBX/database'))
 result.private_database_identity=true;mark('database_ready')
 local native_query=db.__base.query
 function db.__base:query(sql,callback)mark('native_query_begin',#sql);local returned,err=native_query(self,sql,callback);mark(returned and 'native_query_complete' or 'native_query_refused');return returned,err end
 local release=db.release
 function db:release()mark('release_begin');local returned=release(self);mark('release_complete');return returned end
 local quote=db.quote
 function db:quote(value)mark('quote_begin',#value);local escaped=quote(self,value);mark('quote_complete',#escaped);return escaped end
 local query=db.query
 function db:query(sql,...)
  mark('query_begin',#sql)
  local args={n=select('#',...),...};local callback=args[args.n]
  if type(callback)=='function'then args[args.n]=function(row)result.callbacks=result.callbacks+1;mark('callback',0);return callback(row)end end
  local returned,err=query(self,sql,(table.unpack or unpack)(args,1,args.n));mark(returned and 'query_complete' or 'query_refused');return returned,err
 end
 require'resources.functions.base64';local encode=base64.encode
 function base64.encode(bytes)mark('encode_begin',#bytes);local out=encode(bytes);mark('encode_complete',#out);return out end
 local cases={{name='small',bytes=3200},{name='medium',bytes=102400},{name='large',bytes=512000}}
 local enqueue=require'resources.functions.voicemail_mail_queue'.enqueue
 for index,case in ipairs(cases)do
  current=case.name;local path=p.root..'/'..case.name..'.wav';assert(norm(path)==root..'/'..case.name..'.wav')
  io.open=function(name,mode)
   local file,err=open(name,mode);if name~=path or not file then return file,err end
   mark('file_open');local proxy={}
   function proxy:seek(...)mark('file_seek');return file:seek(...)end
   function proxy:read(...)mark('file_read_begin');local data=file:read(...);mark('file_read_complete',data and #data or 0);return data end
   function proxy:close(...)mark('file_close');return file:close(...)end
   return proxy
  end
  local queue=string.format('00000000-0000-4000-8000-%012d',200+index)
  local values={queue=queue,attachment=string.format('00000000-0000-4000-8000-%012d',300+index),domain=p.domain,hostname='owned-mail-dbh',sender='',recipient='sink@example.invalid',subject="Owned O'Neil voicemail",body='<p>Fictional waveform</p>',message=string.format('00000000-0000-4000-8000-%012d',400+index),after='delete'}
  mark('enqueue_begin',case.bytes+44);assert(enqueue(db,values,path)==queue,'Owned native enqueue did not acknowledge')
  io.open=open;result.completed_cases=index;mark('enqueue_complete')
 end
 db:release();db=nil;result.state='passed';mark('complete')
end)
io.open=open
if not ok then result.state='failed';mark('operation_failed')end
if db then pcall(function()db:release()end)end
stream:write(json.encode({schema=1,state=result.state,actual_native_dbh=result.actual_native_dbh,completed_cases=result.completed_cases}))
