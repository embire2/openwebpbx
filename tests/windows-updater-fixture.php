<?php
/** SPDX-License-Identifier: AGPL-3.0-or-later. Private disposable updater audit. */

function updater_fixture_greeting_heartbeat(array $rows): array {
    if(count($rows)>1)throw new RuntimeException('Greeting heartbeat must retain its exact singleton inventory.');
    $projected=[];
    foreach($rows as $row){
        if(!$row instanceof stdClass)throw new RuntimeException('Greeting heartbeat row is malformed.');
        $fields=array_keys(get_object_vars($row));sort($fields,SORT_STRING);
        if($fields!==['checked_at','provider_configured','singleton']||!is_int($row->singleton)||$row->singleton!==1||!is_bool($row->provider_configured)
            ||!is_string($row->checked_at)||!preg_match('/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$/D',$row->checked_at))
            throw new RuntimeException('Greeting heartbeat schema or values changed.');
        $time=new DateTimeImmutable($row->checked_at);$errors=DateTimeImmutable::getLastErrors();
        if($errors!==false&&($errors['warning_count']||$errors['error_count']))throw new RuntimeException('Greeting heartbeat time is malformed.');
        $copy=clone $row;$copy->checked_at='__openweb_worker_heartbeat__';$projected[]=$copy;
    }
    return $projected;
}

if (PHP_SAPI !== 'cli' || PHP_OS_FAMILY !== 'Windows' || getenv('OPENWEB_WINDOWS_UPDATER_TEST') !== '1'
    || getenv('GITHUB_ACTIONS') !== 'true' || getenv('RUNNER_ENVIRONMENT') !== 'github-hosted'
    || getenv('GITHUB_REPOSITORY') !== 'embire2/openwebpbx') exit(2);
require 'C:/OpenWebPBX/web/resources/require.php';
$path = $argv[2] ?? '';
$directory = realpath(dirname($path)); $base = realpath(pbx_paths::state().'/updater-qualification');
if (!$directory || !$base || strtolower(str_replace('\\','/',dirname($directory))) !== strtolower(str_replace('\\','/',$base))
    || !preg_match('/^[a-f0-9]{24}$/D',basename($directory)) || basename($path) !== 'input.json' || is_link($path))
    throw new RuntimeException('The private disposable qualification input is required.');
$s = json_decode(file_get_contents($path),true,64,JSON_THROW_ON_ERROR);
$installation = json_decode(file_get_contents(pbx_paths::state().'/installation.json'),true,32,JSON_THROW_ON_ERROR);
if (($s['schema'] ?? null) !== 1 || ($s['run_id'] ?? '') !== getenv('GITHUB_RUN_ID')
    || ($s['scope'] ?? '') !== basename($directory) || !($installation['RestoreServer'] ?? false)
    || !($installation['Completed'] ?? false) || ($installation['DomainName'] ?? '') !== 'windowsqa.example.invalid'
    || ($installation['AdminEmail'] ?? '') !== ($s['admin_email'] ?? '')) throw new RuntimeException('The owned replacement factory is required.');
$db = $database->db; $db->setAttribute(PDO::ATTR_ERRMODE,PDO::ERRMODE_EXCEPTION);
$q = static function(string $sql,array $args=[]) use($db): PDOStatement {$p=$db->prepare($sql);$p->execute($args);return $p;};
$save = static function() use(&$s,$path): void {file_put_contents($path,json_encode($s,JSON_THROW_ON_ERROR|JSON_PRETTY_PRINT));};
$factory = static function() use($q): void {
    foreach (['v_extensions','v_pbx_tenants','v_pbx_services','v_pbx_restore','v_gateways','v_pbx_jobs','v_recordings','v_voicemail_messages'] as $t)
        if ((int)$q('select count(*) from '.$t)->fetchColumn() !== 0) throw new RuntimeException('An independently empty factory is required.');
    if ((int)$q('select count(*) from v_users')->fetchColumn() !== 1 || (int)$q('select count(*) from v_domains')->fetchColumn() !== 1)
        throw new RuntimeException('An independently empty factory is required.');
};
$action = $argv[1] ?? '';
if ($action === 'baseline') {
    $factory(); $s['factory_admin']=$q('select user_uuid,domain_uuid from v_users where username=?',[$s['admin_email']])->fetch(PDO::FETCH_ASSOC);
    if (!$s['factory_admin']) throw new RuntimeException('The real factory administrator is required.');
    $s['original_drafts']=$q('select draft_uuid from v_pbx_setup_drafts')->fetchAll(PDO::FETCH_COLUMN);
    $s['original_update_commands']=$q('select command_uuid from v_pbx_update_commands')->fetchAll(PDO::FETCH_COLUMN);
    $save();echo "{\"factory_empty\":true}\n";exit;
}
if (!isset($s['factory_admin'])) throw new RuntimeException('A captured factory baseline is required.');
if ($action === 'discover') {
    $owned=$q('select s.domain_uuid,s.tenant_uuid,d.domain_name,t.home_domain_uuid from v_pbx_services s join v_domains d using(domain_uuid) join v_pbx_tenants t using(tenant_uuid) where s.service_name=? and t.owner_user_uuid=?',[$s['service_name'],$s['factory_admin']['user_uuid']])->fetchAll(PDO::FETCH_ASSOC);
    if (count($owned)!==1 || !preg_match('/^pbx-[a-f0-9]{12}\./D',$owned[0]['domain_name'])) throw new RuntimeException('Normal setup did not create the exact owned fictional PBX.');
    $s['owned']=$owned[0];$save();echo "{\"normal_setup_discovered\":true}\n";exit;
}
if ($action === 'status') {
    $pending=$q("select command_uuid,action,status from v_pbx_update_commands order by created_at,command_uuid")->fetchAll(PDO::FETCH_ASSOC);
    $native=json_decode(event_socket::api('show channels as json'),true,32,JSON_THROW_ON_ERROR);
    if (!isset($native['row_count'])) throw new RuntimeException('Actual native call count is unavailable.');
    echo json_encode(['commands'=>$pending,'channels'=>(int)$native['row_count']],JSON_THROW_ON_ERROR),PHP_EOL;exit;
}
if ($action === 'snapshot') {
    $key=file_get_contents($directory.'/audit.key');if (strlen($key)!==32) throw new RuntimeException('An independent audit key is required.');
    $digest=static fn($v):string => hash_hmac('sha256',json_encode($v,JSON_THROW_ON_ERROR|JSON_UNESCAPED_SLASHES),$key);
    $admin=new PDO('pgsql:host=127.0.0.1;port=5433;dbname=fusionpbx','postgres',$installation['PostgresPassword'],[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);
    $aq=static fn(string $sql):array => $admin->query($sql)->fetchAll(PDO::FETCH_ASSOC);
    $out=['identity'=>$digest($aq("select datname,oid,datdba,datacl::text from pg_database where datname=current_database()")),
        'cluster'=>$digest($aq('select system_identifier,pg_control_version,catalog_version_no from pg_control_system()')),
        'roles'=>$digest($aq('select * from pg_authid order by oid')),
        'memberships'=>$digest($aq('select * from pg_auth_members order by roleid,member,grantor')),
        'role_settings'=>$digest($aq('select * from pg_db_role_setting order by setdatabase,setrole')),
        // PostgreSQL recovery rebuilds the public schema; its owner/grants and
        // structure must match while the database and cluster identity stay exact.
        'schema'=>$digest($aq("select nspname,nspowner,nspacl::text from pg_namespace where nspname='public'")),
        'table_metadata'=>$digest($aq("select c.relname,c.relowner,c.relacl::text,c.relkind from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind in ('r','p') order by c.relname")),
        'columns'=>$digest($aq("select table_name,column_name,ordinal_position,data_type,udt_name,is_nullable,column_default from information_schema.columns where table_schema='public' order by table_name,ordinal_position")), 'values'=>[]];
    // Schema and table metadata remain covered. Only updater/heartbeat/session
    // operational values are excluded; customer/security/routing rows stay exact.
    $volatile=['v_pbx_update_status','v_pbx_backup_status','v_pbx_update_commands','v_pbx_job_slots','v_user_logs','v_logs','v_pbx_user_presence','v_pbx_presence'];
    foreach ($q("select tablename from pg_tables where schemaname='public' order by tablename")->fetchAll(PDO::FETCH_COLUMN) as $table) {
        if (in_array($table,$volatile,true)) continue;
        $quoted='"'.str_replace('"','""',$table).'"';
        $rows=$db->query('select coalesce(json_agg(t order by row_to_json(t)::text),\'[]\') from '.$quoted.' t')->fetchColumn();
        // Only the existing worker's validated singleton timestamp is a heartbeat.
        // Keep this table, provider state, inventory and every schema field exact.
        $values=$table==='v_pbx_greeting_status'
            ? updater_fixture_greeting_heartbeat(json_decode($rows,false,512,JSON_THROW_ON_ERROR))
            : json_decode($rows,true,512,JSON_THROW_ON_ERROR);
        $out['values'][$table]=$digest($values);
    }
    $label=$s['snapshot_label']??'';if(!preg_match('/^[a-z0-9-]{1,48}$/D',$label))throw new RuntimeException('A fixed audit label is required.');
    file_put_contents($directory.'/'.$label.'-database.json',json_encode($out,JSON_THROW_ON_ERROR|JSON_PRETTY_PRINT));
    echo json_encode(['tables'=>count($out['values']),'private_hmac_inventory'=>true],JSON_THROW_ON_ERROR),PHP_EOL;exit;
}
if ($action === 'cleanup') {
    $owned=$s['owned']??null;
    if ($owned) {
        if ($q('select domain_name from v_domains where domain_uuid=?',[$owned['domain_uuid']])->fetchColumn()!==$owned['domain_name']) throw new RuntimeException('Owned fixture identity changed.');
        if ((int)$q('select count(*) from v_gateways')->fetchColumn()!==0) throw new RuntimeException('Cleanup refuses any carrier gateway.');
        $native=json_decode(event_socket::api('show channels as json'),true,32,JSON_THROW_ON_ERROR);
        if (!isset($native['row_count']) || (int)$native['row_count']!==0) throw new RuntimeException('Cleanup refuses active native calls.');
        $db->beginTransaction();
        foreach (['domain_uuid'=>[$owned['domain_uuid'],$owned['home_domain_uuid']],'tenant_uuid'=>[$owned['tenant_uuid']]] as $column=>$ids) {
            $tables=$q("select distinct c.table_name from information_schema.columns c join information_schema.tables t using(table_schema,table_name) where c.table_schema='public' and c.column_name=? and c.table_name like 'v_%' and t.table_type='BASE TABLE'",[$column])->fetchAll(PDO::FETCH_COLUMN);
            foreach ($tables as $table) if ($table!=='v_domains' && preg_match('/^v_[a-z0-9_]+$/D',$table)) foreach ($ids as $id) $q('delete from '.$table.' where '.$column.'=?',[$id]);
        }
        foreach ([$owned['domain_uuid'],$owned['home_domain_uuid']] as $id) $q('delete from v_domains where domain_uuid=?',[$id]);
        foreach ($q('select draft_uuid from v_pbx_setup_drafts where user_uuid=?',[$s['factory_admin']['user_uuid']])->fetchAll(PDO::FETCH_COLUMN) as $id)
            if (!in_array($id,$s['original_drafts'],true)) $q('delete from v_pbx_setup_drafts where draft_uuid=?',[$id]);
        $db->commit();event_socket::api('reloadxml');
    }
    foreach ($s['owned_update_commands']??[] as $id) {
        if (!is_uuid($id) || in_array($id,$s['original_update_commands']??[],true)) throw new RuntimeException('Cleanup refused an unowned global command.');
        $row=$q('select action,status,requested_by from v_pbx_update_commands where command_uuid=?',[$id])->fetch(PDO::FETCH_ASSOC);
        if (!$row || $row['action']!=='install' || !in_array($row['status'],['failed','completed'],true) || $row['requested_by']!==$s['factory_admin']['user_uuid']) throw new RuntimeException('Cleanup refused a changed global update command.');
        $q('delete from v_pbx_update_commands where command_uuid=?',[$id]);
    }
    $factory();echo "{\"owned_rows\":0,\"factory_empty\":true}\n";exit;
}
throw new RuntimeException('Unknown private updater qualification operation.');
