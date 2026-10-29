-- Short-lived meeting credentials deliberately do not inherit extension calling permissions.
local Database=require 'resources.functions.database'
local db=Database.new('system');local record
local method=tostring(params:getHeader('sip_auth_method') or ''):upper()
local ok=pcall(function()
 if method~='INVITE' and method~='REGISTER' and method~='BYE' and method~='INFO' and method~='UPDATE' and method~='PRACK' then return end
 if params:getHeader('sip_from_user')~=user or params:getHeader('sip_from_host')~=domain_name then return end
 db:query([[select a.sip_username,a.sip_a1_hash,a.member_uuid::text,p.meeting_uuid::text,d.domain_uuid::text,d.domain_name
 from v_pbx_meeting_members a join v_pbx_meetings p using(meeting_uuid) join v_domains d using(domain_uuid)
 where a.sip_username=:user and d.domain_name=:domain and a.state='admitted' and p.ended_at is null
 and p.started_at is not null and now() between p.starts_at-interval '15 minutes' and p.ends_at
 and d.domain_enabled='true' and not exists(select 1 from v_pbx_services s join v_pbx_tenants t using(tenant_uuid) where s.domain_uuid=d.domain_uuid and not t.enabled)]],
 {user=user,domain=domain_name},function(row)record=row end)
 if record and not dofile(scripts_dir..'/app/pbx_onboarding/gate.lua').allowed(db,record.domain_uuid)then record=nil end
end);db:release()
XML_STRING='<document type="freeswitch/xml"><section name="result"><result status="not found"/></section></document>'
if not ok or not record then return end
local function esc(v)return tostring(v):gsub('&','&amp;'):gsub('<','&lt;'):gsub('>','&gt;'):gsub('"','&quot;'):gsub("'",'&apos;')end
local vars={user_context='openweb-meet-only',domain_uuid=record.domain_uuid,domain_name=record.domain_name,openweb_meeting_member=record.member_uuid,
 effective_caller_id_number='meeting',effective_caller_id_name='Meeting',toll_allow=''}
local xml={'<document type="freeswitch/xml"><section name="directory"><domain name="'..esc(record.domain_name)..'"><groups><group name="default"><users><user id="'..esc(record.sip_username)..'"><params><param name="a1-hash" value="'..esc(record.sip_a1_hash)..'"/></params><variables>'}
for k,v in pairs(vars) do xml[#xml+1]='<variable name="'..k..'" value="'..esc(v)..'"/>' end
xml[#xml+1]='</variables></user></users></group></groups></domain></section></document>';XML_STRING=table.concat(xml)
