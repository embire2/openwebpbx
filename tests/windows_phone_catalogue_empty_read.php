<?php
/** Actual protected-file reads; namespaced read/metadata instrumentation is explicit. */
if(PHP_SAPI!=='cli')exit(2);
$source=$argv[1]??dirname(__DIR__).'/resources/classes/pbx_windows_phone_catalogue.php';
if(count($argv)>2||!is_file($source)||is_link($source))throw new RuntimeException('An ordinary source file is required.');
require $source;
$checks=0;
function check_read(bool $ok):void{global$checks;if(!$ok)throw new RuntimeException('Empty catalogue read control '.($checks+1).' refused.');$checks++;}
function refuse_read(callable $body):void{$caught=false;try{$body();}catch(UnexpectedValueException){$caught=true;}check_read($caught);}
$base='/var/lib/openwebpbx/windows-phone100/empty-read-'.bin2hex(random_bytes(8));
if(!mkdir($base,0700))throw new RuntimeException('The isolated read fixture could not be created.');
try{
 $empty=$base.'/empty';$full=$base.'/full';file_put_contents($empty,'');file_put_contents($full,"actual\0bytes");chmod($empty,0600);chmod($full,0600);
 check_read(pbx_windows_phone_catalogue::read($empty,0)==='');
 check_read(pbx_windows_phone_catalogue::read($empty,1048576)==='');
 check_read(pbx_windows_phone_catalogue::read($full,12)==="actual\0bytes");
 refuse_read(fn()=>pbx_windows_phone_catalogue::read($full,3));
 refuse_read(fn()=>pbx_windows_phone_catalogue::read($base.'/absent',1));
 refuse_read(fn()=>pbx_windows_phone_catalogue::read($base,1048576));
 chmod($empty,0660);refuse_read(fn()=>pbx_windows_phone_catalogue::read($empty,10));chmod($empty,0600);
 symlink($empty,$base.'/symlink');refuse_read(fn()=>pbx_windows_phone_catalogue::read($base.'/symlink',10));unlink($base.'/symlink');
 link($empty,$base.'/hardlink');refuse_read(fn()=>pbx_windows_phone_catalogue::read($empty,10));unlink($base.'/hardlink');
 mkdir($base.'/ancestor',0700);file_put_contents($base.'/ancestor/empty','');chmod($base.'/ancestor',0770);refuse_read(fn()=>pbx_windows_phone_catalogue::read($base.'/ancestor/empty',10));chmod($base.'/ancestor',0700);unlink($base.'/ancestor/empty');rmdir($base.'/ancestor');
 // Execute the actual method source with only explicit namespace instrumenters.
 $method=new ReflectionMethod('pbx_windows_phone_catalogue','read');$lines=file($source);$body=implode('',array_slice($lines,$method->getStartLine()-1,$method->getEndLine()-$method->getStartLine()+1));
 eval(<<<'ADAPTER'
namespace OpenWebCatalogueReadFixture;
$GLOBALS['catalogue_read_probe']=['reads'=>0,'stats'=>0,'closes'=>0,'change'=>null];
function stream_get_contents($stream,$maximum){$GLOBALS['catalogue_read_probe']['reads']++;$stat=\fstat($stream);if($stat['size']===0)throw new \RuntimeException('Explicit mandatory empty-read refusal adapter.');return \stream_get_contents($stream,$maximum);}
function fstat($stream){$stat=\fstat($stream);$GLOBALS['catalogue_read_probe']['stats']++;$field=$GLOBALS['catalogue_read_probe']['change'];if($GLOBALS['catalogue_read_probe']['stats']===2&&$field!==null)$stat[$field]++;return$stat;}
function fclose($stream){$GLOBALS['catalogue_read_probe']['closes']++;return \fclose($stream);}
class ActualReader {private static function invalid():never{throw new \UnexpectedValueException('The actual read predicate refused.');}
ADAPTER
 .$body.'}');
 $reset=static function(?string$field=null):void{$GLOBALS['catalogue_read_probe']=['reads'=>0,'stats'=>0,'closes'=>0,'change'=>$field];};
 $reset();check_read(OpenWebCatalogueReadFixture\ActualReader::read($empty,1048576)==='');check_read($GLOBALS['catalogue_read_probe']===['reads'=>0,'stats'=>2,'closes'=>1,'change'=>null]);
 $reset();check_read(OpenWebCatalogueReadFixture\ActualReader::read($full,1048576)==="actual\0bytes");check_read($GLOBALS['catalogue_read_probe']===['reads'=>1,'stats'=>2,'closes'=>1,'change'=>null]);
 foreach(['dev','ino','mode','nlink','uid','gid','size','mtime','ctime']as$field){$reset($field);refuse_read(fn()=>OpenWebCatalogueReadFixture\ActualReader::read($empty,1048576));check_read($GLOBALS['catalogue_read_probe']['reads']===0&&$GLOBALS['catalogue_read_probe']['stats']===2&&$GLOBALS['catalogue_read_probe']['closes']===1);}
 $reset();$lease=fopen($empty,'r+b');flock($lease,LOCK_EX);
 try{check_read(pbx_windows_phone_catalogue::read($empty,1048576)==='');$contender=fopen($empty,'r+b');try{$blocked=0;check_read(!flock($contender,LOCK_EX|LOCK_NB,$blocked)&&$blocked===1);}finally{fclose($contender);}}finally{flock($lease,LOCK_UN);fclose($lease);}
 check_read(file_get_contents($empty)==='');
}finally{foreach(scandir($base)?:[]as$name){if($name==='.'||$name==='..')continue;$path=$base.'/'.$name;if(is_link($path)||is_file($path))unlink($path);else{chmod($path,0700);foreach(scandir($path)?:[]as$child)if($child!=='.'&&$child!=='..')unlink($path.'/'.$child);rmdir($path);}}rmdir($base);}
echo 'PASS '.$checks.' actual protected zero/nonempty/refusal checks with explicit read/metadata adapters; no Windows lock claim'.PHP_EOL;
