-- Local authenticated Admin calls this helper; never execute a supplied command.
require 'resources.functions.config'
local Database=require 'resources.functions.database'
local json=require 'resources.functions.lunajson'
local api=freeswitch.API()
local domain,id,action,target=argv[1],argv[2],argv[3],argv[4]
local function uuid(v) return type(v)=='string' and #v==36 and v:match('^[a-f0-9%-]+$') end
if not uuid(domain) or not uuid(id) or api:execute('uuid_exists',id):gsub('%s+$','')~='true' or api:execute('uuid_getvar',id..' domain_uuid'):gsub('%s+$','')~=domain then stream:write('-ERR Call unavailable');return end
local db=Database.new('system')
local c
db:query([[select r.config from v_pbx_restore r join v_domains d using(domain_uuid) where r.domain_uuid=:d and d.domain_enabled='true'
  and not exists(select 1 from v_pbx_services s join v_pbx_tenants t using(tenant_uuid) where s.domain_uuid=r.domain_uuid and not t.enabled)]],{d=domain},function(r)c=json.decode(r.config)end)
db:release()
if not c or not c.realm:match('^[a-z0-9.%-]+$') then stream:write('-ERR PBX unavailable');return end
local result
if action=='hold' then result=api:execute('uuid_hold',id)
elseif action=='resume' then result=api:execute('uuid_hold','off '..id)
elseif action=='end' then result=api:execute('uuid_kill',id..' NORMAL_CLEARING')
elseif action=='transfer' or action=='pickup' then
    if not target or not target:match('^%d+$') or not c.users[target] or not c.users[target].enabled then stream:write('-ERR User unavailable');return end
    result=api:execute('uuid_transfer',id..' '..target..' XML '..c.realm)
elseif action=='park' then
    if not c.parking_enabled or not target or not target:match('^%d+$') or tonumber(target)<1 or tonumber(target)>20 then stream:write('-ERR Parking unavailable');return end
    -- Keep an external caller's authorization restricted to this parking action.
    api:execute('uuid_setvar',id..' openweb_park_authorized true')
    result=api:execute('uuid_transfer',id..' *70'..target..' XML '..c.realm)
else stream:write('-ERR Action unavailable');return end
stream:write(result or '-ERR Call unavailable')
