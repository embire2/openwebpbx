<?php
/** QA-only read-only restart diagnostics. No PBX bootstrap or lock acquisition. */
function windows_health_restart_journal(string $path,string $field,array $allowed): string {
    clearstatcache(true,$path);
    if(!file_exists($path)&&!is_link($path))return 'absent';
    if(is_link($path)||!is_file($path))return 'unsafe_type';
    $size=@filesize($path);if(!is_int($size))return 'unreadable';if($size>1048576)return 'oversized';
    $raw=@file_get_contents($path,false,null,0,1048577);if(!is_string($raw))return 'unreadable';if(strlen($raw)>1048576)return 'oversized';
    try{$value=json_decode($raw,true,32,JSON_THROW_ON_ERROR);}catch(Throwable){return 'invalid';}
    if(!is_array($value)||!array_key_exists($field,$value))return 'invalid';
    return in_array($value[$field],$allowed,true)?'accepted':'blocking';
}
function windows_health_restart_phase(PDO $db,string $state,array $ports): array {
    if(count($ports)>32||array_values($ports)!==$ports||count(array_unique($ports,SORT_REGULAR))!==count($ports))throw new InvalidArgumentException('Bounded unique owned connection ports required.');
    foreach($ports as$port)if(!is_int($port)||$port<1||$port>65535)throw new InvalidArgumentException('Typed owned connection ports required.');
    $out=['schema'=>1,'state'=>'observed','snapshot_atomic'=>false,'runtime_observed'=>false,'runtime_ready'=>false,'holds'=>array_fill_keys(['calls','jobs','updates','backups'],'unobserved'),'journals'=>array_fill_keys(['installation','update','restore'],'unobserved'),'database_observed'=>false,'backends'=>[],'error_kind'=>'none'];
    try{
        foreach(['calls','jobs','updates','backups']as$name){$path=$state.'/backup-restore/hold-'.$name;clearstatcache(true,$path);$out['holds'][$name]=(file_exists($path)||is_link($path))?'present':'absent';}
        foreach(['installation'=>[$state.'/installation.json','Completed',[true]],'update'=>[$state.'/updates/install-journal.json','state',['completed','rolled_back']],'restore'=>[$state.'/backup-restore/journal.json','state',['restored','recovered']]]as$name=>[$path,$field,$allowed])$out['journals'][$name]=windows_health_restart_journal($path,$field,$allowed);
        set_error_handler(static function(int $severity,string $message):never{throw new ErrorException('Read-only runtime observation refused.',0,$severity);});
        try{$out['runtime_ready']=pbx_windows_health_runtime::ready($state);}finally{restore_error_handler();}
        $out['runtime_observed']=true;
    }catch(Throwable){$out['error_kind']='runtime';}
    $transactionOwned=false;
    try{
        if($db->inTransaction())throw new RuntimeException('A fresh observation connection is required.');
        $db->beginTransaction();$transactionOwned=true;$db->exec("set transaction read only;set local statement_timeout='2s';set local lock_timeout='500ms'");
        $where=$ports?'client_port in ('.implode(',',array_fill(0,count($ports),'?')).')':'false';
        // SQL text remains inside PostgreSQL. Only fixed classifications leave it.
        $sql="select case when state in ('active','idle','idle in transaction','idle in transaction (aborted)','fastpath function call','disabled') then state else 'other' end state,
          case when wait_event_type is null then 'none' when wait_event_type in ('Activity','BufferPin','Client','Extension','IO','IPC','Lock','LWLock','Timeout') then wait_event_type else 'other' end wait_type,
          case when wait_event is null then 'none' when wait_event in ('ClientRead','ClientWrite','advisory','relation','transactionid','tuple') then wait_event else 'other' end wait_event,
          case when query like 'select recovery_uuid,block_uuid from v_pbx_phone_health_recoveries %' then 'recovery_heartbeat'
            when query like 'select pg_advisory_xact_lock(%' then 'advisory_lock'
            when query like 'select event_guard_log_uuid from v_event_guard_logs %' then 'guard_intent_read'
            when query ~* '^select .*v_event_guard_logs' then 'guard_read'
            when query ~* '^(insert into|update|delete from) v_event_guard_logs' then 'guard_write'
            when query ~* '^select .*v_pbx_phone_health_' then 'health_read'
            when query ~* '^(insert into|update|delete from) v_pbx_phone_health_' then 'health_write'
            when query ~* '^select .*v_(default_settings|settings|domains|extensions|pbx_restore|access_control_nodes)' then 'configuration_read'
            when query ~* '^(begin|commit|rollback)$' then 'transaction'
            when query ~* '^set ' then 'session_setup' else 'other' end query_class
          from pg_stat_activity where datname=current_database() and usename=current_user and pid<>pg_backend_pid() and client_addr='127.0.0.1'::inet and $where order by client_port limit 33";
        $query=$db->prepare($sql);foreach($ports as$i=>$port)$query->bindValue($i+1,$port,PDO::PARAM_INT);$query->execute();$rows=$query->fetchAll(PDO::FETCH_ASSOC);
        if(count($rows)>32)throw new RuntimeException('The owned backend count exceeds its bound.');
        foreach($rows as$row){
            foreach(['state'=>['active','idle','idle in transaction','idle in transaction (aborted)','fastpath function call','disabled','other'],'wait_type'=>['none','Activity','BufferPin','Client','Extension','IO','IPC','Lock','LWLock','Timeout','other'],'wait_event'=>['none','ClientRead','ClientWrite','advisory','relation','transactionid','tuple','other'],'query_class'=>['recovery_heartbeat','advisory_lock','guard_intent_read','guard_read','guard_write','health_read','health_write','configuration_read','transaction','session_setup','other']]as$key=>$values)if(!is_string($row[$key]??null)||!in_array($row[$key],$values,true))throw new RuntimeException('A closed backend classification is required.');
        }
        $db->commit();$out['database_observed']=true;$out['backends']=$rows;
    }catch(Throwable){if($transactionOwned&&$db->inTransaction())try{$db->rollBack();}catch(Throwable){}$out['error_kind']=$out['error_kind']==='runtime'?'runtime_database':'database';}
    return $out;
}
