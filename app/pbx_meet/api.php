<?php
require_once dirname(__DIR__,2).'/resources/require.php';
header('Content-Type: application/json');header('Cache-Control: no-store');header('Referrer-Policy: no-referrer');header('X-Content-Type-Options: nosniff');
try{
 if($_SERVER['REQUEST_METHOD']!=='POST'||!str_starts_with($_SERVER['CONTENT_TYPE']??'','application/json')){http_response_code(405);throw new InvalidArgumentException('Use the meeting controls.');}
 if(isset($_SERVER['HTTP_ORIGIN'])&&$_SERVER['HTTP_ORIGIN']!==rtrim(pbx_paths::url(),'/')){http_response_code(403);throw new DomainException('Open the meeting on your PBX.');}
 if((int)($_SERVER['CONTENT_LENGTH']??0)>8192)throw new InvalidArgumentException('Meeting request too large.');
 $in=json_decode(file_get_contents('php://input',false,null,0,8193),true,16,JSON_THROW_ON_ERROR);if(!is_array($in))throw new InvalidArgumentException('Check the meeting details.');
 $meet=new pbx_meet;$action=$in['action']??'';session_write_close();
 if($action==='join')$out=$meet->join($in);
 else{$auth=$_SERVER['HTTP_AUTHORIZATION']??'';$token=str_starts_with($auth,'Bearer ')?substr($auth,7):'';$out=$action==='status'?$meet->status($token):$meet->action($token,$in);}
 echo json_encode($out,JSON_THROW_ON_ERROR);
}catch(Throwable $ex){if(http_response_code()<400)http_response_code($ex instanceof DomainException?403:($ex instanceof OutOfBoundsException?404:422));echo json_encode(['error'=>$ex instanceof PDOException?'The meeting service is temporarily unavailable. Please try again.':$ex->getMessage()]);}
