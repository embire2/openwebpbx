<?php
/** Same tenant controller, permissions and CSRF; host context is bound by require.php. */
require_once dirname(__DIR__).'/resources/require.php';
header('Cache-Control: no-store');
header('Location: /tenantadmin/');
