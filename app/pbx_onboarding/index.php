<?php
require_once dirname(__DIR__,2).'/resources/require.php';
require_once PROJECT_ROOT.'/resources/check_auth.php';
header('Cache-Control: no-store');header('Referrer-Policy: no-referrer');header('X-Content-Type-Options: nosniff');
if(!in_array($_SERVER['HTTPS']??'',['on','1'],true)){http_response_code(403);exit('Open this setup page using the secure HTTPS address.');}
$escape=static fn(mixed $value): string=>htmlspecialchars((string)$value,ENT_QUOTES|ENT_SUBSTITUTE,'UTF-8');
$error='';$notice=$_SESSION['openweb_onboarding_notice']??'';unset($_SESSION['openweb_onboarding_notice']);
$accountMode=($_GET['mode']??'')==='signin'?'signin':((($_GET['mode']??'')==='register')?'register':'auto');
try{
    $list=(new pbx_onboarding($database->db))->services();
    if(!$list)throw new pbx_onboarding_denied('Sign in as a PBX owner to complete this setup.');
    $chosen=$_POST['service_uuid']??$_GET['service_uuid']??$_SESSION['openweb_onboarding_service']??'';
    if(!is_string($chosen))throw new pbx_onboarding_denied('Choose a PBX that you own.');
    $ids=array_column($list,'service_uuid');
    if($chosen===''){
        foreach($list as $service)if($service['domain_uuid']===($_SESSION['domain_uuid']??'')){$chosen=$service['service_uuid'];break;}
        if($chosen===''&&count($list)===1)$chosen=$list[0]['service_uuid'];
    }
    if($chosen!==''&&!in_array($chosen,$ids,true))throw new pbx_onboarding_denied('Choose a PBX that you own.');
    $onboarding=$chosen!==''?new pbx_onboarding($database->db,$chosen):null;
    if(($_SERVER['REQUEST_METHOD']??'')==='POST'){
        if((int)($_SERVER['CONTENT_LENGTH']??0)>8192||strlen(http_build_query($_POST))>8192){http_response_code(413);throw new InvalidArgumentException('Keep this setup form short and try again.');}
        if(isset($_SERVER['HTTP_ORIGIN'])){
            $origin=parse_url((string)$_SERVER['HTTP_ORIGIN']);$host=parse_url('https://'.(string)($_SERVER['HTTP_HOST']??''));
            if(!$origin||!$host||($origin['scheme']??'')!=='https'||strtolower($origin['host']??'')!==strtolower($host['host']??'')||($origin['port']??443)!==($host['port']??443)||isset($origin['user'])||isset($origin['pass'])||isset($origin['query'])||isset($origin['fragment'])||isset($origin['path'])){http_response_code(403);throw new pbx_onboarding_denied('Refresh this setup page before trying again.');}
        }
        // Require the actual POST field; token::validate also supports legacy
        // request values, which are deliberately not accepted by this wizard.
        $formKey='/app/pbx_onboarding/index.php';$csrfValid=false;
        foreach($_SESSION['tokens'][$formKey]??[]as$entry)if(is_string($_POST[$entry['name']]??null)&&hash_equals($entry['hash'],$_POST[$entry['name']])){$csrfValid=true;break;}
        if(!$csrfValid||!(new token)->validate($formKey)){http_response_code(403);throw new pbx_onboarding_denied('Your form expired. Refresh the page and try again.');}
        if(!$onboarding)throw new InvalidArgumentException('Choose your PBX before continuing.');
        $action=$_POST['action']??'';
        if(!is_string($action))throw new InvalidArgumentException('Choose an action.');
        switch($action){
            case 'select':break;
            case 'register':$onboarding->register(['tenant_name'=>$_POST['tenant_name']??'','slug'=>$_POST['slug']??'','email'=>$_POST['email']??'','password'=>$_POST['password']??'','accept_terms'=>($_POST['accept_terms']??'')==='true']);$_SESSION['openweb_onboarding_notice']='Check your inbox and spam folder for your verification code.';break;
            case 'verify':$onboarding->verify(['token'=>$_POST['verification_code']??'','password'=>$_POST['password']??'']);$_SESSION['openweb_onboarding_notice']='Your email is confirmed. Choose the address for this PBX.';break;
            case 'signin':$onboarding->signIn(['email'=>$_POST['email']??'','password'=>$_POST['password']??'']);$_SESSION['openweb_onboarding_notice']='You are signed in to your OpenWeb account.';break;
            case 'request_email_code':$onboarding->requestEmailCode();$_SESSION['openweb_onboarding_notice']='Check your email for your confirmation code.';break;
            case 'verify_email':$onboarding->verifyAccountEmail(['token'=>$_POST['verification_code']??'','password'=>$_POST['password']??'']);$_SESSION['openweb_onboarding_notice']='Your email is confirmed. You can continue setup.';break;
            case 'connect':$onboarding->queue(['label'=>$_POST['label']??'']);$_SESSION['openweb_onboarding_notice']='Your server registration is queued. This page will show when its secure address is ready.';break;
            case 'finish':if(!$onboarding->status()['ready'])throw new InvalidArgumentException('Wait until this PBX registration and secure address are ready.');(new pbx_tenants($database->db))->switchService($chosen);header('Location: /core/desktop/');exit;
            default:throw new InvalidArgumentException('Choose an action.');
        }
        $_SESSION['openweb_onboarding_service']=$chosen;header('Location: /app/pbx_onboarding/?service_uuid='.rawurlencode($chosen));exit;
    }
    if(!in_array($_SERVER['REQUEST_METHOD']??'',['GET','HEAD'],true)){header('Allow: GET, HEAD, POST');http_response_code(405);exit('Choose a supported action.');}
    $status=$onboarding?$onboarding->status():null;
    if(($_GET['format']??'')==='json'){
        header('Content-Type: application/json; charset=utf-8');if(!$status){http_response_code(400);echo json_encode(['error'=>'Choose a PBX first.']);exit;}
        echo json_encode($status,JSON_THROW_ON_ERROR|JSON_UNESCAPED_SLASHES);exit;
    }
}catch(pbx_onboarding_denied $ex){http_response_code(403);if(($_GET['format']??'')==='json'){header('Content-Type: application/json; charset=utf-8');echo json_encode(['error'=>'Sign in again as the PBX owner.']);exit;}$error=$ex->getMessage();if(!isset($list)||!$list)exit($escape($error));}
catch(InvalidArgumentException|pbx_onboarding_pending $ex){$error=$ex->getMessage();}
catch(Throwable $ex){error_log('OpenWeb PBX local account setup failed ('.get_class($ex).').');$error='Setup could not be checked. Try again shortly or ask your instance administrator.';}
if(!isset($status)&&isset($onboarding)&&$onboarding){try{$status=$onboarding->status();}catch(Throwable){$status=null;}}
if(($_GET['format']??'')==='json'){header('Content-Type: application/json; charset=utf-8');http_response_code(503);echo json_encode(['error'=>'Setup could not be checked. Try again shortly.']);exit;}
$list??=[];$chosen??='';$status??=null;
$formToken=(new token)->create('/app/pbx_onboarding/index.php');
$fields=static function(string $action)use($formToken,$escape,$chosen): void {echo '<input type="hidden" name="'.$escape($formToken['name']).'" value="'.$escape($formToken['hash']).'"><input type="hidden" name="action" value="'.$escape($action).'">';if($chosen!=='')echo '<input type="hidden" name="service_uuid" value="'.$escape($chosen).'">';};
$connected=(bool)($status['account_connected']??false);$ready=(bool)($status['ready']??false);$pending=($status['state']??'')==='account_pending';$needsEmail=(bool)($status['needs_email_verification']??false);$needsSignIn=(bool)($status['needs_sign_in']??false);
$step=$ready?4:($needsSignIn?1:($needsEmail||($pending&&!$connected)?2:($connected?3:1)));if(in_array($status['state']??'',['queued','preparing','retry'],true)&&!$needsEmail&&!$needsSignIn)$step=4;
$document['title']='Connect your PBX · OpenWeb';require_once PROJECT_ROOT.'/resources/header.php';
?>
<link rel="stylesheet" href="/app/pbx_setup/setup.css?v=5">
<link rel="stylesheet" href="/app/pbx_onboarding/onboarding.css?v=1">
<script src="/app/pbx_onboarding/onboarding.js?v=1" defer></script>
<main class="pbx-setup onboarding" data-onboarding data-service="<?= $escape($chosen) ?>" data-pending="<?= $status&&!$ready&&$connected?'true':'false' ?>" data-needs-email="<?= $needsEmail?'true':'false' ?>" data-needs-signin="<?= $needsSignIn?'true':'false' ?>">
 <header class="setup-heading"><div><span class="setup-eyebrow">OPENWEB PBX · WELCOME</span><h1>Connect your PBX</h1><p>Your calls stay on this server. Your OpenWeb account gives it a secure tenant address.</p></div><span class="onboarding-brand"><img src="/themes/default/images/openweb-logo.svg" alt="OpenWeb PBX" width="190"></span></header>
 <ol class="onboarding-steps" aria-label="Setup progress"><?php foreach(['Your account','Confirm email','Your address','Ready to use']as$i=>$title): ?><li class="<?= $step===$i+1?'current':($step>$i+1?'complete':'') ?>" <?= $step===$i+1?'aria-current="step"':'' ?>><span><?= $i+1 ?></span><?= $escape($title) ?></li><?php endforeach; ?></ol>
 <?php if($error): ?><p class="setup-message error" role="alert"><?= $escape($error) ?></p><?php endif; ?>
 <?php if($notice): ?><p class="setup-message" role="status"><?= $escape($notice) ?></p><?php endif; ?>
 <?php if(!$chosen): ?>
 <section class="setup-card"><h2>Which PBX are you connecting?</h2><p>Choose one of your local PBX services.</p><form method="post" class="setup-form"><?php $fields('select'); ?><label>PBX<select name="service_uuid" required><?php foreach($list as$service): ?><option value="<?= $escape($service['service_uuid']) ?>"><?= $escape($service['tenant_name'].' · '.$service['service_name']) ?></option><?php endforeach; ?></select></label><button class="setup-button primary" type="submit">Continue</button></form></section>
 <?php elseif(!$status): ?>
 <section class="setup-card"><h2>We could not check this PBX yet</h2><p>Wait a moment and refresh. Your users and calling settings are unchanged.</p><a class="setup-button" href="?service_uuid=<?= $escape($chosen) ?>">Check again</a></section>
 <?php else: ?>
 <section class="setup-card onboarding-summary"><div><span class="setup-eyebrow">YOUR LOCAL PBX</span><h2><?= $escape($status['service_name']) ?></h2><p><?= $escape($status['tenant_name']) ?></p></div><span class="setup-state <?= $ready?'done':'' ?>" data-onboarding-badge><?= $ready?'Connected':'Setup in progress' ?></span></section>
 <section class="setup-card onboarding-finished" data-finished <?= !$ready?'hidden':'' ?>><span class="onboarding-check" aria-hidden="true">✓</span><h2>Your PBX is ready</h2><p>Its registration is confirmed and its secure tenant address is ready. Your PBX administrator sign-in stays the same.</p><p><a class="onboarding-address" data-tenant-address href="<?= $escape($status['url']??'#') ?>"><?= $escape($status['url']??'') ?></a></p><form method="post"><?php $fields('finish'); ?><button class="setup-button primary" type="submit">Open my PBX</button></form></section>
 <?php if(!$ready): ?>
  <?php if(!$connected&&!$pending||$needsSignIn||$accountMode==='signin'||($accountMode==='register'&&!$connected)): ?>
  <section class="setup-card" data-onboarding-stage><div class="onboarding-tabs"><?php if(!$connected): ?><a class="<?= $accountMode!=='signin'&&!$needsSignIn?'selected':'' ?>" href="?service_uuid=<?= $escape($chosen) ?>&amp;mode=register">Create an account</a><?php endif; ?><a class="<?= $accountMode==='signin'||$needsSignIn?'selected':'' ?>" href="?service_uuid=<?= $escape($chosen) ?>&amp;mode=signin">I already have an account</a></div>
  <?php if($accountMode==='signin'||$needsSignIn): ?>
   <h2>Sign in to your OpenWeb account</h2><p>Use your organisation’s OpenWeb account. This does not change your local PBX password.</p><form method="post" class="setup-form"><?php $fields('signin'); ?><label>Account email<input type="email" name="email" autocomplete="username" maxlength="254" required value="<?= $escape($status['account_email']) ?>"></label><label>Account password<input type="password" name="password" autocomplete="current-password" maxlength="72" required></label><button type="submit" class="setup-button primary">Sign in</button></form>
  <?php else: ?>
   <h2>Create your OpenWeb account</h2><p>Choose the account your organisation will use to register this server.</p><form method="post" class="setup-form"><?php $fields('register'); ?><div class="setup-fields"><label>Company name<input name="tenant_name" maxlength="120" autocomplete="organization" required value="<?= $escape($status['tenant_name']) ?>"></label><label>Company short name<input name="slug" maxlength="40" minlength="3" pattern="[a-z0-9][a-z0-9-]{1,38}[a-z0-9]" placeholder="your-company" autocapitalize="none" spellcheck="false" required><small>3–40 lowercase letters, numbers or hyphens.</small></label></div><label>Administrator email<input type="email" name="email" autocomplete="username" maxlength="254" required value="<?= $escape($status['account_email']) ?>"></label><label>Choose an account password<input type="password" name="password" autocomplete="new-password" maxlength="72" required><small>12–72 bytes, including a letter and a number. Your PBX administrator password stays unchanged.</small></label><label class="setup-check-label"><input type="checkbox" name="accept_terms" value="true" required><span>I accept the <a href="https://openwebpbx.com/terms" target="_blank" rel="noopener noreferrer">terms</a> and <a href="https://openwebpbx.com/privacy" target="_blank" rel="noopener noreferrer">privacy policy</a>.</span></label><button class="setup-button primary" type="submit">Create account</button></form>
  <?php endif; ?></section>
  <?php elseif($pending&&!$connected||$needsEmail): ?>
  <section class="setup-card" data-onboarding-stage><h2>Confirm your email</h2><p><?= $pending?'Check your inbox and spam folder for the code sent to':'Request a confirmation code for' ?> <strong><?= $escape($status['account_email']) ?></strong>.</p><?php if($pending): ?><form method="post" class="setup-form"><?php $fields($needsEmail?'verify_email':'verify'); ?><label>Verification code<input name="verification_code" autocomplete="one-time-code" autocapitalize="none" spellcheck="false" maxlength="64" minlength="64" pattern="[a-f0-9]{64}" required></label><label>OpenWeb account password<input type="password" name="password" autocomplete="current-password" maxlength="72" required></label><button class="setup-button primary" type="submit">Confirm email</button></form><?php endif; ?><?php if($needsEmail): ?><form method="post" class="onboarding-secondary"><?php $fields('request_email_code'); ?><button class="setup-button <?= $pending?'':'primary' ?>" type="submit"><?= $pending?'Send a new code':'Send verification code' ?></button></form><?php else: ?><p class="setup-hint">The code lasts 30 minutes. A new request replaces the old code.</p><div class="setup-actions"><a class="setup-button" href="?service_uuid=<?= $escape($chosen) ?>&amp;mode=register">Create account request again</a><a class="setup-button" href="?service_uuid=<?= $escape($chosen) ?>&amp;mode=signin">Sign in instead</a></div><?php endif; ?></section>
  <?php elseif(!$status['registration_confirmed']||$status['can_request_registration']): ?>
  <section class="setup-card" data-onboarding-stage><h2>Choose your tenant address</h2><p>Your OpenWeb account is <strong><?= $escape($status['account_email']) ?></strong>. The address will connect your users to this local PBX.</p><form method="post" class="setup-form"><?php $fields('connect'); ?><label>Tenant short name<span class="onboarding-host"><input name="label" minlength="3" maxlength="40" pattern="[a-z0-9][a-z0-9-]{1,38}[a-z0-9]" autocapitalize="none" spellcheck="false" required value="<?= $escape($status['requested_label']) ?>"><span>.openwebpbx.com</span></span><small>Keep an existing reserved short name. If a name is already used elsewhere, OpenWeb may assign a stable suffix.</small></label><button class="setup-button primary" type="submit" data-connect <?= !$status['identity_ready']?'disabled':'' ?>><?= in_array($status['state'],['queued','preparing','retry'],true)?'Check and retry setup':'Connect this PBX' ?></button></form><?php if(!$status['identity_ready']): ?><p class="setup-hint">This server is preparing its secure connection. Wait a moment and check again.</p><?php endif; ?><a class="onboarding-account-link" href="?service_uuid=<?= $escape($chosen) ?>&amp;mode=signin">Sign in to this OpenWeb account again</a></section>
  <?php else: ?><section class="setup-card" data-onboarding-stage><h2>Your registration is confirmed</h2><p>Your OpenWeb account is linked to this local PBX. We are preparing its secure tenant address.</p></section>
  <?php endif; ?>
 <section class="setup-card onboarding-progress" data-progress><div class="onboarding-pulse" aria-hidden="true"></div><div><h2>Server registration</h2><p data-onboarding-message role="status"><?= $escape($status['message']) ?></p><p class="setup-hint">DNS and the secure certificate are checked in the background. Setup finishes only after this server and its tenant address are confirmed.</p><p data-poll-help hidden>We could not get a fresh status. Your setup is retained; use Check again.</p><a class="setup-button" href="?service_uuid=<?= $escape($chosen) ?>">Check again</a></div></section>
 <?php endif; ?>
 <?php endif; ?>
 <p class="onboarding-help">Your PBX runs on this machine. OpenWeb keeps the tenant address registered to this installation. <a href="https://openwebpbx.com/api-docs" target="_blank" rel="noopener noreferrer">API documentation</a> · <a href="https://openwebpbx.com/privacy" target="_blank" rel="noopener noreferrer">Privacy</a></p>
 <noscript><p class="setup-message">The forms work without JavaScript. Use Check again to see when the tenant address is ready.</p></noscript>
</main>
<?php require_once PROJECT_ROOT.'/resources/footer.php'; ?>
