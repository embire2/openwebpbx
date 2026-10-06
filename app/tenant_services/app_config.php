<?php
$apps[$x]['name'] = 'Tenant Services';
$apps[$x]['uuid'] = '1c279eb7-b1c1-4f67-bef8-dda4a1110100';
$apps[$x]['category'] = 'Applications';
$apps[$x]['version'] = '1.0';
$apps[$x]['license'] = 'Mozilla Public License 1.1';
$apps[$x]['description']['en-us'] = 'Invite-only tenants, PBX templates, and isolated service provisioning.';
foreach (['pbx_service_view','pbx_service_create','pbx_template_manage','pbx_tenant_manage'] as $i => $name) {
    $apps[$x]['permissions'][$i]['name'] = $name;
    $apps[$x]['permissions'][$i]['groups'] = $name === 'pbx_tenant_manage' ? ['superadmin'] : ['superadmin','tenant_admin'];
}
$apps[$x]['permissions'][0]['menu']['uuid'] = '1c279eb7-b1c1-4f67-bef8-dda4a1110101';
