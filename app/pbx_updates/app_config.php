<?php
$apps[$x]['name'] = 'Updates';
$apps[$x]['uuid'] = '5a609fd8-a63f-47f2-9a50-47903c6b2104';
$apps[$x]['category'] = 'Applications';
$apps[$x]['version'] = '1.0';
$apps[$x]['license'] = 'Mozilla Public License 1.1';
$apps[$x]['description']['en-us'] = 'Verified server updates and tenant Android update policies.';
$apps[$x]['permissions'][0]['name'] = 'pbx_update_manage';
$apps[$x]['permissions'][0]['groups'] = ['superadmin','tenant_admin'];
$apps[$x]['permissions'][0]['menu']['uuid'] = '5a609fd8-a63f-47f2-9a50-47903c6b2105';
$apps[$x]['permissions'][1]['name'] = 'pbx_update_instance';
$apps[$x]['permissions'][1]['groups'] = ['superadmin'];
