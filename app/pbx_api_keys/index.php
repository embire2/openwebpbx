<?php
require_once dirname(__DIR__,2).'/resources/require.php';
require_once PROJECT_ROOT.'/resources/check_auth.php';
header('Cache-Control: no-store');header('Referrer-Policy: no-referrer');
$keys=new pbx_access_keys;$error='';$notice='';$created=null;
try {
    $choices=$keys->choices();
    if(($_SERVER['REQUEST_METHOD']??'')==='POST') {
        if(!(new token)->validate('/app/pbx_api_keys/index.php'))throw new pbx_api_access_denied('Your form expired. Refresh this page.');
        $action=$_POST['action']??'';
        if($action==='create'){$created=$keys->create($_POST);$notice='Your API key is ready. Save it now; only its name will be shown later.';}
        elseif($action==='revoke'&&is_string($_POST['key_uuid']??null)){$keys->revoke($_POST['key_uuid']);$notice='API key revoked. It and keys it delegated will be refused on their next request.';}
        elseif($action==='rotate'&&is_string($_POST['key_uuid']??null)){$created=$keys->rotate($_POST['key_uuid']);$notice='New key created. The previous key and keys it delegated have been revoked.';}
        else throw new InvalidArgumentException('Choose an API key action.');
    }
    $rows=$keys->listing();
}catch(pbx_api_access_denied $e){http_response_code(403);$error=$e->getMessage();}
catch(InvalidArgumentException|OutOfBoundsException|OverflowException $e){http_response_code(400);$error=$e->getMessage();}
catch(Throwable){http_response_code(503);$error='API keys are not ready. Ask your instance administrator to finish installing the update.';}
$e=static fn($v)=>htmlspecialchars((string)$v,ENT_QUOTES,'UTF-8');
$form=(new token)->create('/app/pbx_api_keys/index.php');$csrf=static function()use($form,$e){echo '<input type="hidden" name="'.$e($form['name']).'" value="'.$e($form['hash']).'">';};
$document['title']='API Keys';require_once PROJECT_ROOT.'/resources/header.php';
$labels=['pbx:read'=>'View PBX settings and reports','pbx:write'=>'Manage users, trunks and routing','calls:control'=>'Control live calls and run call tests','credentials:read'=>'Read phone passwords and QR setup','backups:read'=>'View and download backups','backups:write'=>'Create, verify and restore backups','templates:read'=>'View PBX templates and services','templates:write'=>'Manage templates and create services','reseller:manage'=>'Manage packages and approve resources','keys:manage'=>'Manage integration keys within this scope','system:manage'=>'Manage this entire server'];
?>
<link rel="stylesheet" href="/app/pbx_setup/setup.css?v=4">
<main class="pbx-setup">
<header class="setup-heading"><div><span class="setup-eyebrow">OPENWEB PBX · INTEGRATIONS</span><h1>API Keys</h1><p>Connect your billing system, customer portal or automation. Each key has its own permissions and expiry.</p><p><a href="https://openwebpbx.com/api-docs#administration-v2" target="_blank" rel="noopener noreferrer">API documentation and examples</a></p></div><a class="setup-button" href="/tenantadmin/">Tenant Admin</a></header>
<?php if($error):?><div class="setup-message error" role="alert"><?=$e($error)?></div><?php endif;?>
<?php if($notice):?><div class="setup-message" role="status"><?=$e($notice)?></div><?php endif;?>
<?php if($created):?><section class="setup-card"><h2>Save your new key</h2><p>This is the only time its full value is displayed. Treat it like a password.</p><label>API key<input type="text" readonly autocomplete="off" spellcheck="false" style="width:100%" value="<?=$e($created['token'])?>" aria-label="New API key"></label><p>Installation API: <code><?=$e(pbx_paths::url())?>/api/v2/</code> · <a href="https://openwebpbx.com/api-docs" target="_blank" rel="noopener noreferrer">API documentation</a></p></section><?php endif;?>
<?php if(isset($choices,$rows)):?>
<section class="setup-card"><h2>Create an API key</h2><form method="post" autocomplete="off" class="setup-form"><?php $csrf();?><input type="hidden" name="action" value="create">
<div class="form-grid"><label>Name<input name="name" maxlength="100" required placeholder="Customer billing portal"></label><label>Expires after (days)<input name="days" type="number" min="1" max="365" value="90" required></label>
<label>Tenant<select name="tenant_uuid" id="key-tenant" data-default-domain="<?=$e($choices['default_domain'])?>"><?php if($choices['instance']):?><option value="">Entire instance — administrator only</option><?php elseif($choices['domain_admin']):?><option value="">My own PBX only</option><?php endif;?><?php foreach($choices['tenants'] as $t):?><option value="<?=$e($t['tenant_uuid'])?>"><?=$e($t['tenant_name'])?></option><?php endforeach;?></select></label>
<label>PBX service<select name="domain_uuid" id="key-domain" data-domain-search-init="true"><option value="">All services in the selected tenant</option><?php foreach($choices['services'] as $s):?><option data-tenant="<?=$e($s['tenant_uuid'])?>" value="<?=$e($s['domain_uuid'])?>"><?=$e($s['service_name'].' · '.$s['domain_name'])?></option><?php endforeach;?></select></label></div>
<fieldset><legend>What can this key do?</legend><p class="setup-hint">Start with view access. Add permission only when your integration needs it. Downloaded backups contain private customer data.</p><div class="form-grid"><?php foreach($labels as $scope=>$label):if($scope==='system:manage'&&!$choices['instance']||$scope==='reseller:manage'&&!$choices['reseller'])continue;?><label><input type="checkbox" name="scopes[]" value="<?=$e($scope)?>" <?=$scope==='pbx:read'?'checked':''?>> <?=$e($label)?></label><?php endforeach;?></div></fieldset><button class="setup-button primary">Create API key</button></form></section>
<section class="setup-card"><h2>Your API keys</h2><p>Revoking or rotating a key also withdraws keys it delegated through the API. Phone registrations and QR codes are unaffected.</p><div style="overflow:auto"><table style="width:100%;min-width:680px"><thead><tr><th>Name</th><th>Permissions</th><th>Expires</th><th>Last used</th><th>Actions</th></tr></thead><tbody><?php foreach($rows as $r):$scopes=json_decode($r['scopes'],true)??[];$active=filter_var($r['effective_active'],FILTER_VALIDATE_BOOLEAN);?><tr><td><strong><?=$e($r['key_name'])?></strong><br><code><?=$e($r['prefix'])?>…</code><br><?=$active?'Active':($r['revoked_at']?'Revoked':(strtotime($r['expires_at'])<=time()?'Expired':'Parent key withdrawn'))?></td><td><?=$e(implode(', ',$scopes))?></td><td><?=$e($r['expires_at'])?></td><td><?=$e($r['last_used_at']?:'Not used yet')?></td><td><?php if($active):?><form method="post"><?php $csrf();?><input type="hidden" name="key_uuid" value="<?=$e($r['key_uuid'])?>"><button class="setup-button" name="action" value="rotate">Replace key</button> <button class="setup-button" name="action" value="revoke">Revoke</button></form><?php endif;?></td></tr><?php endforeach;?><?php if(!$rows):?><tr><td colspan="5">No keys yet. Create your first integration key above.</td></tr><?php endif;?></tbody></table></div></section>
<script src="/app/pbx_api_keys/keys.js?v=25" defer></script>
<?php endif;?></main>
<?php require_once PROJECT_ROOT.'/resources/footer.php';?>
