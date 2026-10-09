<?php
/** Offline native-module migration checks. No installed configuration is read. */
if(PHP_SAPI!=='cli')exit(2);
require dirname(__DIR__).'/packaging/debian/normalize-codec-modules.php';
$root=sys_get_temp_dir().'/openweb-codec-check-'.bin2hex(random_bytes(6));mkdir($root,0700);
$path=$root.'/modules.conf.xml';$module=$root.'/mod_bcg729.so';file_put_contents($module,'synthetic module marker');
$count=0;
$check=function(bool $condition,string $message)use(&$count){$count++;if(!$condition)throw new RuntimeException($message);};
$wrap=fn(string $loads)=>'<?xml version="1.0"?><configuration name="modules.conf"><!-- retain upstream comment --><modules>'.$loads.'<load module="mod_sofia" data="untouched"/></modules></configuration>';
try{
 foreach([
  '<load module="mod_g729"/><load module="mod_bcg729"/>',
  '<load module="mod_bcg729"/><load module="mod_g729"/>'
 ] as $loads){
  file_put_contents($path,$wrap($loads));chmod($path,0640);$before=stat($path);
  $check(openweb_normalize_codec_modules($path,$module),'Conflicting module pair was not repaired.');
  $doc=new DOMDocument();$doc->load($path);$x=new DOMXPath($doc);
  $check($x->query('/configuration/modules/load[@module="mod_g729"]')->length===0&&$x->query('/configuration/modules/load[@module="mod_bcg729"]')->length===1,'Only the active passthrough codec must be removed.');
  $check($x->query('/configuration/comment()[.=" retain upstream comment "]')->length===1&&$x->query('/configuration/modules/load[@module="mod_sofia" and @data="untouched"]')->length===1,'Unrelated nodes/comments changed.');
  clearstatcache(true,$path);$after=stat($path);$check(($after['mode']&07777)===0640&&$before['uid']===$after['uid']&&$before['gid']===$after['gid'],'Native file permissions changed.');
  $repaired=file_get_contents($path);$check(!openweb_normalize_codec_modules($path,$module)&&file_get_contents($path)===$repaired,'Repeated migration changed an already repaired file.');
 }
 foreach(['<load module="mod_g729"/>','<!-- <load module="mod_bcg729"/> --><load module="mod_g729"/>','<load module="mod_bcg729"/>'] as $loads){
  $source=$wrap($loads);file_put_contents($path,$source);
  $check(!openweb_normalize_codec_modules($path,$module)&&file_get_contents($path)===$source,'A single codec or commented module must remain byte-identical.');
 }
 $source=$wrap('<load module="mod_g729"/><load module="mod_bcg729"/>');file_put_contents($path,$source);unlink($module);
 $check(!openweb_normalize_codec_modules($path,$module)&&file_get_contents($path)===$source,'A missing transcoder must not disable passthrough.');
 foreach(['<configuration><modules>','<!DOCTYPE configuration [<!ENTITY x "value">]><configuration/>'] as $bad){
  file_put_contents($path,$bad);$rejected=false;try{openweb_normalize_codec_modules($path,$module);}catch(RuntimeException){$rejected=true;}
  $check($rejected&&file_get_contents($path)===$bad,'Malformed or entity-bearing configuration must fail without writes.');
 }
 $check(glob($root.'/.openweb-codec-*')===[],'Staged module configuration was not removed.');
 echo 'PASS: '.$count." Debian codec migration checks\n";
}finally{foreach(glob($root.'/*') as $file)unlink($file);rmdir($root);}
