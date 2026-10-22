<?php
require_once dirname(__DIR__,2).'/resources/require.php';
require_once PROJECT_ROOT.'/resources/check_auth.php';
if(!in_array(PHP_OS_FAMILY,['Linux','Windows'],true)){http_response_code(501);exit('Phone Health requires a supported OpenWeb PBX server.');}
header('Cache-Control: no-store');header('Referrer-Policy: no-referrer');
try {pbx_admin::openPreferred();$health=new pbx_phone_health;$health->alertSettings();}
catch(Throwable){http_response_code(403);exit('Administrator access required.');}
$e=static fn($value)=>htmlspecialchars((string)$value,ENT_QUOTES,'UTF-8');
$token=(new token)->create('/app/pbx_phone_health/api.php');
$document['title']='Phone Health · Admin';require_once PROJECT_ROOT.'/resources/header.php';
?>
<link rel="stylesheet" href="/app/pbx_setup/setup.css?v=5">
<link rel="stylesheet" href="/app/pbx_phone_health/health.css?v=1">
<script src="/app/pbx_phone_health/health.js?v=1" defer></script>
<main class="pbx-setup phone-health" data-phone-health="<?= $e($_SESSION['domain_uuid']) ?>" data-token-name="<?= $e($token['name']) ?>" data-token-value="<?= $e($token['hash']) ?>">
 <header class="setup-heading"><div><span class="setup-eyebrow">OPENWEB PBX · ADMIN</span><h1>Phone Health &amp; Recovery</h1><p>See what needs attention and get your phones connected again.</p></div><a class="setup-button" href="/app/pbx_setup/">Back to Admin</a></header>
 <div class="health-toolbar"><p id="health-checked" role="status">Checking your PBX…</p><button class="setup-button" id="health-refresh" type="button">Refresh now</button></div>
 <div id="health-message" class="setup-message" role="status" hidden></div>
 <div class="health-counts" aria-label="Current phone health"><div><strong data-count="online">—</strong><span>Online phones</span></div><div><strong data-count="offline">—</strong><span>Offline phones</span></div><div><strong data-count="blocked_offices">—</strong><span>Blocked offices</span></div><div><strong data-count="provider_failures">—</strong><span>Provider problems</span></div></div>
 <section class="setup-card"><h2>Needs attention</h2><p>Security blocks and provider failures appear here. Online means connected; make a test call to check ringing and sound.</p><div id="health-issues" class="health-list"><p>Waiting for the first check.</p></div></section>
 <section class="setup-card"><h2>Office security blocks</h2><p>Recovery removes one verified phone sign-in block. It keeps the security checks and your phone passwords in place.</p><div id="health-blocks" class="health-list"></div></section>
 <section class="setup-card"><h2>Recent recovery requests</h2><p>A request is complete only when the security service confirms it. Phone registration and a successful call are separate checks.</p><div id="health-recoveries" class="health-list"></div></section>
 <section class="setup-card"><div class="admin-card-title"><h2>Phones</h2><label class="health-search">Find a phone<input id="health-search" type="search" placeholder="Name or extension" maxlength="100"></label></div><div id="health-phones" class="health-list"></div></section>
 <section class="setup-card"><h2>Phone providers</h2><p>Provider connection status and the next useful check. This does not place a call or change a connection.</p><div id="health-providers" class="health-list"></div><a class="setup-button" href="/app/pbx_setup/?view=voice">Open Voice &amp; Chat</a></section>
 <section class="setup-card"><h2>Administrator alerts</h2><p>Alerts stay visible in Admin. You can also receive a message when a problem starts or clears, through the instance’s outgoing mail server.</p><form id="health-alert-settings" class="setup-form"><label class="setup-check-label"><input type="checkbox" id="health-alerts-enabled" disabled><span>Email me when phone health changes</span></label><div class="setup-actions"><button class="setup-button" type="submit" disabled>Save alerts</button></div></form><p class="setup-hint">No automatic unblocking, provider changes or phone restarts are performed.</p></section>
 <dialog id="health-recovery"><form id="health-recovery-form" class="setup-form"><h2>Recover this office?</h2><p id="health-recovery-description"></p><p>The phones may need a moment to try signing in again. A repeated password failure can block them again.</p><label class="setup-check-label"><input type="checkbox" id="health-confirm"><span>I recognise this office and have checked its phone settings.</span></label><div class="setup-actions"><button id="health-recover-submit" class="setup-button primary" type="submit" disabled>Remove this sign-in block</button><button id="health-recovery-cancel" class="setup-button" type="button">Cancel</button></div></form></dialog>
 <noscript><p class="setup-message warning">Enable JavaScript to load live phone health and use the recovery controls.</p></noscript>
</main>
<?php require_once PROJECT_ROOT.'/resources/footer.php'; ?>
