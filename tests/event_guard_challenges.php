<?php
/** Replay actual service run-loop events with explicit DB/socket/firewall doubles.
 * The only subprocess is an owned fs_cli fixture. No PBX bootstrap, network,
 * customer database or host firewall is used. An old service source can be
 * supplied to demonstrate the original false-block regression.
 */
if (PHP_SAPI !== 'cli' || PHP_OS_FAMILY !== 'Linux') exit(2);
require dirname(__DIR__).'/app/event_guard/resources/interfaces/event_guard_interface.php';
$source=$argv[1]??dirname(__DIR__).'/app/event_guard/resources/classes/event_guard_service.php';
if (!is_string($source)||!is_file($source)) throw new RuntimeException('A service source file is required.');
final class guard_fixture {
    public static array $cases=[],$blocks=[],$writes=[],$queries=[],$cache=[],$cacheWrites=[],$registered=[];
    public static array $userLog=[],$acl=[],$socketCommands=[];
    public static int $index=0,$eventChecks=0,$priorBlockCount=0;
    public static string $registrationFile;
    public static ?event_guard_service $service=null;
}
class service {
    public bool $running=true;
    protected static object $config;
    public static function fixtureConfig():void {self::$config=new class {public function read():void {}};}
    public function debug($value):void {}
    public function warning($value):void {}
    public function info($value):void {}
    public function notice($value):void {}
}
class database {
    public function __construct(array $args) {}
    public function is_connected():bool {return true;}
    public function select(string $sql, mixed $args=null, string $mode='all'):mixed {
        guard_fixture::$queries[]=$sql;
        if(str_contains($sql,'from v_user_logs'))return isset(guard_fixture::$userLog[$args['remote_address']])?1:0;
        if(str_contains($sql,'from v_access_control_nodes'))return array_map(static fn($ip)=>['node_cidr'=>$ip],guard_fixture::$acl);
        throw new RuntimeException('Unexpected fixture query.');
    }
    public function save(array $rows,bool $unused):void {guard_fixture::$writes[]=$rows;}
}
class settings {
    public function __construct(array $args) {}
    public function get(string $category,string $name,mixed $default=null):mixed {return $name==='firewall_name'?'fixture':$default;}
}
class cache {
    public function get(string $name):mixed {return guard_fixture::$cache[$name]??null;}
    public function set(string $name,mixed $value):void {guard_fixture::$cacheWrites[$name]=$value;}
}
class event_guard_fixture implements event_guard_interface {
    public function __construct(settings $settings) {}
    public function block_add(string $ip,string $filter):bool {guard_fixture::$blocks[]=[$ip,$filter];return true;}
    public function block_delete(string $ip,string $filter):bool {throw new RuntimeException('No replay may unblock a source.');}
    public function block_exists(string $ip,string $filter):bool {throw new RuntimeException('Unexpected native rule query.');}
}
class permissions {
    public static function new():self {return new self;}
    public function add($permission,$scope):void {}
    public function delete($permission,$scope):void {}
}
function uuid():string {return '00000000-0000-4000-a000-'.str_pad((string)count(guard_fixture::$writes),12,'0',STR_PAD_LEFT);}
function check_cidr(string $cidr,string $ip):bool {return $cidr===$ip.'/32'||$cidr===$ip.'/128';}
class event_socket {
    public function connect():void {}
    public function connected():bool {return true;}
    public function request(string $command):array {guard_fixture::$socketCommands[]=$command;return ['Reply-Text'=>'+OK fixture'];}
    public function read_event():array {
        if(guard_fixture::$index>0){
            $previous=guard_fixture::$cases[guard_fixture::$index-1];
            $added=array_slice(guard_fixture::$blocks,guard_fixture::$priorBlockCount);
            $expected=isset($previous['expectedBlock'])?[[$previous['event']['network-ip'],$previous['expectedBlock']]]:[];
            if($added!==$expected)throw new RuntimeException('A challenge caused an office block or a genuine auth failure lost protection.');
            guard_fixture::$eventChecks++;
        }
        if(guard_fixture::$index>=count(guard_fixture::$cases)){
            guard_fixture::$service->running=false;
            return ['$'=>json_encode(['Event-Subclass'=>'fixture::done'])];
        }
        $case=guard_fixture::$cases[guard_fixture::$index++];
        guard_fixture::$priorBlockCount=count(guard_fixture::$blocks);
        guard_fixture::$cache=$case['cache']??[];guard_fixture::$userLog=$case['userLog']??[];guard_fixture::$acl=$case['acl']??[];
        $rows=$case['registered']??[];
        file_put_contents(guard_fixture::$registrationFile,json_encode(['row_count'=>count($rows),'rows'=>$rows]));
        return ['$'=>json_encode($case['event'],JSON_THROW_ON_ERROR)];
    }
}
require $source;
$checks=0;$ok=static function(bool $result,string $message)use(&$checks):void{if(!$result)throw new RuntimeException($message);$checks++;};
$temporary=sys_get_temp_dir().'/.openweb-guard-challenge-'.bin2hex(random_bytes(12));
if(!mkdir($temporary,0700))throw new RuntimeException('A private fixture directory is required.');
$oldPath=getenv('PATH');$oldRegs=getenv('OPENWEB_GUARD_FIXTURE_REGISTRATIONS');
try {
    guard_fixture::$registrationFile=$temporary.'/registrations.json';
    $cli=$temporary.'/fs_cli';
    file_put_contents($cli,'#!'.PHP_BINARY."\n<?php echo file_get_contents(getenv('OPENWEB_GUARD_FIXTURE_REGISTRATIONS'));\n");
    chmod($cli,0700);putenv('PATH='.$temporary);putenv('OPENWEB_GUARD_FIXTURE_REGISTRATIONS='.guard_fixture::$registrationFile);
    $base=['Event-Subclass'=>'sofia::pre_register','network-ip'=>'198.51.100.40','to-user'=>'','to-host'=>'192.168.10.20','from-user'=>'fixture-1000','from-host'=>'tenant-a.example.invalid','user-agent'=>'Yealink W60B fixture'];
    // Native pre_register lacks a method: private/public/IPv6/empty/malformed
    // From headers, stale leases and forged tenant names are all challenges.
    $hosts=['192.168.10.20','10.1.2.3','172.16.4.5','8.8.8.8','2001:db8::10','tenant-a.example.invalid','tenant-b.example.invalid','',null,[],str_repeat('x',65536)];
    foreach($hosts as$host)foreach(['fixture-1000','',null,[]]as$user){
        guard_fixture::$cases[]=['event'=>array_replace($base,['to-host'=>$host,'to-user'=>$user])];
    }
    // A challenge does not grant source trust: the same office can still be
    // blocked by a subsequent genuine failed digest under the original policy.
    $failure=array_replace($base,['Event-Subclass'=>'sofia::register_failure','to-user'=>'fictional-auth','to-host'=>'tenant-a.example.invalid','registration-type'=>'REGISTER']);
    guard_fixture::$cases[]=['event'=>$failure,'expectedBlock'=>'sip-auth-fail'];
    guard_fixture::$cases[]=['event'=>array_replace($failure,['network-ip'=>'198.51.100.41','registration-type'=>'INVITE','to-host'=>'192.168.10.20']),'expectedBlock'=>'sip-auth-fail'];
    guard_fixture::$cases[]=['event'=>array_replace($failure,['network-ip'=>'198.51.100.42','to-host'=>'8.8.8.8']),'expectedBlock'=>'sip-auth-fail'];
    guard_fixture::$cases[]=['event'=>array_replace($failure,['network-ip'=>'2001:db8::42']),'expectedBlock'=>'sip-auth-fail'];
    // Existing explicit administrator/cache/ACL/current-registration exemptions
    // remain unchanged. Merely asserting another tenant is no exemption.
    guard_fixture::$cases[]=['event'=>array_replace($failure,['network-ip'=>'198.51.100.50']),'cache'=>['switch:allowed:198.51.100.50'=>'true']];
    guard_fixture::$cases[]=['event'=>array_replace($failure,['network-ip'=>'198.51.100.51']),'userLog'=>['198.51.100.51'=>true]];
    guard_fixture::$cases[]=['event'=>array_replace($failure,['network-ip'=>'198.51.100.52']),'acl'=>['198.51.100.52/32']];
    guard_fixture::$cases[]=['event'=>array_replace($failure,['network-ip'=>'198.51.100.53']),'registered'=>[['network_ip'=>'198.51.100.53','reg_user'=>'fixture-1000','realm'=>'tenant-a.example.invalid']]];
    guard_fixture::$cases[]=['event'=>array_replace($failure,['network-ip'=>'198.51.100.54','to-host'=>'tenant-b.example.invalid']),'expectedBlock'=>'sip-auth-fail'];
    foreach(['bad;command','',null,[],str_repeat('x',65536)]as$sourceIp){
        // Malformed caller-controlled challenge data is ignored without access
        // lookups or a native mutation, not treated as authenticated identity.
        guard_fixture::$cases[]=['event'=>array_replace($base,['network-ip'=>$sourceIp])];
    }
    service::fixtureConfig();$worker=new event_guard_service;guard_fixture::$service=$worker;
    $ok($worker->run()===0,'Actual service run did not complete.');
    $expected=[['198.51.100.40','sip-auth-fail'],['198.51.100.41','sip-auth-fail'],['198.51.100.42','sip-auth-fail'],['2001:db8::42','sip-auth-fail'],['198.51.100.54','sip-auth-fail']];
    $ok(guard_fixture::$blocks===$expected,'A challenge caused an office block or a genuine auth failure lost protection.');
    $ok(count(guard_fixture::$writes)===count($expected),'Unexpected security ledger mutation.');
    foreach(guard_fixture::$writes as$i=>$write){$row=$write['event_guard_logs'][0];$ok($row['ip_address']===$expected[$i][0]&&$row['filter']==='sip-auth-fail'&&$row['log_status']==='blocked','Failure ledger correlation changed.');}
    $ok(!array_filter(guard_fixture::$blocks,static fn($entry)=>$entry[1]==='sip-auth-ip'),'Challenge-derived IP blocking remains enabled.');
    $ok(count(guard_fixture::$cases)===guard_fixture::$index&&guard_fixture::$eventChecks===count(guard_fixture::$cases),'Not every native-shaped event was replayed and checked.');
    $ok(guard_fixture::$cacheWrites===['switch:allowed:198.51.100.51'=>'true','switch:allowed:198.51.100.52'=>'true','switch:allowed:198.51.100.53'=>'true'],'Challenge input granted source trust or changed existing exemptions.');
    $ok(!array_filter(guard_fixture::$queries,static fn($sql)=>str_contains($sql,'v_extensions')||str_contains($sql,'v_pbx_restore')),'The security guard touched phone identities or routing.');
    echo json_encode(['checks'=>$checks+guard_fixture::$eventChecks,'replayed_actual_run_loop_events'=>count(guard_fixture::$cases),'challenge_variants'=>count($hosts)*4+5,'true_failure_blocks'=>count($expected),'socket_database_firewall_are_explicit_doubles'=>true,'owned_fs_cli_fixture'=>true,'no_customer_or_host_mutation'=>true],JSON_PRETTY_PRINT).PHP_EOL;
} finally {
    putenv($oldPath===false?'PATH':'PATH='.$oldPath);putenv($oldRegs===false?'OPENWEB_GUARD_FIXTURE_REGISTRATIONS':'OPENWEB_GUARD_FIXTURE_REGISTRATIONS='.$oldRegs);
    foreach([guard_fixture::$registrationFile,$temporary.'/fs_cli']as$file)if(is_file($file))unlink($file);
    rmdir($temporary);
}
