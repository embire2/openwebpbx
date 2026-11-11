<?php
require_once dirname(__DIR__,2).'/resources/require.php';
require_once PROJECT_ROOT.'/resources/check_auth.php';
header('Cache-Control: no-store');header('Referrer-Policy: no-referrer');
$protection=new pbx_protection;$error='';$notice='';$tenants=[];$status=['backups'=>[],'jobs'=>[]];
$tenant=is_string($_GET['tenant']??null)?$_GET['tenant']:'';
try {
    $tenants=$protection->tenants();$instance=$protection->instance();
    if($tenant===''&&!$instance)$tenant=$tenants[0]['tenant_uuid']??'';
    if(!$instance&&$tenant==='')throw new DomainException('No tenant workspace is available.');
    $name=$tenant===''?pbx_paths::host():'';foreach($tenants as $t)if($t['tenant_uuid']===$tenant)$name=$t['tenant_name'];
    if($name==='')throw new DomainException('Choose your own tenant workspace.');
    if(($_SERVER['REQUEST_METHOD']??'')==='POST'){
        if(!(new token)->validate('/app/pbx_protection/index.php'))throw new DomainException('Your form expired. Refresh this page.');
        if(($_POST['tenant_uuid']??null)!==$tenant)throw new DomainException('The selected workspace changed. Refresh this page.');
        $action=$_POST['action']??'';
        if($action==='instance_create'){
            if($tenant!==''||!$instance)throw new DomainException('Instance administrator access is required.');
            (new pbx_backups)->request('create','',true);
        }else $protection->request(is_string($action)?$action:'',$tenant,$_POST);
        $notice='Request queued. Progress updates automatically. Calls continue during backups. A restore waits for the recovery worker.';
    }
    $status=$protection->status($tenant);
}catch(DomainException $ex){http_response_code(403);$error=$ex->getMessage();}
catch(InvalidArgumentException|OverflowException $ex){http_response_code(400);$error=$ex->getMessage();}
catch(Throwable){http_response_code(503);$error='The backup and recovery service is unavailable. Ask the instance administrator to check its installation and storage.';}
if (($_SERVER['REQUEST_METHOD']??'')==='GET' && ($_GET['format']??'')==='status') {
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode(['error'=>$error,'status'=>$status],JSON_THROW_ON_ERROR);exit;
}
$e=static fn($s)=>htmlspecialchars((string)$s,ENT_QUOTES,'UTF-8');
$formToken=(new token)->create('/app/pbx_protection/index.php');
$csrf=static function()use($formToken,$e,$tenant){echo '<input type="hidden" name="'.$e($formToken['name']).'" value="'.$e($formToken['hash']).'"><input type="hidden" name="tenant_uuid" value="'.$e($tenant).'">';};
$document['title']='Backup & Restore';require_once PROJECT_ROOT.'/resources/header.php';
?>
<link rel="stylesheet" href="/app/pbx_setup/setup.css?v=4"><link rel="stylesheet" href="/app/pbx_backups/backups.css?v=1">
<main class="pbx-setup" data-backup-watch data-backup-tenant="<?=$e($tenant)?>"><header class="setup-heading"><div><span class="setup-eyebrow">OPENWEB PBX · PROTECTION</span><h1>Backup &amp; Restore</h1><p>Create a protected copy, check it, then restore when needed.</p></div><a class="setup-button" href="/tenantadmin/">Tenant Admin</a></header>
<?php if($error):?><div class="setup-message error" role="alert"><?=$e($error)?></div><?php endif;?>
<?php if($notice):?><div class="setup-message" role="status"><?=$e($notice)?></div><?php endif;?>
<section class="setup-card"><h2>Choose what to protect</h2><form method="get" class="setup-form"><label>Workspace<select name="tenant"><?php if(!empty($instance)):?><option value="" <?=$tenant===''?'selected':''?>>Full server · all tenants</option><?php endif;?><?php foreach($tenants as $t):?><option value="<?=$e($t['tenant_uuid'])?>" <?=$tenant===$t['tenant_uuid']?'selected':''?>><?=$e($t['tenant_name'])?></option><?php endforeach;?></select></label><button class="setup-button">Open backups</button></form></section>
<?php if(!empty($name)):?>
<section class="setup-card"><h2>Back up <?=$e($name)?></h2>
<?php if($tenant===''):?><p>A full copy includes every tenant, the complete database, private server settings, voicemail, call recordings and custom sounds. Calls continue while it runs.</p><p><a href="/app/pbx_backups/">Set the backup password, automatic schedule and off-server storage</a></p><form method="post"><?php $csrf();?><button class="setup-button primary" name="action" value="instance_create">Create full server backup</button></form>
<?php else:?><p>Includes this tenant’s PBX settings, extensions, SIP phone passwords, templates, voicemail, recordings and custom greetings. Current app and portal access, QR setup, API keys, caller authentication, consumed callback minutes, call history, subscription allowances and billing stay current during a restore. Shared server settings and waiting call jobs are protected by the separate full-server backup. A restore refuses to remove phones or services that still have current accounts or waiting actions; remove those accounts or cancel those actions normally first.</p><form method="post" class="setup-form" autocomplete="off"><?php $csrf();?><label>Backup password<input type="password" name="password" required minlength="12" maxlength="256" autocomplete="new-password"></label><p class="setup-hint">Keep this password separately. It cannot be recovered. Tenant copies restore onto this installation and the same PBX addresses and release.</p><button class="setup-button primary" name="action" value="tenant_create">Back up tenant settings and media</button></form><?php endif;?>
</section>
<section class="setup-card"><h2>Upload a saved backup</h2><p>Upload a previously downloaded <?=$tenant===''?'full-server .owpbx':'tenant .owtenant'?> copy, up to 2 GB. It is checked before becoming available for restore. Larger full-server copies can use the replacement-server restore tool.</p><form id="backup-upload" class="setup-form" autocomplete="off" data-tenant="<?=$e($tenant)?>" data-token-name="<?=$e($formToken['name'])?>" data-token="<?=$e($formToken['hash'])?>"><label>Encrypted backup<input type="file" name="backup" accept="<?=$tenant===''?'.owpbx':'.owtenant'?>" required></label><label>Original backup password<input type="password" name="password" required minlength="12" maxlength="256" autocomplete="off"></label><button class="setup-button">Upload and check backup</button><p id="backup-upload-result" role="status" aria-live="polite"></p><noscript>Enable JavaScript to upload a protected backup.</noscript></form></section>
<section class="setup-card"><h2>Saved backups</h2><?php if(!$status['backups']):?><p data-no-backups>No backups yet.</p><?php endif;?>
<div class="backup-list" data-backup-list><?php foreach($status['backups'] as $b):?><article class="backup-entry" data-backup-id="<?=$e($b['backup_uuid'])?>" id="backup-<?=$e($b['backup_uuid'])?>"><h3><?=$e($b['created_at'])?></h3><p class="backup-live-meta"><?=$e(ucfirst($b['status']))?> · <?=$e($b['app_version'])?> · <?=number_format((int)$b['size_bytes']/1048576,1)?> MB</p><p class="backup-live-note"><?=$e($b['message']??'')?></p>
<?php if($b['status']==='ready'):?><a class="setup-button" href="<?=$tenant===''?'/app/pbx_backups/download.php?id=':'/app/pbx_protection/download.php?tenant='.$e($tenant).'&amp;id='?><?=$e($b['backup_uuid'])?>">Download encrypted copy</a>
<form method="post" class="setup-form" autocomplete="off"><?php $csrf();?><input type="hidden" name="backup_uuid" value="<?=$e($b['backup_uuid'])?>"><label>Original backup password<input type="password" name="password" required minlength="12" maxlength="256" autocomplete="off"></label><button class="setup-button" name="action" value="<?=$tenant===''?'instance_verify':'tenant_verify'?>">Check backup before restore</button></form>
<details><summary>Restore this backup</summary><p>First check the backup above. A successful check is valid for 30 minutes. Restoring replaces <?=$tenant===''?'the entire server database and private files; current calls will end and previously running services restart. Server API keys will be revoked so previously revoked credentials cannot return; create new keys after restoring':'this tenant’s PBX settings and matching media files; wait for this tenant’s active calls to end'?>. A protected recovery copy is kept before replacement.</p><form method="post" class="setup-form" autocomplete="off"><?php $csrf();?><input type="hidden" name="backup_uuid" value="<?=$e($b['backup_uuid'])?>"><label>Original backup password<input type="password" name="password" required minlength="12" maxlength="256" autocomplete="off"></label><label>Type <?=$e($name)?> to confirm<input name="<?=$tenant===''?'confirm_server':'confirm_tenant'?>" required autocomplete="off"></label><label><input type="checkbox" name="confirm_replace" value="1" required> I understand that this replaces the selected <?=$tenant===''?'server':'tenant PBX settings'?>.</label><button class="setup-button" name="action" value="<?=$tenant===''?'instance_restore':'tenant_restore'?>">Restore backup</button></form></details><details><summary>Checksum</summary><code class="backup-hash"><?=$e($b['sha256'])?></code></details><?php endif;?></article><?php endforeach;?></div></section>
<section class="setup-card"><h2>Recent requests</h2><a class="setup-button" href="?tenant=<?=$e($tenant)?>">Refresh results</a><div data-backup-jobs><?php foreach($status['jobs'] as $j):?><p><strong><?=$e(str_replace('_',' ',$j['action']))?> · <?=$e($j['status'])?></strong><br><?=$e($j['message'])?><br><small><?=$e($j['created_at'])?></small></p><?php endforeach;?></div></section>
<section class="setup-card"><h2>Replacing a failed server?</h2><p>Use a full-server encrypted copy on a separate fresh Debian installation of the same release, with the original server name. Keep the source server off while testing the replacement. Tenant copies keep recovery separate inside a shared instance; they do not replace a whole-server copy.</p><a href="https://github.com/embire2/openwebpbx/blob/customization/docs/backups.md" rel="noopener noreferrer" target="_blank">Replacement-server restore guide</a></section>
<?php endif;?></main><script src="/app/pbx_protection/upload.js?v=25" defer></script><script src="/app/pbx_backups/status.js?v=25.2" defer></script><?php require_once PROJECT_ROOT.'/resources/footer.php';?>
