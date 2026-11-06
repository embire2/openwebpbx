-- Package capacity belongs to the caller channel, not to each ringing B-leg.
-- Native mod_limit performs the atomic admission and releases on hangup.
local M={}
function M.origin(db,domain)
    if type(domain)~='string' or #domain~=36 or not domain:match('^[a-f0-9%-]+$') then return nil end
    local rule
    db:query('select concurrent_calls+extra_calls as maximum,restore_hold from v_pbx_service_entitlements where domain_uuid=:domain',{domain=domain},function(r)rule=r end)
    if not rule then return '' end
    if rule.restore_hold==true or rule.restore_hold=='t' or rule.restore_hold=='true' then return nil end
    local maximum=tonumber(rule.maximum)
    if not maximum or maximum%1~=0 or maximum<1 or maximum>20000 then return nil end
    return "limit_ignore_transfer=true,execute_on_originate_openweb_capacity='limit hash openweb-pbx-"..domain.." calls "..maximum.." !NORMAL_CIRCUIT_CONGESTION',"
end
function M.admit(session,db,domain)
    if type(domain)~='string' or #domain~=36 or not domain:match('^[a-f0-9%-]+$') then session:hangup('CALL_REJECTED');return false end
    local rule
    db:query('select concurrent_calls+extra_calls as maximum,restore_hold from v_pbx_service_entitlements where domain_uuid=:domain',{domain=domain},function(r)rule=r end)
    if not rule then return true end -- Preserves existing, unassigned installations.
    if rule.restore_hold==true or rule.restore_hold=='t' or rule.restore_hold=='true' then session:hangup('NORMAL_TEMPORARY_FAILURE');return false end
    -- Transfers on this channel retain the native lease. Never export the marker
    -- to another leg: an independently dialled caller needs its own admission.
    if session:getVariable('openweb_capacity_domain')==domain then return true end
    local maximum=tonumber(rule.maximum)
    if not maximum or maximum%1~=0 or maximum<1 or maximum>20000 then session:hangup('CALL_REJECTED');return false end
    session:setVariable('limit_ignore_transfer','true')
    session:execute('limit','hash openweb-pbx-'..domain..' calls '..maximum..' !NORMAL_CIRCUIT_CONGESTION')
    if not session:ready() then return false end
    session:setVariable('openweb_capacity_domain',domain)
    return true
end
return M
