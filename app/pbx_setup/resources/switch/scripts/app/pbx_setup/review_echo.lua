-- The audio test belongs only to an explicitly assigned, enabled demo phone.
if not session or not session:ready() then return end
local domain=session:getVariable('domain_uuid') or ''
local realm=session:getVariable('sip_auth_realm') or ''
local auth=session:getVariable('sip_auth_username') or ''
if #domain~=36 or not domain:match('^[a-f0-9%-]+$') or not auth:match('^owm%-[a-f0-9]+$') or session:getVariable('openweb_provider_origin')=='true' then session:hangup('CALL_REJECTED');return end
local db=require('resources.functions.database').new('system')
local allowed=false
local ok=pcall(function()
 db:query([[select 1 as allowed from v_pbx_mobile_reviewers r
 join v_pbx_mobile_devices m on m.extension_uuid=r.extension_uuid and m.domain_uuid=r.domain_uuid
 join v_users u on u.user_uuid=r.user_uuid and u.domain_uuid=r.domain_uuid
 join v_extensions e on e.extension_uuid=r.extension_uuid and e.domain_uuid=r.domain_uuid
 join v_domains d on d.domain_uuid=r.domain_uuid
 join v_pbx_services s on s.domain_uuid=r.domain_uuid join v_pbx_tenants t using(tenant_uuid)
 where r.domain_uuid=:domain and d.domain_name=:realm and m.sip_username=:auth
 and r.echo_number=:number and r.enabled and u.user_enabled='true' and e.enabled='true'
 and d.domain_enabled='true' and t.enabled and m.revoked_at is null and m.expires_at>now()]],
 {domain=domain,realm=realm,auth=auth,number=session:getVariable('destination_number') or ''},function() allowed=true end)
end)
db:release()
if not ok or not allowed then session:hangup('CALL_REJECTED');return end
session:answer()
session:execute('sched_hangup','+120 NORMAL_CLEARING')
session:execute('echo')
