<?php
/** Read-only, current-session phone status; caller parameters cannot select another PBX. */
require_once dirname(__DIR__,2).'/resources/require.php';
require_once PROJECT_ROOT.'/resources/check_auth.php';
header('Content-Type: application/json');header('Cache-Control: no-store');header('X-Content-Type-Options: nosniff');header('Referrer-Policy: no-referrer');
if(($_SERVER['REQUEST_METHOD']??'GET')!=='GET'){http_response_code(405);header('Allow: GET');echo json_encode(['error'=>'Use GET.']);exit;}
try{$presence=new pbx_user_presence;if(session_status()===PHP_SESSION_ACTIVE)session_write_close();echo json_encode($presence->snapshot(),JSON_THROW_ON_ERROR);}
catch(Throwable){http_response_code(403);echo json_encode(['error'=>'Phone status is unavailable. Refresh and sign in again.']);}
