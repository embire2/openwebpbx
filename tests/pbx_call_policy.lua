local P=loadfile('app/pbx_setup/resources/switch/scripts/app/pbx_setup/policy.lua')()
local n=0
local function check(value,why) n=n+1;assert(value,why) end
local function destination(number) return {type='Extension',number=number,external=''} end
check(P.contact('sofia/internal/sip:100@127.0.0.1:5060\n')=='sofia/internal/sip:100@127.0.0.1:5060','Registered phone contact')
check(not P.contact('error/user_not_registered'),'Native unregistered phone response')
check(not P.contact('-ERR Invalid Profile'),'Invalid profile response')
check(not P.contact(''),'Empty phone contact')
local c={timezone='Africa/Johannesburg',departments={{number='GRP1',name='Sales',timezone='Africa/Johannesburg',members={{number='100',primary=true}},hours={type='SpecificHours',periods={{day=1,start='08:00', ['end']='17:00'}}},breaks={periods={{day=1,start='12:00',['end']='13:00'}}},holidays={{date='2026-12-25'}}}},users={['100']={profile='Available',auto_status='1',profiles={Available={available={NoAnswer={internal_inactive=false,internal=destination('101'),all=destination('102')}},away={}},Away={available={},away={Internal={outside_inactive=true,all=destination('103')},External={outside_inactive=false,all=destination('104'),outside=destination('105')}}},['Out of office']={available={},away={}}}}},outbound_rules={{prefix='0, +27',lengths='10-12',departments={'Sales'},ranges={},routes={{trunk_id='T1',strip=1,prepend='+27'}}},{prefix='9',lengths='',departments={},ranges={{from='200',to='299'}},routes={{trunk_id='T2',strip=1,prepend=''}}}}}
local clock=function(t) return function() return 1,t,'2026-10-05' end end
check(P.in_hours({type='AllHours'},0,'00:00'),'Always-open schedule')
check(P.in_hours(c.departments[1].hours,1,'08:00'),'Opening boundary')
check(not P.in_hours(c.departments[1].hours,1,'17:00'),'Closing boundary')
check(not P.in_hours(c.departments[1].hours,0,'12:00'),'Closed weekday')
check(P.office(c,'100',clock('09:00')),'Inside office hours')
check(not P.office(c,'100',clock('12:30')),'Break time')
check(not P.office(c,'100',clock('20:00')),'After hours')
check(not P.office(c,'100',function()return 1,'09:00','2026-12-25' end),'Holiday')
check(P.profile(c,'100',clock('09:00'))==c.users['100'].profiles.Available,'Automatic available status')
check(P.profile(c,'100',clock('12:30'))==c.users['100'].profiles.Away,'Automatic break status')
check(P.profile(c,'100',clock('20:00'))==c.users['100'].profiles['Out of office'],'Automatic closed status')
check(P.forward(c.users['100'].profiles.Available,'NoAnswer',true,true).number=='101','Internal unanswered destination')
check(P.forward(c.users['100'].profiles.Available,'NoAnswer',false,true).number=='102','External unanswered destination')
check(P.forward(c.users['100'].profiles.Away,'NoAnswer',false,false).number=='105','Outside-hours away destination')
check(P.forward(c.users['100'].profiles.Away,'NoAnswer',true,false).number=='103','Disabled outside-hours override')
check(P.outbound(c,'0111234567','100')==c.outbound_rules[1],'Matching department/prefix/length')
check(not P.outbound(c,'0111234567','300'),'Foreign department blocked')
check(not P.outbound(c,'011','100'),'Wrong length blocked')
check(P.outbound(c,'912345','200')==c.outbound_rules[2],'Extension range allowed')
check(not P.outbound(c,'912345','300'),'Extension range denied')
check(P.route_string('External..0123456789').external=='0123456789','External route string')
check(P.route_string('Extension.101.').number=='101','Internal route string')
check(P.route_string('ProceedWithNoExceptions..')==nil,'Continue route string')
local header='name|state|status|ready_time|last_bridge_end|wrap_up_time|external_calls_count|\n'
check(P.agent_available(header..'agent|Waiting|Available|0|0|2|0|\n+OK','agent',100),'Available native agent')
check(not P.agent_available(header..'agent|Waiting|On Break|0|0|2|0|','agent',100),'Native pause honored')
check(not P.agent_available(header..'agent|Waiting|Available|110|0|2|0|','agent',100),'Retry delay honored')
check(not P.agent_available(header..'agent|Waiting|Available|0|95|10|0|','agent',100),'Queue wrap-up honored')
check(not P.agent_available(header..'agent|Waiting|Available|0|0|2|1|','agent',100),'Outside call makes agent busy')
check(not P.agent_available('-ERR Agent not found!','agent',100),'Missing native agent rejected')
check(not P.agent_available(header..'other|Waiting|Available|0|0|2|0|','agent',100),'Foreign native agent rejected')
check(P.callback_open(c,{number='100',hours={hours={type='OfficeHours'},outside=''}},clock('09:00')),'Callbacks inside office hours')
check(not P.callback_open(c,{number='100',hours={hours={type='OfficeHours'},outside=''}},clock('20:00')),'Callbacks wait until office opens')
check(P.rewrite('0123456789',{strip=1,prepend='+27'})=='+27123456789','Per-provider number rewriting')
check(P.rewrite('+27123456789',{strip=3,prepend='0'})=='0123456789','International-to-national rewrite')
check(not P.rewrite('123',{strip=3,prepend=''}),'Empty rewritten target is rejected')
check(not P.rewrite('123',{strip=-1,prepend=''}),'Negative strip is rejected')
check(not P.rewrite('123',{strip=0.5,prepend=''}),'Fractional strip is rejected')
check(not P.rewrite('123',{strip=0,prepend='${bad}'}),'Unsafe rewrite is rejected')
local trunk={gateway_uuid='00000000-0000-4000-a000-000000000001',main_number='+27210000001',caller_id='+27210000002',codecs={'PCMA','PCMU'},headers={FromUserPart='$OutboundCallerId',FromDisplayName='$OutboundCallerId',FromHostPart='$GWHostPort',RemotePartyIDCallingPartyUserPart='$OutboundCallerId'},host='provider.example.invalid',port=5060}
local user={outbound_caller_id='+27210000003'}
local outbound_route={strip=1,prepend='+27',caller_id='+27210000004'}
check(P.caller_id(trunk,outbound_route,user,'100')=='+27210000004','Route caller ID overrides user and trunk')
outbound_route.caller_id=''
check(P.caller_id(trunk,outbound_route,user,'100')=='+27210000003','User caller ID overrides trunk')
user.outbound_caller_id=''
check(P.caller_id(trunk,outbound_route,user,'100')=='+27210000002','Trunk caller ID selected')
trunk.caller_id=''
check(P.caller_id(trunk,outbound_route,user,'100')=='+27210000001','Main-number final caller ID fallback')
check(P.caller_id({}, {}, {}, '')=='anonymous','Missing identity does not inherit earlier route')
local native={enabled='true',register='false',from_domain='provider.example.invalid:5060'}
local leg,cid=P.outbound_leg(trunk,outbound_route,'0123456789',user,'100','00000000-0000-4000-a000-000000000009','fixture.example.invalid',native)
check(leg and leg:find('absolute_codec_string=^^:PCMA:PCMU',1,true),'Ordered provider codecs use a separator safe through native originate parsers')
check(cid==trunk.main_number and leg:find('origination_caller_id_number='..cid,1,true),'Outgoing leg owns its caller ID')
check(leg:find('sip_invite_from_uri=sip:'..cid..'@provider.example.invalid:5060',1,true),'Provider From URI uses selected identity')
check(leg:find('sip_cid_type=rpid',1,true) and leg:find('sip_copy_custom_headers=false',1,true),'RPID selected without copying inbound headers')
check(leg:find('/+27123456789',1,true),'Bridge dials rewritten target')
trunk.codecs={'PCMA,origination_uuid=bad'}
check(not P.outbound_leg(trunk,outbound_route,'0123456789',user,'100','00000000-0000-4000-a000-000000000009','fixture.example.invalid',native),'Malformed codec list cannot inject originate variables')
trunk.codecs={'PCMA','PCMU'}
check(not P.outbound_leg(trunk,outbound_route,'0123456789',user,'100','other-domain','fixture.example.invalid',native),'Malformed domain rejected')
check(P.gateway_available(native,'State   \tNOREG\nStatus  \tUP\n'),'Healthy IP-authenticated provider')
check(not P.gateway_available(native,'State   \tNOREG\nStatus  \tDOWN\n'),'Down IP provider skipped')
native.register='true'
check(P.gateway_available(native,'State   \tREGED\nStatus  \tUP\n'),'Registered provider selected')
check(not P.gateway_available(native,'State   \tFAIL_WAIT\nStatus  \tUP\n'),'Unregistered provider skipped')
check(not P.gateway_available(native,'-ERR Invalid Gateway'),'Missing native gateway skipped')
native.enabled='false'
check(not P.gateway_available(native,'State   \tREGED\nStatus  \tUP\n'),'Disabled native provider skipped')
for _,code in ipairs({400,401,402,403,404,405,406,407,408,409,410,411,413,414,415,416,420,421,423,433,480,481,482,483,484,485,487,500,501,502,503,504,505,513,603,604,606}) do check(P.failover('CALL_REJECTED','sip:'..code,nil,tostring(code)),'Published provider-failover SIP '..code) end
for _,code in ipairs({200,301,302,486,488,600,602,1408}) do check(not P.failover('NORMAL_TEMPORARY_FAILURE','sip:'..code),'No provider failover for SIP '..code) end
check(not P.failover('SUCCESS','sip:503'),'Answered call never retried')
check(not P.failover('ORIGINATOR_CANCEL','sip:487'),'Caller cancellation never retried')
check(not P.failover('NO_ANSWER','sip:408'),'Unanswered destination never retried')
check(not P.failover('NO_USER_RESPONSE','sip:408'),'No response never retried')
check(not P.failover('USER_BUSY',nil),'Busy without raw SIP response stops')
check(not P.failover('NORMAL_TEMPORARY_FAILURE','sip:503','12345'),'Previously answered bridge never retried')
check(P.failover('GATEWAY_DOWN',nil),'Local gateway failure can use backup route')
local ingress_trunk={gateway_uuid='00000000-0000-4000-a000-000000000001',main_number='27210000009',dids={'27210000001'},source_field='ToUserPart',allowed_ips={'192.0.2.10'}}
local incoming={rule_id='fixture-in',enabled=true,condition='BasedOnDID',number='+27210000001',trunk_id='one'}
local inbound_config={inbound_rules={incoming}}
local sip={sip_to_user='27210000001',sip_req_user='27210000002',destination_number='27210000003'}
local get=function(name)return sip[name]end
check(P.incoming(inbound_config,incoming,ingress_trunk,get,'192.0.2.10'),'To-field DID accepted despite different Request URI')
check(not P.incoming(inbound_config,incoming,ingress_trunk,get,'192.0.2.11'),'Foreign source IP denied')
ingress_trunk.source_field='RequestLineURIUser'
check(not P.incoming(inbound_config,incoming,ingress_trunk,get,'192.0.2.10'),'Request URI selector does not trust To field')
sip.sip_req_user='+27210000001'
check(P.incoming(inbound_config,incoming,ingress_trunk,get,'192.0.2.10'),'Request URI and plus normalization accepted')
sip.sip_req_user=nil
check(not P.incoming(inbound_config,incoming,ingress_trunk,get,'192.0.2.10'),'Missing source field does not trust destination_number')
check(P.did_matches('*000001','+27210000001'),'Explicit suffix DID match')
check(not P.did_matches('*000002','+27210000001'),'Wrong suffix denied')
check(not P.did_matches('*.*','27210000001'),'DID regex injection rejected')
check(not P.did_matches('0210000001','210000001'),'DID leading zeros are preserved')
ingress_trunk.source_field='ToUserPart'
local fallback={enabled=true,condition='ForwardAll',trunk_id='one'}
check(not P.incoming(inbound_config,fallback,ingress_trunk,get,'192.0.2.10'),'Provider fallback cannot steal configured DID')
sip.sip_to_user='27210000009'
check(P.incoming(inbound_config,fallback,ingress_trunk,get,'192.0.2.10'),'Declared main number uses explicit forward-all rule')
incoming.enabled=false
sip.sip_to_user='27210000001'
check(P.incoming(inbound_config,fallback,ingress_trunk,get,'192.0.2.10'),'Disabled DID does not claim a provider fallback')
incoming.enabled=true
incoming.condition='BasedOnCallerID'
check(not P.incoming(inbound_config,incoming,ingress_trunk,get,'192.0.2.10'),'Unsupported ingress condition rejected')
trunk.headers.ContactUser='$OutboundCallerId'
native={enabled='true',register='false',from_domain='provider.example.invalid:5060',proxy='provider.example.invalid:5060',outbound_proxy='edge.example.invalid:5070',register_transport='tcp',profile='external',from_user='provider-account'}
leg,cid=P.outbound_leg(trunk,outbound_route,'0123456789',user,'100','00000000-0000-4000-a000-000000000009','fixture.example.invalid',native)
check(leg and leg:find(']sofia/external/+27123456789@provider.example.invalid:5060;transport=tcp',1,true),'Dynamic Contact uses native profile and trusted proxy/transport')
check(leg:find('sip_contact_user='..trunk.main_number,1,true),'Dynamic Contact owns the selected route caller ID')
check(leg:find('sip_use_gateway='..trunk.gateway_uuid,1,true) and leg:find('sip_gateway_name='..trunk.gateway_uuid,1,true),'Direct leg keeps the existing tenant gateway for authentication and attribution')
check(leg:find('sip_route_uri=sip:edge.example.invalid:5070;transport=tcp',1,true),'Direct leg preserves trusted outbound proxy')
check(leg:find('sip_invite_contact_params=transport=tcp;gw='..trunk.gateway_uuid,1,true),'Direct Contact retains transport and native inbound gateway identifier')
trunk.headers.FromUserPart='$AuthID'
leg=P.outbound_leg(trunk,outbound_route,'0123456789',user,'100','00000000-0000-4000-a000-000000000009','fixture.example.invalid',native)
check(leg:find('sip_invite_from_uri=sip:provider-account@provider.example.invalid:5060',1,true),'Direct leg preserves provider authentication identity in From')
native.from_user='account@example.invalid'
leg=P.outbound_leg(trunk,outbound_route,'0123456789',user,'100','00000000-0000-4000-a000-000000000009','fixture.example.invalid',native)
check(leg:find('sip_invite_from_uri=sip:account%40example.invalid@',1,true),'From identity escapes an embedded at-sign')
native.proxy='provider.example.invalid,origination_uuid=bad'
check(not P.outbound_leg(trunk,outbound_route,'0123456789',user,'100','00000000-0000-4000-a000-000000000009','fixture.example.invalid',native),'Unsafe native proxy cannot inject originate settings')
native.proxy='provider.example.invalid:5060';native.profile='../external'
check(not P.outbound_leg(trunk,outbound_route,'0123456789',user,'100','00000000-0000-4000-a000-000000000009','fixture.example.invalid',native),'Unsafe profile cannot change the direct routing path')
check(P.trunk_number({main_number='',dids=' +27210000001;*000002\n27210000003 '},'27210000001'),'Raw source DID declarations match safely')
check(P.trunk_number({dids='*000002'},'+27210000002'),'Raw source wildcard DID declaration matches suffix')
check(not P.trunk_number({dids='*.*'},'27210000001'),'Malformed source DID declaration cannot match')
incoming.condition='BasedOnDID';sip.sip_gateway='00000000-0000-4000-a000-000000000099'
check(not P.incoming(inbound_config,incoming,ingress_trunk,get,'192.0.2.10'),'Native inbound gateway cannot select another provider')
sip.sip_gateway=ingress_trunk.gateway_uuid
check(P.incoming(inbound_config,incoming,ingress_trunk,get,'192.0.2.10'),'Matching native inbound gateway accepts its declared DID')
sip.sip_gateway=nil;sip.sip_to_user='27210000008'
check(not P.incoming(inbound_config,fallback,ingress_trunk,get,'192.0.2.10'),'Forward-all does not claim an undeclared public DID')
sip.sip_to_user='27210000009'
local other_trunk={allowed_ips={'192.0.2.10'},main_number='27210000009'}
inbound_config.trunks={one=ingress_trunk,two=other_trunk}
inbound_config.inbound_rules={{rule_id='other',trunk_id='two',enabled=true,condition='BasedOnDID',number='27210000009'}}
check(not P.incoming(inbound_config,fallback,ingress_trunk,get,'192.0.2.10'),'Forward-all cannot steal another same-IP provider DID')
inbound_config.inbound_rules[1].condition='ForwardAll'
check(not P.incoming(inbound_config,fallback,ingress_trunk,get,'192.0.2.10'),'Ambiguous same-IP provider fallback is rejected')
sip.sip_gateway=ingress_trunk.gateway_uuid
check(P.incoming(inbound_config,fallback,ingress_trunk,get,'192.0.2.10'),'Native gateway ownership disambiguates same-IP provider fallbacks')
check(P.track_answer('[leg_timeout=10]sofia/gateway/fixture/123','00000000-0000-4000-a000-000000000009'):find("api_on_answer='uuid_setvar 00000000-0000-4000-a000-000000000009 openweb_provider_answered true'",1,true),'Answer tracking updates only this local caller UUID')
check(not P.track_answer('[leg_timeout=10]sofia/gateway/fixture/123','bad;shutdown'),'Answer tracking rejects API command injection')
check(not P.failover('NORMAL_TEMPORARY_FAILURE','sip:503','true'),'Actual-answer flag blocks provider failover')
check(P.failover('NO_USER_RESPONSE','sip:480',nil,'480'),'Actual provider480 overrides native no-user-response cause')
check(P.failover('ORIGINATOR_CANCEL','sip:487',nil,'487'),'Actual provider487 overrides native cancel cause while caller remains ready')
check(not P.failover('RECOVERY_ON_TIMER_EXPIRE','sip:408',nil,''),'Generated timeout408 is not a provider failure response')
print('PASS: '..n..' office-hours, forwarding, outbound and callback decisions')
