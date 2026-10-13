<?php
/** Read-only, credential-free catalogue of an explicitly supplied private V20 archive. */
if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }
require_once dirname(__DIR__).'/resources/classes/threecx_v20.php';
require_once dirname(__DIR__).'/resources/classes/threecx_backup.php';
require_once dirname(__DIR__).'/resources/classes/pbx_phone_restore.php';
$source = getenv('OPENWEB_PRIVATE_BACKUP');
if (!$source || !is_file($source) || is_link($source)) {
    fwrite(STDERR, "Supply OPENWEB_PRIVATE_BACKUP outside published fixtures.\n"); exit(2);
}
$plan = threecx_backup::analyze($source);
if (($plan['source_version'] ?? '') !== '20.0.9.995' || !isset($plan['v20'])) {
    throw new RuntimeException('This qualification requires the inspected V20 build.');
}
$v = $plan['v20'];
$frequencies = static function(array $rows, string $field): array {
    $out = [];
    foreach ($rows as $row) {
        $value = (string)($row[$field] ?? 'missing');
        // Only source-defined enum values reach the public report.
        if ($field === 'profile') {
            if (!in_array($value,['Available','Away','Out of office','Custom 1','Custom 2'],true)) $value = 'other';
        } elseif (!preg_match('/^[A-Za-z0-9_-]{1,60}$/D', $value)) $value = 'other';
        $out[$value] = ($out[$value] ?? 0) + 1;
    }
    ksort($out); return $out;
};
$credentials = ['users_with_password'=>0, 'users_with_separate_authentication_id'=>0,
    'numeric_identity_collisions_across_users'=>0,
    'users_with_voicemail_pin'=>0, 'disabled_users'=>0];
foreach ($plan['users'] as $u) {
    $credentials['users_with_password'] += $u['password'] !== '';
    $credentials['users_with_separate_authentication_id'] += $u['auth_id'] !== $u['number'];
    $credentials['numeric_identity_collisions_across_users'] += $u['auth_id'] !== $u['number'] &&
        (bool)array_filter($plan['users'],static fn($other)=>$other['number']===$u['auth_id']);
    $credentials['users_with_voicemail_pin'] += $u['voicemail_pin'] !== '';
    $credentials['disabled_users'] += !$u['enabled'];
}
$profiles = []; $forwardTypes = []; $forwardingRules = 0;
foreach ($v['users'] as $u) foreach ($u['profiles'] as $p) {
    $name = in_array($p['name'],['Available','Away','Out of office','Custom 1','Custom 2'],true) ? $p['name'] : 'other';
    $profiles[$name] = ($profiles[$name] ?? 0) + 1;
    foreach (['available','away'] as $kind) foreach ($p[$kind] ?? [] as $rule) {
        $forwardingRules++;
        foreach ($rule as $destination) if (is_array($destination) && isset($destination['type'])) {
            $type = (string)$destination['type'];
            if (!preg_match('/^[A-Za-z0-9_-]{1,60}$/D', $type)) $type = 'other';
            $forwardTypes[$type] = ($forwardTypes[$type] ?? 0) + 1;
        }
    }
}
$phoneTemplates = []; $phonesWithSettings = 0;
$phoneKnowledge=['explicit_model'=>0,'explicit_transport'=>0,'explicit_registrar_port'=>0,
    'source_interface_present'=>0,'source_provisioning_filename_present'=>0];
foreach ($v['phones'] as $phone) {
    $template = strtolower((string)$phone['template']);
    $vendor = str_contains($template,'fanvil') ? 'Fanvil' :
        (str_contains($template,'yealink') ? 'Yealink' :
        (str_contains($template,'snom') ? 'Snom' : 'Other'));
    $phoneTemplates[$vendor] = ($phoneTemplates[$vendor] ?? 0) + 1;
    $phonesWithSettings += $phone['settings'] !== '';
    $user=current(array_filter($plan['users'],static fn($user)=>$user['number']===$phone['number']));
    $mapped=pbx_phone_restore::plan($phone,$v['users'][$phone['number']]+$user,'audit-only.example.invalid');
    $phoneKnowledge['explicit_model'] += !empty($mapped['summary']['model']);
    $phoneKnowledge['explicit_transport'] += $mapped['summary']['transport_known'];
    $phoneKnowledge['explicit_registrar_port'] += $mapped['summary']['port_known'];
    $phoneKnowledge['source_interface_present'] += ($phone['interface']??'')!=='';
    $phoneKnowledge['source_provisioning_filename_present'] += ($phone['provisioning_filename']??'')!==''||($phone['provisioning_filename2']??'')!=='';
}
$waitingQueues=0;
foreach($v['queues'] as $queue){
    $eligible=array_filter($queue['members'],static fn($member)=>$member['status']==='LoggedIn'&&
        $v['users'][$member['number']]['queue_status']==='LoggedIn'&&$v['users'][$member['number']]['profile']==='Available');
    $waitingQueues+=!$eligible;
}
$report = [
    'read_only'=>true, 'archive_not_extracted'=>true, 'source_version'=>$plan['source_version'],
    'counts'=>threecx_v20::counts($plan), 'phone_credentials'=>$credentials,
    'ring_group_strategies'=>$frequencies($v['ring_groups'],'strategy'),
    'queue_strategies'=>$frequencies($v['queues'],'strategy'),
    'queue_callback_modes'=>$frequencies($v['queues'],'callback_mode'),
    'queues_with_no_source_logged_in_available_member'=>$waitingQueues,
    'users_source_logged_out_of_queues'=>count(array_filter($v['users'],static fn($user)=>$user['queue_status']==='LoggedOut')),
    'announcement_only_receptionists'=>count(array_filter($v['receptionists'],static fn($ivr)=>!$ivr['options'])),
    'user_status_profiles'=>$frequencies(array_values($v['users']),'profile'),
    'forwarding_profiles'=>$profiles, 'forwarding_rule_count'=>$forwardingRules,
    'forwarding_destination_types'=>$forwardTypes,
    'department_holiday_count'=>array_sum(array_map(fn($d)=>count($d['holidays'] ?? []),$v['departments'])),
    'phone_template_vendors'=>$phoneTemplates, 'phones_with_source_settings'=>$phonesWithSettings,
    'phone_source_identification_counts'=>$phoneKnowledge,
    'provider_registration_modes'=>$frequencies(array_values($v['trunks']),'registration_mode'),
    'provider_authentication_modes'=>$frequencies(array_values($v['trunks']),'auth_mode'),
    'provider_types'=>$frequencies(array_values($v['trunks']),'type'),
    'source_limitation_categories'=>array_map(fn($n)=>['category'=>$n['category'],'count'=>$n['count'],'reason'=>$n['reason']],$plan['unsupported']),
    'private_values_excluded'=>true,
];
echo json_encode($report, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR)."\n";
