-- Synthetic runtime integration: no database, registrations or external calls.
local base='app/pbx_setup/resources/switch/scripts'
local count=0
local function check(value,message) count=count+1;assert(value,message) end
local function copy(value)
    if type(value)~='table' then return value end
    local result={};for key,item in pairs(value) do result[key]=copy(item) end;return result
end
local domain='00000000-0000-4000-a000-000000000009'
local gateway1='00000000-0000-4000-a000-000000000001'
local gateway2='00000000-0000-4000-a000-000000000002'
local profile={timeout=10,queue_status='1',available={},away={}}
local config={realm='fixture.example.invalid',timezone='UTC',users={
    ['100']={number='100',auth_id='auth100',enabled=true,profile='Available',profiles={Available=profile},outbound_caller_id=''},
    ['200']={number='200',auth_id='auth200',enabled=true,profile='Available',profiles={Available=profile}}},
    trunks={one={gateway_uuid=gateway1,main_number='+27210000001',caller_id='',host='provider-one.example.invalid',port=5060,codecs={'PCMA'},headers={FromUserPart='$OutboundCallerId',FromHostPart='$GWHostPort',RemotePartyIDCallingPartyUserPart='$OutboundCallerId'},source_field='ToUserPart',allowed_ips={'192.0.2.10'}},
        two={gateway_uuid=gateway2,main_number='+27210000002',caller_id='',host='provider-two.example.invalid',port=5060,codecs={'PCMU'},headers={FromUserPart='$OutboundCallerId',FromHostPart='$GWHostPort'}}},
    departments={{number='sales',name='Sales',members={{number='100',primary=true}},hours={type='AllHours'},breaks={periods={}},holidays={}}},
    outbound_rules={{prefix='0',lengths='10',ranges={},departments={'Sales'},routes={{trunk_id='one',strip=1,prepend='+27',caller_id='+27210000003'},{trunk_id='two',strip=1,prepend='+27',caller_id=''}}}},
    inbound_rules={{rule_id='incoming-one',trunk_id='one',condition='BasedOnDID',number='+27210000001',enabled=true,hours={type='AllHours'},office={type='Extension',number='200',external=''}}},
    ring_groups={},receptionists={},scripts={},queues={{number='300',callback_mode='request',callback_prefix='',ring_timeout=10,wrap_up=2,members={{number='100',agent_uuid='fixture-agent',status='LoggedIn'}}}}}
config.users['100'].queue_status='LoggedIn'
local function fixture()
    return {config=copy(config),active=true,gateways={
        [gateway1]={domain=domain,enabled='true',register='false',from_domain='provider-one.example.invalid',proxy='provider-one.example.invalid:5060',profile='external',register_transport='udp',state='NOREG'},
        [gateway2]={domain=domain,enabled='true',register='false',from_domain='provider-two.example.invalid',proxy='provider-two.example.invalid:5060',profile='external',register_transport='udp',state='NOREG'}},
        variables={domain_uuid=domain,destination_number='0123456789',sip_auth_username='auth100',sip_auth_realm=config.realm,uuid='00000000-0000-4000-a000-000000000010'},
        responses={{cause='NORMAL_TEMPORARY_FAILURE',protocol='sip:503'},{cause='SUCCESS',protocol='sip:200'}},bridges={},bridge_timeouts={},transfers={},released=false}
end
local function environment(f)
    local s={variables=f.variables,alive=true}
    function s:ready()return self.alive end
    function s:getVariable(key)return self.variables[key]end
    function s:setVariable(key,value)self.variables[key]=value end
    function s:hangup(cause)f.hangup=cause;self.alive=false end
    function s:answer()end
    function s:transfer(number,_,realm)f.transfers[#f.transfers+1]={number=number,realm=realm}end
    function s:execute(application,data)
        if application=='record_session' then f.recordings=(f.recordings or 0)+1
        elseif application=='bridge' then
            f.bridges[#f.bridges+1]=data
            f.bridge_timeouts[#f.bridges]=self.variables.call_timeout
            local response=f.responses[#f.bridges] or {cause='NO_ANSWER',protocol='sip:408'}
            self.variables.originate_disposition=response.cause
            self.variables.last_bridge_proto_specific_hangup_cause=response.protocol
            self.variables.sip_invite_failure_status=response.received or ''
            if response.answered then self.variables.openweb_provider_answered='true' end
            if response.disconnect then self.alive=false end
        end
    end
    local db={}
    function db:query(sql,params,callback)
        if sql:find('from v_gateways',1,true) then
            local native=f.gateways[params.id]
            if native and native.domain==params.domain and callback then callback(native) end
        elseif sql:find('from v_pbx_mobile_devices',1,true) then
            if f.mobile_active and params.domain==domain then callback({extension_uuid='mobile-fixture-extension'}) end
        elseif sql:find('select r.config from v_pbx_restore',1,true) then
            assert(sql:find("d.domain_enabled='true'",1,true) and sql:find('not t.enabled',1,true),'Enabled domain and tenant guard missing')
            if f.active then callback({config='fixture-config'}) end
        elseif sql:find('select j.*,r.config',1,true) then
            if f.active then
                f.job={job_uuid='00000000-0000-4000-a000-000000000030',domain_uuid=domain,call_uuid='00000000-0000-4000-a000-000000000031',kind='callback',queue_number='300',target_number='0123456789',internal_target='false',attempts=0,max_attempts=3,config='fixture-config'}
                callback(f.job)
            end
        elseif sql:find("set state='calling'",1,true) then if callback then callback({attempts=1}) end
        elseif sql:find("state='calling'",1,true) and sql:find('select 1 as ok',1,true) then if callback then callback({ok=1}) end
        elseif sql:find('set state=:state',1,true) then f.job_state=params.state
        elseif sql:find('select config from v_pbx_restore',1,true) then callback({config='fixture-config'})
        end
    end
    function db:release()f.released=true end
    local api={}
    function api:execute(command,data)
        if command=='sofia' then
            local id=data:match('status gateway (.+)')
            local native=f.gateways[id]
            return native and ('State\t'..native.state..'\nStatus\t'..(native.status or 'UP')..'\n') or '-ERR Gateway not found'
        elseif command=='sofia_contact' then return f.offline and 'error/user_not_registered' or 'sofia/internal/sip:fixture@127.0.0.1:15060'
        elseif command=='show' then return 'fixture-channels'
        elseif command=='strftime_tz' then return '1_09:00_2026-10-05'
        elseif command=='callcenter_config' and data:match('^agent list ') then
            return 'name|state|status|ready_time|last_bridge_end|wrap_up_time|external_calls_count|\nfixture-agent|Waiting|Available|0|0|0|0|'
        end
        return '+OK'
    end
    local env=setmetatable({session=s,scripts_dir=base,storage_dir='/nonexistent-fixture-storage',argv={'00000000-0000-4000-a000-000000000030'}},{__index=_G})
    env.require=function(name)
        if name=='resources.functions.database' then return {new=function()return db end} end
        if name=='resources.functions.lunajson' then return {decode=function(value)return value=='fixture-channels' and {rows={}} or f.config end} end
        if name=='resources.functions.config' then return {} end
        error('Unexpected dependency '..name)
    end
    env.freeswitch={API=function()return api end,consoleLog=function(_,message)f.log=message end,Session=function(dial)f.agent_dial=dial;return s end}
    return env
end
local function run(f,mode,key)
    local env=environment(f)
    assert(loadfile(base..'/app/pbx_setup/index.lua','t',env))({'pbx_setup',mode or 'outbound',key})
    assert(f.released,'Database connection was not released')
end
local f=fixture();run(f)
check(#f.bridges==2 and f.bridges[1]:find(gateway1,1,true) and f.bridges[2]:find(gateway2,1,true),'Provider503 retries ordered backup route')
check(f.bridges[1]:find('origination_caller_id_number=+27210000003',1,true) and f.bridges[2]:find('origination_caller_id_number=+27210000002',1,true),'Ordinary backup route does not inherit failed caller ID')
check(f.bridges[1]:find('absolute_codec_string=^^:PCMA',1,true) and f.bridges[2]:find('absolute_codec_string=^^:PCMU',1,true),'Each actual bridge receives its provider codec')
check(f.bridges[2]:find('/+27123456789',1,true),'Backup provider receives rewritten number')
for _, inherited in ipairs({'0','1','3600'}) do
    f=fixture();f.variables.call_timeout=inherited;f.variables.originate_timeout='1';f.variables.progress_timeout='1';run(f)
    check(#f.bridges==2 and f.bridge_timeouts[1]=='60' and f.bridge_timeouts[2]=='60'
        and f.bridges[1]:find('{originate_timeout=60,progress_timeout=60}[leg_timeout=60,',1,true)
        and f.bridges[2]:find('{originate_timeout=60,progress_timeout=60}[leg_timeout=60,',1,true),
        'Inherited user timeout '..inherited..' cannot shorten or remove the bounded provider window')
end
f=fixture();f.config.users['100'].profiles.Available.timeout=1;f.config.users['100'].profiles.Available.available.NoAnswer={internal_inactive=true,all={type='External',number='',external='0123456789'}}
f.responses={{cause='NO_ANSWER',protocol='sip:408'},{cause='SUCCESS',protocol='sip:200'}};run(f,'user','100')
check(#f.bridges==2 and f.bridge_timeouts[1]=='1' and f.bridges[1]:find('leg_timeout=1]user/',1,true)
    and f.bridge_timeouts[2]=='60' and f.bridges[2]:find('{originate_timeout=60,progress_timeout=60}[leg_timeout=60,',1,true),
    'No-answer external forwarding keeps the user ring timeout and gives the provider an independent window')
f=fixture();f.responses[1]={cause='USER_BUSY',protocol='sip:486'};run(f)
check(#f.bridges==1 and f.hangup=='USER_BUSY','Busy stops provider fallback')
f=fixture();f.responses[1]={cause='NO_USER_RESPONSE',protocol='sip:408'};run(f)
check(#f.bridges==1,'No-response does not redial another provider')
f=fixture();f.responses[1]={cause='ORIGINATOR_CANCEL',protocol='sip:487',disconnect=true};run(f)
check(#f.bridges==1,'Caller cancellation does not redial another provider')
f=fixture();f.responses[1]={cause='SUCCESS',protocol='sip:200'};run(f)
check(#f.bridges==1,'Answered call is not duplicated')
f=fixture();f.responses[1]={cause='NORMAL_CLEARING',protocol='sip:503',answered='123'};run(f)
check(#f.bridges==1 and f.bridges[1]:find("api_on_answer='uuid_setvar ",1,true),'Actual-answer callback blocks provider retry even if disposition differs')
f=fixture();f.gateways[gateway1].register='true';f.gateways[gateway1].state='FAIL_WAIT';run(f)
check(#f.bridges==1 and f.bridges[1]:find(gateway2,1,true),'Failed registration is skipped before first originate')
f=fixture();f.gateways[gateway1].domain='00000000-0000-4000-a000-000000000099';run(f)
check(#f.bridges==1 and f.bridges[1]:find(gateway2,1,true),'Foreign tenant gateway cannot be used')
f=fixture();f.active=false;run(f)
check(#f.bridges==0 and f.hangup=='UNALLOCATED_NUMBER','Disabled domain or suspended tenant cannot route')
f=fixture();f.variables.sip_auth_username=nil;run(f)
check(#f.bridges==0 and f.hangup=='CALL_REJECTED','Unauthenticated caller cannot dial an outbound rule directly')
f=fixture();f.variables.sip_auth_realm='foreign.example.invalid';run(f)
check(#f.bridges==0,'Foreign authentication realm cannot satisfy a local user restriction')
f=fixture();f.config.outbound_rules[1].routes={};f.config.outbound_rules[2]={prefix='0',lengths='',routes={{trunk_id='two',strip=1,prepend='+27'}}};run(f)
check(#f.bridges==0,'Blocking first rule does not fall through to a later matching rule')
f=fixture();f.variables.sip_network_ip='192.0.2.10';f.variables.sip_to_user='27210000001';f.variables.sip_req_user='27210000009';run(f,'incoming','incoming-one')
check(#f.transfers==1 and f.transfers[1].number=='200' and f.variables.openweb_provider_origin=='true','Selected To DID routes within tenant and remains provider-origin')
f=fixture();f.variables.sip_network_ip='192.0.2.11';f.variables.sip_to_user='27210000001';run(f,'incoming','incoming-one')
check(#f.transfers==0 and f.hangup=='CALL_REJECTED','Foreign provider IP blocked in runtime')
f=fixture();f.variables.sip_network_ip='192.0.2.10';f.variables.sip_to_user='27210000009';f.variables.destination_number='27210000001';run(f,'incoming','incoming-one')
check(#f.transfers==0,'Native destination cannot override the selected To DID')
f=fixture();f.variables.openweb_provider_origin='true';f.variables.caller_id_number='0990000000';f.variables.sip_auth_username='auth100'
f.config.users['100'].profiles.Available.away={External={outside_inactive=true,all={type='External',number='',external='0123456789'}}};run(f,'user','100')
check(#f.bridges==2,'External forwarding uses forwarding owner department rather than external caller')
f=fixture();f.variables.openweb_provider_origin='true';run(f,'voicemail_login')
check(f.hangup=='CALL_REJECTED','Provider origin cannot become internal by spoofing an auth username after transfer')
local function job(f)assert(loadfile(base..'/app/pbx_setup/jobs.lua','t',environment(f)))();assert(f.released,'Job connection not released')end
f=fixture();job(f)
check(f.agent_dial and #f.bridges==2 and f.job_state=='completed','Agent-first callback retries provider503 and connects')
check(f.bridges[1]:find('origination_caller_id_number=+27210000003',1,true) and f.bridges[2]:find('origination_caller_id_number=+27210000002',1,true),'Callback provider fallback resets route identity')
f=fixture();f.responses[1]={cause='USER_BUSY',protocol='sip:486'};job(f)
check(#f.bridges==1 and f.job_state=='waiting','Busy callback retains bounded job retry without immediate provider fallback')
f=fixture();f.responses[1]={cause='SUCCESS',protocol='sip:200'};job(f)
check(#f.bridges==1 and f.job_state=='completed','Answered callback is not duplicated')
f=fixture();f.gateways[gateway1].enabled='false';job(f)
check(#f.bridges==1 and f.bridges[1]:find(gateway2,1,true),'Callback skips a disabled first provider')
f=fixture();f.gateways[gateway1].enabled='false';f.gateways[gateway2].enabled='false';job(f)
check(not f.agent_dial and #f.bridges==0 and f.job_state=='waiting','Callback waits without ringing an agent when no provider route exists')
f=fixture();for _,trunk in pairs(f.config.trunks) do trunk.headers.ContactUser='$OutboundCallerId' end;run(f)
check(#f.bridges==2 and f.bridges[1]:find('sip_contact_user=+27210000003',1,true) and f.bridges[2]:find('sip_contact_user=+27210000002',1,true),'Ordinary dynamic Contact changes with provider fallback')
check(f.bridges[1]:find(']sofia/external/',1,true) and f.bridges[2]:find(']sofia/external/',1,true),'Dynamic contacts use validated native profile legs')
f=fixture();for _,trunk in pairs(f.config.trunks) do trunk.headers.ContactUser='$OutboundCallerId' end;job(f)
check(#f.bridges==2 and f.job_state=='completed' and f.bridges[2]:find('sip_contact_user=+27210000002',1,true),'Callbacks apply dynamic Contact on backup provider')
f=fixture();f.variables.sip_network_ip='192.0.2.10';f.variables.sip_to_user='27210000001';f.variables.sip_gateway=gateway2;run(f,'incoming','incoming-one')
check(#f.transfers==0 and f.hangup=='CALL_REJECTED','Native gateway binding cannot select another trunk incoming DID')
f=fixture();f.config.users['100'].record_calls=true;f.config.users['100'].record_external_only=true;run(f)
check(f.recordings==1,'Authenticated outside call records with external-only preference and no duplicate recording')
f=fixture();f.config.users['200'].record_calls=true;f.config.users['200'].record_external_only=true;run(f,'user','200')
check(not f.recordings,'Internal call does not record a recipient with external-only preference')
f=fixture();f.responses[1]={cause='NORMAL_CLEARING',protocol='sip:503',answered=true};job(f)
check(#f.bridges==1 and f.job_state=='completed','Answered callback completes without a later duplicate job retry')
f=fixture();f.responses[1]={cause='NO_USER_RESPONSE',protocol='sip:480',received='480'};run(f)
check(#f.bridges==2,'Actual provider480 retries despite Sofia NO_USER_RESPONSE cause')
f=fixture();f.responses[1]={cause='ORIGINATOR_CANCEL',protocol='sip:487',received='487'};run(f)
check(#f.bridges==2,'Actual provider487 retries when the caller remains connected')
f=fixture();f.responses[1]={cause='RECOVERY_ON_TIMER_EXPIRE',protocol='sip:408'};run(f)
check(#f.bridges==1,'Locally generated no-response408 does not redial another provider')
f=fixture();f.responses[1]={cause='RECOVERY_ON_TIMER_EXPIRE',protocol='sip:408',received='408'};job(f)
check(#f.bridges==2 and f.job_state=='completed','Received provider408 retries callback through backup route')
f=fixture();f.mobile_active=true;f.config.users['100'].extension_uuid='mobile-fixture-extension';f.variables.sip_auth_username='owm-0123456789abcdef0123456789abcdef';run(f)
check(#f.bridges==2,'Active mobile credentials use the original user outgoing policy')
f=fixture();f.variables.sip_auth_username='owm-0123456789abcdef0123456789abcdef';run(f)
check(#f.bridges==0 and f.hangup=='CALL_REJECTED','Removed mobile credentials cannot call even when configuration has no matching extension UUID')
f=fixture();f.mobile_active=true;f.config.users['100'].extension_uuid='other-extension';f.variables.sip_auth_username='owm-0123456789abcdef0123456789abcdef';run(f)
check(#f.bridges==0 and f.hangup=='CALL_REJECTED','Mobile credentials cannot assume a different configured user')
print('PASS: '..count..' synthetic ordinary-call, forwarding, ingress, callback and mobile runtime checks')
