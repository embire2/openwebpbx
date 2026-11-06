<?php
require_once dirname(__DIR__,2).'/resources/require.php';
require_once PROJECT_ROOT.'/resources/check_auth.php';
header('Cache-Control: no-store');header('Referrer-Policy: no-referrer');header('X-Content-Type-Options: nosniff');
try {
    $tenant=$_GET['tenant']??'';$id=$_GET['id']??'';
    if(!is_string($tenant)||!is_string($id))throw new InvalidArgumentException('Choose an available backup.');
    $file=(new pbx_protection)->download($tenant,$id);
    header('Content-Type: application/octet-stream');header('Content-Length: '.$file['size']);header('Content-Disposition: attachment; filename="'.$file['filename'].'"');header('X-Checksum-SHA256: '.$file['sha256']);
    fpassthru($file['handle']);fclose($file['handle']);
}catch(DomainException){http_response_code(403);echo 'Backup access denied.';}
catch(Throwable){http_response_code(404);echo 'Backup unavailable.';}
