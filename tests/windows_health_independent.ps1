# Actual QA continuation AST with owned files and fictional observers only.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$checks=0;$tokens=$null;$errors=$null
function Check([bool]$Value){if(!$Value){throw ('Health continuation control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-suite.ps1'),[ref]$tokens,[ref]$errors);Check ($errors.Count -eq 0)
foreach($name in 'SafePhoneHealthFailure','SafeFailureFields','SafeQueueFailureFields','SafeVoicemailFailureFields','SafeMailboxFailureFields','SafeHotelFailureFields','SafeSmtpFailureFields','SafeMeetingOwnerPageFields','SafeMeetingMediaFields','SafeMeetingSignalingFields','SafeMeetingPathFields','SafeNativeCleanupFields','RememberSuiteFailure','NativeIdleIsHealthy'){$nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));Check ($nodes.Count -eq 1);Invoke-Expression $nodes[0].Extent.Text}
. (Join-Path $SourceRoot 'tests/windows-suite-independent.ps1')
function Fixture {return @{schema=1;producer='windows_phone_health_acceptance.ps1';state='failed';actual_native_windows=$true;physical_phone_audio=$false;policy_signalling_doubles=$true;diagnostic_recovery_exact=$true;gates=@{installed_task='passed';installed_system_observer='passed';installed_continuous_observer='passed';installed_restart='passed';installed_collector='passed';native_worker='pending';cleanup='passed'};private='PRIVATE'}}
function PhoneHealthHook {if($pass){$facts.gates.phone_health='passed';return};throw 'PRIVATE'}
function NativeStartupFailure {$script:observerCalls++;return @{schema=1;service_state='Running';service_status='OK';events=@();service_observed=$true;event_query_succeeded=$true;win32_exit_code=0;service_specific_exit_code=0;native_queries=@{attempted=$true;authenticated=$true;sofia_loaded=$true;lua_loaded=$true;pgsql_loaded=$true;pause_state_known=$true;channels_known=$true;internal_profile_available=$true;channels_count=$channels}}}
function Get-SuiteIndependentHealth {return $web}
$work=Join-Path ([IO.Path]::GetTempPath()) ('openweb-health-independent-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($work);$path=Join-Path $work 'phone-health-native.json'
function Reset {
 $script:facts=[ordered]@{state='running';gates=@{phone_health='unqualified'}};$script:pass=$false;$script:channels=0;$script:observerCalls=0;$script:ReplaySuiteRunId='39835943565';$script:later=$false
 $script:web=@{schema=1;local_service=$true;local_version_matches=$true;trusted_iis=$true;local_class='running';iis_class='ready';iis_status=200};Fixture|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $path
}
function Run {try{PhoneHealthAcceptanceHook ([DateTime]::UtcNow);$script:later=$true}catch{}}
try{
 Reset;Run;Check ($later -and $facts.state -ceq 'failed' -and $facts.gates.phone_health -ceq 'unqualified' -and $facts.failed_phase -ceq 'native phone health qualification' -and $facts.phone_health_continuation -ceq 'independent gates only');Check (!$facts.release_eligible -and !$facts.owner_transaction_eligible -and $observerCalls -eq 1);Check (($facts|ConvertTo-Json -Depth 10) -cnotmatch 'PRIVATE')
 foreach($field in 'schema','producer','state','actual_native_windows','physical_phone_audio','policy_signalling_doubles','diagnostic_recovery_exact'){
  foreach($bad in $null,'PRIVATE',@($true),@{},2){Reset;$row=Fixture;$row[$field]=$bad;$row|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $path;Run;Check (!$later -and $facts.state -ceq 'failed' -and $facts.phone_health_continuation -ceq 'aborted_report' -and $observerCalls -eq 0)}
 }
 foreach($field in 'installed_task','installed_system_observer','installed_continuous_observer','installed_restart','installed_collector','native_worker','cleanup'){
  foreach($bad in $null,'PRIVATE',@('passed'),$true){Reset;$row=Fixture;$row.gates[$field]=$bad;$row|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $path;Run;Check (!$later -and $facts.phone_health_continuation -ceq 'aborted_report')}
 }
 Reset;$row=Fixture;$row.diagnostic_recovery_exact=$false;$row|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $path;Run;Check (!$later -and $facts.phone_health_continuation -ceq 'aborted_report')
 Reset;$row=Fixture;$row.diagnostic_recovery_failure=@{error_type='RuntimeException';source_line=42};$row|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $path;Run;Check (!$later -and $facts.phone_health_continuation -ceq 'aborted_report')
 foreach($bad in @{},$null,0,'PRIVATE'){Reset;$row=Fixture;$row.diagnostic_recovery_failure=$bad;$row|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $path;Run;Check (!$later -and $facts.phone_health_continuation -ceq 'aborted_report')}
 Reset;$row=Fixture;$row.gates.native_worker='passed';$row|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $path;Run;Check (!$later -and $facts.phone_health_continuation -ceq 'aborted_report')
 Reset;$ReplaySuiteRunId='';Run;Check (!$later -and $facts.phone_health_continuation -ceq 'aborted_report')
 Reset;Remove-Item -LiteralPath $path;Run;Check (!$later -and $facts.phone_health_continuation -ceq 'aborted_report')
 Reset;Set-Content -LiteralPath $path -Value '{invalid';Run;Check (!$later -and $facts.phone_health_continuation -ceq 'aborted_report')
 Reset;(Get-Item -LiteralPath $path).LastWriteTimeUtc=[DateTime]::UtcNow.AddMinutes(-1);Run;Check (!$later -and $facts.phone_health_continuation -ceq 'aborted_report')
 Reset;$channels=1;Run;Check (!$later -and $facts.phone_health_continuation -ceq 'aborted_health')
 foreach($field in 'schema','local_service','local_version_matches','trusted_iis','local_class','iis_class','iis_status'){
  foreach($bad in $null,'PRIVATE',@($true),@{},2){Reset;$web[$field]=$bad;Run;Check (!$later -and $facts.phone_health_continuation -ceq 'aborted_health')}
 }
 Reset;$pass=$true;Run;Check ($later -and $facts.state -ceq 'running' -and $facts.gates.phone_health -ceq 'passed' -and $observerCalls -eq 0 -and !$facts.Contains('release_eligible'))
 $row=Fixture;$row.diagnostic_recovery_exact='true';Check (!(SafePhoneHealthFailure $row).ContainsKey('diagnostic_recovery_exact'))
 $row=Fixture;$row.diagnostic_recovery_failure=@{error_type='RuntimeException';source_line=42;private='PRIVATE'};$safe=SafePhoneHealthFailure $row;Check ($safe.diagnostic_recovery_failure.Count -eq 2 -and ($safe|ConvertTo-Json -Depth 8) -cnotmatch 'PRIVATE')
}finally{Remove-Item -LiteralPath $work -Recurse -Force}
Write-Output ('PASS '+$checks+' actual recovery/report/independent-health controls; no installed PBX invoked')
