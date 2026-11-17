<?php
/** Private loopback-only IIS admission. Never receives the upload body. */
ini_set('display_errors','0');
if(PHP_OS_FAMILY!=='Windows'||($_SERVER['REMOTE_ADDR']??'')!=='127.0.0.1'||($_SERVER['REQUEST_METHOD']??'')!=='POST'||($_SERVER['CONTENT_LENGTH']??'')!=='0'){http_response_code(404);exit;}
$private=str_replace('\\','/',getenv('ProgramData')?:'C:/ProgramData').'/OpenWebPBX/upload-admission';
$key=@file_get_contents($private.'/gate.key');$supplied=$_SERVER['HTTP_X_OPENWEB_GATE_SECRET']??'';
if(!is_string($key)||!preg_match('/^[a-f0-9]{64}$/D',$key)||!is_string($supplied)||!hash_equals($key,$supplied)){http_response_code(404);exit;}
// Every security-relevant server value comes from the trusted module, never
// from the loopback request's public Host/HTTPS/body-length interpretation.
$_SERVER['OPENWEB_UPLOAD_GATE']='1';
$_SERVER['OPENWEB_WINDOWS_UPLOAD_GATE']='1';
$_SERVER['OPENWEB_UPLOAD_METHOD']=$_SERVER['HTTP_X_OPENWEB_UPLOAD_METHOD']??'';
$_SERVER['OPENWEB_UPLOAD_LENGTH']=$_SERVER['HTTP_X_OPENWEB_UPLOAD_LENGTH']??'';
$_SERVER['OPENWEB_UPLOAD_URI']=$_SERVER['HTTP_X_OPENWEB_UPLOAD_URI']??'';
$_SERVER['CONTENT_TYPE']=$_SERVER['HTTP_X_OPENWEB_UPLOAD_TYPE']??'';
$_SERVER['HTTP_HOST']=$_SERVER['HTTP_X_OPENWEB_UPLOAD_HOST']??'';
$_SERVER['REMOTE_ADDR']=$_SERVER['HTTP_X_OPENWEB_UPLOAD_ADDRESS']??'';
$_SERVER['HTTPS']='on';
foreach(['AUTHORIZATION','COOKIE','ORIGIN','X_OPENWEB_TOKEN_NAME','X_OPENWEB_TOKEN','X_BACKUP_PASSWORD'] as $name){
    unset($_SERVER['HTTP_'.$name]);
    if(isset($_SERVER['HTTP_X_OPENWEB_ORIGINAL_'.$name]))$_SERVER['HTTP_'.$name]=$_SERVER['HTTP_X_OPENWEB_ORIGINAL_'.$name];
}
// PHP parses cookies before this private bridge substitutes the original
// request, so explicitly parse only the ordinary PHP session cookie.
$_COOKIE=[];
if(isset($_SERVER['HTTP_COOKIE']))foreach(explode(';',$_SERVER['HTTP_COOKIE']) as $cookie){$pair=explode('=',trim($cookie),2);if(count($pair)===2&&$pair[0]===session_name())$_COOKIE[$pair[0]]=rawurldecode($pair[1]);}
$_SESSION=[];
if(!str_starts_with($_SERVER['OPENWEB_UPLOAD_URI'],'/api/v2/')){
    $id=$_COOKIE[session_name()]??'';
    $sessions=dirname($private).'/sessions';$file=$sessions.'/sess_'.$id;
    // No new sessions, token consumption, garbage collection or session-data
    // writes occur during admission. The ordinary upload rechecks/consumes CSRF.
    if(!is_string($id)||!preg_match('/^[a-zA-Z0-9,-]{1,128}$/D',$id)||is_link($sessions)||is_link($file)||!is_file($file)||filesize($file)>1048576){http_response_code(401);exit;}
    ini_set('session.gc_probability','0');session_id($id);
    if(!session_start(['read_and_close'=>true])){http_response_code(403);exit;}
}
require 'C:/OpenWebPBX/web/app/pbx_protection/upload_gate.php';
