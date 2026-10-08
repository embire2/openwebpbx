<?php
/** Private CLI bridge for native SIP profile TLS configuration. */
if (PHP_SAPI !== 'cli' || !function_exists('posix_geteuid') || posix_geteuid() !== 0) { exit(1); }
require '/var/www/fusionpbx/resources/require.php';
$db = $database->db;
$db->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
$action = $argv[1] ?? '';
$host = gethostname();
$query = $db->prepare("select sip_profile_uuid, sip_profile_name from v_sip_profiles where sip_profile_name in ('internal','internal-ipv6') and sip_profile_enabled=true and (sip_profile_hostname is null or sip_profile_hostname='' or sip_profile_hostname=:h) order by sip_profile_name");
$query->execute(['h'=>$host]);
$profiles = $query->fetchAll(PDO::FETCH_ASSOC);
if (!$profiles || !in_array('internal', array_column($profiles, 'sip_profile_name'), true)) { throw new RuntimeException('An enabled internal phone profile is required.'); }
if ($action === 'configure') {
    $values = ['tls'=>'true', 'tls-only'=>'false', 'tls-sip-port'=>'5061', 'tls-cert-dir'=>'/etc/freeswitch/tls', 'tls-version'=>'tlsv1.2', 'inbound-reg-force-matching-username'=>'true'];
    $db->beginTransaction();
    try {
        foreach ($profiles as $profile) {
            foreach ($values as $name=>$value) {
                $update = $db->prepare('update v_sip_profile_settings set sip_profile_setting_value=:v, sip_profile_setting_enabled=true where sip_profile_uuid=:p and sip_profile_setting_name=:n');
                $parameters = ['v'=>$value,'p'=>$profile['sip_profile_uuid'],'n'=>$name];
                $update->execute($parameters);
                if (!$update->rowCount()) {
                    $insert = $db->prepare('insert into v_sip_profile_settings(sip_profile_setting_uuid,sip_profile_uuid,sip_profile_setting_name,sip_profile_setting_value,sip_profile_setting_enabled) values(:u,:p,:n,:v,true)');
                    $insert->execute(['u'=>uuid()]+$parameters);
                }
            }
        }
        $db->commit();
    } catch (Throwable $exception) { if ($db->inTransaction()) { $db->rollBack(); } throw $exception; }
    $cache = new cache;
    $cache->delete($host.':configuration:sofia.conf');
    $cache->delete('configuration:sofia.conf');
    settings::clear_cache();
} elseif ($action !== 'profiles') { exit(1); }
echo json_encode(array_column($profiles, 'sip_profile_name'), JSON_THROW_ON_ERROR);
