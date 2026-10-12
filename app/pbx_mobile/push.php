<?php
require_once dirname(__DIR__,2).'/resources/require.php';
require_once PROJECT_ROOT.'/resources/check_auth.php';
if(!permission_exists('pbx_update_instance')||!(new pbx_updates)->instanceAdmin()){http_response_code(403);exit('Access denied.');}
header('Cache-Control: no-store');header('Referrer-Policy: no-referrer');
$push=new pbx_mobile_push;$error='';$notice='';
if($_SERVER['REQUEST_METHOD']==='POST'){
    if(!(new token)->validate('/app/pbx_mobile/push.php')){http_response_code(403);$error='Your form expired. Refresh and try again.';}
    else try{$push->save($_POST);$notice='Incoming wake-up settings saved for this instance.';}catch(InvalidArgumentException $e){$error=$e->getMessage();}catch(Throwable){$error='Could not save. Check your configuration files and try again.';}
}
$client=$push->client();try{$saved=$push->view();}catch(Throwable){$saved=['enabled'=>false,'provider'=>'webpush','delivery'=>'direct','relay_url'=>'','has_client'=>false,'has_service_key'=>false,'has_relay_key'=>false,'project_id'=>''];$error=$error?:'Private wake-up settings could not be read. Check file permissions before saving.';}
$escape=fn($v)=>htmlspecialchars((string)$v,ENT_QUOTES,'UTF-8');$token=(new token)->create('/app/pbx_mobile/push.php');
$document_title='Incoming Call Wake-up';require_once PROJECT_ROOT.'/resources/header.php';
?>
<link rel="stylesheet" href="/app/pbx_setup/setup.css">
<main class="pbx-setup"><header class="setup-heading"><div><h1>Incoming Call Wake-up</h1><p>One setup for all tenants. Optional; the PBX and its call data stay on your server.</p></div></header>
<?php if($error): ?><p role="alert"><?= $escape($error) ?></p><?php endif; ?><?php if($notice): ?><p role="status"><?= $escape($notice) ?></p><?php endif; ?>
<section class="setup-card"><h2><?= !empty($client['enabled'])?'Settings saved':'Automatic setup needed' ?></h2>
<?php if(!empty($saved['enabled'])&&$saved['provider']==='fcm'): ?><p role="status">The saved legacy Firebase adapter cannot wake the current Android app. Enable incoming wake-up below and save to use automatic setup.</p><?php endif; ?>
<p>Automatic setup creates this server's wake-up keys. No Firebase project or Google developer account is needed. On supported Android phones, the native distributor uses installed Google Play services to deliver encrypted wake-up messages. Cloudflare can forward those encrypted messages through the supplied Worker relay.</p><p>Call audio, phone passwords and recordings stay on the PBX. Force-stopping an Android app prevents wake-up until the user opens it again. Test delivery on your actual locked and sleeping phones before relying on it.</p>
<form method="post" class="setup-form"><input type="hidden" name="<?= $escape($token['name']) ?>" value="<?= $escape($token['hash']) ?>">
<label><input type="checkbox" name="enabled" value="1" <?= !empty($client['enabled'])?'checked':'' ?>> Enable incoming wake-up</label>
<input type="hidden" name="provider" value="webpush">
<label>Send notifications using<select name="delivery"><option value="direct" <?= $saved['delivery']==='direct'?'selected':'' ?>>This PBX server</option><option value="cloudflare" <?= $saved['delivery']==='cloudflare'?'selected':'' ?>>Cloudflare Worker relay</option></select></label>
<label>Cloudflare Worker address<input name="relay_url" type="url" value="<?= $escape($saved['relay_url']) ?>" placeholder="https://openweb-push.your-account.workers.dev" autocomplete="off"></label>
<label>Cloudflare relay key (blank keeps the saved key)<input name="relay_token" type="password" autocomplete="new-password"></label>
<?php if($saved['has_relay_key']): ?><p>Relay key saved. Changing the Worker address requires its relay key.</p><?php endif; ?>
<button class="setup-button primary" type="submit">Save</button></form><p>Secrets are stored outside the website and never shown in this form. Setup instructions: <a href="https://github.com/embire2/openwebpbx/blob/customization/docs/android-push.md">Incoming-call wake-up guide</a>.</p></section></main>
<?php require_once PROJECT_ROOT.'/resources/footer.php'; ?>
