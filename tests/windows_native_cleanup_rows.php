<?php
/** Actual PostgreSQL read-only observer controls; explicitly owned socket cluster only. */
require __DIR__.'/windows-native-cleanup-rows.php';
$c=json_decode(file_get_contents($argv[1]??''),true,64,JSON_THROW_ON_ERROR);
if(($c['production_connection']??null)!==false||($c['listen_addresses']??null)!==''||!preg_match('~^/tmp/openweb-cleanup-pg-[a-f0-9]{32}$~D',$c['root']??'')||($c['socket']??null)!==$c['root']||$c['dsn']!=='pgsql:host='.$c['socket'].';port='.$c['port'].';dbname=postgres')throw new RuntimeException('Owned socket-only cluster required.');
$db=new PDO($c['dsn'],$c['user'],null,[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);
if($db->query('show data_directory')->fetchColumn()!==$c['root'].'/data'||$db->query('show listen_addresses')->fetchColumn()!=='')throw new RuntimeException('Owned isolated server identity differs.');
$checks=0;function check(bool$v):void{global$checks;if(!$v)throw new RuntimeException('Cleanup PG observer control failed.');$checks++;}
$d=['10000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000002'];$foreign='10000000-0000-0000-0000-000000000003';
$before=windows_native_cleanup_rows($db,$d);check($before['leftover_rows']===0&&$before['all_tables_queried']);check(!$db->inTransaction());
$map=['v_pbx_phone_health_state'=>'health','v_call_center_queues'=>'queue','v_pbx_jobs'=>'jobs','v_email_queue'=>'mail','v_pbx_cmb_requests'=>'callback','v_pbx_unknown_private'=>'other'];
$created=[];
try{
 foreach($map as$table=>$category){$db->exec('create table '.$table.'(domain_uuid uuid,value text)');$created[]=$table;$q=$db->prepare('insert into '.$table.' values(?,?)');$q->execute([$d[0],'PRIVATE_SENSITIVE_VALUE']);$q->execute([$foreign,'FOREIGN_PRIVATE']);}
 $snap=static function()use($db,$created):array{$out=[];foreach($created as$t)$out[$t]=$db->query('select row_to_json(x)::text from '.$t.' x order by domain_uuid')->fetchAll(PDO::FETCH_COLUMN);return$out;};
 $original=$snap();$row=windows_native_cleanup_rows($db,$d);check($snap()===$original);check($row['leftover_rows']===6&&$row['leftover_tables']===6);check($row['read_only']&&$row['all_tables_queried']&&!$row['counts_capped']);
 foreach($map as$category)check($row['categories'][$category]===1);
 check(!str_contains(json_encode($row),'PRIVATE')&&!str_contains(json_encode($row),'10000000')&&!str_contains(json_encode($row),'v_pbx_'));
 foreach([[],[$d[0]],[$d[0],$d[0]],[$d[0],"');delete from v_domains;--"],[$d[0],3]]as$invalid){$failed=false;try{windows_native_cleanup_rows($db,$invalid);}catch(InvalidArgumentException){$failed=true;}check($failed&&!$db->inTransaction()&&$snap()===$original);}
 $db->beginTransaction();$failed=false;try{windows_native_cleanup_rows($db,$d);}catch(InvalidArgumentException){$failed=true;}check($failed&&$db->inTransaction());$db->rollBack();
 // A real separate backend owns the table lock; observer must fail promptly,
 // leave its transaction closed, and preserve every fixture/foreign value.
 $other=new PDO($c['dsn'],$c['user'],null,[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);$other->beginTransaction();$other->exec('lock table v_pbx_unknown_private in access exclusive mode');$time=microtime(true);$failed=false;
 try{windows_native_cleanup_rows($db,$d);}catch(PDOException$e){$failed=$e->getCode()==='55P03';}
 check($failed&&microtime(true)-$time<3&&!$db->inTransaction());$other->rollBack();check($snap()===$original);
 $db->exec('create table "v_bad-name"(domain_uuid uuid)');$created[]='"v_bad-name"';$failed=false;try{windows_native_cleanup_rows($db,$d);}catch(RuntimeException){$failed=true;}check($failed&&!$db->inTransaction());
 // CLI refuses on Linux before loading the installed application or any DB.
 $p=proc_open([PHP_BINARY,__DIR__.'/windows-native-cleanup-rows.php','/foreign/input.json'],[0=>['pipe','r'],1=>['pipe','w'],2=>['pipe','w']],$pipes);fclose($pipes[0]);$out=stream_get_contents($pipes[1]);$err=stream_get_contents($pipes[2]);fclose($pipes[1]);fclose($pipes[2]);$exit=proc_close($p);check($exit===1&&$err===''&&json_decode($out,true)['state']==='unavailable');
 echo json_encode(['schema'=>1,'state'=>'passed','checks'=>$checks,'actual_postgresql'=>true,'socket_only'=>true,'read_only_rows_and_foreign_values_exact'=>true,'actual_lock_timeout_refusal'=>true,'protected_cli_refused_before_bootstrap'=>true],JSON_PRETTY_PRINT),PHP_EOL;
}finally{if($db->inTransaction())$db->rollBack();foreach(array_reverse($created)as$t)$db->exec('drop table '.$t);}
