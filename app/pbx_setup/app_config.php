<?php
$apps[$x]['name'] = 'PBX Setup';
$apps[$x]['uuid'] = '7bc5a01f-1a32-4ad9-8a9a-0c7a861eaa10';
$apps[$x]['category'] = 'Applications';
$apps[$x]['version'] = '1.0';
$apps[$x]['license'] = 'Mozilla Public License 1.1';
$apps[$x]['description']['en-us'] = 'Guided PBX setup and reviewed migration from compatible 3CX backup configuration.';
$apps[$x]['permissions'][0]['name'] = 'pbx_setup_manage';
$apps[$x]['permissions'][0]['groups'] = ['superadmin','tenant_admin'];
$apps[$x]['permissions'][0]['menu']['uuid'] = '7bc5a01f-1a32-4ad9-8a9a-0c7a861eaa11';
