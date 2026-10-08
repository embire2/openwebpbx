<?php
/** OpenWeb PBX tenant administration entry point. */
require_once dirname(__DIR__).'/resources/require.php';

header('Cache-Control: no-store');
header('Referrer-Policy: no-referrer');

// Keep the existing sign-in flow and return to this portal after authentication.
// The shared controller below applies the same permissions, tenant guard and
// CSRF validation as /app/tenant_services/; there is no separate account store.
if (empty($_SESSION['authorized'])) {
    $_SESSION['redirect_path']='/tenantadmin/';
}
define('OPENWEB_TENANT_ADMIN_ENTRY', true);
require PROJECT_ROOT.'/app/tenant_services/index.php';
