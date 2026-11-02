<?php
// PRIVATE diagnostic only: readonly DB/ESL and State-only native queries.
if(PHP_SAPI!=='cli'||PHP_OS_FAMILY!=='Windows')exit(2);
ini_set('display_errors','0');ini_set('log_errors','0');set_time_limit(85);
require 'C:/OpenWebPBX/web/resources/require.php';
require __DIR__.'/windows_phone_health_state_adapter.php';
if(!hash_equals(openweb_diag_event_guard_windows::BASE_SOURCE_SHA256,hash_file('sha256','C:/OpenWebPBX/web/app/event_guard/resources/classes/event_guard_windows.php')))throw new RuntimeException('Diagnostic source binding differs.');
$out=['schema'=>1,'scope'=>'closed readonly health availability layers; no monitor/collect/reconcile','started_at'=>gmdate('c'),'errors'=>[]];
function step(string $name,callable $fn):mixed {global$out;try{$r=$fn();$out[$name]=true;return $r;}catch(Throwable$e){$out[$name]=false;$t=get_class($e);$out['errors'][$name]=in_array($t,['RuntimeException','PDOException','JsonException','TypeError','ReflectionException'],true)?$t:'OtherError';return null;}}
$stream=new pbx_windows_health_stream();$db=null;
try{
 $out['runtime_ready']=pbx_windows_health_runtime::ready(pbx_paths::state());
 step('esl_subscription',function()use($stream){$stream->connect();return true;});$stream->close();
 $raw=step('registrations_api',fn()=>pbx_windows_health_stream::api('show registrations as json'));
 if(is_string($raw)){$rows=step('registrations_parser',fn()=>pbx_phone_health::registrations($raw));$out['registration_count']=is_array($rows)?count($rows):null;}unset($raw,$rows);
 $xml=step('sofia_api',fn()=>pbx_windows_health_stream::api('sofia xmlstatus'));
 $shape=['valid'=>false,'running'=>0,'loopback'=>0,'non_loopback'=>0,'unparseable'=>0,'loopback_only'=>false];
 if(is_string($xml)&&strlen($xml)<=1048576&&!str_contains($xml,'<!DOCTYPE')&&!str_contains($xml,'<!ENTITY')){
  $tree=@simplexml_load_string($xml,'SimpleXMLElement',LIBXML_NONET|LIBXML_NOERROR|LIBXML_NOWARNING);
  if($tree&&$tree->getName()==='profiles'){
   $shape['valid']=true;
   foreach($tree->profile as$profile){$data=(string)$profile->data;if((string)$profile->type!=='profile'||!str_starts_with((string)$profile->state,'RUNNING')||str_contains($data,'transport=ws'))continue;
    if(++$shape['running']>2048){$shape['valid']=false;break;}
    if(!preg_match('~^(sips?):[^@\s]+@(?:\[([^\]]+)\]|([^:;\s]+)):([0-9]{1,5})(?:;transport=(tcp|udp|tls))?$~D',$data,$m)){$shape['unparseable']++;continue;}
    $host=$m[2]?:$m[3];$shape[in_array($host,['127.0.0.1','::1'],true)?'loopback':'non_loopback']++;
   }
   $shape['loopback_only']=$shape['valid']&&$shape['running']>0&&$shape['unparseable']===0&&$shape['non_loopback']===0;
  }
 }
 $out['sofia_profile_summary']=$shape;unset($tree,$data,$host,$m,$shape);
 if(is_string($xml)){$ports=step('sofia_listener_parser',fn()=>event_guard_windows::ports($xml));$out['listener_counts']=is_array($ports)?['tcp'=>count($ports['tcp']),'udp'=>count($ports['udp'])]:null;}unset($xml,$ports);
 $db=database::new()->db;$db->beginTransaction();$db->exec("set transaction read only;set local statement_timeout='4s';set local lock_timeout='2s'");
 $out['phone_health_schema_installed']=pbx_phone_health::installed($db);
 $out['contacts_insert_privilege']=in_array($db->query("select has_table_privilege(current_user,'v_pbx_phone_health_contacts','INSERT')")->fetchColumn(),[true,'t','true',1,'1'],true);
 $out['contacts_update_privilege']=in_array($db->query("select has_table_privilege(current_user,'v_pbx_phone_health_contacts','UPDATE')")->fetchColumn(),[true,'t','true',1,'1'],true);
 $q=$db->prepare("select count(*) from v_event_guard_logs where hostname=? and log_status='windows_intent'");$q->execute([gethostname()]);$out['pending_intents']=(int)$q->fetchColumn();
 $out['reconcile_readonly_precondition']=$out['pending_intents']===0;
 $out['last_state_counts']=[];foreach($db->query('select available,detail,count(*) n from v_pbx_phone_health_state group by available,detail')->fetchAll(PDO::FETCH_ASSOC)as$r){$out['last_state_counts'][]=['available'=>in_array($r['available'],[true,'t','true',1,'1'],true),'detail'=>in_array($r['detail'],['Checked','Phone status unavailable','Phone security observer unavailable'],true)?$r['detail']:'other','count'=>(int)$r['n']];}
 $db->rollBack();$out['sql_readonly_rolled_back']=true;
 step('phone_health_identity',function(){if(!preg_match('/^[a-f0-9]{64}$/D',pbx_phone_health::instanceId()??''))throw new RuntimeException();return true;});
 $original=new event_guard_windows();$originalStarted=hrtime(true);$out['original_firewall_state']=step('original_state_query',fn()=>$original->block_state_exact('198.18.0.254','sip-auth-fail'));$out['original_state_elapsed_ms']=(int)round((hrtime(true)-$originalStarted)/1000000);
 $observed=new openweb_diag_event_guard_windows();$out['instrumented_firewall_state']=step('instrumented_state_query',fn()=>$observed->block_state_exact('198.18.0.254','sip-auth-fail'));$out['state_transport']=$observed->lastRun;
 $neutral=step('neutral_transport_call',fn()=>$observed->neutral());$out['neutral_transport_exact']=is_string($neutral)&&trim($neutral)==='12345';$out['neutral_transport']=$observed->lastRun;unset($neutral);
 $out['read_only_diagnostic_completed']=true;
}catch(Throwable$e){$out['read_only_diagnostic_completed']=false;$out['outer_error_type']=get_class($e);}finally{if($db instanceof PDO&&$db->inTransaction())$db->rollBack();$stream->close();}
$out['finished_at']=gmdate('c');$out['no_monitor_collect_reconcile_called']=true;$out['no_add_remove_or_worker_invocation']=true;echo json_encode($out,JSON_THROW_ON_ERROR),PHP_EOL;
