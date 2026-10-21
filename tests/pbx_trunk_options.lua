local directory='app/pbx_setup/resources/switch/scripts/app/pbx_setup/'
local T=dofile(directory..'trunk_options.lua')
local P=dofile(directory..'policy.lua')
local checks=0
local function ok(value,message) assert(value,message);checks=checks+1 end
local domain='00000000-0000-4000-a000-000000000009'
local gateway='00000000-0000-4000-a000-000000000008'
local t={gateway_uuid=gateway,limit=2}
local contact='[domain_uuid='..domain..']sofia/gateway/'..gateway..'/0123456789'
ok(T.leg(domain,t,contact)==contact,'Legacy dial string changed')
local function session(vars)
 return {vars=vars or {},alive=true,executions={},getVariable=function(self,n)return self.vars[n]end,setVariable=function(self,n,v)self.vars[n]=v end,hangup=function(self,c)self.cause=c;self.alive=false end,ready=function(self)return self.alive end,execute=function(self,n,d)self.executions[#self.executions+1]={n,d};if self.exhausted then self:hangup('NORMAL_CIRCUIT_CONGESTION')end end}
end
local s=session();ok(T.accept(s,domain,t) and #s.executions==0,'Legacy inbound calling changed')
t.options={schema=1,allow_incoming=true,allow_outgoing=true,support_reinvite=true,srtp_mode='inherit',scope_department=''}
local leg=T.leg(domain,t,contact)
ok(leg:find("execute_on_originate_openweb_trunk_limit='limit hash openweb%-trunk%-"),'Missing native B-leg capacity hook')
ok(leg:find('!NORMAL_CIRCUIT_CONGESTION',1,true),'Capacity refusal must permit provider failover')
ok(leg:find('limit_ignore_transfer=true',1,true),'Transfer must retain a live leg slot')
ok(leg:find('sip_ignore_reinvites=false',1,true),'Default hold negotiation changed')
ok(not leg:find('rtp_secure_media_outbound',1,true),'Automatic audio changed existing encryption policy')
ok(leg:find('bypass_media=false',1,true) and leg:find('proxy_media=false',1,true),'Provider media can bypass the PBX')
for mode,expected in pairs({disabled='forbidden',optional='optional:AES_CM_128_HMAC_SHA1_80',required='mandatory:AES_CM_128_HMAC_SHA1_80'})do t.options.srtp_mode=mode;ok(T.leg(domain,t,contact):find('rtp_secure_media_outbound='..expected,1,true),'SRTP mode not applied to provider leg')end
t.options.srtp_mode='inherit';t.options.support_reinvite=false;ok(T.leg(domain,t,contact):find('sip_ignore_reinvites=true',1,true),'Explicit provider re-invite refusal missing');t.options.support_reinvite=true
t.options.allow_outgoing=false;ok(not T.leg(domain,t,contact),'Disabled outbound trunk accepted');t.options.allow_outgoing=true
t.options.scope_department='d';local config={departments={{number='d',members={{number='1000'},{number='1001',primary=false}}}}}
ok(T.leg(domain,t,contact,config,'1000'),'Department member denied');ok(T.leg(domain,t,contact,config,'1001'),'Secondary department member denied');ok(not T.leg(domain,t,contact,config,'1002'),'Foreign department member accepted');ok(not T.leg(domain,t,contact,nil,'1000'),'Missing department snapshot accepted');t.options.scope_department=''
s=session();ok(T.accept(s,domain,t) and #s.executions==1 and s.executions[1][1]=='limit','Incoming slot not acquired');ok(s.vars.sip_ignore_reinvites=='false' and s.vars.bypass_media=='false','Incoming policy not applied')
s=session();s.exhausted=true;ok(not T.accept(s,domain,t) and s.cause=='NORMAL_CIRCUIT_CONGESTION','Full incoming trunk continued')
t.options.allow_incoming=false;s=session();ok(not T.accept(s,domain,t) and s.cause=='CALL_REJECTED' and #s.executions==0,'Disabled inbound trunk acquired a slot');t.options.allow_incoming=true
t.options.srtp_mode='required';s=session();ok(not T.accept(s,domain,t) and s.cause=='INCOMPATIBLE_DESTINATION','Required SRTP accepted plain audio');s=session({rtp_has_crypto='AES_CM_128_HMAC_SHA1_80'});ok(T.accept(s,domain,t),'Required SRTP rejected secure audio')
t.options.srtp_mode='disabled';s=session({rtp_has_crypto='AES_CM_128_HMAC_SHA1_80'});ok(not T.accept(s,domain,t),'Disabled SRTP accepted secure audio');s=session();ok(T.accept(s,domain,t),'Disabled SRTP rejected plain audio')
t.options.srtp_mode='inherit'
for _,limit in ipairs({0,-1,1.5,10001,'bad'})do local old=t.limit;t.limit=limit;ok(not T.leg(domain,t,contact),'Invalid call capacity accepted');t.limit=old end
ok(not T.leg('foreign',t,contact),'Malformed domain accepted');ok(not T.leg(domain,t,'sofia/gateway/x'),'Unbracketed dial string accepted')
local user={caller_id='27110000001'};local route={strip=0,prepend='',caller_id=''};local native={}
local old=t.options;t.options=nil;local ordinary=P.outbound_leg(t,route,'0123456789',user,'1000',domain,'fixture.invalid',native,config);ok(ordinary and not ordinary:find('trunk_limit',1,true),'Legacy policy changed')
t.options=old;local wrapped=P.outbound_leg(t,route,'0123456789',user,'1000',domain,'fixture.invalid',native,config);ok(wrapped and wrapped:find('trunk_limit',1,true),'Shared outbound policy omitted provider options')
t.options.allow_outgoing=false;ok(not P.outbound_leg(t,route,'0123456789',user,'1000',domain,'fixture.invalid',native,config),'Shared outbound policy ignored direction')
print('PASS: '..checks..' trunk options decisions; native slot ownership requires separate engine proof')
