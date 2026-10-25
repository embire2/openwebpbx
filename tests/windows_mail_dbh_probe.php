<?php
// Only a newly installed, empty hosted factory. Never emits credentials/audio/query text.
if(PHP_SAPI!=='cli'||PHP_OS_FAMILY!=='Windows'||getenv('GITHUB_ACTIONS')!=='true'||getenv('RUNNER_ENVIRONMENT')!=='github-hosted'||getenv('GITHUB_REPOSITORY')!=='embire2/openwebpbx')exit(2);
set_exception_handler(static function(Throwable $e):void{echo json_encode(['schema'=>1,'state'=>'failed','error_type'=>get_class($e),'source_line'=>$e->getLine()]),PHP_EOL;exit(1);});
$action=$argv[1]??'';$root=str_replace('\\','/',$argv[2]??'');
if(!preg_match('~^[A-Za-z]:/ProgramData/OpenWebPBX/mail-dbh-diagnostic/([a-f0-9]{24})$~D',$root,$match)||is_link($root)||!is_dir($root))throw new RuntimeException('Owned diagnostic directory required.');
$scope=$match[1];$plan=json_decode(file_get_contents($root.'/plan.private.json'),true,32,JSON_THROW_ON_ERROR);
$state=json_decode(file_get_contents('C:/ProgramData/OpenWebPBX/installation.json'),true,32,JSON_THROW_ON_ERROR);
if(empty($state['Completed'])||empty($state['RestoreServer'])||($state['AdminEmail']??'')!=='fixture@example.invalid')throw new RuntimeException('The new owned restore factory is required.');
$dbName='maildbh_'.$scope;$pdo=new PDO('pgsql:host=127.0.0.1;port=5433;dbname=postgres','postgres',$state['PostgresPassword'],[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);
$fixture=$root.'/fixture.private.json';$marker=$root.'/owned-database.private.json';
if($action==='setup'){
 if(is_file($marker)||$pdo->query("select count(*) from pg_database where datname='$dbName'")->fetchColumn()!=0)throw new RuntimeException('Retain the prior diagnostic.');
 $pdo->exec('CREATE DATABASE '.$dbName);$oid=(int)$pdo->query("select oid from pg_database where datname='$dbName'")->fetchColumn();$ownedJson=json_encode(['database'=>$dbName,'oid'=>$oid],JSON_THROW_ON_ERROR);if(file_put_contents($marker,$ownedJson)!==strlen($ownedJson))throw new RuntimeException('The new database ownership could not be retained.');
 $db=new PDO('pgsql:host=127.0.0.1;port=5433;dbname='.$dbName,'postgres',$state['PostgresPassword'],[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);
 $db->exec('CREATE TABLE v_email_queue(email_queue_uuid uuid primary key,domain_uuid uuid,hostname text,email_date timestamptz,email_from text,email_to text,email_subject text,email_body text,email_status text,email_uuid uuid,email_action_before text,email_action_after text,insert_date timestamptz);CREATE TABLE v_email_queue_attachments(email_queue_attachment_uuid uuid primary key,email_queue_uuid uuid,domain_uuid uuid,email_attachment_mime_type text,email_attachment_type text,email_attachment_path text,email_attachment_name text,email_attachment_base64 text,email_attachment_cid text,insert_date timestamptz)');
 foreach(['small'=>3200,'medium'=>102400,'large'=>512000]as$name=>$bytes){$data=pack('a4Va4a4VvvVVvva4V','RIFF',36+$bytes,'WAVE','fmt ',16,1,1,8000,16000,2,16,'data',$bytes).str_repeat("\0",$bytes);if(file_put_contents($root.'/'.$name.'.wav',$data)!==strlen($data))throw new RuntimeException('Owned WAV write failed.');}
 $input=['tag'=>'openweb-owned-windows-mail-dbh-v1','scope'=>$scope,'root'=>$root,'progress'=>$root.'/progress.safe.json','database'=>$dbName,'password'=>$state['PostgresPassword'],'domain'=>'00000000-0000-4000-8000-000000000100','code'=>$plan['code']];file_put_contents($fixture,json_encode($input,JSON_THROW_ON_ERROR));
 echo json_encode(['schema'=>1,'state'=>'prepared','owned_database'=>true,'invented_audio'=>true]),PHP_EOL;exit;
}
if($action==='cleanup'&&!is_file($marker)){
 if((int)$pdo->query("select count(*) from pg_database where datname='$dbName'")->fetchColumn()!==0)throw new RuntimeException('Unproved database ownership; retain this failed component.');
 echo json_encode(['schema'=>1,'state'=>'cleaned','owned_database_removed'=>true,'file_cleanup_deferred_until_engine_exit'=>true]),PHP_EOL;exit;
}
$owned=json_decode(file_get_contents($marker),true,16,JSON_THROW_ON_ERROR);
if($owned['database']!==$dbName||(int)$pdo->query("select oid from pg_database where datname='$dbName'")->fetchColumn()!==$owned['oid'])throw new RuntimeException('Exact owned database identity changed.');
if($action==='run'){
 $script=str_replace('\\','/',__DIR__.'/windows_mail_dbh_probe.lua');foreach([$script,$fixture]as$path)if(preg_match('/[\x00\r\n"\s]/',$path))throw new RuntimeException('Unquoted owned Lua paths required.');
 $socket=fsockopen('127.0.0.1',8021,$error,$text,5);if(!$socket)throw new RuntimeException('Owned native event socket unavailable.');stream_set_timeout($socket,2);
 $frame=static function()use($socket):string{$body='';$length=0;for($i=0;$i<32;$i++){$line=fgets($socket,8193);if($line===false)throw new RuntimeException('Owned event socket read refused.');$body.=$line;if(strlen($body)>8192)throw new RuntimeException('Owned event headers exceeded limit.');if(trim($line)==='')break;if(preg_match('/^Content-Length: ([0-9]+)\r?\n$/D',$line,$m))$length=(int)$m[1];}if($length>65536)throw new RuntimeException('Owned event body exceeded limit.');while($length>0){$part=fread($socket,$length);if($part===false||$part==='')throw new RuntimeException('Owned event body incomplete.');$body.=$part;$length-=strlen($part);}return$body;};
 try{if(!str_contains($frame(),'auth/request'))throw new RuntimeException('Owned event authentication unavailable.');fwrite($socket,'auth '.$state['SwitchPassword']."\n\n");if(!str_contains($frame(),'+OK accepted'))throw new RuntimeException('Owned event authentication refused.');fwrite($socket,'bgapi lua '.$script.' '.$fixture."\n\n");if(!str_contains($frame(),'+OK Job-UUID:'))throw new RuntimeException('Owned native Lua job refused.');}finally{fclose($socket);}
 $deadline=microtime(true)+15;$completed=0;$progress=null;
 do{clearstatcache(true,$root.'/progress.safe.json');if(is_file($root.'/progress.safe.json')&&filesize($root.'/progress.safe.json')<=65536){$raw=file_get_contents($root.'/progress.safe.json');try{$value=json_decode($raw,true,32,JSON_THROW_ON_ERROR);if(($value['schema']??null)===1){$progress=$value;if(($value['completed_cases']??0)>$completed){$completed=$value['completed_cases'];$deadline=microtime(true)+15;}if(in_array($value['state']??null,['passed','failed'],true))break;}}catch(JsonException $ignored){}}usleep(50000);}while(microtime(true)<$deadline);
 echo json_encode(['schema'=>1,'state'=>($progress['state']??'')==='passed'?'passed':'failed','per_case_observation_seconds'=>15,'timed_out'=>!in_array($progress['state']??null,['passed','failed'],true),'progress'=>$progress],JSON_THROW_ON_ERROR),PHP_EOL;exit(($progress['state']??'')==='passed'?0:1);
}
if($action==='cleanup'){
 $q=$pdo->prepare("select pg_terminate_backend(pid) from pg_stat_activity where datname=? and application_name=? and pid<>pg_backend_pid()");$q->execute([$dbName,'owned-mail-dbh-'.$scope]);
 $pdo->exec('DROP DATABASE '.$dbName.' WITH(FORCE)');if($pdo->query("select count(*) from pg_database where datname='$dbName'")->fetchColumn()!=0)throw new RuntimeException('Owned database remains.');
 echo json_encode(['schema'=>1,'state'=>'cleaned','owned_database_removed'=>true,'file_cleanup_deferred_until_engine_exit'=>true]),PHP_EOL;exit;
}
if($action!=='inspect')throw new RuntimeException('Choose the owned diagnostic operation.');
$db=new PDO('pgsql:host=127.0.0.1;port=5433;dbname='.$dbName,'postgres',$state['PostgresPassword'],[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);$checks=[];
foreach(['small'=>3200,'medium'=>102400,'large'=>512000]as$name=>$bytes){$index=count($checks)+1;$queue=sprintf('00000000-0000-4000-8000-%012d',200+$index);$q=$db->prepare('select q.email_status,q.email_action_before,a.email_attachment_base64 from v_email_queue q join v_email_queue_attachments a using(email_queue_uuid) where q.email_queue_uuid=?');$q->execute([$queue]);$row=$q->fetch(PDO::FETCH_ASSOC);$audio=file_get_contents($root.'/'.$name.'.wav');$checks[]=['case'=>$name,'expected_bytes'=>$bytes+44,'file_sha256'=>hash('sha256',$audio),'queued'=>$row!==false,'marker_exact'=>$row&&$row['email_status']==='waiting'&&$row['email_action_before']==='voicemail-attachment-v1','audio_exact'=>$row&&base64_decode($row['email_attachment_base64'],true)===$audio];}
echo json_encode(['schema'=>1,'state'=>'observed','checks'=>$checks,'queue_rows'=>(int)$db->query('select count(*) from v_email_queue')->fetchColumn(),'attachment_rows'=>(int)$db->query('select count(*) from v_email_queue_attachments')->fetchColumn()],JSON_THROW_ON_ERROR),PHP_EOL;
