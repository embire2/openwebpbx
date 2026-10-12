<?php
require_once dirname(__DIR__,2).'/resources/require.php';require_once PROJECT_ROOT.'/resources/check_auth.php';
try{$core=new pbx_core;}catch(Throwable){http_response_code(403);exit('Access denied.');}
header('Cache-Control: no-store');header('Referrer-Policy: no-referrer');$view=($_GET['view']??'')==='wallboard'?'wallboard':'switchboard';$document['title']=$view==='wallboard'?'Wallboard':'Switchboard';require_once PROJECT_ROOT.'/resources/header.php';
?>
<link rel="stylesheet" href="/app/pbx_setup/setup.css?v=5"><link rel="stylesheet" href="/app/pbx_setup/core.css?v=1"><script src="/app/pbx_setup/core.js?v=1" defer></script>
<main class="pbx-setup"><section class="setup-card"><h1><?= $view==='wallboard'?'Queue Wallboard':'Switchboard' ?></h1><div class="setup-actions"><a class="setup-button" href="?view=switchboard">Switchboard</a><a class="setup-button" href="?view=wallboard">Queue Wallboard</a></div><div data-core-board="<?= $view ?>"><p class="core-live-status" role="status">Connecting to live calls…</p><div class="core-live-calls"></div><h3><?= $view==='switchboard'?'People':'Queues' ?></h3><input class="core-people-search" type="search" placeholder="Search people" aria-label="Search people"><div class="core-live-people"></div><div class="core-live-queues"></div></div><noscript><p>Enable JavaScript to display live calls. Ordinary PBX settings remain available in Admin.</p></noscript></section></main>
<?php require_once PROJECT_ROOT.'/resources/footer.php'; ?>
