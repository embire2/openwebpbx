<?php
/** Real socket-only PostgreSQL and owned-file controls; no installed Windows action. */
if(PHP_SAPI!=='cli')exit(2);
$dsn=getenv('OPENWEB_CDR_OBSERVER_DSN');$work=getenv('OPENWEB_CDR_OBSERVER_WORK');
if(!is_string($dsn)||!preg_match('~^pgsql:host=/tmp/openweb-cdr-observer-[a-f0-9]{12}/socket;port=58479;dbname=postgres$~D',$dsn)||!is_string($work)||!preg_match('~^/tmp/openweb-cdr-observer-[a-f0-9]{12}/work$~D',$work)||!is_dir($work))throw new RuntimeException('An isolated observer fixture is required.');
$db=new PDO($dsn,'postgres',null,[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);
if($db->query('select inet_server_addr() is null')->fetchColumn()!==true)throw new RuntimeException('Socket-only observer fixture required.');
require __DIR__.'/windows_cdr_observation.php';
$id=static fn():string=>vsprintf('%s%s-%s-%s-%s-%s%s%s',str_split(bin2hex(random_bytes(16)),4));
$domain=$id();$foreign=$id();$caller=$id();$target=$id();$cdr=$id();$realm='pbx-0123456789ab.fixture.invalid';$sip=str_repeat('a',24).'@localfixture';$spool=$work.'/xml_cdr';mkdir($spool,0700);file_put_contents($spool.'/foreign.keep','foreign inert sentinel');
$users=[['number'=>'8100','auth'=>'fixture-8100','extension_uuid'=>$caller,'domain_uuid'=>$domain],['number'=>'8101','auth'=>'8102','extension_uuid'=>$target,'domain_uuid'=>$domain]];
$db->exec('create table v_domains(domain_uuid uuid primary key,domain_name text);create table v_extensions(extension_uuid uuid primary key,domain_uuid uuid,extension text);create table v_xml_cdr(xml_cdr_uuid uuid primary key,domain_uuid uuid,extension_uuid uuid,caller_id_number text,destination_number text,direction text,billsec numeric,json jsonb);create table v_pbx_call_history(domain_uuid uuid,owner_number text,party_number text,call_type text,end_status text,source_id text)');
$q=static function(string$sql,array$args=[])use($db):PDOStatement{$p=$db->prepare($sql);$p->execute($args);return$p;};
$q('insert into v_domains values(?,?),(?,?)',[$domain,$realm,$foreign,'foreign.invalid']);$q('insert into v_extensions values(?,?,?),(?,?,?)',[$caller,$domain,'fixture-8100',$target,$domain,'8102']);
$count=0;$ok=static function(bool$v)use(&$count):void{if(!$v)throw new RuntimeException('CDR observer control failed '.($count+1));$count++;};
$snapshot=static function()use($db):array{$r=[];foreach(['v_domains','v_extensions','v_xml_cdr','v_pbx_call_history']as$t)$r[$t]=$db->query('select coalesce(json_agg(x order by row_to_json(x)::text),\'[]\') from '.$t.' x')->fetchColumn();return$r;};
$read=static function(?string$c=null,?array$u=null,?string$p=null)use($db,$domain,$realm,$sip,$users,$spool,$snapshot,$ok):array{$before=$snapshot();try{return windows_native_cdr_observation($db,$domain,$realm,$c??$sip,$u??$users,$p??$spool);}finally{$ok($snapshot()===$before);$ok(!$db->inTransaction());$ok(file_get_contents($spool.'/foreign.keep')==='foreign inert sentinel');}};
$refuse=static function(callable$f)use($ok):void{$bad=false;try{$f();}catch(RuntimeException){$bad=true;}$ok($bad);};
$seedCdr=static function()use($q,$cdr,$domain,$caller,$sip):void{$q("insert into v_xml_cdr values(?,?,?,'8100','8101','local',3,?::jsonb)",[$cdr,$domain,$caller,json_encode(['variables'=>['sip_call_id'=>$sip,'openweb_scope_origin'=>'8100','openweb_scope_target'=>'8101']],JSON_THROW_ON_ERROR)]);};
$seedHistory=static function()use($q,$domain,$cdr):void{foreach(['8100','8101']as$n)$q('insert into v_pbx_call_history values(?,?,?,?,?,?)',[$domain,$n,$n==='8100'?'8101':'8100',$n==='8100'?'InternalOutbound':'InternalInbound','Answered','native/'.$cdr.'/'.$n]);};
$r=$read();$ok(!$r['completed']&&!$r['spool_absent']&&$r['cdr_rows']===0);
$seedCdr();$r=$read();$ok($r['record_scope_exact']&&$r['answered_cdr_rows']===1&&$r['spool_absent']&&!$r['completed']);
$seedHistory();$r=$read();$ok($r['completed']&&$r['history_rows']===2&&$r['history_owner_rows']===2&&$r['history_sources_exact']);$ok(array_keys($r)===['schema','state','read_only','scope','cdr_rows','answered_cdr_rows','history_rows','history_owner_rows','spool_files_present','quarantined_files_present','record_scope_exact','history_sources_exact','spool_absent','completed']);$ok(!preg_match('/'.$domain.'|'.$cdr.'|localfixture|foreign.keep/',json_encode($r)));
foreach([$cdr.'.cdr.xml','a_'.$cdr.'.cdr.xml']as$name){file_put_contents($spool.'/'.$name,'inert');$r=$read();$ok(!$r['completed']&&$r['spool_files_present']===1);unlink($spool.'/'.$name);}
mkdir($spool.'/failed');mkdir($spool.'/failed/openweb');file_put_contents($spool.'/failed/openweb/'.$cdr.'.cdr.xml','inert');$r=$read();$ok(!$r['completed']&&$r['quarantined_files_present']===1);unlink($spool.'/failed/openweb/'.$cdr.'.cdr.xml');rmdir($spool.'/failed/openweb');rmdir($spool.'/failed');
$q('update v_xml_cdr set billsec=0');$r=$read();$ok(!$r['completed']&&$r['answered_cdr_rows']===0);$q('update v_xml_cdr set billsec=3');
foreach(['domain_uuid'=>$foreign,'extension_uuid'=>$target,'caller_id_number'=>'8102','destination_number'=>'8102','direction'=>'inbound']as$field=>$bad){$db->beginTransaction();$old=$q('select '.$field.' from v_xml_cdr')->fetchColumn();$q('update v_xml_cdr set '.$field.'=?',[$bad]);$db->commit();$refuse(fn()=>$read());$q('update v_xml_cdr set '.$field.'=?',[$old]);}
$q('insert into v_xml_cdr select ?,domain_uuid,extension_uuid,caller_id_number,destination_number,direction,billsec,json from v_xml_cdr',[$id()]);$refuse(fn()=>$read());$q('delete from v_xml_cdr where xml_cdr_uuid<>?',[$cdr]);
$q('delete from v_pbx_call_history where owner_number=\'8101\'');$r=$read();$ok(!$r['completed']&&$r['history_rows']===1);$q('delete from v_pbx_call_history');$seedHistory();
foreach(['domain_uuid'=>$foreign,'owner_number'=>'8102','party_number'=>'8102','call_type'=>'Outbound','end_status'=>'Missed']as$field=>$bad){$old=$q('select '.$field.' from v_pbx_call_history where owner_number=\'8100\'')->fetchColumn();$q('update v_pbx_call_history set '.$field.'=? where source_id=?',[$bad,'native/'.$cdr.'/8100']);$refuse(fn()=>$read());$q('update v_pbx_call_history set '.$field.'=? where source_id=?',[$old,'native/'.$cdr.'/8100']);}
$q('insert into v_pbx_call_history select * from v_pbx_call_history where owner_number=\'8100\'');$refuse(fn()=>$read());$q('delete from v_pbx_call_history');$seedHistory();
foreach(['wrong',str_repeat('a',24).'@foreign',str_repeat('a',25).'@localfixture']as$bad)$refuse(fn()=>$read($bad));
$bad=$users;$bad[]=$users[0];$refuse(fn()=>$read(null,$bad));$bad=$users;$bad[0]['domain_uuid']=$foreign;$refuse(fn()=>$read(null,$bad));$bad=$users;$bad[0]['auth']='wrong';$refuse(fn()=>$read(null,$bad));
$db->beginTransaction();$refuse(fn()=>windows_native_cdr_observation($db,$domain,$realm,$sip,$users,$spool));$ok($db->inTransaction());$db->rollBack();
symlink($spool,$work.'/spool-link');$refuse(fn()=>$read(null,null,$work.'/spool-link'));unlink($work.'/spool-link');
mkdir($spool.'/'.$cdr.'.cdr.xml');$refuse(fn()=>$read());rmdir($spool.'/'.$cdr.'.cdr.xml');
symlink($work,$spool.'/failed');$refuse(fn()=>$read());unlink($spool.'/failed');$r=$read();$ok($r['completed']);
echo json_encode(['schema'=>1,'state'=>'passed','checks'=>$count,'actual_postgresql'=>true,'actual_owned_filesystem'=>true,'read_only_rows_exact'=>true,'foreign_file_preserved'=>true,'native_windows'=>false,'actual_importer_executed'=>false],JSON_THROW_ON_ERROR),PHP_EOL;
