<?php
/** SPDX-License-Identifier: AGPL-3.0-or-later. Fictional hosted-runner fixture only. */
if(PHP_SAPI!=='cli'||PHP_OS_FAMILY!=='Windows'||getenv('OPENWEB_WINDOWS_NATIVE_TEST')!=='1'||getenv('GITHUB_ACTIONS')!=='true'||getenv('RUNNER_ENVIRONMENT')!=='github-hosted'||getenv('GITHUB_REPOSITORY')!=='embire2/openwebpbx')exit(2);
function windows_native_fixture_failure_record(Throwable $error,string $inputFile,string $action,string $stage,string $programData): bool {
 try{
  $root=realpath(rtrim($programData,'/\\').'/OpenWebPBX/native-qualification');$input=realpath($inputFile);
  if($root===false||$input===false||is_link($inputFile)||!is_file($inputFile)||basename($input)!=='input.json')return false;
  $root=strtolower(rtrim(str_replace('\\','/',$root),'/'));$directory=strtolower(str_replace('\\','/',dirname($input)));
  if(dirname($directory)!==$root||!preg_match('/^[a-f0-9]{24}$/D',basename($directory)))return false;
  if(!in_array($action,['baseline','discover','cleanup','status','queue-state','job','due','voicemail-login','api','mail-seed','meeting-path-state','services-info','providers-create','cmb-setup','cmb-status','cmb-reset','cmb-quota'],true))return false;
  if(!in_array($stage,['initialization','owned_service_lookup','realm_validation','admin_permissions','config_read','users_discovery','extension_update','policy_save','cache_refresh'],true))$stage='initialization';
  $source=basename(str_replace('\\','/',$error->getFile()));
  if(!in_array($source,['windows-native-fixture.php','permissions.php','database.php','pbx_admin.php','pbx_setup.php','pbx_setup_provisioner.php','pbx_tenants.php','pbx_paths.php','pbx_mapper.php','pbx_schedule.php','pbx_operations.php','pbx_native.php','pbx_phone_auth.php','pbx_sip_domain.php','config.php','event_socket.php','cache.php'],true))$source='external_component';
  $type=basename(str_replace('\\','/',get_class($error)));if(!preg_match('/^[A-Za-z0-9_]{1,80}$/D',$type))$type='Throwable';
  $line=$error->getLine();if($line<1||$line>100000)$line=1;
  $bytes=json_encode(['schema'=>1,'error_type'=>$type,'source_basename'=>$source,'source_line'=>$line,'action'=>$action,'stage'=>$stage],JSON_THROW_ON_ERROR);
  if(strlen($bytes)>2048)return false;$stream=@fopen($input.'.'.$action.'.failure.json','xb');if($stream===false)return false;
  try{return fwrite($stream,$bytes)===strlen($bytes)&&fflush($stream);}finally{fclose($stream);}
 }catch(Throwable $ignored){return false;}
}
function windows_native_mail_response_class(?string $response): string {
 if($response===null||$response==='')return 'none';
 if(strlen($response)>65536)return 'other';
 if(str_contains($response,'Configure global outgoing mail'))return 'configuration';
 if(preg_match('/certificate verify failed|certificate verification|peer certificate|certificate.*(?:expired|hostname|name)/i',$response))return 'certificate';
 if(preg_match('/(?:could not|failed to) authenticate|authentication failed|535[ -]/i',$response))return 'authentication';
 if(preg_match('/could not connect|failed to connect|connection (?:refused|timed out)|connect\(\) failed|SMTP connect\(\) failed/i',$response))return 'connection';
 return 'other';
}
function windows_native_meeting_pg_state(PDO $db): array {
 $names=['total','active','idle','idle_in_transaction','wait_lock','meeting_select','meeting_update','meeting_insert','meeting_other','meeting_wait_lock'];
 $out=['observed'=>false,'read_only'=>false,'query_visible'=>false,'counts_capped'=>false,...array_fill_keys($names,0),'error_kind'=>'database'];
 if($db->inTransaction())return $out;
 try{
  $db->exec('begin transaction read only');$db->exec("set local statement_timeout='2000ms'");
  $row=$db->query("with own_database as (select state,wait_event_type,query,query ~* 'v_pbx_meeting(s|_members)' as meeting from pg_stat_activity where datname=current_database() and pid<>pg_backend_pid()) select count(*) as total,count(*) filter(where state='active') as active,count(*) filter(where state='idle') as idle,count(*) filter(where state like 'idle in transaction%') as idle_in_transaction,count(*) filter(where wait_event_type='Lock') as wait_lock,count(*) filter(where state='active' and meeting and query ~* '^\\s*select\\y') as meeting_select,count(*) filter(where state='active' and meeting and query ~* '^\\s*update\\y') as meeting_update,count(*) filter(where state='active' and meeting and query ~* '^\\s*insert\\y') as meeting_insert,count(*) filter(where state='active' and meeting and query !~* '^\\s*(select|update|insert)\\y') as meeting_other,count(*) filter(where meeting and wait_event_type='Lock') as meeting_wait_lock,count(*) filter(where query is null or query='<insufficient privilege>') as hidden_queries,current_setting('transaction_read_only') as read_only from own_database")->fetch(PDO::FETCH_ASSOC);
  if(!is_array($row)||($row['read_only']??'')!=='on')throw new RuntimeException('Read-only observer unavailable.');
  foreach([...$names,'hidden_queries'] as $name){$value=(string)($row[$name]??'');if(!preg_match('/^[0-9]{1,12}$/D',$value))throw new RuntimeException('Observer count unavailable.');if($name!=='hidden_queries'){$out['counts_capped']=$out['counts_capped']||(int)$value>512;$out[$name]=min(512,(int)$value);}}
  $out['observed']=true;$out['read_only']=true;$out['query_visible']=(int)$row['hidden_queries']===0;$out['error_kind']='none';$db->rollBack();
 }catch(Throwable $e){if($db->inTransaction())$db->rollBack();$out['error_kind']=$e instanceof PDOException&&(string)$e->getCode()==='57014'?'timeout':'database';}
 return $out;
}
function windows_native_queue_table(string $text): array {
 if(strlen($text)>65536)return [];$lines=preg_split('/\r?\n/',trim($text));$keys=explode('|',array_shift($lines)??'');
 if(!$keys||count($keys)>64||array_filter($keys,static fn($key)=>!preg_match('/^[a-z_]+$/D',$key)))return [];
 $out=[];foreach(array_slice($lines,0,64) as $line){$values=explode('|',$line);if(count($values)===count($keys))$out[]=array_combine($keys,$values);}return $out;
}
function windows_native_queue_snapshot(array $c,array $users,callable $owned,callable $api,string $sipCallId=''): array {
 if($sipCallId!==''&&!preg_match('/^[a-f0-9]{24}@localfixture$/D',$sipCallId))throw new RuntimeException('Only an owned peer call is observable.');
 $queues=array_values(array_filter($c['queues']??[],static fn($row)=>($row['number']??'')==='8190'));
 if(count($queues)!==1||count($users)!==4)throw new RuntimeException('Exact fictional queue required.');$queue=$queues[0];$realm=$c['realm'];
 $out=['config_matches'=>array_column($queue['members'],'number')===['8101','8102']&&($queue['native_strategy']??'')==='top-down'&&($queue['polling_mode']??'')==='native'&&($queue['timeout']??0)===8&&($queue['ring_timeout']??0)===3&&($queue['wrap_up']??0)===2&&($queue['callback_mode']??'')==='request'&&($queue['destination']['number']??'')==='8102'];
 $channels=json_decode($api('show channels as json'),true);$channelRows=is_array($channels['rows']??null)?array_slice($channels['rows'],0,64):[];
 $tiers=windows_native_queue_table($api('callcenter_config queue list tiers 8190@'.$realm));
 $membersText=$api('callcenter_config queue list members 8190@'.$realm);$members=windows_native_queue_table($membersText);$out['queue_readable']=!str_starts_with(trim($membersText),'-ERR');
 foreach(['Waiting'=>'waiting_members','Trying'=>'trying_members','Answered'=>'answered_members'] as $state=>$field)$out[$field]=count(array_filter($members,static fn($row)=>($row['state']??'')===$state));
 foreach(['expected'=>1,'other'=>2] as $label=>$index){
  $user=$users[$index];$number=$index===1?'8101':'8102';$member=array_values(array_filter($queue['members'],static fn($row)=>($row['number']??'')===$number));
  if(($user['number']??'')!==$number||count($member)!==1||($c['users'][$number]['auth_id']??null)!==$user['auth']||!is_uuid($member[0]['agent_uuid']??'')||!$owned($member[0]['agent_uuid']))throw new RuntimeException('Exact owned queue agent required.');
  $id=$member[0]['agent_uuid'];$records=windows_native_queue_table($api('callcenter_config agent list '.$id));$agent=array_values(array_filter($records,static fn($row)=>($row['name']??'')===$id));$agent=$agent[0]??[];
  $tier=array_values(array_filter($tiers,static fn($row)=>($row['agent']??'')===$id&&($row['queue']??'')==='8190@'.$realm));$tier=$tier[0]??[];
  $out[$label.'_registered']=str_starts_with(trim($api('sofia_contact '.$user['auth'].'@'.$realm)),'sofia/');
  $out[$label.'_agent_present']=$agent!==[];$out[$label.'_contact_matches']=str_ends_with($agent['contact']??'','user/'.$user['auth'].'@'.$realm);
  $out[$label.'_status']=in_array($agent['status']??'', ['Unknown','Logged Out','Available','Available (On Demand)','On Break'],true)?$agent['status']:'Unknown';
  $out[$label.'_state']=in_array($agent['state']??'', ['Unknown','Waiting','Receiving','In a queue call','Idle','Reserved'],true)?$agent['state']:'Unknown';
  $out[$label.'_tier_state']=in_array($tier['state']??'', ['Unknown','No Answer','Ready','Offering','Active Inbound','Standby'],true)?$tier['state']:'Unknown';
  $out[$label.'_tier_position']=ctype_digit((string)($tier['position']??''))?min(1000,(int)$tier['position']):0;
  $out[$label.'_tier_level']=ctype_digit((string)($tier['level']??''))?min(1000,(int)$tier['level']):0;
  $out[$label.'_ready_due']=$agent!==[]&&(int)($agent['ready_time']??0)<=time();
  $out[$label.'_wrap_due']=$agent!==[]&&(int)($agent['last_bridge_end']??0)+(int)($agent['wrap_up_time']??0)<=time();
  $u=$c['users'][$number];$profile=$u['profiles'][$u['profile']]??[];$forced=(string)($profile['queue_status']??'-1');
  $out[$label.'_policy_ready']=!empty($u['enabled'])&&empty($member[0]['supervisor_break'])&&($member[0]['status']??'')==='LoggedIn'&&($forced==='1'||$forced==='-1'&&($u['queue_status']??'')==='LoggedIn');
  $out[$label.'_busy_channels']=count(array_filter($channelRows,static fn($row)=>($row['presence_id']??'')===$user['auth'].'@'.$realm));
 }
 $out['caller_found']=false;$out['agent_bridged']=false;$out['queue_waiting']=false;$out['cancel_reason']='UNKNOWN';$out['originate_cause']='UNKNOWN';
 if($sipCallId!=='')foreach($channelRows as $row){
  $id=$row['uuid']??'';if(!is_uuid($id)||($row['context']??'')!==$realm||trim($api('uuid_getvar '.$id.' sip_call_id'))!==$sipCallId)continue;
  $out['caller_found']=true;$out['agent_bridged']=trim($api('uuid_getvar '.$id.' cc_agent_bridged'))==='true';$out['queue_waiting']=trim($api('uuid_getvar '.$id.' openweb_queue_waiting'))==='true';
  $cancel=trim($api('uuid_getvar '.$id.' cc_cancel_reason'));$out['cancel_reason']=in_array($cancel,['NONE','TIMEOUT','NO_AGENT_TIMEOUT','BREAK_OUT','EXIT_WITH_KEY'],true)?$cancel:'UNKNOWN';
  $cause=trim($api('uuid_getvar '.$id.' originate_disposition'));$out['originate_cause']=in_array($cause,['SUCCESS','NO_ANSWER','USER_BUSY','CALL_REJECTED','NORMAL_CLEARING','NORMAL_TEMPORARY_FAILURE','SUBSCRIBER_ABSENT','UNALLOCATED_NUMBER','NO_ROUTE_DESTINATION','NORMAL_UNSPECIFIED','RECOVERY_ON_TIMER_EXPIRE','LOSE_RACE','DESTINATION_OUT_OF_ORDER','ORIGINATOR_CANCEL','SERVICE_UNAVAILABLE','MEDIA_TIMEOUT','INCOMPATIBLE_DESTINATION','INVALID_NUMBER_FORMAT','NORMAL_CIRCUIT_CONGESTION'],true)?$cause:'UNKNOWN';break;
 }
 return $out;
}
$fixtureStage='initialization';
set_exception_handler(static function(Throwable $e): void {global $argv,$fixtureStage;windows_native_fixture_failure_record($e,(string)($argv[2]??''),(string)($argv[1]??''),$fixtureStage,(string)(getenv('ProgramData')?:'C:/ProgramData'));fwrite(STDERR,"Private Windows native fixture failed.\n");exit(1);});
require 'C:/OpenWebPBX/web/resources/require.php';
$path=str_replace('\\','/',$argv[2]??'');$root=pbx_paths::state().'/native-qualification/';
if(!str_starts_with($path,$root)||is_link($path)||!is_file($path))throw new RuntimeException('Private fixture input required.');
$s=json_decode(file_get_contents($path),true,128,JSON_THROW_ON_ERROR);$db=$database->db;$db->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);
if(($s['schema']??0)!==1||($s['restore_server']??false)!==true||!preg_match('/^[a-f0-9]{24}$/D',$s['scope']??''))throw new RuntimeException('Explicit disposable factory required.');
$q=static function(string $sql,array $args=[])use($db):PDOStatement{$p=$db->prepare($sql);foreach(array_values($args) as $i=>$value)$p->bindValue($i+1,$value,$value===null?PDO::PARAM_NULL:(is_bool($value)?PDO::PARAM_BOOL:(is_int($value)?PDO::PARAM_INT:PDO::PARAM_STR)));$p->execute();return $p;};
$save=static function()use(&$s,$path):void{file_put_contents($path,json_encode($s,JSON_THROW_ON_ERROR|JSON_PRETTY_PRINT));};
$identity=static function()use($q):array{return ['users'=>$q('select user_uuid,domain_uuid,username,user_email,password,salt,user_enabled from v_users order by user_uuid')->fetchAll(PDO::FETCH_ASSOC),'domains'=>$q('select * from v_domains order by domain_uuid')->fetchAll(PDO::FETCH_ASSOC)];};
$factory=static function()use($q):void{
 foreach(['v_extensions','v_pbx_tenants','v_pbx_services','v_pbx_restore','v_recordings','v_voicemail_messages','v_gateways','v_call_center_queues','v_pbx_jobs','v_pbx_media'] as $t)if((int)$q('select count(*) from '.$t)->fetchColumn()!==0)throw new RuntimeException('A separate empty factory is required.');
 if((int)$q('select count(*) from v_users')->fetchColumn()!==1||(int)$q('select count(*) from v_domains')->fetchColumn()!==1)throw new RuntimeException('A separate empty factory is required.');
};
$restoreFactoryLoginHash=static function()use(&$s,$q,$identity):void{
 $current=$identity();$before=$s['baseline'];
 if($current===$before)return;
 if(count($current['users'])!==1||count($before['users'])!==1)throw new RuntimeException('Factory administrator count changed.');
 $old=$before['users'][0]['password'];$new=$current['users'][0]['password'];$changed=$current;
 $changed['users'][0]['password']=$old;
 $a=password_get_info($old);$b=password_get_info($new);
 if($changed!==$before||$a['algoName']!=='bcrypt'||$b['algoName']!=='bcrypt'||($a['options']['cost']??0)!==12||($b['options']['cost']??0)!==10||!password_verify($s['admin_password'],$old)||!password_verify($s['admin_password'],$new))throw new RuntimeException('Unproved factory identity change.');
 $update=$q('update v_users set password=? where user_uuid=? and password=?',[$old,$before['users'][0]['user_uuid'],$new]);
 if($update->rowCount()!==1)throw new RuntimeException('Factory administrator changed concurrently.');
 $s['normal_login_bcrypt_rehash_proved']=true;$s['original_factory_hash_restored']=true;
};
$restoreGlobals=static function()use(&$s,$q,$restoreFactoryLoginHash):void{
 $restoreFactoryLoginHash();
 foreach(['v_default_settings'=>['email',$s['smtp_before']??[]],'v_sip_profile_settings'=>[null,$s['profiles_before']??[]],'v_pbx_mobile_push_config'=>[null,$s['push_before']??[]]] as $table=>[$category,$rows]){
  if($category)$q('delete from '.$table.' where default_setting_category=?',[$category]);else $q('delete from '.$table);
  foreach($rows as $r){$keys=array_keys($r);$q('insert into '.$table.'('.implode(',',$keys).') values('.implode(',',array_fill(0,count($keys),'?')).')',array_values($r));}
 }
};
$action=$argv[1]??'';
if($action==='baseline'){
 $factory();$admin=$q('select user_uuid,domain_uuid from v_users where username=?',[$s['admin_email']])->fetch(PDO::FETCH_ASSOC);if(!$admin)throw new RuntimeException('Factory administrator missing.');
 $s['baseline']=$identity();$s['factory_admin']=$admin;$s['smtp_before']=$q("select * from v_default_settings where default_setting_category='email' order by default_setting_uuid")->fetchAll(PDO::FETCH_ASSOC);
 $s['profiles_before']=$q('select * from v_sip_profile_settings order by sip_profile_setting_uuid')->fetchAll(PDO::FETCH_ASSOC);
 $s['push_before']=$q('select * from v_pbx_mobile_push_config')->fetchAll(PDO::FETCH_ASSOC);
 $s['drafts_before']=$q('select draft_uuid from v_pbx_setup_drafts')->fetchAll(PDO::FETCH_COLUMN);$save();echo "{\"factory_empty\":true}\n";exit;
}
if(!isset($s['baseline']))throw new RuntimeException('Original factory inventory is required.');
if($action==='discover'||$action==='cleanup'){
 $fixtureStage='owned_service_lookup';
 $service=$q('select s.domain_uuid,s.tenant_uuid,d.domain_name,t.home_domain_uuid from v_pbx_services s join v_domains d using(domain_uuid) join v_pbx_tenants t using(tenant_uuid) where s.service_name=? and t.owner_user_uuid=?',[$s['service_name'],$s['factory_admin']['user_uuid']])->fetch(PDO::FETCH_ASSOC);
 if($service){$s['owned']=$service;$save();}
 if($action==='discover'&&!$service)throw new RuntimeException('Normal HTTPS setup did not create its owned PBX.');
}
$owned=$s['owned']??null;
if(!$owned){if($action==='cleanup'){$restoreGlobals();foreach($q('select draft_uuid from v_pbx_setup_drafts where user_uuid=?',[$s['factory_admin']['user_uuid']])->fetchAll(PDO::FETCH_COLUMN) as $id)if(!in_array($id,$s['drafts_before'],true))$q('delete from v_pbx_setup_drafts where draft_uuid=?',[$id]);$factory();echo json_encode(['factory_empty'=>true,'owned_rows'=>0,'owned_contacts'=>0,'original_identity_preserved'=>true,'normal_login_bcrypt_rehash_proved'=>$s['normal_login_bcrypt_rehash_proved']??false,'original_factory_hash_restored'=>$s['original_factory_hash_restored']??false],JSON_THROW_ON_ERROR),PHP_EOL;exit;}throw new RuntimeException('Owned PBX is unavailable.');}
$fixtureStage='realm_validation';$domain=$owned['domain_uuid'];$realm=$owned['domain_name'];if(!is_uuid($domain)||!preg_match('/^pbx-[a-f0-9]{12}\./D',$realm))throw new RuntimeException('Fixture ownership mismatch.');
if($q('select domain_name from v_domains where domain_uuid=?',[$domain])->fetchColumn()!==$realm)throw new RuntimeException('Fixture realm mismatch.');
if($action==='meeting-path-state'){echo json_encode(windows_native_meeting_pg_state($db),JSON_THROW_ON_ERROR),PHP_EOL;exit;}
$fixtureStage='admin_permissions';$admin=$s['factory_admin'];unset($_SESSION['permissions']);$permissions=(new permissions($database,$admin['domain_uuid'],$admin['user_uuid']))->get_permissions();
if(empty($permissions['pbx_tenant_manage'])||empty($permissions['pbx_service_create']))throw new RuntimeException('The genuine factory administrator is required.');
$_SESSION=['authorized'=>true,'user_uuid'=>$admin['user_uuid'],'domain_uuid'=>$domain,'domain_name'=>$realm,'user'=>['domain_uuid'=>$admin['domain_uuid']],'permissions'=>$permissions];
$fixtureStage='config_read';$pbx=new pbx_admin($db);$c=$pbx->config();
if($action==='discover'){
 $s['realm']=$realm;$s['domain']=$domain;$s['music']=pbx_paths::storage().'/openweb-music/8000/lofi-beat-loop-schmoop.wav';
 $s['users']=[];
 $auths=['8100'=>'fixture-8100','8101'=>'8102','8102'=>'fixture-8102','8103'=>'fixture-8103'];
 $db->beginTransaction();foreach($auths as $n=>$auth){
  $fixtureStage='users_discovery';
  if(!isset($c['users'][$n]))throw new RuntimeException('Normal HTTPS users missing.');$u=&$c['users'][$n];
  $u['auth_id']=$auth;$u['contact_user']=(string)$n;
  $fixtureStage='extension_update';$q('update v_extensions set extension=? where domain_uuid=? and extension_uuid=?',[$auth,$domain,$u['extension_uuid']]);
  $password=$q('select password from v_extensions where domain_uuid=? and extension_uuid=?',[$domain,$u['extension_uuid']])->fetchColumn();
  $s['users'][]=['number'=>(string)$n,'auth'=>$auth,'password'=>$password,'extension_uuid'=>$u['extension_uuid'],'domain_uuid'=>$domain,'tone_hz'=>440+array_search($n,array_keys($auths),true)*110];
 }unset($u);
 $fixtureStage='policy_save';$q('update v_pbx_restore set config=cast(? as jsonb) where domain_uuid=?',[json_encode($c,JSON_THROW_ON_ERROR),$domain]);$db->commit();$save();
 $fixtureStage='cache_refresh';foreach($s['users'] as $u)(new cache)->delete('directory:'.$u['auth'].'@'.$realm);event_socket::api('reloadxml');echo "{\"normal_https_users_discovered\":4,\"fictional_auth_collision\":true}\n";exit;
}
if($action==='status'){
 $status=event_socket::api('sofia status profile internal');if(!preg_match('/^\s*SIP-IP\s+([0-9.]+)\s*$/m',$status,$m))throw new RuntimeException('Native profile IP unavailable.');
 $messages=$q('select m.voicemail_message_uuid,m.message_length,v.voicemail_id from v_voicemail_messages m join v_voicemails v using(voicemail_uuid,domain_uuid) where m.domain_uuid=?',[$domain])->fetchAll(PDO::FETCH_ASSOC);
 foreach($messages as &$message)$message['message_path']=pbx_paths::voicemail().'/default/'.$realm.'/'.$message['voicemail_id'].'/msg_'.$message['voicemail_message_uuid'].'.wav';unset($message);
 $codecPreferences=[];foreach($q('select extension_uuid,extension,password,absolute_codec_string from v_extensions where domain_uuid=?',[$domain])->fetchAll(PDO::FETCH_ASSOC) as $row)$codecPreferences[$row['extension']]=['extension_uuid'=>$row['extension_uuid'],'absolute_codec_string'=>$row['absolute_codec_string']??'','password_sha256'=>hash('sha256',$row['password'])];
 $mail=$q('select email_queue_uuid,email_uuid,email_status,email_retry_count,email_response from v_email_queue where domain_uuid=?',[$domain])->fetchAll(PDO::FETCH_ASSOC);
 foreach($mail as &$row){$row['response_class']=windows_native_mail_response_class($row['email_response']);unset($row['email_response']);}unset($row);
 echo json_encode(['bind'=>$m[1],'config'=>$c,'extension_codec_preferences'=>$codecPreferences,'registration_limits'=>$q('select max_registrations from v_extensions where domain_uuid=? order by extension',[$domain])->fetchAll(PDO::FETCH_COLUMN),'jobs'=>$q('select job_uuid,kind,queue_number,target_number,internal_target,request_key,state,attempts,max_attempts,last_result,call_uuid,due_at<=now() as due,expires_at<=now() as expired,lease_until<now() as lease_expired,lease_until is not null as has_lease from v_pbx_jobs where domain_uuid=? order by created_at',[$domain])->fetchAll(PDO::FETCH_ASSOC),'voicemail'=>$messages,'mail'=>$mail],JSON_THROW_ON_ERROR);exit;
}
if($action==='services-info'){
 $configuration=config::load();$host=$configuration->get('switch.event_socket.host',null)??'127.0.0.1';
 if(!in_array($host,['127.0.0.1','localhost'],true))throw new RuntimeException('A loopback-only event listener is required.');
 $external=(string)event_socket::api('sofia status profile external');
 if(!preg_match('/^\s*SIP-IP\s+([0-9.]+)\s*$/m',$external,$externalAddress)||!filter_var($externalAddress[1],FILTER_VALIDATE_IP,FILTER_FLAG_IPV4))throw new RuntimeException('The native external SIP interface is unavailable.');
 $externalPort=$q("select x.sip_profile_setting_value from v_sip_profile_settings x join v_sip_profiles p using(sip_profile_uuid) where p.sip_profile_name='external' and p.sip_profile_enabled=true and x.sip_profile_setting_name='sip-port' and x.sip_profile_setting_enabled=true limit 1")->fetchColumn();
 if(!ctype_digit((string)$externalPort)||(int)$externalPort<1024||(int)$externalPort>65535)throw new RuntimeException('The native external SIP port is unavailable.');
 echo json_encode(['external_sip'=>[$externalAddress[1],(int)$externalPort],'event_socket'=>['host'=>$host,'port'=>(int)$configuration->get('switch.event_socket.port',8021),'password'=>$configuration->get('switch.event_socket.password')],'sounds'=>(string)$configuration->get('switch.sounds.dir'),'scripts'=>(string)$configuration->get('switch.scripts.dir')],JSON_THROW_ON_ERROR);exit;
}
if($action==='providers-create'){
 if(isset($s['providers'])||count($c['trunks']))throw new RuntimeException('Use the empty owned provider fixture once.');
 $ports=array_slice($argv,3);if(count($ports)!==2||count(array_unique($ports))!==2)throw new RuntimeException('Two distinct local provider ports are required.');
 foreach($ports as $port)if(!ctype_digit($port)||(int)$port<1024||(int)$port>65535)throw new RuntimeException('Invalid local provider port.');
 $s['original_phone_tuples']=$q('select extension_uuid,extension,password from v_extensions where domain_uuid=? order by extension_uuid',[$domain])->fetchAll(PDO::FETCH_ASSOC);$s['providers']=[];$save();
 foreach($ports as $index=>$port){
  $input=['name'=>'Fictional native provider '.($index+1),'host'=>'127.0.0.1','port'=>$port,'transport'=>'udp','authentication'=>'ip','allowed_ips'=>'127.0.0.1','main_number'=>'99910000'.($index+1),'caller_id_in_from'=>'1','sip_cid_type'=>'rpid','codecs'=>'PCMU,PCMA','source_field'=>'ToUserPart','enabled'=>'1'];
  $key=$pbx->save('trunk','new',$input);$current=$pbx->config();$s['providers'][]=['trunk'=>$key,'gateway'=>$current['trunks'][$key]['gateway_uuid'],'port'=>(int)$port];$save();
 }
 $routes=[];foreach($s['providers'] as $provider)$routes[]=['trunk_id'=>$provider['trunk'],'strip'=>'2','prepend'=>'55'];
 $s['provider_rule']=$pbx->save('outbound','new',['name'=>'Fictional native failover only','prefix'=>'99','lengths'=>'5','routes'=>$routes]);
 $s['provider_incoming']=$pbx->save('incoming','new',['trunk_id'=>$s['providers'][0]['trunk'],'number'=>'999100001','office'=>'Extension:8101','enabled'=>'1']);
 $actual=$pbx->config();$rule=null;foreach($actual['outbound_rules'] as $candidate)if($candidate['rule_id']===$s['provider_rule'])$rule=$candidate;
 if(!$rule||$rule['prefix']!=='99'||$rule['lengths']!=='5'||count($rule['routes'])!==2)throw new RuntimeException('The fictional provider rule does not retain its prefix and length.');
 foreach($s['providers'] as $index=>$provider){$gateway=$q('select proxy,register,enabled,profile from v_gateways where domain_uuid=? and gateway_uuid=?',[$domain,$provider['gateway']])->fetch(PDO::FETCH_ASSOC);$route=$rule['routes'][$index];
  if(!$gateway||!in_array($gateway['register'],['false',false,'f','0',0],true)||!in_array($gateway['enabled'],['true',true,'t','1',1],true)||$gateway['proxy']!=='127.0.0.1:'.$provider['port']||$gateway['profile']!=='external'||$route['trunk_id']!==$provider['trunk']||(int)$route['strip']!==2||$route['prepend']!=='55')throw new RuntimeException('The actual native provider or number rewrite differs from the owned fixture.');}
 $save();echo json_encode(['created'=>true,'number_rewrite_verified'=>true,'local_nonregistering_providers'=>2],JSON_THROW_ON_ERROR);exit;
}
if($action==='provider-observations'){
 $number=$argv[3]??'';
 if(!in_array($number,['99100','99101','99102','99103'],true)||count($s['providers']??[])!==2)throw new RuntimeException('Only the fixed fictional provider cases may be observed.');
 require_once __DIR__.'/windows_provider_observations.php';$attempts=[];
 foreach($s['providers'] as $provider){
  $gateway=$q('select proxy,register from v_gateways where domain_uuid=? and gateway_uuid=?',[$domain,$provider['gateway']])->fetch(PDO::FETCH_ASSOC);
  if(!$gateway||!in_array($gateway['register'],['false',false,'f','0',0],true)||$gateway['proxy']!=='127.0.0.1:'.$provider['port'])throw new RuntimeException('The fictional observation provider changed.');
  $rows=$q('select state,cause,sip_status,will_retry from v_pbx_provider_attempts where domain_uuid=? and provider_uuid=? and dialled_number=? and owner_number=? order by started_at,attempt_no limit 17',[$domain,$provider['gateway'],$number,'8100'])->fetchAll(PDO::FETCH_ASSOC);
  $attempts[]=windows_provider_attempts($rows);
 }
 $actualRule=null;foreach($c['outbound_rules'] as $row)if($row['rule_id']===$s['provider_rule'])$actualRule=$row;
 if(!$actualRule)throw new RuntimeException('The owned provider rule is unavailable.');
 $raw=event_socket::api('lua app/pbx_setup/core_call_plan.lua '.$domain.' 8100 '.$number);if(strlen($raw)>65536)throw new RuntimeException('The owned runtime plan exceeds its bound.');$plan=json_decode($raw,true,32,JSON_THROW_ON_ERROR);
 if(!is_array($plan))throw new RuntimeException('The actual runtime plan did not return a JSON object.');
 $runtime=[];
 try{$probe=__DIR__.'/windows_provider_runtime.lua';if(!is_file($probe)||is_link($probe))throw new RuntimeException('The read-only native policy observer is unavailable.');
  if(str_contains($probe,"'"))throw new RuntimeException('The owned observer path cannot be quoted.');
  $rawRuntime=event_socket::api("lua '".str_replace('\\','/',$probe)."' ".$domain.' '.$number);if(strlen($rawRuntime)>8192)throw new RuntimeException('The native provider observation exceeds its bound.');$runtime=json_decode($rawRuntime,true,32,JSON_THROW_ON_ERROR);
 }catch(Throwable $ignored){} // Preserve actual SQL/plan evidence and original call failure.
 echo json_encode(['schema'=>1,'attempts'=>$attempts,'plan'=>windows_provider_plan($plan,$s['providers'],$actualRule['name']),'runtime'=>$runtime],JSON_THROW_ON_ERROR);exit;
}
if($action==='cmb-setup'){
 if(isset($s['cmb'])||count($s['providers']??[])!==2)throw new RuntimeException('The owned local providers are required.');
 foreach($s['providers'] as $provider){$row=$q('select proxy,register from v_gateways where domain_uuid=? and gateway_uuid=?',[$domain,$provider['gateway']])->fetch(PDO::FETCH_ASSOC);if(!$row||!in_array($row['register'],['false',false,'f','0',0],true)||$row['proxy']!=='127.0.0.1:'.$provider['port'])throw new RuntimeException('Only exact fictional nonregistering providers may be used.');}
 $pbx->save('outbound','new',['name'=>'Fictional callback destination','prefix'=>'0820000002','lengths'=>'10','routes'=>[['trunk_id'=>$s['providers'][1]['trunk'],'strip'=>'0','prepend'=>'']]]);
 $pbx->save('outbound','new',['name'=>'Fictional callback caller','prefix'=>'0','lengths'=>'10','routes'=>[['trunk_id'=>$s['providers'][0]['trunk'],'strip'=>'0','prepend'=>'']]]);
 $service=uuid();$identity='8001015009087';$s['cmb']=['service'=>$service,'identity'=>$identity,'caller'=>'+27820000001','destination'=>'0820000002'];
 $s['cmb_parent_existed']=is_dir(pbx_paths::storage().'/openwebpbx/call-me-back');$save();$dir=pbx_paths::storage().'/openwebpbx/call-me-back/'.$service;
 if(file_exists($dir))throw new RuntimeException('The owned prompt fixture already exists.');
 if(!mkdir($dir,0750,true))throw new RuntimeException('The owned prompt directory could not be created.');
 $sounds=(string)config::load()->get('switch.sounds.dir');if(!pbx_call_me_back::promptPackReady($sounds))throw new RuntimeException('The frozen Nathaniel callback pack is required.');
 // A frozen generic Nathaniel prompt stands in only for this fictional tenant's
 // generated-name greeting; no external voice service or real identity is used.
 if(!copy($sounds.'/openwebpbx/voices/1.0.1/call-me-back/enter-number.wav',$dir.'/greeting.wav'))throw new RuntimeException('The owned greeting could not be staged.');
 $q("insert into v_pbx_cmb_services(service_uuid,domain_uuid,name,incoming_rule_uuid,route_owner,prompt_state,prompt_sha256,enabled) values(?,?,'Fictional native callback',?,'8100','ready',?,true)",[$service,$domain,$s['provider_incoming'],hash_file('sha256',$dir.'/greeting.wav')]);
 (new pbx_call_me_back($db))->action(['cmb_action'=>'save_account','service_uuid'=>$service,'account_uuid'=>'','account_name'=>'Fictional native account','south_african_id'=>$identity,'total_minutes'=>'60','enabled'=>'1']);
 $row=$q('select account_uuid,id_hmac,id_last4,total_seconds,used_seconds,reserved_seconds from v_pbx_cmb_accounts where domain_uuid=? and service_uuid=?',[$domain,$service])->fetch(PDO::FETCH_ASSOC);
 $fixtureKey=file_get_contents(pbx_paths::key());if(strlen($fixtureKey)!==32)throw new RuntimeException('The installed identity key has an unexpected length.');
 $tenantKey=hash_hmac('sha256',"openweb-call-me-back-id/v1\0".$domain,$fixtureKey,true);$expectedHmac=hash_hmac('sha256',$identity,$tenantKey);unset($fixtureKey,$tenantKey);
 if(!$row||!hash_equals($expectedHmac,$row['id_hmac'])||$row['id_hmac']===$identity||(int)$row['total_seconds']!==3600||(int)$row['used_seconds']!==0||(int)$row['reserved_seconds']!==0)throw new RuntimeException('The owned allowance/HMAC fixture differs.');
 $s['cmb']['account']=$row['account_uuid'];$s['cmb']['original_hmac']=$row['id_hmac'];$save();echo json_encode(['created'=>true,'identity_hmac_verified'=>true,'configured_total_seconds'=>3600,'no_plaintext_identity_in_database'=>true],JSON_THROW_ON_ERROR);exit;
}
if(in_array($action,['cmb-status','cmb-reset','cmb-quota'],true)){
 $cmb=$s['cmb']??null;if(!$cmb||!is_uuid($cmb['account'])||!is_uuid($cmb['service']))throw new RuntimeException('The owned callback fixture is required.');
 if($action==='cmb-reset'){$q("update v_pbx_cmb_requests set created_at=now()-interval '2 minutes' where domain_uuid=? and service_uuid=? and state in ('completed','failed','cancelled')",[$domain,$cmb['service']]);echo '{"reset":true}';exit;}
 if($action==='cmb-quota'){$value=$argv[3]??'';if(!ctype_digit($value)||(int)$value>3600)throw new RuntimeException('Use a bounded fictional quota.');$row=$q('update v_pbx_cmb_accounts set total_seconds=used_seconds+? where domain_uuid=? and account_uuid=? and reserved_seconds=0 returning account_uuid',[(int)$value,$domain,$cmb['account']])->fetchColumn();if($row!==$cmb['account'])throw new RuntimeException('The owned quota remains reserved.');echo '{"updated":true}';exit;}
 $account=$q('select total_seconds,used_seconds,reserved_seconds,id_hmac from v_pbx_cmb_accounts where domain_uuid=? and account_uuid=? and service_uuid=?',[$domain,$cmb['account'],$cmb['service']])->fetch(PDO::FETCH_ASSOC);
 if(!$account||!hash_equals($cmb['original_hmac'],$account['id_hmac']))throw new RuntimeException('The owned identity verifier changed.');unset($account['id_hmac']);
 $request=$q('select request_uuid,state,reserved_seconds,used_seconds,last_result,connected_at is not null as answered,call_uuid,bridge_uuid from v_pbx_cmb_requests where domain_uuid=? and service_uuid=? order by created_at desc limit 1',[$domain,$cmb['service']])->fetch(PDO::FETCH_ASSOC);
 $bindings=(int)$q('select count(*) from v_pbx_cmb_bindings where domain_uuid=? and service_uuid=? and account_uuid=? and revoked_at is null',[$domain,$cmb['service'],$cmb['account']])->fetchColumn();
 echo json_encode(['account'=>$account,'request'=>$request?:null,'bindings'=>$bindings,'identity_hmac_unchanged'=>true],JSON_THROW_ON_ERROR);exit;
}
if($action==='queue-state'){
 $ownedAgent=static fn(string $id):bool=>(bool)$q('select 1 from v_call_center_agents where domain_uuid=? and call_center_agent_uuid=?',[$domain,$id])->fetchColumn();
 echo json_encode(windows_native_queue_snapshot($c,$s['users'],$ownedAgent,static fn(string $command):string=>(string)event_socket::api($command),(string)($argv[3]??'')),JSON_THROW_ON_ERROR),PHP_EOL;exit;
}
if($action==='job'){
 // Synthetic callback uses an explicit internal target. A wire caller ID is
 // never reclassified as internal. The normal C# service claims this row.
 $id=uuid();$q("insert into v_pbx_jobs(job_uuid,domain_uuid,kind,queue_number,target_number,internal_target,request_key,due_at,expires_at,max_attempts) values(?,?,'callback','8190','8100',true,?,now(),now()+interval '10 minutes',1)",[$id,$domain,'windows-native/'.$id]);echo json_encode(['job'=>$id],JSON_THROW_ON_ERROR);exit;
}
if($action==='due'){$updated=$q("update v_pbx_jobs set due_at=now() where domain_uuid=? and kind='wakeup' and state='waiting'",[$domain])->rowCount();echo json_encode(['owned_wakeup_due'=>true,'owned_wakeup_updated_count'=>$updated],JSON_THROW_ON_ERROR),PHP_EOL;exit;}
if($action==='voicemail-login'){
 $mailbox=$q('select voicemail_password from v_voicemails where domain_uuid=? and voicemail_id=? and voicemail_enabled=true',[$domain,'8103'])->fetch(PDO::FETCH_ASSOC);
 if(!$mailbox||$mailbox['voicemail_password']!==null)throw new RuntimeException('Owned PIN-free mailbox unavailable.');
 $configuration=config::load();$host=$configuration->get('switch.event_socket.host',null)??$configuration->get('event_socket.ip_address',null)??'127.0.0.1';
 if(!in_array($host,['127.0.0.1','localhost'],true))throw new RuntimeException('Only the disposable loopback event listener is permitted.');
 echo json_encode(['mailbox_number'=>'8103','voicemail_dial'=>'121','pin_free'=>true,'event_socket'=>['host'=>$host,'port'=>(int)($configuration->get('switch.event_socket.port',null)??$configuration->get('event_socket.port',null)??8021),'password'=>$configuration->get('switch.event_socket.password',null)??$configuration->get('event_socket.password',null)??'ClueCon']],JSON_THROW_ON_ERROR);exit;
}
if($action==='api'){
 $command=$argv[3]??'';
 $allowed=in_array($command,['status','show channels as json','show codecs as json','sofia status profile internal','fsctl pause_check'],true);
 foreach($s['providers']??[] as $provider)if(is_uuid($provider['gateway']??'')&&$command==='sofia status gateway '.$provider['gateway']){
  $row=$q('select proxy,register from v_gateways where domain_uuid=? and gateway_uuid=?',[$domain,$provider['gateway']])->fetch(PDO::FETCH_ASSOC);
  if($row&&in_array($row['register'],['false',false,'f','0',0],true)&&$row['proxy']==='127.0.0.1:'.$provider['port'])$allowed=true;
 }
 foreach($s['users'] as $u)foreach(['sofia_contact ','user_data '] as $prefix)if($command===$prefix.$u['auth'].'@'.$realm||$command===$prefix.$u['auth'].'@'.$realm.' param password')$allowed=true;
 if(!$allowed)throw new RuntimeException('Only owned read-only native queries are allowed.');echo event_socket::api($command);exit;
}
if($action==='mail-seed'){
 $id=uuid();$q("insert into v_email_queue(email_queue_uuid,domain_uuid,hostname,email_date,email_from,email_to,email_subject,email_body,email_status,email_retry_count,email_action_after) values(?,?,?,now(),?,?,?,?,'waiting',0,'')",[$id,$domain,gethostname(),'Tenant sender <tenant@example.invalid>','sink@example.invalid','Windows fictional queue '.$s['scope'],'Fictional localhost message']);$s['seed_mail']=$id;$save();echo json_encode(['id'=>$id],JSON_THROW_ON_ERROR);exit;
}
if($action==='cleanup'){
 $channels=json_decode(event_socket::api('show channels as json'),true,64,JSON_THROW_ON_ERROR);
 foreach($channels['rows']??[] as $row){$id=$row['uuid']??'';if(is_uuid($id)&&(($row['context']??'')===$realm||($row['presence_id']??'')!==''&&str_ends_with($row['presence_id'],'@'.$realm)))event_socket::api('uuid_kill '.$id.' NORMAL_CLEARING');}
 foreach($q('select call_center_agent_uuid from v_call_center_agents where domain_uuid=?',[$domain])->fetchAll(PDO::FETCH_COLUMN) as $id)if(is_uuid($id)){foreach($c['queues'] as $queue)event_socket::api('callcenter_config tier del '.$queue['number'].'@'.$realm.' '.$id);event_socket::api('callcenter_config agent del '.$id);}
 foreach($c['queues'] as $queue)event_socket::api('callcenter_config queue unload '.$queue['number'].'@'.$realm);
 foreach($s['users']??[] as $u)event_socket::api('sofia profile internal flush_inbound_reg '.$u['auth'].'@'.$realm);
 foreach($s['providers']??[] as $provider)if(is_uuid($provider['gateway']))event_socket::api('sofia profile external killgw '.$provider['gateway']);
 if(isset($s['original_phone_tuples'])&&$q('select extension_uuid,extension,password from v_extensions where domain_uuid=? order by extension_uuid',[$domain])->fetchAll(PDO::FETCH_ASSOC)!==$s['original_phone_tuples'])throw new RuntimeException('Fictional provider/callback tests changed phone credentials.');
 $files=$q('select file_path from v_pbx_media where domain_uuid=?',[$domain])->fetchAll(PDO::FETCH_COLUMN);

 foreach($files as $file)if(is_file($file)&&(pbx_paths::contains(pbx_paths::media().'/'.$domain,$file)||pbx_paths::contains(pbx_paths::voicemail(),$file))&&!is_link($file))unlink($file);
 foreach(['v_pbx_cmb_requests','v_pbx_cmb_bindings','v_pbx_cmb_accounts','v_pbx_cmb_services','v_pbx_cmb_audit'] as $table)$q('delete from '.$table.' where domain_uuid=?',[$domain]);
 $db->beginTransaction();
 $tables=$q("select distinct c.table_name from information_schema.columns c join information_schema.tables t using(table_schema,table_name) where c.table_schema='public' and c.column_name='domain_uuid' and c.table_name like 'v_%' and t.table_type='BASE TABLE'")->fetchAll(PDO::FETCH_COLUMN);
 foreach([$domain,$owned['home_domain_uuid']] as $d)foreach($tables as $t)if($t!=='v_domains'&&preg_match('/^v_[a-z0-9_]+$/D',$t))$q('delete from '.$t.' where domain_uuid=?',[$d]);
 foreach($q("select distinct c.table_name from information_schema.columns c join information_schema.tables t using(table_schema,table_name) where c.table_schema='public' and c.column_name='tenant_uuid' and c.table_name like 'v_%' and t.table_type='BASE TABLE'")->fetchAll(PDO::FETCH_COLUMN) as $t)if(preg_match('/^v_[a-z0-9_]+$/D',$t))$q('delete from '.$t.' where tenant_uuid=?',[$owned['tenant_uuid']]);
 foreach([$domain,$owned['home_domain_uuid']] as $d)$q('delete from v_domains where domain_uuid=?',[$d]);
 foreach($q('select draft_uuid from v_pbx_setup_drafts where user_uuid=?',[$admin['user_uuid']])->fetchAll(PDO::FETCH_COLUMN) as $id)if(!in_array($id,$s['drafts_before'],true))$q('delete from v_pbx_setup_drafts where draft_uuid=?',[$id]);
 $restoreGlobals();
 $db->commit();settings::clear_cache();
 $sofiaCache=new cache();$sofiaCache->delete('configuration:sofia.conf');$sofiaCache->delete(gethostname().':configuration:sofia.conf');
 $cleanupReloadXml=trim((string)event_socket::api('reloadxml'));
 $removeDirectory=static function(string $path)use(&$removeDirectory):void{
  if(!is_dir($path))return;if(is_link($path))throw new RuntimeException('Owned storage must be ordinary.');
  foreach(new DirectoryIterator($path) as $file){if($file->isDot())continue;if($file->isLink())throw new RuntimeException('Owned storage link refused.');if($file->isDir())$removeDirectory($file->getPathname());else unlink($file->getPathname());}rmdir($path);
 };
 if(isset($s['cmb']['service'])&&is_uuid($s['cmb']['service']))$removeDirectory(pbx_paths::storage().'/openwebpbx/call-me-back/'.$s['cmb']['service']);
 if(isset($s['cmb_parent_existed'])&&!$s['cmb_parent_existed']){$parent=pbx_paths::storage().'/openwebpbx/call-me-back';if(is_dir($parent)&&count(array_diff(scandir($parent),['.','..']))===0)rmdir($parent);}
 $removeDirectory(pbx_paths::media().'/'.$domain);$removeDirectory(pbx_paths::voicemail().'/default/'.$realm);
 $factory();if($identity()!==$s['baseline'])throw new RuntimeException('Factory administrator or domain identity changed.');
 foreach($tables as $t)if(preg_match('/^v_[a-z0-9_]+$/D',$t))foreach([$domain,$owned['home_domain_uuid']] as $d)if((int)$q('select count(*) from '.$t.' where domain_uuid=?',[$d])->fetchColumn())throw new RuntimeException('Owned rows remain.');
 foreach($s['users']??[] as $u)if(!str_starts_with(trim(event_socket::api('sofia_contact '.$u['auth'].'@'.$realm)),'error/'))throw new RuntimeException('Owned native contact remains.');
 echo json_encode(['factory_empty'=>true,'owned_rows'=>0,'owned_contacts'=>0,'original_identity_preserved'=>true,'normal_login_bcrypt_rehash_proved'=>$s['normal_login_bcrypt_rehash_proved']??false,'original_factory_hash_restored'=>$s['original_factory_hash_restored']??false,'cleanup_reloadxml'=>$cleanupReloadXml===''?'empty':(str_starts_with($cleanupReloadXml,'+OK')?'success':(str_starts_with($cleanupReloadXml,'-ERR')?'error':'other'))],JSON_THROW_ON_ERROR),PHP_EOL;exit;
}
throw new RuntimeException('Unknown native fixture operation.');
