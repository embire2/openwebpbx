<?php
/** Private managed worker only. Native contact/authentication material never reaches logs. */
if (PHP_SAPI !== 'cli' || !function_exists('posix_geteuid') || posix_geteuid() !== 33
    || posix_getegid() !== 33 || posix_getgroups() !== []) exit(2);
// The protected root launcher establishes these conditions before exec. Refuse
// root execution or an unsandboxed manual invocation before loading web code.
$status = file_get_contents('/proc/self/status');
if (!is_string($status) || !preg_match('/^NoNewPrivs:\s+1$/m', $status)
    || !preg_match('/^CapEff:\s+0+$/m', $status)) exit(2);
ini_set('display_errors', '0');
ini_set('log_errors', '0');
set_time_limit(20);
try {
    require '/var/www/fusionpbx/resources/require.php';
    $action = $argv[1] ?? '';
    if ($action === 'registrations') {
        $raw = event_socket::api('show registrations as json');
        if (!is_string($raw) || strlen($raw) > 4194304) exit(1);
        $value = json_decode($raw, true, 32, JSON_THROW_ON_ERROR);
        if (!is_array($value) || !isset($value['row_count']) || !is_numeric($value['row_count'])) exit(1);
        echo $raw;
    } elseif ($action === 'monitor') {
        $raw = stream_get_contents(STDIN, 4194305);
        if (!is_string($raw) || strlen($raw) > 4194304) exit(1);
        $result = pbx_phone_health::monitor(database::new()->db, $raw === 'null' ? null : $raw);
        // Keep tenant names, phone identities, addresses and all native responses private.
        $safe = ['available' => ($result['available'] ?? false) === true];
        foreach (['observed_contacts', 'checked_domains', 'open', 'new', 'resolved', 'queued'] as $name) {
            $count = $result[$name] ?? 0;
            if (!is_int($count) || $count < 0 || $count > 2000000) exit(1);
            $safe[$name] = $count;
        }
        echo json_encode($safe, JSON_THROW_ON_ERROR);
    } else exit(2);
} catch (Throwable $error) {
    // The service wrapper reports only a fixed, safe failure message.
    exit(1);
}
