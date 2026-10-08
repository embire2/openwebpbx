<?php
/** Invoked by smtp_transport_integration.py against a local SMTP fixture, never a real relay. */
if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }
require dirname(__DIR__).'/resources/require.php';
// A separate CLI process exercises the real delivery job repeatedly without redefining
// its native helper functions, while sharing only this test's private schema.
if (($argv[1] ?? '') === '--queue-job') {
    $fixtureSchema=$argv[2] ?? ''; $queueId=$argv[3] ?? '';
    if (!preg_match('/^openweb_mail_test_[a-f0-9]{12}$/D', $fixtureSchema) || !is_uuid($queueId)) {
        throw new RuntimeException('A private SMTP fixture schema and queue identifier are required.');
    }
    $database->db->exec('set search_path to '.$fixtureSchema.',public');
    $job=dirname(__DIR__).'/app/email_queue/resources/jobs/email_send.php';
    $argv=[$job,'email_queue_uuid='.$queueId.'&hostname=localhost'];
    include $job;
    exit;
}
$port = filter_var($argv[1] ?? '', FILTER_VALIDATE_INT, ['options'=>['min_range'=>1024,'max_range'=>65535]]);
if (!$port) throw new RuntimeException('A local fixture port is required.');
$pdo = $database->db;
$pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
$schema = 'openweb_mail_test_'.bin2hex(random_bytes(6));
$assert = function(bool $ok, string $message) { if (!$ok) throw new RuntimeException($message); };
$throws = function(callable $fn, string $message) use ($assert) { try { $fn(); } catch (Throwable $e) { return; } $assert(false, $message); };
class forbidden_mail_settings extends outgoing_mail { public function canManage(): bool { return false; } }
$runQueue = function(string $queueId) use ($schema, $assert) {
    $process=proc_open([PHP_BINARY, __FILE__, '--queue-job', $schema, $queueId],
        [0=>['pipe','r'],1=>['pipe','w'],2=>['pipe','w']], $pipes, dirname(__DIR__));
    $assert(is_resource($process), 'SMTP fixture queue process did not start');
    fclose($pipes[0]);
    $output=stream_get_contents($pipes[1]); fclose($pipes[1]);
    $errors=stream_get_contents($pipes[2]); fclose($pipes[2]);
    $assert(proc_close($process) === 0 && $errors === '', 'SMTP fixture queue process failed');
    return $output;
};
try {
    $pdo->exec('create schema '.$schema);
    $pdo->exec('set search_path to '.$schema.',public');
    foreach (['v_default_settings','v_domain_settings','v_email_queue','v_email_queue_attachments','v_voicemails','v_voicemail_messages'] as $table) {
        $pdo->exec('create table '.$table.' (like public.'.$table.' including all)');
    }
    $pdo->exec('insert into v_default_settings select * from public.v_default_settings');
    $pdo->exec("update v_default_settings set default_setting_value='false' where default_setting_category='email' and default_setting_subcategory='smtp_global'");
    $settingsApp = new outgoing_mail($pdo);
    $throws(fn()=>$settingsApp->transport(), 'Unconfigured global mail allowed another transport');
    $assert(!$settingsApp->view()['is_configured'], 'Unconfigured global relay appeared ready in the editor');
    $config = ['smtp_host'=>'127.0.0.1','smtp_port'=>(string)$port,'smtp_secure'=>'none','authentication'=>'ip',
        'smtp_from'=>'pbx@example.invalid','smtp_from_name'=>'SMTP Fixture','smtp_username'=>'ignored','smtp_password'=>'ignored'];
    $forbidden = new forbidden_mail_settings($pdo);
    $throws(fn()=>$forbidden->save($config), 'Unauthorized SMTP configuration accepted');
    $throws(fn()=>$forbidden->view(), 'Unauthorized SMTP configuration visible');
    $bad = $config; $bad['smtp_port']='0';
    $throws(fn()=>$settingsApp->save($bad), 'Invalid SMTP port accepted');
    $bad = $config; $bad['smtp_host']='smtp://127.0.0.1';
    $throws(fn()=>$settingsApp->save($bad), 'SMTP URL accepted instead of a hostname');
    $bad = $config; $bad['smtp_ip_whitelisted']='unknown';
    $throws(fn()=>$settingsApp->save($bad), 'Invalid whitelist checkbox accepted');
    $bad = $config; $bad['smtp_ip_whitelisted']=['1'];
    $throws(fn()=>$settingsApp->save($bad), 'Invalid whitelist checkbox array accepted');
    $domain = uuid();
    $stmt = $pdo->prepare("insert into v_domain_settings(domain_setting_uuid,domain_uuid,domain_setting_category,domain_setting_subcategory,domain_setting_name,domain_setting_value,domain_setting_enabled)
        values(:id,:domain,'email',:key,'text',:value,true)");
    foreach (['smtp_host'=>'127.0.0.1','smtp_port'=>(string)$port,'smtp_secure'=>'none','smtp_auth'=>'false',
        'smtp_from'=>'tenant@example.invalid','smtp_username'=>'foreign-user','smtp_password'=>'foreign-secret'] as $key=>$value) {
        $stmt->execute(['id'=>uuid(),'domain'=>$domain,'key'=>$key,'value'=>$value]);
    }
    $tenantSettings = new settings(['database'=>$database,'domain_uuid'=>$domain,'allow_caching'=>false]);
    // A working tenant relay must never receive mail while global configuration is absent.
    $blocked = new email(['database'=>$database,'domain_uuid'=>$domain,'settings'=>$tenantSettings]);
    $blocked->method='direct'; $blocked->recipients='recipient@example.invalid';
    $blocked->subject='Must not escape through a tenant relay'; $blocked->body='Captured only if a regression leaks mail.';
    $assert($blocked->send() === false && $blocked->delivery_deferred, 'Unconfigured global mail used the tenant relay');
    $assert(str_contains($blocked->error, 'Configure global outgoing mail'), 'Missing global relay did not show a clear configuration error');
    $_SESSION['domain_uuid']=$domain;
    $waiting = new email(['database'=>$database,'domain_uuid'=>$domain,'settings'=>$tenantSettings]);
    $waiting->method='queue'; $waiting->recipients='recipient@example.invalid';
    $waiting->subject='Queued local SMTP fixture'; $waiting->body='This queued message must wait for the instance relay.';
    $waiting->attachments=[['name'=>'fixture.txt','type'=>'txt','base64'=>base64_encode('Private fixture attachment')]];
    $assert($waiting->send() === 'Added to queue', 'Unconfigured global mail discarded a queued message');
    $queueId=$pdo->query('select email_queue_uuid from v_email_queue')->fetchColumn();
    $assert(is_uuid($queueId), 'SMTP fixture queue identifier missing');
    $pdo->prepare('update v_email_queue set email_retry_count=2 where email_queue_uuid=:id')->execute(['id'=>$queueId]);
    $queueState=$pdo->prepare('select email_status,email_retry_count,email_response,email_body from v_email_queue where email_queue_uuid=:id');
    for ($attempt=0;$attempt<2;$attempt++) {
        $runQueue($queueId);
        $queueState->execute(['id'=>$queueId]); $row=$queueState->fetch(PDO::FETCH_ASSOC);
        $assert($row['email_status'] === 'waiting' && (int)$row['email_retry_count'] === 2, 'Unconfigured relay consumed a queue retry or lost waiting mail');
        $assert(str_contains($row['email_response'], 'Configure global outgoing mail'), 'Deferred queue status did not identify the missing global relay');
        $assert($row['email_body'] === $waiting->body, 'Deferred delivery changed the queued message');
        $assert((int)$pdo->query('select count(*) from v_email_queue_attachments')->fetchColumn() === 1, 'Deferred delivery removed a queued attachment');
    }
    // A manually incomplete saved relay must also fail closed rather than use tenant defaults.
    $pdo->exec("update v_default_settings set default_setting_value='true' where default_setting_category='email' and default_setting_subcategory='smtp_global'");
    $pdo->exec("update v_default_settings set default_setting_value='' where default_setting_category='email' and default_setting_subcategory='smtp_host'");
    $assert($blocked->send() === false && $blocked->delivery_deferred, 'Incomplete global relay fell back to tenant SMTP');
    $settingsApp->save($config);
    $smtp = $settingsApp->transport();
    $assert($settingsApp->view()['is_configured'], 'A saved complete global relay did not appear ready in the editor');
    $assert($smtp['auth'] === false && $smtp['username'] === '' && $smtp['password'] === '', 'IP authentication retained credentials');
    $send = function() use ($database, $domain, $tenantSettings, $assert) {
        $email = new email(['database'=>$database,'domain_uuid'=>$domain,'settings'=>$tenantSettings]);
        $email->method='direct'; $email->debug_level=3;
        $email->recipients='recipient@example.invalid'; $email->subject='Local SMTP fixture';
        $email->body='This message is captured locally by the integration fixture.';
        $assert((bool)$email->send(), 'SMTP fixture delivery failed: '.($email->error ?? ''));
        $assert($email->response === '', 'Global SMTP debug traffic appeared in the delivery response');
    };
    $assert($settingsApp->checkConnection(), 'IP-authenticated connection failed');
    $send();
    $config['authentication']='password'; $config['smtp_username']='fixture-user'; $config['smtp_password']='fixture-password';
    $settingsApp->save($config);
    $view = $settingsApp->view();
    $assert($view['has_password'] && !array_key_exists('smtp_password', $view), 'SMTP password exposed in the editor');
    $config['smtp_password']=''; $settingsApp->save($config);
    $assert($settingsApp->transport()['password'] === 'fixture-password', 'Blank password did not preserve the saved credential');
    $changed = $config; $changed['smtp_username']='another-user';
    $throws(fn()=>$settingsApp->save($changed), 'A new username reused the previous SMTP password');
    $assert($settingsApp->checkConnection(), 'Credential-authenticated connection failed');
    $send();
    // Explicit unchecked and checked checkbox states override the old API field.
    $config['authentication']='ip'; $config['smtp_ip_whitelisted']='0';
    $settingsApp->save($config);
    $assert($settingsApp->transport()['auth'] === true, 'Unchecked whitelist checkbox disabled authentication');
    $config['authentication']='password'; $config['smtp_ip_whitelisted']='1';
    $settingsApp->save($config);
    $stmt=$pdo->query("select default_setting_value from v_default_settings where default_setting_category='email' and default_setting_subcategory in ('smtp_username','smtp_password')");
    foreach ($stmt->fetchAll(PDO::FETCH_COLUMN) as $value) $assert($value === '', 'Switching to IP authentication did not clear stored credentials');
    $assert($settingsApp->checkConnection(), 'Whitelist checkbox connection failed');
    // The original waiting message is now delivered through the saved global relay.
    $runQueue($queueId);
    $stmt=$pdo->prepare('select email_status from v_email_queue where email_queue_uuid=:id');
    $stmt->execute(['id'=>$queueId]);
    $assert($stmt->fetchColumn() === 'sent', 'Native queue delivery did not use the global whitelist relay');
    echo "PASS: permissions/validation, fail-closed global mail, waiting queue/retry preservation and resumed delivery, legacy/checkbox authentication, masked/retained/cleared passwords and private SMTP responses\n";
} finally {
    if ($pdo->inTransaction()) $pdo->rollBack();
    $pdo->exec('set search_path to public');
    $pdo->exec('drop schema if exists '.$schema.' cascade');
}
