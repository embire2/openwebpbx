<?php
// Local installation/restore guard. Never print certificate or private-key bytes.
if (PHP_SAPI !== 'cli' || count($argv) !== 2) exit(2);
require $argv[1].'/resources/classes/config.php';
config::load();
require $argv[1].'/resources/classes/auto_loader.php';
new auto_loader();
try {
    $pair = pbx_meet_install::tls();
    if (!is_file($pair['certificate']) || !is_file($pair['trust'])) throw new RuntimeException('Missing meeting transport.');
    echo "Private meeting certificate pair verified.\n";
} catch (Throwable $e) {
    fwrite(STDERR, "The private meeting certificate pair needs administrator review.\n");
    exit(1);
}
