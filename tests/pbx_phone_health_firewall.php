<?php
/** Real iptables, only inside an explicitly separate network namespace. */
if(PHP_SAPI!=='cli'||posix_geteuid()!==0||readlink('/proc/self/ns/net')===readlink('/proc/1/ns/net'))throw new RuntimeException('Run as root using unshare -n. The host firewall must not be touched.');
require dirname(__DIR__).'/resources/classes/pbx_phone_health_firewall.php';
require dirname(__DIR__).'/app/event_guard/resources/interfaces/event_guard_interface.php';
class settings {public function database():mixed{return null;}}
require dirname(__DIR__).'/app/event_guard/resources/classes/event_guard_iptables.php';
$checks=0;$ok=static function(bool $v,string $m)use(&$checks){if(!$v)throw new RuntimeException($m);$checks++;};
$run=static function(array $args):string{$pipes=[];$p=proc_open(array_merge(['/usr/sbin/iptables','-w','2'],$args),[0=>['pipe','r'],1=>['pipe','w'],2=>['pipe','w']],$pipes);fclose($pipes[0]);$out=stream_get_contents($pipes[1]);$err=stream_get_contents($pipes[2]);fclose($pipes[1]);fclose($pipes[2]);if(proc_close($p)!==0)throw new RuntimeException('Owned namespace firewall command failed: '.$err);return$out;};
$run(['-I','INPUT','-s','192.0.2.77','-j','ACCEPT']);
$fw=new pbx_phone_health_firewall('/usr/sbin/iptables');$fw->ensureChains();$before=$run(['-S']);$fw->ensureChains();$ok($before===$run(['-S']),'Repeated chain setup changed existing rules or jump order');
$native=new event_guard_iptables(new settings);$ok($before===$run(['-S']),'Actual Event Guard constructor duplicated INPUT jumps');
$lines=explode("\n",trim($before));$fail=array_search('-A INPUT -j sip-auth-fail',$lines,true);$ip=array_search('-A INPUT -j sip-auth-ip',$lines,true);$ok(is_int($fail)&&is_int($ip)&&$fail<$ip,'Fresh chain setup reversed the original jump ordering');
$source='198.51.100.10';$similar='198.51.100.100';
foreach([['sip-auth-fail',$source],['sip-auth-fail',$similar],['sip-auth-ip',$source]]as[$filter,$address])$run(['-A',$filter,'-s',$address,'-j','DROP']);
$full=$run(['-S']);$ok($fw->state($source,'sip-auth-fail')==='present','Exact block not found');$ok($native->block_state_exact($source,'sip-auth-fail')==='present','Native exact adapter not wired');
$ok($fw->state('198.51.100.1','sip-auth-fail')==='absent','Prefix/substring source falsely matched');$ok($fw->state($source,'unrelated')==='unknown','Arbitrary chain accepted');$ok($fw->state('2001:db8::1','sip-auth-fail')==='unknown','IPv6 silently queried through IPv4 adapter');$ok($fw->state('127.0.0.1;true','sip-auth-fail')==='unknown','Invalid address accepted');
$ok(!$fw->remove($source,'sip-auth-ip')&&$run(['-S'])===$full,'Recovery modified a non-authentication-failure filter');
$ok($native->block_delete_exact($source,'sip-auth-fail'),'Exact native delete failed');$after=$run(['-S']);$expected=str_replace('-A sip-auth-fail -s '.$source.'/32 -j DROP'."\n",'',$full);$ok($after===$expected,'Exact removal changed another policy/rule/order');
$ok($fw->state($source,'sip-auth-fail')==='absent'&&$fw->state($source,'sip-auth-ip')==='present','Other-chain source confused absence check');$ok($fw->state($similar,'sip-auth-fail')==='present','Similar-address block removed');$ok($fw->remove($source,'sip-auth-fail')&&$after===$run(['-S']),'Repeat recovery not idempotent');
$run(['-A','sip-auth-fail','-s',$source,'-j','DROP']);$run(['-A','sip-auth-fail','-s',$source,'-j','DROP']);$ok($fw->remove($source,'sip-auth-fail')&&$after===$run(['-S']),'Duplicate exact drops not safely removed');
$run(['-F','sip-auth-fail']);$run(['-D','INPUT','-j','sip-auth-fail']);$run(['-X','sip-auth-fail']);$ok($fw->state($source,'sip-auth-fail')==='unknown','Missing chain was mistaken for verified absence');
// Exercise the real subprocess primitive, including final buffered output after exit.
$dir=sys_get_temp_dir().'/health-fw-'.bin2hex(random_bytes(6));mkdir($dir,0700);$script=$dir.'/iptables';
try{
 file_put_contents($script,"#!/usr/bin/php\n<?php if(in_array('--overflow',\$argv,true)){echo str_repeat('x',70000);exit(0);}if(in_array('--deadline',\$argv,true)){usleep(4000000);exit(0);}echo 'ok';\n");chmod($script,0700);$probe=new pbx_phone_health_firewall($script);$method=new ReflectionMethod($probe,'run');
 $normal=$method->invoke($probe,['--normal']);$ok($normal['exit']===0,'Normal bounded subprocess refused');
 $overflow=$method->invoke($probe,['--overflow']);$ok($overflow['exit']===null,'Output refusal promoted cached successful child exit');
 $start=microtime(true);$deadline=$method->invoke($probe,['--deadline']);$elapsed=microtime(true)-$start;$ok($deadline['exit']===null&&$elapsed>=2.9&&$elapsed<3.8,'Subprocess deadline was not bounded/refused');
}finally{@unlink($script);@rmdir($dir);}
echo json_encode(['checks'=>$checks,'actual_isolated_network_namespace'=>true,'actual_iptables_exact_rules'=>true,'actual_constructor_idempotence'=>true,'actual_subprocess_overflow_and_deadline'=>true,'no_host_firewall_changes'=>true],JSON_PRETTY_PRINT).PHP_EOL;
