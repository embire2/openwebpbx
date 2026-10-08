<?php
/** Engine-refresh ordering with isolated transport/cache doubles; no live commands. */
if(PHP_SAPI!=='cli'){http_response_code(404);exit;}
final class pbx_refresh_trace {public static array $entries=[];}
class cache {public function delete(string $key):void{pbx_refresh_trace::$entries[]=['cache',$key];}}
class settings {public static function clear_cache():void{pbx_refresh_trace::$entries[]=['settings','clear'];}}
class event_socket {public static function api(string $command):string{pbx_refresh_trace::$entries[]=['api',$command];return '+OK';}}
function is_uuid(mixed $value):bool{return is_string($value)&&preg_match('/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/iD',$value)===1;}
class pbx_refresh_statement extends PDOStatement {
    public function bindValue(string|int $param,mixed $value,int $type=PDO::PARAM_STR):bool{return true;}
    public function execute(?array $params=null):bool{return true;}
    public function fetchColumn(int $column=0):mixed{return '{"users":{}}';}
}
class pbx_refresh_database extends PDO {
    public function __construct(){}
    public function prepare(string $query,array $options=[]):PDOStatement|false{return new pbx_refresh_statement;}
}
require dirname(__DIR__).'/resources/classes/pbx_admin.php';
$checks=0;$assert=static function(bool $ok,string $message)use(&$checks){if(!$ok)throw new RuntimeException($message);$checks++;};
$_SESSION=['domain_name'=>'refresh.example.invalid'];$domain='11111111-1111-4111-8111-111111111111';$trunk='22222222-2222-4222-8222-222222222222';
$class=new ReflectionClass(pbx_admin::class);$admin=$class->newInstanceWithoutConstructor();
$class->getProperty('domain')->setValue($admin,$domain);$class->getProperty('db')->setValue($admin,new pbx_refresh_database);
$changed=$class->getMethod('changed');$changed->invoke($admin,$trunk);
$entries=pbx_refresh_trace::$entries;$apis=array_values(array_map(static fn($entry)=>$entry[1],array_filter($entries,static fn($entry)=>$entry[0]==='api')));
$assert($apis===['reloadxml','reloadacl','sofia profile external killgw '.$trunk,'sofia profile external rescan'],'Trunk refresh did not reload ACL synchronously before gateway refresh');
$assert(in_array(['cache','dialplan:openweb-incoming:'.gethostname()],$entries,true),'Restored incoming public fragment was not invalidated');
$reload=array_search(['api','reloadacl'],$entries,true);
foreach(['configuration:acl.conf',gethostname().':configuration:acl.conf'] as $key){$position=array_search(['cache',$key],$entries,true);$assert($position!==false&&$position<$reload,'ACL cache was not invalidated before reload');}
pbx_refresh_trace::$entries=[];$changed->invoke($admin,null,'100');
$apis=array_values(array_map(static fn($entry)=>$entry[1],array_filter(pbx_refresh_trace::$entries,static fn($entry)=>$entry[0]==='api')));
$assert($apis===['reloadxml','callcenter_config queue unload 100@refresh.example.invalid'],'Non-trunk refresh unexpectedly changed provider ACLs');
pbx_refresh_trace::$entries=[];$changed->invoke($admin,'invalid-gateway');
$assert(!in_array(['api','reloadacl'],pbx_refresh_trace::$entries,true),'Invalid gateway triggered provider ACL reload');
echo 'PASS: '.$checks." isolated ACL cache and synchronous engine-refresh ordering checks; no live commands\n";
