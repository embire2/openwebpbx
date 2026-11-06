<?php
/** A client-supplied header can never opt into the internal CGI upload gate. */
if(PHP_SAPI!=='cli')exit;
$entry=dirname(__DIR__).'/app/pbx_protection/upload_gate.php';$checks=0;
foreach([[],['HTTP_OPENWEB_UPLOAD_GATE'=>'1','HTTP_OPENWEB_UPLOAD_URI'=>'/api/v2/instance/backups/import','HTTP_OPENWEB_UPLOAD_METHOD'=>'POST','HTTP_OPENWEB_UPLOAD_LENGTH'=>'104857600']] as $headers){
    $code='$_SERVER='.var_export($headers,true).'; ob_start(); register_shutdown_function(static function(){ $body=ob_get_contents(); ob_end_clean(); echo json_encode(["status"=>http_response_code(),"body_bytes"=>strlen($body)],JSON_THROW_ON_ERROR); }); require '.var_export($entry,true).';';
    $pipes=[];$process=proc_open([PHP_BINARY,'-r',$code],[1=>['pipe','w'],2=>['pipe','w']],$pipes);if(!is_resource($process))throw new RuntimeException('Gate entry test unavailable.');$out=stream_get_contents($pipes[1]);$err=stream_get_contents($pipes[2]);fclose($pipes[1]);fclose($pipes[2]);$exit=proc_close($process);$reply=json_decode($out,true,16,JSON_THROW_ON_ERROR);if($exit!==0||$err!==''||$reply!==['status'=>404,'body_bytes'=>0])throw new RuntimeException('An external header enabled the internal gate or caused response output.');$checks++;
}
echo 'PASS '.$checks." isolated upload-gate entry/header controls; no framework/database/body read.\n";
