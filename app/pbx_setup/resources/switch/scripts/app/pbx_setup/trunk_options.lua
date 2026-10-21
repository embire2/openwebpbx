-- Per-provider policy. Missing options retain the established calling behaviour.
local M={}
local function uuid(value) return type(value)=='string' and value:match('^[a-fA-F0-9%-]+$') and #value==36 end
local function options(trunk)
    if type(trunk)~='table' or trunk.options==nil then return nil end
    local o=trunk.options
    if type(o)~='table' or o.schema~=1 or type(o.allow_incoming)~='boolean' or type(o.allow_outgoing)~='boolean'
      or type(o.support_reinvite)~='boolean'
      or (o.srtp_mode~='inherit' and o.srtp_mode~='disabled' and o.srtp_mode~='optional' and o.srtp_mode~='required')
      or type(o.scope_department)~='string' or #o.scope_department>40 or not o.scope_department:match('^[A-Za-z0-9_%-]*$')
      or not tonumber(trunk.limit) or tonumber(trunk.limit)<1 or tonumber(trunk.limit)>10000 or tonumber(trunk.limit)%1~=0 then return false end
    return o
end
function M.scoped(config,department,origin)
    if department=='' then return true end
    for _,d in ipairs((config or {}).departments or {}) do
        if tostring(d.number)==department then
            for _,member in ipairs(d.members or {}) do if tostring(member.number)==tostring(origin) then return true end end
            return false
        end
    end
    return false
end
function M.limit_data(domain,trunk)
    if not uuid(domain) or not uuid(trunk.gateway_uuid) then return nil end
    local maximum=tonumber(trunk.limit)
    if not maximum or maximum<1 or maximum>10000 or maximum%1~=0 then return nil end
    return 'hash openweb-trunk-'..domain..' '..trunk.gateway_uuid..' '..maximum..' !NORMAL_CIRCUIT_CONGESTION'
end
local function secure(mode)
    if mode=='disabled' then return 'forbidden' end
    if mode=='optional' then return 'optional:AES_CM_128_HMAC_SHA1_80' end
    if mode=='required' then return 'mandatory:AES_CM_128_HMAC_SHA1_80' end
end
function M.leg(domain,trunk,contact,config,origin)
    local o=options(trunk)
    if o==nil then return contact end
    if not o or not o.allow_outgoing or not M.scoped(config,o.scope_department,origin) or type(contact)~='string' or contact:sub(1,1)~='[' then return nil end
    local limit=M.limit_data(domain,trunk);if not limit then return nil end
    -- The actual B-leg owns its slot. The native hash state hook releases it on
    -- hangup, including refusal/cancel/failover, without holding an A-leg lease.
    local variables={'limit_ignore_transfer=true',"execute_on_originate_openweb_trunk_limit='limit "..limit.."'",
        'sip_ignore_reinvites='..tostring(not o.support_reinvite),
        'bypass_media=false','bypass_media_after_bridge=false','proxy_media=false'}
    local media=secure(o.srtp_mode);if media then variables[#variables+1]='rtp_secure_media_outbound='..media end
    local result=contact:gsub('^%[','['..table.concat(variables,',')..',',1)
    return result
end
function M.accept(session,domain,trunk)
    local o=options(trunk)
    if o==nil then return true end
    if not o or not o.allow_incoming then session:hangup('CALL_REJECTED');return false end
    local limit=M.limit_data(domain,trunk)
    if not limit then session:hangup('CALL_REJECTED');return false end
    local crypto=session:getVariable('rtp_has_crypto')
    local encrypted=type(crypto)=='string' and crypto~='' and crypto~='false' and crypto~='0'
    if (o.srtp_mode=='required' and not encrypted) or (o.srtp_mode=='disabled' and encrypted) then session:hangup('INCOMPATIBLE_DESTINATION');return false end
    session:setVariable('limit_ignore_transfer','true')
    session:execute('limit',limit)
    if not session:ready() then return false end
    session:setVariable('sip_ignore_reinvites',tostring(not o.support_reinvite))
    -- A configured provider policy never changes a phone's separate media leg.
    for _,name in ipairs({'bypass_media','bypass_media_after_bridge','proxy_media'}) do session:setVariable(name,'false') end
    return true
end
return M
