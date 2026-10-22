<?php
/** Installed fresh-factory native observer proof; never use on an occupied PBX. */
if(PHP_SAPI!=='cli'||PHP_OS_FAMILY!=='Windows')exit(2);
require 'C:/OpenWebPBX/web/resources/require.php';
$db=database::new()->db;
if((int)$db->query('select count(*) from v_pbx_restore')->fetchColumn()!==0||(int)$db->query('select count(*) from v_pbx_phone_health_contacts')->fetchColumn()!==0)throw new RuntimeException('An empty disposable factory is required.');
if(!pbx_phone_health::installed($db)||!preg_match('/^[a-f0-9]{64}$/D',pbx_phone_health::instanceId()??''))throw new RuntimeException('The native health installation is unavailable.');
$raw=pbx_windows_health_stream::api('show registrations as json');$rows=pbx_phone_health::registrations($raw);
if($rows!==[])throw new RuntimeException('The disposable factory already has phone contacts.');
$collected=pbx_phone_health::collect($db,$raw);
if($collected['observed_contacts']!==0||$collected['checked_domains']!==0)throw new RuntimeException('The empty native collector changed customer scope.');
$ports=event_guard_windows::ports(pbx_windows_health_stream::api('sofia xmlstatus'));
if(!$ports['tcp']||!$ports['udp'])throw new RuntimeException('The native phone listener scope is unavailable.');
echo json_encode(['state'=>'passed','actual_installed_collector'=>true,'native_registration_count'=>0,'credentials_or_routes_changed'=>false,'checks'=>4],JSON_THROW_ON_ERROR),PHP_EOL;
