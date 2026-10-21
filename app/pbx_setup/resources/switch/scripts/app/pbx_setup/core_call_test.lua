-- Calls the administrator's chosen phone first; the outside leg starts after answer.
require 'resources.functions.config'
local Database=require 'resources.functions.database';local json=require 'resources.functions.lunajson'
local P=loadfile(scripts_dir..'/app/pbx_setup/policy.lua')();local registered=loadfile(scripts_dir..'/app/pbx_setup/registered.lua')()
local domain,trunk,owner,number,id=argv[1],argv[2],argv[3],argv[4],argv[5]
local function uuid(v)return type(v)=='string' and #v==36 and v:match('^[a-f0-9%-]+$')end
if not uuid(domain) or not uuid(id) or not trunk or not trunk:match('^[%w%-]+$') or #trunk>40 or not owner or not owner:match('^%d%d%d*$') or #owner>10 or not number or not number:match('^%+?%d+$') or #number>32 then return end
local db=Database.new('system');local api=freeswitch.API();local config;local claimed=false
db:query([[update v_pbx_core_audit set result='calling' where audit_uuid=:id and call_uuid=:id and domain_uuid=:d and target=:target and action='first_call_test' and result='starting'
  and created_at>now()-interval '2 minutes' returning audit_uuid]],{id=id,d=domain,target=owner..'/'..number},function()claimed=true end)
if not claimed then db:release();return end
db:query([[select r.config from v_pbx_restore r join v_domains d using(domain_uuid) where r.domain_uuid=:d and d.domain_enabled='true'
  and not exists(select 1 from v_pbx_services s join v_pbx_tenants t using(tenant_uuid) where s.domain_uuid=r.domain_uuid and not t.enabled)]],{d=domain},function(r)config=json.decode(r.config)end)
local call;local result='failed'
local ok=pcall(function()
    local u=config and config.users[owner];if not u or not u.enabled or config.users[number] or P.emergency(config,number) then return end
    for _,kind in ipairs({'queues','ring_groups','receptionists','scripts','specials'}) do if P.find(config[kind],number) then return end end
    local live_contact=registered(db,api,P,domain,u,config.realm);if not live_contact then return end
    local rule=P.outbound(config,number,owner);local selected
    if not rule then return end
    for _,r in ipairs(rule.routes) do local t=config.trunks[tostring(r.trunk_id)];local native
        if t then db:query('select enabled,register,from_domain,from_user,username,proxy,outbound_proxy,register_transport,profile from v_gateways where domain_uuid=:d and gateway_uuid=:id',{d=domain,id=t.gateway_uuid},function(row)native=row end) end
        if t and native and P.gateway_available(native,api:execute('sofia','status gateway '..t.gateway_uuid)) and P.outbound_leg(t,r,number,u,owner,domain,config.realm,native,config) then selected=tostring(r.trunk_id);break end
    end
    if tostring(rule.routes[1].trunk_id)~=trunk or not selected or selected~=trunk then return end
    local vars='origination_uuid='..id..',domain_uuid='..domain..',domain_name='..config.realm..',originate_timeout=30,call_timeout=30,absolute_timeout=180,ignore_early_media=true,rtp_secure_media=optional:AES_CM_128_HMAC_SHA1_80,origination_caller_id_name=First Call Test,origination_caller_id_number='..owner
    -- One fresh registered contact avoids assigning the same UUID to several devices.
    call=freeswitch.Session('{'..vars..',presence_id='..u.auth_id..'@'..config.realm..'}'..live_contact)
    if not call:ready() then result='phone_no_answer';return end
    call:setVariable('sip_auth_username',u.auth_id);call:setVariable('sip_auth_realm',config.realm);call:setVariable('effective_caller_id_number',owner);call:setVariable('destination_number',number)
    call:execute('playback','ivr/ivr-please_hold_while_party_contacted.wav')
    call:execute('lua','app.lua pbx_setup outbound all')
    result='finished'
end)
if call and call:ready() then call:hangup() end
db:query("update v_pbx_core_audit set result=:result where audit_uuid=:id and domain_uuid=:d and result='calling'",{result=ok and result or 'failed',id=id,d=domain});db:release()
