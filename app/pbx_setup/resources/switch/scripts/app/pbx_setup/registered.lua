-- Presence uses the same per-device identities that the native directory expands for dialing.
-- An active mobile registration counts only for this enabled extension and domain.
local realms=dofile(scripts_dir..'/app/xml_handler/resources/scripts/directory/contact_realms.lua')
return function(db,api,P,domain,user,realm)
    local contact
    local owned_realms=realms.realms(db,domain,realm)
    if #owned_realms==0 then return nil end
    for _,owned_realm in ipairs(owned_realms) do
        contact=P.contact(api:execute('sofia_contact',user.auth_id..'@'..owned_realm))
        if contact then return contact end
    end
    local accounts={}
    db:query([[select m.sip_username from v_pbx_mobile_devices m join v_extensions e using(extension_uuid)
      where m.domain_uuid=:domain and e.domain_uuid=:domain and e.enabled='true'
      and m.extension_uuid=:extension and m.revoked_at is null and m.expires_at>now() limit 10]],
      {domain=domain,extension=user.extension_uuid},function(row) accounts[#accounts+1]=row.sip_username end)
    for _,username in ipairs(accounts) do
        if #username==36 and username:match('^owm%-[a-f0-9]+$') then
            contact=P.contact(api:execute('sofia_contact',username..'@'..realm))
            if contact then return contact end
        end
    end
end
