-- Execute the actual echo entry point with synthetic sessions and a scoped database.
local path='app/pbx_setup/resources/switch/scripts/app/pbx_setup/review_echo.lua'
local count=0
local function check(value,message)count=count+1;assert(value,message)end
local function run(overrides,available)
 local domain='00000000-0000-4000-a000-000000000001'
 local values={domain_uuid=domain,sip_auth_realm='demo.invalid',sip_auth_username='owm-00000000000000000000000000000001',destination_number='7000'}
 for k,v in pairs(overrides or {})do values[k]=v end
 local result={actions={},queries=0}
 local session={ready=function()return true end,getVariable=function(_,name)return values[name] end,answer=function()result.answered=true end,hangup=function(_,cause)result.hangup=cause end,execute=function(_,action,data)table.insert(result.actions,{action,data})end}
 local db={query=function(_,sql,p,callback)result.queries=result.queries+1;if available=='error'then error('unavailable')end;if available and p.domain==domain and p.realm=='demo.invalid' and p.auth=='owm-00000000000000000000000000000001' and p.number=='7000' then callback({allowed=1})end end,release=function()result.released=true end}
 local env=setmetatable({session=session,require=function(name)assert(name=='resources.functions.database');return{new=function()return db end}end},{__index=_G})
 assert(loadfile(path,'t',env))();return result
end
local valid=run({},true);check(valid.answered and valid.actions[1][1]=='sched_hangup' and valid.actions[1][2]=='+120 NORMAL_CLEARING' and valid.actions[2][1]=='echo','Assigned phone gets bounded native echo');check(valid.released,'Database released before media')
for _,input in ipairs({{sip_auth_username=''},{domain_uuid='invalid'},{openweb_provider_origin='true'},{sip_auth_realm='foreign.invalid'},{destination_number='7001'}})do local r=run(input,true);check(not r.answered and r.hangup=='CALL_REJECTED','Foreign or unauthenticated route denied')end
for _,available in ipairs({false,'error'})do local r=run({},available);check(not r.answered and r.hangup=='CALL_REJECTED' and r.released,'Unavailable/disabled assignment fails closed')end
print('PASS: '..count..' review echo authorization and duration checks')
