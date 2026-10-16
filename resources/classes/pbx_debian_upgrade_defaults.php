<?php
/** Preserve installed choices when an older Debian updater calls the stock defaults commands. */
class pbx_debian_upgrade_defaults {
    private static function trusted(string $path): string {
        clearstatcache(true,$path);$real=realpath($path);if($real===false||$real!==$path)throw new RuntimeException('The sealed upgrade source is unavailable.');
        for($p=$path;;$p=dirname($p)){clearstatcache(true,$p);$s=lstat($p);if(!$s||is_link($p)||$s['uid']!==0||($s['mode']&0022))throw new RuntimeException('Upgrade source ownership or permissions differ.');if($p==='/')break;}
        if(!is_file($path))throw new RuntimeException('An ordinary upgrade source file is required.');return $path;
    }
    public static function previous(string $journal='/var/lib/openwebpbx/updates/install-journal.json',string $web='/var/www/fusionpbx',string $backups='/var/backups/openwebpbx'): ?string {
        if(!file_exists($journal))return null;
        $j=json_decode(file_get_contents(self::trusted($journal)),true,32,JSON_THROW_ON_ERROR);
        if(in_array($j['state']??'', ['completed','rolled_back'],true))return null;
        if(($j['schema']??null)!==1||($j['state']??'')!=='migrating'||($j['version']??'')!==trim(file_get_contents($web.'/VERSION')))throw new RuntimeException('The active update is not ready for additive defaults.');
        $backup=$j['backup_path']??'';
        if(!is_string($backup)||!preg_match('~^'.preg_quote($backups,'~').'/upgrade-[0-9]{8}T[0-9]{6}Z-[a-f0-9]{8}$~D',$backup))throw new RuntimeException('The upgrade backup binding is invalid.');
        $integrity=json_decode(file_get_contents(self::trusted($backup.'/integrity.json')),true,32,JSON_THROW_ON_ERROR);
        $inventory=self::trusted($backup.'/files.json');if(!isset($integrity['files.json'])||!hash_equals($integrity['files.json'],hash_file('sha256',$inventory)))throw new RuntimeException('The sealed source inventory differs.');
        $files=json_decode(file_get_contents($inventory),true,512,JSON_THROW_ON_ERROR);if(!is_array($files)||!array_is_list($files)||count($files)>50000)throw new RuntimeException('The source inventory is invalid.');
        $seen=[];$existing=[];$root=$backup.'/files'.$web;
        foreach($files as$f){$path=$f['path']??'';if(!is_string($path)||!str_starts_with($path,$web.'/'))continue;
            if(isset($seen[$path])||str_contains($path,'/../')||str_contains($path,'/./')||str_contains($path,"\0"))throw new RuntimeException('The source inventory has an unsafe or repeated path.');$seen[$path]=true;
            if(($f['exists']??null)===true){$existing[$path]=true;$saved=self::trusted($backup.'/files'.$path);if(!is_string($f['sha256']??null)||!hash_equals($f['sha256'],hash_file('sha256',$saved)))throw new RuntimeException('The sealed previous source differs.');}
        }
        if(!isset($existing[$web.'/resources/require.php'])||!is_file($root.'/resources/require.php')||trim(file_get_contents(self::trusted($root.'/VERSION')))!==($j['previous_version']??null))throw new RuntimeException('The previous source identity differs.');
        // Include files only from this authenticated inventory. Refuse an added metadata file.
        foreach(array_merge(glob($root.'/*/*/app_config.php')?:[],glob($root.'/*/*/app_menu.php')?:[],glob($root.'/*/*/resources/switch/conf/dialplan/*.xml')?:[])as$file){$original=$web.substr($file,strlen($root));if(!isset($existing[$original]))throw new RuntimeException('Unsealed upgrade metadata was added.');}
        return $root;
    }
    public static function run(PDO $db,string $command): bool {
        if(PHP_SAPI!=='cli'||PHP_OS_FAMILY!=='Linux'||!function_exists('posix_geteuid')||posix_geteuid()!==0||!in_array($command,['--defaults','--group','--menu'],true))return false;
        $previous=self::previous();if($previous===null)return false;
        $initializer=new pbx_upgrade_defaults($db,PROJECT_ROOT,$previous);$counts=$initializer->apply();$phrases=$initializer->voicemailFiles((string)config::load()->get('switch.conf.dir'));
        echo json_encode(['additive_upgrade_defaults'=>$counts,'phrase_compatibility'=>$phrases],JSON_THROW_ON_ERROR)."\n";return true;
    }
}
