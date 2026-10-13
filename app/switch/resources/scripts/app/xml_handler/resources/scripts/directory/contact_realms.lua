-- Exact tenant-owned SIP realms; never infer ownership from a suffix or a caller header.
local M={}
local function realm(value)
    return type(value)=='string' and #value>0 and #value<=253 and value:match('^[a-z0-9][a-z0-9%.%-]*[a-z0-9]$')~=nil
end
local function alias_table(db)
    local found=false
    db:query("select to_regclass('v_pbx_sip_domains')::text as relation",{},function(row) found=row.relation=='v_pbx_sip_domains' or row.relation=='public.v_pbx_sip_domains' end)
    return found
end
function M.condition(db)
    if alias_table(db) then
        return [[(d.domain_name=:domain or exists(select 1 from v_pbx_sip_domains a where a.domain_uuid=d.domain_uuid and a.sip_domain=:domain and a.enabled))]]
    end
    return 'd.domain_name=:domain'
end
function M.owner(db, requested)
    if not realm(requested) then return nil end
    local rows={}
    db:query([[select d.domain_uuid::text,d.domain_name,d.domain_enabled::text,
        exists(select 1 from v_pbx_services s join v_pbx_tenants t using(tenant_uuid) where s.domain_uuid=d.domain_uuid and not t.enabled)::text as suspended
        from v_domains d where ]]..M.condition(db)..' limit 2',{domain=requested},function(row) rows[#rows+1]=row end)
    if #rows~=1 or rows[1].domain_enabled~='true' or rows[1].suspended=='true' then return nil end
    return rows[1]
end
function M.realms(db, domain_uuid, canonical)
    if not realm(canonical) then return {} end
    local owner=M.owner(db,canonical)
    if not owner or owner.domain_uuid~=domain_uuid or owner.domain_name~=canonical then return {} end
    local result={canonical};local seen={[canonical]=true}
    if alias_table(db) then
        db:query([[select a.sip_domain from v_pbx_sip_domains a where a.domain_uuid=:uuid and a.enabled
            and not exists(select 1 from v_domains foreign_domain where foreign_domain.domain_name=a.sip_domain and foreign_domain.domain_uuid<>a.domain_uuid)
            order by a.sip_domain limit 3]],{uuid=domain_uuid},function(row)
            if realm(row.sip_domain) and not seen[row.sip_domain] then result[#result+1]=row.sip_domain;seen[row.sip_domain]=true end
        end)
    end
    return result
end
return M
