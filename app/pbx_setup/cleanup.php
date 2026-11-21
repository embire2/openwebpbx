<?php
/** Cron entry. Only expired, unlocked private upload files are removed. */
if(PHP_SAPI!=='cli'){http_response_code(404);exit;}
require dirname(__DIR__,2).'/resources/require.php';
$db=$database->db;
$db->exec('delete from v_pbx_setup_drafts where draft_uuid in
    (select draft_uuid from v_pbx_setup_drafts where expires_at<now() and completed_domain_uuid is null for update skip locked)');
// An upload lease lasts two hours; reviewed drafts expire after one hour.
// Original operator backups are never stored in this disposable upload directory.
function expire_setup_uploads(string $directory, string $pattern): void {
    if (!is_dir($directory) || is_link($directory)) return;
    $expiry = time() - 7200;
    foreach (new DirectoryIterator($directory) as $file) {
        if (!$file->isFile() || $file->isLink() || !preg_match($pattern, $file->getFilename())
            || $file->getMTime() >= $expiry) continue;
        $path = $file->getPathname();
        $stream = @fopen($path, 'rb');
        if (!$stream) continue;
        try {
            // An import that began before expiry can still be restoring.
            if (!flock($stream, LOCK_EX | LOCK_NB)) continue;
            clearstatcache(true, $path);
            $current = @lstat($path);
            $opened = fstat($stream);
            if ($current && $opened && $current['ino'] === $opened['ino'] && $current['dev'] === $opened['dev']
                && $current['mtime'] < $expiry && !is_link($path)) @unlink($path);
        } finally {
            fclose($stream);
        }
    }
}
expire_setup_uploads(pbx_paths::uploads(), '/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\.zip$/D');
// PHP normally removes these at the end of the request. A killed worker can
// leave one behind. Only inspect the product-managed Debian directory.
if (PHP_OS_FAMILY === 'Linux') expire_setup_uploads(pbx_paths::phpUploads(), '/^php[A-Za-z0-9_-]{6,64}$/D');
