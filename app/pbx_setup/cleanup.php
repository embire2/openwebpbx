<?php
/** Cron entry. Only expired, unreferenced upload files are removed. */
if(PHP_SAPI!=='cli'){http_response_code(404);exit;}
require dirname(__DIR__,2).'/resources/require.php';
$db=$database->db;$db->exec('delete from v_pbx_setup_drafts where expires_at<now() and completed_domain_uuid is null');
// An upload lease lasts two hours; reviewed drafts expire after one hour.
// Original operator backups are never stored in this disposable upload directory.
foreach(glob(pbx_paths::uploads().'/*.zip')?:[] as $file){
    if(!preg_match('/^[0-9a-f-]{36}\.zip$/D',basename($file))||is_link($file)||filemtime($file)>time()-7200)continue;
    // Keep a file while a draft is locked/restoring, even if its lease is old.
    $active=(int)$db->query('select count(*) from v_pbx_setup_drafts where payload_ciphertext is not null and expires_at>now()')->fetchColumn();
    if($active===0)unlink($file);
}
