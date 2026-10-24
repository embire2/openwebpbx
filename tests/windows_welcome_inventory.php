<?php
/** Bounded, read-only QA observations. Never an acceptance predicate. */
function welcome_inventory_known_tables(): array {
    return ['v_default_settings','v_domain_settings','v_domains','v_email_queue','v_email_queue_attachments','v_event_guard_logs','v_extensions','v_gateways','v_logs','v_pbx_backup_commands','v_pbx_backup_settings','v_pbx_backup_status','v_pbx_backups','v_pbx_jobs','v_pbx_mobile_devices','v_pbx_phone_health_contacts','v_pbx_phone_health_issues','v_pbx_phone_health_recoveries','v_pbx_phone_health_settings','v_pbx_phone_health_state','v_pbx_restore','v_pbx_services','v_pbx_tenant_domains','v_pbx_tenants','v_pbx_update_commands','v_pbx_update_policies','v_pbx_update_status','v_user_logs','v_user_settings','v_users','v_xml_cdr'];
}

function welcome_inventory_sample(PDO $db): ?array {
    // This diagnostic has a smaller budget than the original fingerprint.
    // Its own transaction resets all local deadlines and holds no write locks.
    if($db->inTransaction())return null;
    $started=microtime(true);$owned=false;
    try {
        $db->beginTransaction();$owned=true;
        $db->exec('set transaction isolation level repeatable read, read only');
        $db->exec("set local statement_timeout='750ms';set local lock_timeout='250ms';set local work_mem='1MB'");
        $tables=$db->query("select tablename from pg_tables where schemaname='public' order by tablename limit 513")->fetchAll(PDO::FETCH_COLUMN);
        if(count($tables)>512)throw new RuntimeException('Diagnostic inventory limit.');
        $hash=hash_init('sha256');$out=[];$bytes=0;
        foreach($tables as$table){
            if(!is_string($table)||strlen($table)>63||!preg_match('/^[a-z_][a-z0-9_]*$/D',$table)||microtime(true)-$started>2.0)throw new RuntimeException('Diagnostic inventory limit.');
            hash_update($hash,$table."\0");$rowHash=hash_init('sha256');$count=0;
            $db->exec('declare welcome_inventory_rows no scroll cursor for select case when octet_length(row_to_json(t)::text)<=1048576 then row_to_json(t)::text else null end from public."'.$table.'" t order by row_to_json(t)::text collate "C"');
            do {
                if(microtime(true)-$started>2.0)throw new RuntimeException('Diagnostic inventory limit.');
                $batch=$db->query('fetch forward 1 from welcome_inventory_rows')->fetchAll(PDO::FETCH_COLUMN);
                foreach($batch as$row){
                    if(!is_string($row)||strlen($row)>1048576||($bytes+=strlen($row))>8388608||++$count>1000000)throw new RuntimeException('Diagnostic inventory limit.');
                    $entry=strlen($row).':'.$row."\n";hash_update($hash,$entry);hash_update($rowHash,$entry);
                }
            }while(count($batch)===1);
            $db->exec('close welcome_inventory_rows');$out[$table]=['rows'=>$count,'sha256'=>hash_final($rowHash)];
        }
        $result=['aggregate'=>hash_final($hash),'tables'=>$out];
        $db->rollBack();$owned=false;return $result;
    }catch(Throwable $ignored){return null;}
    finally{if($owned&&$db->inTransaction()){try{$db->rollBack();}catch(Throwable $ignored){}}}
}

function welcome_inventory_baseline(PDO $db,string $original): array {
    $sample=welcome_inventory_sample($db);
    if($sample===null)return ['state'=>'unavailable'];
    if($sample['aggregate']!==$original)return ['state'=>'unstable'];
    return ['state'=>'matched','sample'=>$sample];
}

function welcome_inventory_valid_sample(mixed $sample,string $original): bool {
    if(!is_array($sample)||array_keys($sample)!==['aggregate','tables']||$sample['aggregate']!==$original||!is_array($sample['tables'])||count($sample['tables'])>512)return false;
    foreach($sample['tables']as$name=>$row)if(!is_string($name)||strlen($name)>63||!preg_match('/^[a-z_][a-z0-9_]*$/D',$name)||!is_array($row)||array_keys($row)!==['rows','sha256']||!is_int($row['rows'])||$row['rows']<0||$row['rows']>1000000||!is_string($row['sha256'])||!preg_match('/^[a-f0-9]{64}$/D',$row['sha256']))return false;
    return true;
}

function welcome_inventory_failure(PDO $db,array $state,string $configFile,string $publicAfter,mixed $configAfter): ?array {
    try {
        $before=$state['public_before']??null;$originalConfig=$state['original_config_sha256']??null;
        if(!is_string($before)||!preg_match('/^[a-f0-9]{64}$/D',$before)||!preg_match('/^[a-f0-9]{64}$/D',$publicAfter)||!is_string($originalConfig)||!preg_match('/^[a-f0-9]{64}$/D',$originalConfig))return null;
        $configCheck='original';
        if($configAfter===null){$configCheck='after_refusal';$configAfter=@hash_file('sha256',$configFile);}
        if(!is_string($configAfter)||!preg_match('/^[a-f0-9]{64}$/D',$configAfter))$configCheck='unavailable';
        $out=['schema'=>1,'public_equal'=>$publicAfter===$before,'config_equal'=>$configAfter===$originalConfig,'config_check'=>$configCheck,
            'baseline_state'=>'unavailable','sample_state'=>'unavailable','before_tables'=>0,'after_tables'=>0,'changed_tables'=>0,'added_tables'=>0,'removed_tables'=>0,'unlisted_tables'=>0,'tables'=>[]];
        $baseline=$state['public_observation_before']??null;
        if(is_array($baseline)&&($baseline['state']??null)==='unstable')$out['baseline_state']='unstable';
        if(is_array($baseline)&&($baseline['state']??null)==='matched'&&welcome_inventory_valid_sample($baseline['sample']??null,$before)){
            $out['baseline_state']='matched';$out['before_tables']=count($baseline['sample']['tables']);
        }
        $sample=welcome_inventory_sample($db);
        if($sample!==null){
            $out['sample_state']=$sample['aggregate']===$publicAfter?'matched':'unstable';
            if($out['sample_state']==='matched')$out['after_tables']=count($sample['tables']);
        }
        if($out['baseline_state']==='matched'&&$out['sample_state']==='matched'){
            $a=$baseline['sample']['tables'];$b=$sample['tables'];$names=array_unique(array_merge(array_keys($a),array_keys($b)));sort($names,SORT_STRING);
            foreach($names as$name){
                if(isset($a[$name],$b[$name])&&$a[$name]===$b[$name])continue;
                $kind=!isset($a[$name])?'added':(!isset($b[$name])?'removed':'changed');$out['changed_tables']++;
                if($kind==='added')$out['added_tables']++;if($kind==='removed')$out['removed_tables']++;
                if(in_array($name,welcome_inventory_known_tables(),true)&&count($out['tables'])<8)$out['tables'][]=['name'=>$name,'before'=>$a[$name]['rows']??0,'after'=>$b[$name]['rows']??0,'kind'=>$kind];
                else $out['unlisted_tables']++;
            }
        }
        if(strlen(json_encode($out,JSON_THROW_ON_ERROR))>1400)return null;
        return $out;
    }catch(Throwable $ignored){return null;}
}
