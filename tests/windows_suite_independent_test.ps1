# Actual QA helper/runner AST with owned files and mocked observers only.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$tokens=$null;$errors=$null
$suite=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-suite.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The suite must parse.'}
foreach($name in 'SafeQueueFailureFields','SafeVoicemailFailureFields','SafeMailboxFailureFields','SafeHotelFailureFields','SafeSmtpFailureFields','SafeNativeCleanupFields','SafeFailureFields','SafeTenantDomainsProof','SafeTenantDomainsReport','RememberSuiteFailure','NativeIdleIsHealthy'){
 $nodes=@($suite.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true))
 if($nodes.Count -ne 1){throw 'The actual runner control must be unique.'};Invoke-Expression $nodes[0].Extent.Text
}
$helperPath=Join-Path $SourceRoot 'tests/windows-suite-independent.ps1';$helper=[Management.Automation.Language.Parser]::ParseFile($helperPath,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The independent helper must parse.'};. $helperPath
$final=@($suite.FindAll({param($node)$node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$facts.state' -and $node.Right.Extent.Text.Contains('elseif($missing.Count)')},$true))
if($final.Count -ne 1){throw 'The actual final state control must be unique.'};$finalExpression=$final[0].Right.Extent.Text
$controls=0
function Assert([bool]$Value){if(!$Value){throw ('Independent continuation failed at test line '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:controls++}
function Record {
 [pscustomobject]@{schema=1;state='failed';case='native_windows_tenant_alias_worker_iis_https';phase='packaged_task';checks=5;exception_type='InvalidOperationException';source_basename='windows-tenant-domains-native.ps1';source_line=84;cleanup_exact=$true;actual_acme='unqualified';real_registry_dns_mutations=$false;password='PRIVATE_NEVER_PUBLISH';message='PRIVATE_NEVER_PUBLISH'}
}
function HealthyObserver {
 [pscustomobject]@{schema=1;service_observed=$true;service_state='Running';service_status='OK';win32_exit_code=[uint32]0;service_specific_exit_code=[uint32]0;event_query_succeeded=$true;events=@();native_queries=[pscustomobject]@{attempted=$true;authenticated=$true;sofia_loaded=$true;lua_loaded=$true;pgsql_loaded=$true;pause_state_known=$true;channels_known=$true;channels_count=[long]0;internal_profile_available=$true}}
}
function ResetCase {
 $script:facts=[ordered]@{state='running';gates=[ordered]@{tenant_domains='unqualified';later='pending'}}
 $script:hookMode='failed';$script:observer=HealthyObserver;$script:observerCalls=0;$script:observerThrows=$false;$script:webCalls=0;$script:webThrows=$false;$script:later=$false
 $script:web=[ordered]@{schema=1;local_service=$true;trusted_iis=$true;local_class='running';iis_class='ready';iis_status=200;password='PRIVATE_NEVER_PUBLISH'}
 (Record)|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $report
}
function TenantDomainsHook {
 if($script:hookMode -ceq 'passed'){$facts.gates.tenant_domains='passed';return}
 if($script:hookMode -ceq 'missing'){return}
 throw 'PRIVATE_NEVER_PUBLISH'
}
function NativeStartupFailure([DateTime]$StartedAt,[string]$PrivateDirectory){$script:observerCalls++;if($script:observerThrows){throw 'PRIVATE_NEVER_PUBLISH'};return $script:observer}
function Get-SuiteIndependentHealth {$script:webCalls++;if($script:webThrows){throw 'PRIVATE_NEVER_PUBLISH'};return $script:web}
function RunCase {
 try{TenantDomainsAcceptanceHook ([DateTime]::UtcNow);$script:later=$true;$facts.gates.later='passed'}catch{}
 $missing=@($facts.gates.GetEnumerator()|Where-Object {$_.Value -cne 'passed'});$UpgradeDiagnosticsOnly=$false;$BackupsDiagnosticsOnly=$false;$facts.state=Invoke-Expression $finalExpression
}
$work=Join-Path ([IO.Path]::GetTempPath()) ('openweb-independent-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($work);$report=Join-Path $work 'tenant-domains-native.json'
try{
 ResetCase;RunCase
 Assert ($later -and $facts.state -ceq 'failed' -and $facts.gates.tenant_domains -ceq 'unqualified' -and $facts.failed_phase -ceq 'native tenant-domain qualification')
 Assert ($facts.tenant_domains_continuation -ceq 'independent gates only' -and $facts.tenant_domains_independent_health.iis_status -eq 200 -and $observerCalls -eq 1 -and $webCalls -eq 1)
 Assert (($facts|ConvertTo-Json -Depth 10) -cnotmatch 'PRIVATE_NEVER_PUBLISH|password|message')
 try{throw 'PRIVATE_NEVER_PUBLISH'}catch{RememberSuiteFailure $_ 'later independent gate'}
 Assert ($facts.failed_phase -ceq 'native tenant-domain qualification' -and $facts.secondary_failure.runner_failure.failed_phase -ceq 'later independent gate')
 foreach($field in 'schema','state','case','phase','exception_type','source_basename','source_line','cleanup_exact','actual_acme','real_registry_dns_mutations','checks'){
  foreach($bad in $null,'PRIVATE_NEVER_PUBLISH',@('PRIVATE_NEVER_PUBLISH')){
   ResetCase;$record=Record;$record.$field=$bad;$record|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $report;RunCase
   Assert (!$later -and $facts.tenant_domains_continuation -ceq 'aborted_report' -and $observerCalls -eq 0 -and $webCalls -eq 0 -and $facts.state -ceq 'failed')
  }
 }
 foreach($phase in 'cleanup','complete'){ResetCase;$record=Record;$record.phase=$phase;$record|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $report;RunCase;Assert (!$later -and $facts.tenant_domains_continuation -ceq 'aborted_report')}
 ResetCase;Remove-Item -LiteralPath $report;RunCase;Assert (!$later -and $facts.tenant_domains_continuation -ceq 'aborted_report')
 ResetCase;Set-Content -LiteralPath $report -Value '{invalid';RunCase;Assert (!$later -and $facts.tenant_domains_continuation -ceq 'aborted_report')
 ResetCase;[IO.File]::WriteAllText($report,('x'*65537));RunCase;Assert (!$later -and $facts.tenant_domains_continuation -ceq 'aborted_report')
 ResetCase;(Get-Item -LiteralPath $report).LastWriteTimeUtc=[DateTime]::UtcNow.AddMinutes(-1);RunCase;Assert (!$later -and $facts.tenant_domains_continuation -ceq 'aborted_report')
 foreach($field in 'service_observed','event_query_succeeded','attempted','authenticated','sofia_loaded','lua_loaded','pgsql_loaded','pause_state_known','channels_known','internal_profile_available'){
  ResetCase;if($field -cin 'service_observed','event_query_succeeded'){$observer.$field=$false}else{$observer.native_queries.$field=$false};RunCase
  Assert (!$later -and $facts.tenant_domains_continuation -ceq 'aborted_health' -and !$facts.tenant_domains_independent_health.engine_idle)
 }
 ResetCase;$observer.native_queries.channels_count=1;RunCase;Assert (!$later -and $facts.tenant_domains_continuation -ceq 'aborted_health')
 foreach($field in 'schema','local_service','trusted_iis','local_class','iis_class','iis_status'){
  foreach($bad in $null,'PRIVATE_NEVER_PUBLISH',@('PRIVATE_NEVER_PUBLISH')){
   ResetCase;$web[$field]=$bad;RunCase;Assert (!$later -and $facts.tenant_domains_continuation -ceq 'aborted_health' -and ($facts|ConvertTo-Json -Depth 10) -cnotmatch 'PRIVATE_NEVER_PUBLISH')
  }
 }
 foreach($status in 0,301,403,500){ResetCase;$web.iis_status=$status;$web.trusted_iis=$false;$web.iis_class='http_status';RunCase;Assert (!$later -and $facts.tenant_domains_independent_health.iis_status -eq $status -and $facts.tenant_domains_continuation -ceq 'aborted_health')}
 foreach($classification in 'tls','timeout','content','transport','cleanup_refused'){ResetCase;$web.trusted_iis=$false;$web.iis_class=$classification;RunCase;Assert (!$later -and $facts.tenant_domains_independent_health.iis_class -ceq $classification -and $facts.tenant_domains_continuation -ceq 'aborted_health')}
 ResetCase;$observerThrows=$true;RunCase;Assert (!$later -and $facts.tenant_domains_continuation -ceq 'aborted_health')
 ResetCase;$webThrows=$true;RunCase;Assert (!$later -and $facts.tenant_domains_continuation -ceq 'aborted_health')
 ResetCase;$hookMode='missing';Remove-Item -LiteralPath $report;RunCase;Assert (!$later -and $facts.tenant_domains_continuation -ceq 'aborted_report')
 ResetCase;$hookMode='passed';RunCase;Assert ($later -and $facts.state -ceq 'passed' -and $observerCalls -eq 0 -and $webCalls -eq 0 -and !$facts.Contains('failed_phase'))
 $record=[pscustomobject]@{Exception=[InvalidOperationException]::new('PRIVATE_NEVER_PUBLISH',[Security.Authentication.AuthenticationException]::new('PRIVATE_NEVER_PUBLISH'))}
 Assert ((Get-SuiteIndependentFailureClass $record) -ceq 'tls')
 $record.Exception=[Threading.Tasks.TaskCanceledException]::new('PRIVATE_NEVER_PUBLISH');Assert ((Get-SuiteIndependentFailureClass $record) -ceq 'timeout')
 $record.Exception=[IO.IOException]::new('PRIVATE_NEVER_PUBLISH');Assert ((Get-SuiteIndependentFailureClass $record) -ceq 'transport')
 $network=@($helper.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-SuiteIndependentHealth'},$true))[0].Extent.Text
 Assert ($network.Contains("'https://windowsqa.example.invalid:8443/login.php'") -and $network.Contains("'http://127.0.0.1:8087/health'"))
 Assert ($network.Contains('$handler.AllowAutoRedirect=$false') -and $network.Contains('$handler.UseProxy=$false') -and $network.Contains('$handler.UseCookies=$false'))
 Assert ($network -cnotmatch 'ServerCertificateCustomValidationCallback|ServerCertificateValidationCallback|SkipCertificateCheck')
 Assert ($network.Contains('$sessionBefore.Contains($name)') -and $network.Contains('ReadAsync($buffer,0,$buffer.Length,$cancel.Token)'))
}finally{Remove-Item -LiteralPath $work -Recurse -Force}
Write-Output ('PASS '+$controls+' actual independent continuation/report/health/privacy controls; no PBX invoked')
