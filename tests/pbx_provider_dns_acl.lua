-- Actual unchanged native ACL renderer and incoming policy; no engine/network.
local source=assert(io.open('app/switch/resources/scripts/app/xml_handler/resources/scripts/configuration/acl.conf.lua','rb')):read('*a')
source=source:gsub('\r\n','\n')
local body=assert(source:match('(local approved_sql = %[%[.-dbh:query%(approved_sql, function%(item%).-\n%s*end%))'))
local output={}
local env=setmetatable({xml={sanitize=function(v)return v end},dbh={}}, {__index=_G})
function env.xml:append(v)output[#output+1]=v end
function env.dbh:query(sql,callback)
 assert(sql:find('gateway.enabled=true',1,true) and sql:find('domain.domain_enabled=true',1,true) and sql:find('tenant.enabled=false',1,true))
 for _,ip in ipairs({'10.20.30.42','fd00::44','10.20.30.42/0','*','8.8.8.8"/>','300.2.3.4','fd00:::1'}) do callback({provider_ip=ip}) end
end
assert(load(body,'actual-provider-acl','t',env))()
assert(#output==2 and output[1]:find('cidr="10.20.30.42/32"',1,true) and output[2]:find('cidr="fd00::44/128"',1,true))
local P=dofile('app/pbx_setup/resources/switch/scripts/app/pbx_setup/policy.lua')
local trunk={allowed_ips={'10.20.30.42','fd00::44'},gateway_uuid='fictional-gateway',source_field='ToUserPart'}
local rule={enabled=true,condition='BasedOnDID',number='+27110000000'}
local fields={sip_to_user='+27110000000',sip_gateway='fictional-gateway'}
local function get(k)return fields[k] end
local checks=3
for _,ip in ipairs(trunk.allowed_ips) do assert(P.incoming({},rule,trunk,get,ip));checks=checks+1 end
for _,ip in ipairs({'10.20.30.41','fd00::45','10.20.30.42.attacker'}) do assert(not P.incoming({},rule,trunk,get,ip));checks=checks+1 end
fields.sip_gateway='foreign-gateway';assert(not P.incoming({},rule,trunk,get,'10.20.30.42'));checks=checks+1
fields.sip_gateway='fictional-gateway';fields.sip_to_user='+27119999999';assert(not P.incoming({},rule,trunk,get,'10.20.30.42'));checks=checks+1
rule.enabled=false;fields.sip_to_user='+27110000000';assert(not P.incoming({},rule,trunk,get,'10.20.30.42'));checks=checks+1
-- The native Windows software phones and fictional carrier share one NIC.
-- Render the actual source ACL for both isolated stages: the old shared-IP
-- fixture trusts ordinary phones too; the staged incoming override does not.
local peer='10.11.12.13'
for _,stage in ipairs({'outbound','incoming','outbound'}) do
 output={}
 local address=stage=='incoming' and peer or '198.51.100.254'
 function env.dbh:query(sql,callback)callback({provider_ip=address})end
 assert(load(body,'actual-staged-provider-acl','t',env))()
 assert(#output==1 and output[1]:find('cidr="'..address..'/32"',1,true));checks=checks+1
 assert((output[1]:find('cidr="'..peer..'/32"',1,true)~=nil)==(stage=='incoming'));checks=checks+1
 trunk.allowed_ips={address};rule.enabled=true;fields.sip_gateway='fictional-gateway';fields.sip_to_user='+27110000000'
 assert(P.incoming({},rule,trunk,get,peer)==(stage=='incoming'));checks=checks+1
end
print('PASS '..checks..' actual native ACL renderer and incoming provider/DID/tenant-binding controls')
