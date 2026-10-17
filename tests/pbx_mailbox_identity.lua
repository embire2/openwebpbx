package.path='app/switch/resources/scripts/?.lua;'..package.path
local M=require 'resources.functions.mailbox_identity'
local count=0
local function check(v) assert(v);count=count+1 end
local realm={domain_uuid='tenant-a',domain_name='tenant-a.invalid'}
package.loaded['app.xml_handler.resources.scripts.directory.contact_realms']={owner=function(_,name)
    if name=='tenant-a.invalid' or name=='phones.tenant-a.invalid' then return realm end
    if name=='tenant-b.invalid' then return {domain_uuid='tenant-b',domain_name=name} end
end}
local vars={sip_authorized='true',sip_auth_username='separate-auth-id',sip_auth_realm='tenant-a.invalid',domain_uuid='tenant-a',caller_id_number='9999'}
local session={ready=function()return true end,getVariable=function(_,name)return vars[name]end}
local extension=true;local mailbox=true
local db={query=function(_,sql,p,callback)
    check(p.domain=='tenant-a')
    if sql:find('from v_extensions',1,true) then
        check(p.auth==vars.sip_auth_username and sql:find("e.enabled='true'",1,true) and sql:find('m.revoked_at is null',1,true) and sql:find('m.expires_at>now()',1,true))
        if extension then callback({extension_uuid='extension-a',number='1000'}) end
    else
        check(p.number=='1000' and sql:find('voicemail_enabled=true',1,true))
        if mailbox then callback({voicemail_uuid='mailbox-a'}) end
    end
end}
check(M.mailbox(session,db).number=='1000') -- presented CLI9999 cannot select its mailbox
check(M.mailbox(session,db,'9999')==nil)
check(M.mailbox(session,db,'1000').voicemail_uuid=='mailbox-a')
for _,name in ipairs({'sip_authorized','sip_auth_username','sip_auth_realm','domain_uuid'}) do
    local old=vars[name];vars[name]=nil;check(M.mailbox(session,db)==nil);vars[name]=old
end
vars.sip_authorized='false';check(M.mailbox(session,db)==nil);vars.sip_authorized='true'
vars.openweb_provider_origin='true';check(M.mailbox(session,db)==nil);vars.openweb_provider_origin=nil
vars.sip_auth_realm='tenant-b.invalid';check(M.mailbox(session,db)==nil)
vars.sip_auth_realm='invented.invalid';check(M.mailbox(session,db)==nil)
vars.sip_auth_realm='phones.tenant-a.invalid';check(M.mailbox(session,db).number=='1000')
extension=false;check(M.mailbox(session,db)==nil);extension=true
mailbox=false;check(M.mailbox(session,db)==nil);check(M.principal(session,db).number=='1000');mailbox=true
vars.sip_auth_username='owm-fictional-device';check(M.mailbox(session,db).number=='1000')
print('PASS '..count..' authenticated mailbox identity controls')
