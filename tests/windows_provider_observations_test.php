<?php
require __DIR__.'/windows_provider_observations.php';$checks=0;
function check_provider(bool $value): void {global $checks;if(!$value)throw new RuntimeException('Closed provider observation control failed.');$checks++;}
$row=['state'=>'failed','cause'=>'INCOMPATIBLE_DESTINATION','sip_status'=>'488','will_retry'=>'t','password'=>'PRIVATE','leg_uuid'=>'PRIVATE'];
$value=windows_provider_attempts([$row]);check_provider($value['cause']==='INCOMPATIBLE_DESTINATION'&&$value['sip_status']===488&&$value['will_retry']===true);check_provider(!str_contains(json_encode($value),'PRIVATE'));
foreach(['state','cause'] as $field){$bad=$row;$bad[$field]='PRIVATE';$value=windows_provider_attempts([$bad]);check_provider(!str_contains(json_encode($value),'PRIVATE'));}
foreach([true,[],'PRIVATE',-1,700] as $bad){$copy=$row;$copy['sip_status']=$bad;check_provider(windows_provider_attempts([$copy])['sip_status']===0);}
foreach(['f','false',false,0,'0'] as $false){$copy=$row;$copy['will_retry']=$false;check_provider(windows_provider_attempts([$copy])['will_retry']===false);}
$value=windows_provider_attempts(array_fill(0,17,$row));check_provider($value['count']===16&&$value['counts_capped']===true);check_provider(windows_provider_attempts([])['state']==='absent');
$providers=[['trunk'=>'PRIVATE_PRIMARY'],['trunk'=>'PRIVATE_BACKUP']];$plan=['registered'=>true,'rule'=>'PRIVATE_RULE','routes'=>[['id'=>'PRIVATE_PRIMARY','available'=>false],['id'=>'PRIVATE_BACKUP','available'=>true]],'provider'=>'PRIVATE_BACKUP'];
$value=windows_provider_plan($plan,$providers,'PRIVATE_RULE');check_provider($value['observed']&&$value['registered']&&$value['rule_matches']&&$value['selected_index']===1&&!$value['primary_available']&&$value['backup_available']);check_provider(!str_contains(json_encode($value),'PRIVATE'));
foreach(['No outgoing rule matches this phone and number. Open Outbound Rules.'=>'no_rule','The providers for this number are off or unavailable. Review SIP Trunks before starting.'=>'providers_unavailable','PRIVATE'=>'other'] as $text=>$expected){$plan['error']=$text;check_provider(windows_provider_plan($plan,$providers,'PRIVATE_RULE')['error']===$expected);}
echo json_encode(['schema'=>1,'state'=>'passed','checks'=>$checks,'actual_php_projection'=>true,'native_engine_or_database_invoked'=>false]).PHP_EOL;
