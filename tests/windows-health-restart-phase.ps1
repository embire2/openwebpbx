# QA-only closed observation consumer. No native API or PBX operations.
function Read-HealthRestartPhase($Value){
 $fields=@('schema','state','snapshot_atomic','runtime_observed','runtime_ready','holds','journals','database_observed','backends','error_kind')
 function PhaseKeys($Object,[string[]]$Expected){
  $keys=if($Object -is [pscustomobject]){@($Object.PSObject.Properties.Name)}elseif($Object -is [Collections.IDictionary]){@($Object.Keys)}else{@()}
  if($keys.Count -ne $Expected.Count -or @($keys|Where-Object {$_ -cnotin $Expected}).Count){throw 'The closed restart phase shape differs.'}
 }
 PhaseKeys $Value $fields
 if(($Value.schema -isnot [int] -and $Value.schema -isnot [long]) -or $Value.schema -ne 1 -or $Value.state -isnot [string] -or $Value.state -cne 'observed'){throw 'The restart phase identity differs.'}
 foreach($flag in 'snapshot_atomic','runtime_observed','runtime_ready','database_observed'){if($Value.$flag -isnot [bool]){throw 'A restart phase flag is mistyped.'}}
 if($Value.snapshot_atomic -or (!$Value.runtime_observed -and $Value.runtime_ready)){throw 'No atomic snapshot or unobserved readiness may be inferred.'}
 $expectedError=if($Value.runtime_observed){if($Value.database_observed){'none'}else{'database'}}else{if($Value.database_observed){'runtime'}else{'runtime_database'}}
 if($Value.error_kind -isnot [string] -or $Value.error_kind -cne $expectedError){throw 'The restart phase observation status differs.'}
 PhaseKeys $Value.holds @('calls','jobs','updates','backups');PhaseKeys $Value.journals @('installation','update','restore')
 foreach($name in 'calls','jobs','updates','backups'){if($Value.holds.$name -isnot [string] -or $Value.holds.$name -cnotin 'present','absent','unobserved' -or ($Value.runtime_observed -and $Value.holds.$name -ceq 'unobserved')){throw 'A fixed hold observation differs.'}}
 foreach($name in 'installation','update','restore'){if($Value.journals.$name -isnot [string] -or $Value.journals.$name -cnotin 'unobserved','absent','unsafe_type','unreadable','oversized','invalid','accepted','blocking' -or ($Value.runtime_observed -and $Value.journals.$name -ceq 'unobserved')){throw 'A fixed journal observation differs.'}}
 if($Value.backends -isnot [array] -or $Value.backends.Count -gt 32 -or (!$Value.database_observed -and $Value.backends.Count)){throw 'A bounded observed backend list is required.'}
 $backends=@()
 foreach($row in $Value.backends){
  PhaseKeys $row @('state','wait_type','wait_event','query_class')
  foreach($entry in @(@('state',@('active','idle','idle in transaction','idle in transaction (aborted)','fastpath function call','disabled','other')),@('wait_type',@('none','Activity','BufferPin','Client','Extension','IO','IPC','Lock','LWLock','Timeout','other')),@('wait_event',@('none','ClientRead','ClientWrite','advisory','relation','transactionid','tuple','other')),@('query_class',@('recovery_heartbeat','advisory_lock','guard_intent_read','guard_read','guard_write','health_read','health_write','configuration_read','transaction','session_setup','other')))){
   if($row.($entry[0]) -isnot [string] -or $row.($entry[0]) -cnotin $entry[1]){throw 'A closed backend state/wait/query class is required.'}
  }
  $backends+=@{state=$row.state;wait_type=$row.wait_type;wait_event=$row.wait_event;query_class=$row.query_class}
 }
 $out=[ordered]@{};foreach($field in $fields){$out[$field]=$Value.$field};$out.backends=$backends;return $out
}
