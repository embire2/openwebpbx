<?php
require_once dirname(__DIR__,2).'/resources/require.php';require_once PROJECT_ROOT.'/resources/check_auth.php';
if(!(new pbx_setup)->canManage()||!permission_exists('extension_edit')){http_response_code(403);exit('Access denied.');}
header('Cache-Control: no-store');header('Referrer-Policy: no-referrer');pbx_admin::openPreferred();$admin=new pbx_admin;$mobile=new pbx_mobile;
$error='';$notice='';$code=null;$number=is_string($_GET['extension']??null)?$_GET['extension']:'';
try {
    $config=$admin->config();if($number!=='')$mobile->adminExtension($number);
    if(($_SERVER['REQUEST_METHOD']??'')==='POST'){
        if(!(new token)->validate('/app/pbx_mobile/index.php')){http_response_code(403);throw new RuntimeException('Your form expired. Refresh this page.');}
        if(($_POST['action']??'')==='create')$code=$mobile->createCode($number);
        elseif(($_POST['action']??'')==='revoke'&&is_string($_POST['device']??null)){$mobile->adminRevoke($number,$_POST['device']);$notice='Phone removed. It needs a new code to connect again.';}
        else throw new InvalidArgumentException('Choose an action.');
    }
}catch(PDOException){$error='Phone setup is unavailable. Ask your instance administrator to finish the update.';}catch(Throwable $ex){$error=$ex->getMessage();}
$e=static fn($v)=>htmlspecialchars((string)$v,ENT_QUOTES,'UTF-8');$token=(new token)->create('/app/pbx_mobile/index.php');
$csrf=static function()use($token,$e){echo '<input type="hidden" name="'.$e($token['name']).'" value="'.$e($token['hash']).'">';};
$document['title']='Android App';require_once PROJECT_ROOT.'/resources/header.php';
?>
<link rel="stylesheet" href="/app/pbx_setup/setup.css?v=4">
<main class="pbx-setup"><header class="setup-heading"><div><span class="setup-eyebrow">OPENWEB PBX · <?= htmlspecialchars(pbx_updates::version(),ENT_QUOTES,'UTF-8') ?></span><h1>Android App</h1><p>Connect your phone by scanning its setup code.</p></div><a class="setup-button" href="/app/pbx_setup/?view=users">Users</a></header>
<?php if($error): ?><div class="setup-message error" role="alert"><?= $e($error) ?></div><?php endif; ?>
<?php if($notice): ?><div class="setup-message" role="status"><?= $e($notice) ?></div><?php endif; ?>
<section class="setup-card"><form method="get" class="setup-form"><label>User<select name="extension" required><option value="">Choose a user</option><?php foreach($config['users']??[] as $n=>$u): if(empty($u['enabled']))continue; ?><option value="<?= $e($n) ?>" <?= (string)$n===$number?'selected':'' ?>><?= $e($n.' · '.$u['name']) ?></option><?php endforeach; ?></select></label><button class="setup-button" type="submit">Open</button></form></section>
<?php if($number!==''&&!$error): ?><section class="setup-card"><h2><?= $e($number.' · '.$config['users'][$number]['name']) ?></h2><ol><li>Install <a href="https://openwebpbx.com/#downloads" target="_blank" rel="noopener noreferrer">OpenWeb PBX for Android</a>.</li><li>Choose <strong>Scan QR code</strong> in the app.</li><li>Scan the code below and confirm your server address.</li></ol>
<form method="post" class="setup-form"><?php $csrf(); ?><button class="setup-button primary" type="submit" name="action" value="create"><?= $code?'Create a new code':'Show QR code' ?></button></form>
<?php if($code): ?><div style="padding:16px 0"><?= pbx_mobile::qr($code['payload']) ?></div><p>This code works once and expires in ten minutes. Share it only with the person using this extension. Creating another code replaces this one.</p><details><summary>Enter setup details manually</summary><p>Choose Enter details in the app if its camera is unavailable.</p><?php $manual=json_decode($code['payload'],true); ?><div class="setup-form"><label>Server address<input readonly value="<?= $e($manual['server']) ?>"></label><label>Connection code<input readonly value="<?= $e($manual['code']) ?>" style="font-family:monospace"></label></div></details><?php endif; ?>
<p class="setup-hint">Keep the app’s phone connection notification enabled to receive calls. After force-stopping the app or restarting your phone, open it again.</p></section>
<section class="setup-card"><h2>Connected phones</h2><?php $devices=$mobile->devices($number);if(!$devices): ?><p>No phones connected yet.</p><?php endif; foreach($devices as $device): ?><div class="setup-card"><strong><?= $e($device['device_name']) ?></strong><p><?= $device['revoked_at']?'Removed':(strtotime($device['expires_at'])<time()?'Expired':'Connected') ?> · Added <?= $e(substr($device['created_at'],0,10)) ?><?php if($device['last_seen_at']): ?> · Last opened <?= $e(substr($device['last_seen_at'],0,16)) ?><?php endif; ?></p><?php if(!$device['revoked_at']): ?><form method="post"><?php $csrf(); ?><input type="hidden" name="device" value="<?= $e($device['device_uuid']) ?>"><button class="setup-button" name="action" value="revoke" type="submit">Remove phone</button></form><?php endif; ?></div><?php endforeach; ?></section><?php endif; ?></main>
<?php require_once PROJECT_ROOT.'/resources/footer.php'; ?>
