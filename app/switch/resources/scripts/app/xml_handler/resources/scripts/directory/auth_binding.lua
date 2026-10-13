-- Authentication identities are bound before directory caching or number-alias lookup.
local M = {}
local domains=dofile(scripts_dir and scripts_dir..'/app/xml_handler/resources/scripts/directory/contact_realms.lua' or 'app/switch/resources/scripts/app/xml_handler/resources/scripts/directory/contact_realms.lua')
M.POLICY = 'same-tenant-auth-pair-before-cache-v1'
local methods = {REGISTER=true, INVITE=true, SUBSCRIBE=true, NOTIFY=true, MESSAGE=true, OPTIONS=true, REFER=true, UPDATE=true, INFO=true, BYE=true, PRACK=true}
local function identifier(value)
    return type(value)=='string' and #value>0 and #value<=128 and value:match('^[%w_.!%-]+$')~=nil
end
function M.allowed(rows, request)
    if #rows~=1 or not identifier(request.user) or not identifier(request.from_user) or not methods[request.method] then return nil end
    local row=rows[1]
    local requested=type(row.requested_domain)=='string' and #row.requested_domain>0 and row.requested_domain or row.domain_name
    if row.auth_user~=request.user or requested~=request.domain or request.from_domain~=requested or row.user_enabled~='true' or row.domain_enabled~='true' or row.suspended=='true' then return nil end
    local sip_user=row.auth_user
    row.restored=type(row.restore_number)=='string' and #row.restore_number>0
    if row.restored then
        if row.restore_realm~=row.domain_name or row.restore_enabled~='true' or row.restore_auth~=row.auth_user or row.restore_uuid~=row.extension_uuid then return nil end
        sip_user=type(row.contact_user)=='string' and #row.contact_user>0 and row.contact_user or row.restore_number
    elseif request.alias_enabled and row.number_alias and #row.number_alias>0 and row.alias_collision~='true' then
        sip_user=row.number_alias
    end
    if not identifier(sip_user) then return nil end
    local canonical_allowed = not row.restored or row.canonical_collision=='false'
    if request.from_user~=sip_user and not (canonical_allowed and request.from_user==row.auth_user) then return nil end
    if request.method=='REGISTER' and (request.to_user~=request.from_user or request.to_domain and request.to_domain~=requested) then return nil end
    row.sip_user=request.from_user
    return row
end
function M.lookup(db, request)
    local rows={}
    db:query([[select :domain as requested_domain,e.extension as auth_user,e.extension_uuid::text,e.number_alias,d.domain_name,d.domain_uuid::text,
        e.enabled::text as user_enabled,d.domain_enabled::text as domain_enabled,
        exists(select 1 from v_pbx_services s join v_pbx_tenants t using(tenant_uuid) where s.domain_uuid=d.domain_uuid and not t.enabled)::text as suspended,
        exists(select 1 from v_extensions other where other.domain_uuid=d.domain_uuid and (other.extension=e.number_alias or other.number_alias=e.number_alias) and other.extension_uuid<>e.extension_uuid)::text as alias_collision,
        exists(select 1 from jsonb_each(coalesce(r.config->'users','{}'::jsonb)) other where other.key=e.extension and other.value->>'extension_uuid'<>e.extension_uuid::text)::text as canonical_collision,
        r.config->>'realm' as restore_realm,u.key as restore_number,u.value->>'enabled' as restore_enabled,
        u.value->>'auth_id' as restore_auth,u.value->>'extension_uuid' as restore_uuid,u.value->>'contact_user' as contact_user
        from v_extensions e join v_domains d using(domain_uuid)
        left join v_pbx_restore r using(domain_uuid)
        left join lateral jsonb_each(coalesce(r.config->'users','{}'::jsonb)) u on u.value->>'extension_uuid'=e.extension_uuid::text
        where e.extension=:user and ]]..domains.condition(db)..' limit 2',
        {user=request.user,domain=request.domain},function(row) rows[#rows+1]=row end)
    return M.allowed(rows,request)
end
return M
