-- Passwordless voicemail uses a verified phone account, never a caller-supplied CLI.
local M={}
function M.principal(session,db)
    if not session or not session:ready() or session:getVariable('sip_authorized')~='true'
      or session:getVariable('openweb_provider_origin')=='true' then return nil end
    local auth=session:getVariable('sip_auth_username')
    local realm=session:getVariable('sip_auth_realm')
    local domain=session:getVariable('domain_uuid')
    if type(auth)~='string' or auth=='' or #auth>255 or type(realm)~='string' or not domain then return nil end
    local realms=require 'app.xml_handler.resources.scripts.directory.contact_realms'
    local owner=realms.owner(db,realm)
    if not owner or owner.domain_uuid~=domain then return nil end
    local rows={}
    db:query([[select e.extension_uuid::text,
        coalesce(u.key,nullif(e.number_alias,''),e.extension) as number
        from v_extensions e left join v_pbx_restore r using(domain_uuid)
        left join lateral jsonb_each(coalesce(r.config->'users','{}'::jsonb)) u
            on u.value->>'extension_uuid'=e.extension_uuid::text
        where e.domain_uuid=:domain and e.enabled='true'
        and (r.domain_uuid is null or (u.key is not null and r.config->>'realm'=:realm
            and u.value->>'auth_id'=e.extension and u.value->>'enabled'='true'))
        and (e.extension=:auth or exists(select 1 from v_pbx_mobile_devices m
            where m.extension_uuid=e.extension_uuid and m.domain_uuid=e.domain_uuid
            and m.sip_username=:auth and m.revoked_at is null and m.expires_at>now()))
        limit 2]],{domain=domain,auth=auth,realm=owner.domain_name},function(row) rows[#rows+1]=row end)
    if #rows~=1 or not rows[1].number or not rows[1].number:match('^%d+$') then return nil end
    return {domain_uuid=domain,domain_name=owner.domain_name,number=rows[1].number,extension_uuid=rows[1].extension_uuid}
end
function M.mailbox(session,db,requested)
    local p=M.principal(session,db)
    if not p or (requested and requested~='' and requested~=p.number) then return nil end
    local rows={}
    db:query([[select voicemail_uuid::text from v_voicemails
        where domain_uuid=:domain and voicemail_id=:number and voicemail_enabled=true limit 2]],
        {domain=p.domain_uuid,number=p.number},function(row) rows[#rows+1]=row end)
    if #rows~=1 then return nil end
    p.voicemail_uuid=rows[1].voicemail_uuid
    return p
end
return M
