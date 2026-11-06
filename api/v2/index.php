<?php
/** Stateless PBX/reseller administration API. */
$no_session=true;$_SESSION=[];ini_set('display_errors','0');
header('Content-Type: application/json; charset=utf-8');header('Cache-Control: no-store');header('Referrer-Policy: no-referrer');header('X-Content-Type-Options: nosniff');
$requestId=bin2hex(random_bytes(16));header('X-Request-ID: '.$requestId);
function reseller_api_reply(int $status,mixed $data): never {http_response_code($status);echo json_encode($data,JSON_THROW_ON_ERROR|JSON_UNESCAPED_SLASHES);exit;}
function reseller_api_error(int $status,string $code,string $message): never {global $requestId;reseller_api_reply($status,['error'=>['code'=>$code,'message'=>$message],'request_id'=>$requestId]);}
try {
    if(!in_array($_SERVER['HTTPS']??'',['on','1'],true))reseller_api_error(403,'https_required','Use HTTPS for the PBX API.');
    if(isset($_SERVER['HTTP_ORIGIN']))reseller_api_error(403,'origin_not_allowed','Use this administration API from your server.');
    require_once dirname(__DIR__,2).'/resources/classes/config.php';
    $canonical=(string)config::load()->get('openweb.public_host','call.openweb.co.za');
    $host=strtolower((string)($_SERVER['HTTP_HOST']??''));if(str_ends_with($host,':443'))$host=substr($host,0,-4);
    if($host!==$canonical)reseller_api_error(403,'host_not_allowed','Use the installation API hostname.');
    require dirname(__DIR__,2).'/resources/require.php';$_SESSION=[];permissions::reset();
    $path=parse_url($_SERVER['REQUEST_URI']??'',PHP_URL_PATH);
    if(!is_string($path)||str_contains($path,'%')||str_contains($path,'//')||str_contains($path,'..'))reseller_api_error(400,'invalid_path','Use an exact API path.');
    if(in_array($path,['/api/v2/','/api/v2/index.php'],true)&&isset($_GET['route'])){$route=$_GET['route'];if(!is_string($route))reseller_api_error(400,'invalid_path','Use an exact API path.');}
    elseif(str_starts_with($path,'/api/v2/'))$route=substr($path,7);else reseller_api_error(404,'not_found','This API endpoint is unavailable.');
    $method=$_SERVER['REQUEST_METHOD']??'';
    if(!in_array($method,['GET','POST','DELETE'],true)){header('Allow: GET, POST, DELETE');reseller_api_error(405,'method_not_allowed','Use GET, POST or DELETE.');}
    $input=$_GET;unset($input['route']);
    if($method!=='GET') {
        if($input)reseller_api_error(400,'invalid_request','Send request fields in the JSON body.');
        $binary=$method==='POST'&&(preg_match('~^/tenants/[a-f0-9-]+/backups/import$~D',$route)||$route==='/instance/backups/import');
        $multipart=$method==='POST'&&(preg_match('~^/pbx/[a-f0-9-]+/actions/(audio-upload|migration-inspect)$~D',$route)||$route==='/setup/import-review');
        if($binary) {
            if(($_SERVER['CONTENT_TYPE']??'')!=='application/octet-stream')reseller_api_error(415,'binary_required','Send the encrypted backup as application/octet-stream.');
            $size=filter_var($_SERVER['CONTENT_LENGTH']??null,FILTER_VALIDATE_INT,['options'=>['min_range'=>52,'max_range'=>2147483648]]);
            if($size===false)reseller_api_error(413,'backup_size','Send Content-Length for a backup no larger than 2 GiB.');
            $encoded=$_SERVER['HTTP_X_BACKUP_PASSWORD']??'';$password=is_string($encoded)&&strlen($encoded)<=344?base64_decode($encoded,true):false;
            if(!is_string($password)||base64_encode($password)!==$encoded||strlen($password)<12||strlen($password)>256)reseller_api_error(400,'backup_password','Send X-Backup-Password as base64 of your 12 to 256 byte backup password.');
            $input=['_stream'=>fopen('php://input','rb'),'_size'=>$size,'_password'=>$password];
        }elseif($multipart&&preg_match('~^multipart/form-data;~i',$_SERVER['CONTENT_TYPE']??'')) {
            if((int)($_SERVER['CONTENT_LENGTH']??0)>33554432)reseller_api_error(413,'upload_too_large','Keep audio and phone configuration uploads below 32 MiB.');
            $input=$_POST;if(array_filter(array_keys($input),static fn($k)=>str_starts_with((string)$k,'_')))reseller_api_error(400,'invalid_request','Unsupported form field.');
        }elseif($method==='POST'||(int)($_SERVER['CONTENT_LENGTH']??0)>0) {
            if(!preg_match('~^application/json(?:\s*;\s*charset=utf-8)?$~iD',$_SERVER['CONTENT_TYPE']??''))reseller_api_error(415,'json_required','Send application/json.');
            if((int)($_SERVER['CONTENT_LENGTH']??0)>131072)reseller_api_error(413,'body_too_large','Keep JSON requests below 128 KiB.');
            $raw=file_get_contents('php://input',false,null,0,131073);if(!is_string($raw)||strlen($raw)>131072)reseller_api_error(413,'body_too_large','Keep JSON requests below 128 KiB.');
            $object=json_decode($raw,false,32,JSON_THROW_ON_ERROR);if(!is_object($object))reseller_api_error(400,'invalid_request','Send a JSON object.');$input=json_decode($raw,true,32,JSON_THROW_ON_ERROR);
            if(array_filter(array_keys($input),static fn($k)=>str_starts_with((string)$k,'_')))reseller_api_error(400,'invalid_request','Unsupported JSON field.');
        }
    }elseif(strlen($_SERVER['QUERY_STRING']??'')>4096)reseller_api_error(413,'query_too_large','Keep queries below 4 KiB.');
    $authorization=(string)($_SERVER['HTTP_AUTHORIZATION']??'');
    if($authorization==='')reseller_api_error(401,'key_required','Send your API key using Authorization: Bearer.');
    $result=(new pbx_reseller_api)->handle($method,$route,$input,$authorization,(string)($_SERVER['REMOTE_ADDR']??''));
    if($result instanceof pbx_api_file) {
        $f=$result->file;$h=$f['handle']??null;if(!is_resource($h))throw new RuntimeException('Download unavailable.');
        $filename=basename((string)($f['filename']??'openweb-backup.owpbx'));if(!preg_match('/^[A-Za-z0-9._-]{1,180}$/D',$filename))$filename='openweb-download.bin';
        header('Content-Type: '.$result->mime);header('Content-Length: '.(int)$f['size']);header('Content-Disposition: attachment; filename="'.$filename.'"');
        if(isset($f['sha256'])&&is_string($f['sha256'])&&preg_match('/^[a-f0-9]{64}$/D',$f['sha256']))header('X-Content-SHA256: '.$f['sha256']);
        fpassthru($h);fclose($h);exit;
    }
    reseller_api_reply(200,['data'=>$result,'request_id'=>$requestId]);
}catch(pbx_api_rate_limited){header('Retry-After: 60');reseller_api_error(429,'rate_limited','This key has reached 120 requests per minute. Try again shortly.');}
catch(pbx_api_access_denied|pbx_staff_denied|pbx_core_access){reseller_api_error(403,'access_denied','This key or account does not allow this action.');}
catch(JsonException){reseller_api_error(400,'invalid_json','Send a valid JSON object.');}
catch(InvalidArgumentException){reseller_api_error(400,'invalid_request','Check the supplied details against the API documentation.');}
catch(OutOfBoundsException){reseller_api_error(404,'not_found','This item or endpoint is unavailable.');}
catch(OverflowException|DomainException){reseller_api_error(409,'conflict','The requested operation is unavailable or another request is running.');}
catch(PDOException $e){error_log('OpenWeb PBX API v2 '.$requestId.' failed (SQLSTATE '.$e->getCode().').');reseller_api_error(in_array($e->getCode(),['23505','P0001'],true)?409:503,'request_failed','The request could not be completed. Check resource limits and try again.');}
catch(Throwable $e){error_log('OpenWeb PBX API v2 '.$requestId.' failed ('.get_class($e).').');reseller_api_error(503,'temporarily_unavailable','The request could not be completed. Try again later.');}
