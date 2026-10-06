<?php
/** Invoked by smtp_transport_integration.py against a local SMTP fixture, never a real relay. */
if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }
require dirname(__DIR__).'/resources/require.php';
$port = filter_var($argv[1] ?? '', FILTER_VALIDATE_INT, ['options'=>['min_range'=>1024,'max_range'=>65535]]);
if (!$port) throw new RuntimeException('A local fixture port is required.');
$pdo = $database->db;
$pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
$schema = 'openweb_mail_test_'.bin2hex(random_bytes(6));
$assert = function(bool $ok, string $message) { if (!$ok) throw new RuntimeException($message); };
$throws = function(callable $fn, string $message) use ($assert) { try { $fn(); } catch (Throwable $e) { return; } $assert(false, $message); };
class forbidden_mail_settings extends outgoing_mail { public function canManage(): bool { return false; } }
try {
    $pdo->exec('create schema '.$schema);
    $pdo->exec('set search_path to '.$schema.',public');
    foreach (['v_default_settings','v_domain_settings'] as $table) $pdo->exec('create table '.$table.' (like public.'.$table.' including all)');
    $pdo->exec('insert into v_default_settings select * from public.v_default_settings');
    $pdo->exec("update v_default_settings set default_setting_value='false' where default_setting_category='email' and default_setting_subcategory='smtp_global'");
    $settingsApp = new outgoing_mail($pdo);
    $assert($settingsApp->transport() === null, 'Unconfigured global mail did not preserve the existing transport');
    $config = ['smtp_host'=>'127.0.0.1','smtp_port'=>(string)$port,'smtp_secure'=>'none','authentication'=>'ip',
        'smtp_from'=>'pbx@example.invalid','smtp_from_name'=>'SMTP Fixture','smtp_username'=>'ignored','smtp_password'=>'ignored'];
    $forbidden = new forbidden_mail_settings($pdo);
    $throws(fn()=>$forbidden->save($config), 'Unauthorized SMTP configuration accepted');
    $throws(fn()=>$forbidden->view(), 'Unauthorized SMTP configuration visible');
    $bad = $config; $bad['smtp_port']='0';
    $throws(fn()=>$settingsApp->save($bad), 'Invalid SMTP port accepted');
    $bad = $config; $bad['smtp_host']='smtp://127.0.0.1';
    $throws(fn()=>$settingsApp->save($bad), 'SMTP URL accepted instead of a hostname');
    $settingsApp->save($config);
    $smtp = $settingsApp->transport();
    $assert($smtp['auth'] === false && $smtp['username'] === '' && $smtp['password'] === '', 'IP authentication retained credentials');
    $domain = uuid();
    $stmt = $pdo->prepare("insert into v_domain_settings(domain_setting_uuid,domain_uuid,domain_setting_category,domain_setting_subcategory,domain_setting_name,domain_setting_value,domain_setting_enabled)
        values(:id,:domain,'email',:key,'text',:value,true)");
    foreach (['smtp_host'=>'foreign-relay.invalid','smtp_port'=>'1','smtp_auth'=>'true','smtp_username'=>'foreign-user','smtp_password'=>'foreign-secret'] as $key=>$value) {
        $stmt->execute(['id'=>uuid(),'domain'=>$domain,'key'=>$key,'value'=>$value]);
    }
    $tenantSettings = new settings(['database'=>$database,'domain_uuid'=>$domain,'allow_caching'=>false]);
    $send = function() use ($database, $domain, $tenantSettings, $assert) {
        $email = new email(['database'=>$database,'domain_uuid'=>$domain,'settings'=>$tenantSettings]);
        $email->method='direct'; $email->debug_level=0;
        $email->recipients='recipient@example.invalid'; $email->subject='Local SMTP fixture';
        $email->body='This message is captured locally by the integration fixture.';
        $assert((bool)$email->send(), 'SMTP fixture delivery failed: '.($email->error ?? ''));
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
    $config['authentication']='ip'; $settingsApp->save($config);
    $stmt=$pdo->query("select default_setting_value from v_default_settings where default_setting_category='email' and default_setting_subcategory in ('smtp_username','smtp_password')");
    foreach ($stmt->fetchAll(PDO::FETCH_COLUMN) as $value) $assert($value === '', 'Switching to IP authentication did not clear stored credentials');
    echo "PASS: permissions, validation, global relay precedence, IP and password SMTP connections/delivery, password masking/retention, and credential clearing\n";
} finally {
    if ($pdo->inTransaction()) $pdo->rollBack();
    $pdo->exec('set search_path to public');
    $pdo->exec('drop schema if exists '.$schema.' cascade');
}
