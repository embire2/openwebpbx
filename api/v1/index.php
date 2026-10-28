<?php
/** Tenant API front controller. Configure the /api/v1/ prefix to reach this file. */
$no_session=true;
$_SESSION=[];
ini_set('display_errors','0');
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');
header('Referrer-Policy: no-referrer');
header('X-Content-Type-Options: nosniff');
$requestId=bin2hex(random_bytes(16));
header('X-Request-ID: '.$requestId);
function tenant_api_reply(int $status,array $body,array $headers=[]): never {
    http_response_code($status);foreach($headers as $name=>$value)header($name.': '.$value);
    if($status!==204)echo json_encode($body,JSON_THROW_ON_ERROR|JSON_UNESCAPED_SLASHES);exit;
}
function tenant_api_error(int $status,string $code,string $message,array $headers=[]): never {
    global $requestId;tenant_api_reply($status,['error'=>['code'=>$code,'message'=>$message],'request_id'=>$requestId],$headers);
}
try {
    if(!in_array($_SERVER['HTTPS']??'',['on','1'],true))tenant_api_error(403,'https_required','Use HTTPS for the tenant API.');
    if(isset($_SERVER['HTTP_ORIGIN']))tenant_api_error(403,'origin_not_allowed','Use the tenant API from your server.');
    require_once dirname(__DIR__,2).'/resources/classes/config.php';
    $canonical=(string)config::load()->get('openweb.public_host','call.openweb.co.za');
    $host=strtolower((string)($_SERVER['HTTP_HOST']??''));if(str_ends_with($host,':443'))$host=substr($host,0,-4);
    if($host!==$canonical)tenant_api_error(403,'host_not_allowed','Use the installation API hostname.');
    require dirname(__DIR__,2).'/resources/require.php';
    // No endpoint reads PHP-session cookies, query-string keys or Basic auth.
    $_SESSION=[];
    $uri=parse_url($_SERVER['REQUEST_URI']??'',PHP_URL_PATH);
    if(!is_string($uri)||str_contains($uri,'%')||str_contains($uri,'//')||str_contains($uri,'..'))tenant_api_error(400,'invalid_path','Use an exact API path.');
    if(in_array($uri,['/api/v1/index.php','/api/v1/'],true)&&isset($_GET['route'])){
        $route=$_GET['route'];if(!is_string($route)||!preg_match('~^/[A-Za-z0-9/_-]{1,200}$~D',$route))tenant_api_error(400,'invalid_path','Use an exact API path.');
    }else{
        if(!str_starts_with($uri,'/api/v1/'))tenant_api_error(404,'not_found','This API endpoint is unavailable.');$route=substr($uri,7);
    }
    $method=$_SERVER['REQUEST_METHOD']??'';$input=[];
    if(in_array($method,['POST','DELETE'],true)){
        if($method==='POST'||(int)($_SERVER['CONTENT_LENGTH']??0)>0){
            if(!preg_match('~^application/json(?:\s*;\s*charset=utf-8)?$~iD',$_SERVER['CONTENT_TYPE']??''))tenant_api_error(415,'json_required','Send application/json.');
            if((int)($_SERVER['CONTENT_LENGTH']??0)>32768)tenant_api_error(413,'body_too_large','Keep requests below 32 KiB.');
            $raw=file_get_contents('php://input',false,null,0,32769);if(!is_string($raw)||strlen($raw)>32768)tenant_api_error(413,'body_too_large','Keep requests below 32 KiB.');
            $decoded=json_decode($raw,false,16,JSON_THROW_ON_ERROR);if(!is_object($decoded))tenant_api_error(400,'invalid_request','Send a JSON object.');$input=json_decode($raw,true,16,JSON_THROW_ON_ERROR);
        }
    }elseif($method==='GET'){
        $input=$_GET;unset($input['route']);if(array_diff(array_keys($input),$route==='/subdomains/availability'?['label']:[]))tenant_api_error(400,'invalid_request','Unsupported query parameters.');
    }
    $headers=['authorization'=>(string)($_SERVER['HTTP_AUTHORIZATION']??''),'idempotency-key'=>(string)($_SERVER['HTTP_IDEMPOTENCY_KEY']??'')];
    [$status,$body,$extra]=(new pbx_tenant_api)->handle($method,$route,$input,$headers,(string)($_SERVER['REMOTE_ADDR']??''));
    tenant_api_reply($status,$body,$extra);
}catch(pbx_tenant_api_error $ex){tenant_api_error($ex->status,$ex->apiCode,$ex->getMessage(),$ex->headers);}
catch(JsonException){tenant_api_error(400,'invalid_json','Send a valid JSON object.');}
catch(InvalidArgumentException){tenant_api_error(400,'invalid_request','Check the supplied details.');}
catch(OutOfBoundsException){tenant_api_error(404,'not_found','This item is unavailable.');}
catch(DomainException){tenant_api_error(409,'conflict','The requested name or operation is unavailable.');}
catch(PDOException $ex){
    error_log('OpenWeb PBX tenant API database request '.$requestId.' failed (SQLSTATE '.$ex->getCode().').');
    if($ex->getCode()==='23505')tenant_api_error(409,'conflict','The requested name or operation is unavailable.');
    tenant_api_error(503,'temporarily_unavailable','The request could not be completed. Try again later.');
}catch(Throwable $ex){error_log('OpenWeb PBX tenant API request '.$requestId.' failed ('.get_class($ex).').');tenant_api_error(503,'temporarily_unavailable','The request could not be completed. Try again later.');}
