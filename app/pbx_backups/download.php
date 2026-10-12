<?php
require_once dirname(__DIR__,2).'/resources/require.php';
require_once PROJECT_ROOT.'/resources/check_auth.php';
header('Cache-Control: no-store');header('Referrer-Policy: no-referrer');header('X-Content-Type-Options: nosniff');
$backups=new pbx_backups;
try {
    if (!is_string($_GET['id']??null)) throw new InvalidArgumentException('Backup unavailable.');
    $download=$backups->download($_GET['id']);
    if (session_status()===PHP_SESSION_ACTIVE) session_write_close();
    while(ob_get_level()>0)ob_end_clean();
    header('Content-Type: application/octet-stream');
    header('Content-Disposition: attachment; filename="'.$download['filename'].'"');
    header('Content-Length: '.$download['size']);
    header('X-Backup-SHA256: '.$download['sha256']);
    fpassthru($download['handle']);fclose($download['handle']);
} catch(DomainException) { http_response_code(403);echo 'Access denied.'; }
catch(InvalidArgumentException) { http_response_code(404);echo 'Backup unavailable.'; }
catch(Throwable) { http_response_code(503);echo 'The encrypted download is unavailable. Check the backup service.'; }
