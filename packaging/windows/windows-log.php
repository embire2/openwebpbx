<?php
/** Windows global native-log initialization. Never rewrites a nonempty setting. */
final class openweb_windows_log {
    public static function path(mixed $value):string {
        if(!is_string($value)||$value===''||strlen($value)>4096||trim($value)!==$value||preg_match('/[\x00-\x1f<>"|?*]/',$value))throw new RuntimeException('Invalid Windows log directory.');
        $path=str_replace('\\','/',$value);
        if(str_contains(substr($path,preg_match('~^[A-Za-z]:/~D',$path)?2:0),':'))throw new RuntimeException('Invalid Windows log directory.');
        $path=(str_starts_with($path,'//')?'//':'').preg_replace('~/+~','/',str_starts_with($path,'//')?substr($path,2):$path);
        if(!preg_match('~^(?:[A-Za-z]:/|//[^/:]+/[^/:]+(?:/|$))~D',$path))throw new RuntimeException('An absolute Windows log directory is required.');
        foreach(explode('/',$path)as$part)if($part==='.'||$part==='..'||($part!==''&&preg_match('/[. ]$/D',$part)))throw new RuntimeException('Ambiguous Windows log directory.');
        return preg_match('~^[A-Za-z]:/$~D',$path)?$path:rtrim($path,'/');
    }
    public static function same(string $one,string $two):bool{return strcasecmp(self::path($one),self::path($two))===0;}
    public static function owned(string $conf):string {
        $path=self::path($conf);if(!str_ends_with(strtolower($path),'/conf'))throw new RuntimeException('The owned Windows engine layout needs review.');
        return substr($path,0,-5).'/log';
    }
    public static function rows(PDO $db):array {
        $q=$db->query("select default_setting_uuid,default_setting_name,default_setting_value,default_setting_order,dense_rank() over(order by default_setting_order asc) as priority_group from v_default_settings where default_setting_category='switch' and default_setting_subcategory='log' and default_setting_enabled=true order by default_setting_order asc");
        $rows=$q->fetchAll(PDO::FETCH_ASSOC);if(count($rows)>128)throw new RuntimeException('The global log setting is ambiguous.');return$rows;
    }
    public static function effective(array $rows):?string {
        $group=null;$values=[];
        foreach($rows as$r){if($r['default_setting_value']===null||$r['default_setting_value']==='')continue;
            if($group!==$r['priority_group']){$group=$r['priority_group'];$values=[];}
            $values[]=$r;
        }
        if(!$values)return null;$selected=null;
        foreach($values as$r){if(in_array($r['default_setting_name'],['array','boolean'],true))throw new RuntimeException('The global log setting is ambiguous.');$value=self::path($r['default_setting_value']);if($selected!==null&&!self::same($selected,$value))throw new RuntimeException('The global log setting is ambiguous.');$selected=$r['default_setting_value'];}
        return$selected;
    }
    public static function plan(PDO $db,string $conf,mixed $configured=null):array {
        $owned=self::owned($conf);$effective=self::effective(self::rows($db));
        $value=$effective??(($configured===null||$configured==='')?$owned:self::path($configured));
        return ['log_directory'=>self::path($value),'spool_directory'=>rtrim(self::path($value),'/').'/xml_cdr','owned_log_directory'=>$owned,'setting_present'=>$effective!==null,'custom'=>!self::same($value,$owned)];
    }
    public static function initialize(PDO $db,string $conf,mixed $configured=null):array {
        if($db->inTransaction())throw new RuntimeException('Log initialization requires its own transaction.');$db->beginTransaction();
        try{
            $db->exec('lock table v_default_settings in share row exclusive mode');$rows=self::rows($db);$plan=self::plan($db,$conf,$configured);$inserted=0;$updated=0;
            if(!$plan['setting_present']){
                $empty=array_values(array_filter($rows,static fn(array$r):bool=>in_array($r['default_setting_name'],['dir','text'],true)&&($r['default_setting_value']===null||$r['default_setting_value']==='')));
                if(count($empty)===1){$q=$db->prepare('update v_default_settings set default_setting_value=? where default_setting_uuid=? and default_setting_enabled=true and (default_setting_value is null or default_setting_value=\'\')');$q->execute([$plan['log_directory'],$empty[0]['default_setting_uuid']]);if($q->rowCount()!==1)throw new RuntimeException('The global log setting changed.');$updated=1;}
                else{$q=$db->prepare("insert into v_default_settings(default_setting_uuid,default_setting_category,default_setting_subcategory,default_setting_name,default_setting_value,default_setting_enabled) values(?,'switch','log','dir',?,true)");$q->execute([uuid(),$plan['log_directory']]);$inserted=1;}
            }
            $db->commit();return ['schema'=>1,'state'=>'initialized','inserted'=>$inserted,'updated'=>$updated,'existing_nonempty_preserved'=>$plan['setting_present'],'custom'=>$plan['custom']];
        }catch(Throwable$e){if($db->inTransaction())$db->rollBack();throw$e;}
    }
    public static function check(PDO $db,string $conf,mixed $configured,?callable $api,bool $requireSetting=false,?callable $ordinary=null):array {
        $plan=self::plan($db,$conf,$configured);if($requireSetting&&!$plan['setting_present'])throw new RuntimeException('The Windows global log setting is missing.');
        $ordinary??=static fn(string$p):bool=>is_dir($p)&&!is_link($p);
        if($api!==null){$native=self::path(trim((string)$api('global_getvar log_dir')));if(!self::same($native,$plan['log_directory']))throw new RuntimeException('The configured and native log directories differ.');if(!$ordinary($native))throw new RuntimeException('The native log directory is unavailable.');}
        elseif($plan['custom']&&!$ordinary($plan['log_directory']))throw new RuntimeException('The custom log directory is unavailable.');
        return ['schema'=>1,'state'=>'passed','setting_present'=>$plan['setting_present'],'custom'=>$plan['custom'],'native_observed'=>$api!==null,'native_matches'=>$api!==null,'stopped_engine_layout_only'=>$api===null];
    }
}
if(realpath($_SERVER['SCRIPT_FILENAME']??'')===__FILE__){
    if(PHP_SAPI!=='cli'||PHP_OS_FAMILY!=='Windows')exit(2);
    set_exception_handler(static function(Throwable$e):void{echo json_encode(['schema'=>1,'state'=>'failed','error_type'=>get_class($e)],JSON_THROW_ON_ERROR),PHP_EOL;exit(1);});
    $web=$argv[1]??'';$mode=$argv[2]??'';if(!in_array($mode,['describe','initialize','check'],true))throw new RuntimeException('Choose the Windows log operation.');
    $no_session=true;require$web.'/resources/require.php';$db=$database->db;$configuration=config::load();$conf=(string)$configuration->get('switch.conf.dir','');$configured=$configuration->get('switch.log.dir',null);
    if($mode==='initialize')$result=openweb_windows_log::initialize($db,$conf,$configured);
    else{
        $db->beginTransaction();try{$db->exec('set transaction read only');$db->exec("set local statement_timeout='5s'");
            $result=$mode==='describe'?openweb_windows_log::plan($db,$conf,$configured):openweb_windows_log::check($db,$conf,$configured,in_array('--engine-stopped',$argv,true)?null:event_socket::api(...),in_array('--require-setting',$argv,true));$db->rollBack();
        }catch(Throwable$e){if($db->inTransaction())$db->rollBack();throw$e;}
    }
    echo json_encode($result,JSON_THROW_ON_ERROR),PHP_EOL;
}
