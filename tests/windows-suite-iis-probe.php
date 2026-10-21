<?php
/* Ephemeral QA fixture. The runner replaces only the exact nonce marker. */
$nonce='__OPENWEB_QA_NONCE__';
$expires=__OPENWEB_QA_EXPIRES__;
$openwebQaCli=PHP_SAPI==='cli';
if(PHP_OS_FAMILY!=='Windows'||getenv('GITHUB_ACTIONS')!=='true'&&$openwebQaCli){http_response_code(404);exit;}
if($openwebQaCli){if(!hash_equals($nonce,(string)($argv[1]??'')))exit(2);}
elseif(time()>$expires||!in_array($_SERVER['REMOTE_ADDR']??'', ['127.0.0.1','::1'],true)||($_SERVER['HTTP_HOST']??'')!=='windowsqa.example.invalid:8443'||($_SERVER['REQUEST_METHOD']??'')!=='GET'||!hash_equals($nonce,(string)($_GET['nonce']??''))){http_response_code(404);exit;}
$loaded=realpath(php_ini_loaded_file());$expected=realpath('C:/OpenWebPBX/php/php.ini');
$openwebQaResult=['schema'=>1,'sapi'=>$openwebQaCli?'cli':(PHP_SAPI==='cgi-fcgi'?'cgi-fcgi':'other'),'ini_matches'=>$loaded!==false&&$expected!==false&&strtolower($loaded)===strtolower($expected),'pdo_pgsql'=>extension_loaded('pdo_pgsql'),'config_readable'=>is_readable('C:/ProgramData/fusionpbx/config.conf'),'application_status'=>0,'error_class'=>'none','source_basename'=>'none','source_line'=>0];
ob_start();
register_shutdown_function(static function()use(&$openwebQaResult,$openwebQaCli):void{
 $status=http_response_code();$openwebQaResult['application_status']=is_int($status)&&$status>=100&&$status<=599?$status:0;
 $error=error_get_last();
 if($error&&in_array($error['type'],[E_ERROR,E_PARSE,E_CORE_ERROR,E_COMPILE_ERROR,E_USER_ERROR,E_RECOVERABLE_ERROR],true)){
  $openwebQaResult['error_class']=$error['type']===E_PARSE?'ParseError':'fatal_error';
  if(preg_match('/\bUncaught (PDOException|TypeError|ValueError|ParseError|RuntimeException|InvalidArgumentException|ErrorException|Exception|Error)\b/',$error['message'],$match))$openwebQaResult['error_class']=$match[1];
  $name=basename(str_replace('\\','/',$error['file']));$allowed=['login.php','require.php','config.php','auto_loader.php','settings.php','cache.php','database.php','pbx_tenant_domains.php','permissions.php','functions.php','check_auth.php','token.php','auth.php','index.php'];
  $openwebQaResult['source_basename']=in_array($name,$allowed,true)?$name:'external_component';$openwebQaResult['source_line']=max(0,min(999999,(int)$error['line']));
 }
 for($i=0;$i<16&&ob_get_level()>0;$i++){if(!@ob_end_clean())break;}
 if(!$openwebQaCli){header_remove('Location');header('Content-Type: application/json');http_response_code(200);}
 echo json_encode($openwebQaResult,JSON_THROW_ON_ERROR);
});
if(!$openwebQaCli){
 // After the loopback/host/nonce fence, reproduce the sign-in request identity
 // inside this one diagnostic request; no server rule or auth check is changed.
 $_GET=[];$_SERVER['QUERY_STRING']='';$_SERVER['REQUEST_URI']='/login.php';$_SERVER['SCRIPT_NAME']='/login.php';$_SERVER['PHP_SELF']='/login.php';$_SERVER['SCRIPT_FILENAME']='C:/OpenWebPBX/web/login.php';
 require 'C:/OpenWebPBX/web/login.php';
}
