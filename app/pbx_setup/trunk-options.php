<?php
if(!isset($admin,$view,$key)||$view!=='voice'||$key==='new'){http_response_code(404);exit;}
$trunkOptions=(new pbx_trunk_options)->snapshot($key);$opt=$trunkOptions['options'];$nativeOptions=$trunkOptions['native'];
$departmentOptions=[''=>'System Wide'];foreach($trunkOptions['config']['departments']??[] as $department)$departmentOptions[(string)$department['number']]=$departmentName($department['name']);
?>
<section id="trunk-options" class="trunk-incoming"><h3>Options</h3>
<p class="setup-hint">Trunk Options <?= $e(pbx_trunk_options::VERSION) ?> · Call settings apply to new calls. Phones keep their existing account details.</p>
<?php if(!isset($trunkOptions['trunk']['options'])): ?><p class="setup-hint">These are the current connection values. Saving Options activates the call permissions and shared call-limit protection shown here for this trunk. Its restored limit was previously displayed without this protection.</p><?php endif; ?>
<?php if(!empty($opt['connection_pending'])): ?><p class="setup-message" role="status">The saved connection still needs a refresh. When calls have ended, select the confirmation below and save again.</p><?php endif; ?>
<form method="post" class="setup-form" action="?view=voice&amp;edit=<?= $e($key) ?>#trunk-options"><?php $csrf(); ?><input type="hidden" name="action" value="save_trunk_options"><input type="hidden" name="options_revision" value="<?= $e($trunkOptions['revision']) ?>">
<div class="setup-fields">
<?php $select('scope_department','Limit Outgoing Use To',$departmentOptions,$opt['scope_department']);$input('limit','Number of Simultaneous Calls Per Trunk',$trunkOptions['trunk']['limit']??$nativeOptions['channels']??10,'number','min="1" max="10000" required'); ?>
</div><p class="setup-hint">System Wide allows users throughout this PBX. A department allows its members, including secondary members, to use this connection. Incoming numbers keep their saved routes. The call limit is shared by incoming and outgoing call legs; a full trunk can use an available backup provider.</p>
<?php $check('allow_incoming','Allow Inbound Calls',(bool)$opt['allow_incoming']);$check('allow_outgoing','Allow Outbound Calls',(bool)$opt['allow_outgoing']); ?>
<div class="setup-fields">
<?php $select('transport','Transport Protocol',['udp'=>'UDP','tcp'=>'TCP','tls'=>'TLS'],$nativeOptions['register_transport']?:'udp');$select('srtp_mode','Secure Audio (SRTP)',['inherit'=>'Automatic · keep existing audio settings','disabled'=>'Disabled · unencrypted provider audio','optional'=>'Optional · accept secure or ordinary audio','required'=>'Required · secure provider audio only'],$opt['srtp_mode']);$input('expires','Re-Register Timeout (Seconds)',$nativeOptions['expire_seconds']?:3600,'number','min="1" max="86400" required');$input('outbound_proxy','Alternative Proxy',$nativeOptions['outbound_proxy']??'','text','autocomplete="off" placeholder="Leave empty to use the provider"'); ?>
</div><p class="setup-hint">Use the connection values supplied by your provider. A proxy may be a host name or IP address, with an optional port. Requiring secure audio can reject a provider that does not support it; this setting applies only to the provider leg.</p>
<label class="setup-check-label"><input type="checkbox" checked disabled><span>PBX Delivers Audio</span></label>
<p class="setup-hint">Always enabled so calls stay anchored through this PBX for recording, hold music and remote phones.</p>
<?php $check('support_reinvite','Support Re-Invite',(bool)$opt['support_reinvite']); ?>
<p class="setup-hint">Enabled by default to support normal hold and resume negotiation. Change this only when your provider requires it.</p>
<details><summary>Managed Connection Settings</summary><dl class="setup-review">
<div><dt>IP Mode</dt><dd>Automatic · use the provider address and server networking settings</dd></div>
<div><dt>Video</dt><dd>Provider connections carry audio. App video and conferences use their own service.</dd></div>
<div><dt>Contact, SDP and Via IP Addresses</dt><dd>Managed by the instance public-address settings</dd></div>
<div><dt>Support Replaces / Carrier-Side Transfers (SIP REFER)</dt><dd>Managed by the calling service profile; no separate per-trunk switch is available.</dd></div>
<div><dt>Diversion Headers</dt><dd>Incoming custom headers are not copied to another provider.</dd></div>
</dl><p class="setup-hint">These are displayed for clarity. This form does not change shared network settings or other tenants.</p></details>
<?php $check('confirm_connection','I confirm refreshing this trunk connection if transport, proxy or registration timeout changes'); ?>
<p class="setup-hint">Connection changes require this confirmation and no current calls. Call permissions, limits, department, secure audio and re-invite settings do not restart an existing connection.</p>
<div class="setup-actions"><button type="submit" class="setup-button primary">Save Trunk Options</button></div>
</form></section>
