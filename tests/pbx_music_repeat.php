<?php
/** Real filesystem/SoX/SQLite initializer: upgrades preserve existing stock and custom WAVs. */
if(PHP_SAPI!=='cli'||PHP_OS_FAMILY!=='Linux')exit(2);
define('PROJECT_ROOT',dirname(__DIR__));
class pbx_paths {
    public static string $root;
    public static function storage(): string {return self::$root;}
    public static function contains(string $root,string $file): bool {return str_starts_with((string)realpath($file),rtrim((string)realpath($root),'/').'/');}
}
class cache {public function delete(string $name): void {}}
function uuid(): string {return bin2hex(random_bytes(16));}
require $argv[1]??PROJECT_ROOT.'/resources/classes/pbx_music.php';
set_error_handler(static function(int $level,string $message,string $file,int $line): never {throw new ErrorException($message,0,$level,$file,$line);});
$root=sys_get_temp_dir().'/openweb-music-repeat-'.bin2hex(random_bytes(8));mkdir($root,0700);pbx_paths::$root=$root.'/storage';mkdir(pbx_paths::$root,0700);
$db=new PDO('sqlite::memory:');$db->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);
$db->exec('create table v_music_on_hold(music_on_hold_uuid text primary key,domain_uuid text,music_on_hold_name text,music_on_hold_path text,music_on_hold_rate integer,music_on_hold_shuffle integer,music_on_hold_channels integer,music_on_hold_interval integer,music_on_hold_timer_name text);create table v_vars(var_name text,var_value text)');
$db->exec("insert into v_vars values('hold_music','local_stream://default'),('hold_music','local_stream://operator');insert into v_music_on_hold values('custom','own-tenant','custom','operator-path',8000,1,2,30,'operator')");
$n=0;$check=static function(bool $ok,string $label)use(&$n): void {if(!$ok)throw new RuntimeException($label);$n++;};
$files=[];foreach([8000,16000,32000,48000]as$r)$files[$r]=pbx_paths::$root.'/openweb-music/'.$r.'/lofi-beat-loop-schmoop.wav';
$state=static function(string $file): array {clearstatcache(true,$file);$s=stat($file);return ['sha256'=>hash_file('sha256',$file),'mode'=>$s['mode']&0777,'uid'=>$s['uid'],'gid'=>$s['gid'],'mtime'=>$s['mtime'],'inode'=>$s['ino']];};
$rows=static fn():array=>$db->query('select *from v_music_on_hold order by music_on_hold_uuid')->fetchAll(PDO::FETCH_ASSOC);
$reject=static function(callable $fn,string $name)use($check): void {$refused=false;try{$fn();}catch(RuntimeException){$refused=true;}$check($refused,$name);};
try{
    pbx_music::install($db);
    foreach($files as$rate=>$file){
        $check(is_file($file)&&!is_link($file),'Fresh audio file exists at '.$rate);
        $p=proc_open(['sox','--i','-r',$file],[0=>['file','/dev/null','r'],1=>['pipe','w'],2=>['pipe','w']],$pipes);$out=stream_get_contents($pipes[1]);$error=stream_get_contents($pipes[2]);fclose($pipes[1]);fclose($pipes[2]);$code=proc_close($p);
        $check($code===0&&(int)trim($out)===$rate,'Fresh audio decodes at its actual native rate '.$rate);
    }
    $before=array_map($state,$files);$beforeRows=$rows();pbx_music::install($db);
    foreach($files as$rate=>$file)$check($before[$rate]===$state($file),'Repeated upgrade preserves exact audio, inode and metadata '.$rate);
    $check($beforeRows===$rows(),'Repeated initializer leaves every music row identical');
    // An operator may replace the bundled path; even that recording and its
    // metadata belong to the instance and must survive an ordinary upgrade.
    $operator=file_get_contents($files[8000]);$operator[strlen($operator)-2]=chr(ord($operator[strlen($operator)-2])^1);file_put_contents($files[8000],$operator);chmod($files[8000],0600);touch($files[8000],1234567890);
    if(function_exists('posix_geteuid')&&posix_geteuid()===0){chown($files[8000],33);chgrp($files[8000],33);}
    $custom=$state($files[8000]);pbx_music::install($db);$check($custom===$state($files[8000]),'Operator recording, inode, mode, owner and mtime survive upgrade');
    $before=array_map($state,$files);unlink($files[48000]);pbx_music::install($db);
    foreach([8000,16000,32000]as$rate)$check($before[$rate]===$state($files[$rate]),'Filling a missing rate preserves existing '.$rate);
    $check(is_file($files[48000])&&filesize($files[48000])>0,'Only missing rate is populated');
    $check((int)$db->query('select count(*)from v_music_on_hold')->fetchColumn()===5,'No duplicate streams after partial repair');
    $customRow=$db->query("select *from v_music_on_hold where music_on_hold_uuid='custom'")->fetch(PDO::FETCH_ASSOC);$check($customRow['music_on_hold_path']==='operator-path'&&(int)$customRow['music_on_hold_channels']===2,'Unrelated tenant stream remains exact');
    $check($db->query('select var_value from v_vars order by rowid')->fetchAll(PDO::FETCH_COLUMN)===['local_stream://openweb','local_stream://operator'],'Only stock hold selection is initialized');
    $valid48000=file_get_contents($files[48000]);$beforeOther=$state($files[8000]);
    foreach(['not-wave','truncated','wrong-rate','wrong-bit-depth','wrong-channels','bad-riff-size','empty-data','duplicate-data','oversized-chunk','odd-data']as$kind){
        $bad=$valid48000;
        if($kind==='not-wave')$bad='not a wave recording';
        elseif($kind==='truncated')$bad=substr($bad,0,-1);
        elseif($kind==='wrong-rate')$bad=substr_replace($bad,pack('V',16000),24,4);
        elseif($kind==='wrong-bit-depth')$bad=substr_replace($bad,pack('v',8),34,2);
        elseif($kind==='wrong-channels')$bad=substr_replace($bad,pack('v',2),22,2);
        elseif($kind==='bad-riff-size')$bad=substr_replace($bad,pack('V',strlen($bad)-9),4,4);
        elseif($kind==='empty-data'){$bad=substr($bad,0,44);$bad=substr_replace($bad,pack('V',36),4,4);$bad=substr_replace($bad,pack('V',0),40,4);}
        elseif($kind==='duplicate-data'){$bad.='data'.pack('V',2).chr(0).chr(0);$bad=substr_replace($bad,pack('V',strlen($bad)-8),4,4);}
        elseif($kind==='oversized-chunk')$bad=substr_replace($bad,pack('V',4294967295),40,4);
        else{$bad=substr_replace($bad,pack('V',strlen($bad)-45),40,4);}
        file_put_contents($files[48000],$bad);$beforeBad=$state($files[48000]);$beforeRows=$rows();
        $reject(fn()=>pbx_music::install($db),'Malformed existing '.$kind.' refuses');
        $check($rows()===$beforeRows&&$state($files[8000])===$beforeOther&&$state($files[48000])===$beforeBad,'Malformed '.$kind.' preserves all existing data');
    }
    file_put_contents($files[48000],$valid48000);
    $outside=$root.'/outside.wav';copy($files[16000],$outside);$outsideState=$state($outside);
    foreach(['file','dangling','directory','parent']as$kind){
        $file=$files[48000];$dir=dirname($file);unlink($file);
        if($kind==='file')symlink($outside,$file);
        elseif($kind==='dangling')symlink($root.'/absent.wav',$file);
        elseif($kind==='directory')mkdir($file,0700);
        else{rmdir($dir);symlink(dirname($outside),$dir);}
        $snapshot=$rows();$beforeOther=$state($files[8000]);$reject(fn()=>pbx_music::install($db),'Unsafe existing '.$kind.' refused before install');
        $check($rows()===$snapshot&&$state($files[8000])===$beforeOther&&$state($outside)===$outsideState,'Unsafe '.$kind.' causes no database/audio mutation');
        if($kind==='directory')rmdir($file);elseif($kind==='parent'){unlink($dir);mkdir($dir,0700);}else unlink($file);
        file_put_contents($file,$valid48000);
    }
    foreach(['README.md','manifest.json']as$name){
        $file=pbx_paths::$root.'/openweb-music/'.$name;file_put_contents($file,'Operator provenance, preserve exactly.');chmod($file,0600);touch($file,1234567890);
        $original=$state($file);pbx_music::install($db);$check($state($file)===$original,'Existing '.$name.' content/inode/metadata preserved');
        $content=file_get_contents($file);unlink($file);symlink($outside,$file);$beforeRows=$rows();
        $reject(fn()=>pbx_music::install($db),'Linked '.$name.' refuses before writing');
        $check($rows()===$beforeRows&&$state($outside)===$outsideState,'Linked '.$name.' preserves database/outside file');
        unlink($file);file_put_contents($file,$content);
    }
    $check(glob(pbx_paths::$root.'/openweb-music/*/track-*.wav')===[],'No temporary conversion files remain');
    echo 'PASS '.$n." real SoX/filesystem/SQLite fresh/repeat/custom/missing-rate/path controls; no production services/database accessed\n";
}finally{
    $it=new RecursiveIteratorIterator(new RecursiveDirectoryIterator($root,FilesystemIterator::SKIP_DOTS),RecursiveIteratorIterator::CHILD_FIRST);foreach($it as$f){if($f->isDir()&&!$f->isLink())rmdir($f->getPathname());else unlink($f->getPathname());}rmdir($root);
}
