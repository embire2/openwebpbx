-- Revoke one mobile phone without parsing its caller-controlled REGISTER Call-ID.
-- Invoked through the private call engine after the application revokes the device.
local id=argv and argv[1] or ''
local function result(value) if stream then stream:write(value) end end
if #id~=36 or not id:match('^[a-f0-9%-]+$') then result('-ERR Invalid phone');return end

local Database=require 'resources.functions.database'
local api=freeswitch.API()
local system,native
local ok=pcall(function()
    system=Database.new('system')
    local device
    system:query([[select m.sip_username,d.domain_name from v_pbx_mobile_devices m
        join v_domains d using(domain_uuid) where m.device_uuid=:id and m.revoked_at is not null]],
        {id=id},function(row) device=row end)
    -- A previously deleted device needs no further application cleanup.
    if not device then return end
    if #device.sip_username~=36 or not device.sip_username:match('^owm%-[a-f0-9]+$') then error('Invalid phone identity') end
    for _,profile in ipairs({'internal','internal-ipv6'}) do
        local status=api:execute('sofia','status profile '..profile)
        if status and status:find('SIP%-IP') then
            local dsn='sofia_reg_'..profile
            local odbc
            system:query([[select s.sip_profile_setting_name as name,s.sip_profile_setting_value as value
                from v_sip_profile_settings s join v_sip_profiles p using(sip_profile_uuid)
                where p.sip_profile_name=:profile and p.sip_profile_enabled='true'
                and s.sip_profile_setting_enabled='true'
                and s.sip_profile_setting_name in ('dbname','odbc-dsn')]],
                {profile=profile},function(row)
                    if row.name=='odbc-dsn' and row.value~='' then odbc=row.value
                    elseif row.name=='dbname' and row.value~='' then dsn=row.value end
                end)
            native=Database.new(freeswitch.Dbh(odbc or dsn))
            -- sofia_contact skips an empty contact immediately. Retain Call-ID,
            -- user and network fields so Sofia's normal expiry sweep can close
            -- the original connection and publish its normal expiry events.
            assert(native:query([[update sip_registrations set contact='',expires=1
                where sip_username=:username and sip_realm=:realm]],
                {username=device.sip_username,realm=device.domain_name}))
            native:release();native=nil
        end
    end
end)
if native then native:release() end
if system then system:release() end
result(ok and '+OK Phone connections removed' or '-ERR Phone connection cleanup failed')
