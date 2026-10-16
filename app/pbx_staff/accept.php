<?php
require_once dirname(__DIR__,2).'/resources/require.php';
header('Cache-Control: no-store');header('Referrer-Policy: no-referrer');header('X-Content-Type-Options: nosniff');
$a=new pbx_staff_accounts;$invite=is_string($_GET['invite']??null)?$_GET['invite']:($_SESSION['pbx_staff_invite']??'');
if(is_string($_GET['invite']??null)){if(!preg_match('/^[a-f0-9]{64}$/D',$invite)){http_response_code(404);exit('Invitation unavailable.');}$_SESSION['pbx_staff_invite']=$invite;header('Location: /app/pbx_staff/accept.php');exit;}
$error='';$done=false;
if($_SERVER['REQUEST_METHOD']==='POST')try{if(!(new token)->validate('/app/pbx_staff/accept.php'))throw new RuntimeException('Refresh this page and try again.');$password=$_POST['password']??null;if(!is_string($password)||$password!==($_POST['confirm_password']??null))throw new InvalidArgumentException('The passwords must match.');$a->accept($invite,$password);unset($_SESSION['pbx_staff_invite']);$done=true;}catch(Throwable$e){$error=$e instanceof PDOException?'The invitation could not be accepted.':$e->getMessage();}
$r=$done?null:$a->invitation($invite);if(!$done&&!$r){http_response_code(404);exit('This invitation has expired or has already been used. Ask your administrator for a new invitation.');}
$e=fn($s)=>htmlspecialchars($s,ENT_QUOTES,'UTF-8');$t=(new token)->create('/app/pbx_staff/accept.php');$document['title']='Join OpenWeb PBX';require PROJECT_ROOT.'/resources/header.php';
?>
<link rel="stylesheet" href="/app/pbx_setup/setup.css?v=5"><main class="pbx-setup"><h1>Welcome to OpenWeb PBX</h1>
<?php if($done): ?><p>Your web account is ready. Your phone password has not changed.</p><a class="setup-button primary" href="/login.php">Sign In</a>
<?php else: ?><p>Create your web password for <?= $e($r['username']) ?>. This is separate from your phone password.</p><?php if($error): ?><p class="setup-message error" role="alert"><?= $e($error) ?></p><?php endif; ?>
<form method="post" class="setup-form"><input type="hidden" name="<?= $e($t['name']) ?>" value="<?= $e($t['hash']) ?>"><div class="setup-fields"><label>New Password<input type="password" name="password" autocomplete="new-password" minlength="12" maxlength="72" required></label><label>Confirm Password<input type="password" name="confirm_password" autocomplete="new-password" minlength="12" maxlength="72" required></label></div><button class="setup-button primary">Create My Account</button></form><?php endif; ?></main>
<?php require PROJECT_ROOT.'/resources/footer.php'; ?>
