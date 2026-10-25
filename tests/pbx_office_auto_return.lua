local root=arg[1]or'.';local P=dofile(root..'/app/pbx_setup/resources/switch/scripts/app/pbx_setup/policy.lua');local checks=0
local function check(v,m)assert(v,m);checks=checks+1 end
local function fixture()
 local c={timezone='Africa/Johannesburg',default_hours={type='AllHours',periods={}},users={},departments={{number='COMPANY',timezone='Africa/Johannesburg',hours={type='SpecificHoursExcludingHolidays',periods={}},breaks={periods={}},holidays={},members={}}}}
 for day=1,5 do table.insert(c.departments[1].hours.periods,{day=day,start='07:00',['end']='16:30'})end
 table.insert(c.departments[1].hours.periods,{day=6,start='08:00',['end']='11:30'})
 for _,n in ipairs({'2001','2002','2003','2004'})do c.users[n]={profile='Out of office',auto_status='1',profiles={Available={name='Available',disable_ring_groups=false},['Out of office']={name='Out of office',disable_ring_groups=true},Away={name='Away',disable_ring_groups=true},['Do Not Disturb']={name='Do Not Disturb',disable_ring_groups=true},['Custom 1']={name='Custom 1',disable_ring_groups=false}}};table.insert(c.departments[1].members,{number=n,primary=true})end;return c
end
for _,case in ipairs({{0,'12:00',false},{1,'06:59',false},{1,'07:00',true},{1,'16:29',true},{1,'16:30',false},{6,'07:59',false},{6,'08:00',true},{6,'11:29',true},{6,'11:30',false}})do
 local c=fixture();for n in pairs(c.users)do local v=P.profile(c,n,function()return case[1],case[2],'2026-10-26'end);check((not v.disable_ring_groups)==case[3],'Company auto-status eligibility at boundary');check(c.users[n].profile=='Out of office','Evaluator mutated stored status')end
end
local function evaluate(c,skip)return P.profile(c,'2001',function()return 1,'07:00','2026-10-26'end,skip).name end
for _,status in ipairs({'Away','Custom 1','Do Not Disturb'})do local c=fixture();c.users['2001'].profile=status;check(evaluate(c)==status,'Personal status overridden while open')end
local c=fixture();c.users['2001'].auto_status='0';check(evaluate(c)=='Out of office','Automatic switching disabled ignored')
c=fixture();c.users['2001'].mobile_temporary={target='Out of office',previous='Available',expires=os.time()+60};check(evaluate(c)=='Out of office','Active temporary status overridden')
c.users['2001'].mobile_temporary.expires=os.time()-1;check(evaluate(c)=='Available','Expired temporary return failed')
c=fixture();c.users['2001'].profiles.Available=nil;check(evaluate(c)=='Out of office','Missing Available profile fabricated')
c=fixture();c.departments={};check(evaluate(c)=='Out of office','Unassigned/default-hours behavior expanded')
c=fixture();check(evaluate(c,true)=='Out of office','Explicit direct/internal schedule skip changed')
c=fixture();c.departments[1].office_override={state='closed',expires=os.time()+60};check(evaluate(c)=='Out of office','Closed company override ignored')
c=fixture();c.departments[1].breaks={type='SpecificHours',periods={{day=1,start='07:00',['end']='08:00'}}};check(evaluate(c)=='Away','Company break ignored')
c=fixture();c.departments[1].holidays={{date='2026-10-26'}};check(evaluate(c)=='Out of office','Company holiday ignored')
print('PASS '..checks..' office-auto-return Lua controls; no engine/database/network')
