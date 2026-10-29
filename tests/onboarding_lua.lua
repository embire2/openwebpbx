-- Real gate code and JSON parser, isolated database/filesystem boundaries.
package.path='app/switch/resources/scripts/?.lua;'..package.path
local json=require'resources.functions.lunajson'
local gate=dofile('app/pbx_setup/resources/switch/scripts/app/pbx_onboarding/gate.lua')
local count=0
local function check(value,message)assert(value,message);count=count+1 end
local domain='11111111-1111-4111-a111-111111111111'
local row={hostname='fixture.openwebpbx.com',key_hash=string.rep('a',64),server_host='node-'..string.rep('b',32)..'.openwebpbx.com',grant_hash=string.rep('c',64)}
local future=os.date('!%Y-%m-%dT%H:%M:%SZ',os.time()+3600)
local marker=false;local installed=false;local required=false;local ready=false
local snapshot={schema=1,server_host=row.server_host,key_hash=row.key_hash,aliases={[row.hostname]=future},authorizations={[domain]={grant_hash=row.grant_hash,expires_at=future}}}
local db={query=function(self,sql,params,callback)
 if type(params)=='function'then callback=params end
 if sql:find('to_regclass',1,true)then callback({installed=installed})
 elseif sql:find('select required',1,true)then callback({required=required})
 elseif sql:find('select domain_uuid from',1,true)then callback({domain_uuid=domain})
 elseif ready then callback(row)end
end}
local original=io.open
io.open=function(path,mode)
 if path:match('/onboarding%-required$')then return marker and {close=function()end} or nil end
 if path:match('/tenant%-domains/ready.json$')then return {read=function()return json.encode(snapshot)end,close=function()end}end
 error('Unexpected filesystem access '..tostring(path))
end
check(gate.allowed(db,domain),'Legacy absent policy preserves calls')
installed=true;check(gate.allowed(db,domain),'Explicit false legacy policy preserves calls')
required=true;check(not gate.allowed(db,domain),'Fresh unregistered blocks')
required=false;marker=true;check(not gate.allowed(db,domain),'Durable marker blocks restored false policy')
ready=true;check(gate.allowed(db,domain),'Matching root-verified receipt and HTTPS allow')
check(gate.context(db,'ingress@fixture.example.test',nil),'Context resolves its own registered domain')
check(gate.context(db,'public',nil),'Public ingress is filtered by target')
check(not gate.allowed(db,'invalid'),'Malformed domain blocks')
local auth=snapshot.authorizations;snapshot.authorizations=nil;check(not gate.allowed(db,domain),'Database state alone cannot authorize');snapshot.authorizations=auth
auth[domain].grant_hash=string.rep('d',64);check(not gate.allowed(db,domain),'Changed database activation cannot reuse root proof');auth[domain].grant_hash=row.grant_hash
auth[domain].expires_at='2000-01-01T00:00:00Z';check(not gate.allowed(db,domain),'Expired root receipt blocks');auth[domain].expires_at=future
snapshot.aliases[row.hostname]='2000-01-01T00:00:00Z';check(not gate.allowed(db,domain),'Expired HTTPS blocks');snapshot.aliases[row.hostname]=future
snapshot.key_hash=string.rep('f',64);check(not gate.allowed(db,domain),'Other instance key blocks');snapshot.key_hash=row.key_hash
snapshot.server_host='other.example.test';check(not gate.allowed(db,domain),'Other server blocks');snapshot.server_host=row.server_host
local fn=db.query;db.query=function()error('Database unavailable')end;check(not gate.allowed(db,domain),'Database failure refuses safely');db.query=fn
io.open=original
check(gate.instant('1970-01-01T00:00:00Z')==0,'UTC epoch exact')
check(gate.instant('2000-02-29T12:00:00Z')==951825600,'Leap-year epoch exact')
for _,invalid in ipairs({'2025-02-29T00:00:00Z','2026-00-10T00:00:00Z','2026-13-01T00:00:00Z','2026-10-29T24:00:00Z','2026-10-29T00:00:00+02:00','invalid'})do check(gate.instant(invalid)==nil,'Malformed timestamp refused')end
print('PASS '..count..' actual Lua activation, transport and legacy controls')
