<?php
/** Real isolated PostgreSQL and temporary files; never bootstrap an installed PBX. */
if(PHP_SAPI!=='cli'||getenv('OPENWEB_HEALTH_PHASE_TEST_ISOLATED')!=='yes')exit(2);
$dsn=getenv('OPENWEB_HEALTH_PHASE_TEST_DSN');if(!is_string($dsn)||!preg_match('/^pgsql:host=127\.0\.0\.1;port=[1-9][0-9]{3,4};dbname=postgres$/D',$dsn))exit(2);
require __DIR__.'/windows_phone_health_restart_phase.php';require dirname(__DIR__).'/resources/classes/pbx_windows_health_runtime.php';
$connect=static fn(string $user='postgres',?string $target=null)=>new PDO($target??$dsn,$user,null,[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION,PDO::ATTR_EMULATE_PREPARES=>false]);
if(($argv[1]??'')==='owned-child'){
 $db=$connect();$port=(int)$db->query('select inet_client_port()')->fetchColumn();echo json_encode(['port'=>$port]),PHP_EOL;flush();
 $db->beginTransaction();$db->query('select pg_advisory_xact_lock(987654321)');$db->commit();exit;
}
$checks=0;$ok=static function(bool $pass)use(&$checks){if(!$pass)throw new RuntimeException('Read-only restart phase control refused at '.debug_backtrace(DEBUG_BACKTRACE_IGNORE_ARGS,1)[0]['line']);$checks++;};
$deny=static function(callable $run)use($ok){try{$run();}catch(InvalidArgumentException){$ok(true);return;}$ok(false);};
$db=$connect();$worker=$connect();$other=null;$foreign=null;$child=null;$pipes=[];$lock=null;
$dir=sys_get_temp_dir().'/health-phase-'.bin2hex(random_bytes(10));mkdir($dir,0700);mkdir($dir.'/updates');mkdir($dir.'/backup-restore');
try{
 $db->exec('create table v_pbx_phone_health_recoveries (recovery_uuid text,block_uuid text);create table phase_sentinel (value text);insert into phase_sentinel values (\'PRIVATE_KEEP\')');
 $port=(int)$worker->query('select inet_client_port()')->fetchColumn();$settings=$db->query('show statement_timeout')->fetchColumn();
 file_put_contents($dir.'/installation.json','{"Completed":true}');file_put_contents($dir.'/upgrade.lock','EXACT_LOCK_BYTES');$lock=fopen($dir.'/upgrade.lock','r+b');flock($lock,LOCK_EX);
 $worker->query('select recovery_uuid,block_uuid from v_pbx_phone_health_recoveries where false')->fetchAll();
 $started=microtime(true);$r=windows_health_restart_phase($db,$dir,[$port]);$ok(microtime(true)-$started<2&&$r['runtime_ready']&&$r['database_observed']&&!$r['snapshot_atomic']);
 $ok(count($r['backends'])===1&&$r['backends'][0]['state']==='idle'&&$r['backends'][0]['wait_event']==='ClientRead'&&$r['backends'][0]['query_class']==='recovery_heartbeat');
 $ok(file_get_contents($dir.'/upgrade.lock')==='EXACT_LOCK_BYTES'&&flock($lock,LOCK_EX|LOCK_NB));
 $ok($db->query('show statement_timeout')->fetchColumn()===$settings&&$db->query('show transaction_read_only')->fetchColumn()==='off');
 $worker->query("select 'PRIVATE_SQL_URI' as never_exported")->fetchAll();$r=windows_health_restart_phase($db,$dir,[$port]);$ok($r['backends'][0]['query_class']==='other'&&!str_contains(json_encode($r),'PRIVATE'));
 $worker->beginTransaction();$worker->query('select 1')->fetchAll();$r=windows_health_restart_phase($db,$dir,[$port]);$ok($r['backends'][0]['state']==='idle in transaction');$worker->rollBack();
 foreach([[],[$port],[$port,65535]]as$ports){$r=windows_health_restart_phase($db,$dir,$ports);$ok(count($r['backends'])===($ports?1:0)&&$r['database_observed']);}
 foreach([[$port,$port],[0],[65536],['55001'],[true],[1.0],range(1,33),[1=>$port]]as$bad)$deny(fn()=>windows_health_restart_phase($db,$dir,$bad));
 // Current database/user selection excludes real foreign connections.
 $db->exec('create role phase_other login');$db->exec('create database phase_other_db');$other=$connect('phase_other');$otherPort=(int)$other->query('select inet_client_port()')->fetchColumn();$foreign=$connect('postgres',str_replace('dbname=postgres','dbname=phase_other_db',$dsn));$foreignPort=(int)$foreign->query('select inet_client_port()')->fetchColumn();
 $r=windows_health_restart_phase($db,$dir,[$port,$otherPort,$foreignPort]);$ok(count($r['backends'])===1);
 // A real owned backend blocked on an advisory lock, not an invented activity row.
 $db->query('select pg_advisory_lock(987654321)');$child=proc_open([PHP_BINARY,__FILE__,'owned-child'],[['pipe','r'],['pipe','w'],['pipe','w']],$pipes);if(!is_resource($child))throw new RuntimeException('Owned child unavailable.');fclose($pipes[0]);stream_set_blocking($pipes[1],false);$line='';$until=microtime(true)+5;
 while(!str_contains($line,"\n")&&microtime(true)<$until){$line.=stream_get_contents($pipes[1]);if(strlen($line)>1024)throw new RuntimeException('Owned readiness oversized.');usleep(10000);}
 $ready=json_decode(trim($line),true,8,JSON_THROW_ON_ERROR);$childPort=$ready['port'];$found=false;$until=microtime(true)+5;
 do{$r=windows_health_restart_phase($db,$dir,[$childPort]);if(count($r['backends'])===1){$b=$r['backends'][0];$found=$b['state']==='active'&&$b['wait_type']==='Lock'&&$b['wait_event']==='advisory'&&$b['query_class']==='advisory_lock';}if(!$found)usleep(10000);}while(!$found&&microtime(true)<$until);$ok($found);
 $db->query('select pg_advisory_unlock(987654321)');stream_set_blocking($pipes[1],true);$tail=stream_get_contents($pipes[1]);$error=stream_get_contents($pipes[2]);fclose($pipes[1]);fclose($pipes[2]);$pipes=[];$exit=proc_close($child);$child=null;$ok($exit===0&&$tail===''&&$error==='');
 foreach(['calls','jobs','updates','backups']as$name){$file=$dir.'/backup-restore/hold-'.$name;file_put_contents($file,'PRIVATE_HOLD');$r=windows_health_restart_phase($db,$dir,[$port]);$ok(!$r['runtime_ready']&&$r['holds'][$name]==='present'&&file_get_contents($file)==='PRIVATE_HOLD');unlink($file);}
 foreach(['update'=>['updates/install-journal.json',['completed','rolled_back']],'restore'=>['backup-restore/journal.json',['restored','recovered']]]as$name=>[$relative,$accepted]){
  $file=$dir.'/'.$relative;
  foreach($accepted as$value){file_put_contents($file,json_encode(['state'=>$value]));$r=windows_health_restart_phase($db,$dir,[]);$ok($r['runtime_ready']&&$r['journals'][$name]==='accepted');}
  foreach(['prepared','PRIVATE_UNKNOWN']as$value){file_put_contents($file,json_encode(['state'=>$value]));$r=windows_health_restart_phase($db,$dir,[]);$ok(!$r['runtime_ready']&&$r['journals'][$name]==='blocking'&&!str_contains(json_encode($r),'PRIVATE'));}unlink($file);
 }
 foreach(['absent'=>null,'blocking'=>'{"Completed":false}','invalid'=>'not json','oversized'=>str_repeat('x',1048577)]as$class=>$raw){$file=$dir.'/installation.json';if($raw===null)unlink($file);else file_put_contents($file,$raw);clearstatcache();$r=windows_health_restart_phase($db,$dir,[]);$ok(!$r['runtime_ready']&&$r['journals']['installation']===$class);}
 file_put_contents($dir.'/installation.json','{"Completed":true}');$r=windows_health_restart_phase($db,$dir,[]);$ok($r['runtime_ready']);
 $db->beginTransaction();$db->exec("insert into phase_sentinel values ('CALLER_TRANSACTION')");$r=windows_health_restart_phase($db,$dir,[]);$ok(!$r['database_observed']&&$r['error_kind']==='database'&&$db->inTransaction());$ok((int)$db->query('select count(*) from phase_sentinel')->fetchColumn()===2);$db->rollBack();
 $ok($db->query('select value from phase_sentinel')->fetchAll(PDO::FETCH_COLUMN)===['PRIVATE_KEEP']);
 $source=file_get_contents(__DIR__.'/windows_phone_health_restart_phase.php');$ok(!str_contains($source,'::locked(')&&!str_contains($source,'flock(')&&!str_contains($source,'fopen('));
 echo json_encode(['schema'=>1,'state'=>'passed','checks'=>$checks,'actual_isolated_postgresql'=>true,'actual_temporary_files'=>true,'native_windows'=>false,'production_changed'=>false]),PHP_EOL;
}finally{
 if($db->inTransaction())$db->rollBack();$db->query('select pg_advisory_unlock_all()');if(is_resource($child)){proc_terminate($child);foreach($pipes as$pipe)if(is_resource($pipe))fclose($pipe);proc_close($child);}if(is_resource($lock))fclose($lock);
 foreach(glob($dir.'/backup-restore/*')as$file)unlink($file);foreach(glob($dir.'/updates/*')as$file)unlink($file);foreach(glob($dir.'/*')as$file)if(is_file($file))unlink($file);rmdir($dir.'/backup-restore');rmdir($dir.'/updates');rmdir($dir);
}
