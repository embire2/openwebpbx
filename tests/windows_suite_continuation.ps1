# Exercise actual AST-extracted runner controls with owned report files and
# mocked hooks/observer. No Windows services, native engines or PBX are invoked.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
. (Join-Path $SourceRoot 'tests/windows-hold-failure-fields.ps1')
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-suite.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The actual suite must parse.'}
foreach($name in 'SafeQueueFailureFields','SafeVoicemailFailureFields','SafeMailboxFailureFields','SafeHotelFailureFields','SafeSmtpFailureFields','SafeNativeCleanupFields','SafeMeetingOwnerPageFields','SafeMeetingMediaFields','SafeMeetingSignalingFields','SafeMeetingPathFields','SafeFailureFields','RememberHookFailure','RememberSuiteFailure','NativeCleanupIsExact','NativeIdleIsHealthy','NativeAcceptanceHook'){
 $nodes=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true))
 if($nodes.Count -ne 1){throw 'Actual runner control must be uniquely identified.'}
 Invoke-Expression $nodes[0].Extent.Text
}
$final=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$facts.state' -and $node.Right.Extent.Text.Contains('elseif($missing.Count)')},$true))
if($final.Count -ne 1){throw 'The actual final-state assignment must be uniquely identified.'}
$finalExpression=$final[0].Right.Extent.Text
$checks=0
function Check([bool]$Value){if(!$Value){throw 'The native continuation control failed.'};$script:checks++}
function ReportRecord {
 [pscustomobject]@{schema=1;state='failed';gates=[pscustomobject]@{cleanup='passed'};cleanup='Original factory rows/contacts/identity/profile/config/certificate binding restored; owned CA/leaf and private probe task removed';active_case='native_voicemail_recording_and_email_queue';primary_substage='voicemail_message_created';primary_error_type='AssertionError';primary_source_basename='windows-native-acceptance.py';primary_source_line=269;error_type='AssertionError';source_basename='windows-native-acceptance.py';source_line=269;password='PRIVATE_NEVER_PUBLISH';error='PRIVATE_NEVER_PUBLISH'}
}
function HealthyObserver {
 [pscustomobject]@{schema=1;service_observed=$true;service_state='Running';service_status='OK';win32_exit_code=[uint32]0;service_specific_exit_code=[uint32]0;event_query_succeeded=$true;events=@();log_categories=@{xml_error=$true};native_queries=[pscustomobject]@{attempted=$true;authenticated=$true;sofia_loaded=$true;lua_loaded=$true;pgsql_loaded=$true;pause_state_known=$true;channels_known=$true;channels_count=[long]0;internal_profile_available=$true}}
}
function AcceptanceHook([string]$Name,[string]$Report){
 $script:hookCalls++
 if($script:hookMode -eq 'missing'){return $null}
 if($script:hookMode -eq 'passed'){return [pscustomobject]@{state='passed'}}
 if(Test-Path -LiteralPath $Report){try{RememberHookFailure (Get-Content -LiteralPath $Report -Raw|ConvertFrom-Json)}catch{}}
 throw 'PRIVATE_NEVER_PUBLISH'
}
function NativeStartupFailure([DateTime]$StartedAt,[string]$PrivateDirectory){
 $script:observerCalls++
 if($script:observerThrows){throw 'PRIVATE_NEVER_PUBLISH'}
 return $script:observer
}
function ResetCase {
 $script:facts=[ordered]@{state='running';gates=[ordered]@{native_sip_audio='unqualified';upgrade='pending';backups='pending';outside_acme='unqualified'}}
 $script:hookMode='failed';$script:hookCalls=0;$script:observerCalls=0;$script:observerThrows=$false;$script:observer=HealthyObserver;$script:later=@()
}
function RunCase([switch]$LaterFailure){
 try{
  $native=NativeAcceptanceHook $report ([DateTime]::UtcNow)
  if($native){$facts.gates.native_sip_audio='passed'}
  $script:later+='upgrade'
  if($LaterFailure){
   RememberHookFailure ([pscustomobject]@{active_case='owned_upgrade_failure';error_type='RuntimeError';source_basename='windows-upgrade-acceptance.ps1';source_line=22;password='PRIVATE_NEVER_PUBLISH'})
   try{throw 'PRIVATE_NEVER_PUBLISH'}catch{RememberSuiteFailure $_ 'upgrade acceptance hook'}
   return
  }
  $facts.gates.upgrade='passed';$script:later+='backups';$facts.gates.backups='passed'
  $missing=@($facts.gates.GetEnumerator()|Where-Object {$_.Value -ne 'passed'})
  $facts.state=Invoke-Expression $finalExpression
 }catch{RememberSuiteFailure $_ 'native acceptance hook'}
}
$work=Join-Path ([IO.Path]::GetTempPath()) ('openweb-suite-continuation-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work);$report=Join-Path $work 'native.json'
try{
 ResetCase;(ReportRecord)|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $report
 $roundtrip=Get-Content -LiteralPath $report -Raw|ConvertFrom-Json
 Check (($roundtrip.schema -is [int] -or $roundtrip.schema -is [long]) -and (NativeCleanupIsExact $roundtrip))
 Check (NativeIdleIsHealthy ((HealthyObserver)|ConvertTo-Json -Depth 8|ConvertFrom-Json))
 RunCase
 Check (($later -join '|') -ceq 'upgrade|backups')
 Check ($facts.state -ceq 'failed' -and $facts.gates.native_sip_audio -ceq 'unqualified')
 Check ($facts.failed_phase -ceq 'native acceptance hook' -and $facts.hook_failure.active_case -ceq 'native_voicemail_recording_and_email_queue')
 Check ($facts.hook_failure.primary_substage -ceq 'voicemail_message_created')
 Check ($facts.native_continuation -ceq 'independent gates only' -and $observerCalls -eq 1)
 Check ($facts.gates.upgrade -ceq 'passed' -and $facts.gates.backups -ceq 'passed')
 Check (($facts|ConvertTo-Json -Depth 12) -notmatch 'PRIVATE_NEVER_PUBLISH|password')
 ResetCase;RunCase -LaterFailure
 Check ($facts.failed_phase -ceq 'native acceptance hook' -and $facts.hook_failure.active_case -ceq 'native_voicemail_recording_and_email_queue')
 Check ($facts.hook_failure.primary_substage -ceq 'voicemail_message_created' -and $facts.hook_failure.primary_source_line -eq 269)
 Check ($facts.secondary_failure.hook_failure.active_case -ceq 'owned_upgrade_failure' -and $facts.secondary_failure.runner_failure.failed_phase -ceq 'upgrade acceptance hook')
 Check ($facts.state -ceq 'failed' -and ($later -join '|') -ceq 'upgrade')
 Check (($facts|ConvertTo-Json -Depth 12) -notmatch 'PRIVATE_NEVER_PUBLISH|password')
 foreach($field in 'schema','state','cleanup','gate'){
  foreach($bad in $null,$true,'PRIVATE_NEVER_PUBLISH',@('passed')){
   ResetCase;$record=ReportRecord
   if($field -eq 'gate'){$record.gates.cleanup=$bad}else{$record.$field=$bad}
   $record|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $report;RunCase
   Check ($later.Count -eq 0 -and $facts.state -eq 'failed' -and $facts.native_continuation -ceq 'aborted_cleanup' -and $observerCalls -eq 0)
  }
 }
 foreach($bad in 0,2,'1',1.5){$record=ReportRecord;$record.schema=$bad;Check (!(NativeCleanupIsExact $record))}
 ResetCase;Remove-Item -LiteralPath $report;RunCase
 Check ($later.Count -eq 0 -and $facts.native_continuation -ceq 'aborted_cleanup')
 ResetCase;$hookMode='missing';RunCase
 Check ($later.Count -eq 0 -and $facts.native_continuation -ceq 'aborted_cleanup')
 ResetCase;Set-Content -LiteralPath $report -Value '{ invalid json';RunCase
 Check ($later.Count -eq 0 -and $facts.native_continuation -ceq 'aborted_cleanup')
 (ReportRecord)|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $report
 foreach($field in 'service_observed','event_query_succeeded','attempted','authenticated','sofia_loaded','lua_loaded','pgsql_loaded','pause_state_known','channels_known','internal_profile_available'){
  foreach($bad in $false,$null,'true',1){
   ResetCase
   if($field -in 'service_observed','event_query_succeeded'){$observer.$field=$bad}else{$observer.native_queries.$field=$bad}
   RunCase;Check ($later.Count -eq 0 -and $facts.native_continuation -ceq 'aborted_health' -and $observerCalls -eq 1)
  }
 }
 foreach($field in 'win32_exit_code','service_specific_exit_code','channels_count'){
  foreach($bad in 1,-1,$null,$false,'0',0.0){
   ResetCase;if($field -eq 'channels_count'){$observer.native_queries.$field=$bad}else{$observer.$field=$bad}
   RunCase;Check ($later.Count -eq 0 -and $facts.native_continuation -ceq 'aborted_health')
  }
 }
 foreach($field in 'schema','service_state','service_status','events'){
  foreach($bad in $null,$true,'PRIVATE_NEVER_PUBLISH'){
   ResetCase;$observer.$field=$bad;RunCase;Check ($later.Count -eq 0 -and $facts.native_continuation -ceq 'aborted_health')
  }
 }
 ResetCase;$observer.events=@([pscustomobject]@{event_id=1000;exception_code='c0000005'});RunCase
 Check ($later.Count -eq 0 -and $facts.native_continuation -ceq 'aborted_health')
 ResetCase;$observerThrows=$true;RunCase
 Check ($later.Count -eq 0 -and $facts.native_continuation -ceq 'aborted_health')
 ResetCase;$hookMode='passed';RunCase
 Check ($facts.state -ceq 'partial' -and $facts.gates.native_sip_audio -ceq 'passed' -and ($later -join '|') -ceq 'upgrade|backups')
 Check ($observerCalls -eq 0 -and !$facts.Contains('failed_phase') -and !$facts.Contains('hook_failure') -and !$facts.Contains('secondary_failure'))
 $facts.gates.outside_acme='passed';$missing=@();$facts.state=Invoke-Expression $finalExpression;Check ($facts.state -ceq 'passed')
}finally{Remove-Item -LiteralPath $work -Recurse -Force}
Write-Output "PASS $checks actual AST/JSON/native-failure continuation controls; no PBX invoked"
