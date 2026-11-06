<?php
/** Executed only by an nginx internal auth_request with its request body disabled. */
if(($_SERVER['OPENWEB_UPLOAD_GATE']??null)!=='1'){http_response_code(404);exit;}
$no_session=str_starts_with((string)($_SERVER['OPENWEB_UPLOAD_URI']??''),'/api/v2/');
if($no_session)$_SESSION=[];
ini_set('display_errors','0');ob_start(static fn(string $output): string=>'');
header('Cache-Control: no-store');header('Referrer-Policy: no-referrer');
try {
    require_once dirname(__DIR__,2).'/resources/require.php';
    if($no_session){$_SESSION=[];permissions::reset();}
    (new pbx_upload_gate)->authorize($_SERVER);
    http_response_code(204);
}catch(pbx_upload_gate_denied $error){http_response_code($error->status);}
catch(Throwable){http_response_code(403);}
if(session_status()===PHP_SESSION_ACTIVE)session_write_close();
exit;
