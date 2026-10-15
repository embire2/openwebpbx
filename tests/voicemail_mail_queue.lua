-- Actual queue/settings/SQL binding regression. No installed config or engine.
-- The terminal backend records SQL for the isolated PostgreSQL caller.
local root=arg[1] or '.'
package.path=root..'/app/switch/resources/scripts/?.lua;'..package.path
package.preload['resources.functions.config']=function()database={backend='fixture'};return true end
package.preload['resources.functions.cache']=function()return{settings=true}end
local statements,errors,defaults={},{},{}
package.preload['resources.functions.database.fixture']=function()
  local Backend={};Backend.__index=Backend
  function Backend.new()return setmetatable({},Backend)end
  function Backend:query(sql,callback)
    if sql:lower():match('^insert into')then statements[#statements+1]=sql end
    if callback and sql:find('FROM v_default_settings',1,true)then
      for subcategory,value in pairs(defaults)do
        if sql:find("default_setting_subcategory = '"..subcategory.."'",1,true)then
          callback({default_setting_category='email',default_setting_subcategory=subcategory,default_setting_name='text',default_setting_value=value})
        end
      end
    end
    return true
  end
  return Backend
end
local sequence=0
freeswitch={
  consoleLog=function(level,message)if level=='err'then errors[#errors+1]=message end end,
  API=function()return{
    execute=function(_,command,value)assert(command=='sql_escape');return value:gsub("'","''")end,
    executeString=function(_,command)
      if command=='hostname'then return'fictional-queue-host'end
      assert(command=='create_uuid');sequence=sequence+1;return string.format('00000000-0000-4000-8000-%012d',sequence)
    end
  }end
}
debug={sql=false};domain_name='fictional.invalid';domain_uuid='00000000-0000-4000-8000-000000000100'
local Database=require'resources.functions.database';dbh=Database.new('system')
local send_mail=require'resources.functions.send_mail'
local json=require'resources.functions.lunajson'
local headers={['X-FusionPBX-Domain-UUID']=domain_uuid,['X-FusionPBX-Domain-Name']=domain_name,['X-FusionPBX-Call-UUID']='00000000-0000-4000-8000-000000000101'}
local attachment='C:/ProgramData/OpenWebPBX/storage/voicemail/default/fictional.invalid/8103/msg_00000000-0000-4000-8000-000000000101.wav'
local cases={
  {name='unconfigured',expected='',attachment=true},
  {name='empty-setting',sender='',defaults={smtp_from='',smtp_from_name='OpenWeb PBX'},expected='',attachment=true},
  {name='configured-default',defaults={smtp_from='pbx@example.invalid'},expected='pbx@example.invalid',attachment=true},
  {name='configured-name',defaults={smtp_from='pbx@example.invalid',smtp_from_name='Fictional PBX'},expected='Fictional PBX<pbx@example.invalid>',attachment=true},
  {name='supplied',sender='Tenant Sender <tenant@example.invalid>',defaults={smtp_from='pbx@example.invalid',smtp_from_name='Fictional PBX'},expected='Tenant Sender <tenant@example.invalid>',attachment=true},
  {name='named-default-again',defaults={smtp_from='second@example.invalid',smtp_from_name='Second PBX'},expected='Second PBX<second@example.invalid>',attachment=true},
  {name='unconfigured-after-named',expected='',attachment=true},
  {name='reference-only',expected='',attachment=false},
}
local results={}
for _,case in ipairs(cases)do
  statements={};errors={};defaults=case.defaults or{}
  send_mail(headers,case.sender,'sink@example.invalid',{'Fictional voicemail','Fictional body'},case.attachment and attachment or nil)
  assert(#errors==0,'Actual parameter binding rejected '..case.name)
  assert(#statements==(case.attachment and 2 or 1),'Missing queue/attachment SQL for '..case.name)
  assert(statements[1]:find('insert into v_email_queue (',1,true),'Queue must precede attachment')
  assert(statements[1]:find("'"..case.expected.."'",1,true),'Expected sender absent for '..case.name)
  if case.attachment then
    assert(statements[2]:find("'C:/ProgramData/OpenWebPBX/storage/voicemail/default/fictional.invalid/8103'",1,true),'Drive-letter attachment folder changed')
    assert(statements[2]:find("'msg_00000000-0000-4000-8000-000000000101.wav'",1,true),'Attachment basename changed')
  end
  results[#results+1]={name=case.name,expected_sender=case.expected,attachment=case.attachment,sql=statements}
end
print(json.encode({cases=results,passed=true}))
