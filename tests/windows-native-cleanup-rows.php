<?php
/** SPDX-License-Identifier: AGPL-3.0-or-later. Read-only, fictional Windows fixture diagnostics. */
function windows_native_cleanup_rows(PDO $db,array $domains): array {
    if($db->getAttribute(PDO::ATTR_DRIVER_NAME)!=='pgsql'||$db->inTransaction()||count($domains)!==2||count(array_unique($domains))!==2)throw new InvalidArgumentException('An independent read-only fixture observer is required.');
    foreach($domains as$id)if(!is_string($id)||!preg_match('/^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$/D',$id))throw new InvalidArgumentException('Owned fixture identifiers required.');
    $categories=array_fill_keys(['cdr','history','health','queue','jobs','mail','callback','domain','other'],0);
    $out=['schema'=>1,'state'=>'observed','read_only'=>true,'all_tables_queried'=>true,'tables_checked'=>0,'leftover_tables'=>0,'leftover_rows'=>0,'counts_capped'=>false,'categories'=>$categories];
    $start=hrtime(true);
    $db->exec('begin transaction isolation level repeatable read read only');
    try{
        $db->exec("set local statement_timeout='2000ms';set local lock_timeout='500ms'");
        if($db->query("select current_setting('transaction_read_only')")->fetchColumn()!=='on')throw new RuntimeException('Read-only transaction unavailable.');
        $tables=$db->query("select distinct c.table_name from information_schema.columns c join information_schema.tables t using(table_schema,table_name) where c.table_schema='public' and c.column_name='domain_uuid' and c.table_name like 'v_%' and t.table_type='BASE TABLE' order by c.table_name")->fetchAll(PDO::FETCH_COLUMN);
        if(!$tables||count($tables)>512)throw new RuntimeException('Bounded complete fixture table inventory required.');
        foreach($tables as$table){
            if(!preg_match('/^v_[a-z0-9_]+$/D',$table)||hrtime(true)-$start>15000000000)throw new RuntimeException('Bounded complete fixture inventory unavailable.');
            $q=$db->prepare('select count(*) from public.'.$table.' where domain_uuid in (?,?)');$q->execute($domains);$value=$q->fetchColumn();
            if(!ctype_digit((string)$value))throw new RuntimeException('Fixture count unavailable.');
            $n=min(1000000,(int)$value);$out['tables_checked']++;
            if($n){$out['leftover_tables']++;$out['leftover_rows']=min(1000000,$out['leftover_rows']+$n);
                $category=match(true){$table==='v_xml_cdr'=>'cdr',$table==='v_pbx_call_history'=>'history',str_starts_with($table,'v_pbx_phone_health')=>'health',str_starts_with($table,'v_pbx_queue')||str_starts_with($table,'v_call_center_')=>'queue',str_contains($table,'job')=>'jobs',str_contains($table,'email')||str_contains($table,'mail_queue')=>'mail',str_starts_with($table,'v_pbx_cmb_')||str_contains($table,'callback')=>'callback',$table==='v_domains'=>'domain',default=>'other'};
                $out['categories'][$category]=min(1000000,$out['categories'][$category]+$n);
            }
            $out['counts_capped']=$out['counts_capped']||(int)$value>1000000||array_sum($out['categories'])>1000000;
        }
        $db->rollBack();return$out;
    }catch(Throwable$e){if($db->inTransaction())$db->rollBack();throw$e;}
}
function windows_native_cleanup_scope(array $s,string $scope,bool $allowPreOwned=false):array{
    if(!preg_match('/^[a-f0-9]{24}$/D',$scope)||($s['scope']??null)!==$scope||($s['schema']??null)!==1||($s['restore_server']??null)!==true||($s['run_id']??null)!==getenv('GITHUB_RUN_ID')||($s['service_name']??null)!=='Fictional Native '.$scope)throw new InvalidArgumentException('Exact owned hosted fixture required.');
    $admin=$s['factory_admin']??[];
    foreach([$admin['user_uuid']??null,$admin['domain_uuid']??null]as$id)if(!is_string($id)||!preg_match('/^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$/D',$id))throw new InvalidArgumentException('Original factory administrator required.');
    if($allowPreOwned&&!array_key_exists('owned',$s))return[];
    $owned=$s['owned']??[];
    foreach([$owned['domain_uuid']??null,$owned['home_domain_uuid']??null,$owned['tenant_uuid']??null,$admin['user_uuid']??null,$admin['domain_uuid']??null]as$id)if(!is_string($id)||!preg_match('/^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$/D',$id))throw new InvalidArgumentException('Owned fixture identifiers required.');
    if(!preg_match('/^pbx-[a-f0-9]{12}\.[a-z0-9.-]+$/D',$owned['domain_name']??'')||$owned['domain_uuid']===$owned['home_domain_uuid']||in_array($admin['domain_uuid'],[$owned['domain_uuid'],$owned['home_domain_uuid']],true))throw new InvalidArgumentException('Unrelated administrator and exact fictional service required.');
    return[$owned['domain_uuid'],$owned['home_domain_uuid']];
}
function windows_native_cleanup_input(string $inputPath,bool $allowPreOwned=false):array{
    if(PHP_SAPI!=='cli'||PHP_OS_FAMILY!=='Windows'||getenv('OPENWEB_WINDOWS_NATIVE_TEST')!=='1'||getenv('GITHUB_ACTIONS')!=='true'||getenv('RUNNER_ENVIRONMENT')!=='github-hosted'||getenv('GITHUB_REPOSITORY')!=='embire2/openwebpbx')throw new RuntimeException('Disposable Windows runner required.');
    $path=$inputPath;$canonical=realpath($path);$root=realpath((getenv('ProgramData')?:'C:/ProgramData').'/OpenWebPBX/native-qualification');
    if(!$canonical||!$root||is_link($path)||!is_file($path)||filesize($path)>1048576||basename($canonical)!=='input.json'||strcasecmp(dirname(dirname($canonical)),$root)!==0)throw new RuntimeException('Protected fixture input required.');
    $s=json_decode(file_get_contents($canonical),true,64,JSON_THROW_ON_ERROR);$domains=windows_native_cleanup_scope($s,basename(dirname($canonical)),$allowPreOwned);
    return[$s,$domains];
}
if(realpath($_SERVER['SCRIPT_FILENAME']??'')===__FILE__){
    $out=['schema'=>1,'state'=>'unavailable'];$code=1;
    try{
        [$s,$domains]=windows_native_cleanup_input($argv[1]??'');
        // This deliberately avoids fixture.php's service/realm/config preamble: cleanup
        // may already have deleted those owned records. No calling-engine API is used.
        require 'C:/OpenWebPBX/web/resources/require.php';$out=windows_native_cleanup_rows($database->db,$domains);$code=0;
    }catch(Throwable$e){$out['error_kind']=$e instanceof PDOException&&in_array((string)$e->getCode(),['57014','55P03'],true)?'timeout':'unavailable';}
    echo json_encode($out,JSON_THROW_ON_ERROR),PHP_EOL;exit($code);
}
