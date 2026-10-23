<?php
/** Actual early-refusal child processes; sentinel files stay exact, no database used. */
if(PHP_SAPI!=='cli')exit(2);
$checks=0;$root=sys_get_temp_dir().'/openweb-threecx-refusal-'.bin2hex(random_bytes(16));mkdir($root,0700);
$check=static function(bool$v)use(&$checks):void{if(!$v)throw new RuntimeException('The early import refusal changed foreign fixture data.');$checks++;};
$roots=[$root.'/foreign'];
if(PHP_OS_FAMILY!=='Windows')$roots[]='/tmp/openweb-threecx-pg-'.bin2hex(random_bytes(16)).'/work';
try{
    foreach($roots as$work){
        mkdir($work,0700,true);mkdir($work.'/private storage',0700);$files=[$work.'/openweb-template.key'=>'FOREIGN_KEY',$work.'/private storage/sentinel.wav'=>'FOREIGN_MEDIA',$work.'/synthetic V20.zip'=>'FOREIGN_ARCHIVE'];
        foreach($files as$file=>$bytes)file_put_contents($file,$bytes);$config=$root.'/input.conf';file_put_contents($config,'not a database configuration');
        $process=proc_open([PHP_BINARY,__DIR__.'/windows_threecx_import_native.php',$work,'--portable-socket',$config,dirname(__DIR__)],[0=>['pipe','r'],1=>['pipe','w'],2=>['pipe','w']],$pipes);
        if(!is_resource($process))throw new RuntimeException('The owned refusal child could not start.');fclose($pipes[0]);$out=stream_get_contents($pipes[1]);$err=stream_get_contents($pipes[2]);fclose($pipes[1]);fclose($pipes[2]);$exit=proc_close($process);$report=json_decode($out,true,64,JSON_THROW_ON_ERROR);
        $check($exit===1&&$err===''&&$report['state']==='failed'&&$report['phase']==='input'&&$report['actual_php_pg_zip_restore']===false);
        foreach($files as$file=>$bytes)$check(is_file($file)&&file_get_contents($file)===$bytes);
        foreach(array_keys($files)as$file)unlink($file);rmdir($work.'/private storage');rmdir($work);if(!str_starts_with($work,$root.'/'))rmdir(dirname($work));
    }
    echo 'PASS '.$checks.' actual import early-refusal/sentinel-preservation controls; no database or PBX used',PHP_EOL;
}finally{if(is_file($root.'/input.conf'))unlink($root.'/input.conf');if(is_dir($root))rmdir($root);}
