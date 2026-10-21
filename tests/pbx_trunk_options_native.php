<?php
/** Opt-in actual FreeSWITCH hash leases using fictional null endpoints only. */
if(PHP_SAPI!=='cli'||getenv('OPENWEB_LIVE_TRUNK_OPTIONS_TEST')!=='1')exit("Set OPENWEB_LIVE_TRUNK_OPTIONS_TEST=1 for isolated native software calls.\n");
require dirname(__DIR__).'/resources/require.php';
$directory=(PHP_OS_FAMILY==='Linux'?'/run':sys_get_temp_dir()).'/openweb-trunk-options-native-'.bin2hex(random_bytes(12));
if(!mkdir($directory,0755))throw new RuntimeException('Cannot stage native test.');chmod($directory,0755);
try {
 copy(dirname(__DIR__).'/app/pbx_setup/resources/switch/scripts/app/pbx_setup/trunk_options.lua',$directory.'/trunk_options.lua');chmod($directory.'/trunk_options.lua',0644);
 $source=<<<'LUA'
local T=dofile(STAGE..'/trunk_options.lua')
local api=freeswitch.API()
local sessions,resources={},{}
local checks=0
local stage='module'
local function ok(value,message) assert(value,message);checks=checks+1 end
local function command(c) local result=api:executeString(c):gsub('%s+$','');return result end
local function id()return command('create_uuid')end
local domain=id();local other=id();local gateway=id()
local trunk={gateway_uuid=gateway,limit=1,options={schema=1,allow_incoming=true,allow_outgoing=true,support_reinvite=true,srtp_mode='inherit',scope_department=''}}
local function usage(d,g)return tonumber(command('limit_usage hash openweb-trunk-'..d..' '..g))end
local function count(d,g,expected)
 resources[d..' '..g]={d,g}
 for i=1,50 do if usage(d,g)==expected then return true end freeswitch.msleep(20)end
 return false
end
local function make(d,t,extra)
 local contact='[origination_uuid='..id()..',process_cdr=false,no_cdr=true,leg_timeout=1,'..(extra or '')..']null/openweb-trunk-options-fixture'
 local wrapped=T.leg(d,t,contact,nil,'1000')
 local session=freeswitch.Session('{originate_timeout=2,ignore_early_media=true}'..wrapped);sessions[#sessions+1]=session;return session
end
local success,message=pcall(function()
 ok(command('module_exists mod_hash')=='true','Native hash backend not loaded')
 stage='initial_capacity';local first=make(domain,trunk)
 ok(first:ready() and count(domain,gateway,1),'First provider leg did not reserve capacity')
 local refused=make(domain,trunk)
 ok(not refused:ready() and refused:hangupCause()=='NORMAL_CIRCUIT_CONGESTION','Capacity did not refuse with retryable provider cause')
 ok(first:ready() and count(domain,gateway,1),'Refused leg disturbed active call')
 stage='tenant_isolation';local foreign=make(other,trunk)
 ok(foreign:ready() and count(other,gateway,1),'A different tenant shared capacity')
 foreign:hangup('NORMAL_CLEARING');ok(count(other,gateway,0),'Foreign slot leaked')
 first:hangup('NORMAL_CLEARING');ok(count(domain,gateway,0),'Hangup slot leaked')
 stage='failure_release';local failed=make(domain,trunk,'null_enable_auto_answer=false,')
 ok(not failed:ready() and failed:hangupCause()=='NO_ANSWER','Owned provider attempt did not fail as arranged')
 -- No polling or delayed retry here: the previous native attempt must release
 -- its slot before the caller can immediately try the next provider leg.
 ok(usage(domain,gateway)==0,'Failed attempt returned before releasing capacity')
 stage='immediate_backup';local backup=make(domain,trunk)
 ok(backup:ready() and count(domain,gateway,1),'Immediate backup attempt could not acquire released capacity')
 backup:hangup('NORMAL_CLEARING');ok(count(domain,gateway,0),'Backup slot leaked')
 stage='shared_directions';local inbound=freeswitch.Session('[origination_uuid='..id()..',process_cdr=false,no_cdr=true]null/openweb-trunk-options-inbound');sessions[#sessions+1]=inbound
 ok(inbound:ready() and T.accept(inbound,domain,trunk) and count(domain,gateway,1),'Incoming lease not acquired')
 local outgoing=make(domain,trunk)
 ok(not outgoing:ready() and outgoing:hangupCause()=='NORMAL_CIRCUIT_CONGESTION','Incoming and outgoing limits were separate')
 inbound:hangup('NORMAL_CLEARING');ok(count(domain,gateway,0),'Incoming lease leaked')
end)
for _,session in ipairs(sessions)do pcall(function()if session:ready()then session:hangup('NORMAL_CLEARING')end end)end
for _,resource in pairs(resources)do ok(count(resource[1],resource[2],0),'Owned final capacity not released')end
if not success then stream:write('{"failed_stage":"'..stage..'","checks":'..checks..'}');return end
stream:write('{"checks":'..checks..',"actual_native_hash_leases":true,"shared_incoming_outgoing":true,"release_before_failover":true,"tenant_isolation":true,"customer_calls":false}\n')
LUA;
 $source='local STAGE='.json_encode($directory,JSON_UNESCAPED_SLASHES)."\n".$source;
 file_put_contents($directory.'/run.lua',$source);chmod($directory.'/run.lua',0644);
 $response=(string)event_socket::api('lua '.$directory.'/run.lua');
 $facts=json_decode(trim($response),true);if(!is_array($facts)||($facts['checks']??0)<16||!($facts['release_before_failover']??false))throw new RuntimeException('Native trunk options checks failed: '.substr(preg_replace('/[^A-Za-z0-9 .,:_{}"\n-]/','?',trim($response)),0,500));
 echo json_encode($facts,JSON_PRETTY_PRINT).PHP_EOL;
}finally{foreach(['run.lua','trunk_options.lua']as$file)if(is_file($directory.'/'.$file))unlink($directory.'/'.$file);rmdir($directory);}
