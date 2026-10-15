-- Actual queue_runtime API emission and scoped state preservation; no PBX.
local runtime=assert(loadfile('app/pbx_setup/resources/switch/scripts/app/pbx_setup/queue_runtime.lua'))()
local checks=0
local function check(value,message)assert(value,message);checks=checks+1 end
local function copy(value)
 if type(value)~='table' then return value end
 local result={};for key,item in pairs(value)do result[key]=copy(item)end;return result
end
local function equal(a,b)
 if type(a)~=type(b)then return false end
 if type(a)~='table'then return a==b end
 for key,value in pairs(a)do if not equal(value,b[key])then return false end end
 for key in pairs(b)do if a[key]==nil then return false end end;return true
end
local domain='00000000-0000-4000-a000-000000000009'
local first='eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'
local second='11111111-1111-4111-8111-111111111111'
local foreign='22222222-2222-4222-8222-222222222222'
local realm='fixture.example.invalid';local name='8190@'..realm
local config={realm=realm,users={['8101']={enabled=true,auth_id='auth8101'},['8102']={enabled=true,auth_id='auth8102'}}}
local queue={number='8190',wrap_up=2,members={{number='8101',agent_uuid=first},{number='8102',agent_uuid=second}}}
local function key(q,a)return q..'|'..a end
local function tier(agent,level,position,state,q)return {queue=q or name,agent=agent,level=tostring(level),position=tostring(position),state=state or 'Ready',custom='preserve'}end
local function fixture()
 local f={agents={},tiers={},calls={},columns={'position','state','queue','level','agent','custom'}}
 local api={}
 function api:execute(command,data)
  assert(command=='callcenter_config');f.calls[#f.calls+1]=data
  local words={};for word in data:gmatch('%S+')do words[#words+1]=word end
  if words[1]=='agent' and words[2]=='list'then
   local agent=f.agents[words[3]]
   return agent and ('name|state|status\n'..words[3]..'|'..agent.state..'|'..agent.status..'\n+OK\n') or '+OK\n'
  elseif words[1]=='agent' and words[2]=='add'then
   if f.concurrent then f.agents[words[3]]=copy(f.concurrent);return '-ERR Agent already exist!\n'end
   assert(not f.agents[words[3]]);f.agents[words[3]]={state='Waiting',status='Logged Out',type=words[4]};return '+OK\n'
  elseif words[1]=='agent' and words[2]=='set'then
   f.agents[words[4]][words[3]]=table.concat(words,' ',5);return '+OK\n'
  elseif words[1]=='tier' and words[2]=='add'then
   -- Grammar is independently checked against the actual native C parser.
   assert(#words==6 and words[5]:match('^%d+$') and words[6]:match('^%d+$'))
   local id=key(words[3],words[4]);if f.tiers[id]then return '-ERR Tier already exist!\n'end
   f.tiers[id]=tier(words[4],words[5],words[6],'Ready',words[3]);return '+OK\n'
  elseif words[1]=='queue' and words[2]=='list' and words[3]=='tiers'then
   assert(#words==4 and words[4]==name)
   if f.tier_text then return f.tier_text end
   local lines={table.concat(f.columns,'|')}
   -- Include foreign rows deliberately, to test exact queue/agent selection.
   for _,row in pairs(f.tiers)do
    local values={};for _,column in ipairs(f.columns)do values[#values+1]=row[column] or '' end
    lines[#lines+1]=table.concat(values,'|')
   end
   lines[#lines+1]='+OK'
   if f.after_list then local after=f.after_list;f.after_list=nil;after(f)end
   return table.concat(lines,'\n')..'\n'
  elseif words[1]=='tier' and words[2]=='set'then
   assert(#words==6 and (words[3]=='level' or words[3]=='position'))
   local row=assert(f.tiers[key(words[4],words[5])]);row[words[3]]=words[6];return '+OK\n'
  end
  error('Unexpected native mutation: '..data)
 end
 f.api=api;return f
end
local function ensure(f,q)return runtime.ensure(f.api,config,q or queue,domain,function(u)return 'user/'..u.auth_id..'@'..realm end)end
local function mutations(f,prefix)
 local result={};for _,value in ipairs(f.calls)do if value:sub(1,#prefix)==prefix then result[#result+1]=value end end;return result
end
local function emit(label,f)
 for _,value in ipairs(mutations(f,'tier add '))do print('EMIT|'..label..'|'..value)end
end
local f=fixture();local created=ensure(f)
check(created[first] and created[second],'Only actual agent additions are owned')
check(f.tiers[key(name,first)].level=='1' and f.tiers[key(name,first)].position=='1','First fresh tier has numeric level/position')
check(f.tiers[key(name,second)].level=='1' and f.tiers[key(name,second)].position=='2','Second fresh tier has a distinct declared position')
check(#mutations(f,'queue list ')==0 and #mutations(f,'tier set ')==0,'Fresh additions do not repair existing records')
emit('fresh',f)
for _,case in ipairs({{name='missing',level=1},{name='empty',skill='',level=1},{name='negative',skill='-4',level=1},{name='zero',skill='0',level=1},
 {name='two',skill='2',level=3},{name='upper',skill='9',level=10},{name='imported',skill='14',level=15},
 {name='decimal',skill='2.9',level=3},{name='negative_fraction',skill='-0.2',level=1},
 {name='negative_decimal',skill='-2.9',level=1},{name='small_fraction',skill='.2',level=1},
 {name='nonnumeric',skill='unassigned',level=1},{name='numeric_prefix',skill='2.9imported',level=3},
 {name='scientific',skill='1.e2 imported',level=101},{name='hex_text',skill='0x10',level=1}})do
 f=fixture();local q=copy(queue);q.members={q.members[1]};q.members[1].skill=case.skill
 ensure(f,q);check(f.tiers[key(name,first)].level==tostring(case.level),'Skill level '..case.name)
 emit('skill-'..case.name,f)
end
for _,skill in ipairs({'1e999','2147483647',math.huge,-math.huge,0/0})do
 f=fixture();q=copy(queue);q.members[2].skill=skill
 check(not pcall(ensure,f,q) and #f.calls==0,'Unsafe/unbounded skill is rejected before any native operation')
end
f=fixture()
f.agents[first]={state='In a queue call',status='Available',contact='private-first-contact',ready_time='123',last_bridge_end='456',calls_answered='19',talk_time='987',wrap_up_time='8'}
f.agents[second]={state='Receiving',status='On Break',contact='private-paused-contact',ready_time='234',last_bridge_end='567',calls_answered='23',talk_time='876',wrap_up_time='7'}
f.tiers[key(name,first)]=tier(first,0,1,'Active Inbound')
f.tiers[key(name,second)]=tier(second,0,1,'Offering')
local foreign_queue='8191@foreign.invalid'
f.tiers[key(foreign_queue,first)]=tier(first,0,1,'Standby',foreign_queue)
f.tiers[key(name,foreign)]=tier(foreign,0,1,'Ready')
local agents=copy(f.agents);local foreign_tiers={copy(f.tiers[key(foreign_queue,first)]),copy(f.tiers[key(name,foreign)])}
local q=copy(queue);q.members[2].skill='2';created=ensure(f,q)
check(not next(created) and equal(f.agents,agents),'Repair never resets active/paused agents, contacts or metrics')
check(f.tiers[key(name,first)].level=='1' and f.tiers[key(name,first)].position=='1','First owned malformed tier repaired')
check(f.tiers[key(name,second)].level=='3' and f.tiers[key(name,second)].position=='2','Second owned malformed tier matches skill and order')
check(f.tiers[key(name,first)].state=='Active Inbound' and f.tiers[key(name,second)].state=='Offering','Tier states preserved while calls are active')
check(equal(f.tiers[key(foreign_queue,first)],foreign_tiers[1]) and equal(f.tiers[key(name,foreign)],foreign_tiers[2]),'Foreign queue and foreign agent tiers preserved')
check(#mutations(f,'agent set ')==0 and #mutations(f,'agent add ')==0,'Existing agents are never initialized again')
check(#mutations(f,'queue list tiers ')==1 and #mutations(f,'tier set ')==3,'One bounded queue snapshot and only required numeric repairs')
for _,value in ipairs(mutations(f,'tier set '))do print('REPAIR|'..value)end
f.calls={};local repaired=copy(f.tiers);ensure(f,q)
check(equal(f.tiers,repaired) and #mutations(f,'tier set ')==0,'Repair is idempotent')
for _,values in ipairs({{1,1},{7,42},{0,2},{2,1}})do
 f=fixture();f.agents[first]=copy(agents[first]);f.agents[second]=copy(agents[second])
 f.tiers[key(name,first)]=tier(first,values[1],values[2],'Standby');f.tiers[key(name,second)]=tier(second,9,17,'No Answer')
 local before=copy(f.tiers);ensure(f)
 check(equal(f.tiers,before) and equal(f.agents,agents) and #mutations(f,'tier set ')==0,'Valid/custom/nonmatching tier preserved')
end
f=fixture();f.concurrent=copy(agents[first]);f.tiers[key(name,first)]=tier(first,8,32,'Active Inbound')
q=copy(queue);q.members={q.members[1]};local before=copy(f.tiers);created=ensure(f,q)
check(not next(created) and equal(f.agents[first],agents[first]),'Concurrent agent-add winner retains exact bytes')
check(equal(f.tiers,before) and #mutations(f,'agent set ')==0 and #mutations(f,'tier set ')==0,'Concurrent winner valid tier is preserved')
f=fixture();f.agents=copy(agents);f.tiers[key(name,first)]=tier(first,1,1)
f.after_list=function(state)state.tiers[key(name,second)]=tier(second,1,2,'Offering')end
created=ensure(f)
check(not next(created) and equal(f.agents,agents),'Tier creation after an earlier snapshot preserves both existing agents')
check(f.tiers[key(name,second)].position=='2' and f.tiers[key(name,second)].state=='Offering' and #mutations(f,'tier set ')==0 and #mutations(f,'queue list tiers ')==2,'A bounded cache-miss refresh sees the concurrent valid tier')
for _,text in ipairs({'queue|agent|position\n'..name..'|'..first..'|1\n+OK\n',
 'queue|agent|level|level|position\n'..name..'|'..first..'|0|0|1\n+OK\n',
 'queue|agent|level|position\n'..name..'|'..first..'|0\n+OK\n',
 'queue|agent|level|position\n'..name..'|'..first..'|0|1\n'..name..'|'..first..'|0|1\n+OK\n',
 string.rep('x',1048577),string.rep('+OK\n',4099)})do
 f=fixture();f.agents[first]=copy(agents[first]);f.tiers[key(name,first)]=tier(first,0,1);f.tier_text=text
 q=copy(queue);q.members={q.members[1]};local tiers=copy(f.tiers)
 check(not pcall(ensure,f,q) and equal(f.tiers,tiers) and #mutations(f,'tier set ')==0,'Malformed/oversized/duplicate tier snapshot fails before repair')
end
print('PASS '..checks..' actual Lua queue API/scoped repair/preservation controls; no PBX contacted')
