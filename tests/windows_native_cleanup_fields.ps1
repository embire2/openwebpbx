# Actual AST cleanup/report projection controls; all operations are private mocks.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$tokens=$null;$errors=$null
$native=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-native-acceptance.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Native hook must parse.'}
$suite=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-suite.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Suite must parse.'}
foreach($pair in @(@($native,@('CompletedMediaCases','CollectNativeProgress','RecordNativeCleanupFailure','NativeCleanupFixtureFields')),@($suite,@('SafeQueueFailureFields','SafeVoicemailFailureFields','SafeMailboxFailureFields','SafeHotelFailureFields','SafeNativeCleanupFields','SafeFailureFields','NativeCleanupIsExact')))){
 foreach($name in $pair[1]){
  $nodes=@($pair[0].FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
  if($nodes.Count -ne 1){throw 'Actual function must be uniquely identified.'};Invoke-Expression $nodes[0].Extent.Text
 }
}
$nodes=@($native.FindAll({param($n)$n -is [Management.Automation.Language.TryStatementAst] -and $n.Body.Extent.Text.Contains('$cleanupPassed=$true') -and $n.Body.Extent.Text.Contains("`$cleanupStage='restore_factory'")},$true))
if($nodes.Count -ne 1){throw 'Actual native cleanup must be uniquely identified.'}
$cleanup=[scriptblock]::Create($nodes[0].Extent.Text)
$checks=0
function Check([bool]$Value){if(!$Value){throw ('The native cleanup diagnostic control failed at control line '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
$work=Join-Path ([IO.Path]::GetTempPath()) ('openweb-native-cleanup-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work);$evidence=$work;$privateInput=Join-Path $work 'input.json'
function SaveRecord($Value,[string]$Name='software-native-report.json'){$Value|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $work $Name)}
function ChildRecord {return [ordered]@{schema=1;producer='windows-native-acceptance.py';state='passed';checks=@([pscustomobject]@{case='native_tls_mailbox_wire_forwarding_exact_binary_wav';passed=$true;path='PRIVATE'},[pscustomobject]@{case='native_global_smtp_password_auth_actual_loopback';passed=$true;password='PRIVATE'},[pscustomobject]@{case='native_localservice_notification_store_reader';passed=$true},[pscustomobject]@{case='PRIVATE';passed=$true})}}
function FixtureRecord {return [ordered]@{schema=1;action='cleanup';stage='config_read';source_basename='windows-native-fixture.php';source_line=187;error_type='PDOException';message='PRIVATE';sql='PRIVATE';path='PRIVATE'}}
function MaybeFail {if($script:failStage -ceq $cleanupStage){throw 'PRIVATE_CLEANUP_MESSAGE'}}
function Stop-ScheduledTask {MaybeFail}
function Unregister-ScheduledTask {MaybeFail}
function Php {MaybeFail;return '{"factory_empty":true,"owned_rows":0,"owned_contacts":0}'}
function FixtureBinding {MaybeFail}
function Restart-Service {MaybeFail}
function Get-Service {return [pscustomobject]@{Status='Running'}}
function Stop-Process {MaybeFail}
function Remove-Item {MaybeFail}
function Test-Path {param([string]$LiteralPath) return $LiteralPath -eq 'OWNED_PRIVATE_FILE' -or ($LiteralPath -like '*unexpected-localservice-*' -and $script:failStage -ceq 'parent_write_guard')}
try{
 SaveRecord (ChildRecord)
 $fixturePath=$privateInput+'.cleanup.failure.json';(FixtureRecord)|ConvertTo-Json|Set-Content -LiteralPath $fixturePath
 $steps=@('stop_notification_task','remove_notification_task','restore_factory','restore_binding','restore_files','restart_engine','remove_leaf','remove_root','stop_pki','collect_pki_logs','parent_write_guard')
 foreach($primary in $false,$true){
  foreach($stage in $steps){
   $script:failStage=$stage;$facts=[ordered]@{schema=1;state='running';checks=@();gates=[ordered]@{cleanup='pending'}}
   if($primary){$facts.state='failed';$facts.failed_phase='normal HTTPS and native calling';$facts.error_type='AssertionError';$facts.source_basename='windows-native-acceptance.py';$facts.source_line=235;$facts.primary_substage='mailbox_main_menu_prompt'}
   $notificationTask='OWNED';$baseline=$true;$binding=$true;$originalBinding=@{hash=[byte[]]@(1);store='My'}
   $paths=@('owned');$originalFiles=@{owned='OWNED_PRIVATE_FILE'};$originalPresent=@{owned=$false};$state=$work;$scope='owned'
   $leaf=[pscustomobject]@{Thumbprint='OWNED_LEAF'};$rootCertificate=[pscustomobject]@{Thumbprint='OWNED_ROOT'}
   $pkiProcess=[pscustomobject]@{HasExited=$false;Id=999999}
   $pkiProcess|Add-Member ScriptMethod WaitForExit {param($Timeout)return $true};$pkiProcess|Add-Member ScriptMethod Dispose {}
   $pkiOutput=[pscustomobject]@{};$pkiOutput|Add-Member ScriptMethod GetAwaiter {return $this};$pkiOutput|Add-Member ScriptMethod GetResult {MaybeFail;return 'PRIVATE_LOG'};$pkiErrors=$pkiOutput
   $cleanupStage='stop_notification_task';$cleanupPassed=$false
   . $cleanup
   CollectNativeProgress $facts $evidence
   $safe=SafeFailureFields ([pscustomobject]$facts)
   $expectedType=if($stage -ceq 'collect_pki_logs'){'MethodInvocationException'}else{'RuntimeException'}
   Check (!$cleanupPassed -and $facts.state -ceq 'failed' -and $facts.cleanup -ceq 'failed' -and !(NativeCleanupIsExact ([pscustomobject]$facts)))
   Check ($safe.native_cleanup_stage -ceq $stage -and $safe.native_cleanup_error_type -ceq $expectedType -and $safe.native_cleanup_source_line -gt 0)
   Check ($safe.native_child_state -ceq 'passed' -and ($safe.completed_media_cases -join '|') -ceq 'native_tls_mailbox_wire_forwarding_exact_binary_wav|native_global_smtp_password_auth_actual_loopback')
   Check (($safe|ConvertTo-Json -Depth 8) -notmatch 'PRIVATE|OWNED|sql|Thumbprint')
   if($primary){Check ($safe.failed_phase -ceq 'normal HTTPS and native calling' -and $safe.error_type -ceq 'AssertionError' -and $safe.source_line -eq 235 -and $safe.primary_substage -ceq 'mailbox_main_menu_prompt')}
   else{Check ($safe.failed_phase -ceq 'exact scoped cleanup' -and $safe.active_case -ceq 'exact_scoped_cleanup' -and $safe.error_type -ceq $expectedType)}
   if($stage -ceq 'restore_factory'){Check ($safe.native_cleanup_fixture_source_basename -ceq 'windows-native-fixture.php' -and $safe.native_cleanup_fixture_source_line -eq 187 -and $safe.native_cleanup_fixture_error_type -ceq 'PDOException')}
   else{Check (@($safe.Keys|Where-Object {$_ -like 'native_cleanup_fixture_*'}).Count -eq 0)}
  }
 }
 # A PS-owned completion is retained, but the same name in a child is refused.
 $facts=@{completed_media_cases=@('native_localservice_notification_store_reader')};CollectNativeProgress $facts $evidence
 Check ($facts.completed_media_cases[-1] -ceq 'native_localservice_notification_store_reader')
 Check ((SafeFailureFields ([pscustomobject]$facts)).completed_media_cases[-1] -ceq 'native_localservice_notification_store_reader')
 foreach($field in 'schema','producer','state','checks'){
  foreach($bad in $null,$true,'PRIVATE',@{secret='PRIVATE'}){
   $record=ChildRecord;$record[$field]=$bad;SaveRecord $record;$facts=@{};CollectNativeProgress $facts $evidence
   Check (!$facts.ContainsKey('completed_media_cases') -and !$facts.ContainsKey('native_child_state'))
  }
 }
 $record=ChildRecord;$record.state='failed';$record.checks=@([pscustomobject]@{case='native_tls_mailbox_wire_forwarding_exact_binary_wav';passed='true'});SaveRecord $record;$facts=@{};CollectNativeProgress $facts $evidence
 Check ($facts.native_child_state -ceq 'failed' -and !$facts.ContainsKey('completed_media_cases'))
 $record=ChildRecord;$record.checks=@(1..257|ForEach-Object {[pscustomobject]@{case='native_tls_mailbox_wire_forwarding_exact_binary_wav';passed=$true}});SaveRecord $record;$facts=@{};CollectNativeProgress $facts $evidence
 Check (!$facts.ContainsKey('completed_media_cases'))
 [IO.File]::WriteAllText((Join-Path $work 'software-native-report.json'),('x'*1048577));$facts=@{};CollectNativeProgress $facts $evidence;Check (!$facts.ContainsKey('completed_media_cases'))
 $record=ChildRecord;$record.state='running';SaveRecord $record 'native-progress.json';$facts=@{};CollectNativeProgress $facts $evidence
 Check ($facts.completed_media_cases.Count -eq 2 -and !$facts.ContainsKey('native_child_state'))
 foreach($field in 'schema','action','stage','source_basename','source_line','error_type'){
  foreach($bad in $null,$true,'PRIVATE',@{secret='PRIVATE'}){
   $record=FixtureRecord;$record[$field]=if($field -ceq 'error_type' -and $bad -is [string]){'PRIVATE TYPE'}else{$bad};$record|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $fixturePath
   Check ((NativeCleanupFixtureFields $privateInput).Count -eq 0)
  }
 }
 [IO.File]::WriteAllText($fixturePath,('x'*2049));Check ((NativeCleanupFixtureFields $privateInput).Count -eq 0)
 $target=Join-Path $work 'valid-fixture.json';(FixtureRecord)|ConvertTo-Json|Set-Content -LiteralPath $target
 Microsoft.PowerShell.Management\Remove-Item -LiteralPath $fixturePath
 New-Item -ItemType SymbolicLink -Path $fixturePath -Target $target|Out-Null;Check ((NativeCleanupFixtureFields $privateInput).Count -eq 0)
 Microsoft.PowerShell.Management\Remove-Item -LiteralPath (Join-Path $work 'software-native-report.json'),(Join-Path $work 'native-progress.json')
 $target=Join-Path $work 'valid-child.json';(ChildRecord)|ConvertTo-Json -Depth 8|Set-Content -LiteralPath $target
 New-Item -ItemType SymbolicLink -Path (Join-Path $work 'software-native-report.json') -Target $target|Out-Null
 $facts=@{};CollectNativeProgress $facts $evidence;Check (!$facts.ContainsKey('completed_media_cases'))
 foreach($stage in 'PRIVATE','RESTORE_FACTORY','restore_factory ',$null){Check (!(SafeNativeCleanupFields ([pscustomobject]@{native_cleanup_stage=$stage;native_cleanup_error_type='PRIVATE'})).ContainsKey('native_cleanup_stage'))}
 foreach($bad in '187',$true,1.5,0,100001){Check (!(SafeNativeCleanupFields ([pscustomobject]@{native_cleanup_stage='restore_factory';native_cleanup_source_basename='windows-native-acceptance.ps1';native_cleanup_source_line=$bad})).ContainsKey('native_cleanup_source_line'))}
}finally{Microsoft.PowerShell.Management\Remove-Item -LiteralPath $work -Recurse -Force}
Write-Output "PASS $checks actual AST cleanup-stage/primary/progress/PHP-record/both-layer privacy controls; no Windows/PBX invoked"
