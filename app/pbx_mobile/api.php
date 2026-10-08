<?php
// Bearer-authenticated native API. Browser sessions never authorize this endpoint.
$no_session=true;
require_once dirname(__DIR__,2).'/resources/require.php';
header('Cache-Control: no-store');header('Referrer-Policy: no-referrer');header('X-Content-Type-Options: nosniff');header('Content-Type: application/json; charset=utf-8');
function mobile_reply(array $body,int $status=200): never {http_response_code($status);echo json_encode($body,JSON_THROW_ON_ERROR|JSON_UNESCAPED_SLASHES);exit;}
try {
    if(($_SERVER['HTTPS']??'')!=='on'&&($_SERVER['HTTPS']??'')!=='1')mobile_reply(['error'=>'Use the secure server address.'],403);
    $action=$_GET['action']??'';$method=$_SERVER['REQUEST_METHOD']??'';
    $get=['bootstrap','directory','calls','voicemail','voicemail_audio'];$post=['enroll','call_log','voicemail_read','voicemail_delete','revoke'];
    if(!is_string($action)||!in_array($action,array_merge($get,$post),true))mobile_reply(['error'=>'Action unavailable.'],404);
    if($method!==(in_array($action,$post,true)?'POST':'GET')){header('Allow: '.(in_array($action,$post,true)?'POST':'GET'));mobile_reply(['error'=>'Method unavailable.'],405);}
    if(isset($_SERVER['HTTP_ORIGIN']))mobile_reply(['error'=>'Use the OpenWeb PBX app.'],403);
    $input=[];if($method==='POST'){
        if(!str_starts_with(strtolower($_SERVER['CONTENT_TYPE']??''),'application/json'))mobile_reply(['error'=>'Send JSON details.'],415);
        if((int)($_SERVER['CONTENT_LENGTH']??0)>16384)mobile_reply(['error'=>'Request too large.'],413);
        $raw=file_get_contents('php://input',false,null,0,16385);if(strlen($raw)>16384)mobile_reply(['error'=>'Request too large.'],413);
        $input=json_decode($raw,true,16,JSON_THROW_ON_ERROR);if(!is_array($input)||array_is_list($input)&&$input!==[])mobile_reply(['error'=>'Check the supplied details.'],400);
    }
    $mobile=new pbx_mobile;
    if($action==='enroll')mobile_reply($mobile->enroll($input,(string)($_SERVER['REMOTE_ADDR']??'')));
    $auth=$_SERVER['HTTP_AUTHORIZATION']??'';if(!is_string($auth)||!preg_match('/^Bearer ([a-f0-9]{64})$/D',$auth,$match))mobile_reply(['error'=>'Connect your phone again.'],401);
    $account=$mobile->authenticate($match[1]);$mobile->rate('device:'.$account['device_uuid'],300,60);
    $id=$input['id']??$_GET['id']??'';if(!is_string($id))throw new InvalidArgumentException('Item unavailable.');
    if($action==='voicemail_audio'){
        $audio=$mobile->voicemailAudio($account,$id);$size=isset($audio['file'])?filesize($audio['file']):strlen($audio['data']);$start=0;$end=$size-1;
        if(isset($_SERVER['HTTP_RANGE'])){if(!preg_match('/^bytes=(\d+)-(\d*)$/D',$_SERVER['HTTP_RANGE'],$m))mobile_reply(['error'=>'Range unavailable.'],416);$start=(int)$m[1];$end=$m[2]!==''?min((int)$m[2],$end):$end;if($start>$end||$start>=$size){header('Content-Range: bytes */'.$size);mobile_reply(['error'=>'Range unavailable.'],416);}http_response_code(206);header('Content-Range: bytes '.$start.'-'.$end.'/'.$size);}
        header('Content-Type: '.$audio['type']);header('Accept-Ranges: bytes');header('Content-Length: '.($end-$start+1));
        if(isset($audio['file'])){$f=fopen($audio['file'],'rb');if(!$f)throw new RuntimeException('Message unavailable.');fseek($f,$start);$left=$end-$start+1;while($left>0&&!feof($f)){$buf=fread($f,min(65536,$left));if($buf===false||$buf==='')break;echo $buf;$left-=strlen($buf);}fclose($f);}else echo substr($audio['data'],$start,$end-$start+1);exit;
    }
    $result=match($action){'bootstrap'=>$mobile->bootstrap($account),'directory'=>$mobile->directory($account),'calls'=>$mobile->calls($account),'call_log'=>$mobile->callLog($account,$input),'voicemail'=>$mobile->voicemail($account),'voicemail_read'=>$mobile->voicemailRead($account,$id),'voicemail_delete'=>$mobile->voicemailDelete($account,$id),'revoke'=>(function()use($mobile,$account){$mobile->revoke($account);return ['ok'=>true];})()};mobile_reply($result);
}catch(OverflowException $ex){header('Retry-After: 600');mobile_reply(['error'=>$ex->getMessage()],429);}catch(UnexpectedValueException $ex){mobile_reply(['error'=>$ex->getMessage()],401);}catch(OutOfBoundsException $ex){mobile_reply(['error'=>$ex->getMessage()],404);}catch(InvalidArgumentException|JsonException){mobile_reply(['error'=>'Check the supplied details or create a new setup code.'],400);}catch(Throwable){mobile_reply(['error'=>'This request is unavailable. Try again or contact your administrator.'],503);}
