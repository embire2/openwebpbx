<?php
/** Independent multi-process PostgreSQL controls; explicitly owned disposable database only. */
if(PHP_SAPI!=='cli'||!getenv('OPENWEB_CMB_TEST_DSN'))exit(2);
function cmb_review_connect(): PDO {return new PDO(getenv('OPENWEB_CMB_TEST_DSN'),getenv('OPENWEB_CMB_TEST_USER')?:'postgres',null,[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);}
function cmb_review_uuid(): string {$v=bin2hex(random_bytes(16));return substr($v,0,8).'-'.substr($v,8,4).'-'.substr($v,12,4).'-'.substr($v,16,4).'-'.substr($v,20);}
if(($argv[1]??'')==='child'){
 $v=json_decode(base64_decode($argv[2]??'',true),true,512,JSON_THROW_ON_ERROR);
 if(!preg_match('/^cmb_parallel_[a-f0-9]{12}$/D',$v['schema']??''))exit(2);
 $db=cmb_review_connect();$db->exec('set search_path to '.$v['schema']);$s=$db->prepare("select set_config('application_name',?,false)");$s->execute([$v['tag']]);
 $sql=match($v['action']){'enqueue'=>'select count(*) from openweb_cmb_enqueue(?,?,?,?)','authorize'=>'select openweb_cmb_authorize(?,?)','finish'=>'select openweb_cmb_finish(?,137,?)',default=>throw new RuntimeException('Unsupported fixture operation.')};
 $s=$db->prepare($sql);$s->execute($v['args']);echo json_encode(['result'=>$s->fetchColumn()],JSON_THROW_ON_ERROR);exit;
}
$db=cmb_review_connect();$schema='cmb_parallel_'.bin2hex(random_bytes(6));$checks=0;$children=[];
$q=static function(string $sql,array $args=[])use($db){$s=$db->prepare($sql);$s->execute($args);return$s;};
$ok=static function(bool $v,string $message)use(&$checks){if(!$v)throw new RuntimeException($message);$checks++;};
$parallel=static function(array $tasks,string $lockedTable,string $lockedKey,string $lockedId)use($db,$schema,$q,$ok,&$children):array{
 $tag='cmb-review-'.bin2hex(random_bytes(6));$db->beginTransaction();$q('select 1 from '.$lockedTable.' where '.$lockedKey.'=? for update',[$lockedId]);$batch=[];
 try{
  foreach($tasks as$task){$task+=['schema'=>$schema,'tag'=>$tag];$pipes=[];$process=proc_open([PHP_BINARY,__FILE__,'child',base64_encode(json_encode($task,JSON_THROW_ON_ERROR))],[0=>['pipe','r'],1=>['pipe','w'],2=>['pipe','w']],$pipes);if(!is_resource($process))throw new RuntimeException('Fixture child could not start.');fclose($pipes[0]);$batch[]=[$process,$pipes];$children[]=[$process,$pipes];}
  $waiting=0;$until=microtime(true)+10;
  do{$q('select pg_stat_clear_snapshot()');$waiting=(int)$q("select count(*) from pg_stat_activity where application_name=? and wait_event_type='Lock'",[$tag])->fetchColumn();if($waiting===count($tasks))break;usleep(10000);}while(microtime(true)<$until);
  $ok($waiting===count($tasks),'The independent children did not all contend on the real PostgreSQL lock.');$db->commit();
  $results=[];foreach($batch as[$process,$pipes]){$stdout=stream_get_contents($pipes[1]);$stderr=stream_get_contents($pipes[2]);fclose($pipes[1]);fclose($pipes[2]);$exit=proc_close($process);$ok($exit===0&&$stderr==='','A contending PostgreSQL operation failed.');$result=json_decode($stdout,true,512,JSON_THROW_ON_ERROR);$results[]=$result['result'];}$children=[];return$results;
 }catch(Throwable $e){if($db->inTransaction())$db->rollBack();throw$e;}
};
try{
 $db->exec('create schema '.$schema.';set search_path to '.$schema);
 $db->exec('create table v_domains(domain_uuid uuid primary key,domain_enabled boolean default true);create table v_pbx_tenants(tenant_uuid uuid primary key,enabled boolean);create table v_pbx_services(domain_uuid uuid,tenant_uuid uuid)');
 $db->exec(file_get_contents(dirname(__DIR__).'/app/pbx_setup/resources/call_me_back.sql'));
 $domain=cmb_review_uuid();$foreign=cmb_review_uuid();$service=cmb_review_uuid();$service2=cmb_review_uuid();$foreignService=cmb_review_uuid();$account=cmb_review_uuid();$account2=cmb_review_uuid();$foreignAccount=cmb_review_uuid();$proof=hash('sha256','independent fictional keyed match');
 $q('insert into v_domains(domain_uuid) values(?),(?)',[$domain,$foreign]);
 foreach([[$service,$domain],[$service2,$domain],[$foreignService,$foreign]]as[$s,$d])$q("insert into v_pbx_cmb_services(service_uuid,domain_uuid,name,incoming_rule_uuid,route_owner,prompt_state,prompt_sha256,enabled,max_requests_hour) values(?,?,'Independent fictional service',?,'1000','ready',repeat('a',64),true,300)",[$s,$d,cmb_review_uuid()]);
 foreach([[$account,$domain,$service],[$account2,$domain,$service2],[$foreignAccount,$foreign,$foreignService]]as[$a,$d,$s])$q("insert into v_pbx_cmb_accounts(account_uuid,domain_uuid,service_uuid,name,id_hmac,id_last4,total_seconds) values(?,?,?,'Independent fictional account',?,'0000',1000)",[$a,$d,$s,$proof]);
 // Different services still share the same tenant-wide four-request guard.
 $tasks=[];for($i=0;$i<12;$i++)$tasks[]=['action'=>'enqueue','args'=>[$domain,$i%2?$service:$service2,cmb_review_uuid(),'+278200001'.str_pad((string)$i,2,'0',STR_PAD_LEFT)]];
 $results=$parallel($tasks,'v_domains','domain_uuid',$domain);
 $ok(array_sum(array_map('intval',$results))===4,'Concurrent different-service incoming calls exceeded the tenant-wide limit.');
 $ok((int)$q('select count(*) from v_pbx_cmb_requests where domain_uuid=?',[$domain])->fetchColumn()===4,'Stored tenant request count differs from accepted concurrent requests.');
 $q('delete from v_pbx_cmb_requests where domain_uuid=?',[$domain]);
 // Requests within one service also serialize its hourly limit.
 $q('update v_pbx_cmb_services set max_requests_hour=2 where service_uuid=?',[$service]);$tasks=[];
 for($i=0;$i<8;$i++)$tasks[]=['action'=>'enqueue','args'=>[$domain,$service,cmb_review_uuid(),'+278200002'.str_pad((string)$i,2,'0',STR_PAD_LEFT)]];
 $results=$parallel($tasks,'v_domains','domain_uuid',$domain);$ok(array_sum(array_map('intval',$results))===2,'Concurrent requests exceeded the configured service hourly limit.');
 $q('delete from v_pbx_cmb_requests where domain_uuid=?',[$domain]);$q('update v_pbx_cmb_services set max_requests_hour=300 where service_uuid=?',[$service]);
 // Two real simultaneous callback answers cannot reserve one account twice.
 $r1=cmb_review_uuid();$r2=cmb_review_uuid();foreach([[$r1,'+27820000301'],[$r2,'+27820000302']]as[$r,$cli])$q("insert into v_pbx_cmb_requests(request_uuid,domain_uuid,service_uuid,inbound_uuid,caller_number,state) values(?,?,?,?,?,'authenticating')",[$r,$domain,$service,cmb_review_uuid(),$cli]);
 $results=$parallel([['action'=>'authorize','args'=>[$r1,$proof]],['action'=>'authorize','args'=>[$r2,$proof]]],'v_pbx_cmb_accounts','account_uuid',$account);$ints=array_map('intval',$results);sort($ints);$ok($ints===[0,600],'Simultaneous authentication reserved more than one call for one account.');
 $row=$q('select used_seconds,reserved_seconds from v_pbx_cmb_accounts where account_uuid=?',[$account])->fetch(PDO::FETCH_ASSOC);$ok($row===['used_seconds'=>0,'reserved_seconds'=>600],'Account totals differ from the single accepted reservation.');
 $ok((int)$q('select count(*) from v_pbx_cmb_bindings where account_uuid=?',[$account])->fetchColumn()===1,'Denied concurrent authentication saved an extra trusted caller.');
 $accepted=$q('select request_uuid from v_pbx_cmb_requests where account_uuid=?',[$account])->fetchColumn();$acceptedCli=$q('select caller_number from v_pbx_cmb_requests where request_uuid=?',[$accepted])->fetchColumn();
 $q("update v_pbx_cmb_requests set state='connected',connected_at=now()-interval '137 seconds' where request_uuid=?",[$accepted]);
 $results=$parallel([['action'=>'finish','args'=>[$accepted,'independent_finish']],['action'=>'finish','args'=>[$accepted,'independent_duplicate']]],'v_pbx_cmb_requests','request_uuid',$accepted);$ok(count(array_filter($results))===1,'Concurrent completion charged the same call more than once.');
 $row=$q('select used_seconds,reserved_seconds from v_pbx_cmb_accounts where account_uuid=?',[$account])->fetch(PDO::FETCH_ASSOC);$ok($row===['used_seconds'=>137,'reserved_seconds'=>0],'Concurrent settlement failed exact observed usage and unused-reservation return.');
 // A bound caller remains untrusted at another service/tenant, even with the same test proof.
 $r3=cmb_review_uuid();$r4=cmb_review_uuid();foreach([[$r3,$domain,$service2],[$r4,$foreign,$foreignService]]as[$r,$d,$s])$q("insert into v_pbx_cmb_requests(request_uuid,domain_uuid,service_uuid,inbound_uuid,caller_number,state) values(?,?,?,?,?,'authenticating')",[$r,$d,$s,cmb_review_uuid(),$acceptedCli]);
 foreach([$r3,$r4]as$r)$ok((int)$q('select openweb_cmb_authorize(?,null)',[$r])->fetchColumn()===0,'A saved caller was recognised in a foreign service or tenant.');
 $ok($q('select used_seconds,reserved_seconds from v_pbx_cmb_accounts where account_uuid=?',[$foreignAccount])->fetch(PDO::FETCH_ASSOC)===['used_seconds'=>0,'reserved_seconds'=>0],'Another tenant account counters changed.');
 $q('delete from v_pbx_cmb_requests where account_uuid is null');$q('update v_pbx_cmb_accounts set used_seconds=total_seconds where account_uuid=?',[$account]);$q("update v_pbx_cmb_requests set created_at=now()-interval '2 minutes' where account_uuid=?",[$account]);
 $s=$q('select * from openweb_cmb_enqueue(?,?,?,?)',[$domain,$service,cmb_review_uuid(),$acceptedCli])->fetch(PDO::FETCH_ASSOC);$ok($s!==false&&$s['known'],'Exhaustion lost the independent saved-caller identity.');$q("update v_pbx_cmb_requests set state='authenticating' where request_uuid=?",[$s['request_uuid']]);$ok((int)$q('select openweb_cmb_authorize(?,null)',[$s['request_uuid']])->fetchColumn()===0,'An exhausted recognised caller received a reservation.');
 $null=$q('select count(*) from openweb_cmb_enqueue(?,?,?,null)',[$domain,$service,cmb_review_uuid()])->fetchColumn();$ok((int)$null===0,'SQL accepted a NULL caller number intended only for redacted history.');
 echo "PASS: $checks independent actual concurrent PostgreSQL lock, cross-service/tenant, quota, identity and settlement checks\n";
}finally{
 if($db->inTransaction())$db->rollBack();foreach($children as[$process,$pipes]){if(is_resource($process))proc_terminate($process);foreach($pipes as$pipe)if(is_resource($pipe))fclose($pipe);if(is_resource($process))proc_close($process);}
 $db->exec('set search_path to public;drop schema if exists '.$schema.' cascade');
}
