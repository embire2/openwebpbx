<?php
/** Protected Windows task. Native events remain in private memory, never task logs. */
if(PHP_SAPI!=='cli'||PHP_OS_FAMILY!=='Windows'||!in_array($argv[1]??'',['once','service'],true))exit(2);
ini_set('display_errors','0');ini_set('log_errors','0');set_time_limit(0);
require 'C:/OpenWebPBX/web/resources/require.php';
$stream=new pbx_windows_health_stream();$connected=false;$nextScan=0;
try{
    $db=database::new()->db;$firewall=new event_guard_windows();$guard=new pbx_windows_event_guard($db,$firewall);
    do{
        if(!pbx_windows_health_runtime::ready(pbx_paths::state())){$stream->close();$connected=false;if(($argv[1]??'')==='once'){echo '{"state":"deferred"}',PHP_EOL;exit;}sleep(1);continue;}
        if(!$connected)try{$stream->connect();$connected=true;}catch(Throwable){$stream->close();$connected=false;}
        if(microtime(true)>=$nextScan){
            $safe=pbx_windows_health_runtime::locked(pbx_paths::state(),static function()use($db,$connected,$firewall){$raw=null;try{$candidate=pbx_windows_health_stream::api('show registrations as json');pbx_phone_health::registrations($candidate);$raw=$candidate;}catch(Throwable){}$r=pbx_phone_health::monitor($db,$raw,$connected&&$firewall->healthy());$out=['state'=>'observed','available'=>($r['available']??false)===true];foreach(['observed_contacts','checked_domains','open','new','resolved','queued']as$n){$count=$r[$n]??0;if(!is_int($count)||$count<0||$count>2000000)throw new RuntimeException('Invalid aggregate.');$out[$n]=$count;}return $out;});
            $nextScan=microtime(true)+30;
            if(($argv[1]??'')==='once'){echo json_encode($safe??['state'=>'deferred'],JSON_THROW_ON_ERROR),PHP_EOL;exit;}
        }
        if(!$connected){sleep(1);continue;}
        try{$packet=$stream->packet(1);if(($packet['Content-Type']??null)==='text/event-json'){$event=json_decode($packet['body'],true,32,JSON_THROW_ON_ERROR);if(is_array($event))pbx_windows_health_runtime::locked(pbx_paths::state(),static fn()=>$guard->consume($event));}}
        catch(Throwable){$stream->close();$connected=false;sleep(1);}
    }while(true);
}catch(Throwable){fwrite(STDERR,"Phone Health observation failed; existing incidents and security rules are retained.\n");exit(1);}
