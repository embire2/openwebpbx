<?php
/** Reusable reviewer access uses ordinary authentication and a fixed demo assignment. */
require_once dirname(__DIR__,2).'/resources/require.php';
require_once PROJECT_ROOT.'/resources/check_auth.php';
header('Cache-Control: no-store');header('Referrer-Policy: no-referrer');header('X-Robots-Tag: noindex, nofollow');
$mobile=new pbx_mobile;
try{$account=$mobile->reviewExtension();}catch(Throwable){http_response_code(403);exit('Review access required.');}
$error='';$notice='';$code=null;
try{
 if(($_SERVER['REQUEST_METHOD']??'')==='POST'){
  if(!(new token)->validate('/app/pbx_mobile/review.php')){http_response_code(403);throw new RuntimeException('Your form expired. Refresh this page and try again.');}
  if(($_POST['action']??'')==='create')$code=$mobile->reviewCode();
  elseif(($_POST['action']??'')==='ring'){$mobile->reviewRing();$notice='Your demo phone will ring shortly. Answer it, then speak to hear your voice returned. Wait two and a half minutes before requesting another call.';}
  elseif(($_POST['action']??'')==='revoke'&&is_string($_POST['device']??null)){$mobile->reviewRevoke($_POST['device']);$notice='That demo phone has been removed. It can connect again with a new code.';}
  else throw new InvalidArgumentException('Choose an action.');
 }
 $devices=$mobile->reviewDevices();
}catch(OverflowException $ex){http_response_code(429);$error=$ex->getMessage();}catch(PDOException){$error='Review setup is temporarily unavailable. Please contact support.';}catch(Throwable $ex){$error=$ex->getMessage();}
$e=static fn($v)=>htmlspecialchars((string)$v,ENT_QUOTES,'UTF-8');$token=(new token)->create('/app/pbx_mobile/review.php');
$csrf=static function()use($token,$e){echo '<input type="hidden" name="'.$e($token['name']).'" value="'.$e($token['hash']).'">';};
?><!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>OpenWeb PBX · App review</title><link rel="icon" href="/themes/default/favicon.ico"><link rel="stylesheet" href="/app/pbx_setup/setup.css?v=4"><link rel="stylesheet" href="/app/pbx_mobile/review.css"></head><body><main class="pbx-setup">
<header class="setup-heading"><div><span class="setup-eyebrow">OPENWEB PBX</span><h1>App review</h1><p>A separate demo phone for testing the Android app.</p></div><a class="setup-button" href="/logout.php">Sign out</a></header>
<?php if($error): ?><div class="setup-message error" role="alert"><?= $e($error) ?></div><?php endif; ?>
<?php if($notice): ?><div class="setup-message" role="status"><?= $e($notice) ?></div><?php endif; ?>
<section class="setup-card"><h2>1. Connect your phone</h2><ol><li>Open the installed <strong>OpenWeb PBX</strong> Android app.</li><li>Select <strong>Scan QR code</strong>, allow camera access, and scan the code from this page on another screen. Alternatively select <strong>Enter a connection code instead</strong> and use the manual fields below.</li><li>Confirm the server address and allow microphone access for calls. Allow notifications to receive incoming calls.</li></ol>
<form method="post"><?php $csrf(); ?><button class="setup-button primary" name="action" value="create" type="submit">Show a fresh QR code</button></form>
<?php if($code): $manual=json_decode($code['payload'],true); ?><div class="review-qr"><?= pbx_mobile::qr($code['payload']) ?></div><p>The code works once and expires after ten minutes. This review login stays available; return here for a new code whenever needed.</p><div class="setup-form"><label>Server address<input readonly value="<?= $e($manual['server']) ?>"></label><label>Connection code<input readonly value="<?= $e($manual['code']) ?>"></label></div><?php endif; ?>
<p>Your demo extension is <strong><?= $e($account['number']) ?></strong>. This account cannot call outside numbers and contains no customer data.</p></section>
<section class="setup-card"><h2>2. Try the app</h2><ul><li>Dial <strong><?= $e($account['echo_number']) ?></strong> for the audio test. Speak to hear your voice returned. Try Speaker, Mute, Hold and End call. The test ends automatically after two minutes.</li><li>Dial <strong><?= $e($account['voicemail_number']) ?></strong> to leave a message for your demo mailbox. End the call, then open <strong>Voicemail</strong> to refresh, play or delete the message. A short sample tone is also supplied initially.</li><li>Open <strong>Contacts</strong> to see the demo numbers. Open <strong>Recents</strong> after making a call to see its history.</li><li>For an incoming call, use <strong>Ring my demo phone</strong> below. Answer in the Android app, then speak to hear your voice returned. You need only one phone.</li></ul><form method="post"><?php $csrf(); ?><button class="setup-button primary" name="action" value="ring" type="submit">Ring my demo phone</button></form><p>One test call can be requested every two and a half minutes. The call rings for up to 25 seconds and ends automatically after two minutes.</p><p>Keep the app’s phone connection notification enabled. Open the app again after restarting or force-stopping it. Only the demo phones listed below can be removed here.</p></section>
<section class="setup-card"><h2>3. Manage demo phones</h2><p>Up to ten phones can be connected. Remove an unused review phone if the limit is reached; then create a fresh code.</p>
<?php if(empty($devices)): ?><p>No demo phones are connected.</p><?php endif; foreach($devices??[] as $device): ?><div class="review-device"><strong><?= $e($device['device_name']) ?></strong><p>Added <?= $e(substr($device['created_at'],0,10)) ?></p><form method="post"><?php $csrf(); ?><input type="hidden" name="device" value="<?= $e($device['device_uuid']) ?>"><button class="setup-button" name="action" value="revoke" type="submit">Remove this demo phone</button></form></div><?php endforeach; ?></section>
<footer><a href="https://openwebpbx.com/privacy.html">Privacy</a> · <a href="https://openwebpbx.com/support.html">Support</a></footer>
</main></body></html>
