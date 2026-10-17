-- Execute the real answer hook with controlled DB/API failures, without any PBX connection.
local source=debug.getinfo(1,'S').source:sub(2)
local root=source:match('^(.*)/tests/pbx_call_me_back_answer_faults.lua$') or '.'
scripts_dir=root..'/app/pbx_setup/resources/switch/scripts'
package.loaded['resources.functions.config']=true
local checks=0
local function check(value,message)if not value then error(message)end;checks=checks+1 end
for _,mode in ipairs({'first-timer-refused','second-timer-refused','db-query-refused','db-open-exception','db-query-exception','invalid-reservation','success'})do
 local hungup=false;local deleted=false;local timers={};local released=false
 argv={'11111111-1111-4111-a111-111111111111'}
 package.loaded['resources.functions.database']={new=function()
  if mode=='db-open-exception'then error('Controlled private DB-open failure')end
  return{
   query=function(_,_,_,callback)
    if mode=='db-query-exception'then error('Controlled private DB-query failure')end
    if mode=='db-query-refused'then return false end
    callback({call_uuid='22222222-2222-4222-a222-222222222222',reserved_seconds=mode=='invalid-reservation'and'601'or'600'});return true
   end,
   release=function()released=true end,
  }
 end}
 freeswitch={consoleLog=function()end,API=function()return{execute=function(_,command,argument)
  if command=='sched_del'then deleted=true;return'+OK'end
  if command=='sched_api'then
   timers[#timers+1]=argument
   if mode=='first-timer-refused'or(mode=='second-timer-refused'and#timers==2)then return'-ERR controlled scheduler refusal'end
   return'+OK Added: 1'
  end
  error('Unexpected engine command in controlled answer hook')
 end}end}
 session={ready=function()return true end,getVariable=function()return'33333333-3333-4333-a333-333333333333'end,hangup=function()hungup=true end,execute=function()error('A hard limit must have an acknowledged installation result')end}
 assert(loadfile(scripts_dir..'/app/pbx_setup/call_me_back_answer.lua'))()
 if mode=='success'then
  check(not hungup,'The valid answer hook refused a permitted call.')
  check(#timers==2 and deleted,'Successful destination answer did not replace both hard limits before releasing the short safety timer.')
  check(timers[1]:find('uuid_kill 22222222-2222-4222-a222-222222222222',1,true)~=nil and timers[2]:find('uuid_kill 33333333-3333-4333-a333-333333333333',1,true)~=nil,'Both owned legs did not receive distinct hard limits.')
 else
  check(hungup,'An accounting or hard-limit failure left the destination connected.')
  check(not deleted,'An unsuccessful replacement removed the existing short safety timer.')
 end
 check(mode=='db-open-exception'or released,'The owned answer-hook database handle was not released.')
end
print(string.format('PASS: %d independent actual Lua answer-hook accounting, both-leg timer and fail-closed controls',checks))
