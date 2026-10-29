-- New installations accept calls only after verified tenant registration.
local M={}
local function yes(v)return v==true or v=='true' or v=='t' or v=='1' or v==1 end
local function uuid(v)return type(v)=='string' and #v==36 and v:match('^[0-9a-f%-]+$') end
local function marker()
    local windows=package.config:sub(1,1)=='\\'
    return windows and (os.getenv('ProgramData') or 'C:/ProgramData')..'/OpenWebPBX-Installation/onboarding-required'
        or '/etc/openwebpbx-installation/onboarding-required'
end
function M.required(db)
    local f,message,code=io.open(marker(),'rb')
    if f then f:close();return true end
    if code~=nil and code~=2 then return true end -- Only an absent marker is legacy.
    if type(message)=='string' and message:lower():find('permission',1,true) then return true end
    local installed=false
    db:query("select to_regclass('v_pbx_onboarding_policy') is not null as installed",function(r)installed=yes(r.installed)end)
    if not installed then return false end
    local required=true -- Missing/damaged fresh policy is never an activation.
    db:query('select required from v_pbx_onboarding_policy where singleton=true',function(r)required=yes(r.required)end)
    return required
end
local function instant(value)
    if type(value)~='string' or #value>40 then return nil end
    local y,m,d,h,n,s,tail=value:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(.*)$')
    if not y or not(tail=='Z' or tail=='+00:00' or tail:match('^%.%d+%+00:00$') or tail:match('^%.%d+Z$'))then return nil end
    y,m,d,h,n,s=tonumber(y),tonumber(m),tonumber(d),tonumber(h),tonumber(n),tonumber(s)
    local leap=y%4==0 and(y%100~=0 or y%400==0);local months={31,leap and 29 or 28,31,30,31,30,31,31,30,31,30,31}
    if y<1970 or m<1 or m>12 or d<1 or d>months[m] or h>23 or n>59 or s>59 then return nil end
    local days=365*(y-1970)+math.floor((y-1)/4)-math.floor(1969/4)-math.floor((y-1)/100)+math.floor(1969/100)+math.floor((y-1)/400)-math.floor(1969/400)+d-1
    for i=1,m-1 do days=days+months[i] end
    return days*86400+h*3600+n*60+s
end
M.instant=instant
function M.allowed(db,domain)
    local ok,allowed=pcall(function()
        if not M.required(db)then return true end
        if not uuid(domain)then return false end
        local row
        db:query([[select a.hostname,o.key_hash,o.server_host,encode(sha256(convert_to(o.activation::text,'UTF8')),'hex') grant_hash from v_pbx_onboarding o
            join v_pbx_onboarding_policy p on p.singleton=true and p.canonical_host=o.server_host and p.instance_key_hash=o.key_hash
            join v_pbx_services s on s.service_uuid=o.service_uuid and s.tenant_uuid=o.tenant_uuid and s.domain_uuid=o.domain_uuid
            join v_pbx_tenants t on t.tenant_uuid=o.tenant_uuid and t.owner_user_uuid=o.owner_user_uuid
            join v_users u on u.user_uuid=o.owner_user_uuid and u.user_enabled='true'
            join v_domains d on d.domain_uuid=o.domain_uuid and d.domain_enabled='true'
            join v_pbx_tenant_domains a on a.domain_uuid=o.domain_uuid and a.tenant_uuid=o.tenant_uuid and a.service_uuid=o.service_uuid
              and a.requested_label=o.requested_label and a.server_host=o.server_host and a.key_hash=o.key_hash
            where o.domain_uuid=:domain and o.state='ready' and o.activation is not null and o.grant_expires_at>now()
              and t.enabled=true and a.state='ready' and a.desired_enabled and a.certificate_not_after>now()]],{domain=domain},function(r)row=r end)
        if not row or type(row.hostname)~='string' or not row.hostname:match('^[a-z0-9][a-z0-9%-]+[a-z0-9]%.openwebpbx%.com$')then return false end
        local root=package.config:sub(1,1)=='\\' and (os.getenv('ProgramData')or'C:/ProgramData')..'/OpenWebPBX' or '/var/lib/openwebpbx'
        local file=io.open(root..'/tenant-domains/ready.json','rb');if not file then return false end
        local raw=file:read(65537);file:close();if not raw or #raw>65536 then return false end
        local data=require('resources.functions.lunajson').decode(raw)
        if type(data)~='table' or data.schema~=1 or data.server_host~=row.server_host or data.key_hash~=row.key_hash or type(data.aliases)~='table'then return false end
        local grant=type(data.authorizations)=='table' and data.authorizations[domain] or nil
        if type(grant)~='table' or type(row.grant_hash)~='string' or grant.grant_hash~=row.grant_hash then return false end
        local expiry=instant(grant.expires_at);if not expiry or expiry<=os.time() then return false end
        local until_time=instant(data.aliases[row.hostname]);return until_time~=nil and until_time>os.time()
    end)
    return ok and allowed==true
end
function M.context(db,context,domain)
    if uuid(domain)then return M.allowed(db,domain)end
    if context=='public'then return true end -- Individual target rows are checked before rendering.
    local found
    db:query('select domain_uuid from v_domains where domain_name=:name and domain_enabled=true',{name=tostring(context or ''):gsub('^ingress@','')},function(r)found=r.domain_uuid end)
    return M.allowed(db,found)
end
return M
