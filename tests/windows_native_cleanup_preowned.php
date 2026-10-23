<?php
/** Actual pre-owned function with explicit read-only ESL/settings/PDO adapters. */
require __DIR__.'/windows-native-cleanup-drain.php';require dirname(__DIR__).'/resources/classes/pbx_call_records.php';
class settings{public static string$dir;public function get(...$p){return self::$dir;}}
class event_socket{public static array$inventory=['row_count'=>0];public static array$calls=[];public static function api(string$command):string{self::$calls[]=$command;if($command!=='show channels as json')throw new RuntimeException('Unexpected mutating API.');return json_encode(self::$inventory);}}
class NoDatabaseQueries extends PDO{public function __construct(){}public function prepare(string$query,array$options=[]):PDOStatement|false{throw new RuntimeException('Pre-owned cleanup queried customer data.');}}
$dir=sys_get_temp_dir().'/openweb-preowned-'.bin2hex(random_bytes(16));mkdir($dir,0700);mkdir($dir.'/xml_cdr',0700);settings::$dir=$dir;$checks=0;
function check_pre(bool$v):void{global$checks;if(!$v)throw new RuntimeException('Pre-owned cleanup control failed.');$checks++;}
try{
 $db=new NoDatabaseQueries;$out=windows_native_cleanup_drain($db,[],[]);check_pre($out['pre_owned']===true&&$out['actual_importer']===false&&$out['owned_channels_ended']===0&&$out['imported']===0);check_pre(event_socket::$calls===['show channels as json']);
 foreach([['rows'=>[]],['row_count'=>'0'],['row_count'=>1,'rows'=>[['uuid'=>'FOREIGN']]],['row_count'=>0,'rows'=>'FOREIGN']]as$inventory){event_socket::$inventory=$inventory;$failed=false;try{windows_native_cleanup_drain($db,[],[]);}catch(RuntimeException){$failed=true;}check_pre($failed);}
 event_socket::$inventory=['row_count'=>0];$file=$dir.'/xml_cdr/10000000-0000-0000-0000-000000000001.cdr.xml';file_put_contents($file,'FOREIGN_PRIVATE');$before=hash_file('sha256',$file);$failed=false;try{windows_native_cleanup_drain($db,[],[]);}catch(RuntimeException){$failed=true;}check_pre($failed&&hash_file('sha256',$file)===$before);unlink($file);
 check_pre(array_unique(event_socket::$calls)===['show channels as json']);
 echo 'PASS '.$checks.' actual pre-owned drain idle/unknown/active/spool refusal controls; read-only ESL/settings/PDO adapters only',PHP_EOL;
}finally{rmdir($dir.'/xml_cdr');rmdir($dir);}
