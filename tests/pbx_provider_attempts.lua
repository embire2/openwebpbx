local A=assert(loadfile('app/pbx_setup/resources/switch/scripts/app/pbx_setup/provider_attempts.lua'))()
local P=assert(loadfile('app/pbx_setup/resources/switch/scripts/app/pbx_setup/policy.lua'))()
local n=0;local function ok(v,m)assert(v,m);n=n+1 end
freeswitch={consoleLog=function()end};local records={};local db={query=function(self,sql,p)records[#records+1]={sql=sql,p=p}end};local serial=0
local api={execute=function()serial=serial+1;return string.format('00000000-0000-4000-8000-%012d',serial)end};local vars={uuid='00000000-0000-4000-8000-000000000999'}
local call={getVariable=function(self,k)return vars[k]end,setVariable=function(self,k,v)vars[k]=v end};local d='00000000-0000-4000-8000-000000000998';local trunk={number='10000',gateway_uuid='00000000-0000-4000-8000-000000000997'}
local p=A.begin(db,api,call,d,trunk,'1000','0110000101',true);ok(p and records[1].p.state=='calling','Available attempt missing');ok(records[1].p.n==1,'First attempt order');ok(A.contact(p,'[foo=bar]sofia/gateway/test'):find('origination_uuid='..p.leg,1,true),'Native provider-leg identity absent');
A.finish(db,p,'NORMAL_TEMPORARY_FAILURE','sip:503',nil,false,true,true);ok(records[2].p.state=='failed' and records[2].p.code==503 and records[2].p.retry=='true','Actual SIP failure not recorded');
local skip=A.begin(db,api,call,d,trunk,'1000','0110000101',false);ok(skip and records[3].p.state=='skipped' and records[3].p.retry=='true' and records[3].p.n==2,'Unavailable provider order');
for _,case in ipairs({{'USER_BUSY','sip:486',false,true,false,'failed'},{'NORMAL_CLEARING','sip:200',true,false,false,'answered'},{'ORIGINATOR_CANCEL','',false,false,false,'cancelled'},{'NO_ANSWER','',false,true,false,'failed'}})do
 A.finish(db,p,case[1],case[2],nil,case[3],case[4],case[5]);local r=records[#records].p;ok(r.state==case[6] and r.retry=='false','Unsafe retry observation')
end
local broken={query=function()error('unavailable')end};ok(A.begin(broken,api,call,d,trunk,'1000','0110000101',true)==nil,'Diagnostic failure was treated as evidence');ok(A.contact(nil,'[foo=bar]contact')=='[foo=bar]contact','Diagnostic failure changed provider call');A.finish(broken,p,'FAIL','sip:503',nil,false,true,true);ok(true,'Diagnostic failure interrupted call');
local source=assert(io.open('app/pbx_setup/resources/switch/scripts/app/pbx_setup/jobs.lua')):read('*a');ok(source:find('attempts.begin',1,true) and source:find('attempts.finish',1,true),'Callbacks lack same attempt observer');
ok(not P.failover('SUCCESS','sip:503','true'),'Answered provider retried');ok(not P.failover('ORIGINATOR_CANCEL','','false'),'Cancelled provider retried');ok(not P.failover('NO_ANSWER','','false'),'Unanswered phone retried');ok(P.failover('NORMAL_TEMPORARY_FAILURE','sip:503','false'),'Service-unavailable provider not retried');
print('PASS: '..n..' provider observation/order/failure controls')
