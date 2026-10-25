<?php
/** Verify real installed marker/audio gating without writing any installed sound. */
if(PHP_SAPI!=='cli')exit(2);
require dirname(__DIR__).'/resources/classes/pbx_call_me_back.php';
$pack=$argv[1]??'';if(!is_dir($pack.'/files/openwebpbx/voices/1.0.2/call-me-back'))exit(2);
$root=sys_get_temp_dir().'/cmb-prompts-'.bin2hex(random_bytes(8));mkdir($root,0700);$base=$root.'/openwebpbx';mkdir($base.'/voices/1.0.2/call-me-back',0700,true);$checks=0;
$ok=function($v,$m)use(&$checks){if(!$v)throw new RuntimeException($m);$checks++;};
try{
 $ok(!pbx_call_me_back::promptPackReady($root),'Missing pack accepted');
 copy($pack.'/pack.json',$base.'/voice-pack.json');$original=file_get_contents($base.'/voice-pack.json');$data=json_decode($original,true,512,JSON_THROW_ON_ERROR);
 $ok(!pbx_call_me_back::promptPackReady($root),'Missing callback audio accepted');
 foreach(glob($pack.'/files/openwebpbx/voices/1.0.2/call-me-back/*.wav')as$p)copy($p,$base.'/voices/1.0.2/call-me-back/'.basename($p));
 $ok(pbx_call_me_back::promptPackReady($root),'Complete Keoma callback files not accepted');
 $path=$base.'/voices/1.0.2/call-me-back/incoming-new.wav';$wav=file_get_contents($path);file_put_contents($path,$wav.'tampered');$ok(!pbx_call_me_back::promptPackReady($root),'Changed audio accepted');file_put_contents($path,$wav);
 foreach([['version','1.0.0'],['voice_id','wrong-voice']]as[$key,$value]){$changed=$data;$changed[$key]=$value;file_put_contents($base.'/voice-pack.json',json_encode($changed));$ok(!pbx_call_me_back::promptPackReady($root),'Wrong pack identity accepted');}
 file_put_contents($base.'/voice-pack.json',$original);rename($path,$path.'.original');symlink($path.'.original',$path);$ok(!pbx_call_me_back::promptPackReady($root),'Linked callback audio accepted');unlink($path);rename($path.'.original',$path);
 rename($base.'/voice-pack.json',$base.'/voice-pack.original');symlink($base.'/voice-pack.original',$base.'/voice-pack.json');$ok(!pbx_call_me_back::promptPackReady($root),'Linked marker accepted');unlink($base.'/voice-pack.json');rename($base.'/voice-pack.original',$base.'/voice-pack.json');
 file_put_contents($base.'/voice-pack.json','{broken');$ok(!pbx_call_me_back::promptPackReady($root),'Broken marker accepted');file_put_contents($base.'/voice-pack.json',$original);
 $ok(pbx_call_me_back::promptPackReady($root),'Original valid marker/audio did not recover');
 echo "PASS: $checks real Keoma callback marker/audio activation controls\n";
}finally{$all=new RecursiveIteratorIterator(new RecursiveDirectoryIterator($root,FilesystemIterator::SKIP_DOTS),RecursiveIteratorIterator::CHILD_FIRST);foreach($all as$p){if($p->isLink()||$p->isFile())unlink($p->getPathname());else rmdir($p->getPathname());}rmdir($root);}
