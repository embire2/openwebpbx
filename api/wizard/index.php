<?php
/** Only this enrollment surface permits the public OpenWeb PBX wizard origin. */
$no_session=true;$_SESSION=[];ini_set('display_errors','0');
header('Content-Type: application/json; charset=utf-8');header('Cache-Control: no-store');header('Referrer-Policy: no-referrer');header('X-Content-Type-Options: nosniff');
$wizardRequestId=bin2hex(random_bytes(16));header('X-Request-ID: '.$wizardRequestId);
function wizard_reply(int $status,array $body,array $headers=[]): never {http_response_code($status);foreach($headers as$name=>$value)header($name.': '.$value);if($status!==204)echo json_encode($body,JSON_UNESCAPED_SLASHES|JSON_THROW_ON_ERROR);exit;}
function wizard_error(int $status,string $code,string $message,array $headers=[]): never {global$wizardRequestId;wizard_reply($status,['error'=>['code'=>$code,'message'=>$message],'request_id'=>$wizardRequestId],$headers);}
try{
 if(!in_array($_SERVER['HTTPS']??'',['on','1'],true))wizard_error(403,'https_required','Use the secure setup address.');
 $origin=$_SERVER['HTTP_ORIGIN']??null;
 if($origin!==null){
  if($origin!=='https://openwebpbx.com')wizard_error(403,'origin_not_allowed','Use the official OpenWeb PBX setup wizard.');
  header('Access-Control-Allow-Origin: https://openwebpbx.com');header('Vary: Origin');
  header('Access-Control-Allow-Methods: GET, POST, OPTIONS');header('Access-Control-Allow-Headers: Authorization, Content-Type');header('Access-Control-Max-Age: 300');
 }
 require_once dirname(__DIR__,2).'/resources/classes/config.php';
 $canonical=(string)config::load()->get('openweb.public_host','call.openweb.co.za');$host=strtolower((string)($_SERVER['HTTP_HOST']??''));if(str_ends_with($host,':443'))$host=substr($host,0,-4);
 if($host!==$canonical)wizard_error(403,'host_not_allowed','Use the official OpenWeb PBX setup address.');
 $uri=parse_url($_SERVER['REQUEST_URI']??'',PHP_URL_PATH);
 if(!is_string($uri)||!str_starts_with($uri,'/api/v1/wizard/')||str_contains($uri,'%')||str_contains($uri,'..')||str_contains($uri,'//'))wizard_error(404,'not_found','This setup step is unavailable.');
 $route=substr($uri,14);$method=$_SERVER['REQUEST_METHOD']??'';
 $posts=['/account/register','/account/verify','/account/login','/account/email/request','/account/email/verify','/devices','/devices/lookup','/claim','/devices/poll','/devices/bootstrap','/devices/challenge','/devices/authorize','/devices/complete'];
 $get=$route==='/health'||preg_match('~^/sessions/[a-f0-9-]{36}$~D',$route);
 if($method==='OPTIONS'){
  if($origin===null||(!in_array($route,$posts,true)&&!$get))wizard_error(404,'not_found','This setup step is unavailable.');
  $requested=strtoupper((string)($_SERVER['HTTP_ACCESS_CONTROL_REQUEST_METHOD']??''));if(!in_array($requested,$get?['GET']:['POST'],true))wizard_error(405,'method_not_allowed','Use the supported setup method.');wizard_reply(204,[]);
 }
 if(($get&&$method!=='GET')||(!$get&&(!in_array($route,$posts,true)||$method!=='POST')))wizard_error($get||in_array($route,$posts,true)?405:404,'not_found','This setup step is unavailable.');
 if($_GET!==[])wizard_error(400,'invalid_request','Send setup details in the request body.');
 $input=[];
 if($method==='POST'){
  if(!preg_match('~^application/json(?:\s*;\s*charset=utf-8)?$~iD',$_SERVER['CONTENT_TYPE']??''))wizard_error(415,'json_required','Send application/json.');
  if((int)($_SERVER['CONTENT_LENGTH']??0)>16384)wizard_error(413,'body_too_large','Keep setup requests below 16 KiB.');
  $raw=file_get_contents('php://input',false,null,0,16385);if(!is_string($raw)||strlen($raw)>16384)wizard_error(413,'body_too_large','Keep setup requests below 16 KiB.');
  $object=json_decode($raw,false,16,JSON_THROW_ON_ERROR);if(!is_object($object))wizard_error(400,'invalid_request','Send a JSON object.');$input=json_decode($raw,true,16,JSON_THROW_ON_ERROR);
 }
 require dirname(__DIR__,2).'/resources/require.php';$_SESSION=[];
 $api=new pbx_tenant_api;$api->handle('GET','/health',[],[],(string)($_SERVER['REMOTE_ADDR']??''));
 if($route==='/health')wizard_reply(200,['wizard'=>'OpenWeb PBX server setup','version'=>1,'providers'=>['webhotel','debian'],'verification_uri'=>'https://openwebpbx.com/wizard']);
 $authorization=(string)($_SERVER['HTTP_AUTHORIZATION']??'');$ip=(string)($_SERVER['REMOTE_ADDR']??'');
 $facade=['/account/register'=>'/registrations','/account/verify'=>'/registrations/verify','/account/login'=>'/auth/token','/account/email/request'=>'/onboarding/email/request','/account/email/verify'=>'/onboarding/email/verify'];
 if(isset($facade[$route])){[$status,$body,$extra]=$api->handle('POST',$facade[$route],$input,['authorization'=>$authorization],$ip);wizard_reply($status,$body,$extra);}
 $wizard=new pbx_wizard_api($database->db,$api);
 if($route==='/devices')wizard_reply(201,$wizard->start($input,$ip));
 if($route==='/devices/lookup')wizard_reply(200,$wizard->lookup($input,$ip));
 if($route==='/devices/poll')wizard_reply(200,$wizard->poll($input,$ip));
 if($route==='/devices/bootstrap')wizard_reply(200,$wizard->bootstrap($input));
 if($route==='/devices/challenge')wizard_reply(201,$wizard->challenge($input));
 if($route==='/devices/authorize')wizard_reply(201,$wizard->authorize($input));
 if($route==='/devices/complete')wizard_reply(200,$wizard->complete($input));
 $account=$api->authenticate($authorization);$api->rate('wizard:owner:'.$account['tenant_uuid'],120,60);
 if($route==='/claim')wizard_reply(202,$wizard->claim($account,$input));
 if(preg_match('~^/sessions/([a-f0-9-]{36})$~D',$route,$m))wizard_reply(200,$wizard->status($account,$m[1]));
 wizard_error(404,'not_found','This setup step is unavailable.');
}catch(pbx_tenant_api_error$e){wizard_error($e->status,$e->apiCode,$e->getMessage(),$e->headers);}
catch(JsonException|InvalidArgumentException){wizard_error(400,'invalid_request','Check the supplied setup details.');}
catch(PDOException$e){error_log('OpenWeb PBX wizard database request '.$wizardRequestId.' failed (SQLSTATE '.$e->getCode().').');wizard_error($e->getCode()==='23505'?409:503,$e->getCode()==='23505'?'conflict':'temporarily_unavailable','This setup step could not be completed. Try again shortly.');}
catch(Throwable$e){error_log('OpenWeb PBX wizard request '.$wizardRequestId.' failed ('.get_class($e).').');wizard_error(503,'temporarily_unavailable','This setup step could not be completed. Try again shortly.');}
