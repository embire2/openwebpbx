<?php
require_once dirname(__DIR__,2).'/resources/require.php';
header('Cache-Control: no-store');header('Referrer-Policy: no-referrer');
$portal=new pbx_tenants;$invite=$_POST['invite']??$_GET['invite']??'';$tenant=$portal->invitation($invite);$error='';
if($_SERVER['REQUEST_METHOD']==='POST') {
 try {
  if(!(new token)->validate('/app/tenant_services/accept.php')){http_response_code(403);throw new RuntimeException('This form expired. Refresh the invitation and try again.');}
  if(($_POST['password']??'')!==($_POST['confirm_password']??''))throw new InvalidArgumentException('The passwords do not match.');
  $portal->accept($invite,$_POST['password']??'');header('Location: /login.php');exit;
 }catch(PDOException $e){$error='This invitation could not be accepted. Please contact your administrator.';error_log('OpenWeb PBX invitation error: '.$e->getCode());}
 catch(Throwable $e){$error=$e->getMessage();}
}
$formToken=(new token)->create('/app/tenant_services/accept.php');$e=fn($v)=>htmlspecialchars((string)$v,ENT_QUOTES,'UTF-8');
?>
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Join your workspace · OpenWeb PBX</title><link rel="icon" href="/themes/default/images/openweb-mark.svg"><link rel="stylesheet" href="/app/tenant_services/workspace.css?v=1"></head><body class="invite-page"><main class="invite-card"><img src="/themes/default/images/openweb-logo.svg" alt="OpenWeb PBX" width="260">
<?php if($tenant): ?><h1>Welcome to <?= $e($tenant['tenant_name']) ?></h1><p>Create your administrator password to join the workspace.</p><p class="invite-email"><?= $e($tenant['invite_email']) ?></p><?php if($error): ?><div class="portal-message error" role="alert"><?= $e($error) ?></div><?php endif; ?><form method="post" class="portal-form"><input type="hidden" name="<?= $e($formToken['name']) ?>" value="<?= $e($formToken['hash']) ?>"><input type="hidden" name="invite" value="<?= $e($invite) ?>"><label>Password<input type="password" name="password" autocomplete="new-password" minlength="10" maxlength="72" required></label><label>Confirm password<input type="password" name="confirm_password" autocomplete="new-password" minlength="10" maxlength="72" required></label><button type="submit" class="portal-button primary">Join workspace</button></form><?php else: ?><h1>Invitation unavailable</h1><p>This invitation has expired or has already been accepted. Contact the platform administrator for help.</p><a href="/login.php" class="portal-button primary">Sign in</a><?php endif; ?></main></body></html>
