<?php
/** OpenWeb PBX desktop. Existing administration applications retain their own permissions. */
require_once dirname(__DIR__, 2).'/resources/require.php';
require_once PROJECT_ROOT.'/resources/check_auth.php';
if((new pbx_setup)->canManage())pbx_admin::openPreferred();

// A session timeout inside an application must never open a desktop inside a desktop.
if (($_SERVER['HTTP_SEC_FETCH_DEST'] ?? '') === 'iframe') {
    header('Location: '.PROJECT_PATH.'/core/dashboard/?classic=1');
    exit;
}

function desktop_status($database): array {
    $parameters = ['domain_uuid' => $_SESSION['domain_uuid']];
    $extensions = permission_exists('extension_view')
        ? (int)$database->select('select count(*) from v_extensions where domain_uuid = :domain_uuid', $parameters, 'column') : null;
    $status = ['online' => false, 'extensions' => $extensions, 'registered' => null, 'calls' => null];
    try {
        $status['online'] = str_contains((string)event_socket::api('status'), 'is ready');
        if (permission_exists('extension_view')) {
            $registrations = json_decode((string)event_socket::api('show registrations as json'), true);
            $status['registered'] = count(array_filter($registrations['rows'] ?? [], static fn($row) =>
                ($row['realm'] ?? '') === $_SESSION['domain_name']));
        }
        if (permission_exists('call_active_view')) {
            $calls = json_decode((string)event_socket::api('show channels as json'), true);
            $status['calls'] = count(array_filter($calls['rows'] ?? [], static fn($row) =>
                ($row['context'] ?? '') === $_SESSION['domain_name']));
        }
    } catch (Throwable $error) {
        error_log('OpenWeb PBX desktop: telephony status unavailable');
    }
    return $status;
}

if (($_GET['action'] ?? '') === 'status') {
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store');
    echo json_encode(desktop_status($database));
    exit;
}

$menu = new menu;
$menu->menu_uuid = $settings->get('domain', 'menu');
$applications = [];
$collect = function (array $items, string $group = '') use (&$collect, &$applications): void {
    foreach ($items as $item) {
        $title = html_entity_decode(strip_tags($item['menu_language_title'] ?? $item['menu_item_title'] ?? ''), ENT_QUOTES, 'UTF-8');
        $link = $item['menu_item_link'] ?? '';
        if (str_starts_with($link, '/') && !str_starts_with($link, '//')
            && !in_array(parse_url($link, PHP_URL_PATH), ['/login.php', '/logout.php', '/'])) {
            if (str_starts_with($link, '/core/dashboard')) {
                $link = '/core/dashboard/?classic=1';
                $title = 'PBX Overview';
            }
            $applications[$link] = ['id' => substr(hash('sha256', $link), 0, 12), 'title' => $title,
                'url' => PROJECT_PATH.$link, 'group' => $group ?: 'Workspace',
                'icon' => preg_replace('/[^a-zA-Z0-9 -]/', '', $item['menu_item_icon'] ?? '')];
        }
        if (!empty($item['menu_items'])) {
            $collect($item['menu_items'], $group ?: $title);
        }
    }
};
$collect($menu->menu_array());
$adminPages=['/app/extensions/extensions.php'=>['Users','users'],'/app/devices/devices.php'=>['Phones','phones'],'/app/gateways/gateways.php'=>['Voice & Chat','voice'],'/app/destinations/destinations.php'=>['DID Numbers','incoming'],'/app/ring_groups/ring_groups.php'=>['Ring Groups','ring_groups'],'/app/ivr_menus/ivr_menus.php'=>['Digital Receptionists','receptionists'],'/app/call_centers/call_center_queues.php'=>['Call Queues','queues'],'/app/time_conditions/time_conditions.php'=>['Office Hours','hours'],'/app/xml_cdr/xml_cdr.php'=>['Reports','reports'],'/app/recordings/recordings.php'=>['Recordings','recordings'],'/app/voicemails/voicemails.php'=>['Voicemail','voicemails']];
if((new pbx_setup)->canManage()&&(new pbx_admin)->restored())foreach($applications as $key=>&$application){
    if(isset($adminPages[$key])){$application['title']=$adminPages[$key][0];$application['url']=PROJECT_PATH.'/app/pbx_setup/?view='.$adminPages[$key][1];$application['group']='Admin';}
    if($key==='/app/pbx_setup/')$application['title']='Admin';
}
unset($application);
if (isset($applications['/app/pbx_setup/']) && !(new pbx_setup)->canManage()) unset($applications['/app/pbx_setup/']);
if ((new pbx_tenants)->installed() && (new pbx_tenants)->workspaceOnly() && !permission_exists('domain_all')) {
    $applications = array_filter($applications, fn($app) => str_contains($app['url'], '/app/tenant_services/') || str_contains($app['url'], '/app/pbx_setup/'));
}
if (permission_exists('user_edit') || permission_exists('user_view')) {
    $applications['/core/users/user_profile.php'] = ['id' => 'profile', 'title' => 'My Profile',
        'url' => PROJECT_PATH.'/core/users/user_profile.php', 'group' => 'Workspace', 'icon' => 'fa-solid fa-user'];
}
$bootstrap = ['apps' => array_values($applications), 'user' => $_SESSION['username'], 'domainUuid' => $_SESSION['domain_uuid'],
    'domain' => $_SESSION['domain_name'], 'preferenceKey' => 'openweb-desktop-'.$_SESSION['domain_uuid'].'-'.$_SESSION['user_uuid'],
    'statusUrl' => PROJECT_PATH.'/core/desktop/?action=status', 'status' => desktop_status($database)];
$bootstrap['openSetup'] = isset($applications['/app/pbx_setup/']);
$escape = static fn($value) => htmlspecialchars((string)$value, ENT_QUOTES, 'UTF-8');
$workspaceLabel=$_SESSION['domain_name'];
$serviceLabel=$database->select('select s.service_name,t.tenant_name from v_pbx_services s join v_pbx_tenants t using(tenant_uuid) where s.domain_uuid=:domain',['domain'=>$_SESSION['domain_uuid']],'row');
if($serviceLabel)$workspaceLabel=$serviceLabel['tenant_name'].' · '.$serviceLabel['service_name'];
header('Cache-Control: no-store');
?>
<!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="color-scheme" content="light dark">
    <title>Desktop · OpenWeb PBX</title>
    <link rel="icon" type="image/svg+xml" href="<?= PROJECT_PATH ?>/themes/default/images/openweb-mark.svg">
    <link rel="stylesheet" href="<?= PROJECT_PATH ?>/resources/fontawesome/css/all.min.css.php">
    <link rel="stylesheet" href="<?= PROJECT_PATH ?>/core/desktop/desktop.css?v=2">
    <script id="desktop-data" type="application/json"><?= json_encode($bootstrap, JSON_HEX_TAG | JSON_HEX_AMP | JSON_HEX_APOS | JSON_HEX_QUOT | JSON_UNESCAPED_SLASHES) ?></script>
    <script defer src="<?= PROJECT_PATH ?>/core/desktop/desktop.js?v=5"></script>
</head>
<body>
    <main id="desktop" aria-label="OpenWeb PBX desktop">
        <header class="desktop-brand"><img src="<?= PROJECT_PATH ?>/themes/default/images/openweb-mark.svg" alt="" width="38" height="38"><div><strong>OpenWeb PBX</strong><span>Communications workspace</span></div></header>
        <nav id="desktop-shortcuts" class="desktop-shortcuts" aria-label="Desktop applications"></nav>
        <aside class="workspace-card glass" aria-label="PBX status">
            <div class="workspace-eyebrow">YOUR WORKSPACE</div>
            <h1>Welcome back,<br><span><?= $escape($_SESSION['username']) ?>.</span></h1>
            <p class="workspace-domain"><?= $escape($workspaceLabel) ?></p>
            <div class="connection-status"><span class="status-dot"></span><span id="connection-label" aria-live="polite">Checking PBX connection</span></div>
            <div class="workspace-metrics"><div><strong data-metric="extensions">—</strong><span>Users</span></div><div><strong data-metric="registered">—</strong><span>Connected Phones</span></div><div><strong data-metric="calls">—</strong><span>Active Calls</span></div></div>
            <button class="workspace-launch" data-toggle="start">Explore your applications <i class="fa-solid fa-arrow-right" aria-hidden="true"></i></button>
            <p class="workspace-tip">Your tools, one desktop.<br>Open an app to get started.</p>
        </aside>
        <div id="window-layer" aria-label="Open administration windows"></div>
        <div id="snap-preview" hidden></div>
    </main>

    <section id="start-menu" class="start-menu glass popover" aria-label="Start menu" hidden>
        <div class="start-search"><i class="fa-solid fa-magnifying-glass" aria-hidden="true"></i><input id="app-search" type="search" placeholder="Search apps, settings, and tools" aria-label="Search applications" autocomplete="off"><kbd>Esc</kbd></div>
        <div class="start-section-heading"><h2 id="apps-heading">Pinned</h2><button id="all-apps" class="subtle-button">All apps <i class="fa-solid fa-chevron-right" aria-hidden="true"></i></button></div>
        <div id="start-apps" class="start-apps"></div>
        <p id="no-apps" class="empty-search" hidden>No applications match your search.</p>
        <div class="start-recommended"><h2>Workspace</h2><div><i class="fa-solid fa-circle-info" aria-hidden="true"></i><p>Everything you need to manage your PBX.<span>Search the full application library above.</span></p></div></div>
        <footer class="start-footer"><button id="profile-button" class="user-button"><span class="avatar"><?= $escape(strtoupper(substr($_SESSION['username'], 0, 1))) ?></span><?= $escape($_SESSION['username']) ?></button><a class="icon-button" href="<?= PROJECT_PATH ?>/logout.php" aria-label="Sign out" title="Sign out"><i class="fa-solid fa-power-off" aria-hidden="true"></i></a></footer>
    </section>

    <section id="quick-settings" class="quick-settings glass popover" aria-label="Quick settings" hidden>
        <div class="start-section-heading"><h2>Quick settings</h2><span class="status-badge">OpenWeb PBX</span></div>
        <div class="quick-tiles"><button id="theme-toggle" class="quick-tile"><i class="fa-solid fa-moon" aria-hidden="true"></i><span>Dark mode</span></button><button id="wallpaper-toggle" class="quick-tile"><i class="fa-solid fa-palette" aria-hidden="true"></i><span>Wallpaper</span></button><button id="fullscreen-toggle" class="quick-tile"><i class="fa-solid fa-expand" aria-hidden="true"></i><span>Full screen</span></button></div>
        <div class="quick-connection"><i class="fa-solid fa-network-wired" aria-hidden="true"></i><div><strong id="quick-status">Checking connection</strong><span><?= $escape($workspaceLabel) ?></span></div></div>
        <button id="refresh-status" class="subtle-button">Refresh connection status <i class="fa-solid fa-rotate" aria-hidden="true"></i></button>
    </section>

    <section id="calendar-panel" class="calendar-panel glass popover" aria-label="Calendar" hidden>
        <div class="calendar-date" id="calendar-date"></div><div class="start-section-heading"><button id="calendar-prev" class="icon-button" aria-label="Previous month"><i class="fa-solid fa-chevron-left" aria-hidden="true"></i></button><h2 id="calendar-month"></h2><button id="calendar-next" class="icon-button" aria-label="Next month"><i class="fa-solid fa-chevron-right" aria-hidden="true"></i></button></div><div class="calendar-weekdays"><span>Su</span><span>Mo</span><span>Tu</span><span>We</span><span>Th</span><span>Fr</span><span>Sa</span></div><div id="calendar-days" class="calendar-days"></div><p class="calendar-note">All times shown in your local timezone.</p>
    </section>

    <footer class="taskbar glass" aria-label="Taskbar">
        <button class="taskbar-status" data-toggle="quick"><span class="status-dot"></span><span><strong>OpenWeb PBX</strong><small id="taskbar-status-label">Connecting</small></span></button>
        <div class="taskbar-center"><button id="start-button" class="taskbar-button" data-toggle="start" aria-label="Start" aria-controls="start-menu" aria-expanded="false" title="Start"><span class="start-symbol"><span></span><span></span><span></span><span></span></span></button><button id="search-button" class="taskbar-search" aria-label="Search apps"><i class="fa-solid fa-magnifying-glass" aria-hidden="true"></i><span>Search</span></button><button id="overview-button" class="taskbar-button" aria-label="Open PBX Overview" title="PBX Overview"><i class="fa-solid fa-chart-simple" aria-hidden="true"></i></button><div class="taskbar-separator"></div><div id="running-apps" class="running-apps" aria-label="Running applications"></div></div>
        <div class="taskbar-tray"><button class="taskbar-button" data-toggle="quick" aria-label="Quick settings" aria-controls="quick-settings" aria-expanded="false" title="Quick settings"><i class="fa-solid fa-network-wired" aria-hidden="true"></i></button><button id="clock-button" data-toggle="calendar" aria-label="Open calendar" aria-controls="calendar-panel" aria-expanded="false"><time id="clock-time"></time><time id="clock-date"></time></button><button id="show-desktop" aria-label="Show desktop" title="Show desktop"></button></div>
    </footer>
    <div id="desktop-announcement" class="sr-only" aria-live="polite"></div>
</body>
</html>
