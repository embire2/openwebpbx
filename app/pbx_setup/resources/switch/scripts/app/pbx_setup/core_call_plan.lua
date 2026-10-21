-- A read-only route explanation for the authenticated first-call wizard.
require 'resources.functions.config'
local Database=require 'resources.functions.database';local json=require 'resources.functions.lunajson'
local P=loadfile(scripts_dir..'/app/pbx_setup/policy.lua')();local registered=loadfile(scripts_dir..'/app/pbx_setup/registered.lua')()
local domain,caller,number=argv[1],argv[2],argv[3]
if not domain or #domain~=36 or not domain:match('^[a-f0-9%-]+$') or not caller or not caller:match('^%d%d%d*$') or #caller>10 or not number or not number:match('^%+?%d+$') or #number>32 then stream:write('{"error":"Choose a phone and a valid outside number."}');return end
local db=Database.new('system');local api=freeswitch.API();local config
db:query([[select r.config from v_pbx_restore r join v_domains d using(domain_uuid) where r.domain_uuid=:d and d.domain_enabled='true'
  and not exists(select 1 from v_pbx_services s join v_pbx_tenants t using(tenant_uuid) where s.domain_uuid=r.domain_uuid and not t.enabled)]],{d=domain},function(r)config=json.decode(r.config)end)
local result={routes={}}
local function internal_number()
    if config.users[number] or P.emergency(config,number) then return true end
    for _,kind in ipairs({'queues','ring_groups','receptionists','scripts','specials'}) do if P.find(config[kind],number) then return true end end
    return false
end
local u=config and config.users[caller]
if not u or not u.enabled then result.error='Choose an enabled phone in your PBX.'
elseif internal_number() then result.error='Use a normal outside test number. Emergency tests need a provider-approved procedure.'
else
    result.registered=registered(db,api,P,domain,u,config.realm)~=nil
    local rule=P.outbound(config,number,caller)
    if not rule then result.error='No outgoing rule matches this phone and number. Open Outbound Rules.'
    else
        result.rule=rule.name
        for _,r in ipairs(rule.routes) do
            local t=config.trunks[tostring(r.trunk_id)];local native
            if t and t.gateway_uuid then db:query('select enabled,register,from_domain,from_user,username,proxy,outbound_proxy,register_transport,profile from v_gateways where domain_uuid=:d and gateway_uuid=:id',{d=domain,id=t.gateway_uuid},function(row)native=row end) end
            local usable=t and native and P.gateway_available(native,api:execute('sofia','status gateway '..t.gateway_uuid)) and P.outbound_leg(t,r,number,u,caller,domain,config.realm,native,config)~=nil or false
            result.routes[#result.routes+1]={id=tostring(r.trunk_id),name=t and t.name or 'Missing Provider',number=P.rewrite(number,r),available=usable}
            if usable and not result.provider then result.provider=tostring(r.trunk_id) end
        end
        if not result.provider then result.error='The providers for this number are off or unavailable. Review SIP Trunks before starting.' end
    end
end
db:release();stream:write(json.encode(result))
