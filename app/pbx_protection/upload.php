<?php
require_once dirname(__DIR__,2).'/resources/require.php';
require_once PROJECT_ROOT.'/resources/check_auth.php';
header('Cache-Control: no-store');header('Content-Type: application/json');header('Referrer-Policy: no-referrer');
try {
    if(($_SERVER['REQUEST_METHOD']??'')!=='POST'||($_SERVER['CONTENT_TYPE']??'')!=='application/octet-stream')throw new InvalidArgumentException('Send an encrypted backup as a binary upload.');
    $name=$_SERVER['HTTP_X_OPENWEB_TOKEN_NAME']??'';$hash=$_SERVER['HTTP_X_OPENWEB_TOKEN']??'';
    if(!is_string($name)||strlen($name)>100||!is_string($hash)||strlen($hash)>256)throw new DomainException('Refresh the backup page.');
    if(!pbx_protection::uploadToken($name,$hash,true))throw new DomainException('Your form expired. Refresh the backup page.');
    $tenant=$_GET['tenant']??'';$encoded=$_SERVER['HTTP_X_BACKUP_PASSWORD']??'';
    if(!is_string($tenant)||!is_string($encoded)||strlen($encoded)>512||($password=base64_decode($encoded,true))===false)throw new InvalidArgumentException('Enter a valid backup password.');
    $size=filter_var($_SERVER['CONTENT_LENGTH']??null,FILTER_VALIDATE_INT,['options'=>['min_range'=>52,'max_range'=>2147483648]]);
    if($size===false)throw new InvalidArgumentException('Send a known file size, up to 2 GB.');
    $stream=fopen('php://input','rb');if($stream===false)throw new RuntimeException('Upload unavailable.');
    try {$job=(new pbx_protection)->importStream($tenant,$stream,$size,$password);}finally{fclose($stream);}
    http_response_code(202);echo json_encode(['job_uuid'=>$job,'message'=>'Upload received. The recovery worker will check it before adding it to saved backups.'],JSON_THROW_ON_ERROR);
}catch(DomainException $e){http_response_code(403);echo json_encode(['error'=>$e->getMessage()]);}
catch(InvalidArgumentException|OverflowException $e){http_response_code(400);echo json_encode(['error'=>$e->getMessage()]);}
catch(Throwable){http_response_code(503);echo json_encode(['error'=>'The protected upload could not finish. Check available storage and the recovery worker.']);}
