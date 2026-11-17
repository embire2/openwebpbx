<?php
/** Internal body-free server admission; never consumes a backup or queues work. */
if(($_SERVER['OPENWEB_UPLOAD_GATE']??null)!=='1'){http_response_code(404);exit;}
$api_gate=str_starts_with((string)($_SERVER['OPENWEB_UPLOAD_URI']??''),'/api/v2/');
// Windows' authenticated loopback bridge has already read and closed the exact
// existing session. Suppress automatic session creation/writes in the framework.
$no_session=$api_gate||(PHP_OS_FAMILY==='Windows'&&($_SERVER['OPENWEB_WINDOWS_UPLOAD_GATE']??null)==='1');
if($api_gate)$_SESSION=[];
ini_set('display_errors','0');ob_start(static fn(string $output): string=>'');
header('Cache-Control: no-store');header('Referrer-Policy: no-referrer');
try {
    require_once dirname(__DIR__,2).'/resources/require.php';
    if($api_gate){$_SESSION=[];permissions::reset();}
    (new pbx_upload_gate)->authorize($_SERVER);
    http_response_code(204);
}catch(pbx_upload_gate_denied $error){http_response_code($error->status);}
catch(Throwable){http_response_code(403);}
if(session_status()===PHP_SESSION_ACTIVE)session_write_close();
exit;
