<?php
// Closed test-only projection; never return database identifiers or raw results.
function windows_provider_attempts(array $rows): array {
    $causes=['PROVIDER_UNAVAILABLE','SUCCESS','NORMAL_CLEARING','NORMAL_TEMPORARY_FAILURE','INCOMPATIBLE_DESTINATION','SERVICE_UNAVAILABLE','DESTINATION_OUT_OF_ORDER','INVALID_GATEWAY','GATEWAY_DOWN','CHAN_NOT_IMPLEMENTED','MANDATORY_IE_MISSING','INVALID_IE_CONTENTS','NO_ROUTE_DESTINATION','CALL_REJECTED','ORIGINATOR_CANCEL','NO_USER_RESPONSE','NO_ANSWER','NORMAL_CIRCUIT_CONGESTION','USER_BUSY','LOSE_RACE','ALLOTTED_TIMEOUT','RECOVERY_ON_TIMER_EXPIRE','WRONG_CALL_STATE','UNALLOCATED_NUMBER','NETWORK_OUT_OF_ORDER','SWITCH_CONGESTION','RESOURCE_UNAVAILABLE','CRASH','UNKNOWN'];
    $last=$rows?end($rows):[];$state=$last['state']??'absent';$cause=$last['cause']??'';$status=$last['sip_status']??0;$retry=$last['will_retry']??null;
    return ['observed'=>true,'count'=>min(16,count($rows)),'counts_capped'=>count($rows)>16,
        'state'=>in_array($state,['absent','calling','skipped','answered','failed','cancelled'],true)?$state:'unknown',
        'cause'=>$cause===''?'none':(in_array($cause,$causes,true)?$cause:'other'),
        'sip_status'=>(is_int($status)||(is_string($status)&&ctype_digit($status)))&&((int)$status===0||((int)$status>=100&&(int)$status<=699))?(int)$status:0,
        'will_retry'=>in_array($retry,[true,'true','t',1,'1'],true)?true:(in_array($retry,[false,'false','f',0,'0'],true)?false:null)];
}
function windows_provider_plan(array $plan,array $providers,string $rule): array {
    $out=['observed'=>false,'registered'=>false,'rule_matches'=>false,'routes_count'=>0,'primary_available'=>false,'backup_available'=>false,'selected_index'=>-1,'error'=>'other'];
    if(count($providers)!==2||!is_array($plan['routes']??null)||count($plan['routes'])>16)return $out;
    $out['observed']=true;$out['registered']=($plan['registered']??null)===true;$out['rule_matches']=($plan['rule']??null)===$rule;$out['routes_count']=count($plan['routes']);
    foreach($providers as $index=>$provider){foreach($plan['routes'] as $route)if(is_array($route)&&($route['id']??null)===$provider['trunk'])$out[$index===0?'primary_available':'backup_available']=($route['available']??null)===true;if(($plan['provider']??null)===$provider['trunk'])$out['selected_index']=$index;}
    $out['error']=!isset($plan['error'])?'none':match($plan['error']){
        'No outgoing rule matches this phone and number. Open Outbound Rules.'=>'no_rule',
        'The providers for this number are off or unavailable. Review SIP Trunks before starting.'=>'providers_unavailable',
        'Choose an enabled phone in your PBX.'=>'phone_unavailable',default=>'other'};
    return $out;
}
