# Test-only closed hold diagnostics. Never returns addresses, headers or identities.
function HoldFailureFields($Record){
 $row=$Record.hold_diagnostics
 if(($row -isnot [Collections.IDictionary] -and $row -isnot [pscustomobject]) -or ($row.schema -isnot [int] -and $row.schema -isnot [long]) -or $row.schema -ne 1 -or $row.stage -isnot [string] -or $row.stage -cnotin 'before','initial_invite','initial_destination','initial_media','hold_request','hold_music','resume_request','resumed_audio','transfer_request','transfer_destination','transferred_audio','end_transferred_call','complete'){return @{}}
 $safe=@{schema=1;stage=$row.stage}
 if($row.snapshot_unavailable -is [bool] -and $row.snapshot_unavailable){$safe.snapshot_unavailable=$true;return @{hold_diagnostics=$safe}}
 if(($row.elapsed_ms -isnot [int] -and $row.elapsed_ms -isnot [long]) -or $row.elapsed_ms -lt 0 -or $row.elapsed_ms -gt 3600000){return @{}};$safe.elapsed_ms=[long]$row.elapsed_ms
 $safe.codes=@{}
 foreach($code in 'invite','hold','resume','transfer'){$value=$row.codes.$code;if(($value -isnot [int] -and $value -isnot [long]) -or $value -lt 0 -or $value -gt 699){return @{}};$safe.codes[$code]=[int]$value}
 foreach($phase in 'before','after'){
  $safe[$phase]=@{}
  foreach($name in 'caller','first','second'){
   $peer=$row.$phase.$name;$part=@{}
   if($peer.contact -isnot [string] -or $peer.contact -cnotin 'registered','unregistered','unknown' -or $peer.receiver_failure -isnot [string] -or $peer.receiver_failure -cnotin 'none','ConnectionResetError','OSError','AssertionError','other'){return @{}}
   $part.contact=$peer.contact;$part.receiver_failure=$peer.receiver_failure
   foreach($field in 'contact_query_failed','receiver_running','registration_observed'){if($peer.$field -isnot [bool]){return @{}};$part[$field]=$peer.$field}
   foreach($limit in @(@('registration_code',0,699),@('requested_expires',-1,86400),@('accepted_expires',-1,86400),@('registration_age_ms',-1,3600000),@('new_invites',0,1000),@('new_dialogs',0,64),@('acked_dialogs',0,64),@('ended_dialogs',0,64))){
    $value=$peer.($limit[0]);if(($value -isnot [int] -and $value -isnot [long]) -or $value -lt $limit[1] -or $value -gt $limit[2]){return @{}};$part[$limit[0]]=[long]$value
   }
   $safe[$phase][$name]=$part
  }
 }
 return @{hold_diagnostics=$safe}
}
function AssertNativeHoldDiagnosticCases($Checks){
 $required=@('native_hold_diagnostic_immediate','native_hold_diagnostic_natural_expiry_observed','native_hold_diagnostic_reregistered','native_hold_diagnostic_identical_tuple_reregistered')
 foreach($name in $required){
  $rows=@($Checks|Where-Object {$_.case -is [string] -and $_.case -ceq $name})
  if($rows.Count -ne 1 -or $rows[0].passed -isnot [bool] -or !$rows[0].passed){throw 'Each actual hold/expiry/re-registration diagnostic must complete exactly once.'}
  $row=$rows[0]
  if($name -cin 'native_hold_diagnostic_immediate','native_hold_diagnostic_reregistered'){
   foreach($field in 'correlation','held_seconds'){$value=$row.$field;if(($value -isnot [double] -and $value -isnot [single] -and $value -isnot [int] -and $value -isnot [long]) -or [double]::IsNaN($value) -or [double]::IsInfinity($value)){throw 'Actual hold music measurements are required.'}}
   if($row.correlation -lt .75 -or $row.correlation -gt 1.000001 -or $row.held_seconds -lt 7 -or $row.held_seconds -gt 60){throw 'The unchanged held music thresholds must pass.'}
  }else{
   if($row.no_product_registration_change -isnot [bool] -or !$row.no_product_registration_change){throw 'The diagnostic must leave product registration settings unchanged.'}
   if($name -ceq 'native_hold_diagnostic_natural_expiry_observed'){
    if(($row.requested_expires -isnot [int] -and $row.requested_expires -isnot [long]) -or $row.requested_expires -ne 120 -or $row.negotiated_expires -isnot [array] -or $row.negotiated_expires.Count -ne 3){throw 'The actual negotiated short leases are required.'}
    foreach($value in $row.negotiated_expires){if(($value -isnot [int] -and $value -isnot [long]) -or $value -lt 1 -or $value -gt 180){throw 'The actual negotiated short leases are invalid.'}}
   }else{foreach($field in 'exact_tuples_preserved','all_three_actual_contacts_returned'){if($row.$field -isnot [bool] -or !$row.$field){throw 'Actual identical-tuple re-registration must pass.'}}}
  }
 }
}
