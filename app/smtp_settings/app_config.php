<?php
$apps[$x]['name'] = 'SMTP Outgoing Mail';
$apps[$x]['uuid'] = '986b9340-3285-4708-840d-eb5790e94110';
$apps[$x]['category'] = 'System';
$apps[$x]['version'] = '1.0';
$apps[$x]['license'] = 'Mozilla Public License 1.1';
$apps[$x]['description']['en-us'] = 'Configure the outgoing SMTP server for all tenants.';
$apps[$x]['permissions'][0]['name'] = 'smtp_settings_manage';
$apps[$x]['permissions'][0]['groups'] = ['superadmin'];
$apps[$x]['permissions'][0]['menu']['uuid'] = '986b9340-3285-4708-840d-eb5790e94111';
