<?php
require_once dirname(__DIR__,2).'/resources/require.php';require_once PROJECT_ROOT.'/resources/check_auth.php';
header('Cache-Control: private, no-store');header('X-Content-Type-Options: nosniff');header('Referrer-Policy: no-referrer');
try{
    $id=$_GET['id']??'';if(!is_string($id))throw new InvalidArgumentException('Choose a greeting.');
    $media=(new pbx_greetings)->media($id);$file=fopen($media['file_path'],'rb');if(!$file)throw new RuntimeException('Greeting unavailable.');
    $stat=fstat($file);if(!$stat||$stat['size']>32000000){fclose($file);throw new RuntimeException('Greeting unavailable.');}
    header('Content-Type: audio/wav');header('Content-Length: '.$stat['size']);
    header('Content-Disposition: '.(isset($_GET['download'])?'attachment':'inline').'; filename="openweb-greeting-'.$id.'.wav"');
    session_write_close();fpassthru($file);fclose($file);
}catch(DomainException){http_response_code(403);echo 'Access denied.';}catch(Throwable){http_response_code(404);echo 'Greeting unavailable.';}
