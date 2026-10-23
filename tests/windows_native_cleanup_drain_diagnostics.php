<?php
/** Actual QA drain/error functions with explicit PDO/settings/read-only ESL adapters. */
require __DIR__.'/windows-native-cleanup-drain.php';
require dirname(__DIR__).'/resources/classes/pbx_call_records.php';
class settings{public static string $dir;public function get(...$arguments){return self::$dir;}}
class event_socket{public static array $calls=[];public static function api(string $command):string{self::$calls[]=$command;if($command!=='show channels as json')throw new RuntimeException('Unexpected mutating API.');return '{"row_count":0,"rows":[]}';}}
class CleanupCountStatement extends PDOStatement{public function __construct(private int $count){}public function execute(?array $params=null):bool{return true;}public function fetchColumn(int $column=0):mixed{return $this->count;}}
class CleanupCountDatabase extends PDO{public array $queries=[];public function __construct(public int $count=1){}public function prepare(string $query,array $options=[]):PDOStatement|false{$this->queries[]=$query;if($query!=='select count(*) from v_domains where domain_uuid=? and domain_name=?')throw new RuntimeException('Unexpected cleanup query.');return new CleanupCountStatement($this->count);}}
$checks=0;
function check_drain(bool $value):void{global $checks;if(!$value)throw new RuntimeException('Drain diagnostic control failed at '.debug_backtrace(DEBUG_BACKTRACE_IGNORE_ARGS,1)[0]['line']);$checks++;}
$owned=sys_get_temp_dir().'/openweb-drain-diagnostics-'.bin2hex(random_bytes(16));mkdir($owned,0700);
$domains=['10000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000002'];
$fixture=['owned'=>['domain_name'=>'pbx-0123456789ab.invalid']];
try{
 settings::$dir=$owned.'/missing';$db=new CleanupCountDatabase;$observation=['input_scope_validated'=>true];
 try{windows_native_cleanup_drain($db,$fixture,$domains,$observation);throw new LogicException('Missing spool accepted.');}catch(RuntimeException $error){$record=windows_native_cleanup_drain_failure($error,$observation);}
 check_drain($record['stage']==='spool_path'&&$record['reason']==='spool_path'&&$record['owned_service_validated']===true&&$record['spool_directory_exists']===false&&$record['spool_directory_link']===false);
 check_drain(event_socket::$calls===['show channels as json']&&count($db->queries)===1&&!file_exists(settings::$dir));
 check_drain($record['source_basename']==='windows-native-cleanup-drain.php'&&$record['error_type']==='RuntimeException'&&$record['source_line']>0);
 check_drain(!str_contains(json_encode($record),$owned)&&!str_contains(json_encode($record),$fixture['owned']['domain_name'])&&!str_contains(json_encode($record),$domains[0]));
 $db=new CleanupCountDatabase(0);$observation=[];event_socket::$calls=[];
 try{windows_native_cleanup_drain($db,$fixture,$domains,$observation);throw new LogicException('Missing service accepted.');}catch(RuntimeException $error){$record=windows_native_cleanup_drain_failure($error,$observation);}
 check_drain($record['stage']==='owned_service_lookup'&&$record['reason']==='owned_service_missing'&&!isset($record['owned_service_validated'])&&event_socket::$calls===[]);
 foreach(['input_scope','bootstrap','spool_configuration','pre_owned_inventory','owned_service_lookup','owned_channels','spool_path','spool_inventory','spool_import','spool_quiet']as$stage){
  $record=windows_native_cleanup_drain_failure(new RuntimeException('PRIVATE arbitrary message/password/path'),['stage'=>$stage,'configured_spool_path'=>'PRIVATE','password'=>'PRIVATE']);
  check_drain($record['stage']===$stage&&$record['reason']==='other'&&!str_contains(json_encode($record),'PRIVATE')&&!isset($record['configured_spool_path']));
 }
 foreach(['input_scope_validated','owned_service_validated','spool_directory_exists','spool_directory_link','spool_expected_engine_log','configured_log_setting_present','native_log_authenticated','native_log_observed','configured_matches_native_log','native_log_spool_directory_exists']as$key){
  foreach([false,true]as$value){$record=windows_native_cleanup_drain_failure(new RuntimeException('PRIVATE'),[$key=>$value]);check_drain(array_key_exists($key,$record)&&$record[$key]===$value);}
  $record=windows_native_cleanup_drain_failure(new RuntimeException('PRIVATE'),[$key=>'true']);check_drain(!array_key_exists($key,$record));
 }
 foreach(['legacy_posix_path','native_engine_log','other']as$kind){$record=windows_native_cleanup_drain_failure(new RuntimeException('PRIVATE'),['configured_spool_kind'=>$kind]);check_drain($record['configured_spool_kind']===$kind);}
 $record=windows_native_cleanup_drain_failure(new LogicException('PRIVATE'),['stage'=>'PRIVATE','configured_spool_kind'=>'PRIVATE']);
 check_drain($record['error_type']==='external_error'&&$record['stage']==='input_scope'&&!isset($record['configured_spool_kind']));
 // These are lexical comparisons only; no native path is created or replaced.
 foreach([['C:/Program Files/FreeSWITCH/log/xml_cdr','C:\\Program Files\\FreeSWITCH\\log',true,'native_engine_log'],['c:\\PROGRAM FILES\\freeswitch\\log\\xml_cdr/','C:/Program Files/FreeSWITCH/log/',true,'native_engine_log'],['/var/log/freeswitch/xml_cdr','C:/Program Files/FreeSWITCH/log',false,'legacy_posix_path'],['C:/custom/xml_cdr','C:/Program Files/FreeSWITCH/log',false,'other']]as[$spool,$native,$match,$kind]){
  $commands=[];$result=windows_native_cleanup_log_observation($spool,static function($command)use(&$commands,$native){$commands[]=$command;return$native;});
  check_drain($commands===['global_getvar log_dir']&&$result['native_log_observed']===true&&$result['configured_matches_native_log']===$match&&$result['configured_spool_kind']===$kind);
  check_drain(!str_contains(json_encode($result),'FreeSWITCH')&&!str_contains(json_encode($result),'custom'));
 }
 foreach(['','_undef_','/var/log/freeswitch','C:relative',"C:/bad\npath",str_repeat('x',4097)]as$native){$result=windows_native_cleanup_log_observation('/var/log/freeswitch/xml_cdr',static fn($command)=>$native);check_drain($result===['native_log_observed'=>false,'configured_spool_kind'=>'legacy_posix_path']);}
 $error=new RuntimeException('Ordinary native spool required.');$original=windows_native_cleanup_drain_failure($error,['stage'=>'spool_path']);
 try{windows_native_cleanup_log_observation('PRIVATE',static function(){throw new RuntimeException('PRIVATE observation error');});}catch(Throwable){}
 check_drain(windows_native_cleanup_drain_failure($error,['stage'=>'spool_path'])===$original);
 // Direct unsupported-platform CLI refuses before any installed bootstrap/import.
 if(PHP_OS_FAMILY!=='Windows'){
  $process=proc_open([PHP_BINARY,__DIR__.'/windows-native-cleanup-drain.php','PRIVATE_INPUT'],[0=>['pipe','r'],1=>['pipe','w'],2=>['pipe','w']],$pipes);fclose($pipes[0]);$stdout=stream_get_contents($pipes[1]);$stderr=stream_get_contents($pipes[2]);fclose($pipes[1]);fclose($pipes[2]);$exit=proc_close($process);$record=json_decode($stdout,true,64,JSON_THROW_ON_ERROR);
  check_drain($exit===1&&$record['stage']==='input_scope'&&$record['reason']==='runner_scope'&&$record['state']==='failed'&&$stderr==="The owned disposable record drain refused.\n"&&!str_contains($stdout,'PRIVATE_INPUT'));
 }
 echo 'PASS '.$checks.' actual-source drain refusal/log-observation/privacy controls; PDO/settings/read-only ESL adapters only',PHP_EOL;
}finally{rmdir($owned);}
