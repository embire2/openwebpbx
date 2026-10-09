<?php
require_once dirname(__DIR__,2).'/resources/require.php';
require_once PROJECT_ROOT.'/resources/check_auth.php';
$updates = new pbx_updates;
if (!$updates->canView()) { http_response_code(403); exit('Access denied.'); }
header('Cache-Control: no-store'); header('Referrer-Policy: no-referrer');
$error = ''; $notice = ''; $tenant = is_string($_GET['tenant'] ?? null) ? $_GET['tenant'] : '';
try {
    $tenants = $updates->tenants();
    if ($tenant === '' && $tenants) $tenant = $tenants[0]['tenant_uuid'];
    if (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST') {
        if (!(new token)->validate('/app/pbx_updates/index.php')) { http_response_code(403); throw new DomainException('Your form expired. Refresh this page.'); }
        $action = $_POST['action'] ?? '';
        if ($action === 'save_instance') { $updates->saveInstance($_POST); $notice = 'Server update settings saved.'; }
        elseif ($action === 'save_tenant') { $updates->saveTenant($tenant, $_POST); $notice = 'Android update settings saved for this tenant.'; }
        elseif (is_string($action) && in_array($action, ['check','download','install'], true)) { $updates->request($action); $notice = 'Request queued. The update service will report progress below.'; }
        else throw new InvalidArgumentException('Choose an update action.');
    }
    $phonePolicy = $tenant !== '' ? $updates->tenantPolicy($tenant) : null;
    $serverPolicy = $updates->instanceAdmin() ? $updates->instancePolicy() : null;
    $status = $updates->instanceAdmin() ? $updates->status() : null;
} catch (DomainException $e) { http_response_code(403); $error = $e->getMessage(); }
catch (InvalidArgumentException|OverflowException $e) { http_response_code(400); $error = $e->getMessage(); }
catch (Throwable) { http_response_code(503); $error = 'Updates are not ready. Ask your instance administrator to finish installing the update service.'; }
$e = static fn($value) => htmlspecialchars((string)$value, ENT_QUOTES, 'UTF-8');
$formToken = (new token)->create('/app/pbx_updates/index.php');
$csrf = static function() use($e,$formToken) { echo '<input type="hidden" name="'.$e($formToken['name']).'" value="'.$e($formToken['hash']).'">'; };
$document['title'] = 'Updates'; require_once PROJECT_ROOT.'/resources/header.php';
?>
<link rel="stylesheet" href="/app/pbx_setup/setup.css?v=4">
<link rel="stylesheet" href="/app/pbx_updates/updates.css?v=1">
<script src="/app/pbx_updates/updates.js?v=2" defer></script>
<main class="pbx-setup">
<header class="setup-heading"><div><span class="setup-eyebrow">OPENWEB PBX · <?= $e(pbx_updates::version()) ?></span><h1>Updates</h1><p>Keep your server and phones up to date.</p></div><a class="setup-button" href="/tenantadmin/">Tenant Admin</a></header>
<?php if ($error): ?><div class="setup-message error" role="alert"><?= $e($error) ?></div><?php endif; ?>
<?php if ($notice): ?><div class="setup-message" role="status"><?= $e($notice) ?></div><?php endif; ?>
<?php if (isset($status,$serverPolicy)): ?>
<section class="setup-card" data-update-status data-update-version="<?= $e($status['installed_version']) ?>"><h2>Server update</h2>
<p><strong>Installed:</strong> <span data-update-version><?= $e($status['installed_version']) ?></span><span data-update-available><?php if ($status['available_version']): ?> · Available: <?= $e($status['available_version']) ?><?php endif; ?></span></p>
<p role="status" data-update-message><?= $e($status['message']) ?></p>
<p class="setup-hint" data-update-offline <?= $status['service_online'] ? 'hidden' : '' ?>>The update service has not reported recently. Your running PBX is unaffected. An instance administrator can check the update service on the server.</p>
<progress style="width:100%" max="<?= max(1,(int)$status['total_bytes']) ?>" value="<?= (int)$status['progress_bytes'] ?>" aria-label="Download progress" <?= $status['total_bytes'] > 0 && $status['progress_bytes'] < $status['total_bytes'] ? '' : 'hidden' ?>></progress>
<form method="post" class="setup-form"><?php $csrf(); ?><div class="setup-actions"><button class="setup-button" name="action" value="check">Check for updates</button> <button class="setup-button" name="action" value="download">Download update</button> <button class="setup-button primary" name="action" value="install">Install when calls finish</button> <a class="setup-button" href="?<?= $tenant !== '' ? 'tenant='.$e($tenant) : '' ?>">Refresh status</a></div></form>
<p class="setup-hint">The complete download is checked before installation. Calls must finish first. The server is backed up, updated and restarted; a failed update restores the previous version. This page reconnects when the server returns.</p>
<?php if ($status['recent']): ?><details><summary>Recent requests</summary><?php foreach ($status['recent'] as $request): ?><p><?= $e(ucfirst($request['action']).' · '.$request['status'].' · '.$request['created_at']) ?><?php if ($request['message']): ?><br><?= $e($request['message']) ?><?php endif; ?></p><?php endforeach; ?></details><?php endif; ?>
</section>
<section class="setup-card"><h2>Automatic server updates</h2><p>This server hosts every tenant. Only an instance administrator can change these settings.</p>
<form method="post" class="setup-form"><?php $csrf(); ?><input type="hidden" name="action" value="save_instance">
<fieldset class="update-options"><legend>When a new release is available</legend><?php foreach (['notify'=>['Let me choose','I will start the download and installation.'],'download'=>['Download automatically','I will choose when to install.'],'automatic'=>['Install automatically','Download first, then install during the update window.']] as $value=>$option): ?><label class="update-option"><input type="radio" name="mode" value="<?= $e($value) ?>" <?= $serverPolicy['mode']===$value?'checked':'' ?>><span><strong><?= $e($option[0]) ?></strong><small><?= $e($option[1]) ?></small></span></label><?php endforeach; ?></fieldset>
<div class="form-grid"><label>Update window starts (UTC)<select name="maintenance_hour"><?php for($hour=0;$hour<24;$hour++): ?><option value="<?= $hour ?>" <?= (int)$serverPolicy['maintenance_hour']===$hour?'selected':'' ?>><?= sprintf('%02d:00',$hour) ?></option><?php endfor; ?></select></label><label>Window length<select name="maintenance_duration"><?php for($hours=1;$hours<=6;$hours++): ?><option value="<?= $hours ?>" <?= (int)$serverPolicy['maintenance_duration']===$hours?'selected':'' ?>><?= $hours ?> <?= $hours===1?'hour':'hours' ?></option><?php endfor; ?></select></label></div>
<p class="setup-hint">Automatic updates wait for an idle period inside this daily window. Downloads do not interrupt calls.</p><button class="setup-button primary">Save server settings</button></form></section>
<?php endif; ?>
<section class="setup-card"><h2>Android app updates</h2>
<?php if (!empty($tenants)): ?><form method="get" class="setup-form"><label>Tenant<select name="tenant"><?php foreach($tenants as $item): ?><option value="<?= $e($item['tenant_uuid']) ?>" <?= $tenant===$item['tenant_uuid']?'selected':'' ?>><?= $e($item['tenant_name']) ?></option><?php endforeach; ?></select></label><button class="setup-button">Open tenant settings</button></form><?php else: ?><p>Create a tenant to configure its Android app updates.</p><?php endif; ?>
<?php if (isset($phonePolicy)): ?><form method="post" class="setup-form"><?php $csrf(); ?><input type="hidden" name="action" value="save_tenant"><fieldset class="update-options"><legend>When a new app version is available</legend><?php foreach (['notify'=>['Let users choose','Each person starts the download and installation.'],'download'=>['Download automatically','Each person chooses when to install.'],'required'=>['Require the update','Download automatically, then ask the person to complete installation.']] as $value=>$option): ?><label class="update-option"><input type="radio" name="mode" value="<?= $e($value) ?>" <?= $phonePolicy['mode']===$value?'checked':'' ?>><span><strong><?= $e($option[0]) ?></strong><small><?= $e($option[1]) ?></small></span></label><?php endforeach; ?></fieldset><button class="setup-button primary">Save Android settings</button></form>
<p class="setup-hint">Applies to every connected Android phone in this tenant. Required updates wait for the complete verified download and active calls to finish. Android may ask the phone owner to allow installation or confirm the update. If Android prevents reopening, tap the app’s notification.</p><p class="setup-hint">Phones on version 1.0.3 need the first updater-enabled APK installed once. Later releases use these settings. Update the server before installing an app release that needs a newer server.</p><?php endif; ?>
</section>
<p><a href="https://github.com/embire2/openwebpbx/releases" target="_blank" rel="noopener noreferrer">Release notes and downloads</a></p>
</main>
<?php require_once PROJECT_ROOT.'/resources/footer.php'; ?>
