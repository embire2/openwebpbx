-- Called only after normal provider/IP/DID ownership checks have succeeded.
local C={}
function C.run(session,db,config,rule)
 local P=loadfile(scripts_dir..'/app/pbx_setup/cmb_policy.lua')()
 local service
 db:query("select service_uuid from v_pbx_cmb_services where domain_uuid=:d and incoming_rule_uuid=:r and enabled and prompt_state='ready'",{d=session:getVariable('domain_uuid'),r=rule.rule_id},function(row)service=row end)
 if not service then return false end
 if not P.prompts_ready(sounds_dir) then session:hangup('NORMAL_TEMPORARY_FAILURE');return true end
 local privacy=(session:getVariable('sip_h_Privacy') or ''):lower()
 local hidden=session:getVariable('privacy_hide_number')=='true' or session:getVariable('caller_privacy_hide_number')=='true' or privacy:match('%f[%a]id%f[%A]')
 local caller=not hidden and P.cli(session:getVariable('caller_id_number')) or nil
 local function sound(name)return sounds_dir..'/openwebpbx/voices/1.0.2/call-me-back/'..name..'.wav'end
 local request
 if caller then db:query('select * from openweb_cmb_enqueue(:d,:s,:inbound,:cli)',{d=session:getVariable('domain_uuid'),s=service.service_uuid,inbound=session:getVariable('uuid'),cli=caller},function(row)request=row end) end
 if not request then session:answer();session:streamFile(sound('unavailable'));session:hangup('CALL_REJECTED');return true end
 -- No callback is eligible until the original call has ended, including callers
 -- who hang up during this announcement. A crash before release expires safely.
 session:answer();session:streamFile(sound((request.known=='t' or request.known=='true') and 'incoming-known' or 'incoming-new'))
 if session:ready() then session:hangup('NORMAL_CLEARING') end
 db:query("update v_pbx_cmb_requests set state='queued',updated_at=now() where request_uuid=:id and state='announcing'",{id=request.request_uuid})
 return true
end
return C
