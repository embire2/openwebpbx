<?php
/** CLI-only filesystem/SQLite music installation checks; no production database or engine. */
if(PHP_SAPI!=='cli')exit(2);
define('PROJECT_ROOT',dirname(__DIR__));
class pbx_paths {
    public static string $root;
    public static function storage(): string{return self::$root;}
    public static function contains(string $root,string $path): bool {$a=realpath($root);$b=realpath($path);return $a!==false&&$b!==false&&str_starts_with(str_replace('\\','/',$b),rtrim(str_replace('\\','/',$a),'/').'/');}
}
class cache {public static array $deleted=[];public function delete(string $name): void{self::$deleted[]=$name;}}
function uuid(): string {$x=bin2hex(random_bytes(16));return substr($x,0,8).'-'.substr($x,8,4).'-'.substr($x,12,4).'-'.substr($x,16,4).'-'.substr($x,20);}
require PROJECT_ROOT.'/resources/classes/pbx_music.php';
$bundle=$argv[1]??'';if(!is_dir($bundle))throw new RuntimeException('Supply the separately generated music bundle.');
$root=sys_get_temp_dir().'/openweb-music-check-'.bin2hex(random_bytes(6));mkdir($root,0700);pbx_paths::$root=$root.'/storage with spaces';mkdir(pbx_paths::$root,0700);
$checks=0;$check=function(bool $ok,string $name)use(&$checks){if(!$ok)throw new RuntimeException($name);$checks++;};$reject=function(callable $fn,string $name)use($check){try{$fn();}catch(Throwable){$check(true,$name);return;}$check(false,$name);};
$db=new PDO('sqlite::memory:');$db->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);
$db->exec('create table v_music_on_hold(music_on_hold_uuid text primary key,domain_uuid text,music_on_hold_name text,music_on_hold_path text,music_on_hold_rate integer,music_on_hold_shuffle integer,music_on_hold_channels integer,music_on_hold_interval integer,music_on_hold_timer_name text); create table v_vars(var_name text,var_value text)');
$db->exec("insert into v_vars values('hold_music','local_stream://default'),('hold_music','local_stream://custom'),('other','untouched'); insert into v_music_on_hold values('custom','owned-domain','openweb','custom-path',8000,1,2,30,'custom')");
$manifest=json_decode(file_get_contents($bundle.'/bundle-manifest.json'),true,32,JSON_THROW_ON_ERROR);
try{
    pbx_music::install($db,$bundle);
    foreach([8000,16000,32000,48000] as $rate){$file=pbx_paths::$root.'/openweb-music/'.$rate.'/lofi-beat-loop-schmoop.wav';$check(hash_file('sha256',$file)===$manifest['rates'][$rate]['sha256'],'Prepared rate copied byte for byte');}
    $check((int)$db->query('select count(*) from v_music_on_hold where domain_uuid is null')->fetchColumn()===4,'All four native streams installed');
    $custom=$db->query("select * from v_music_on_hold where music_on_hold_uuid='custom'")->fetch(PDO::FETCH_ASSOC);$check($custom['music_on_hold_path']==='custom-path'&&$custom['music_on_hold_channels']===2,'Tenant custom stream unchanged');
    $vars=$db->query('select var_value from v_vars order by rowid')->fetchAll(PDO::FETCH_COLUMN);$check($vars===['local_stream://openweb','local_stream://custom','untouched'],'Only stock database default changes');
    pbx_music::install($db,$bundle);$check((int)$db->query('select count(*) from v_music_on_hold')->fetchColumn()===5,'Repeat does not duplicate stock or custom streams');
    $check(in_array('configuration:local_stream.conf',cache::$deleted,true),'Native stream cache invalidated');
    $conf=$root.'/conf';mkdir($conf,0700);$native=$conf.'/vars.xml';$xml="<?xml version=\"1.0\"?>\n<include>\n <X-PRE-PROCESS cmd='set' data='unrelated=keep exactly'/>\n <X-PRE-PROCESS cmd='set' data='hold_music=local_stream://default'/>\n</include>\n";file_put_contents($native,$xml);
    $check(pbx_music::nativeDefault($native,$conf)&&file_get_contents($native)===str_replace('hold_music=local_stream://default','hold_music=local_stream://openweb',$xml),'Only exact stock XML value changes');
    $customXml=str_replace('local_stream://default','local_stream://custom',$xml);file_put_contents($native,$customXml);$check(!pbx_music::nativeDefault($native,$conf)&&file_get_contents($native)===$customXml,'Custom native default and every byte preserved');
    file_put_contents($native,'<invalid>');$reject(fn()=>pbx_music::nativeDefault($native,$conf),'Malformed XML rejected');
    $twice=str_replace('</include>',"<X-PRE-PROCESS cmd='set' data='hold_music=local_stream://default'/></include>",$xml);file_put_contents($native,$twice);$reject(fn()=>pbx_music::nativeDefault($native,$conf),'Ambiguous duplicate stock default rejected');
    $outside=$root.'/outside.xml';file_put_contents($outside,$xml);$reject(fn()=>pbx_music::nativeDefault($outside,$conf),'Outside config path rejected');
    $bad=$root.'/bad-bundle';mkdir($bad,0700);$fake=$manifest;$fake['source_sha256']=str_repeat('0',64);file_put_contents($bad.'/bundle-manifest.json',json_encode($fake));$reject(fn()=>pbx_music::install($db,$bad),'Wrong source provenance rejected before any update');
    $fake=$manifest;$fake['rates'][8000]['path']='../outside.wav';file_put_contents($bad.'/bundle-manifest.json',json_encode($fake));$reject(fn()=>pbx_music::install($db,$bad),'Manifest traversal rejected');
    $check((int)$db->query('select count(*) from v_music_on_hold')->fetchColumn()===5,'Rejected bundles preserve database rows');
    echo 'PASS: '.$checks." prepared music, custom/default preservation and native path checks\n";
}finally{
    $files=new RecursiveIteratorIterator(new RecursiveDirectoryIterator($root,FilesystemIterator::SKIP_DOTS),RecursiveIteratorIterator::CHILD_FIRST);foreach($files as $file){if($file->isDir()&&!$file->isLink())rmdir($file->getPathname());else unlink($file->getPathname());}rmdir($root);
}
