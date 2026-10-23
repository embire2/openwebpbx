<?php
/** Read-only native readiness for Windows installation and upgrade. */
if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }
set_exception_handler(static function (Throwable $error): void { exit(1); });
if (PHP_OS_FAMILY !== 'Windows') { exit(2); }
require ($argv[1] ?? '').'/resources/require.php';
foreach (['mod_sofia','mod_lua','mod_bcg729'] as $module) {
    if (trim(event_socket::api('module_exists '.$module)) !== 'true') { exit(1); }
}
$profile = event_socket::api('sofia status profile internal');
foreach (['SIP-IP','RTP-IP'] as $field) {
    if (!preg_match('/^'.preg_quote($field,'/').'\s+([^\s]+)\s*$/m',$profile,$match) || !filter_var($match[1], FILTER_VALIDATE_IP)) { exit(1); }
}

require_once __DIR__.'/windows-log.php';
$configuration=config::load();$db=$database->db;$db->beginTransaction();
try{
    $db->exec('set transaction read only');$db->exec("set local statement_timeout='5s'");
    $installed=trim((string)file_get_contents(($argv[1]??'').'/VERSION'));
    openweb_windows_log::check($db,(string)$configuration->get('switch.conf.dir',''),$configuration->get('switch.log.dir',null),event_socket::api(...),version_compare($installed,'1.0.20','>='));
    $db->rollBack();
}catch(Throwable$e){if($db->inTransaction())$db->rollBack();throw$e;}
