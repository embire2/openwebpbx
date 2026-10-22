-- Read-only actual-engine policy evidence for disposable fictional providers.
require 'resources.functions.config'
local Database=require 'resources.functions.database';local json=require 'resources.functions.lunajson'
local domain,number=argv[1],argv[2]
if type(domain)~='string' or #domain~=36 or not domain:match('^[a-f0-9%-]+$') or not ({['99100']=true,['99101']=true,['99102']=true,['99103']=true})[number] then error('Owned provider fixture required') end
local db=Database.new('system');local config
db:query('select config from v_pbx_restore where domain_uuid=:d',{d=domain},function(row)config=json.decode(row.config)end)
if not config or not config.realm:match('^pbx%-[a-f0-9]+%.') or not config.users['8100'] then db:release();error('Owned fictional policy required') end
local P=loadfile(scripts_dir..'/app/pbx_setup/policy.lua')();local api=freeswitch.API();local rule=P.outbound(config,number,'8100');local result={}
if rule then for index,route in ipairs(rule.routes) do
 if index>2 then break end
 local t=config.trunks[tostring(route.trunk_id)];local native
 if t then db:query('select enabled,register,from_domain,from_user,username,proxy,outbound_proxy,register_transport,profile from v_gateways where domain_uuid=:d and gateway_uuid=:g',{d=domain,g=t.gateway_uuid},function(row)native=row end) end
 if not native or type(native.proxy)~='string' or not native.proxy:match('^127%.0%.0%.1:%d+$') then db:release();error('Only fictional loopback providers are observable') end
 local info=debug.getinfo(P.outbound_leg,'S').source;local parent=info:match('^@(.*/)');local file=parent and io.open(parent..'trunk_options.lua','rb');local readable=file~=nil;if file then file:close() end
 local function scalar(value)local kind=type(value);local text=tostring(value);return kind,(({['true']=true,['false']=true,['t']=true,['f']=true,['1']=true,['0']=true})[text] and text or 'other') end
 local enabled_kind,enabled_value=scalar(native.enabled);local register_kind,register_value=scalar(native.register)
 local leg=P.outbound_leg(t,route,number,config.users['8100'],'8100',domain,config.realm,native,config)
 result[#result+1]={enabled_kind=enabled_kind,enabled_value=enabled_value,register_kind=register_kind,register_value=register_value,available=P.gateway_available(native,api:execute('sofia','status gateway '..t.gateway_uuid))==true,rewrite_valid=P.rewrite(number,route)~=nil,leg_valid=type(leg)=='string',options_present=t.options~=nil,options_kind=type(t.options),options_schema_one=type(t.options)=='table' and t.options.schema==1,policy_source_forwardslash=parent~=nil,options_module_readable=readable}
end end
db:release();stream:write(json.encode(result))
