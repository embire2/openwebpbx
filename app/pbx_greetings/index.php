<?php
require_once dirname(__DIR__,2).'/resources/require.php';require_once PROJECT_ROOT.'/resources/check_auth.php';
header('Cache-Control: no-store');header('Referrer-Policy: no-referrer');
$error='';$notice=(string)($_SESSION['pbx_greeting_notice']??'');unset($_SESSION['pbx_greeting_notice']);$items=[];$config=[];$installed=false;$company='';$readiness=['ready'=>false,'message'=>'Greetings is not installed.'];
try{
    $greetings=new pbx_greetings;$installed=$greetings->installed();
    if(!$installed)throw new RuntimeException('Greetings setup is not complete on this server.');
    $items=$greetings->all();$config=$greetings->config();$company=$greetings->companyName();$readiness=$greetings->readiness();
    if(($_SERVER['REQUEST_METHOD']??'')==='POST'){
        if(!(new token)->validate('/app/pbx_greetings/')){http_response_code(403);throw new DomainException('Your form expired. Refresh this page.');}
        $id=$_POST['id']??'';if(!is_string($id))throw new InvalidArgumentException('Choose a greeting.');
        $action=$_POST['action']??'';
        if($action==='create'){$greetings->create($_POST);$notice='Greeting requested. Keoma will prepare the audio; a phone recording starts when its instructions are ready.';}
        elseif($action==='rename'){$greetings->rename($id,$_POST);$notice='Greeting name saved.';}
        elseif($action==='assign'){$kind=$_POST['kind']??'';$targets=$_POST['targets']??[];if(!is_string($kind)||!is_array($targets))throw new InvalidArgumentException('Choose greeting destinations.');$greetings->assign($id,$kind,$targets);$notice='Greeting assigned. Previous custom greeting files were preserved.';}
        elseif($action==='unassign'){$kind=$_POST['kind']??'';$target=$_POST['target']??'';if(!is_string($kind)||!is_string($target))throw new InvalidArgumentException('Choose an assignment.');$greetings->unassign($id,$kind,$target);$notice='Assignment removed. The destination uses its default audio unless another greeting was selected elsewhere. All recordings were preserved.';}
        elseif(in_array($action,['cancel','retry','archive'],true)){$greetings->action($id,$action);$notice='Greeting updated.';}
        else throw new InvalidArgumentException('Choose a greeting action.');
        // Do not replay a phone-recording request when the user refreshes the page.
        $_SESSION['pbx_greeting_notice']=$notice;header('Location: /app/pbx_greetings/');exit;
    }
    $items=$greetings->all();$config=$greetings->config();$company=$greetings->companyName();$readiness=$greetings->readiness();
}catch(DomainException $ex){http_response_code(403);$error=$ex->getMessage();}
catch(InvalidArgumentException|OverflowException $ex){http_response_code(400);$error=$ex->getMessage();}
catch(Throwable){http_response_code(503);$error='Greetings are not ready. Ask your instance administrator to finish installing this service.';}
$e=static fn($s)=>htmlspecialchars((string)$s,ENT_QUOTES,'UTF-8');$form=(new token)->create('/app/pbx_greetings/');
$csrf=static function()use($form,$e){echo '<input type="hidden" name="'.$e($form['name']).'" value="'.$e($form['hash']).'">';};
$document['title']='Greetings';require_once PROJECT_ROOT.'/resources/header.php';
?>
<link rel="stylesheet" href="/app/pbx_setup/setup.css?v=4"><link rel="stylesheet" href="/app/pbx_greetings/greetings.css?v=1">
<script defer src="/app/pbx_greetings/greetings.js?v=1"></script>
<main class="pbx-setup"><header class="setup-heading"><div><span class="setup-eyebrow">OPENWEB PBX</span><h1>Greetings</h1><p>Record once. Use it wherever callers need to hear it.</p></div><a class="setup-button" href="/app/pbx_setup/">Admin</a></header>
<?php if($error): ?><div class="setup-message error" role="alert"><?= $e($error) ?></div><?php endif; ?>
<?php if($notice): ?><div class="setup-message" role="status"><?= $e($notice) ?></div><?php endif; ?>
<?php if($installed&&$config): ?>
<div class="setup-message <?= $readiness['ready']?'':'warning' ?>" role="status" data-greeting-readiness><?= $e($readiness['message']) ?></div>
<section class="setup-card"><h2>Create Greeting</h2><form method="post" class="setup-form" data-create-greeting><?php $csrf(); ?><input type="hidden" name="action" value="create">
<div class="form-grid"><label>Greeting category<select name="category" required><?php foreach(pbx_greetings::CATEGORIES as $key=>$label): ?><option value="<?= $e($key) ?>"><?= $e($label) ?></option><?php endforeach; ?></select></label><label>Name (optional)<input name="name" maxlength="120" placeholder="A unique name is created if left blank"></label><label>Company name<input name="company_name" maxlength="120" value="<?= $e($company) ?>" required></label><label>Create using<select name="source" data-greeting-source><option value="phone">Call a phone to record</option><option value="text">Let Keoma read my text</option></select></label></div>
<div data-record-phone><div class="form-grid"><label>Number to call<input name="target_number" maxlength="20" inputmode="tel" placeholder="Extension or outside number"></label><label>Calling extension<select name="caller_extension"><?php foreach($config['users']??[] as $number=>$u)if(!empty($u['enabled'])): ?><option value="<?= $e($number) ?>"><?= $e($number.' · '.$u['name']) ?></option><?php endif; ?></select></label></div><p class="setup-hint">Answer the phone, listen to Keoma, record after the tone and press <strong>#</strong>. Your greeting is replayed before it is saved. Outside calls follow the selected extension’s normal calling rules and provider charges. The call rings for up to 45 seconds; recordings can last up to five minutes.</p></div>
<div data-record-text hidden><label>Your greeting<textarea name="script" maxlength="3000" rows="5" placeholder="Type exactly what callers should hear."></textarea></label><p class="setup-hint">Keoma creates the recording. There is no OpenWebPBX charge; generation uses your instance’s configured ElevenLabs allowance. Text is sent to the voice provider. Phone recordings stay on your PBX.</p></div>
<button class="setup-button primary" data-create-greeting-button <?= $readiness['ready']?'':'disabled' ?>>Create Greeting</button></form></section>
<section class="setup-card"><div class="greeting-heading"><h2>Your Greetings</h2><label>Show category<select data-greeting-filter><option value="">All greetings</option><?php foreach(pbx_greetings::CATEGORIES as $key=>$label): ?><option value="<?= $e($key) ?>"><?= $e($label) ?></option><?php endforeach; ?></select></label></div>
<p class="setup-hint">Rename, listen, download or assign ready greetings. Every recording has its own unique file; existing custom messages are never overwritten. Archive removes an unused greeting from this list while retaining its audio for your retention policy.</p>
<?php foreach($items as $item)if($item['state']!=='archived'): $id=$item['greeting_uuid']; ?>
<article class="greeting-item" data-greeting-id="<?= $e($id) ?>" data-greeting-category="<?= $e($item['category']) ?>"><div class="greeting-heading"><div><h3><?= $e($item['name']) ?></h3><p><?= $e(pbx_greetings::CATEGORIES[$item['category']]) ?> · <?= $item['source']==='text'?'Keoma':'Phone recording' ?></p></div><strong data-greeting-state><?= $e(ucwords(str_replace('_',' ',$item['state']))) ?></strong></div><p role="status" data-greeting-result><?= $e($item['last_result']) ?></p>
<audio preload="none" controls src="/app/pbx_greetings/media.php?id=<?= $e($id) ?>" data-greeting-audio <?= $item['state']==='ready'?'':'hidden' ?>></audio><a class="setup-button" href="/app/pbx_greetings/media.php?id=<?= $e($id) ?>&amp;download=1" data-greeting-download <?= $item['state']==='ready'?'':'hidden' ?>>Download WAV</a>
<details><summary>Rename</summary><form method="post" class="setup-form"><?php $csrf(); ?><input type="hidden" name="id" value="<?= $e($id) ?>"><input type="hidden" name="action" value="rename"><label>Name<input name="name" maxlength="120" required value="<?= $e($item['name']) ?>"></label><button class="setup-button">Save Name</button></form></details>
<details data-greeting-assign <?= $item['state']==='ready'?'':'hidden' ?>><summary>Use this greeting</summary><form method="post" class="setup-form"><?php $csrf(); ?><input type="hidden" name="id" value="<?= $e($id) ?>"><input type="hidden" name="action" value="assign">
<?php $kinds=match($item['category']){'voicemail'=>['voicemail'=>'Voicemail'],'receptionist'=>['receptionist'=>'Digital Receptionist'],'queue_intro'=>['queue_intro'=>'Queue welcome'],'queue_wait'=>['queue_wait'=>'Queue waiting announcement'],'hold_music'=>['hold_music'=>'Queue music on hold','extension_hold'=>'Extension music on hold'],default=>['queue_intro'=>'Queue welcome','queue_wait'=>'Queue announcement']}; ?>
<label>Use as<select name="kind" data-assignment-kind><?php foreach($kinds as $kind=>$label): ?><option value="<?= $e($kind) ?>"><?= $e($label) ?></option><?php endforeach; ?></select></label>
<label>Destinations <small>Choose one or more.</small><select name="targets[]" multiple size="5" required data-assignment-targets><?php
$options=[];if(in_array($item['category'],['voicemail','hold_music'],true))foreach($config['users']??[] as $n=>$u)if(!empty($u['enabled']))$options[]=['kind'=>'users','number'=>$n,'name'=>$u['name']];
if($item['category']==='receptionist')foreach($config['receptionists']??[] as $r)$options[]=['kind'=>'receptionists','number'=>$r['number'],'name'=>$r['name']];
if(in_array($item['category'],['queue_intro','queue_wait','hold_music','announcement'],true))foreach($config['queues']??[] as $r)$options[]=['kind'=>'queues','number'=>$r['number'],'name'=>$r['name']];
foreach($options as $option): ?><option data-target-kind="<?= $e($option['kind']) ?>" value="<?= $e($option['number']) ?>"><?= $e($option['number'].' · '.$option['name']) ?></option><?php endforeach; ?></select></label><button class="setup-button primary">Assign Greeting</button></form></details>
<?php if($item['state']==='ready'&&$item['uses']): ?><details><summary>Current assignments</summary><p class="setup-hint">Removing an assignment selects default audio only if this greeting is still selected. It never removes another greeting chosen elsewhere.</p><?php foreach($greetings->uses($id) as $use): ?><form method="post" class="setup-actions"><?php $csrf(); ?><input type="hidden" name="id" value="<?= $e($id) ?>"><input type="hidden" name="action" value="unassign"><input type="hidden" name="kind" value="<?= $e($use['kind']) ?>"><input type="hidden" name="target" value="<?= $e($use['target_number']) ?>"><span><?= $e(ucwords(str_replace('_',' ',$use['kind'])).' · '.$use['target_number']) ?></span><button class="setup-button">Remove Assignment</button></form><?php endforeach; ?></details><?php endif; ?>
<form method="post" class="setup-actions greeting-actions"><?php $csrf(); ?><input type="hidden" name="id" value="<?= $e($id) ?>"><button class="setup-button" name="action" value="cancel" data-greeting-cancel <?= in_array($item['state'],['pending','preparing','ready_to_call'],true)?'':'hidden' ?>>Cancel Request</button><button class="setup-button" name="action" value="retry" data-greeting-retry <?= $item['state']==='failed'?'':'hidden' ?>>Retry</button><button class="setup-button" name="action" value="archive" data-greeting-archive <?= in_array($item['state'],['ready','failed','cancelled'],true)?'':'hidden' ?>>Archive</button></form>
</article><?php endif; ?>
<?php if(!$items): ?><p>Create your first greeting above.</p><?php endif; ?></section><?php endif; ?></main>
<?php require_once PROJECT_ROOT.'/resources/footer.php'; ?>
