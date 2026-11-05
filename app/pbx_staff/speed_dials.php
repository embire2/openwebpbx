<?php
if(!isset($csrf,$e,$input))return;
$speed=new pbx_cmb_speed_dials;$speedAccounts=$speed->accounts();
?>
<h2>Speed Dial</h2><p>Your private shortcuts: nine numbers, labelled 1 to 9. Calling permissions and callback minute limits still apply.</p>
<?php if(!$speedAccounts): ?><p class="setup-message">Ask your administrator to link your web login to your Call Me Back account. Your account identity, telephone password and calling permissions do not need to change.</p><?php endif; ?>
<?php foreach($speedAccounts as $speedAccount):$speedSlots=array_column($speed->slots($speedAccount['account_uuid']),null,'slot'); ?>
<section><h3><?= $e($speedAccount['service_name'].' · '.$speedAccount['name']) ?></h3><form method="post" class="setup-form"><?php $csrf(); ?><input type="hidden" name="action" value="speed_dials"><input type="hidden" name="account_uuid" value="<?= $e($speedAccount['account_uuid']) ?>"><div class="setup-fields"><?php for($slot=1;$slot<=9;$slot++){$input('speed_label_'.$slot,'Slot '.$slot.' · Name',$speedSlots[$slot]['label']??'','text','maxlength="80"');$input('speed_number_'.$slot,'Slot '.$slot.' · Telephone number',$speedSlots[$slot]['phone_number']??'','tel','maxlength="17" placeholder="0317102222"');} ?></div><button class="setup-button primary">Save my speed dials</button></form></section>
<?php endforeach; ?>
<p class="setup-hint">During a callback, enter 1–9 then # to call a saved number. From your linked registered PBX phone, dial **1 through **9. Leave a number blank to clear its slot. You can also edit during an authenticated callback: 1*0317102222# saves slot 1 and 1*0# clears it.</p>
