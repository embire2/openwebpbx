local domains=dofile('app/switch/resources/scripts/app/xml_handler/resources/scripts/directory/contact_realms.lua')
local count=0
local function check(value,name) if not value then error(name) end count=count+1 end
local function fixture(options)
 local db={calls={}}
 function db:query(sql,args,callback)
  self.calls[#self.calls+1]={sql=sql,args=args}
  if sql:find('to_regclass',1,true) then callback({relation=options.table==false and '' or 'v_pbx_sip_domains'})
  elseif sql:find('select d.domain_uuid',1,true) then
   for _,row in ipairs(options.owners or {{domain_uuid='uuid-a',domain_name='a.example.test',domain_enabled='true',suspended='false'}}) do callback(row) end
  elseif sql:find('select a.sip_domain',1,true) then for _,name in ipairs(options.aliases or {'phone-a.example.test'}) do callback({sip_domain=name}) end
  else error('Unexpected scoped query') end
 end
 return db
end
local db=fixture({})
local result=domains.realms(db,'uuid-a','a.example.test')
check(#result==2 and result[1]=='a.example.test' and result[2]=='phone-a.example.test','Canonical and exact owned alias returned.')
check(db.calls[2].args.domain=='a.example.test','Owner lookup uses the exact bound realm.')
check(db.calls[#db.calls].args.uuid=='uuid-a','Alias query binds the canonical owner UUID.')
check(db.calls[#db.calls].sql:find('a.enabled',1,true)~=nil,'Disabled alias contacts are excluded by query.')
check(db.calls[#db.calls].sql:find('foreign_domain',1,true)~=nil,'Canonical-domain collisions are excluded from contacts.')
check(#domains.realms(fixture({table=false}),'uuid-a','a.example.test')==1,'Legacy schema retains canonical contact only.')
check(#domains.realms(fixture({}),'uuid-b','a.example.test')==0,'Foreign domain UUID rejected.')
check(#domains.realms(fixture({}),'uuid-a','phone-a.example.test')==0,'Canonical argument cannot be replaced with alias.')
for _,bad in ipairs({'','a.example.test/evil','a.example.test;realm=b','*.example.test','A.example.test'}) do
 db=fixture({});check(domains.owner(db,bad)==nil and #db.calls==0,'Invalid exact realm refused before SQL: '..bad)
end
for _,field in ipairs({'domain_enabled','suspended'}) do
 local row={domain_uuid='uuid-a',domain_name='a.example.test',domain_enabled='true',suspended='false'};row[field]=field=='suspended' and 'true' or 'false'
 check(#domains.realms(fixture({owners={row}}),'uuid-a','a.example.test')==0,'Disabled/suspended owner cannot return contacts.')
end
check(domains.owner(fixture({owners={{domain_uuid='a',domain_name='a.example.test',domain_enabled='true'},{domain_uuid='b',domain_name='b.example.test',domain_enabled='true'}}}),'a.example.test')==nil,'Ambiguous canonical/alias ownership fails closed.')
result=domains.realms(fixture({aliases={'a.example.test','phone-a.example.test','phone-a.example.test','bad/path'}}),'uuid-a','a.example.test')
check(#result==2,'Duplicate and unsafe alias values do not broaden contacts.')
print('PASS: '..count..' exact realm/owner/enabled/suspension/contact scope checks.')
