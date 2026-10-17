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
    ['100']={number='100',auth_id='auth100',extension_uuid='00000000-0000-4000-a000-000000000062',enabled=true,profile='Available',profiles={Available=profile},outbound_caller_id=''},
    ['200']={number='200',auth_id='auth200',extension_uuid='00000000-0000-4000-a000-000000000063',enabled=true,profile='Available',profiles={Available=profile}}},
    trunks={one={gateway_uuid=gateway1,main_number='+27210000001',caller_id='',host='provider-one.example.invalid',port=5060,codecs={'PCMA'},headers={FromUserPart='$OutboundCallerId',FromHostPart='$GWHostPort',RemotePartyIDCallingPartyUserPart='$OutboundCallerId'},source_field='ToUserPart',allowed_ips={'192.0.2.10'}},
        two={gateway_uuid=gateway2,main_number='+27210000002',caller_id='',host='provider-two.example.invalid',port=5060,codecs={'PCMU'},headers={FromUserPart='$OutboundCallerId',FromHostPart='$GWHostPort'}}},
    departments={{number='sales',name='Sales',members={{number='100',primary=true}},hours={type='AllHours'},breaks={periods={}},holidays={}}},
    outbound_rules={{prefix='0',lengths='10',ranges={},departments={'Sales'},routes={{trunk_id='one',strip=1,prepend='+27',caller_id='+27210000003'},{trunk_id='two',strip=1,prepend='+27',caller_id=''}}}},
    inbound_rules={{rule_id='incoming-one',trunk_id='one',condition='BasedOnDID',number='+27210000001',enabled=true,hours={type='AllHours'},office={type='Extension',number='200',external=''}}},
    ring_groups={},receptionists={},scripts={},queues={{number='300',uuid='fixture-queue',timeout=10,intro='',destination={type='Extension',number='200'},callback_mode='request',callback_prefix='',ring_timeout=10,wrap_up=2,members={{number='100',agent_uuid='00000000-0000-4000-a000-000000000077',status='LoggedIn'}}}}}
config.users['100'].queue_status='LoggedIn'
local function fixture()
    return {config=copy(config),active=true,gateways={
        [gateway1]={domain=domain,enabled='true',register='false',from_domain='provider-one.example.invalid',proxy='provider-one.example.invalid:5060',profile='external',register_transport='udp',state='NOREG'},
        [gateway2]={domain=domain,enabled='true',register='false',from_domain='provider-two.example.invalid',proxy='provider-two.example.invalid:5060',profile='external',register_transport='udp',state='NOREG'}},
        variables={domain_uuid=domain,destination_number='0123456789',sip_auth_username='auth100',sip_auth_realm=config.realm,uuid='00000000-0000-4000-a000-000000000010'},
        now=1000,api_calls={},waits={},responses={{cause='NORMAL_TEMPORARY_FAILURE',protocol='sip:503'},{cause='SUCCESS',protocol='sip:200'}},bridges={},bridge_timeouts={},transfers={},released=false}
end
local function environment(f)
    local s={variables=f.variables,alive=true}
    function s:ready()return self.alive end
    function s:getVariable(key)return self.variables[key]end
    function s:setVariable(key,value)self.variables[key]=value end
    function s:hangup(cause)f.hangup=cause;self.alive=false end
    function s:answer()f.answers=(f.answers or 0)+1 end
    function s:streamFile()end
    function s:playAndGetDigits(min,max,tries,timeout,terminators,prompt,bad,regex,var,digit_timeout)
        if prompt=='phrase:openweb_callback_intro' then
            f.intro_reads=(f.intro_reads or 0)+1;f.intro_args={min,max,tries,timeout,terminators,prompt,bad,regex,var,digit_timeout}
            f.intro_visit_state={self.variables.cc_agent_bridged,self.variables.cc_agent_found,self.variables.cc_exit_key,self.variables.cc_exit_keys}
            local delay=f.intro_delay or 0;local budget=f.scheduled_seconds or delay
            f.now=f.now+math.min(delay,budget);return delay>=budget and 'D' or f.intro_digit or ''
        end
        f.prompt_timeout=timeout;f.now=f.now+(f.prompt_delay or 0);return f.answer_digit or '1'
    end
    function s:transfer(number,_,realm)f.transfers[#f.transfers+1]={number=number,realm=realm}end
    function s:execute(application,data)
        if application=='callcenter' then
            f.waits[#f.waits+1]={seconds=f.scheduled_seconds,cursor=self.variables.cc_last_agent_tier_position,exit_keys=self.variables.cc_exit_keys}
            if f.wait_error then error('Injected native failure') end
            f.now=f.now+(f.wait_answer and 2 or f.scheduled_seconds)
            if f.wait_answer then self.variables.cc_agent_bridged='true' end
        elseif application=='phrase' and data=='openweb_callback_intro' then f.now=f.now+(f.intro_delay or 0)
        elseif application=='record_session' then f.recordings=(f.recordings or 0)+1
        elseif application=='lua' and data=='app.lua voicemail' then
            f.voicemail={id=self.variables.voicemail_id,action=self.variables.voicemail_action,domain=self.variables.domain_uuid,realm=self.variables.domain_name}
        elseif application=='bridge' then
            f.bridges[#f.bridges+1]=data
            f.bridge_timeouts[#f.bridges]=self.variables.call_timeout
            f.bridge_ignore_early_media=f.bridge_ignore_early_media or {}
            f.bridge_ignore_early_media[#f.bridges]=self.variables.ignore_early_media
            local response=f.responses[#f.bridges] or {cause='NO_ANSWER',protocol='sip:408'}
            f.now=f.now+(response.delay or 0)
            self.variables.originate_disposition=response.cause
            self.variables.last_bridge_proto_specific_hangup_cause=response.protocol
            self.variables.sip_invite_failure_status=response.received or ''
            if response.answered then self.variables.openweb_provider_answered='true' end
            if response.disconnect then self.alive=false end
        end
    end
    local db={}
    function db:query(sql,params,callback)
        if sql:find("to_regclass('v_pbx_sip_domains')",1,true)then callback({relation=f.owned_aliases and 'v_pbx_sip_domains' or nil})
        elseif sql:find('from v_domains d where',1,true)then
            if params.domain==f.config.realm then callback({domain_uuid=domain,domain_name=f.config.realm,domain_enabled=f.active and 'true' or 'false',suspended='false'})end
        elseif sql:find('select a.sip_domain',1,true)then for _,alias in ipairs(f.owned_aliases or {})do callback({sip_domain=alias})end
        elseif sql:find('r.config,(d.domain_enabled',1,true) then callback({config='fixture-config',allowed=f.active})
        elseif sql:find('from v_call_center_agents',1,true) then if not f.native_foreign then callback({ok=1})end
        elseif sql:find('select 1 as ok from v_pbx_jobs',1,true) and sql:find('agent_number=:number',1,true) then if f.reserved then callback({ok=1})end
        elseif sql:find('insert into v_pbx_queue_tickets',1,true) then
            if not f.capacity_full then callback({joined=f.now}) end
        elseif sql:find('update v_pbx_queue_tickets',1,true) then
            if sql:find("set state='callback'",1,true) then f.queue_callback=(f.queue_callback or 0)+1 else f.queue_finished=(f.queue_finished or 0)+1 end
        elseif sql:find('insert into v_pbx_jobs',1,true) then if not f.callback_refused then f.callback_created=params;callback({job_uuid=params.id}) end
        elseif sql:find('select 1 as ok from v_pbx_jobs',1,true) and sql:find('target_number=:target',1,true) then f.callback_lookup=params;if f.callback_existing then callback({ok=1}) end
        elseif sql:find('from v_gateways',1,true) then
            local native=f.gateways[params.id]
            if native and native.domain==(params.domain or params.d) and callback then callback(native) end
        elseif sql:find('insert into v_pbx_mobile_push_calls',1,true) then
            f.wake_targets=f.wake_targets or {};f.wake_targets[#f.wake_targets+1]=params.extension
            if f.push_configured then callback({request_uuid='fixture-wake'}) end
        elseif sql:find('from v_pbx_mobile_devices',1,true) then
            if sql:find("c.project_id='webpush'",1,true) then if f.push_configured and params.domain==domain then callback({ok=1}) end
            elseif f.mobile_active and params.domain==domain then callback({extension_uuid='mobile-fixture-extension'}) end
        elseif sql:find("set result='calling'",1,true) then if f.audit_claim then callback({audit_uuid=params.id}) end
        elseif sql:find('set result=:result',1,true) then f.audit_result=params.result
        elseif sql:find('select 1 as ok from v_pbx_jobs where job_uuid',1,true) and sql:find('lease_until>now()',1,true) then if f.callback_claim then callback({ok=1}) end
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
        f.api_calls[#f.api_calls+1]={command=command,data=data}
        if command=='create_uuid' then return '00000000-0000-4000-a000-000000000088'
        elseif command=='sched_api' then f.scheduled_seconds=tonumber(data:match('^%+(%d+)'));return f.schedule_error and '-ERR' or '+OK Added: 8'
        elseif command=='sofia' then
            local id=data:match('status gateway (.+)')
            local native=f.gateways[id]
            return native and ('State\t'..native.state..'\nStatus\t'..(native.status or 'UP')..'\n') or '-ERR Gateway not found'
        elseif command=='sofia_contact' then return f.offline and 'error/user_not_registered' or 'sofia/internal/sip:fixture@127.0.0.1:15060'
        elseif command=='show' then return 'fixture-channels'
        elseif command=='strftime_tz' then return '1_09:00_2026-10-05'
        elseif command=='uuid_exists' then return f.source_gone and 'false' or 'true'
        elseif command=='uuid_getvar' then
            if data:match(' domain_uuid$') then return f.source_foreign and '00000000-0000-4000-a000-000000000099' or domain end
            if data:match(' queue_extension$') then return f.source_queue or '300' end
            return f.variables[data:match(' ([^ ]+)$')] or '_undef_'
        elseif command=='callcenter_config' and data:match('^agent list ') then
            return 'name|state|status|ready_time|last_bridge_end|wrap_up_time|external_calls_count|\n00000000-0000-4000-a000-000000000077|Waiting|Available|0|0|0|0|'
        end
        return '+OK'
    end
    local fake_os=setmetatable({time=function()return f.now end},{__index=os})
    local env=setmetatable({os=fake_os,session=s,scripts_dir=base,storage_dir='/nonexistent-fixture-storage',argv={'00000000-0000-4000-a000-000000000030'}},{__index=_G})
    -- Nested helpers must share this isolated runtime environment as well.
    env.loadfile=function(path)if path:find('/directory/contact_realms.lua',1,true)then path='app/switch/resources/scripts/app/xml_handler/resources/scripts/directory/contact_realms.lua'end;return loadfile(path,'t',env)end
    env.dofile=function(path)return env.loadfile(path)()end
    env.require=function(name)
        if name=='resources.functions.database' then return {new=function()return db end} end
        if name=='resources.functions.lunajson' then return {decode=function(value)return value=='fixture-channels' and (f.channels or {rows={}}) or f.config end,encode=function(value)f.output=value;return 'fixture-output'end} end
        if name=='resources.functions.config' then return {} end
        error('Unexpected dependency '..name)
    end
    env.freeswitch={API=function()return api end,consoleLog=function(_,message)f.log=message end,Session=function(dial)f.agent_dial=dial;return s end}
    env.stream={write=function()end}
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
        and f.bridges[1]:find('{openweb_scope_origin=100,openweb_scope_target=100,originate_timeout=60,progress_timeout=60}[leg_timeout=60,',1,true)
        and f.bridges[2]:find('{openweb_scope_origin=100,openweb_scope_target=100,originate_timeout=60,progress_timeout=60}[leg_timeout=60,',1,true),
        'Inherited user timeout '..inherited..' cannot shorten or remove the bounded provider window')
end
f=fixture();f.config.users['100'].profiles.Available.timeout=1;f.config.users['100'].profiles.Available.available.NoAnswer={internal_inactive=true,all={type='External',number='',external='0123456789'}}
f.responses={{cause='NO_ANSWER',protocol='sip:408'},{cause='SUCCESS',protocol='sip:200'}};run(f,'user','100')
check(#f.bridges==2 and f.bridge_timeouts[1]=='1' and f.bridges[1]:find('leg_timeout=1]user/',1,true)
    and f.bridge_timeouts[2]=='60' and f.bridges[2]:find('{openweb_scope_origin=100,openweb_scope_target=100,originate_timeout=60,progress_timeout=60}[leg_timeout=60,',1,true),
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
local function mailbox_fixture()
    local item=fixture()
    item.config.users['200'].voicemail_enabled=true
    for _,reason in ipairs({'NotRegistered','NoAnswer','Busy'}) do
        item.config.users['200'].profiles.Available.available[reason]={internal_inactive=true,all={type='VoiceMail',number='200'}}
    end
    return item
end
f=mailbox_fixture();f.offline=true;run(f,'user','200')
check(#f.bridges==0 and f.answers==1 and f.voicemail and f.voicemail.id=='200' and f.voicemail.action=='save',
    'Offline extension starts the native voicemail recording action instead of answering and immediately returning')
check(f.voicemail.domain==domain and f.voicemail.realm==config.realm,'Voicemail keeps the called tenant domain')
local voicemail_call=f.voicemail
for _,cause in ipairs({'NO_ANSWER','USER_BUSY'}) do
    f=mailbox_fixture();f.responses={{cause=cause,protocol='sip:480'}};run(f,'user','200')
    check(#f.bridges==1 and f.voicemail and f.voicemail.action=='save' and f.voicemail.id=='200',
        cause..' forwarding reaches the called user mailbox recording action')
end
f=mailbox_fixture();f.config.users['200'].voicemail_enabled=false;f.offline=true;run(f,'user','200')
check(not f.voicemail and not f.answers and f.hangup=='NO_ANSWER','Disabled voicemail is not answered or recorded')
f=fixture();f.config.users['100'].voicemail_enabled=true;run(f,'voicemail_login')
check(f.voicemail and f.voicemail.action=='check' and f.voicemail.id=='100','Mailbox login retains the native own-mailbox management action without a PIN')

-- Run the actual native dispatcher, replacing database/audio/filesystem I/O.
-- This catches a producer/consumer action mismatch rather than merely asserting
-- the wrapper string. No recordings, notifications or database rows are created.
local function native_voicemail(call)
    local result={greetings=0,recordings=0,inserts=0,notifications=0,emails=0}
    local vars={voicemail_id=call.id,voicemail_action=call.action,domain_uuid=call.domain,domain_name=call.realm,
        uuid='00000000-0000-4000-a000-000000000040',caller_id_name='Synthetic Caller',caller_id_number='100'}
    local s={}
    function s:ready()return true end
    function s:getVariable(key)return vars[key]end
    function s:setVariable(key,value)vars[key]=value end
    function s:answer()end
    function s:sleep()end
    function s:execute()end
    function s:setInputCallback()end
    local db={}
    function db:query(sql,params,callback)
        if sql:find('INSERT INTO v_voicemail_messages',1,true) then
            assert(params.domain_uuid==call.domain and params.voicemail_uuid=='00000000-0000-4000-a000-000000000041','Wrong voicemail destination')
            result.inserts=result.inserts+1
        elseif sql:find('FROM v_voicemails',1,true) and sql:find('voicemail_enabled = true',1,true) then
            assert(not sql:find('voicemail_password',1,true),'Native mailbox lookup still reads a retired PIN')
            assert(params.domain_uuid==call.domain and params.voicemail_id==call.id,'Wrong mailbox lookup')
            callback({voicemail_uuid='00000000-0000-4000-a000-000000000041',voicemail_mail_to='',voicemail_local_after_forward='true'})
        elseif sql:find('SELECT voicemail_id FROM',1,true) then callback({voicemail_id=call.id})
        end
    end
    function db:release()result.released=true end
    local fake_os=setmetatable({time=function()return f.now end},{__index=os})
    local env=setmetatable({os=fake_os,session=s,argv={'voicemail'},debug={},temp_dir='/nonexistent-fixture-storage',os={remove=function()error('Unexpected filesystem deletion')end}}, {__index=_G})
    env.freeswitch={API=function()return {execute=function(_,cmd)return cmd=='strepoch' and '123' or 'fixture-time'end}end,consoleLog=function()end}
    env.settings=function()return {switch={voicemail={dir='/nonexistent-fixture-storage'}},voicemail={storage_type={text='file'}}}end
    env.play_greeting=function()result.greetings=result.greetings+1 end
    env.record_message=function()result.recordings=result.recordings+1;env.message_length=5;env.start_epoch=123 end
    env.file_size=function()return 8000 end
    env.file_exists=function()return false end
    env.mkdir=function()end
    env.message_waiting=function()result.notifications=result.notifications+1 end
    env.send_email=function()result.emails=result.emails+1 end
    env.require=function(name)
        if name=='resources.functions.database' then return {new=function()return db end}end
        if name:match('^resources%.functions%.') or name:match('^app%.voicemail%.resources%.functions%.') then return {} end
        error('Unexpected native voicemail dependency '..name)
    end
    assert(loadfile('app/switch/resources/scripts/app/voicemail/index.lua','t',env))()
    return result
end
local saved=native_voicemail(voicemail_call)
check(saved.greetings==1 and saved.recordings==1,'Routed offline voicemail executes the actual native greeting and recording dispatcher')
check(saved.inserts==1 and saved.notifications==1 and saved.emails==1 and saved.released,
    'Native voicemail recording reaches message indexing and notification dispatch without live I/O')
local invalid=copy(voicemail_call);invalid.action='leave';local ignored=native_voicemail(invalid)
check(ignored.greetings==0 and ignored.recordings==0 and ignored.inserts==0 and ignored.released,
    'Regression fixture reproduces the old unsupported action returning without a greeting or message')
local function plan(f,number)
    local env=environment(f);env.argv={domain,'100',number or '0123456789'}
    assert(loadfile(base..'/app/pbx_setup/core_call_plan.lua','t',env))();return f.output
end
f=fixture();local explanation=plan(f)
check(explanation.registered and explanation.provider=='one' and explanation.routes[1].number=='+27123456789','First-call plan uses ordinary caller restrictions, registration and rewritten provider route')
f=fixture();f.gateways[gateway1].enabled='false';check(plan(f).provider=='two','First-call plan identifies available ordered backup rather than disabled primary')
f=fixture();check(plan(f,'300').error~=nil,'First-call test cannot call an internal queue as an outside number')
f=fixture();f.config.calling_rules={emergency_numbers={'112'},emergency_routes={{trunk_id='one'}}};check(plan(f,'112').error~=nil,'First-call wizard rejects emergency numbers')
f=fixture();f.active=false;check(plan(f).error~=nil,'Suspended tenant cannot produce a first-call plan')
local function first_test(f)
    local env=environment(f);env.argv={domain,'one','100','0123456789','00000000-0000-4000-a000-000000000061'}
    assert(loadfile(base..'/app/pbx_setup/core_call_test.lua','t',env))()
end
f=fixture();first_test(f);check(not f.agent_dial,'First-call worker cannot execute an unclaimed or replayed audit request')
f=fixture();f.audit_claim=true;first_test(f)
check(f.agent_dial and f.agent_dial:find('absolute_timeout=180',1,true) and f.agent_dial:find('}sofia/',1,true) and f.audit_result=='finished','First-call worker bounds lifetime and calls one registered phone before ordinary outbound handling')
f=fixture();f.audit_claim=true;f.gateways[gateway1].enabled='false';first_test(f);check(not f.agent_dial and f.audit_result=='failed','Changed provider selection prevents first-call worker ringing a phone')
local function agent(f)
    f.config.users['100'].extension_uuid='00000000-0000-4000-a000-000000000062'
    f.variables.openweb_agent_number='100';f.variables.openweb_queue_number='300';f.variables.loopback_leg=f.variables.loopback_leg or 'B'
    f.variables.other_loopback_leg_uuid='00000000-0000-4000-a000-000000000063';f.variables.openweb_queue_source=f.variables.openweb_queue_source or '00000000-0000-4000-a000-000000000064'
    assert(loadfile(base..'/app/pbx_setup/core_agent.lua','t',environment(f)))()
end
f=fixture();f.push_configured=true;agent(f)
check(#f.bridges==1 and #f.wake_targets==1 and f.wake_targets[1]==f.config.users['100'].extension_uuid,'Native queue wrapper wakes and rings only the selected assigned agent')
check(f.bridges[1]:find('user/auth100@',1,true) and not f.voicemail and f.variables.openweb_mobile_wake_targets==f.config.users['100'].extension_uuid,'Selected queue delivery keeps cancellable target identity and bypasses user voicemail forwarding')
for _,change in ipairs({'source_foreign','source_gone'}) do f=fixture();f[change]=true;agent(f);check(#f.bridges==0 and not f.wake_targets,'Queue wrapper rejects '..change..' source before any push') end
f=fixture();f.source_queue='999';agent(f);check(#f.bridges==0,'Queue wrapper rejects another queue caller')
f=fixture();f.variables.loopback_leg='A';agent(f);check(#f.bridges==0,'Ordinary SIP or wrong loopback leg cannot invoke selected-agent delivery')
f=fixture();f.config.users['100'].profiles.Available.away={External={all={type='VoiceMail',number='100'}}};f.config.users['100'].profiles.Available.queue_status='0';agent(f);check(#f.bridges==0 and not f.voicemail,'Explicit queue logout prevents stale selected-agent delivery')
f=fixture();f.config.users['100'].profiles.Available.away={External={all={type='VoiceMail',number='100'}}};f.config.users['100'].queue_status='LoggedOut';agent(f);check(#f.bridges==1 and not f.voicemail,'Explicit profile login rings the queue phone directly without personal forwarding')
f=fixture();f.config.queues[1].members[1].supervisor_break=true;agent(f);check(#f.bridges==0 and not f.wake_targets,'Supervisor break prevents selected-agent push')
f=fixture();f.variables.openweb_callback_job='00000000-0000-4000-a000-000000000030';agent(f);check(#f.bridges==0,'Expired or unclaimed callback cannot wake an agent')
f=fixture();f.variables.openweb_callback_job='00000000-0000-4000-a000-000000000030';f.callback_claim=true;agent(f);check(#f.bridges==1,'Current owned callback lease allows selected-agent delivery')
f=fixture();f.variables.cc_member_session_uuid='00000000-0000-4000-a000-000000000065';agent(f)
check(f.bridges[1]:find(f.variables.cc_member_session_uuid,1,true) and not f.bridges[1]:find(f.variables.openweb_queue_source,1,true),'Queue answer accounting uses native selected member rather than stale shared contact caller')
f=fixture();f.variables.cc_member_session_uuid='invalid';agent(f);check(#f.bridges==0,'Invalid native selected member never falls back to a stale shared caller')
local contact_module=assert(loadfile(base..'/app/pbx_setup/core_agent_contact.lua'))()
local dial=contact_module.dial(domain,config.realm,{number='100'},{number='300',ring_timeout=10},'${uuid}',nil,'${openweb_call_internal}')
check(dial and dial:find('openweb_queue_source=${uuid}',1,true) and dial:find('openweb_call_internal=${openweb_call_internal}',1,true),'Shared push contact defers caller identity and recording origin to native member expansion')
check(not contact_module.dial(domain,config.realm,{number='100'},{number='300',ring_timeout=10},'${arbitrary}'),'Native contact refuses arbitrary variable interpolation')
f=fixture();f.config.ring_groups={{number='400',uuid='fixture-group',strategy='Hunt',timeout=7,members={{number='100'},{number='200'}},destination={type='Extension',number='200'}}};f.responses={{cause='NO_ANSWER'},{cause='SUCCESS'}};f.variables.call_timeout='1';run(f,'group','400')
check(#f.bridges==2 and f.bridges[1]:find('user/auth100@',1,true) and f.bridges[2]:find('user/auth200@',1,true),'Ordered ring group reaches the next member only after the first unanswered attempt')
check(f.bridge_timeouts[1]=='7' and f.bridge_timeouts[2]=='7' and #f.transfers==0,'Ordered ring group keeps each bounded ring window and stops after answer')
f=fixture();f.config.ring_groups={{number='400',uuid='fixture-group',strategy='RingAll',timeout=9,members={{number='100'},{number='200'}},destination={type='Extension',number='200'}}};f.variables.call_timeout='1';f.responses={{cause='SUCCESS'}};run(f,'group','400')
check(#f.bridges==1 and f.bridges[1]:find('user/auth100@',1,true) and f.bridges[1]:find(',[',1,true) and f.bridges[1]:find('user/auth200@',1,true) and f.bridge_timeouts[1]=='9','Simultaneous ring group shares one bounded attempt despite inherited timeout')
f=fixture();f.channels={rows={{uuid='busy-leg',presence_id='auth200@'..config.realm}}};f.config.users['200'].profiles.Available.available.Busy={internal_inactive=true,all={type='Extension',number='100'}};run(f,'user','200')
check(#f.bridges==0 and f.transfers[1].number=='100','PBX busy detection forwards before originating a second call')
f=fixture();f.channels={rows={{uuid='busy-leg',presence_id='auth200@'..config.realm}}};f.config.users['200'].profiles.Available.busy_detection='UsePhoneStatus';f.responses={{cause='SUCCESS'}};run(f,'user','200')
check(#f.bridges==1,'Phone-status busy detection leaves call waiting/rejection to the handset')
for _,mode in ipairs({'disabled','request','offer'})do
 f=fixture();f.config.queues[1].callback_mode=mode;f.config.queues[1].callback_after=3;run(f,'queue','300')
 check(f.now==1010 and f.transfers[1].number=='200','Queue '..mode..' falls back at the original ten-second deadline')
 check(f.queue_finished==1 and f.variables.openweb_queue_limit_token=='' and f.variables.cc_exit_keys=='','Queue '..mode..' leaves one finished visit and no live guard')
 if mode=='offer' then check(#f.waits==2 and f.waits[1].seconds==3 and f.waits[2].seconds==7,'Declined callback offer cannot restart the native max wait')end
end
f=fixture();f.config.queues[1].callback_mode='automatic';f.config.queues[1].callback_after=3;run(f,'queue','300')
check(f.now==1003 and f.callback_created and f.callback_created.target=='100' and f.hangup=='NORMAL_CLEARING','Automatic callback is saved at the timed offer deadline')
f=fixture();f.config.queues[1].callback_mode='offer';f.config.queues[1].callback_after=8;f.prompt_delay=2;run(f,'queue','300')
check(f.prompt_timeout==2000 and f.now==1010 and #f.waits==1,'Callback prompt is capped by the original remaining wait budget')
f=fixture();f.config.queues[1].callback_mode='disabled';f.wait_answer=true;run(f,'queue','300')
check(f.now==1002 and #f.transfers==0 and f.hangup=='NORMAL_CLEARING','Answered queue call completes without timeout forwarding')
f=fixture();f.wait_error=true;run(f,'queue','300')
check(f.queue_finished==1 and f.variables.openweb_queue_limit_token=='' and f.hangup=='NORMAL_TEMPORARY_FAILURE','Native queue exception cancels its scheduled guard and closes the durable visit')
f=fixture();f.capacity_full=true;run(f,'queue','300');check(#f.waits==0 and f.transfers[1].number=='200','Full queue routes without starting any agent or timer')
f=fixture();f.config.queues[1].strategy='HuntRandomStart';f.config.queues[1].polling_mode='random_start';f.config.queues[1].callback_mode='offer';f.config.queues[1].callback_after=3;run(f,'queue','300')
check(#f.waits==2 and f.waits[1].cursor==f.waits[2].cursor and f.variables.cc_last_agent_tier_position=='','Random-start cursor belongs to one caller and survives callback slices until cleanup')
local function guard(f)
 local env=environment(f);assert(loadfile(base..'/app/pbx_setup/index.lua','t',env))({'pbx_setup','queue_limit',domain,'300',f.variables.uuid,'00000000-0000-4000-a000-000000000088'})
 for _,v in ipairs(f.api_calls)do if v.command=='uuid_recv_dtmf' then return v end end
end
f=fixture();f.variables.openweb_queue_limit_token='00000000-0000-4000-a000-000000000088';f.variables.openweb_queue_waiting='true';check(guard(f).data==f.variables.uuid..' D','Scheduled deadline exits only the owned currently waiting caller')
for _,change in ipairs({'source_foreign','source_gone','answered','found','stale'})do
 f=fixture();f.variables.openweb_queue_limit_token='00000000-0000-4000-a000-000000000088';f.variables.openweb_queue_waiting='true'
 if change=='answered' then f.variables.cc_agent_bridged='true' elseif change=='found' then f.variables.cc_agent_found='true' elseif change=='stale' then f.variables.openweb_queue_limit_token='old-visit' else f[change]=true end
 check(not guard(f),'Scheduled guard refuses '..change..' caller')
end
f=fixture();f.config.queues[1].callback_mode='automatic';f.config.queues[1].callback_after=3;f.intro_delay=4;run(f,'queue','300');check(f.now==1004 and f.callback_created and #f.waits==0,'An introduction crossing the callback threshold saves the due job before starting another wait')
f=fixture();f.intro_digit='2';f.intro_delay=2;run(f,'queue','300')
check(f.callback_created and f.callback_created.target=='100' and f.callback_created.internal=='true' and f.callback_created.request=='call/'..f.variables.uuid and f.hangup=='NORMAL_CLEARING' and #f.waits==0,'Early invitation key uses the owned internal caller and existing durable request path')
check(f.intro_args[1]==1 and f.intro_args[2]==1 and f.intro_args[3]==1 and f.intro_args[4]==1 and f.intro_args[5]=='D' and f.intro_args[7]=='' and f.intro_args[8]=='^2$' and f.intro_args[9]=='' and f.intro_args[10]==1,'Invitation uses one bounded native digit read without a separate post-prompt listening window')
check(f.queue_callback==1 and f.queue_finished==1 and f.variables.openweb_queue_limit_token=='' and f.variables.cc_exit_keys=='','Early callback marks one callback visit and clears its live deadline guard')
for _,digit in ipairs({'','9','D'})do
 f=fixture();f.intro_digit=digit;f.intro_delay=4;run(f,'queue','300')
 check(not f.callback_created and f.now==1010 and #f.waits==1 and f.waits[1].seconds==6,'No or invalid invitation key '..digit..' preserves the original queue deadline')
end
for _,reason in ipairs({'disabled','invalid_caller'})do
 f=fixture();f.intro_digit='2'
 if reason=='disabled' then f.config.queues[1].callback_mode='disabled' else f.variables.sip_auth_username=nil;f.variables.caller_id_number='anonymous' end
 run(f,'queue','300');check(not f.callback_created and not f.intro_reads,'Invitation cannot create a callback for '..reason)
end
f=fixture();f.intro_digit='2';f.callback_refused=true;f.intro_delay=2;run(f,'queue','300')
check(not f.callback_created and f.now==1010 and f.transfers[1].number=='200','Refused callback capacity continues through the bounded normal queue fallback')
f=fixture();f.intro_digit='2';f.callback_refused=true;f.callback_existing=true;run(f,'queue','300')
check(not f.callback_created and f.callback_lookup.domain==domain and f.callback_lookup.queue=='300' and f.callback_lookup.target=='100' and f.hangup=='NORMAL_CLEARING','Early duplicate request reuses only the same owned queue target without a second insert')
f=fixture();f.intro_delay=12;f.intro_digit='2';f.variables.cc_agent_bridged='true';f.variables.cc_agent_found='true';f.variables.cc_exit_key='2';f.variables.cc_exit_keys='old';run(f,'queue','300')
check(f.intro_visit_state[1]=='false' and f.intro_visit_state[2]=='false' and f.intro_visit_state[3]=='' and f.intro_visit_state[4]=='','Invitation guard starts with this queue visit flags, clearing a stale earlier bridge and exit')
check(not f.callback_created and f.now==1010 and #f.waits==0 and f.transfers[1].number=='200','An overlong introduction terminates at the original deadline without saving a late key')
local queue_runtime=assert(loadfile(base..'/app/pbx_setup/queue_runtime.lua'))()
local calls={};local native={execute=function(_,_,data)
 calls[#calls+1]=data
 if data:match('^agent list ')then return 'name|state|status|\n'..config.queues[1].members[1].agent_uuid..'|Receiving|On Break|'end
 if data:match('^tier add ')then return '-ERR Tier already exist!\n'end
 if data:match('^queue list tiers ')then return 'queue|agent|state|level|position\n300@'..config.realm..'|'..config.queues[1].members[1].agent_uuid..'|Active Inbound|1|1\n+OK\n'end
 return '+OK'
end}
queue_runtime.ensure(native,config,config.queues[1],domain,function()error('Existing contact must stay intact')end)
local mutation=false;for _,v in ipairs(calls)do if v:match('^queue load')or v:match('^agent set')or v:match('^agent add')then mutation=true end end
check(not mutation,'Queue initialization preserves existing active/paused agent contact, state, metrics and wrap-up')
calls={};native.execute=function(_,_,data)
 calls[#calls+1]=data
 if data:match('^agent list ')then return '-ERR Agent not found!'end
 if data:match('^agent add ')then return '-ERR Agent already exist!'end
 if data:match('^tier add ')then return '-ERR Tier already exist!'end
 if data:match('^queue list tiers ')then return 'queue|agent|state|level|position\n300@'..config.realm..'|'..config.queues[1].members[1].agent_uuid..'|Ready|1|1\n+OK\n'end
 return '+OK'
end
local created=queue_runtime.ensure(native,config,config.queues[1],domain,function()error('Concurrent winner owns initialization')end)
check(not next(created) and #calls==4,'Concurrent creation winner is never overwritten or globally reloaded')
local function status_sync(f)
 local env=environment(f);env.argv={domain,'100'};assert(loadfile(base..'/app/pbx_setup/mobile_state.lua','t',env))()
 local status;for _,v in ipairs(f.api_calls)do if v.command=='callcenter_config' then status=v.data end end;return status
end
f=fixture();f.config.users['100'].queue_status='LoggedOut';check(status_sync(f):find("'Available'",1,true),'Periodic status synchronization honors explicit profile queue login')
f=fixture();f.config.queues[1].members[1].status='LoggedOut';check(status_sync(f):find("'Logged Out'",1,true),'Periodic profile login never rejoins a queue the user left')
f=fixture();f.config.queues[1].members[1].supervisor_break=true;check(status_sync(f):find("'On Break'",1,true),'Periodic synchronization preserves supervisor pause')
f=fixture();f.reserved=true;check(status_sync(f):find("'On Break'",1,true),'Periodic synchronization preserves a callback reservation')
f=fixture();f.active=false;check(status_sync(f):find("'Logged Out'",1,true),'Suspension always wins over explicit profile queue login')
f=fixture();f.native_foreign=true;check(not status_sync(f),'Periodic synchronization never changes a foreign native agent UUID')
f=fixture();f.config.users['100'].profiles.Available.ring_mobile=true;f.config.users['100'].mobile='0123456789';f.responses={{cause='SUCCESS'}};run(f,'user','100')
check(#f.bridges==1 and f.bridges[1]:find('user/auth100@',1,true) and f.bridges[1]:find('pbx_setup mobile 100',1,true),'Personal RingMyMobile parallels the registered phone with a guarded mobile leg')
f=fixture();f.offline=true;f.config.users['100'].profiles.Available.ring_mobile=true;f.config.users['100'].mobile='0123456789';f.responses={{cause='SUCCESS'}};run(f,'user','100')
check(#f.bridges==1 and not f.bridges[1]:find('user/auth100@',1,true) and f.bridges[1]:find('pbx_setup mobile 100',1,true),'Mobile-only personal delivery bypasses NotRegistered forwarding when an ordinary route is healthy')
f=fixture();f.offline=true;f.config.users['100'].profiles.Available.ring_mobile=true;f.config.users['100'].mobile='0123456789';f.gateways[gateway1].enabled='false';f.gateways[gateway2].enabled='false';run(f,'user','100')
check(#f.bridges==0,'Offline mobile-only user never sends a call through disabled providers')
f=fixture();f.config.users['100'].profiles.Available.ring_mobile=true;f.config.users['100'].mobile='0123456789';f.config.ring_groups={{number='400',uuid='group',strategy='Hunt',timeout=8,members={{number='100'}},destination={type='None'}}};f.responses={{cause='SUCCESS'}};run(f,'group','400')
check(f.bridges[1]:find('user/auth100@',1,true) and f.bridges[1]:find('pbx_setup mobile 100',1,true),'Each ordered group member rings its phone and mobile together')
f=fixture();f.config.users['100'].profiles.Available.ring_mobile=true;f.config.users['100'].mobile='0123456789';run(f,'queue','300')
local wrapped=false;for _,v in ipairs(f.api_calls)do if v.data and v.data:find('agent set contact',1,true) and v.data:find('core_agent.lua',1,true)then wrapped=true end end
check(wrapped,'Queue RingMyMobile uses only the selected-agent wrapper, even without Web Push')
f=fixture();f.offline=true;f.config.users['100'].profiles.Available.ring_mobile=true;f.config.users['100'].mobile='0123456789';agent(f)
check(#f.bridges==1 and not f.voicemail and f.bridges[1]:find('pbx_setup mobile 100',1,true),'Selected queue mobile-only delivery bypasses personal voicemail')
f=fixture();f.variables.call_timeout='1';agent(f);check(f.bridge_timeouts[1]=='10','Selected-agent ringing overrides an inherited caller timeout')
for _,change in ipairs({'wrong_leg','source_foreign','source_gone','disabled'})do
 f=fixture();f.config.users['100'].profiles.Available.ring_mobile=true;f.config.users['100'].mobile='0123456789';f.variables.loopback_leg='B';f.variables.other_loopback_leg_uuid='00000000-0000-4000-a000-000000000063';f.variables.openweb_mobile_source='00000000-0000-4000-a000-000000000064';f.variables.openweb_mobile_timeout='9'
 if change=='wrong_leg'then f.variables.loopback_leg='A' elseif change=='disabled'then f.config.users['100'].enabled=false else f[change]=true end
 run(f,'mobile','100');check(#f.bridges==0,'Mobile helper rejects '..change..' before provider dialing')
end
f=fixture();f.config.users['100'].profiles.Available.ring_mobile=true;f.config.users['100'].mobile='0123456789';f.variables.loopback_leg='B';f.variables.other_loopback_leg_uuid='00000000-0000-4000-a000-000000000063';f.variables.openweb_mobile_source='00000000-0000-4000-a000-000000000064';f.variables.openweb_mobile_timeout='9';run(f,'mobile','100')
check(#f.bridges==2 and f.bridge_timeouts[1]=='9' and f.bridge_timeouts[2]=='9','Mobile helper uses ordinary ordered provider failover within one bounded ringing window')
f=fixture();f.owned_aliases={'phone.fixture.invalid'};f.config.sip_domains={'phone.fixture.invalid'};f.variables.sip_auth_realm='phone.fixture.invalid';run(f)
check(#f.bridges==2 and f.variables.call_direction=='outbound','Database-owned alias authenticates the canonical user and preserves ordinary outbound policy')
f=fixture();f.owned_aliases={'phone.fixture.invalid'};f.config.sip_domains={'foreign.fixture.invalid'};run(f)
check(#f.bridges==0 and f.hangup=='CALL_REJECTED','Unowned saved alias cannot authorize any contact or call')
f=fixture();f.owned_aliases={'phone.fixture.invalid'};f.variables.sip_auth_realm='foreign.fixture.invalid';run(f)
check(#f.bridges==0 and f.hangup=='CALL_REJECTED','Foreign authentication realm never grants canonical outbound identity')
f=fixture();f.owned_aliases={'phone.fixture.invalid'};f.config.sip_domains={'phone.fixture.invalid'};f.channels={rows={{uuid='owned-alias-leg',presence_id='auth200@phone.fixture.invalid'}}};f.config.users['200'].profiles.Available.available.Busy={internal_inactive=true,all={type='Extension',number='100'}};run(f,'user','200')
check(#f.bridges==0 and f.transfers[1].number=='100','Busy detection includes the exact database-owned alias identity')
f=fixture();f.owned_aliases={'phone.fixture.invalid'};f.channels={rows={{uuid='foreign-leg',presence_id='auth200@foreign.fixture.invalid'}}};f.responses={{cause='SUCCESS'}};run(f,'user','200')
check(#f.bridges==1,'Foreign alias presence cannot make an owned phone busy')
f=fixture();f.config.users['100'].profiles.Available.ring_mobile=true;f.config.users['100'].mobile='0123456789';f.config.users['100'].profiles.Available.available.NoAnswer={internal_inactive=true,all={type='Extension',number='200'}};f.responses={{cause='NO_ANSWER',protocol='sip:480'}};run(f,'user','100')
check(f.bridge_ignore_early_media[1]=='true' and f.transfers[1].number=='200','Mobile loopback early media never counts as a personal answer or suppresses NoAnswer forwarding')
f=fixture();f.config.users['100'].profiles.Available.ring_mobile=true;f.config.users['100'].mobile='0123456789';f.config.ring_groups={{number='400',uuid='group',strategy='Hunt',timeout=8,members={{number='100'}},destination={type='Extension',number='200'}}};f.responses={{cause='NO_ANSWER'}};run(f,'group','400')
check(f.bridge_ignore_early_media[1]=='true' and f.transfers[1].number=='200','Group mobile candidate remains unanswered until its actual provider leg answers')
f=fixture();f.offline=true;f.config.users['100'].profiles.Available.ring_mobile=true;f.config.users['100'].mobile='0123456789';agent(f)
check(f.bridge_ignore_early_media[1]=='true','Selected-agent mobile early media cannot seize the queue call before an actual phone answer')
check(f.bridges[1]:find('presence_id=auth100@'..config.realm,1,true),'Mobile-only leg carries its canonical target identity for busy detection')
f=fixture();f.config.users['100'].profiles.Available.ring_mobile=true;f.config.users['100'].mobile='0123456789';f.channels={rows={{uuid='existing-mobile-leg',presence_id='auth100@'..config.realm}}};agent(f)
check(#f.bridges==0,'Selected agent never starts mobile delivery during an unrelated canonical busy call')
f=fixture();f.channels={rows={{uuid='00000000-0000-4000-a000-000000000063',presence_id='auth100@'..config.realm},{uuid=f.variables.uuid,presence_id='auth100@'..config.realm}}};agent(f)
check(#f.bridges==1,'Selected-agent callback ignores only its own validated loopback legs for busy detection')
f=fixture();f.config.users['100'].profiles.Available.ring_mobile=true;f.config.users['100'].mobile='0123456789';f.variables.loopback_leg='B';f.variables.other_loopback_leg_uuid='00000000-0000-4000-a000-000000000063';f.variables.openweb_mobile_source='00000000-0000-4000-a000-000000000064';f.variables.openweb_mobile_timeout='9';f.responses={{cause='NORMAL_TEMPORARY_FAILURE',protocol='sip:503',delay=3},{cause='SUCCESS'}};run(f,'mobile','100')
check(f.bridge_timeouts[1]=='9' and f.bridge_timeouts[2]=='6' and f.bridge_ignore_early_media[1]=='true','Mobile provider failover uses only the original remaining ring window and waits for a real answer')
for _,change in ipairs({'foreign','disabled','emergency','invalid-mobile'})do
 f=fixture();f.offline=true;f.config.users['100'].profiles.Available.ring_mobile=true;f.config.users['100'].mobile='0123456789'
 if change=='foreign'then f.gateways[gateway1].domain='00000000-0000-4000-a000-000000000099';f.gateways[gateway2].domain='00000000-0000-4000-a000-000000000099'
 elseif change=='disabled'then f.config.users['100'].enabled=false
 elseif change=='emergency'then f.config.calling_rules={emergency_numbers={'0123456789'},emergency_routes={{trunk_id='one'}}}
 else f.config.users['100'].mobile='0123456789,sofia/foreign'end
 run(f,'user','100');check(#f.bridges==0,'Automatic mobile delivery refuses '..change..' before any provider originate')
end
print('PASS: '..count..' synthetic call, routing, first-call wizard and selected-agent wake runtime checks')
