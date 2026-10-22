<?php
if(!in_array(PHP_OS_FAMILY,['Linux','Windows'],true))return;
$y=0;
$apps[$x]['menu'][$y]['title']['en-us']='Phone Health';
$apps[$x]['menu'][$y]['title']['en-gb']='Phone Health';
$apps[$x]['menu'][$y]['uuid']='86023070-278f-4b4f-bb93-d5128f439ac0';
$apps[$x]['menu'][$y]['parent_uuid']='';
$apps[$x]['menu'][$y]['category']='internal';
$apps[$x]['menu'][$y]['icon']='fa-solid fa-heart-pulse';
$apps[$x]['menu'][$y]['path']='/app/pbx_phone_health/';
$apps[$x]['menu'][$y]['order']='11';
$apps[$x]['menu'][$y]['groups']=['superadmin','tenant_admin'];
