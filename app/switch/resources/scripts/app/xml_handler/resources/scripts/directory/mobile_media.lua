-- Add secure video renegotiation only to this extension's active native-app contacts.
-- Ordinary desk phones, custom dial strings and provider legs retain their policy.
local M={}
local function mobile(user)return type(user)=='string' and #user==36 and user:match('^owm%-[a-f0-9]+$')~=nil end
local active_sql=[[select m.sip_username,d.domain_uuid::text,e.extension_uuid::text,d.domain_name
 from v_pbx_mobile_devices m join v_extensions e on e.extension_uuid=m.extension_uuid and e.domain_uuid=m.domain_uuid
 join v_domains d on d.domain_uuid=m.domain_uuid join v_pbx_restore r on r.domain_uuid=m.domain_uuid,
 lateral jsonb_each(r.config->'users') u
 where m.domain_uuid=:domain and m.revoked_at is null and m.expires_at>now()
 and e.enabled='true' and d.domain_enabled='true' and r.config->>'realm'=d.domain_name
 and u.value->>'extension_uuid'=e.extension_uuid::text and u.value->>'auth_id'=e.extension and u.value->>'enabled'='true'
 and not exists(select 1 from v_pbx_services s join v_pbx_tenants t using(tenant_uuid) where s.domain_uuid=d.domain_uuid and not t.enabled)]]
function M.accounts(db,domain,extension)
 local allowed,counts={},{}
 db:query(active_sql..' and m.extension_uuid=:extension',{domain=domain,extension=extension},function(row)
  if mobile(row.sip_username)then
   counts[row.sip_username]=(counts[row.sip_username] or 0)+1
   allowed[row.sip_username]=counts[row.sip_username]==1 and {domain_uuid=domain,extension_uuid=extension,domain_name=row.domain_name} or nil
  end
 end)
 return allowed
end
function M.active(db,domain,extension,user,realm)
 if not mobile(user)then return false end
 local rows=0
 db:query(active_sql..' and m.extension_uuid=:extension and m.sip_username=:user and d.domain_name=:realm',
  {domain=domain,extension=extension,user=user,realm=realm},function()rows=rows+1 end)
 return rows==1
end
function M.identity(db,domain,user,realm)
 if not mobile(user)then return nil end
 local rows,record=0,nil
 db:query(active_sql..' and m.sip_username=:user and d.domain_name=:realm',
  {domain=domain,user=user,realm=realm},function(row)rows=rows+1;record=row end)
 return rows==1 and record or nil
end
function M.present(contact,allowed)
 if type(contact)~='string' then return false end
 for user in contact:gmatch('/sips?:([^@]+)@')do if mobile(user)and allowed[user]then return true end end
 return false
end
function M.suffix(allowed,user,realm,canonical)
 local owner=allowed[user]
 if realm~=canonical or not mobile(user)or type(owner)~='table' or owner.domain_name~=canonical then return '' end
 -- Optional SRTP emits duplicate secure/plain m-lines. After a stream upgrade
 -- FreeSWITCH can emit a duplicate video m-line without crypto. Native clients
 -- already require SRTP; offer only the encrypted stream to these contacts.
 -- The winner-only hook, rather than authentication or each ringing fork,
 -- enables forwarding after verifying both endpoints. Metadata is generated
 -- here from the exact owned extension, never from a caller's SIP headers.
 return ',rtp_secure_media=mandatory,rtp_secure_media_outbound=mandatory,rtp_secure_media_suites=AES_CM_128_HMAC_SHA1_80'..
  ',openweb_video_device='..user..',openweb_video_domain='..owner.domain_uuid..',openweb_video_extension='..owner.extension_uuid..
  ",execute_on_post_originate_openweb_video='lua app/pbx_services/mobile_video.lua'"
end
return M
