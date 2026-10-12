-- Queue delivery wakes only the selected agent, never every queue member.
local C={}
local function uuid(v)return type(v)=='string' and #v==36 and v:match('^[a-f0-9%-]+$')end
function C.push(db,domain,user)
    if not user or not user.enabled or not uuid(user.extension_uuid) then return false end
    local configured=false
    db:query([[select 1 as ok from v_pbx_mobile_devices m join v_pbx_mobile_push_config c on c.singleton and c.enabled
      where c.project_id='webpush' and m.domain_uuid=:domain and m.extension_uuid=:extension
      and m.push_project=c.project_id and m.push_token is not null and m.revoked_at is null and m.expires_at>now() limit 1]],
      {domain=domain,extension=user.extension_uuid},function()configured=true end)
    return configured
end
function C.dial(domain,realm,user,queue,source,job,internal)
    local timeout=tonumber(queue.ring_timeout)
    if not uuid(domain) or not realm:match('^[a-z0-9.%-]+$') or not tostring(user.number):match('^%d%d%d*$')
      or not tostring(queue.number):match('^%d%d%d*$') or not timeout or timeout<1 or timeout>600 or timeout%1~=0
      or (job and not uuid(job)) or (not job and source~='${uuid}' and not uuid(source)) then return nil end
    local origin=internal=='${openweb_call_internal}' and internal or tostring(internal==true)
    local vars='domain_uuid='..domain..',domain_name='..realm..',loopback_bowout=false,loopback_no_pre_answer=true,originate_timeout='..(timeout+6)..',openweb_agent_number='..user.number..',openweb_queue_number='..queue.number..',openweb_call_internal='..origin
    if job then vars=vars..',openweb_callback_job='..job else vars=vars..',openweb_queue_source='..source end
    return '['..vars..']loopback/app=lua:app/pbx_setup/core_agent.lua'
end
return C
