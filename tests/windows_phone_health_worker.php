<?php
/** Actual installed Windows ESL -> native Defender -> PostgreSQL -> recovery.
 * Explicit disposable factory only. No physical phone or carrier call is made. */
$phase='preflight';$primaryFailure=null;$cleanupFailure=null;$firewallPreflight=null;
function native_health_failure(Throwable $error,string $phase):array {
 $files=['windows_phone_health_worker.php','pbx_windows_event_guard.php','pbx_windows_health_stream.php','pbx_phone_health.php','pbx_phone_health_recovery.php','event_guard_windows.php','database.php','require.php'];
 $types=['RuntimeException','PDOException','Error','TypeError','ValueError','ErrorException','JsonException','Exception'];
 $file=basename(str_replace('\\','/',$error->getFile()));$line=$error->getLine();$code=(string)$error->getCode();
 return ['phase'=>$phase,'error_type'=>in_array(get_class($error),$types,true)?get_class($error):'Exception','source_basename'=>in_array($file,$files,true)?$file:'external_component','source_line'=>max(1,min(99999,$line)),'sqlstate'=>$error instanceof PDOException&&preg_match('/^[A-Z0-9]{5}$/D',$code)?$code:'none'];
}
set_exception_handler(static function(Throwable $error)use(&$phase,&$primaryFailure,&$cleanupFailure,&$firewallPreflight):void {
 $record=['state'=>'failed','native_worker_failure'=>$primaryFailure??native_health_failure($error,$phase)];
 if($cleanupFailure!==null)$record['native_worker_cleanup_failure']=$cleanupFailure;
 if($firewallPreflight!==null)$record['native_worker_firewall_preflight']=$firewallPreflight;
 echo json_encode($record,JSON_THROW_ON_ERROR),PHP_EOL;exit(1);
});
if(PHP_SAPI!=='cli'||PHP_OS_FAMILY!=='Windows'||!in_array('--native-windows-worker',$argv,true)||getenv('GITHUB_ACTIONS')!=='true'||getenv('RUNNER_ENVIRONMENT')!=='github-hosted'||getenv('GITHUB_REPOSITORY')!=='embire2/openwebpbx')throw new RuntimeException('The disposable native Windows factory is required.');
$phase='bootstrap';
require 'C:/OpenWebPBX/web/resources/require.php';
class native_health_diagnostic_adapter extends event_guard_windows {
 public array $nativeCalls=[];
 protected function run(array $arguments):?string {
  $started=microtime(true);$raw=parent::run($arguments);$elapsed=microtime(true)-$started;
  $response=$raw===null?'unavailable':'invalid';
  if(is_string($raw)){try{$r=json_decode($raw,true,8,JSON_THROW_ON_ERROR);if(is_array($r)&&array_keys($r)===['state']&&in_array($r['state'],['absent','present','unknown'],true))$response=$r['state'];}catch(Throwable){}}
  $this->nativeCalls[]=['response'=>$response,'deadline_reached'=>$elapsed>=14.9];return $raw;
 }
}
$db=database::new()->db;$schema='health_native_'.bin2hex(random_bytes(6));$checks=0;$source='198.18.0.252';$firewall=new native_health_diagnostic_adapter();$created=false;$subscriber=null;
$check=static function(bool $v,string $why)use(&$checks):void{if(!$v)throw new RuntimeException($why);$checks++;};
$q=static function(string $sql,array $a=[])use($db):PDOStatement{$s=$db->prepare($sql);$s->execute($a);return $s;};
// Only test hooks change: registrations, instance identity, event stream and
// firewall mutation remain the actual installed production implementations.
class native_health_fault_guard extends pbx_windows_event_guard {protected function afterNativeAdd():void{throw new RuntimeException('Deliberate interruption after native Defender rule creation.');}}
try{
 $phase='firewall_preflight';
 $failState=$firewall->block_state_exact($source,'sip-auth-fail');$ipState=$firewall->block_state_exact($source,'sip-auth-ip');
 $firewallPreflight=['auth_fail_state'=>$failState,'auth_ip_state'=>$ipState,'child_calls'=>$firewall->nativeCalls];
 $check($failState==='absent'&&$ipState==='absent','The native fixture source already has a block or its exact state is unavailable.');
 $phase='factory_preflight';
 $check((int)$db->query('select count(*) from v_pbx_restore')->fetchColumn()===0,'An empty disposable factory is required.');
 $phase='schema';
 $db->exec('create schema '.$schema);$created=true;$db->exec('set search_path to '.$schema);
 $db->exec("create table v_domains(domain_uuid uuid primary key,domain_name text,domain_enabled text);create table v_users(user_uuid uuid primary key,domain_uuid uuid,user_enabled text);create table v_pbx_tenants(tenant_uuid uuid primary key,owner_user_uuid uuid,home_domain_uuid uuid,enabled bool);create table v_pbx_services(tenant_uuid uuid,domain_uuid uuid);create table v_pbx_restore(domain_uuid uuid primary key,config jsonb);create table v_extensions(extension_uuid uuid primary key,domain_uuid uuid,extension text,number_alias text,enabled text,password text);create table v_pbx_sip_domains(sip_domain text,domain_uuid uuid,enabled bool);create table v_pbx_staff_audit(audit_uuid uuid primary key,domain_uuid uuid,actor_uuid uuid,action text,target text,result text);create table v_event_guard_logs(event_guard_log_uuid uuid primary key,hostname text,log_date timestamptz,filter text,ip_address text,extension text,user_agent text,log_status text);create table v_access_control_nodes(node_cidr text,node_type text);create table v_user_logs(remote_address text,result text,timestamp timestamptz);create table v_groups(group_uuid uuid,group_name text);create table v_user_groups(user_uuid uuid,domain_uuid uuid,group_uuid uuid);create table v_group_permissions(group_uuid uuid,group_name text,domain_uuid uuid,permission_name text,permission_assigned text)");
 $db->exec(file_get_contents(dirname(__DIR__).'/app/pbx_setup/resources/phone_health.sql'));
 $phase='fixture';$domain=uuid();$owner=uuid();$tenant=uuid();$extension=uuid();$group=uuid();$realm='health-native.example.invalid';
 $q("insert into v_domains values(?,?,'true')",[$domain,$realm]);$q("insert into v_users values(?,?,'true')",[$owner,$domain]);$q('insert into v_pbx_tenants values(?,?,?,true)',[$tenant,$owner,$domain]);$q('insert into v_pbx_services values(?,?)',[$tenant,$domain]);
 $q("insert into v_extensions values(?,?,?,'1000','true','fixture-only-secret')",[$extension,$domain,'native-health-auth']);
 $c=['realm'=>$realm,'users'=>['1000'=>['enabled'=>true,'auth_id'=>'native-health-auth','extension_uuid'=>$extension]],'departments'=>[]];$q('insert into v_pbx_restore values(?,?::jsonb)',[$domain,json_encode($c,JSON_THROW_ON_ERROR)]);
 $q("insert into v_groups values(?,'native_health_owner')",[$group]);$q('insert into v_user_groups values(?,?,?)',[$owner,$domain,$group]);$q("insert into v_group_permissions values(?,'native_health_owner',null,'pbx_service_create','true')",[$group]);
 // This is explicitly synthetic verified-source history, not a real phone test.
 $q("insert into v_pbx_phone_health_contacts(domain_uuid,extension_uuid,source_address,expires_at) values(?,?,?::inet,now()+interval '5 minutes')",[$domain,$extension,$source]);
 $phase='esl_subscribe';$subscriber=new pbx_windows_health_stream();$subscriber->connect();$marker=uuid();$publisher=new pbx_windows_health_stream();
 $phase='esl_publish';
 try{
  $publisher->connect(false);$send=new ReflectionMethod(pbx_windows_health_stream::class,'send');
  // Both are explicitly synthetic native ESL events. The first reproduces the
  // W60B's numeric/private From-host and empty From-user challenge; it must not
  // mutate Defender or PostgreSQL. The genuine-failure signal then retains all
  // the existing fault/reconciliation/recovery checks below.
  foreach([['sofia::pre_register','192.168.10.20',''],['sofia::register_failure',$realm,'native-health-auth']]as[$subclass,$host,$user]){
   $send->invoke($publisher,"sendevent CUSTOM\nEvent-Name: CUSTOM\nEvent-Subclass: ".$subclass."\nOpenWeb-Health-Fixture: ".$marker."\nnetwork-ip: ".$source."\nto-host: ".$host."\nto-user: ".$user."\nuser-agent: OpenWebPBX isolated native fixture");$ack=$publisher->packet(3);$check(($ack['Content-Type']??null)==='command/reply'&&str_starts_with($ack['Reply-Text']??'','+OK'),'The real local ESL publisher did not accept the fixture event.');
  }
 }finally{$publisher->close();}
 $phase='esl_receive';$event=null;$challenge=null;$deadline=microtime(true)+4;
 while(microtime(true)<$deadline){$packet=$subscriber->packet(min(1,max(.001,$deadline-microtime(true))));if(($packet['Content-Type']??null)!=='text/event-json')continue;$candidate=json_decode($packet['body'],true,32,JSON_THROW_ON_ERROR);if(($candidate['OpenWeb-Health-Fixture']??null)!==$marker)continue;if(($candidate['Event-Subclass']??null)==='sofia::register_failure')$event=$candidate;if(($candidate['Event-Subclass']??null)==='sofia::pre_register')$challenge=$candidate;if($event!==null&&$challenge!==null)break;}
 $check(is_array($event)&&($event['Event-Subclass']??null)==='sofia::register_failure','The actual installed subscriber did not receive the fixture failure event.');
 $check(is_array($challenge)&&($challenge['to-host']??null)==='192.168.10.20','The actual installed subscriber did not receive the numeric-host fixture challenge.');$subscriber->close();
 $guard=new pbx_windows_event_guard($db,$firewall);$beforeChallengeCalls=count($firewall->nativeCalls);$beforeChallengeRows=(int)$q('select count(*) from v_event_guard_logs')->fetchColumn();
 $check($guard->consume($challenge)['status']==='ignored','A legitimate numeric-host challenge was not ignored.');
 $check(count($firewall->nativeCalls)===$beforeChallengeCalls&&(int)$q('select count(*) from v_event_guard_logs')->fetchColumn()===$beforeChallengeRows,'A challenge mutated native rules or the security ledger.');
 $phase='native_add';$fault=new native_health_fault_guard($db,$firewall);$failed=false;try{$fault->consume($event);}catch(RuntimeException$e){if($e->getMessage()!=='Deliberate interruption after native Defender rule creation.')throw$e;$failed=true;}
 $phase='ledger_intent';
 $check($failed,'The native post-mutation interruption was not reached.');$row=$q('select event_guard_log_uuid,log_status from v_event_guard_logs where ip_address=?',[$source])->fetch(PDO::FETCH_ASSOC);
 $check($row&&$row['log_status']==='windows_intent'&&!$db->inTransaction(),'The native fault lost its committed intent.');$check($firewall->block_state_exact($source,'sip-auth-fail')==='present','The actual native rule was not created.');
 $phase='ledger_reconcile';$guard=new pbx_windows_event_guard($db,$firewall);$check($guard->reconcile(),'The native intent did not reconcile.');$check($q('select log_status from v_event_guard_logs where event_guard_log_uuid=?',[$row['event_guard_log_uuid']])->fetchColumn()==='blocked','The native block was not durably confirmed.');
 $recovery=uuid();$q("insert into v_pbx_phone_health_recoveries(recovery_uuid,domain_uuid,actor_uuid,block_uuid,source_address,status,instance_id) values(?,?,?,?,?::inet,'pending',?)",[$recovery,$domain,$owner,$row['event_guard_log_uuid'],$source,pbx_phone_health::instanceId()]);$recoveryEvent=['Event-Subclass'=>'event_guard:phone_health_unblock','OpenWeb-Phone-Health-Block'=>$row['event_guard_log_uuid'],'OpenWeb-Phone-Health-Recovery'=>$recovery];
 $phase='role_refusal';$q("update v_group_permissions set permission_assigned='false'");$denied=$guard->consume($recoveryEvent);$check($denied['status']==='refused'&&$firewall->block_state_exact($source,'sip-auth-fail')==='present','A revoked role removed the native block.');
 $phase='authorised_recovery';$q("update v_group_permissions set permission_assigned='true'");$q("update v_pbx_phone_health_recoveries set status='pending' where recovery_uuid=?",[$recovery]);$ack=$guard->consume($recoveryEvent);
 $check($ack['status']==='acknowledged'&&$firewall->block_state_exact($source,'sip-auth-fail')==='absent','The authorised exact native recovery did not complete.');
 $phase='acknowledgement';$check($q('select log_status from v_event_guard_logs where event_guard_log_uuid=?',[$row['event_guard_log_uuid']])->fetchColumn()==='unblocked'&&$q('select status from v_pbx_phone_health_recoveries where recovery_uuid=?',[$recovery])->fetchColumn()==='acknowledged','The actual native removal lacks its SQL acknowledgement.');
 $phase='duplicate_refusal';
 $check($guard->consume($recoveryEvent)['status']==='refused'&&$firewall->block_state_exact($source,'sip-auth-fail')==='absent','A duplicate event repeated the native removal.');
 $phase='complete';$result=['state'=>'passed','actual_native_windows_worker'=>true,'actual_esl_event'=>true,'actual_defender_adapter'=>true,'actual_postgresql'=>true,'synthetic_office_history'=>true,'post_native_fault_reconciled'=>true,'revoked_role_refused'=>true,'authorised_recovery_acknowledged'=>true,'physical_phone_audio'=>false,'checks'=>$checks];
}catch(Throwable $error){$primaryFailure=native_health_failure($error,$phase);throw $error;}
finally{
 $phase='cleanup';try{
 if($subscriber)$subscriber->close();if($db->inTransaction())$db->rollBack();
 try{if($created&&!$firewall->block_delete_exact($source,'sip-auth-fail'))throw new RuntimeException('The exact native fixture cleanup requires review.');}
 finally{if($created){$db->exec('set search_path to public');$db->exec('drop schema '.$schema.' cascade');}}
 }catch(Throwable $error){$cleanupFailure=native_health_failure($error,'cleanup');throw $error;}
}
echo json_encode($result,JSON_THROW_ON_ERROR),PHP_EOL;
