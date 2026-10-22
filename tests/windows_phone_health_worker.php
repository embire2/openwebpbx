<?php
/** Actual installed Windows ESL -> native Defender -> PostgreSQL -> recovery.
 * Explicit disposable factory only. No physical phone or carrier call is made. */
if(PHP_SAPI!=='cli'||PHP_OS_FAMILY!=='Windows'||!in_array('--native-windows-worker',$argv,true)||getenv('GITHUB_ACTIONS')!=='true'||getenv('RUNNER_ENVIRONMENT')!=='github-hosted'||getenv('GITHUB_REPOSITORY')!=='embire2/openwebpbx')throw new RuntimeException('The disposable native Windows factory is required.');
require 'C:/OpenWebPBX/web/resources/require.php';
$db=database::new()->db;$schema='health_native_'.bin2hex(random_bytes(6));$checks=0;$source='198.18.0.252';$firewall=new event_guard_windows();$created=false;$subscriber=null;
$check=static function(bool $v,string $why)use(&$checks):void{if(!$v)throw new RuntimeException($why);$checks++;};
$q=static function(string $sql,array $a=[])use($db):PDOStatement{$s=$db->prepare($sql);$s->execute($a);return $s;};
// Only test hooks change: registrations, instance identity, event stream and
// firewall mutation remain the actual installed production implementations.
class native_health_fault_guard extends pbx_windows_event_guard {protected function afterNativeAdd():void{throw new RuntimeException('Deliberate interruption after native Defender rule creation.');}}
try{
 $check($firewall->block_state_exact($source,'sip-auth-fail')==='absent'&&$firewall->block_state_exact($source,'sip-auth-ip')==='absent','The native fixture source already has a block.');
 $check((int)$db->query('select count(*) from v_pbx_restore')->fetchColumn()===0,'An empty disposable factory is required.');
 $db->exec('create schema '.$schema);$created=true;$db->exec('set search_path to '.$schema);
 $db->exec("create table v_domains(domain_uuid uuid primary key,domain_name text,domain_enabled text);create table v_users(user_uuid uuid primary key,domain_uuid uuid,user_enabled text);create table v_pbx_tenants(tenant_uuid uuid primary key,owner_user_uuid uuid,home_domain_uuid uuid,enabled bool);create table v_pbx_services(tenant_uuid uuid,domain_uuid uuid);create table v_pbx_restore(domain_uuid uuid primary key,config jsonb);create table v_extensions(extension_uuid uuid primary key,domain_uuid uuid,extension text,number_alias text,enabled text,password text);create table v_pbx_sip_domains(sip_domain text,domain_uuid uuid,enabled bool);create table v_pbx_staff_audit(audit_uuid uuid primary key,domain_uuid uuid,actor_uuid uuid,action text,target text,result text);create table v_event_guard_logs(event_guard_log_uuid uuid primary key,hostname text,log_date timestamptz,filter text,ip_address text,extension text,user_agent text,log_status text);create table v_access_control_nodes(node_cidr text,node_type text);create table v_user_logs(remote_address text,result text,timestamp timestamptz);create table v_groups(group_uuid uuid,group_name text);create table v_user_groups(user_uuid uuid,domain_uuid uuid,group_uuid uuid);create table v_group_permissions(group_uuid uuid,group_name text,domain_uuid uuid,permission_name text,permission_assigned text)");
 $db->exec(file_get_contents(dirname(__DIR__).'/app/pbx_setup/resources/phone_health.sql'));
 $domain=uuid();$owner=uuid();$tenant=uuid();$extension=uuid();$group=uuid();$realm='health-native.example.invalid';
 $q("insert into v_domains values(?,?,'true')",[$domain,$realm]);$q("insert into v_users values(?,?,'true')",[$owner,$domain]);$q('insert into v_pbx_tenants values(?,?,?,true)',[$tenant,$owner,$domain]);$q('insert into v_pbx_services values(?,?)',[$tenant,$domain]);
 $q("insert into v_extensions values(?,?,?,'1000','true','fixture-only-secret')",[$extension,$domain,'native-health-auth']);
 $c=['realm'=>$realm,'users'=>['1000'=>['enabled'=>true,'auth_id'=>'native-health-auth','extension_uuid'=>$extension]],'departments'=>[]];$q('insert into v_pbx_restore values(?,?::jsonb)',[$domain,json_encode($c,JSON_THROW_ON_ERROR)]);
 $q("insert into v_groups values(?,'native_health_owner')",[$group]);$q('insert into v_user_groups values(?,?,?)',[$owner,$domain,$group]);$q("insert into v_group_permissions values(?,'native_health_owner',null,'pbx_service_create','true')",[$group]);
 // This is explicitly synthetic verified-source history, not a real phone test.
 $q("insert into v_pbx_phone_health_contacts(domain_uuid,extension_uuid,source_address,expires_at) values(?,?,?::inet,now()+interval '5 minutes')",[$domain,$extension,$source]);
 $subscriber=new pbx_windows_health_stream();$subscriber->connect();$marker=uuid();$publisher=new pbx_windows_health_stream();
 try{$publisher->connect(false);$send=new ReflectionMethod(pbx_windows_health_stream::class,'send');$send->invoke($publisher,"sendevent CUSTOM\nEvent-Name: CUSTOM\nEvent-Subclass: sofia::register_failure\nOpenWeb-Health-Fixture: ".$marker."\nnetwork-ip: ".$source."\nto-host: ".$realm."\nto-user: native-health-auth\nuser-agent: OpenWebPBX isolated native fixture");$ack=$publisher->packet(3);$check(($ack['Content-Type']??null)==='command/reply'&&str_starts_with($ack['Reply-Text']??'','+OK'),'The real local ESL publisher did not accept the fixture event.');}finally{$publisher->close();}
 $event=null;$deadline=microtime(true)+4;
 while(microtime(true)<$deadline){$packet=$subscriber->packet(min(1,max(.001,$deadline-microtime(true))));if(($packet['Content-Type']??null)!=='text/event-json')continue;$candidate=json_decode($packet['body'],true,32,JSON_THROW_ON_ERROR);if(($candidate['OpenWeb-Health-Fixture']??null)===$marker){$event=$candidate;break;}}
 $check(is_array($event)&&($event['Event-Subclass']??null)==='sofia::register_failure','The actual installed subscriber did not receive the fixture event.');$subscriber->close();
 $fault=new native_health_fault_guard($db,$firewall);$failed=false;try{$fault->consume($event);}catch(RuntimeException$e){if($e->getMessage()!=='Deliberate interruption after native Defender rule creation.')throw$e;$failed=true;}
 $check($failed,'The native post-mutation interruption was not reached.');$row=$q('select event_guard_log_uuid,log_status from v_event_guard_logs where ip_address=?',[$source])->fetch(PDO::FETCH_ASSOC);
 $check($row&&$row['log_status']==='windows_intent'&&!$db->inTransaction(),'The native fault lost its committed intent.');$check($firewall->block_state_exact($source,'sip-auth-fail')==='present','The actual native rule was not created.');
 $guard=new pbx_windows_event_guard($db,$firewall);$check($guard->reconcile(),'The native intent did not reconcile.');$check($q('select log_status from v_event_guard_logs where event_guard_log_uuid=?',[$row['event_guard_log_uuid']])->fetchColumn()==='blocked','The native block was not durably confirmed.');
 $recovery=uuid();$q("insert into v_pbx_phone_health_recoveries(recovery_uuid,domain_uuid,actor_uuid,block_uuid,source_address,status,instance_id) values(?,?,?,?,?::inet,'pending',?)",[$recovery,$domain,$owner,$row['event_guard_log_uuid'],$source,pbx_phone_health::instanceId()]);$recoveryEvent=['Event-Subclass'=>'event_guard:phone_health_unblock','OpenWeb-Phone-Health-Block'=>$row['event_guard_log_uuid'],'OpenWeb-Phone-Health-Recovery'=>$recovery];
 $q("update v_group_permissions set permission_assigned='false'");$denied=$guard->consume($recoveryEvent);$check($denied['status']==='refused'&&$firewall->block_state_exact($source,'sip-auth-fail')==='present','A revoked role removed the native block.');
 $q("update v_group_permissions set permission_assigned='true'");$q("update v_pbx_phone_health_recoveries set status='pending' where recovery_uuid=?",[$recovery]);$ack=$guard->consume($recoveryEvent);
 $check($ack['status']==='acknowledged'&&$firewall->block_state_exact($source,'sip-auth-fail')==='absent','The authorised exact native recovery did not complete.');
 $check($q('select log_status from v_event_guard_logs where event_guard_log_uuid=?',[$row['event_guard_log_uuid']])->fetchColumn()==='unblocked'&&$q('select status from v_pbx_phone_health_recoveries where recovery_uuid=?',[$recovery])->fetchColumn()==='acknowledged','The actual native removal lacks its SQL acknowledgement.');
 $check($guard->consume($recoveryEvent)['status']==='refused'&&$firewall->block_state_exact($source,'sip-auth-fail')==='absent','A duplicate event repeated the native removal.');
 echo json_encode(['state'=>'passed','actual_native_windows_worker'=>true,'actual_esl_event'=>true,'actual_defender_adapter'=>true,'actual_postgresql'=>true,'synthetic_office_history'=>true,'post_native_fault_reconciled'=>true,'revoked_role_refused'=>true,'authorised_recovery_acknowledged'=>true,'physical_phone_audio'=>false,'checks'=>$checks],JSON_THROW_ON_ERROR),PHP_EOL;
}finally{
 if($subscriber)$subscriber->close();if($db->inTransaction())$db->rollBack();
 try{if($created&&!$firewall->block_delete_exact($source,'sip-auth-fail'))throw new RuntimeException('The exact native fixture cleanup requires review.');}
 finally{if($created){$db->exec('set search_path to public');$db->exec('drop schema '.$schema.' cascade');}}
}
