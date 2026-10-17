-- Instance service numbers are independent of imported customer call routes.
local args=...
if not session or not session:ready() then return end
local Database=require 'resources.functions.database'
local identity=require 'resources.functions.mailbox_identity'
local db=Database.new('system')
local mode=args and args[2]
local p=mode=='voicemail' and identity.mailbox(session,db) or identity.principal(session,db)
db:release()
if not p then session:hangup('CALL_REJECTED');return end
session:setVariable('domain_uuid',p.domain_uuid)
session:setVariable('domain_name',p.domain_name)
session:setVariable('effective_caller_id_number',p.number)
session:setVariable('openweb_scope_origin',p.number)
session:execute('clear_digit_action','all')
if mode=='voicemail' then
    session:setVariable('voicemail_id',p.number)
    session:setVariable('voicemail_action','check')
    session:execute('lua','app.lua voicemail')
elseif mode=='clock' then
    local clock=require 'app.pbx_services.clock'
    clock.run(session,freeswitch.API(),session:getVariable('sounds_dir') or sounds_dir)
else session:hangup('UNALLOCATED_NUMBER') end
