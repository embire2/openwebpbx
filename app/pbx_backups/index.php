<?php
require_once dirname(__DIR__,2).'/resources/require.php';
require_once PROJECT_ROOT.'/resources/check_auth.php';
$backups=new pbx_backups;
if (!$backups->canView()) { http_response_code(403);exit('Access denied.'); }
header('Cache-Control: no-store');header('Referrer-Policy: no-referrer');
$error='';$notice='';
try {
    if (($_SERVER['REQUEST_METHOD']??'')==='POST') {
        if (!(new token)->validate('/app/pbx_backups/index.php')) { http_response_code(403);throw new DomainException('Your form expired. Refresh this page.'); }
        $action=$_POST['action']??'';
        if ($action==='save') { $backups->save($_POST);$notice='Backup settings saved. Keep your backup password somewhere separate from this server.'; }
        elseif (in_array($action,['create','verify'],true) && is_string($_POST['backup_uuid']??'')) { $backups->request($action,$_POST['backup_uuid']??'');$notice='Request queued. Refresh this page to see the result.'; }
        else throw new InvalidArgumentException('Choose a backup action.');
    }
    $backupSettings=$backups->settings();$status=$backups->status();
} catch(DomainException $e) { http_response_code(403);$error=$e->getMessage(); }
catch(InvalidArgumentException|OverflowException $e) { http_response_code(400);$error=$e->getMessage(); }
catch(Throwable) { http_response_code(503);$error='Backups are not ready. Ask your instance administrator to finish installing the backup service.'; }
if (!isset($backupSettings,$status)) {
    try { $backupSettings=$backups->settings();$status=$backups->status(); }
    catch(Throwable) { /* Retain the explicit error above without exposing database details. */ }
}
$e=static fn($v)=>htmlspecialchars((string)$v,ENT_QUOTES,'UTF-8');
$date=static fn($v)=>($time=strtotime((string)$v))!==false?gmdate('j M Y, H:i',$time).' UTC':'Unknown date';
$backupLabel=static fn($item)=>str_starts_with($item['message'],'Previous server:')?'Previous server':ucfirst($item['status']);
$formToken=(new token)->create('/app/pbx_backups/index.php');
$csrf=static function()use($formToken,$e){echo '<input type="hidden" name="'.$e($formToken['name']).'" value="'.$e($formToken['hash']).'">';};
$document['title']='Backups';require_once PROJECT_ROOT.'/resources/header.php';
?>
<link rel="stylesheet" href="/app/pbx_setup/setup.css?v=4">
<link rel="stylesheet" href="/app/pbx_backups/backups.css?v=1">
<main class="pbx-setup">
<header class="setup-heading"><div><span class="setup-eyebrow">OPENWEB PBX · INSTANCE SETTINGS</span><h1>Backups</h1><p>Protect every tenant on this server. Download an encrypted copy and keep another copy elsewhere.</p></div><a class="setup-button" href="?">Refresh</a></header>
<?php if($error):?><div class="setup-message error" role="alert"><?=$e($error)?></div><?php endif;?>
<?php if($notice):?><div class="setup-message" role="status"><?=$e($notice)?></div><?php endif;?>
<?php if(isset($backupSettings,$status)):?>
<section class="setup-card"><h2>Backup status</h2><p role="status"><?=$e($status['message'])?></p>
<?php if(!$status['service_online']):?><p class="setup-hint">The backup service has not checked in recently. Requests will wait until it is running.</p><?php endif;?>
<form method="post"><?php $csrf();?><button class="setup-button primary" name="action" value="create" <?=$backupSettings['has_passphrase']?'':'disabled'?>>Back up now</button></form>
<p class="setup-hint">The copy includes all tenants, users, settings, templates, encryption keys and call jobs. Optional media includes voicemail, recordings and custom sounds. Calls continue while a backup runs. A file that changes during the copy makes the backup fail safely; try again at a quiet time.</p></section>
<section class="setup-card"><h2>Automatic backups</h2><form method="post" class="setup-form" autocomplete="off"><?php $csrf();?><input type="hidden" name="action" value="save">
<label class="backup-check"><input type="checkbox" name="enabled" value="1" <?=$backupSettings['enabled']?'checked':''?>> Back up automatically every day</label>
<div class="form-grid"><label>Daily time (UTC)<select name="schedule_hour"><?php for($h=0;$h<24;$h++):?><option value="<?=$h?>" <?=(int)$backupSettings['schedule_hour']===$h?'selected':''?>><?=sprintf('%02d:00',$h)?></option><?php endfor;?></select></label><label>Number of successful local copies to keep<input type="number" name="retention" min="2" max="90" value="<?=$e($backupSettings['retention'])?>" required></label></div>
<label class="backup-check"><input type="checkbox" name="include_media" value="1" <?=$backupSettings['include_media']?'checked':''?>> Include voicemail, recordings and custom sounds</label>
<label>Backup password<input type="password" name="passphrase" maxlength="256" autocomplete="new-password" <?=$backupSettings['has_passphrase']?'':'required minlength="12"'?> placeholder="<?=$backupSettings['has_passphrase']?'Leave blank to keep the saved password':'Use at least 12 characters'?>"></label>
<p class="setup-hint">You need this password to restore a downloaded copy. Changing it affects future backups only. Save each password separately; OpenWeb PBX cannot recover a forgotten password. At least two successful local copies remain when old copies are removed.</p>
<details class="backup-remote" <?=$backupSettings['sftp_enabled']?'open':''?>><summary>Keep an additional copy on another server</summary>
<p>Use an SFTP account. The local copy stays available if sending the remote copy fails. Remote copies are never deleted automatically.</p>
<label class="backup-check"><input type="checkbox" name="sftp_enabled" value="1" <?=$backupSettings['sftp_enabled']?'checked':''?>> Send each completed backup to an SFTP server</label>
<div class="form-grid"><label>Server<input name="sftp_host" maxlength="253" value="<?=$e($backupSettings['sftp_host'])?>" placeholder="backups.example.com"></label><label>Port<input type="number" name="sftp_port" min="1" max="65535" value="<?=$e($backupSettings['sftp_port'])?>"></label><label>Username<input name="sftp_user" maxlength="64" value="<?=$e($backupSettings['sftp_user'])?>"></label><label>Folder<input name="sftp_directory" maxlength="512" value="<?=$e($backupSettings['sftp_directory'])?>" placeholder="/backups/openwebpbx"></label></div>
<label>Server’s trusted public SSH host key<input name="sftp_host_key" maxlength="4096" value="<?=$e($backupSettings['sftp_host_key'])?>" placeholder="ssh-ed25519 AAAA..."></label>
<p class="setup-hint">Get this public key directly from the server owner. It prevents sending a backup to an impersonated server. The folder must already exist.</p>
<label>Private SSH key for this backup account<textarea name="sftp_identity" rows="4" maxlength="32768" autocomplete="off" placeholder="<?=$backupSettings['has_identity']?'Leave blank to keep the saved key':'Paste an unencrypted private SSH key'?>"></textarea></label>
<p class="setup-hint">Stored keys are encrypted and are never displayed. Password login is not supported. Turning remote copies off removes its saved connection and key.</p></details>
<button class="setup-button primary">Save backup settings</button></form></section>
<section class="setup-card"><h2>Your backups</h2>
<?php if(!$status['backups']):?><p>No backups yet. Save a password, then choose Back up now.</p><?php endif;?>
<div class="backup-list"><?php foreach($status['backups'] as $item):?><article class="backup-entry"><h3><?=$e($date($item['created_at']))?></h3><p><?=$e($backupLabel($item))?> · <?=$e($item['app_version'])?> · <?=filter_var($item['include_media'],FILTER_VALIDATE_BOOLEAN)?'Settings and media':'Settings only'?> · <?=$e(number_format((int)$item['size_bytes']/1048576,1))?> MB</p>
<?php if($item['message']):?><p><?=$e($item['message'])?></p><?php endif;?>
<p>Remote copy: <?=$e($item['remote_status'])?><?php if($item['verified_at']):?> · Checked: <?=$e($date($item['verified_at']))?><?php endif;?></p>
<?php if($item['status']==='ready'):?><div class="setup-actions"><a class="setup-button" href="download.php?id=<?=$e($item['backup_uuid'])?>">Download encrypted backup</a><form method="post"><?php $csrf();?><input type="hidden" name="backup_uuid" value="<?=$e($item['backup_uuid'])?>"><button class="setup-button" name="action" value="verify">Check backup</button></form></div><details><summary>File checksum</summary><code class="backup-hash"><?=$e($item['sha256'])?></code></details><?php endif;?></article><?php endforeach;?></div>
</section>
<section class="setup-card"><h2>Restore onto a replacement server</h2><p>A restore replaces a fresh installation’s data. It is performed on the server by an instance administrator, keeping a running customer PBX protected.</p><ol><li>Install the same OpenWeb PBX release on a separate Debian 13 server, using the original server name and a valid HTTPS certificate.</li><li>Copy the encrypted backup to that server and keep the backup password ready.</li><li>Follow the restore guide. The tool checks the whole copy and refuses an installation that already contains customer services.</li><li>Test sign-in, phones and calls before switching your server address.</li></ol><p><a href="https://github.com/embire2/openwebpbx/blob/customization/docs/backups.md" target="_blank" rel="noopener noreferrer">Open the backup and restore guide</a></p></section>
<?php if($status['recent']):?><section class="setup-card"><h2>Recent requests</h2><?php foreach($status['recent'] as $request):?><p><?=$e(ucfirst($request['action']).' · '.$request['status'].' · '.$date($request['created_at']))?><br><?=$e($request['message'])?></p><?php endforeach;?></section><?php endif;?>
<?php endif;?></main>
<?php require_once PROJECT_ROOT.'/resources/footer.php';?>
