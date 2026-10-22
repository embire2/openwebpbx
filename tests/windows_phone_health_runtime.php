<?php
/** Actual files/locks/loopback TCP, no PBX bootstrap or host firewall changes. */
if(PHP_SAPI!=='cli')exit(2);
require dirname(__DIR__).'/resources/classes/pbx_windows_health_runtime.php';
require dirname(__DIR__).'/resources/classes/pbx_windows_health_stream.php';
require dirname(__DIR__).'/app/event_guard/resources/interfaces/event_guard_interface.php';
require dirname(__DIR__).'/app/event_guard/resources/classes/event_guard_windows.php';
$checks=0;$ok=static function(bool$v,string$m)use(&$checks){if(!$v)throw new RuntimeException($m);$checks++;};
$no=static function(callable$f,string$m)use($ok){try{$f();}catch(Throwable){$ok(true,$m);return;}$ok(false,$m);};
$dir=sys_get_temp_dir().'/openweb-health-runtime-'.bin2hex(random_bytes(6));mkdir($dir,0700);mkdir($dir.'/backup-restore');mkdir($dir.'/updates');$resources=[];
try{
 $ok(!pbx_windows_health_runtime::ready($dir),'Empty installation ready');
 file_put_contents($dir.'/installation.json','{"Completed":true}');$ok(pbx_windows_health_runtime::ready($dir),'Complete installation unavailable');
 $writes=0;$action=static function()use(&$writes){$writes++;return 'observed';};$ok(pbx_windows_health_runtime::locked($dir,$action)==='observed'&&$writes===1,'Unlocked complete instance not observed');
 $lock=fopen($dir.'/upgrade.lock','c+b');flock($lock,LOCK_EX);$ok(pbx_windows_health_runtime::locked($dir,$action)===null&&$writes===1,'Held upgrade lock permitted action');fclose($lock);
 foreach(['calls','jobs','updates','backups']as$hold){$file=$dir.'/backup-restore/hold-'.$hold;file_put_contents($file,'');$ok(!pbx_windows_health_runtime::ready($dir)&&pbx_windows_health_runtime::locked($dir,$action)===null&&$writes===1,'Restore hold permitted database/firewall action');unlink($file);}
 foreach(['prepared','restoring','recovery_required','unexpected',null]as$state){file_put_contents($dir.'/backup-restore/journal.json',json_encode(['state'=>$state]));$ok(!pbx_windows_health_runtime::ready($dir)&&pbx_windows_health_runtime::locked($dir,$action)===null&&$writes===1,'Restore recovery journal permitted action');}
 foreach(['restored','recovered']as$state){file_put_contents($dir.'/backup-restore/journal.json',json_encode(['state'=>$state]));$ok(pbx_windows_health_runtime::ready($dir),'Finished restore remained unavailable');}unlink($dir.'/backup-restore/journal.json');
 foreach(['installing','prepared','committed','recovery_required','unexpected',null]as$state){file_put_contents($dir.'/updates/install-journal.json',json_encode(['state'=>$state]));$ok(!pbx_windows_health_runtime::ready($dir)&&pbx_windows_health_runtime::locked($dir,$action)===null&&$writes===1,'Upgrade recovery journal permitted action');}
 foreach(['completed','rolled_back']as$state){file_put_contents($dir.'/updates/install-journal.json',json_encode(['state'=>$state]));$ok(pbx_windows_health_runtime::ready($dir),'Completed/rolled-back update unavailable');}unlink($dir.'/updates/install-journal.json');
 foreach(['not-json',str_repeat('x',1048577),'[]','{"Completed":"true"}']as$raw){file_put_contents($dir.'/installation.json',$raw);clearstatcache();$ok(!pbx_windows_health_runtime::ready($dir),'Malformed/oversize installation accepted');}file_put_contents($dir.'/installation.json','{"Completed":true}');clearstatcache();
 $pair=static function()use(&$resources):array{$server=stream_socket_server('tcp://127.0.0.1:0',$errno,$error);if(!$server)throw new RuntimeException('Local TCP fixture unavailable');$client=stream_socket_client('tcp://'.stream_socket_get_name($server,false));$peer=stream_socket_accept($server,1);fclose($server);stream_set_blocking($client,false);$resources[]=$client;$resources[]=$peer;$stream=new pbx_windows_health_stream();(new ReflectionProperty($stream,'socket'))->setValue($stream,$client);return [$stream,$peer];};
 [$stream,$peer]=$pair();$t=microtime(true);$ok($stream->packet(.025)===null&&microtime(true)-$t<.2,'Idle socket deadline not bounded');
 fwrite($peer,"Content-Ty");$ok($stream->packet(.01)===null,'Partial header emitted event');
 fwrite($peer,"pe: text/event-json\nContent-Length: 19\n\n{\"fixture\":");$ok($stream->packet(.01)===null,'Partial body emitted event');fwrite($peer,'"exact"}');$packet=$stream->packet(.1);$ok($packet['body']==='{"fixture":"exact"}','Delayed continuation lost body');
 fwrite($peer,"Content-Type: command/reply\nReply-Text: +OK accepted\n\nContent-Type: command/reply\r\nReply-Text: +OK second\r\n\r\n");$ok($stream->packet(.1)['Reply-Text']==='+OK accepted'&&$stream->packet(.1)['Reply-Text']==='+OK second','Adjacent LF/CRLF frames lost');
 $body=json_encode(['padding'=>str_repeat('x',8192)]);fwrite($peer,"Content-Type: text/event-json\nContent-Length: ".strlen($body)."\n\n".substr($body,0,33));$ok($stream->packet(.01)===null,'Large fragmented event emitted prematurely');fwrite($peer,substr($body,33));$ok($stream->packet(.1)['body']===$body,'8KiB event delayed body failed');
 $stream->close();
 foreach(["Content-Type: x\nContent-Type: y\n\n","Bad header\n\n","Content-Length: -1\n\n","Content-Length: 4194305\n\n",str_repeat('x',16385)]as$bad){[$stream,$peer]=$pair();fwrite($peer,$bad);$no(fn()=>$stream->packet(.1),'Malformed frame accepted');$stream->close();}
 [$stream,$peer]=$pair();fwrite($peer,"Content-Type: text/event-json\nContent-Length: 2\n\n{}Content-Type: command/reply\nReply-Text: +OK filter added\n\n");(new ReflectionMethod($stream,'reply'))->invoke($stream);$ok($stream->packet(.1)['body']==='{}','Event arriving during subscription was lost');$stream->close();
 $xml='<profiles><profile><name>internal</name><type>profile</type><data>sip:mod_sofia@192.0.2.10:5090</data><state>RUNNING (0)</state></profile><profile><type>profile</type><data>sips:mod_sofia@[2001:db8::1]:5091</data><state>RUNNING (0)</state></profile><profile><type>profile</type><data>sip:mod_sofia@127.0.0.1:5078</data><state>RUNNING (0)</state></profile><profile><type>profile</type><data>sips:mod_sofia@192.0.2.10:7443;transport=wss</data><state>RUNNING (0)</state></profile><gateway><data>sip:user@carrier.example.invalid:7777</data></gateway></profiles>';
 $ok(event_guard_windows::ports($xml)===['tcp'=>[5090,5091],'udp'=>[5090]],'Running profile listener scope wrong');
 foreach(['bad','<!DOCTYPE x><profiles/>',str_replace(':5090',':3389',$xml),str_replace(':5090',':22',$xml),'<profiles/>']as$bad)$no(fn()=>event_guard_windows::ports($bad),'Unsafe listener status accepted');
 class runtime_health_adapter_fixture extends event_guard_windows {public string $spool;protected function spoolDirectory():string{return $this->spool;}}
 $adapter=(new ReflectionClass(runtime_health_adapter_fixture::class))->newInstanceWithoutConstructor();$adapter->spool=getenv('OPENWEB_HEALTH_TEST_SPOOL')?:$dir;$run=new ReflectionMethod($adapter,'run');
 $ok($run->invoke($adapter,[PHP_BINARY,'-n','-r','echo "{\"state\":\"absent\"}";'])==='{"state":"absent"}','Temporary-handle subprocess response lost');
 $ok($run->invoke($adapter,[PHP_BINARY,'-n','-r','echo str_repeat("x",9000);'])===null,'Subprocess overflow accepted');
 $start=microtime(true);$ok($run->invoke($adapter,[PHP_BINARY,'-n','-r','sleep(20);'])===null&&microtime(true)-$start>=14.9&&microtime(true)-$start<16,'Subprocess deadline not bounded');
 echo json_encode(['checks'=>$checks,'actual_files_and_locks'=>true,'actual_loopback_tcp_frames'=>true,'actual_windows_native'=>PHP_OS_FAMILY==='Windows','no_pbx_or_firewall_mutation'=>true],JSON_PRETTY_PRINT),PHP_EOL;
}finally{foreach($resources as$r)if(is_resource($r))fclose($r);foreach(glob($dir.'/backup-restore/*')as$f)unlink($f);foreach(glob($dir.'/updates/*')as$f)unlink($f);foreach(glob($dir.'/*')as$f)if(is_file($f))unlink($f);rmdir($dir.'/backup-restore');rmdir($dir.'/updates');rmdir($dir);}
