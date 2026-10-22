<?php
/** Real loopback TCP/child PHP handshake regression. The peer models CUSTOM
 * subclass subscriptions independently of filters. No PBX or firewall access. */
if (PHP_SAPI !== 'cli') exit(2);
$classes=['sofia::register_failure','sofia::pre_register','event_guard:phone_health_unblock'];
if (($argv[1]??null)==='--client') {
    class config {
        public static function load(): self {return new self();}
        public function get(string $key,mixed $default=null): mixed {
            global $argv;
            return ['switch.event_socket.host'=>'127.0.0.1','switch.event_socket.port'=>(int)$argv[2],
                'switch.event_socket.password'=>'isolated-loopback-fixture'][$key]??$default;
        }
    }
    require $argv[3];$client=new pbx_windows_health_stream();
    try {
        $client->connect();$seen=[];$deadline=microtime(true)+.7;
        while(count($seen)<3&&microtime(true)<$deadline){
            $packet=$client->packet(.1);
            if(($packet['Content-Type']??null)!=='text/event-json')continue;
            $event=json_decode($packet['body'],true,16,JSON_THROW_ON_ERROR);
            if(in_array($event['Event-Subclass']??null,$classes,true))$seen[$event['Event-Subclass']]=true;
        }
        echo json_encode(['state'=>'connected','events'=>array_keys($seen)],JSON_THROW_ON_ERROR),PHP_EOL;
    } catch(Throwable $error) {
        echo json_encode(['state'=>'refused','error_type'=>get_class($error)],JSON_THROW_ON_ERROR),PHP_EOL;
    } finally {$client->close();}
    exit;
}
$source=$argv[1]??dirname(__DIR__).'/resources/classes/pbx_windows_health_stream.php';
if(!is_file($source))throw new RuntimeException('A local stream implementation is required.');
$checks=0;
$check=static function(bool $value,string $why)use(&$checks):void {
    if(!$value)throw new RuntimeException($why);$checks++;
};
foreach(['normal','during_subscription','auth_refused','subscribe_refused','filter_refused']as$case){
    $listener=stream_socket_server('tcp://127.0.0.1:0',$errno,$error);
    if(!$listener)throw new RuntimeException('The isolated loopback listener is unavailable.');
    $port=(int)substr(strrchr(stream_socket_get_name($listener,false),':'),1);
    $child=proc_open([PHP_BINARY,'-n',__FILE__,'--client',(string)$port,$source],
        [0=>['pipe','r'],1=>['pipe','w'],2=>['pipe','w']],$pipes);
    if(!is_resource($child)){fclose($listener);throw new RuntimeException('The isolated child could not start.');}
    $peer=null;
    try {
        fclose($pipes[0]);$peer=stream_socket_accept($listener,3);
        if(!$peer)throw new RuntimeException('The isolated child did not connect.');
        stream_set_timeout($peer,3);fwrite($peer,"Content-Type: auth/request\n\n");
        $subscribed=[];$filters=[];$injected=false;$commands=0;
        $events=static function($socket)use($classes):void {
            foreach($classes as$class){$body=json_encode(['Event-Subclass'=>$class,'fixture'=>true],JSON_THROW_ON_ERROR);
                fwrite($socket,"Content-Type: text/event-json\nContent-Length: ".strlen($body)."\n\n".$body);}
        };
        while($commands++<8){
            $command='';
            while(($line=fgets($peer))!==false){if($line==="\n"||$line==="\r\n")break;$command.=$line;}
            if($line===false)break;$command=rtrim($command,"\r\n");
            if(str_starts_with($command,'auth ')){
                $check($command==='auth isolated-loopback-fixture','The fixture used an unexpected credential.');
                fwrite($peer,'Content-Type: command/reply'."\nReply-Text: ".($case==='auth_refused'?'-ERR denied':'+OK accepted')."\n\n");
                if($case==='auth_refused')break;
            }elseif(str_starts_with($command,'event json CUSTOM')){
                $tokens=explode(' ',$command);$subscribed=array_slice($tokens,3);
                if($case==='subscribe_refused'){fwrite($peer,"Content-Type: command/reply\nReply-Text: -ERR denied\n\n");break;}
                if($case==='during_subscription'&&count(array_intersect($classes,$subscribed))===3){$events($peer);$injected=true;}
                fwrite($peer,"Content-Type: command/reply\nReply-Text: +OK event listener enabled\n\n");
            }elseif(str_starts_with($command,'filter Event-Subclass ')){
                $class=substr($command,22);$check(in_array($class,$classes,true),'The fixture received an unexpected event filter.');$filters[]=$class;
                if($case==='filter_refused'){fwrite($peer,"Content-Type: command/reply\nReply-Text: -ERR denied\n\n");break;}
                fwrite($peer,"Content-Type: command/reply\nReply-Text: +OK filter added\n\n");
                if(count($filters)===3){if(!$injected&&count(array_intersect($classes,$subscribed))===3)$events($peer);break;}
            }else throw new RuntimeException('The fixture received an unexpected command.');
        }
        // Keep the peer open through the client's bounded event wait so a
        // missing subscription is observed as missing events, not EOF.
        $output=stream_get_contents($pipes[1],8193);$errors=stream_get_contents($pipes[2],4097);
        $exit=proc_close($child);$child=null;
        $check($exit===0&&$errors===''&&is_string($output)&&strlen($output)<=8192,'The isolated client failed or exported an error.');
        $result=json_decode($output,true,16,JSON_THROW_ON_ERROR);
        if(in_array($case,['normal','during_subscription'],true)){
            $check(($result['state']??null)==='connected','A valid subscription was refused.');
            $check(($result['events']??null)===$classes,'CUSTOM events were not received in order.');
            $check(count($subscribed)===3&&count(array_unique($subscribed))===3&&count(array_diff($subscribed,$classes))===0,'The subscription included unexpected event types.');
        }else $check($result===['state'=>'refused','error_type'=>'RuntimeException'],'A rejected handshake was accepted.');
    }finally{
        if(is_resource($peer))fclose($peer);fclose($listener);
        foreach($pipes as$pipe)if(is_resource($pipe))fclose($pipe);
        if(is_resource($child)){proc_terminate($child);proc_close($child);}
    }
}
echo json_encode(['state'=>'passed','checks'=>$checks,'actual_loopback_tcp'=>true,'actual_php_child'=>true,
    'subscription_peer_double'=>true,'actual_windows_native'=>PHP_OS_FAMILY==='Windows','no_pbx_or_firewall_mutation'=>true],JSON_THROW_ON_ERROR),PHP_EOL;
