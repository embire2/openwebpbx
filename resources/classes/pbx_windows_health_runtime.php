<?php
/** Maintenance/restore guards shared by the persistent Windows health worker. */
final class pbx_windows_health_runtime {
public static function ready(string $state):bool {
    foreach(['calls','jobs','updates','backups']as$hold)if(file_exists($state.'/backup-restore/hold-'.$hold))return false;
    foreach([[$state.'/installation.json',['Completed'=>true]],[$state.'/updates/install-journal.json',['state'=>['completed','rolled_back']]],[$state.'/backup-restore/journal.json',['state'=>['restored','recovered']]]]as[$file,$required]){
        if(!is_file($file)){if(str_ends_with($file,'installation.json'))return false;continue;}
        if(filesize($file)>1048576)return false;
        try{$r=json_decode(file_get_contents($file),true,32,JSON_THROW_ON_ERROR);}catch(Throwable){return false;}
        foreach($required as$key=>$value)if(is_array($value)?!in_array($r[$key]??null,$value,true):($r[$key]??null)!==$value)return false;
    };return true;
}
public static function locked(string $state,callable $action):mixed {
    $lock=@fopen($state.'/upgrade.lock','c+b');if(!$lock)return null;
    try{if(!flock($lock,LOCK_EX|LOCK_NB)||!self::ready($state))return null;return $action();}finally{fclose($lock);}
}
}
