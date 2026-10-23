# Closed actual-source failure projection; no installed helpers or services run.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest;$checks=0
. (Join-Path $SourceRoot 'tests/windows-native-cleanup-row-fields.ps1')
function Check([bool]$Value){if(!$Value){throw ('Drain projection control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
function Record {return [ordered]@{schema=1;producer='windows-native-cleanup-drain.php';state='failed';stage='spool_path';reason='spool_path';error_type='RuntimeException';source_basename='windows-native-cleanup-drain.php';source_line=35;child_exit_code=1}}
$record=Record;$record.password='PRIVATE';$record.configured_spool_path='PRIVATE';$record.message='PRIVATE';$safe=Get-NativeCleanupDrainFailureFields $record
Check ($safe.Count -eq 9 -and $safe.reason -ceq 'spool_path' -and ($safe|ConvertTo-Json -Depth 8) -cnotmatch 'PRIVATE|password|message|configured_spool_path')
foreach($key in @((Record).Keys)){
 $copy=Record;$copy.Remove($key);Check ((Get-NativeCleanupDrainFailureFields $copy).Count -eq 0)
 foreach($bad in $null,$true,@('PRIVATE'),@{secret='PRIVATE'}){$copy=Record;$copy[$key]=$bad;Check ((Get-NativeCleanupDrainFailureFields $copy).Count -eq 0)}
}
foreach($key in 'schema','source_line','child_exit_code'){
 foreach($bad in '1',1.5,-1,0,100001){$copy=Record;$copy[$key]=$bad;Check ((Get-NativeCleanupDrainFailureFields $copy).Count -eq 0)}
}
foreach($key in 'producer','state','stage','reason','error_type','source_basename'){$copy=Record;$copy[$key]='PRIVATE';Check ((Get-NativeCleanupDrainFailureFields $copy).Count -eq 0)}
foreach($key in 'input_scope_validated','owned_service_validated','spool_directory_exists','spool_directory_link','spool_expected_engine_log','configured_log_setting_present','native_log_authenticated','native_log_observed','configured_matches_native_log','native_log_spool_directory_exists'){
 foreach($value in $false,$true){$copy=Record;$copy[$key]=$value;$safe=Get-NativeCleanupDrainFailureFields $copy;Check ($safe.ContainsKey($key) -and $safe[$key] -eq $value)}
 foreach($bad in 'true',0,$null,@($true)){$copy=Record;$copy[$key]=$bad;Check ((Get-NativeCleanupDrainFailureFields $copy).Count -eq 0)}
}
foreach($kind in 'legacy_posix_path','native_engine_log','other'){$copy=Record;$copy.configured_spool_kind=$kind;Check ((Get-NativeCleanupDrainFailureFields $copy).configured_spool_kind -ceq $kind)}
foreach($bad in 'PRIVATE',$null,1,$true,@('native_engine_log')){$copy=Record;$copy.configured_spool_kind=$bad;Check ((Get-NativeCleanupDrainFailureFields $copy).Count -eq 0)}
foreach($bad in $null,'PRIVATE',1,$true,@((Record))){Check ((Get-NativeCleanupDrainFailureFields $bad).Count -eq 0)}
$copy=Record;$copy.schema=1L;$copy.source_line=100000L;$copy.child_exit_code=255L;Check ((Get-NativeCleanupDrainFailureFields $copy).Count -eq 9)
Write-Output ('PASS '+$checks+' strict actual-source drain failure omission/type/bound/privacy controls')
