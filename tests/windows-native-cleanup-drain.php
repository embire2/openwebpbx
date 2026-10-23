<?php
/** SPDX-License-Identifier: AGPL-3.0-or-later. Drain only the disposable fixture's actual CDR spool. */
require __DIR__.'/windows-native-cleanup-rows.php';
function windows_native_cleanup_drain(PDO $db,array $s,array $domains,?array &$observation=null):array{
    $observation??=[];$observation['stage']='spool_configuration';
    $worker=new class($db) extends pbx_call_records {public function spool():string{return $this->directory();}};
    $dir=$worker->spool();$observation['configured_spool_path']=$dir;
    $observation['spool_directory_exists']=is_dir($dir);$observation['spool_directory_link']=is_link($dir);
    $observation['spool_expected_engine_log']=strcasecmp(str_replace('\\','/',rtrim($dir,'/\\')),'C:/Program Files/FreeSWITCH/log/xml_cdr')===0;
    if(!$domains){
        $observation['stage']='pre_owned_inventory';
        // Before discover there are no recorded owned IDs. Never infer them or
        // kill/import a call here. The unchanged fixture performs its own exact
        // service lookup and factory/identity checks, including its no-service path.
        $inventory=json_decode(event_socket::api('show channels as json'),true,64,JSON_THROW_ON_ERROR);$rows=$inventory['rows']??[];
        if(!is_array($rows)||$rows!==[]||($inventory['row_count']??null)!==0||is_link($dir)||(file_exists($dir)&&!is_dir($dir)))throw new RuntimeException('An idle pre-owned factory is required.');
        if(is_dir($dir))foreach(new DirectoryIterator($dir)as$f)if(preg_match('/^(?:a_)?[a-f0-9-]{36}\.cdr\.xml$/D',$f->getFilename()))throw new RuntimeException('Unscoped pre-owned spool is not empty.');
        return ['schema'=>1,'state'=>'passed','pre_owned'=>true,'owned_channels_ended'=>0,'actual_importer'=>false,'spool_empty_stable_ms'=>0,'imported'=>0,'foreign_records_imported'=>false];
    }
    $observation['stage']='owned_service_lookup';$realm=$s['owned']['domain_name'];
    $check=$db->prepare('select count(*) from v_domains where domain_uuid=? and domain_name=?');$check->execute([$domains[0],$realm]);
    if((int)$check->fetchColumn()!==1)throw new RuntimeException('The exact disposable service must still exist before draining.');
    $observation['owned_service_validated']=true;$observation['stage']='owned_channels';
    $callIds=[];$deadline=hrtime(true)+20000000000;
    do{
        $rows=json_decode(event_socket::api('show channels as json'),true,64,JSON_THROW_ON_ERROR)['rows']??[];
        if(!is_array($rows)||count($rows)>128)throw new RuntimeException('Bounded channel inventory required.');
        $owned=[];
        foreach($rows as$row)if(($row['context']??'')===$realm||str_ends_with($row['presence_id']??'','@'.$realm)){
            $id=$row['uuid']??'';if(!is_uuid($id))throw new RuntimeException('Invalid owned channel.');$owned[]=$id;
            if(!isset($callIds[$id])){event_socket::api('uuid_kill '.$id.' NORMAL_CLEARING');$callIds[$id]=true;}
        }
        if(!$owned)break;
        if(hrtime(true)>$deadline)throw new RuntimeException('Owned channels did not settle.');usleep(100000);
    }while(true);
    // Expose only the real importer's configured directory, with unchanged tick().
    $observation['stage']='spool_path';
    if(!is_dir($dir)||is_link($dir))throw new RuntimeException('Ordinary native spool required.');
    $quiet=null;$imported=0;
    do{
        $observation['stage']='spool_inventory';$files=[];
        foreach(new DirectoryIterator($dir)as$f){
            if($f->isDot()||$f->isDir())continue;$name=$f->getFilename();
            if(!preg_match('/^(?:a_)?([a-f0-9-]{36})\.cdr\.xml$/D',$name,$m))continue;
            if(!$f->isFile()||$f->isLink()||$f->getSize()>3000000||count($files)>=256)throw new RuntimeException('Ordinary bounded fixture spool required.');
            $v=pbx_call_records::variables(file_get_contents($f->getPathname()));
            if(!in_array($v['domain_uuid']??null,$domains,true)||($v['domain_name']??'')!==$realm||($v['uuid']??$v['call_uuid']??'')!==$m[1])throw new RuntimeException('Foreign native spool record refused before importing.');
            $files[]=$name;
        }
        if($files){$observation['stage']='spool_import';$quiet=null;$result=$worker->tick(256);if($result['quarantined']||$result['retained'])throw new RuntimeException('Owned native records could not be durably imported.');$imported+=$result['imported'];}
        elseif($quiet===null){$quiet=hrtime(true);}
        elseif(hrtime(true)-$quiet>=3000000000)break;
        $observation['stage']='spool_quiet';if(hrtime(true)>$deadline)throw new RuntimeException('Owned native record drain timed out.');usleep(100000);
    }while(true);
    return ['schema'=>1,'state'=>'passed','pre_owned'=>false,'owned_channels_ended'=>count($callIds),'actual_importer'=>true,'spool_empty_stable_ms'=>3000,'imported'=>min(1000000,$imported),'foreign_records_imported'=>false];
}
function windows_native_cleanup_log_observation(string $spool,callable $api):array{
    $normalize=static fn(string$p):string=>strtolower(rtrim(str_replace('\\','/',$p),'/'));
    $out=['native_log_observed'=>false,'configured_spool_kind'=>$normalize($spool)==='/var/log/freeswitch/xml_cdr'?'legacy_posix_path':'other'];
    $log=trim((string)$api('global_getvar log_dir'));
    if(strlen($log)>4096||preg_match('/[\x00-\x1f]/',$log)||!preg_match('~^[A-Za-z]:[/\\\\]~D',$log))return$out;
    $native=rtrim($log,'/\\').'/xml_cdr';$match=$normalize($spool)===$normalize($native);
    $out['native_log_observed']=true;$out['configured_matches_native_log']=$match;$out['native_log_spool_directory_exists']=is_dir($native);
    if($match)$out['configured_spool_kind']='native_engine_log';return$out;
}
function windows_native_cleanup_drain_failure(Throwable $error,array $observation):array{
    $stages=['input_scope','bootstrap','spool_configuration','pre_owned_inventory','owned_service_lookup','owned_channels','spool_path','spool_inventory','spool_import','spool_quiet'];
    $reasons=[
      'Exact owned hosted fixture required.'=>'input_scope','Original factory administrator required.'=>'input_scope','Owned fixture identifiers required.'=>'input_scope','Unrelated administrator and exact fictional service required.'=>'input_scope','Disposable Windows runner required.'=>'runner_scope','Protected fixture input required.'=>'input_path',
      'An idle pre-owned factory is required.'=>'pre_owned_not_idle','Unscoped pre-owned spool is not empty.'=>'pre_owned_spool_present','The exact disposable service must still exist before draining.'=>'owned_service_missing','Bounded channel inventory required.'=>'channel_inventory','Invalid owned channel.'=>'channel_identity','Owned channels did not settle.'=>'channel_timeout','Ordinary native spool required.'=>'spool_path','Ordinary bounded fixture spool required.'=>'spool_inventory','Foreign native spool record refused before importing.'=>'foreign_spool_record','Owned native records could not be durably imported.'=>'import_refused','Owned native record drain timed out.'=>'spool_timeout'];
    $source=basename(str_replace('\\','/',$error->getFile()));
    if(!in_array($source,['windows-native-cleanup-drain.php','windows-native-cleanup-rows.php','pbx_call_records.php','settings.php','require.php','database.php','event_socket.php','config.php'],true))$source='external_component';
    $type=get_class($error);if(!in_array($type,['RuntimeException','InvalidArgumentException','PDOException','JsonException','Error','TypeError','ValueError','ErrorException','Exception'],true))$type='external_error';
    $record=['schema'=>1,'producer'=>'windows-native-cleanup-drain.php','state'=>'failed','stage'=>in_array($observation['stage']??null,$stages,true)?$observation['stage']:'input_scope','reason'=>$reasons[$error->getMessage()]??'other','error_type'=>$type,'source_basename'=>$source,'source_line'=>max(1,min(100000,$error->getLine()))];
    foreach(['input_scope_validated','owned_service_validated','spool_directory_exists','spool_directory_link','spool_expected_engine_log','configured_log_setting_present','native_log_authenticated','native_log_observed','configured_matches_native_log','native_log_spool_directory_exists']as$key)if(is_bool($observation[$key]??null))$record[$key]=$observation[$key];
    if(in_array($observation['configured_spool_kind']??null,['legacy_posix_path','native_engine_log','other'],true))$record['configured_spool_kind']=$observation['configured_spool_kind'];
    return$record;
}
if(realpath($_SERVER['SCRIPT_FILENAME']??'')===__FILE__){
 $observation=['stage'=>'input_scope'];$started=microtime(true);
 try{[$s,$domains]=windows_native_cleanup_input($argv[1]??'',true);$observation['input_scope_validated']=true;$observation['stage']='bootstrap';require 'C:/OpenWebPBX/web/resources/require.php';echo json_encode(windows_native_cleanup_drain($database->db,$s,$domains,$observation),JSON_THROW_ON_ERROR),PHP_EOL;}
 catch(Throwable$e){
  // Extra failure observation cannot replace the original refusal or change
  // the configured importer path. A fast refusal leaves time for one bounded,
  // separately authenticated loopback getvar through the installed reader.
  if(isset($observation['configured_spool_path'])&&microtime(true)-$started<3){
   try{$observation['configured_log_setting_present']=(new settings)->get('switch','log',null)!==null;}catch(Throwable){}
   try{require_once 'C:/OpenWebPBX/tools/public-listeners-esl.php';$configuration=config::load();$reader=new windows_public_listener_esl((string)$configuration->get('switch.event_socket.host','127.0.0.1'),(int)$configuration->get('switch.event_socket.port',8021),(string)$configuration->get('switch.event_socket.password'));$observation['native_log_authenticated']=true;$observation=array_replace($observation,windows_native_cleanup_log_observation($observation['configured_spool_path'],$reader->api(...)));}catch(Throwable){$observation['native_log_observed']=false;}
  }
  echo json_encode(windows_native_cleanup_drain_failure($e,$observation),JSON_THROW_ON_ERROR),PHP_EOL;fwrite(STDERR,'The owned disposable record drain refused.'.PHP_EOL);exit(1);
 }
}
