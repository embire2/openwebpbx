<?php
require_once dirname(__DIR__,2).'/resources/require.php';
require_once PROJECT_ROOT.'/resources/check_auth.php';
$windows=new pbx_windows_phone_updates;
if(!$windows->canView()){http_response_code(403);exit('Access denied.');}
header('Cache-Control: no-store');header('Referrer-Policy: no-referrer');
$error='';$notice='';$tenant=is_string($_GET['tenant']??null)?$_GET['tenant']:'';
try{
 $tenants=$windows->tenants();if($tenant===''&&$tenants)$tenant=$tenants[0]['tenant_uuid'];
 if(($_SERVER['REQUEST_METHOD']??'')==='POST'){$windows->saveBrowserRequest($tenant,$_POST);$notice='Windows phone settings saved.';}
 $policy=$tenant!==''?$windows->tenantPolicy($tenant):null;$instance=$windows->instanceAdmin()?$windows->instancePolicy():null;
}catch(DomainException $ex){http_response_code(403);$error=$ex->getMessage();}catch(InvalidArgumentException $ex){http_response_code(400);$error=$ex->getMessage();}catch(Throwable){http_response_code(503);$error='Windows phone settings are not ready. Ask the instance administrator to finish the client integration.';}
$e=static fn($value)=>htmlspecialchars((string)$value,ENT_QUOTES,'UTF-8');$form=(new token)->create(pbx_windows_phone_updates::FORM);$csrf=static function()use($e,$form){echo '<input type="hidden" name="'.$e($form['name']).'" value="'.$e($form['hash']).'">';};
$document['title']='Windows phone updates';require_once PROJECT_ROOT.'/resources/header.php';
?>
<link rel="stylesheet" href="/app/pbx_setup/setup.css?v=4"><link rel="stylesheet" href="/app/pbx_updates/updates.css?v=1">
<main class="pbx-setup"><header class="setup-heading"><div><span class="setup-eyebrow">OPENWEB PBX</span><h1>Windows phone updates</h1><p>Separate settings for OpenWebPBX Free Phone on Windows.</p></div><a class="setup-button" href="/app/pbx_updates/">All updates</a></header>
<?php if($error):?><div class="setup-message error" role="alert"><?=$e($error)?></div><?php endif;?>
<?php if($notice):?><div class="setup-message" role="status"><?=$e($notice)?></div><?php endif;?>
<section class="setup-card"><h2>Windows phone release</h2><p>No Windows phone release has been published through this integration yet. Saved tenant choices will apply when a compatible signed release becomes available. There is no download to require now.</p><p>Microsoft Store installations use Store delivery. Direct installations use their own verified Windows Phone update channel. These settings never update the PBX server or Android app; active calls must finish before client installation.</p></section>
<?php if(isset($instance)):?><section class="setup-card"><h2>Minimum Windows phone release</h2><form method="post" class="setup-form"><?php $csrf();?><input type="hidden" name="action" value="save_instance"><label>Minimum release for this instance<input name="minimum_version" value="<?=$e($instance['minimum_version'])?>" maxlength="17" autocomplete="off" placeholder="No requirement"></label><p>Leave this blank until a Windows phone release has been published and verified. An instance requirement cannot use the Android or PBX server version.</p><button class="setup-button primary">Save minimum release</button></form></section><?php endif;?>
<section class="setup-card"><h2>Tenant download choice</h2>
<?php if(!empty($tenants)):?><form method="get" class="setup-form"><label>Tenant<select name="tenant"><?php foreach($tenants as$item):?><option value="<?=$e($item['tenant_uuid'])?>" <?=$tenant===$item['tenant_uuid']?'selected':''?>><?=$e($item['tenant_name'])?></option><?php endforeach;?></select></label><button class="setup-button">Open tenant</button></form><?php else:?><p>Create a tenant before choosing its Windows phone update behaviour.</p><?php endif;?>
<?php if(isset($policy)&&$policy):?><form method="post" class="setup-form"><?php $csrf();?><input type="hidden" name="action" value="save_tenant"><fieldset class="update-options"><legend>When an available release is verified</legend><?php foreach(['notify'=>['Let users choose','Show the available update.'],'download'=>['Download automatically','Download first; let the user choose when to install.'],'required'=>['Require the update','Make the verified update prominent and finish calls before installation.']]as$value=>$option):?><label class="update-option"><input type="radio" name="mode" value="<?=$e($value)?>" <?=$policy['mode']===$value?'checked':''?>><span><strong><?=$e($option[0])?></strong><small><?=$e($option[1])?></small></span></label><?php endforeach;?></fieldset><p>Store and enterprise delivery rules still apply. A tenant policy cannot force a private installer into the Store edition or weaken an instance minimum.</p><button class="setup-button primary">Save Windows phone settings</button></form><?php endif;?></section></main>
<?php require_once PROJECT_ROOT.'/resources/footer.php';?>
