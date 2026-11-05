<?php
if(!isset($admin,$view,$key)||$view!=='incoming'){http_response_code(404);exit;}
try{$didRoutes=new pbx_did_routes;}catch(PDOException){echo '<p class="setup-message error" role="alert">Incoming numbers are unavailable. Refresh the page and try again.</p>';return;}catch(RuntimeException $ex){echo '<p class="setup-message error" role="alert">'.$e($ex->getMessage()).'</p>';return;}
$didSchedule=static function(array $r,?array $callback=null): string {
    if($callback&&!empty($callback['enabled'])&&($callback['prompt_state']??'')==='ready')return 'Call Me Back · all day';
    $text=!empty($r['use_outside'])?'Office hours + closed-hours destination':'All day';
    return $text.(!empty($r['use_holiday'])?' · saved holiday route':'');
};
$didCurrent=static fn($current)=>is_array($current)?(string)($current['label']??'Unavailable'):(string)$current;
?>
<link rel="stylesheet" href="/app/pbx_setup/did-wizard.css?v=1.0.23">
<?php if($key===''):
    $didListing=$didRoutes->listing();$didConfig=$didListing['config'];$didNumbers=[];$didFallbacks=[];
    foreach($didListing['rows'] as $entry){if(($entry['rule']['condition']??'')==='ForwardAll'||trim((string)($entry['rule']['number']??''))==='')$didFallbacks[]=$entry;else $didNumbers[]=$entry;}
    $saved=is_string($_GET['saved']??null)?$_GET['saved']:'';
    foreach($didListing['rows'] as $entry)if($saved!==''&&$entry['rule']['rule_id']===$saved): ?>
        <p class="setup-message">Incoming number saved. <?php if(empty($entry['callback'])&&($entry['rule']['condition']??'')!=='ForwardAll'&&trim((string)$entry['rule']['number'])!==''): ?><a class="admin-link" href="?view=call_me_back&amp;service=new&amp;incoming=<?= $e($saved) ?>#cmb-service">Set up Call Me Back</a> if callers should receive a callback. Its current destination stays in use until you choose Call Me Back in this wizard.<?php elseif(!empty($entry['callback'])): ?><a class="admin-link" href="?view=call_me_back&amp;service=<?= $e($entry['callback']['service_uuid']) ?>#cmb-service">Manage Call Me Back</a>.<?php endif; ?></p>
    <?php endif;
    $toolbar($newLink('incoming','Add DID Number'));
    $didListRows=static function(array $entries)use($didConfig,$e,$editLink,$didCurrent,$didSchedule): array {
        $rows=[];foreach($entries as $entry){$r=$entry['rule'];$trunk=$didConfig['trunks'][$r['trunk_id']]??[];$callback=$entry['callback']??null;
            $state=empty($r['enabled'])?'Off':(empty($trunk['enabled'])?'Provider off':'Enabled');
            $schedule=is_array($entry['current'])&&($entry['current']['slot']??'')==='callback'?'Call Me Back · all day':$didSchedule($r);
            $rows[]=[$editLink('incoming',$r['rule_id'],(($r['condition']??'')==='ForwardAll'||$r['number']==='')?'Otherwise unassigned numbers':$r['number']).'<small class="did-row-note">'.$e($r['name']??'').'</small>',$e($trunk['name']??'Unavailable provider'),$e($didCurrent($entry['current'])),$e($schedule),'<span class="did-status '.($state==='Enabled'?'is-enabled':'is-off').'">'.$e($state).'</span>',$editLink('incoming',$r['rule_id'],'Edit')];
        }return $rows;
    };
    $table(['DID Number','Provider','Current destination','Schedule','Incoming calls',''],$didListRows($didNumbers));
    ?>
    <p class="setup-hint">Current destination follows this number’s saved schedule. A user’s own forwarding or availability may route the call further.</p>
    <?php if($didFallbacks): ?><details class="did-fallbacks"><summary>Fallback routes · <?= count($didFallbacks) ?></summary><p>These routes cover otherwise unassigned numbers on a provider. Individual DID numbers are listed above.</p><?php $table(['Fallback','Provider','Current destination','Schedule','Incoming calls',''],$didListRows($didFallbacks)); ?></details><?php endif; ?>
<?php return;endif;

$didRequestedTrunk=is_string($_GET['trunk']??null)?$_GET['trunk']:'';
try{$didEditor=$didRoutes->editor($key,$didRequestedTrunk);}catch(PDOException){echo '<p class="setup-message error" role="alert">The incoming number could not be opened. Refresh the page and try again.</p>';return;}catch(RuntimeException|InvalidArgumentException $ex){echo '<p class="setup-message error" role="alert">'.$e($ex->getMessage()).'</p>';return;}
$didConfig=$didEditor['config'];$didRule=$didEditor['rule'];$didNew=$key==='new';
$didFallback=!$didNew&&(($didRule['condition']??'')==='ForwardAll'||trim((string)($didRule['number']??''))==='');
$didPosted=($_SERVER['REQUEST_METHOD']==='POST'&&($_POST['action']??'')==='save_did');
$didValue=static function(string $name,string $default='')use($didPosted): string {return $didPosted&&is_string($_POST[$name]??null)?$_POST[$name]:$default;};
$normal=$didRule['office']??['type'=>'None','number'=>'','external'=>''];
$didDestination=$didValue('destination',(string)($didEditor['destination']??$didRule['destination']??(($normal['type']??'None').':'.($normal['number']??''))));
if($didNew&&!$didPosted)$didDestination='';
$didHours=$didValue('hours_mode',(string)($didRule['hours_mode']??(!empty($didRule['use_outside'])?'office':'always')));
$didOutside=$didRule['outside']??['type'=>'None','number'=>'','external'=>''];
$didChoices=[''=>'Choose where calls go']+$admin->destinations($didConfig);
foreach($didEditor['callbacks'] as $id=>$label)$didChoices['CallMeBack:'.$id]=$label;
if(!$didEditor['callbacks']&&!$didFallback)$didChoices['CallMeBack:setup']='Call Me Back (set up)';
$didTrunks=[''=>'Choose a provider'];foreach($didConfig['trunks'] as $id=>$trunk)$didTrunks[(string)$id]=$trunk['name'];
$didEnabled=$didPosted?(($_POST['enabled']??'')==='1'):(bool)($didRule['enabled']??true);
$didRevision=$didValue('revision',(string)$didEditor['revision']);
?>
<div class="did-intro"><h3><?= $didNew?'Add DID Number':($didFallback?'Edit provider fallback':'Edit DID Number') ?></h3><p>Choose the number and provider, decide where calls go, then review your changes.</p></div>
<?php if(!$didConfig['trunks']): ?><p class="setup-message warning">Add a SIP trunk before adding an incoming number. <a class="admin-link" href="?view=provider_setup&amp;edit=new">Add SIP Trunk</a></p><?php return;endif; ?>
<form method="post" class="setup-form did-wizard" data-did-wizard data-new-did="<?= $didNew?'true':'false' ?>" action="?view=incoming&amp;edit=<?= $e($key) ?><?= $didNew&&$didRequestedTrunk!==''?'&amp;trunk='.rawurlencode($didRequestedTrunk):'' ?>">
<?php $csrf(); ?><input type="hidden" name="action" value="save_did"><input type="hidden" name="revision" value="<?= $e($didRevision) ?>">
<ol class="did-progress" aria-label="Incoming number setup"><li data-did-progress="0">1. Number &amp; provider</li><li data-did-progress="1">2. Destination</li><li data-did-progress="2">3. Review &amp; save</li></ol>
<section class="did-step" data-did-step="0" aria-labelledby="did-step-number"><h3 id="did-step-number" tabindex="-1">1. Number &amp; provider</h3>
<?php if($didFallback): ?><p class="setup-message">This is a fallback for otherwise unassigned numbers on this provider. Its number stays empty; add an individual DID to route a specific telephone number.</p><?php endif; ?>
<div class="setup-fields"><?php
    $input('number','Telephone number',($didFallback?'':$didValue('number',(string)($didRule['number']??''))),'tel',$didFallback?'readonly placeholder="Otherwise unassigned numbers"':'required maxlength="60" pattern="\+?[0-9 \(\)\-]+" autocomplete="tel" placeholder="0800014509"');
    $select('trunk_id','Provider / SIP trunk',$didTrunks,$didValue('trunk_id',(string)($didRule['trunk_id']??'')),'required');
    $select('number_country','Number format',[''=>'Use current PBX setting','27'=>'South Africa (+27)','exact'=>'Use exactly what I enter'],$didValue('number_country',($didConfig['country_calling_code']??'')==='27'?'27':''));
    $input('name','Name (optional)',$didValue('name',(string)($didRule['name']??'')),'text','maxlength="100" placeholder="Reception"');
?></div><?php if(!empty($didRule['number_aliases'])): ?><p class="setup-hint">This same destination also receives calls for the previously saved provider number <?= $e(implode(', ',$didRule['number_aliases'])) ?>. There is one destination for all these number formats.</p><?php endif; ?><p class="setup-hint">Choose South Africa to recognize local and +27 numbers automatically. Use the current setting or exact numbers for other numbering countries. Existing saved number formats are retained. Leading zeros are kept. This does not change provider credentials or outgoing-call rules.</p>
<div class="setup-actions" data-did-navigation hidden><button type="button" class="setup-button primary" data-did-next>Continue</button><a class="setup-button" href="?view=incoming">Cancel</a></div></section>
<section class="did-step" data-did-step="1" aria-labelledby="did-step-destination"><h3 id="did-step-destination" tabindex="-1">2. Where should calls go?</h3>
<div class="setup-fields"><?php $select('destination','Destination',$didChoices,$didDestination,'required data-did-destination'); ?><div data-did-external><?php $input('external','External telephone number',$didValue('external',(string)($normal['external']??'')),'tel','maxlength="32" pattern="\+?[0-9]{1,32}" placeholder="0317102222" autocomplete="tel"'); ?></div></div>
<p data-did-callback hidden>Call Me Back answers this number using its configured greeting and accounts. Its normal destinations remain saved for switching back.</p>
<p data-did-callback-setup hidden>Set up Call Me Back next; the existing destination stays until ready. Saving opens its setup page and does not activate the service. A new number stays off until setup is complete and you select its destination.</p>
<div data-did-schedule><div class="setup-fields"><?php $select('hours_mode','When should this destination be used?',['always'=>'All day','office'=>'During office hours'],$didHours,'data-did-hours'); ?></div>
<div data-did-office><div class="setup-fields"><?php
    $select('office_department','Office-hours department',[''=>'Use destination department']+array_map($departmentName,array_column($didConfig['departments'],'name','number')),$didValue('office_department',(string)($didRule['office_department']??'')));
    $select('outside','When the office is closed',$admin->destinations($didConfig),$didValue('outside',($didOutside['type']??'None').':'.($didOutside['number']??'')),'data-did-outside');
    ?><div data-did-outside-external><?php $input('outside_external','Closed-hours external number',$didValue('outside_external',(string)($didOutside['external']??'')),'tel','maxlength="32" pattern="\+?[0-9]{1,32}" placeholder="0317102222"'); ?></div></div><p class="setup-hint">Office hours come from this department, or the destination’s department when none is selected.</p></div></div>
<?php if(!empty($didRule['use_holiday'])): ?><p class="setup-message" data-did-holiday>Existing holiday routing is retained for normal routing: <?= $e(pbx_trunk_routes::label($didRule['holiday']??['type'=>'None'],$didConfig)) ?>. Call Me Back, when selected, answers instead.</p><?php endif; ?>
<?php $check('enabled','Accept incoming calls on this number',$didEnabled); ?>
<div class="setup-actions" data-did-navigation hidden><button type="button" class="setup-button" data-did-back>Back</button><button type="button" class="setup-button primary" data-did-next>Review</button></div></section>
<section class="did-step" data-did-step="2" aria-labelledby="did-step-review"><h3 id="did-step-review" tabindex="-1">3. Review &amp; save</h3>
<div class="did-review" data-did-review aria-live="polite"><p>Review the number, destination and incoming-call setting above before saving.</p></div>
<p class="setup-hint">Saving updates this incoming route for new calls. The provider connection, outgoing rules and other numbers stay unchanged.</p>
<?php if(!$didEditor['callbacks']&&!$didFallback): ?><?php $check('setup_callback_next','Set up Call Me Back for this number after saving',!empty($_POST['setup_callback_next'])); ?><p class="setup-hint">You will choose its greeting and accounts next. Saving this number does not turn Call Me Back on.</p><?php endif; ?>
<div class="setup-actions"><button type="button" class="setup-button" data-did-back hidden>Back</button><button type="submit" class="setup-button primary" data-did-save>Save Incoming Number</button><a class="setup-button" href="?view=incoming">Cancel</a></div></section>
</form><script src="/app/pbx_setup/did-wizard.js?v=1.0.23" defer></script>
