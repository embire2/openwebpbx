<?php
// Real PostgreSQL policy controls. Only a newly owned fixture database is used.
require dirname(__DIR__).'/packaging/windows/public-listeners-policy.php';
$db=new PDO($argv[1]??'',null,null,[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);
if(!str_starts_with((string)$db->query('select current_database()')->fetchColumn(),'public_listener_'))throw new RuntimeException('A disposable public_listener_ database is required.');
$checks=0;function check(bool $value):void{global $checks;if(!$value)throw new RuntimeException('Public listener control failed at '.debug_backtrace(DEBUG_BACKTRACE_IGNORE_ARGS,1)[0]['line']);$checks++;}
function refused(callable $action):void{$failed=false;try{$action();}catch(RuntimeException){$failed=true;}check($failed);}
$db->exec('create table v_sip_profiles(sip_profile_uuid text primary key,sip_profile_name text,sip_profile_enabled bool);create table v_sip_profile_settings(sip_profile_uuid text,sip_profile_setting_name text,sip_profile_setting_value text,sip_profile_setting_enabled bool)');
function seed(array $profiles):void{global $db;$db->exec('truncate v_sip_profile_settings,v_sip_profiles');foreach($profiles as $name=>$settings){$q=$db->prepare('insert into v_sip_profiles values(?,?,true)');$q->execute([$name,$name]);foreach($settings as $key=>$value){$q=$db->prepare('insert into v_sip_profile_settings values(?,?,?,true)');$q->execute([$name,$key,$value]);}}}
$profiles=['internal'=>['sip-port'=>'5060','tls'=>'false','tls-only'=>'false','tls-sip-port'=>'5061'],'external'=>['sip-port'=>'5080','tls'=>'false','tls-only'=>'false','tls-sip-port'=>'5081']];
$statuses=['internal'=>"Name internal\nSIP-IP 198.18.0.1\nBIND-URL sip:mod_sofia@198.18.0.1:5060;transport=udp,tcp\n",'external'=>"Name external\nSIP-IP 198.18.0.1\nBIND-URL sip:mod_sofia@203.0.113.1:5080;maddr=198.18.0.1;transport=udp,tcp\n"];
$xml='<configuration name="switch.conf"><settings><!-- <param name="rtp-start-port" value="1000"/> --></settings></configuration>';$globals=[];$calls=[];
$api=function(string $command)use(&$statuses,&$xml,&$globals,&$calls,$db):string{$calls[]=$command;check($db->query("select current_setting('transaction_read_only')")->fetchColumn()==='on');if($command==='xml_locate configuration configuration name switch.conf')return $xml;if(str_starts_with($command,'sofia status profile '))return $statuses[substr($command,21)]??'Invalid Profile!';if(str_starts_with($command,'global_getvar '))return $globals[substr($command,14)]??'';throw new RuntimeException('Unexpected API command.');};
$run=fn()=>windows_public_listeners::snapshot($db,$api,windows_public_listeners::CORE_SHA256);
seed($profiles);$proof=$run();check(count($proof['listeners'])===4);check(array_column($proof['listeners'],'port')===[5060,5060,5080,5080]);check($proof['rtp_start']===16384&&$proof['rtp_end']===32768&&$proof['rtp_proof']==='supported_core_configured_default');check(!$db->inTransaction());
// Explicit configuration is not an in-process getter. Refuse even an override
// that repeats the stock numbers; no unproved custom-runtime claim is made.
foreach(['<param name="rtp-start-port" value="16384"/>','<param name="RTP-START-PORT" value="16384"/>','<param name="Rtp-End-Port" value="32768"/>','<param name="rtp-end-port" value="45000"/>','<param name="rtp-start-port" value="$${custom_rtp}"/>'] as $params){$xml='<configuration name="switch.conf"><settings>'.$params.'</settings></configuration>';refused($run);check(!$db->inTransaction());}
$xml='<configuration name="switch.conf"><settings/></configuration>';refused(fn()=>windows_public_listeners::snapshot($db,$api,str_repeat('0',64)));
foreach(['<!DOCTYPE x [<!ENTITY n "x">]><configuration name="switch.conf"/>','<broken','<document/>','<document><configuration name="switch.conf"/><configuration name="switch.conf"/></document>'] as $bad){$xml=$bad;refused($run);}$xml='<configuration name="switch.conf"><settings/></configuration>';
foreach(['5433','8021','8087','3389','0','65536','05060','${unsafe}','5060;reloadxml'] as $port){$p=$profiles;$p['external']['sip-port']=$port;seed($p);refused($run);}
seed($profiles);foreach(['Name external\nName external\n','SIP-IP 198.18.0.1\nSIP-IP 198.18.0.1\n','BIND-URL sip:x@198.18.0.1:5433\n','BIND-URL sip:x@198.18.0.1:5080;transport=udp;transport=tcp\n'] as $bad){$saved=$statuses['external'];$statuses['external']=str_replace('\\n',"\n",$bad);refused($run);$statuses['external']=$saved;}
$p=$profiles;$p['internal']['tls']='true';seed($p);$saved=$statuses['internal'];$statuses['internal'].="TLS-BIND-URL sips:mod_sofia@198.18.0.1:5061;transport=tls\n";$proof=$run();check(count($proof['listeners'])===5&&in_array(['address'=>'198.18.0.1','port'=>5061,'protocol'=>'TCP','tls'=>true],$proof['listeners'],true));
$p['internal']['tls-only']='true';seed($p);$statuses['internal']="Name internal\nSIP-IP 198.18.0.1\nTLS-BIND-URL sips:mod_sofia@198.18.0.1:5061;transport=tls\n";check(count($run()['listeners'])===3);
$statuses['internal']=$saved;$p=$profiles;$p['external']['sip-port']='$${custom_port}';$globals['custom_port']='5090';$statuses['external']=str_replace(':5080',':5090',$statuses['external']);seed($p);check(in_array(5090,array_column($run()['listeners'],'port'),true));
$globals['custom_port']='5433';refused($run);$globals['custom_port']='5090';
$p['external-ipv6']=['sip-port'=>'5080','tls'=>'false'];seed($p);check($run()['skipped_inactive_ipv6_profiles']===['external-ipv6']);
// Valid active loopback-only IPv6 is excluded, never called public acceptance.
$p['internal-ipv6']=['sip-port'=>'5060','tls'=>'false'];$statuses['internal-ipv6']="Name internal-ipv6\nSIP-IP ::1\nBIND-URL sip:mod_sofia@[::1]:5060;transport=udp,tcp\n";seed($p);$mixed=$run();check($mixed['skipped_loopback_profiles']===['internal-ipv6']);check(count($mixed['listeners'])===4);
seed(['internal-ipv6'=>$p['internal-ipv6']]);refused($run);seed($p);
// Duplicate rows or unsafe profile names cannot become commands.
$db->exec("insert into v_sip_profile_settings values('internal','sip-port','5060',true)");refused($run);seed(['external;reloadxml'=>['sip-port'=>'5080']]);refused($run);
check(!$db->inTransaction());
echo json_encode(['schema'=>1,'state'=>'passed','checks'=>$checks,'actual_postgresql'=>true,'read_only_policy_transactions'=>true,'native_api_double'=>true,'actual_windows_engine'=>false,'firewall_or_service_mutation'=>false],JSON_THROW_ON_ERROR),PHP_EOL;
