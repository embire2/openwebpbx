-- OpenWeb PBX mobile credentials. Do not cache: removing a phone must revoke its password.
local Database=require 'resources.functions.database'
local db=Database.new('system')
local record
local ok=pcall(function()
    db:query([[select m.sip_username,m.sip_a1_hash,e.extension,e.extension_uuid,e.user_context,e.toll_allow,
        d.domain_name,d.domain_uuid,u.key as number,u.value->>'name' as name
        from v_pbx_mobile_devices m join v_extensions e on e.extension_uuid=m.extension_uuid and e.domain_uuid=m.domain_uuid
        join v_domains d on d.domain_uuid=m.domain_uuid join v_pbx_restore r on r.domain_uuid=m.domain_uuid,
        lateral jsonb_each(r.config->'users') u
        where m.sip_username=:user and d.domain_name=:domain and m.revoked_at is null and m.expires_at>now()
        and e.enabled='true' and d.domain_enabled='true' and u.value->>'extension_uuid'=e.extension_uuid::text
        and u.value->>'auth_id'=e.extension and u.value->>'enabled'='true' and r.config->>'realm'=d.domain_name
        and not exists(select 1 from v_pbx_services s join v_pbx_tenants t using(tenant_uuid) where s.domain_uuid=d.domain_uuid and not t.enabled)]],
        {user=user,domain=domain_name},function(r) record=r end)
end)
db:release()
local function esc(value) return tostring(value or ''):gsub('%$',''):gsub('&','&amp;'):gsub('<','&lt;'):gsub('>','&gt;'):gsub('"','&quot;'):gsub("'",'&apos;') end
XML_STRING='<document type="freeswitch/xml"><section name="result"><result status="not found"/></section></document>'
if not ok or not record then return end
local variables={domain_uuid=record.domain_uuid,domain_name=record.domain_name,user_context=record.domain_name,
    extension_uuid=record.extension_uuid,effective_caller_id_name=record.name,effective_caller_id_number=record.number,
    outbound_caller_id_name=record.name,outbound_caller_id_number=record.number,toll_allow=record.toll_allow or '',
    ['sip-force-user']=record.extension,['sip-allow-multiple-registrations']='true',
    rtp_secure_media='mandatory:AES_CM_128_HMAC_SHA1_80',rtp_secure_media_outbound='optional:AES_CM_128_HMAC_SHA1_80',
    openweb_mobile_device='true'}
local xml={'<document type="freeswitch/xml"><section name="directory"><domain name="'..esc(record.domain_name)..'"><groups><group name="default"><users><user id="'..esc(record.sip_username)..'" number-alias="'..esc(record.extension)..'"><params><param name="a1-hash" value="'..esc(record.sip_a1_hash)..'"/><param name="mwi-account" value="'..esc(record.number..'@'..record.domain_name)..'"/></params><variables>'}
for k,v in pairs(variables) do xml[#xml+1]='<variable name="'..esc(k)..'" value="'..esc(v)..'"/>' end
xml[#xml+1]='</variables></user></users></group></groups></domain></section></document>'
XML_STRING=table.concat(xml)
