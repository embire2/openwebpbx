<?php
if(!isset($admin,$view,$key)||$view!=='voice'||$key==='new'){http_response_code(404);exit;}
$didListing=(new pbx_did_routes)->listing();$didTrunkRules=[];$didTrunkFallbacks=[];
foreach($didListing['rows'] as $entry){if((string)$entry['rule']['trunk_id']!==$key)continue;if(($entry['rule']['condition']??'')==='ForwardAll'||trim((string)$entry['rule']['number'])==='')$didTrunkFallbacks[]=$entry;else $didTrunkRules[]=$entry;}
$didTrunkRows=static function(array $entries)use($e,$row): array {
    $rows=[];foreach($entries as $entry){$rule=$entry['rule'];$current=$entry['current'];$current=is_array($current)?($current['label']??'Unavailable'):$current;
        $schedule=is_array($entry['current'])&&($entry['current']['slot']??'')==='callback'?'Call Me Back · all day':(!empty($rule['use_outside'])?'Office hours + closed-hours destination':'All day');
        if(!empty($rule['use_holiday'])&&(!is_array($entry['current'])||($entry['current']['slot']??'')!=='callback'))$schedule.=' · saved holiday route';
        $state=empty($rule['enabled'])?'Off':(empty($row['enabled'])?'Provider off':'Enabled');
        $rows[]=['<a href="?view=incoming&amp;edit='.$e($rule['rule_id']).'">'.$e((($rule['condition']??'')==='ForwardAll'||$rule['number']==='')?'Otherwise unassigned numbers':$rule['number']).'</a>',$e($current),$e($schedule),$e($state),'<a href="?view=incoming&amp;edit='.$e($rule['rule_id']).'">Edit incoming number</a>'];
    }return $rows;
};
?>
<section class="trunk-incoming" id="incoming-calls"><h3>Incoming numbers</h3><p>Choose where each number goes in the DID number wizard. Provider settings below do not select a destination.</p>
<div class="setup-actions"><a class="setup-button primary" href="?view=incoming&amp;edit=new&amp;trunk=<?= $e($key) ?>">Add DID Number</a><a class="setup-button" href="?view=incoming">All DID Numbers</a></div>
<div class="did-number-list"><?php $table(['DID Number','Current destination','Schedule','Incoming calls',''],$didTrunkRows($didTrunkRules)); ?></div>
<?php if($didTrunkFallbacks): ?><details class="did-fallbacks"><summary>Fallback routes · <?= count($didTrunkFallbacks) ?></summary><p>Used for otherwise unassigned numbers on this provider.</p><?php $table(['Fallback','Current destination','Schedule','Incoming calls',''],$didTrunkRows($didTrunkFallbacks)); ?></details><?php endif; ?>
<?php $didInventory=pbx_v20_restore::incomingNumbers($row);if($didInventory): ?><details class="did-fallbacks"><summary>Saved provider number inventory</summary><p><?= $e(implode(', ',$didInventory)) ?></p><p class="setup-hint">This provider list is shown for reference. Add or change incoming destinations through DID Numbers.</p></details><?php endif; ?>
</section><link rel="stylesheet" href="/app/pbx_setup/did-wizard.css?v=1">
