<?php
/** Pure actual-parser and command-gate controls. No PBX, native rule or host changes. */
if(PHP_SAPI!=='cli')exit(2);
ini_set('display_errors','stderr');ini_set('log_errors','0');
require_once dirname(__DIR__).'/app/event_guard/resources/interfaces/event_guard_interface.php';
require_once dirname(__DIR__).'/app/event_guard/resources/classes/event_guard_windows.php';
require_once dirname(__DIR__).'/resources/classes/pbx_windows_health_stream.php';
/** Only expected-budget clean EOF may end a private fixture negotiation. */
function windows_phone_health_fixture_frame($peer,bool $expectedTimeout,string $expected):bool {
 $raw='';
 while(!str_ends_with($raw,"\n\n")){
  $line=fgets($peer,513);
  if($line===false){$meta=stream_get_meta_data($peer);if($expectedTimeout&&$raw===''&&feof($peer)&&!($meta['timed_out']??false))return false;throw new RuntimeException('Owned ESL fixture frame refused');}
  $raw.=$line;if(strlen($raw)>512)throw new RuntimeException('Owned ESL fixture frame refused');
 }
 if($raw!==$expected."\n\n")throw new RuntimeException('Owned ESL fixture frame refused');return true;
}
// Actual private loopback ESL integration fixture; no installed configuration.
if(($argv[1]??'')==='--esl-fixture'){
 $input=json_decode(stream_get_contents(STDIN),true,8,JSON_THROW_ON_ERROR);if(!is_bool($input['expect_timeout']??null))exit(2);$expectedTimeout=$input['expect_timeout'];
 $server=stream_socket_server('tcp://127.0.0.1:0',$errno,$error);if(!$server)exit(3);
 echo substr(strrchr(stream_socket_get_name($server,false),':'),1),"\n";flush();$peer=stream_socket_accept($server,3);fclose($server);if(!$peer)exit(4);stream_set_timeout($peer,3);
 $finish=static function(string$stage)use($peer):never{echo json_encode(['expected_timeout_stage'=>$stage],JSON_THROW_ON_ERROR),"\n";fclose($peer);exit(0);};
 @fwrite($peer,"Content-Type: auth/request\n\n");if(!windows_phone_health_fixture_frame($peer,$expectedTimeout,'auth '.$input['password']))$finish('auth_eof');
 @fwrite($peer,"Content-Type: command/reply\nReply-Text: +OK accepted\n\n");if(!windows_phone_health_fixture_frame($peer,$expectedTimeout,'api sofia status profile internal'))$finish('api_eof');
 usleep($input['delay_us']);@fwrite($peer,"Content-Type: api/response\nContent-Length: ".strlen($input['status'])."\n\n".$input['status']);if($expectedTimeout)$finish('api_complete');fclose($peer);exit(0);
}
function windows_phone_health_listener_checks():int {
 $checks=0;$ok=static function(bool$v,string$m)use(&$checks){if(!$v)throw new RuntimeException($m);$checks++;};
 $no=static function(callable$f,string$m)use($ok){try{$f();}catch(Throwable){$ok(true,$m);return;}$ok(false,$m);};
 $row=static fn(string$name,string$data,string$state='RUNNING (0)',string$type='profile')=>'<profile><name>'.htmlspecialchars($name,ENT_XML1).'</name><type>'.$type.'</type><data>'.htmlspecialchars($data,ENT_XML1).'</data><state>'.$state.'</state></profile>';
 // Pinned Sofia emits advertised URL separately from actual bind URI. TLS
 // global URL may be sip:, while TLS-BIND-URL is sips: with optional maddr.
 $xml='<profiles>'.$row('internal','sip:mod_sofia@127.0.0.1:5090').$row('internal','sip:mod_sofia@127.0.0.1:5091','RUNNING (0) (TLS)').'<alias><name>known-alias</name><type>alias</type><data>internal</data><state>ALIASED</state></alias></profiles>';
 $base="Name             \tinternal\nSIP-IP           \t192.0.2.10\nURL              \tsip:mod_sofia@127.0.0.1:5090\nBIND-URL         \tsip:mod_sofia@127.0.0.1:5090;maddr=192.0.2.10;transport=udp,tcp\nTLS-URL          \tsip:mod_sofia@127.0.0.1:5091\nTLS-BIND-URL     \tsips:mod_sofia@127.0.0.1:5091;maddr=192.0.2.10;transport=tls\n";
 $calls=[];$resolve=static function($name)use(&$calls,$base){$calls[]=$name;return $base;};
 $ok(event_guard_windows::ports($xml,$resolve)===['tcp'=>[5090,5091],'udp'=>[5090]],'NAT-advertised loopback masked actual bind or added UDP TLS');$ok($calls===['internal'],'Aliases or duplicate UDP/TLS rows caused extra profile queries');
 $ok(event_guard_windows::ports(str_replace('internal','123',$xml),fn()=>str_replace('internal','123',$base))===['tcp'=>[5090,5091],'udp'=>[5090]],'Valid numeric native profile name refused');
 $plainGlobal='<profiles>'.$row('internal','sip:mod_sofia@127.0.0.1:5090').'</profiles>';$ok(event_guard_windows::ports($plainGlobal,fn()=>$base)===['tcp'=>[5090,5091],'udp'=>[5090]],'Verified detailed TLS bind was silently omitted');
 $v6=str_replace(['192.0.2.10','@127.0.0.1:'],['2001:db8::10','@[::1]:'],$base);$ok(event_guard_windows::ports($xml,fn()=>$v6)===['tcp'=>[5090,5091],'udp'=>[5090]],'IPv6 actual maddr bind refused');
 $crlf=str_replace("\n","\r\n",$base);$ok(event_guard_windows::ports($xml,fn()=>$crlf)===['tcp'=>[5090,5091],'udp'=>[5090]],'CRLF native profile status refused');$no(fn()=>event_guard_windows::ports($xml,fn()=>$crlf."Name \tinternal\r\n"),'CRLF duplicate native field accepted');
 $noMaddr=str_replace(['@127.0.0.1:',';maddr=192.0.2.10'],['@192.0.2.10:',''],$base);$ok(event_guard_windows::ports($xml,fn()=>$noMaddr)===['tcp'=>[5090,5091],'udp'=>[5090]],'Direct bind without maddr refused');
 $noTransport=str_replace([';transport=udp,tcp',';transport=tls'],'',$base);$ok(event_guard_windows::ports($xml,fn()=>$noTransport)===['tcp'=>[5090,5091],'udp'=>[5090]],'Native default bind transports changed');
 $changedAdvert=str_replace('127.0.0.1','198.51.100.44',$xml);$ok(event_guard_windows::ports($changedAdvert,fn()=>$base)===event_guard_windows::ports($xml,fn()=>$base),'Advertised address influenced real listener selection');
 foreach(['127.0.0.1','127.9.2.3','::1','::ffff:127.0.0.1']as$ip){$status=str_replace('192.0.2.10',$ip,$base);$no(fn()=>event_guard_windows::ports($xml,fn()=>$status),'Actual loopback-only bind accepted');}
 $withLoop=$xml;$withLoop=str_replace('</profiles>',$row('private','sip:mod_sofia@198.51.100.1:5078').'</profiles>',$withLoop);$ok(event_guard_windows::ports($withLoop,fn($n)=>$n==='internal'?$base:str_replace(['internal','192.0.2.10'],['private','127.0.0.1'],$base))===['tcp'=>[5090,5091],'udp'=>[5090]],'Actual loopback profile polluted public port set');
 $missingTls=preg_replace('/^TLS-BIND-URL[^\n]*\n/m','',$base);$no(fn()=>event_guard_windows::ports($xml,fn()=>$missingTls),'Running TLS transport without native TLS bind accepted');
 $missingPlain=preg_replace('/^BIND-URL[^\n]*\n/m','',$base);$other=str_replace('</profiles>',$row('other','sip:mod_sofia@192.0.2.10:5090').'</profiles>',$xml);$no(fn()=>event_guard_windows::ports($other,fn($name)=>$name==='internal'?$missingPlain:str_replace('internal','other',$base)),'Missing required plain bind hidden by another profile UDP');
 $tlsGlobal='<profiles>'.$row('internal','sip:mod_sofia@127.0.0.1:5091','RUNNING (0) (TLS)').$row('other','sip:mod_sofia@192.0.2.10:5090').'</profiles>';$no(fn()=>event_guard_windows::ports($tlsGlobal,fn($name)=>$name==='internal'?$missingTls:str_replace('internal','other',$base)),'TLS-only global kind lost its required native bind');
 $bad=[
  str_replace("Name             \tinternal","Name             \tforeign",$base),
  str_replace("SIP-IP           \t192.0.2.10\n",'',$base),$base."SIP-IP \t192.0.2.10\n",
  str_replace('192.0.2.10','not-an-ip',$base),str_replace('maddr=192.0.2.10','maddr=192.0.2.11',$base),
  str_replace(';maddr=192.0.2.10','',$base),str_replace('transport=udp,tcp','transport=udp,tcp;maddr=192.0.2.10',$base),
  str_replace('transport=udp,tcp','transport=udp,tcp;transport=tcp',$base),str_replace('transport=udp,tcp','Transport=udp,tcp',$base),
  str_replace('transport=udp,tcp','transport=udp,tcp;foreign=value',$base),str_replace('transport=udp,tcp','transport=unknown',$base),
  str_replace('transport=tls','transport=tcp',$base),str_replace('sips:mod_sofia','sip:mod_sofia',$base),
  str_replace('sip:mod_sofia@127.0.0.1:5090','sips:mod_sofia@127.0.0.1:5090',$base),
  str_replace('transport=udp,tcp','transport=tcp',$base),
  "Name \tinternal\nSIP-IP \t192.0.2.10\n",$base."BIND-URL \tsip:mod_sofia@192.0.2.10:5090\n",
  $base."\0",$base.str_repeat('x',65537),null,[],
 ];
 foreach($bad as$status)$no(fn()=>event_guard_windows::ports($xml,fn()=>$status),'Malformed, foreign or ambiguous native status accepted');
 foreach([22,80,443,3389,5985,5986,65536,0]as$port){$status=str_replace(':5090',':'.$port,$base);$no(fn()=>event_guard_windows::ports($xml,fn()=>$status),'Protected or invalid native port accepted');}
 foreach(['bad','<!DOCTYPE x><profiles/>','<!ENTITY x><profiles/>','<profiles/>',str_repeat('x',1048577),str_replace('<name>internal</name>','',$xml),preg_replace('~<data>.*?</data>~','',$xml),str_replace('</data>','</data><data>duplicate</data>',$xml),str_replace('sip:mod_sofia@127.0.0.1:5090','not-an-advertised-URI',$xml),str_replace('internal','bad;status',$xml),str_replace('<type>profile</type>','<type>alias</type>',$xml),str_replace('RUNNING (0)','RUNNING_BAD',$xml),str_replace('</profiles>',$row('internal','sip:duplicate@127.0.0.1:5090').'</profiles>',$xml)]as$global){$n=0;$no(function()use($global,&$n,$base){event_guard_windows::ports($global,function()use(&$n,$base){$n++;return$base;});},'Malformed global inventory accepted');$ok($n===0,'Rejected global inventory made a native query');}
 $many='<profiles>';for($i=0;$i<33;$i++)$many.=$row('p'.$i,'sip:mod_sofia@127.0.0.1:5060');$many.='</profiles>';$n=0;$no(function()use($many,&$n,$base){event_guard_windows::ports($many,function()use(&$n,$base){$n++;return$base;});},'Unbounded native query inventory accepted');$ok($n===0,'Profile count was capped after native queries');
 $many='<profiles>';for($i=0;$i<17;$i++)$many.=$row('p'.$i,'sip:mod_sofia@127.0.0.1:5060');$many.='</profiles>';$n=0;$no(function()use($many,&$n,$base){event_guard_windows::ports($many,function($name)use(&$n,$base){$n++;return str_replace('internal',$name,$base).str_repeat(' ',63000);});}, 'Aggregate native response bound lost');$ok($n===17,'Aggregate response bound made extra queries');
 // Existing API commands plus only the closed new token are allowed before
 // accessing private settings. This controlled refusal prevents any TCP call.
 $ok(!class_exists('config',false),'No PBX configuration may be loaded by pure command controls');
 eval('class config {public static int $calls=0;public static ?array $settings=null;public static function load(){self::$calls++;if(self::$settings===null)throw new RuntimeException("owned-config-adapter");return new self();}public function get($name,$default=null){return self::$settings[$name]??$default;}}');
 foreach(['internal','internal-ipv6','p_2.3-4',str_repeat('a',64)]as$name){$before=config::$calls;try{pbx_windows_health_stream::api('sofia status profile '.$name);}catch(RuntimeException$e){$ok($e->getMessage()==='owned-config-adapter'&&config::$calls===$before+1,'Closed native profile command refused');}}
 foreach(['','-bad','bad name',str_repeat('a',65),'../internal','bad;status',"internal\nstatus","internal\r\napi status",'$(status)','a/b',"x\0y"]as$name){$before=config::$calls;$no(fn()=>pbx_windows_health_stream::api('sofia status profile '.$name),'Unsafe profile command accepted');$ok(config::$calls===$before,'Unsafe command accessed configuration or network');}
 $before=config::$calls;$no(fn()=>pbx_windows_health_stream::api('sofia xmlstatus profile internal'),'Unreviewed per-profile command accepted');$ok(config::$calls===$before,'Unreviewed command accessed configuration');
 $budget=new ReflectionMethod(pbx_windows_health_stream::class,'allowance');$value=$budget->invoke(null,4,microtime(true)+.05);$ok($value>0&&$value<=.05,'Shared deadline did not cap response time');$ok($budget->invoke(null,3,null)===3.0,'Existing default connect/auth time changed');$no(fn()=>$budget->invoke(null,4,microtime(true)-1),'Expired shared deadline accepted');
 // Same frame guard: only typed expected-timeout +empty real EOF is admitted.
 $memory=static function(string$raw){$f=fopen('php://temp','w+b');fwrite($f,$raw);rewind($f);return$f;};
 foreach([false,true]as$timeout){$f=$memory("auth fixture\n\n");try{$ok(windows_phone_health_fixture_frame($f,$timeout,'auth fixture'),'Canonical fixture frame refused');}finally{fclose($f);}}
 $f=$memory('');try{$ok(windows_phone_health_fixture_frame($f,true,'auth fixture')===false,'Expected clean EOF refused');}finally{fclose($f);}
 foreach([['',false],["auth partial\n",true],["auth foreign\n\n",true],["api wrong\n\n",true],[str_repeat('x',513)."\n\n",true],[" auth fixture\n\n",true],["auth fixture \n\n",true]]as[$raw,$timeout]){$f=$memory($raw);try{$no(fn()=>windows_phone_health_fixture_frame($f,$timeout,'auth fixture'),'Wrong/partial/oversized or positive EOF admitted');}finally{fclose($f);}}
 $f=$memory("api sofia status profile foreign\n\n");try{$no(fn()=>windows_phone_health_fixture_frame($f,true,'api sofia status profile internal'),'Wrong API frame admitted in expected-timeout mode');}finally{fclose($f);}
 $server=stream_socket_server('tcp://127.0.0.1:0',$errno,$error);$client=stream_socket_client('tcp://'.stream_socket_get_name($server,false),$errno,$error,1);$peer=stream_socket_accept($server,1);fclose($server);stream_set_timeout($peer,0,1000);
 try{$no(fn()=>windows_phone_health_fixture_frame($peer,true,'auth fixture'),'Read timeout admitted as clean EOF');$ok(!feof($peer),'Read-timeout control did not keep its peer open');}finally{fclose($peer);fclose($client);}
 // Exercise the production default resolver, authentication/command/framing
 // and shared response deadline over real private TCP, without injected parser data.
 foreach([false,true]as$timeout){
  $secret=bin2hex(random_bytes(16));$pipes=[];$child=proc_open([PHP_BINARY,'-d','display_errors=stderr','-d','log_errors=0',__FILE__,'--esl-fixture'],[0=>['pipe','r'],1=>['pipe','w'],2=>['pipe','w']],$pipes);
  $ok(is_resource($child),'Owned ESL child unavailable');
  try{
   fwrite($pipes[0],json_encode(['password'=>$secret,'status'=>$base,'delay_us'=>$timeout?200000:0,'expect_timeout'=>$timeout],JSON_THROW_ON_ERROR));fclose($pipes[0]);unset($pipes[0]);stream_set_timeout($pipes[1],3);$port=trim((string)fgets($pipes[1],16));$ok(ctype_digit($port)&&(int)$port>0&&(int)$port<=65535,'Owned ESL listener missing');
   config::$settings=['switch.event_socket.host'=>'127.0.0.1','switch.event_socket.port'=>(int)$port,'switch.event_socket.password'=>$secret];
   if($timeout){$start=microtime(true);$no(fn()=>pbx_windows_health_stream::api('sofia status profile internal',microtime(true)+.05),'Shared native negotiation/response deadline ignored');$elapsed=microtime(true)-$start;$ok($elapsed>=.04&&$elapsed<1,'Shared native negotiation/response deadline expanded or failed prematurely');}
   else{$ok(event_guard_windows::ports($xml)===['tcp'=>[5090,5091],'udp'=>[5090]],'Production resolver did not use exact private native status');}
   $tail=stream_get_contents($pipes[1]);$error=stream_get_contents($pipes[2]);fclose($pipes[1]);fclose($pipes[2]);unset($pipes[1],$pipes[2]);$exit=proc_close($child);$child=null;if($timeout){$stage=json_decode($tail,true,4,JSON_THROW_ON_ERROR);$ok(is_array($stage)&&array_keys($stage)===['expected_timeout_stage']&&is_string($stage['expected_timeout_stage'])&&in_array($stage['expected_timeout_stage'],['auth_eof','api_eof','api_complete'],true),'Owned expected-timeout stage invalid');$GLOBALS['openweb_health_fixture_timeout_stage']=$stage['expected_timeout_stage'];}else{$ok($tail==='','Positive fixture emitted timeout metadata');}$ok($exit===0&&$error==='','Owned ESL fixture failed or leaked output');
  }finally{config::$settings=null;foreach($pipes as$pipe)if(is_resource($pipe))fclose($pipe);if(is_resource($child))proc_close($child);}
 }
 return$checks;
}
if(realpath($_SERVER['SCRIPT_FILENAME']??'')===__FILE__)echo json_encode(['passed'=>true,'checks'=>windows_phone_health_listener_checks(),'source_parser_and_command_gate'=>true,'PBX_native_or_firewall_actions'=>false,'expected_timeout_stage'=>$GLOBALS['openweb_health_fixture_timeout_stage']??null]),PHP_EOL;
