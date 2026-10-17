-- One bounded callback per durable request. Only the engine/worker invokes this.
require 'resources.functions.config'
local Database=require 'resources.functions.database';local json=require 'resources.functions.lunajson'
local P=loadfile(scripts_dir..'/app/pbx_setup/policy.lua')()
local C=loadfile(scripts_dir..'/app/pbx_setup/cmb_policy.lua')()
local Crypto=loadfile(scripts_dir..'/app/pbx_setup/cmb_crypto.lua')()
local id=argv and argv[1];if not C.uuid(id) then return end
local db=Database.new('system');local api=freeswitch.API();local request,config,call,service,destination_call
local function query(sql,values,fn)return db:query(sql,values,fn)end
local function sound(name)return sounds_dir..'/openwebpbx/voices/1.0.1/call-me-back/'..name..'.wav'end
local function finish(result,seconds)
 if seconds~=nil then query('select openweb_cmb_finish(:id,:seconds,:result)',{id=id,seconds=seconds,result=result})
 else query([[select openweb_cmb_finish(request_uuid,case when connected_at is null then 0 else least(reserved_seconds,greatest(0,ceil(extract(epoch from(now()-connected_at))))::integer) end,:result) from v_pbx_cmb_requests where request_uuid=:id]],{id=id,result=result}) end
end
local function active()
 local yes=false
 query([[select 1 from v_pbx_cmb_requests r join v_pbx_cmb_services s using(domain_uuid,service_uuid)
 where r.request_uuid=:id and r.state in ('starting','authenticating','dialling','connected') and s.enabled
 and (r.account_uuid is null or exists(select 1 from v_pbx_cmb_accounts a where a.domain_uuid=r.domain_uuid and a.account_uuid=r.account_uuid and a.enabled))]],{id=id},function()yes=true end)
 return yes
end
local function contact(number,route,owner)
 local trunk=config.trunks[tostring(route.trunk_id)];if not trunk then return end
 local native
 query('select enabled,register,from_domain,from_user,username,proxy,outbound_proxy,register_transport,profile from v_gateways where domain_uuid=:d and gateway_uuid=:id',{d=request.domain_uuid,id=trunk.gateway_uuid},function(row)native=row end)
 if not native or not P.gateway_available(native,api:execute('sofia','status gateway '..trunk.gateway_uuid)) then return end
 return P.outbound_leg(trunk,route,number,owner,tostring(service.route_owner),request.domain_uuid,config.realm,native)
end
local function allowed(number)
 local rule,owner=C.number(config,service,number,P)
 if rule then return rule,owner,number end
 local canonical=C.cli(number)
 if canonical then local national='0'..canonical:sub(4);rule,owner=C.number(config,service,national,P);if rule then return rule,owner,national end end
end
local function play(name)if call and call:ready() then call:streamFile(sound(name)) end end
local function deliver()
 query([[update v_pbx_cmb_requests set state='authenticating',lease_until=now()+interval '3 minutes',updated_at=now()
 where request_uuid=:id and state='starting' and created_at>now()-interval '2 minutes' returning *]],{id=id},function(r)request=r end)
 if not request or not C.uuid(request.call_uuid) then return end
 query([[select r.config,s.* from v_pbx_restore r join v_pbx_cmb_services s using(domain_uuid) join v_domains d using(domain_uuid)
 where s.domain_uuid=:d and s.service_uuid=:s and s.enabled and s.prompt_state='ready' and d.domain_enabled='true'
 and not exists(select 1 from v_pbx_services p join v_pbx_tenants t using(tenant_uuid) where p.domain_uuid=s.domain_uuid and not t.enabled)]],{d=request.domain_uuid,s=request.service_uuid},function(r)service=r;config=json.decode(r.config)end)
 if not service or not config or not C.cli(request.caller_number) then finish('service_unavailable');return end
 -- PostgreSQL arrays are decoded through a JSON projection rather than split.
 query('select array_to_json(destination_prefixes) as prefixes from v_pbx_cmb_services where service_uuid=:s',{s=request.service_uuid},function(r)service.destination_prefixes=json.decode(r.prefixes)end)
 local realms=loadfile(scripts_dir..'/app/xml_handler/resources/scripts/directory/contact_realms.lua')()
 if not P.realm_config(config,realms.realms(db,request.domain_uuid,config.realm)) then finish('domain_unavailable');return end
 local filename=(config_file or ''):gsub('\\','/'):match('^(.*)/[^/]+$')
 local keyfile=filename and io.open(filename..'/openweb-template.key','rb');local key=keyfile and keyfile:read('*a');if keyfile then keyfile:close() end
 if not key or #key~=32 then finish('identity_key_unavailable');return end
 local rule,owner,number=allowed(request.caller_number)
 if not rule then finish('caller_route_blocked');return end
 local greeting=storage_dir..'/openwebpbx/call-me-back/'..request.service_uuid..'/greeting.wav'
 local f=io.open(greeting,'rb');if not f then finish('greeting_missing');return end;f:close()
 for _,route in ipairs(rule.routes) do
  if not active() then finish('cancelled');return end
  local leg=contact(number,route,owner)
  if leg then
   call=freeswitch.Session('{origination_uuid='..request.call_uuid..',domain_uuid='..request.domain_uuid..',domain_name='..config.realm..',originate_timeout=25,call_timeout=25,ignore_early_media=true,absolute_timeout=900,hangup_after_bridge=false,continue_on_fail=true,call_direction=outbound,sensitive_dtmf=true}'..leg)
   if call:ready() then break end
   if not P.failover(call:hangupCause(),nil,false,nil) then break end
  end
 end
 if not call or not call:ready() then finish('caller_no_answer');return end
 api:execute('sched_api','+120 openweb-cmb-'..id..' uuid_kill '..request.call_uuid..' ALLOTTED_TIMEOUT')
 call:setVariable('sensitive_dtmf','true');call:setVariable('dtmf_verbose','false');call:setVariable('verbose_events','false');call:setVariable('openweb_cmb_request',id)
 call:setVariable('sip_copy_custom_headers','false');call:setVariable('continue_on_fail','true');call:setVariable('hangup_after_bridge','false')
 local known=false;local remaining=0
 query([[select a.total_seconds-a.used_seconds-a.reserved_seconds as remaining from v_pbx_cmb_bindings b join v_pbx_cmb_accounts a using(domain_uuid,service_uuid,account_uuid) where b.domain_uuid=:d and b.service_uuid=:s and b.phone_number=:cli and b.revoked_at is null and a.enabled]],{d=request.domain_uuid,s=request.service_uuid,cli=request.caller_number},function(r)known=true;remaining=tonumber(r.remaining) or 0 end)
 local allowance=0
 query('select openweb_cmb_authorize(:id,NULL) as seconds',{id=id},function(r)allowance=tonumber(r.seconds) or 0 end)
 if known and allowance==0 then play(remaining<=0 and 'quota-exhausted' or 'unavailable');finish(remaining<=0 and 'quota_exhausted' or 'account_busy');return end
 if allowance==0 then
  -- ID input remains solely in this interpreter's memory. No variable name,
  -- command argument, recording or SQL value receives the plaintext ID.
  local identity=call:playAndGetDigits(13,13,3,10000,'#',greeting,sound('invalid-id'),'',nil,3000)
  local proof=identity and Crypto.verifier(key,request.domain_uuid,identity);identity=nil;key=nil
  if not proof or not call:ready() then finish('authentication_failed');return end
  query('select openweb_cmb_authorize(:id,:proof) as seconds',{id=id,proof=proof},function(r)allowance=tonumber(r.seconds) or 0 end)
  if allowance==0 then
   local recognised=false;local available=0
   query('select total_seconds-used_seconds-reserved_seconds as remaining from v_pbx_cmb_accounts where domain_uuid=:d and service_uuid=:s and id_hmac=:proof and enabled',{d=request.domain_uuid,s=request.service_uuid,proof=proof},function(r)recognised=true;available=tonumber(r.remaining) or 0 end);proof=nil
   if recognised then play(available<=0 and 'quota-exhausted' or 'unavailable');finish(available<=0 and 'quota_exhausted' or 'account_busy')
   else play('invalid-id');finish('authentication_failed') end
   return
  end
  proof=nil;play('authenticated')
 end
 if not call:ready() or not active() then finish('caller_disconnected');return end
 local target=call:playAndGetDigits(7,16,2,12000,'#',sound('enter-number'),sound('invalid-number'),'',nil,3000)
 -- DTMF has no '+' key; international numbers must use a configured 00 rule.
 local targetRule,targetOwner,dialled=allowed(target)
 if not targetRule then play('invalid-number');finish('destination_blocked');return end
 for _,route in ipairs(targetRule.routes) do
  if not call:ready() or not active() then break end
  local leg=contact(dialled,route,targetOwner)
  if leg then
   local bridge=api:execute('create_uuid',''):gsub('%s+$','');if not C.uuid(bridge) then error('Bridge identity unavailable') end
   destination_call=bridge;local claimed=false
   query("update v_pbx_cmb_requests set bridge_uuid=:bridge,lease_until=now()+interval '12 minutes',updated_at=now() where request_uuid=:id and state='dialling' returning 1",{bridge=bridge,id=id},function()claimed=true end)
   if not claimed then break end
   call:setVariable('openweb_provider_answered','false');call:setVariable('openweb_cmb_answer_observed','false')
   -- Leg variables are server-generated UUIDs only. The destination answer hook
   -- starts both hard timers exactly once; a ringing carrier cannot use quota.
   leg=leg:gsub('^%[','[origination_uuid='..bridge..',openweb_cmb_parent_uuid='..request.call_uuid..',openweb_cmb_limit_seconds='..allowance..',api_on_answer=uuid_setvar '..request.call_uuid..' openweb_cmb_answer_observed true,execute_on_answer=lua app/pbx_setup/call_me_back_answer.lua '..id..',leg_timeout=30,',1)
   call:execute('bridge',leg)
   local connected=false;local elapsed=0
   query('select connected_at is not null as answered,least(reserved_seconds,greatest(0,ceil(extract(epoch from (now()-connected_at))))) as seconds from v_pbx_cmb_requests where request_uuid=:id',{id=id},function(r)connected=r.answered=='t' or r.answered=='true';elapsed=tonumber(r.seconds) or 0 end)
   if connected then finish('connected',elapsed);return end
   if call:getVariable('openweb_cmb_answer_observed')=='true' or call:getVariable('originate_disposition')=='SUCCESS' then query("select openweb_cmb_finish(:id,NULL,'answer_accounting_uncertain')",{id=id});return end
   local cause=call:getVariable('last_bridge_hangup_cause') or call:getVariable('originate_disposition') or 'UNKNOWN'
   if not call:ready() or not P.failover(cause,call:getVariable('last_bridge_proto_specific_hangup_cause'),false,call:getVariable('sip_invite_failure_status')) then break end
  end
 end
 finish('destination_no_answer')
end
local ok=pcall(deliver)
if not ok then
 if call and call:ready() then call:hangup('NORMAL_TEMPORARY_FAILURE') end
 if request then pcall(function()finish('internal_failure')end) end
 freeswitch.consoleLog('ERR','[OpenWeb PBX] Call Me Back request failed; no automatic redial.\n')
end
if call and call:ready() then call:hangup('NORMAL_CLEARING') end
local ended=not call or not call:ready()
if ended and destination_call then
 ended=false
 for _=1,10 do
  local observed=(api:execute('uuid_exists',destination_call) or ''):gsub('%s+$','')
  if observed=='false' then ended=true;break end
  if observed~='true' then break end
  freeswitch.msleep(50)
 end
end
if ended then
 api:execute('sched_del','openweb-cmb-'..id)
 api:execute('sched_del','openweb-cmb-active-'..id)
end
db:release()
