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
