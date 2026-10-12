<?php
$apps[$x]['name']='Switchboard';
$apps[$x]['uuid']='b19bd97f-e90c-43e9-9f22-64e4f9b03d01';
$apps[$x]['category']='Applications';
$apps[$x]['version']='1.0';
$apps[$x]['license']='Mozilla Public License 1.1';
$apps[$x]['description']['en-us']='Tenant-scoped receptionist switchboard and queue wallboard.';
foreach(['pbx_core_view','pbx_core_control','pbx_core_supervise'] as $i=>$name){$apps[$x]['permissions'][$i]['name']=$name;$apps[$x]['permissions'][$i]['groups']=['superadmin','tenant_admin'];}
$apps[$x]['permissions'][0]['menu']['uuid']='b19bd97f-e90c-43e9-9f22-64e4f9b03d02';
