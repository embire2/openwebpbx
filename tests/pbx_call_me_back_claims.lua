-- Read-only reproduction of a duplicate/unclaimed Lua invocation; no call or DB.
local source=debug.getinfo(1,'S').source:sub(2);local root=source:match('^(.*)/tests/pbx_call_me_back_claims.lua$')or'.';scripts_dir=root..'/app/pbx_setup/resources/switch/scripts'
package.path=root..'/app/switch/resources/scripts/?.lua;'..package.path
package.loaded['resources.functions.config']=true
local checks=0
for _,mode in ipairs({'unclaimed','query-error','query-refused','claimed-no-service'})do
local claimed=false;local queries=0
package.loaded['resources.functions.database']={new=function()return{query=function(_,_,_,callback)
 queries=queries+1
 if mode=='query-error'then error('Controlled request-claim database failure')end
 if mode=='query-refused'then return false end
 if mode=='claimed-no-service'and queries==1 then claimed=true;callback({call_uuid='22222222-2222-4222-a222-222222222222',domain_uuid='33333333-3333-4333-a333-333333333333',service_uuid='44444444-4444-4444-a444-444444444444',caller_number='+27820000001'})end
 return true
end,release=function()end}end}
argv={'11111111-1111-4111-a111-111111111111'}
local deleted=0;local created=0
freeswitch={Session=function()created=created+1;error('An unclaimed request must never create a call')end,API=function()return{execute=function(_,command,argument)if command=='sched_del'then deleted=deleted+1;return'+OK'end;error('Unexpected engine operation')end}end,consoleLog=function()end}
assert(loadfile(scripts_dir..'/app/pbx_setup/call_me_back.lua'))()
assert(created==0,'The no-call scenario launched a session')
assert(deleted==(mode=='claimed-no-service'and 2 or 0),'Request-claim ownership did not govern timer cleanup')
checks=checks+2
end
print('PASS: '..checks..' actual callback claim-ownership and no-call cleanup controls')
local policy=assert(loadfile(scripts_dir..'/app/pbx_setup/cmb_policy.lua'))()
local hash=string.rep('a',64)
assert(policy.greeting_file({prompt_version='1.0.1'})=='greeting.wav')
assert(policy.greeting_file({prompt_audio_file='greeting.wav'})=='greeting.wav')
assert(policy.greeting_file({prompt_audio_file='greeting-keoma-'..hash..'.wav',prompt_sha256=hash,prompt_version='1.0.2'})=='greeting-keoma-'..hash..'.wav')
for _,row in ipairs({{prompt_audio_file='../customer.wav'},{prompt_audio_file='/customer.wav'},{prompt_audio_file='greeting-keoma-'..hash..'.wav',prompt_sha256=hash,prompt_version='1.0.1'},{prompt_audio_file='greeting-keoma-'..hash..'.wav',prompt_sha256=string.rep('b',64),prompt_version='1.0.2'},{prompt_audio_file='greeting-keoma-'..hash..'.wav',prompt_sha256=string.rep('a',63),prompt_version='1.0.2'}})do assert(policy.greeting_file(row)==nil)end
print('PASS: 8 legacy/default, committed Keoma selection and malformed/path escape controls')
