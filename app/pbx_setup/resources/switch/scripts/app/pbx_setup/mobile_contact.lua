-- Ordinary, tenant-owned simultaneous mobile delivery. Provider credentials
-- remain in native gateways; no caller supplies a destination or provider.
local M={}
local function uuid(v)return type(v)=='string' and #v==36 and v:match('^[a-f0-9%-]+$')end
function M.enabled(user,profile)
    return user and user.enabled and profile and profile.ring_mobile==true and type(user.mobile)=='string'
      and #user.mobile<=32 and user.mobile:match('^%+?%d+$')~=nil
end
function M.available(db,api,P,domain,config,user,profile)
    if not M.enabled(user,profile) or P.emergency(config,user.mobile) then return false end
    local rule=P.outbound(config,user.mobile,tostring(user.number))
    if not rule then return false end
    for _,route in ipairs(rule.routes or {}) do
        local trunk=config.trunks[tostring(route.trunk_id)]
        if trunk and uuid(trunk.gateway_uuid) then
            local native
            db:query('select enabled,register,from_domain,from_user,username,proxy,outbound_proxy,register_transport,profile from v_gateways where gateway_uuid=:id and domain_uuid=:domain',
              {id=trunk.gateway_uuid,domain=domain},function(row)native=row end)
            if native and P.gateway_available(native,api:execute('sofia','status gateway '..trunk.gateway_uuid))
              and P.outbound_leg(trunk,route,user.mobile,user,tostring(user.number),domain,config.realm,native,config) then return true end
        end
    end
    return false
end
function M.dial(domain,realm,user,timeout,source,internal,answer)
    timeout=tonumber(timeout)
    if not uuid(domain) or not uuid(source) or type(realm)~='string' or not realm:match('^[a-z0-9.%-]+$')
      or type(user.auth_id)~='string' or #user.auth_id>128 or not user.auth_id:match('^[A-Za-z0-9_.!%-]+$')
      or not tostring(user.number):match('^%d%d%d*$') or not timeout or timeout<1 or timeout>600 or timeout%1~=0 then return nil end
    local vars='domain_uuid='..domain..',domain_name='..realm..',loopback_bowout=false,leg_timeout='..timeout..',originate_timeout='..timeout
      ..',presence_id='..user.auth_id..'@'..realm
      ..',openweb_mobile_source='..source..',openweb_mobile_timeout='..timeout..',openweb_call_internal='..tostring(internal==true)
    if answer then vars=vars..",api_on_answer='"..answer.."'" end
    return '['..vars..']loopback/app=lua:app.lua pbx_setup mobile '..user.number
end
return M
