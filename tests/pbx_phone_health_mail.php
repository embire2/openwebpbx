<?php
/** Isolated PostgreSQL + actual global outbox; SMTP is supplied by the loopback wrapper. */
if (PHP_SAPI !== 'cli') exit(2);
require dirname(__DIR__).'/resources/require.php';
if (in_array($argv[1] ?? '', ['--deliver', '--enqueue'], true)) {
    $schema = $argv[2] ?? '';
    if (!preg_match('/^health_mail_[a-f0-9]{12}$/D', $schema)) exit(2);
    $database->db->exec('set search_path to '.$schema.',public');
    if ($argv[1] === '--deliver') {
        $id = $argv[3] ?? '';
        if (!is_uuid($id)) exit(2);
        $job = dirname(__DIR__).'/app/email_queue/resources/jobs/email_send.php';
        $argv = [$job, 'email_queue_uuid='.$id.'&hostname='.urlencode(gethostname())];
        include $job;
    } else {
        $transition = json_decode($argv[3] ?? '', true, 8, JSON_THROW_ON_ERROR);
        $database->db->beginTransaction();
        $queued = pbx_phone_health_mail::queue($database->db, $transition);
        usleep(200000);
        $database->db->commit();
        echo $queued ? 'queued' : 'duplicate';
    }
    exit;
}
$port = (int)($argv[1] ?? 0);
if ($port < 1024 || $port > 65535) throw new RuntimeException('Loopback SMTP fixture required.');
$db = $database->db;
$schema = 'health_mail_'.bin2hex(random_bytes(6));
$checks = 0;
$q = static function(string $sql, array $params = []) use ($db): PDOStatement {
    $statement = $db->prepare($sql); $statement->execute($params); return $statement;
};
$check = static function(bool $ok, string $why) use (&$checks): void {
    if (!$ok) throw new RuntimeException($why); $checks++;
};
$queue = static function(array $transition) use ($db): bool {
    $db->beginTransaction();
    try { $queued = pbx_phone_health_mail::queue($db, $transition); $db->commit(); return $queued; }
    catch (Throwable $error) { if ($db->inTransaction()) $db->rollBack(); throw $error; }
};
$start = static function(array $args) {
    $process = proc_open([PHP_BINARY, __FILE__, ...$args], [0=>['pipe','r'],1=>['pipe','w'],2=>['pipe','w']], $pipes, dirname(__DIR__));
    if (!is_resource($process)) throw new RuntimeException('Local queue fixture failed to start.');
    fclose($pipes[0]); return [$process, $pipes];
};
$finish = static function(array $child) use ($check): string {
    [$process, $pipes] = $child;
    $output = stream_get_contents($pipes[1]); $error = stream_get_contents($pipes[2]);
    fclose($pipes[1]); fclose($pipes[2]);
    $check(proc_close($process) === 0 && $error === '', 'Actual isolated queue child failed.');
    return $output;
};
try {
    $db->exec('create schema '.$schema.';set search_path to '.$schema.',public');
    foreach (['v_default_settings','v_domain_settings','v_email_queue','v_email_queue_attachments','v_domains','v_extensions','v_users','v_pbx_tenants','v_pbx_services','v_voicemails','v_voicemail_messages'] as $table) {
        $db->exec('create table '.$table.'(like public.'.$table.' including all)');
    }
    $db->exec('insert into v_default_settings select * from public.v_default_settings');
    foreach (['smtp_global'=>'true','smtp_host'=>'127.0.0.1','smtp_port'=>(string)$port,'smtp_secure'=>'none','smtp_auth'=>'false',
              'smtp_from'=>'health-system@example.invalid','smtp_from_name'=>'Health Fixture','smtp_reply_to'=>'health-reply@example.invalid',
              'smtp_ipv4_only'=>'true','smtp_username'=>'','smtp_password'=>''] as $name=>$value) {
        $q("delete from v_default_settings where default_setting_category='email' and default_setting_subcategory=?", [$name]);
        $q("insert into v_default_settings(default_setting_uuid,default_setting_category,default_setting_subcategory,default_setting_name,default_setting_value,default_setting_enabled) values(?,'email',?,'text',?,true)", [uuid(), $name, $value]);
    }
    $db->exec(file_get_contents(dirname(__DIR__).'/app/pbx_setup/resources/phone_health.sql'));
    $domain = uuid(); $foreign = uuid(); $owner = uuid(); $tenant = uuid(); $issue = uuid();
    $q("insert into v_domains(domain_uuid,domain_name,domain_enabled) values(?,'health-mail.invalid',true),(?,'foreign-health-mail.invalid',true)", [$domain, $foreign]);
    $q("insert into v_users(user_uuid,domain_uuid,username,user_email,user_enabled) values(?,?,'health-owner','current-owner@example.invalid',true)", [$owner, $domain]);
    $q("insert into v_pbx_tenants(tenant_uuid,tenant_name,slug,home_domain_uuid,owner_user_uuid,invite_email,enabled) values(?,'Health Fixture','health-fixture',?,?,'current-owner@example.invalid',true)", [$tenant, $domain, $owner]);
    $q('insert into v_pbx_phone_health_settings(domain_uuid) values(?)', [$domain]);
    $q("insert into v_pbx_phone_health_issues(issue_uuid,domain_uuid,issue_key,kind,severity,summary) values(?,?,'office:fixture','office_blocked','danger','Fictional office block')", [$issue, $domain]);
    $transition = ['domain_uuid'=>$domain,'issue_uuid'=>$issue,'issue_key'=>'office:fixture','state'=>'opened',
                   'recipient'=>'attacker@example.invalid','kind'=>'PRIVATE_AUTH','summary'=>'PRIVATE_IP_PASSWORD_DO_NOT_MAIL'];
    try { pbx_phone_health_mail::queue($db, $transition); $check(false, 'Nontransactional mail accepted.'); }
    catch (RuntimeException $error) { $check(true, 'Transaction required.'); }
    $check(!$queue($transition), 'Default-disabled alerts queued mail.');
    $q('update v_pbx_phone_health_settings set alerts_enabled=true');
    foreach ([['v_users','user_enabled','false'],['v_pbx_tenants','enabled','false'],['v_domains','domain_enabled','false']] as [$table,$column,$value]) {
        $db->exec('update '.$table.' set '.$column.'='.$value);
        $check(!$queue($transition), 'Disabled owner, tenant or domain received mail.');
        $db->exec('update '.$table.' set '.$column.'=true');
    }
    $q("update v_users set user_email='invalid'");
    $check(!$queue($transition), 'Invalid owner email queued mail.');
    $q("update v_users set user_email='current-owner@example.invalid'");
    $duplicateTenant = uuid(); $otherOwner = uuid();
    $q("insert into v_users(user_uuid,domain_uuid,username,user_email,user_enabled) values(?,?,'other-health-owner','other-owner@example.invalid',true)", [$otherOwner,$domain]);
    $q("insert into v_pbx_tenants(tenant_uuid,tenant_name,slug,home_domain_uuid,owner_user_uuid,invite_email,enabled) values(?,'Ambiguous','ambiguous',?,?,'other-owner@example.invalid',true)", [$duplicateTenant,$domain,$otherOwner]);
    $check(!$queue($transition), 'Ambiguous domain ownership queued mail.');
    $q('delete from v_pbx_tenants where tenant_uuid=?', [$duplicateTenant]);
    $other = $transition; $other['domain_uuid'] = $foreign;
    $check(!$queue($other), 'Foreign tenant issue queued mail.');
    $check($queue($transition), 'Actual open transition did not queue.');
    $check(!$queue($transition), 'Repeated observation queued duplicate mail.');
    $row = $q('select * from v_email_queue')->fetch(PDO::FETCH_ASSOC);
    $check($row['email_to'] === 'current-owner@example.invalid' && $row['email_from'] === '', 'Recipient or sender escaped current ownership/global relay.');
    $check(!str_contains($row['email_body'], 'PRIVATE_') && !str_contains($row['email_body'], 'attacker@'), 'Transition data leaked into mail.');
    $openedId = $row['email_queue_uuid'];
    $recovered = $transition; $recovered['state'] = 'resolved';
    $check(!$queue($recovered), 'Stale recovery queued while incident is open.');
    $q('update v_pbx_phone_health_issues set resolved_at=now() where issue_uuid=?', [$issue]);
    $check($queue($recovered), 'Recovered incident did not queue.');
    $check(!$queue($recovered), 'Repeated recovery queued duplicate mail.');
    $recoveredId = $q('select email_queue_uuid from v_email_queue where email_queue_uuid<>?', [$openedId])->fetchColumn();
    // Dispatch both real queue messages only through the fixture's loopback server.
    foreach ([$openedId, $recoveredId] as $id) {
        $finish($start(['--deliver', $schema, $id]));
        $check($q('select email_status from v_email_queue where email_queue_uuid=?', [$id])->fetchColumn() === 'sent', 'Actual global queue delivery failed.');
    }
    $q('update v_pbx_phone_health_issues set resolved_at=null,notified_at=null,resolved_notified_at=null where issue_uuid=?', [$issue]);
    $a = $start(['--enqueue', $schema, json_encode($transition)]);
    $b = $start(['--enqueue', $schema, json_encode($transition)]);
    $outcomes = [$finish($a), $finish($b)]; sort($outcomes);
    $check($outcomes === ['duplicate','queued'], 'Concurrent observers did not deduplicate.');
    $check((int)$q('select count(*) from v_email_queue')->fetchColumn() === 3, 'Concurrent observers added more than one email.');
    $q('update v_pbx_phone_health_issues set notified_at=null where issue_uuid=?', [$issue]);
    $before = (int)$q('select count(*) from v_email_queue')->fetchColumn();
    $db->beginTransaction(); $check(pbx_phone_health_mail::queue($db, $transition), 'Rollback fixture did not enqueue.'); $db->rollBack();
    $check((int)$q('select count(*) from v_email_queue')->fetchColumn() === $before
        && $q('select notified_at from v_pbx_phone_health_issues where issue_uuid=?', [$issue])->fetchColumn() === null,
        'Outbox and notification marker did not roll back together.');
    echo 'PASS: '.$checks." isolated PostgreSQL health-mail controls, two actual global loopback deliveries, concurrent deduplication\n";
} finally {
    if ($db->inTransaction()) $db->rollBack();
    $db->exec('set search_path to public');
    $db->exec('drop schema if exists '.$schema.' cascade');
}
