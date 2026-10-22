<?php
/** Execute the actual bootstrap statements on isolated PostgreSQL, never a full install. */
if (PHP_SAPI !== 'cli' || PHP_OS_FAMILY !== 'Linux') exit(2);
require dirname(__DIR__).'/resources/require.php';
$db = database::new()->db;
$db->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
$source = file_get_contents(dirname(__DIR__).'/packaging/windows/bootstrap.php');
$tokens = token_get_all($source, TOKEN_PARSE);
$hooks = [];
foreach ($tokens as $index => $token) {
    if (!is_array($token) || $token[0] !== T_CONSTANT_ENCAPSED_STRING
        || !str_contains($token[1], '/app/pbx_setup/resources/phone_health.sql')) continue;
    // Extract the actual complete enclosing if statement, not a copy of its SQL.
    $start = $index;
    while ($start > 0 && (!is_array($tokens[$start]) || $tokens[$start][0] !== T_IF)) $start--;
    if (!is_array($tokens[$start]) || $tokens[$start][0] !== T_IF) throw new RuntimeException('Missing bootstrap condition.');
    $statement = ''; $depth = 0; $done = false;
    for ($end = $start; $end < count($tokens); $end++) {
        $text = is_array($tokens[$end]) ? $tokens[$end][1] : $tokens[$end];
        $statement .= $text;
        if ($text === '(') $depth++;
        if ($text === ')') $depth--;
        if ($text === ';' && $depth === 0) { $done = true; break; }
    }
    if (!$done || $depth !== 0) throw new RuntimeException('Incomplete bootstrap condition.');
    $hooks[] = $statement;
}
if (count($hooks) !== 2) throw new RuntimeException('Review bootstrap Phone Health branch extraction.');
$checks = 0;
$check = static function(bool $ok, string $why) use (&$checks): void {
    if (!$ok) throw new RuntimeException($why);
    $checks++;
};
$query = static function(string $sql, array $params = []) use ($db): PDOStatement {
    $statement = $db->prepare($sql); $statement->execute($params); return $statement;
};
$base = ['v_domains','v_extensions','v_users','v_gateways','v_pbx_restore'];
$health = ['v_pbx_phone_health_contacts','v_pbx_phone_health_recoveries','v_pbx_phone_health_issues',
           'v_pbx_phone_health_settings','v_pbx_phone_health_state'];
$snapshot = static function(array $tables) use ($query): array {
    $rows = [];
    foreach ($tables as $table) {
        $rows[$table] = $query('select coalesce(jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text),\'[]\'::jsonb)::text from '.$table.' t')->fetchColumn();
    }
    return $rows;
};
$web = dirname(__DIR__);
$schemas = [];
try {
    foreach (['fresh_admin' => $hooks[1], 'upgrade_migrate' => $hooks[0]] as $branch => $hook) {
        $schema = 'health_boot_'.bin2hex(random_bytes(6)); $schemas[] = $schema;
        $db->exec('create schema '.$schema.';set search_path to '.$schema);
        $db->exec('create table v_domains(domain_uuid uuid primary key,label text);
            create table v_extensions(extension_uuid uuid primary key,domain_uuid uuid,password text);
            create table v_users(user_uuid uuid primary key,domain_uuid uuid,label text);
            create table v_gateways(gateway_uuid uuid primary key,domain_uuid uuid,password text);
            create table v_pbx_restore(domain_uuid uuid primary key,config jsonb)');
        $domain = uuid(); $extension = uuid(); $actor = uuid();
        $query("insert into v_domains values(?,'Unchanged original domain')", [$domain]);
        $query("insert into v_extensions values(?,?,'original-phone-secret')", [$extension, $domain]);
        $query("insert into v_users values(?,?,'Unchanged original owner')", [$actor, $domain]);
        $query("insert into v_gateways values(?,?,'original-provider-secret')", [uuid(), $domain]);
        $query('insert into v_pbx_restore values(?,?::jsonb)', [$domain, json_encode(['users'=>['1000'=>['password'=>'original-secret']], 'routes'=>['unchanged']])]);
        $original = $snapshot($base);
        eval($hook);
        foreach ($health as $table) {
            $check($query('select to_regclass(?)::text', [$table])->fetchColumn() === $table, $branch.' did not create a health table.');
        }
        $check($original === $snapshot($base), $branch.' changed original base-table data.');
        // Existing health history, operator preference and authentication material
        // must also survive another fresh/admin or normal migrate invocation.
        $query("insert into v_pbx_phone_health_contacts(domain_uuid,extension_uuid,source_address,expires_at)
            values(?,?,'192.0.2.44',now()+interval '1 hour')", [$domain, $extension]);
        $query("insert into v_pbx_phone_health_recoveries(recovery_uuid,domain_uuid,actor_uuid,block_uuid,source_address,status)
            values(?,?,?,?,'192.0.2.44','pending')", [uuid(), $domain, $actor, uuid()]);
        $query("insert into v_pbx_phone_health_issues(issue_uuid,domain_uuid,issue_key,kind,severity,summary)
            values(?,?,'fixture:original','office_blocked','danger','Preserve original incident')", [uuid(), $domain]);
        $query('insert into v_pbx_phone_health_settings(domain_uuid) values(?)', [$domain]);
        $check($query('select alerts_enabled from v_pbx_phone_health_settings where domain_uuid=?', [$domain])->fetchColumn() === false,
            $branch.' enabled outgoing alerts by default.');
        $query('update v_pbx_phone_health_settings set alerts_enabled=true where domain_uuid=?', [$domain]);
        $query("insert into v_pbx_phone_health_state values(?,now(),true,'Preserve previous observation')", [$domain]);
        $all = $snapshot([...$base, ...$health]);
        foreach ([$hook, $hooks[0], $hooks[1]] as $repeat) {
            eval($repeat);
            $check($all === $snapshot([...$base, ...$health]), $branch.' replay changed original or health-history rows.');
        }
        $db->exec('set search_path to public;drop schema '.$schema.' cascade');
        array_pop($schemas);
    }
    echo json_encode(['checks'=>$checks,'actual_isolated_postgresql'=>true,'branches'=>['fresh_admin','upgrade_migrate'],
        'actual_php_bootstrap_statements'=>true,'all_original_and_health_rows_preserved'=>true,
        'bootstrap_sha256'=>hash('sha256',$source),'schema_sha256'=>hash_file('sha256',$web.'/app/pbx_setup/resources/phone_health.sql'),
        'full_installer_executed'=>false], JSON_THROW_ON_ERROR).PHP_EOL;
} finally {
    if ($db->inTransaction()) $db->rollBack();
    $db->exec('set search_path to public');
    foreach ($schemas as $schema) $db->exec('drop schema if exists '.$schema.' cascade');
}
