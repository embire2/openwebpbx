<?php
/** Session-owned PBX only. Recovery always requires a fresh token and explicit confirmation. */
require_once dirname(__DIR__,2).'/resources/require.php';
require_once PROJECT_ROOT.'/resources/check_auth.php';
if(!in_array(PHP_OS_FAMILY,['Linux','Windows'],true)){http_response_code(501);header('Content-Type: application/json');header('Cache-Control: no-store');echo json_encode(['error'=>'Phone Health requires a supported OpenWeb PBX server.']);exit;}
header('Content-Type: application/json');header('Cache-Control: no-store');header('Referrer-Policy: no-referrer');header('X-Content-Type-Options: nosniff');
$method=$_SERVER['REQUEST_METHOD']??'GET';
if(!in_array($method,['GET','POST'],true)){http_response_code(405);header('Allow: GET, POST');echo json_encode(['error'=>'Use GET or POST.']);exit;}
if(!(new pbx_setup)->canManage()||!(new pbx_tenants)->canDomain((string)($_SESSION['domain_uuid']??''))){http_response_code(403);echo json_encode(['error'=>'Administrator access required.']);exit;}
try{
 $health=new pbx_phone_health;
 if($method==='POST'){
  if(!(new token)->validate('/app/pbx_phone_health/api.php')){http_response_code(403);throw new InvalidArgumentException('Your form expired. Refresh the page.');}
  if(($_POST['action']??null)==='recover'){
   if(!is_string($_POST['block_uuid']??null)||!is_string($_POST['revision']??null))throw new InvalidArgumentException('Choose an office block from this page.');
   $reply=$health->recover($_POST['block_uuid'],$_POST['revision'],($_POST['confirmed']??null)==='1');
  }elseif(($_POST['action']??null)==='alerts'&&in_array($_POST['enabled']??null,['0','1'],true)){
   $health->saveAlertSettings($_POST['enabled']==='1');$reply=['message'=>'Alert settings saved.'];
  }else throw new InvalidArgumentException('Choose an action from this page.');
 }else{
  $settings=$health->alertSettings();if(session_status()===PHP_SESSION_ACTIVE)session_write_close();
  $reply=$health->snapshot();$reply['domain_uuid']=$_SESSION['domain_uuid'];$reply['alert_settings']=$settings;
 }
 echo json_encode($reply,JSON_THROW_ON_ERROR);
}catch(InvalidArgumentException $error){if(http_response_code()<400)http_response_code(400);echo json_encode(['error'=>$error->getMessage()]);}
catch(RuntimeException $error){if(http_response_code()<400)http_response_code(409);echo json_encode(['error'=>$error instanceof PDOException?'Phone health could not be checked. Try again shortly.':$error->getMessage()]);}
catch(Throwable){http_response_code(503);echo json_encode(['error'=>'Phone health is unavailable. Refresh and try again.']);}
