<?php
/** SPDX-License-Identifier: AGPL-3.0-or-later. Private Windows backup schema setup. */
if (PHP_SAPI !== 'cli' || PHP_OS_FAMILY !== 'Windows') {
    if (PHP_SAPI !== 'cli') http_response_code(404);
    exit(2);
}
set_exception_handler(static function (Throwable $error): void {
    fwrite(STDERR, "The instance backup schema configuration did not complete.\n");
    exit(1);
});
$web = $argv[1] ?? '';
if ($web === '' || !is_file($web.'/resources/require.php')) {
    throw new RuntimeException('Use the installed Windows web root.');
}
require $web.'/resources/require.php';
$path = $web.'/app/pbx_backups/resources/install.sql';
$size = is_file($path) ? filesize($path) : false;
if ($size === false || $size < 1 || $size > 1048576) {
    throw new RuntimeException('The bundled backup schema is unavailable.');
}
$sql = file_get_contents($path);
if ($sql === false || strlen($sql) !== $size) {
    throw new RuntimeException('The bundled backup schema could not be read.');
}
$db = database::new()->db;
$db->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
// The bundled schema supplies its own transaction and preserves saved settings.
$db->exec($sql);
echo "The instance backup schema is prepared.\n";
