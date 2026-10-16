#Requires -RunAsAdministrator
#Requires -Version 7.4
<# Opt-in diagnostic only. Real fresh installed SYSTEM updater, existing product
lock, no customer/restore fixture, signatures, product changes or owner access. #>
[CmdletBinding()]
param([switch]$DisposableHostedRunner)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if(!$DisposableHostedRunner -or $env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows' -or $env:GITHUB_REPOSITORY -cne 'embire2/openwebpbx'){throw 'Only the explicitly disposable owned hosted Windows runner is authorized.'}
$os=Get-CimInstance Win32_OperatingSystem
if($os.ProductType -eq 1 -or $os.Caption -notmatch 'Windows Server 2025' -or [Environment]::OSVersion.Version.Build -lt 26100){throw 'A disposable Windows Server 2025 runner is required.'}
$source=Split-Path $PSScriptRoot -Parent;$root='C:\OpenWebPBX';$state=Join-Path $env:ProgramData 'OpenWebPBX';$configuration=Join-Path $env:ProgramData 'fusionpbx'
$work=Join-Path $env:RUNNER_TEMP ('openwebpbx-startup-lock-'+[Guid]::NewGuid().ToString('N'));$public=Join-Path $env:RUNNER_TEMP 'openwebpbx-startup-lock-facts'
$installed=$false;$heldLock=$null;$ownHosts=$false;$phase='verified baseline';$retainedProcesses=[Collections.Generic.List[Diagnostics.Process]]::new()
$selectedUpdaterExe="$root\updater\slots\1.0.13\OpenWebPbx.Updater.exe";$originalServicePath=$null;$bindingChanged=$false;$nativeStage=$null;$ownedCommand=$null;$oldSlotBefore=$null;$stageBefore=$null
$script:startupFailureRole=$null
$facts=[ordered]@{schema=1;run_id=$env:GITHUB_RUN_ID;source_commit=$env:GITHUB_SHA;state='running';mode='fixed-native-worker';native_run_id='38840969235';native_source_commit='1f8beff8b2fa2fd680fcc6da9c2f0026007684dd';scope='disposable Windows Server 2025 installed SYSTEM updater startup contention';release_eligible=$false;owner_eligible=$false;base_suite_run_id='38826730298';base_source_commit='97825554dbfe0e01689a9bc796c57884b0623fe3';base_archive_sha256='33d9a52375f27736149898599f0dbf621748e94f4820bd230801ab86e13e958d';fixed_worker=$null;cleanup='pending'}

# Import exact accepted helpers only, never the qualifier's entrypoint.
$helperSource=Join-Path $PSScriptRoot 'windows-updater-qualification.ps1';$tokens=$null;$errors=$null
if((Get-FileHash -LiteralPath $helperSource -Algorithm SHA256).Hash.ToLowerInvariant() -cne '0a45213c1d156264b4cf337e7e4a71682e99be075e79ea58bdb7994d420e4d4e'){throw 'The reviewed qualification helper bytes differ.'}
$ast=[Management.Automation.Language.Parser]::ParseFile($helperSource,[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw 'The reused qualification source did not parse.'}
foreach($name in 'Check','Hash','WriteJson','PrivateDirectory','SafeRelative','ExpandSafe','Api','Artifact','CheckedProcess','NativeVersions','StopQualificationIis','InstalledVersions','OriginalProcessProofSource','RetainQualificationProcess'){
 $nodes=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true))
 if($nodes.Count -ne 1){throw 'Exactly one accepted qualification helper is required.'}
 . ([ScriptBlock]::Create($nodes[0].Extent.Text))
}
$proofSource=Join-Path $PSScriptRoot 'windows-upgrade-acceptance.ps1'
if((Hash $proofSource) -cne '3761b3c3e8b30d07d88cc5309de4a21c315512e2d73b2ef5ca4480942a2ffc30'){throw 'The reviewed original-process proof bytes differ.'}
. (OriginalProcessProofSource $proofSource)
function ErrorKind([Exception]$Exception){$name=$Exception.GetType().Name;if($name -cin @('RuntimeException','IOException','InvalidOperationException','UnauthorizedAccessException','Win32Exception','TimeoutException')){return $name};return 'OtherError'}
function StartupFailureFields($Record,$Role){
 if($Record -isnot [Management.Automation.ErrorRecord]){return $null}
 $functions=@('Check','ServiceRecord','NoHolds','RetainStarted','ObserveFixedRecovery','RetainQualificationProcess','GetManagerOriginalExitProof','VerifyNewNative','ImmutableInventory','RequireInventoryEqual','ProbeSql','AssertHeldWorker','<ScriptBlock>');$frames=[Collections.Generic.List[object]]::new()
 $trace=$Record.ScriptStackTrace
 if($trace -and $trace.Length -le 16384){foreach($line in @([regex]::Split($trace,'\r?\n')|Select-Object -First 64)){
  if($frames.Count -ge 6){break}
  $match=[regex]::Match($line.Trim(),'\Aat (?<function>[^,\r\n]{1,80}), (?:(?:[^\r\n]*[\\/])?(?<source>windows-updater-startup-lock\.ps1|windows-updater-qualification\.ps1)|(?<imported><No file>)): line (?<line>[0-9]{1,5})\z')
  if(!$match.Success -or $match.Groups['function'].Value -cnotin $functions){continue}
  $number=[int]$match.Groups['line'].Value;if($number -lt 1 -or $number -gt 10000){continue}
  $frames.Add(@{function=$match.Groups['function'].Value;source_basename=if($match.Groups['imported'].Success){'imported_scriptblock'}else{$match.Groups['source'].Value};source_line=$number})
 }}
 $command=$Record.InvocationInfo.MyCommand.Name;if($command -cnotin @('Get-CimInstance','Invoke-CimMethod','Check','RetainStarted','RetainQualificationProcess','ObserveFixedRecovery')){$command='other'}
 $roleValue='unknown';$substage='unknown';$retainer=@($frames|Where-Object {$_.function -ceq 'RetainQualificationProcess' -and $_.source_basename -ceq 'imported_scriptblock'})
 if($retainer.Count -and @($frames|Where-Object {$_.function -ceq 'RetainStarted'}).Count){
  if($Role -is [string] -and $Role -cin @('worker','helper')){$roleValue=$Role}
  if($retainer[0].source_line -eq 5){$substage=if($command -ceq 'Get-CimInstance'){'retained_process_lookup'}elseif($command -ceq 'Invoke-CimMethod'){'retained_owner_sid'}else{'retained_process_lookup_or_owner_sid'}}
  elseif($retainer[0].source_line -eq 4){$substage='retained_handle_or_start_time'}
  elseif($retainer[0].source_line -eq 7){$substage='retained_identity_assertion'}
 }
 $known=@{'System.IO.IOException'='IOException';'System.InvalidOperationException'='InvalidOperationException';'System.UnauthorizedAccessException'='UnauthorizedAccessException';'System.ComponentModel.Win32Exception'='Win32Exception';'System.TimeoutException'='TimeoutException';'System.Management.Automation.RuntimeException'='RuntimeException';'System.Management.Automation.MethodInvocationException'='MethodInvocationException';'System.Management.Automation.ParameterBindingException'='ParameterBindingException';'System.Management.Automation.ParameterBindingValidationException'='ParameterBindingValidationException';'System.Management.Automation.ParameterBindingArgumentTransformationException'='ParameterBindingArgumentTransformationException';'Microsoft.Management.Infrastructure.CimException'='CimException'}
 $exceptions=[Collections.Generic.List[object]]::new();$exception=$Record.Exception
 for($depth=0;$exception -and $depth -lt 6;$depth++){
  $name=$exception.GetType().FullName;$type=if($known.ContainsKey($name)){$known[$name]}else{'OtherError'};$native=$null;$kind='none'
  if($name -ceq 'Microsoft.Management.Infrastructure.CimException'){$value=[long]$exception.NativeErrorCode;if($value -ge 0 -and $value -le 65535){$native=[int]$value;$kind='cim'}}
  elseif($exception -is [ComponentModel.Win32Exception] -and $exception.NativeErrorCode -ge 0 -and $exception.NativeErrorCode -le 65535){$native=[int]$exception.NativeErrorCode;$kind='win32'}
  $exceptions.Add(@{type=$type;hresult=[int]$exception.HResult;native_code=$native;native_kind=$kind});$exception=$exception.InnerException
 }
 return @{schema=1;process_role=$roleValue;substage=$substage;command=$command;callsites=$frames.ToArray();exceptions=$exceptions.ToArray()}
}
function AcquireProbeLock {
 # Same existing 40-second/250-ms cleanup guard pattern; never stop services
 # before acquiring it, never delete/create the lock or interrupt its holder.
 $clock=[Diagnostics.Stopwatch]::StartNew()
 do{
  try{return [IO.File]::Open("$state\upgrade.lock",'Open','ReadWrite','None')}catch{
   $native=$_.Exception;while($native.InnerException){$native=$native.InnerException}
   if($native -isnot [IO.IOException] -or $clock.Elapsed.TotalSeconds -ge 40){throw 'An owned transaction is still running; cleanup must not interrupt it.'}
   Start-Sleep -Milliseconds 250
  }
 }while($clock.Elapsed.TotalSeconds -lt 40)
 throw 'An owned transaction is still running; cleanup must not interrupt it.'
}
function ServiceRecord {
 $service=Get-CimInstance Win32_Service -Filter "Name='OpenWebPBXUpdater'"
 Check ($service -and $service.Name -ceq 'OpenWebPBXUpdater' -and $service.StartName -ceq 'LocalSystem' -and $service.StartMode -ceq 'Auto' -and $service.PathName.Trim('"') -ceq $selectedUpdaterExe) 'The exact ordinary installed SYSTEM service is required.'
 Check ($service.State -cin @('Running','Stopped','Start Pending','Stop Pending')) 'The owned service has an unexpected state.'
 return $service
}
function NoHolds {
 $gate=Get-OpenWebRestoreGate -StateRoot $state
 Check (!$gate.Blocked -and !$gate.Calls -and !$gate.Jobs -and !$gate.Updates -and !$gate.Backups) 'The diagnostic refuses real recovery or activation holds.'
 Check (!(Test-Path -LiteralPath "$state\updates\install-journal.json")) 'A fresh diagnostic must not have an update transaction.'
}
function RetainStarted($Record,[DateTime]$Started,[string]$Path,[ValidateSet('worker','helper')][string]$Role){
 $script:startupFailureRole=$null
 try{return RetainQualificationProcess ([Diagnostics.Process]::GetProcessById([int]$Record.ProcessId)) ([int]$Record.ProcessId) $Path 'S-1-5-18' 0 $Started}catch{
  try{$script:startupFailureRole=$Role}catch{}
  throw
 }
}
function VerifyNewNative($Native){
 Check ($Native.run.head_sha -ceq $facts.native_source_commit -and $Native.artifact.id -eq 12021002681 -and $Native.artifact.size_in_bytes -eq 184343137 -and $Native.artifact.digest -ceq 'sha256:c3e028e7154e4e5d7a7f07ace4b9f6bf85e612524488cf5144cc841b2892dc1c') 'The exact independently authenticated new native artifact is required.'
 foreach($pair in @(@('source-inputs.json','8b8d0513bc16d2ff6e773c0c901a8c4cfebb185290abf6621d59e6387778ec80'),@('verification.json','f927fac9e7ed91bb46d1563c11127905beb9f5a7e1b5f6388b215ed15dd454e7'),@('SHA256SUMS','a44b5d0a12e5568df3b6741628c1b9c55bf8ac6b850fc3b94941abc1077dfa13'))){Check ((Hash (Join-Path $Native.directory $pair[0])) -ceq $pair[1]) 'Native metadata bytes differ from the authenticated original.'}
 $inputs=Get-Content (Join-Path $Native.directory 'source-inputs.json') -Raw|ConvertFrom-Json
 Check ($inputs.source_commit -ceq $facts.native_source_commit -and $inputs.version -ceq '1.0.13' -and $inputs.sdk -ceq '10.0.401') 'Native source/version/SDK evidence differs.'
 $expected=@(git -C $source ls-files -- platform packaging/updates/release-public.pem VERSION);Check ($LASTEXITCODE -eq 0 -and $expected.Count -eq 55) 'The exact new native source inventory is required.'
 $provided=@($inputs.source_inputs|ForEach-Object path);Check ($provided.Count -eq 55 -and @(Compare-Object ($expected|Sort-Object) ($provided|Sort-Object)).Count -eq 0) 'The new native source set differs.'
 foreach($entry in $inputs.source_inputs){$relative=SafeRelative $entry.path;Check ($entry.sha256 -cmatch '\A[a-f0-9]{64}\z' -and (Hash (Join-Path $source $relative)) -ceq $entry.sha256) 'A new native source input differs.'}
 $manifest=@{};foreach($line in Get-Content (Join-Path $Native.directory 'SHA256SUMS')){
  $match=[regex]::Match($line,'\A([a-f0-9]{64})  (.+)\z');Check $match.Success 'The native checksum line is invalid.';$relative=SafeRelative $match.Groups[2].Value;$digest=$match.Groups[1].Value
  Check (!$manifest.ContainsKey($relative) -and (Hash (Join-Path $Native.directory $relative)) -ceq $digest) 'A native checksum member is duplicate or differs.';$manifest[$relative]=$digest
 }
 $files=@(Get-ChildItem -LiteralPath $Native.directory -Recurse -Force -File);Check ($manifest.Count -eq 1109 -and $files.Count -eq 1110) 'The complete native checksum inventory differs.'
 foreach($item in @(Get-Item -LiteralPath $Native.directory -Force)+@(Get-ChildItem -LiteralPath $Native.directory -Recurse -Force)){Check (!($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) 'A linked native artifact is refused.';if(!$item.PSIsContainer){$relative=[IO.Path]::GetRelativePath($Native.directory,$item.FullName).Replace('\','/');Check ($relative -ceq 'SHA256SUMS' -or $manifest.ContainsKey($relative)) 'An unlisted native member is refused.'}}
 NativeVersions $Native.directory '1.0.13'|Out-Null;$verification=Get-Content (Join-Path $Native.directory 'verification.json') -Raw|ConvertFrom-Json
 Check ($verification.version -ceq '1.0.13' -and $verification.protocol_checks -ceq 'passed' -and $verification.updater_checks -ceq 'passed' -and $verification.manager_startup.window_verified -and $verification.manager_startup.process_alive -and $verification.manager_startup.responsive) 'Original native checks and real manager evidence must pass.'
 Check ($manifest['updater/OpenWebPbx.Updater.dll'] -ceq '3b31f1dbacc760b74c32146fd2597df3558b9296e5464e0e14c7471c729511fa' -and $manifest['updater/OpenWebPbx.Updater.exe'] -ceq '2e7b28d007d928c6b5271a14d8ac0322127def7853075c7f8fece436779ec244') 'The exact corrected genuine updater is required.'
 return $manifest
}
function ImmutableInventory([string]$Directory){
 $items=@(Get-Item -LiteralPath $Directory -Force)+@(Get-ChildItem -LiteralPath $Directory -Recurse -Force);Check ($items.Count -le 5000) 'The owned immutable inventory exceeds its bound.';$result=@{}
 foreach($item in $items){Check (!($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) 'A linked immutable member is refused.';$record=@{directory=[bool]$item.PSIsContainer;acl=(Get-Acl -LiteralPath $item.FullName).Sddl;bytes=$null;sha256=$null};if(!$item.PSIsContainer){$record.bytes=[long]$item.Length;$record.sha256=Hash $item.FullName};$result[$item.FullName]=$record};return $result
}
function RequireInventoryEqual($Before,$After){
 Check ($Before.Count -eq $After.Count) 'The immutable inventory changed.'
 foreach($key in $Before.Keys){Check ($After.ContainsKey($key)) 'An immutable member disappeared.';foreach($field in 'directory','acl','bytes','sha256'){Check ($Before[$key][$field] -ceq $After[$key][$field]) 'An immutable descriptor or byte record changed.'}}
}
function ProbeSql([string]$Sql,[string]$Label){
 $prior=$env:PGPASSWORD
 try{$installation=Get-Content "$state\installation.json" -Raw|ConvertFrom-Json;$env:PGPASSWORD=$installation.PostgresPassword;CheckedProcess "$root\pgsql\bin\psql.exe" @('-h','127.0.0.1','-p','5433','-U','postgres','-d','fusionpbx','-X','-w','-v','ON_ERROR_STOP=1','-Atc',$Sql) ('fixed-worker-'+$Label) -Timeout 10000;return [IO.File]::ReadAllText((Join-Path $work ('fixed-worker-'+$Label+'.out'))).Trim()}finally{if($null -eq $prior){Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue}else{$env:PGPASSWORD=$prior}}
}
function AssertHeldWorker($Worker){
 $proof=GetManagerOriginalExitProof $Worker $Worker.pid;$service=ServiceRecord
 Check ($proof.manager_original_handle_pinned -and $proof.manager_original_identity_verified -and $proof.manager_original_exit_observed -and !$proof.manager_original_has_exited -and $service.State -ceq 'Running' -and $service.ProcessId -eq $Worker.pid) 'The same original corrected SYSTEM worker must remain live.'
}
function ObserveFixedRecovery {
 $service=ServiceRecord;Check ($service.State -ceq 'Stopped' -and $service.ProcessId -eq 0) 'The owned corrected updater must start from stopped.';NoHolds
 $started=[DateTime]::UtcNow;$clock=[Diagnostics.Stopwatch]::StartNew();Start-Service OpenWebPBXUpdater;$worker=$null
 do{$service=ServiceRecord;if($service.ProcessId -gt 0){$record=Get-CimInstance Win32_Process -Filter ('ProcessId='+$service.ProcessId);$worker=RetainStarted $record $started $selectedUpdaterExe 'worker';Check ($record.CommandLine -notmatch '--run-once|--check-once|--skip-recovery|--verify-package') 'The corrected worker must use its ordinary service loop.';break};Start-Sleep -Milliseconds 50}while($clock.Elapsed.TotalSeconds -lt 15)
 Check ($null -ne $worker) 'The corrected worker identity is unavailable.';$script:fixedWorkerHeld=$worker;$children=[Collections.Generic.List[object]]::new();$seen=[Collections.Generic.HashSet[int]]::new();$busyCount=0;$released=$false;$releasedAt=0L;$success=$false
 do{
  AssertHeldWorker $worker;NoHolds
  $records=@(Get-CimInstance Win32_Process -Filter ('ParentProcessId='+$worker.pid)|Where-Object {$_.Name -ieq 'powershell.exe'});Check ($records.Count -le 1) 'Recovery child identity is ambiguous.'
  if($records.Count -and !$seen.Contains([int]$records[0].ProcessId)){
   $record=$records[0];$helper="$root\tools\Upgrade-OpenWebPBX.ps1";$expected='\A(?:"(?:[^"\r\n]*\\)?powershell\.exe"|(?:[^"\s]*\\)?powershell\.exe) -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (?:"'+[regex]::Escape($helper)+'"|'+[regex]::Escape($helper)+') -Recover\z'
   Check ($record.CommandLine.Length -le 8192 -and $record.CommandLine -imatch $expected -and $children.Count -lt 12) 'The exact bounded installed recovery child is required.'
   $child=RetainStarted $record $started "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" 'helper';$seen.Add($child.pid)|Out-Null
   while(!$child.process.HasExited -and $clock.Elapsed.TotalSeconds -lt 90 -and $(if($released){$clock.ElapsedMilliseconds-$releasedAt -lt 60000}else{$clock.Elapsed.TotalSeconds -lt 30})){AssertHeldWorker $worker;Start-Sleep -Milliseconds 50}
   $proof=GetManagerOriginalExitProof $child $child.pid;Check ($proof.manager_original_handle_pinned -and $proof.manager_original_identity_verified -and $proof.manager_original_exit_observed -and $proof.manager_original_has_exited) 'The original recovery child exit is unavailable.';$code=[int]$child.process.ExitCode
   $children.Add(@{pid=[int]$child.pid;exit_code=$code;after_release=[bool]$released});AssertHeldWorker $worker
   if(!$released){
    Check ($code -eq 75) 'The held actual product lock must defer real recovery.';$busyCount++
    Check ((ProbeSql $pendingSql 'busy-row') -ceq $pendingBefore) 'The pending owned check command was claimed or changed while startup was busy.'
    Check ((Test-Path -LiteralPath $workerJournal) -eq $journalBefore.exists) 'The worker reached Tick while startup was busy.';if($journalBefore.exists){Check ((Hash $workerJournal) -ceq $journalBefore.sha256 -and (Get-Acl -LiteralPath $workerJournal).Sddl -ceq $journalBefore.acl) 'The worker journal changed before recovery succeeded.'}
    if($busyCount -ge 2){$status=Get-Content "$state\updates\status.json" -Raw|ConvertFrom-Json;Check ($status.state -ceq 'installing' -and $status.message -ceq 'Another update is still completing' -and $status.installed_version -ceq '1.0.13' -and [DateTimeOffset]::Parse($status.checked_at).UtcDateTime -ge $started) 'A fresh genuine recovery-busy status is required.';$script:heldLock.Dispose();$script:heldLock=$null;$released=$true;$releasedAt=$clock.ElapsedMilliseconds}
   }elseif($code -eq 0){$success=$true;break}else{Check ($code -eq 75) 'Unlocked recovery must succeed or report only another real defer.'}
  }
  if(!$released){Check ($clock.Elapsed.TotalSeconds -lt 30) 'Two actual deferred recovery children were not observed in bounds.'}elseif($clock.ElapsedMilliseconds-$releasedAt -ge 60000){break}
  Start-Sleep -Milliseconds 50
 }while($clock.Elapsed.TotalSeconds -lt 90)
 Check ($released -and $success -and $busyCount -ge 2) 'Real recovery must succeed after release without restarting the corrected worker.';AssertHeldWorker $worker
 return @{system_identity_verified=$true;worker_pid=[int]$worker.pid;busy_recovery_children=[int]$busyCount;helper_exits=$children.ToArray();busy_observation_ms=[long]$releasedAt;total_observation_ms=[long]$clock.ElapsedMilliseconds;pending_command_unchanged_while_busy=$true;worker_journal_unchanged_while_busy=$true;same_original_worker_live_after_recovery=$true;recover0_after_release=$true}
}

try{
 PrivateDirectory $work
 Check (!(Test-Path $root) -and !(Test-Path "$state\installation.json") -and !(Test-Path "$configuration\config.conf") -and !(Get-Service FreeSWITCH -ErrorAction SilentlyContinue) -and !(Get-Service OpenWebPBXUpdater -ErrorAction SilentlyContinue)) 'An empty disposable runner is required; existing installations are refused.'
 $candidate=Artifact '38826730298' 'openwebpbx-windows-suite-candidate-38826730298' '.github/workflows/windows-suite.yml';$report=Artifact '38826730298' 'openwebpbx-windows-suite-facts-38826730298' '.github/workflows/windows-suite.yml'
 Check ($candidate.run.head_sha -ceq $facts.base_source_commit -and $report.run.head_sha -ceq $facts.base_source_commit) 'The immutable qualified package source differs.'
 $baselinePath=Join-Path $report.directory 'qualification.json';Check ((Hash $baselinePath) -ceq 'a662187faf931d1baf8fe2f364df980f83ac627939b6357dde9e8ab3ef0e88b4') 'The independently accepted original baseline facts differ.';$baseline=Get-Content $baselinePath -Raw|ConvertFrom-Json
 Check ($baseline.schema -eq 1 -and $baseline.run_id -ceq $facts.base_suite_run_id -and $baseline.source_commit -ceq $facts.base_source_commit -and $baseline.state -cin @('passed','partial') -and $baseline.cleanup -ceq 'owned services stopped, SFTP receiver/account removed, hostname removed, activation holds preserved') 'The exact qualified baseline and cleanup are required.'
 foreach($gate in 'fresh','native_sip_audio','backups','direct_113_helper_reapply','direct_failure_rollback','restore_gate_startup'){Check ($baseline.gates.$gate -ceq 'passed') 'Every essential baseline gate must pass.'}
 foreach($gate in 'manager_reopen_success','manager_reopen_rollback'){Check ($baseline.gates.$gate -ceq 'passed') 'Both actual manager gates must pass.'}
 $archive=Join-Path $candidate.directory 'openwebpbx-1.0.13-windows-x64.zip'
 Check ((Get-Item $archive).Length -eq 314773648 -and (Hash $archive) -ceq $facts.base_archive_sha256 -and $baseline.candidate_artifact.sha256 -ceq $facts.base_archive_sha256 -and $baseline.candidate_artifact.private_exclusions -ceq 'passed') 'The exact accepted unchanged package is required.'
 $archiveVerifier=Join-Path $PSScriptRoot 'windows_candidate_archive.py';Check ((Hash $archiveVerifier) -ceq '60638e2ddb0036f97d856a5278aad061a333989222a83045353eed68d399e012') 'The reviewed archive verifier bytes differ.'
 CheckedProcess 'python.exe' @($archiveVerifier,'--archive',$archive,'--version','1.0.13','--sha256',$facts.base_archive_sha256) 'verify-qualified-base'
 $packageDirectory=Join-Path $work 'baseline-package';PrivateDirectory $packageDirectory;ExpandSafe $archive $packageDirectory;$package=Join-Path $packageDirectory 'openwebpbx-1.0.13-windows-x64';NativeVersions $package '1.0.13'|Out-Null
 $phase='verified corrected native artifact';$newNative=Artifact '38840969235' 'openwebpbx-windows-native-1.0.13-38840969235' '.github/workflows/windows-native.yml';$nativeManifest=VerifyNewNative $newNative;$facts.native_artifact_sha256=$newNative.artifact.digest.Substring(7)
 $scope=[Guid]::NewGuid().ToString('N');$hosts=Join-Path $env:SystemRoot 'System32/drivers/etc/hosts';$originalHosts=[IO.File]::ReadAllBytes($hosts);$originalHostsAcl=(Get-Acl $hosts).Sddl;$marker='# OpenWebPBX disposable startup-lock '+$scope
 Check ([IO.File]::ReadAllText($hosts) -notmatch '(?im)^\s*[^#\r\n]+\swindowsqa\.example\.invalid(?:\s|$)') 'The fixture refuses a pre-existing hostname override.'
 [IO.File]::AppendAllText($hosts,"`r`n127.0.0.1 windowsqa.example.invalid $marker`r`n",[Text.UTF8Encoding]::new($false));$ownHosts=$true;Clear-DnsClientCache
 $phase='actual fresh qualified installation';$installInput=Join-Path $work 'install-input.json';$launch=Join-Path $work 'install-baseline.ps1'
 WriteJson $installInput @{package=$package;admin=('startup-'+$scope+'@example.invalid');password=('A9!'+[Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)))}
 [IO.File]::WriteAllText($launch,@'
param([string]$InputPath)
$ErrorActionPreference='Stop';$r=Get-Content -LiteralPath $InputPath -Raw|ConvertFrom-Json
& (Join-Path $r.package 'Install-OpenWebPBX.ps1') -RestoreServer -LocalCertificate -DomainName windowsqa.example.invalid -PublicAddress 127.0.0.1 -AdminEmail $r.admin -AdminPassword (ConvertTo-SecureString $r.password -AsPlainText -Force)
if(!$?){exit 1}
'@,[Text.UTF8Encoding]::new($false))
 $installed=$true;CheckedProcess "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$launch,'-InputPath',$installInput) 'actual-fresh13';Remove-Item -LiteralPath $installInput -Force
 InstalledVersions '1.0.13'|Out-Null;. "$root\tools\Restore-Gates.ps1";NoHolds
 Check ((Hash "$root\tools\Upgrade-OpenWebPBX.ps1") -ceq (Hash (Join-Path $package 'Upgrade-OpenWebPBX.ps1')) -and (Hash "$root\updater\slots\1.0.13\OpenWebPbx.Updater.dll") -ceq (Hash (Join-Path $package 'updater/OpenWebPbx.Updater.dll'))) 'The installed real helper and worker must match the accepted package.'
 $facts.installed_helper_sha256=Hash "$root\tools\Upgrade-OpenWebPBX.ps1";$facts.installed_updater_sha256=Hash "$root\updater\slots\1.0.13\OpenWebPbx.Updater.dll"
 $phase='owned updater stopped before native binding';Stop-Service OpenWebPBXUpdater;(Get-Service OpenWebPBXUpdater).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(45));$serviceBefore=ServiceRecord;$originalServicePath=$serviceBefore.PathName
 CheckedProcess "$env:SystemRoot\System32\sc.exe" @('qfailure','OpenWebPBXUpdater') 'failure-config-before' -Timeout 10000
 CheckedProcess "$env:SystemRoot\System32\sc.exe" @('qc','OpenWebPBXUpdater') 'service-config-before' -Timeout 10000
 $oldSlot="$root\updater\slots\1.0.13";$oldSlotBefore=ImmutableInventory $oldSlot;$nativeStage=Join-Path $root ('startup75-diagnostic-'+$scope);Check (!(Test-Path -LiteralPath $nativeStage)) 'A fresh unique diagnostic program child is required.';PrivateDirectory $nativeStage
 & robocopy.exe (Join-Path $newNative.directory 'updater') $nativeStage /E /COPY:DAT /DCOPY:T /R:1 /W:1 /NFL /NDL /NJH /NJS /NP|Out-Null;Check ($LASTEXITCODE -lt 8) 'The verified new updater staging copy failed.'
 $nativeFiles=@(Get-ChildItem -LiteralPath $nativeStage -Recurse -Force -File);$expectedUpdater=@($nativeManifest.Keys|Where-Object {$_.StartsWith('updater/',[StringComparison]::Ordinal)});Check ($nativeFiles.Count -eq $expectedUpdater.Count) 'The staged corrected updater inventory differs.'
 foreach($item in $nativeFiles){$relative='updater/'+[IO.Path]::GetRelativePath($nativeStage,$item.FullName).Replace('\','/');Check ($nativeManifest.ContainsKey($relative) -and (Hash $item.FullName) -ceq $nativeManifest[$relative]) 'A staged genuine updater member differs.'}
 $stageBefore=ImmutableInventory $nativeStage;RequireInventoryEqual $oldSlotBefore (ImmutableInventory $oldSlot)
 $selectedUpdaterExe=Join-Path $nativeStage 'OpenWebPbx.Updater.exe';$bindingChanged=$true;CheckedProcess "$env:SystemRoot\System32\sc.exe" @('config','OpenWebPBXUpdater','binPath=',('"'+$selectedUpdaterExe+'"')) 'select-corrected-native' -Timeout 10000;ServiceRecord|Out-Null
 $facts.new_updater_sha256=Hash (Join-Path $nativeStage 'OpenWebPbx.Updater.dll');Check ($facts.new_updater_sha256 -ceq '3b31f1dbacc760b74c32146fd2597df3558b9296e5464e0e14c7471c729511fa') 'The selected corrected updater DLL differs.'
 $phase='owned pending check before startup';Check ((ProbeSql 'select count(*) from v_pbx_update_commands' 'original-command-count') -ceq '0') 'The fresh diagnostic refuses pre-existing update commands.'
 $ownedCommand=[Guid]::NewGuid().ToString();ProbeSql ("insert into v_pbx_update_commands(command_uuid,action) values('"+$ownedCommand+"','check')") 'insert-check'|Out-Null
 $pendingSql="select row_to_json(c)::text from v_pbx_update_commands c where command_uuid='"+$ownedCommand+"'";$pendingBefore=ProbeSql $pendingSql 'pending-before';Check (![string]::IsNullOrWhiteSpace($pendingBefore)) 'The exact owned pending check row is required.'
 $pending=$pendingBefore|ConvertFrom-Json;Check ($pending.command_uuid -ceq $ownedCommand -and $pending.action -ceq 'check' -and $pending.status -ceq 'pending' -and $null -eq $pending.requested_by -and $null -eq $pending.started_at -and $null -eq $pending.finished_at -and $pending.message -ceq '') 'The owned check must genuinely start pending and unclaimed.'
 $workerJournal="$state\updates\worker-journal.json";$journalBefore=@{exists=(Test-Path -LiteralPath $workerJournal)};if($journalBefore.exists){$journalBefore.sha256=Hash $workerJournal;$journalBefore.acl=(Get-Acl -LiteralPath $workerJournal).Sddl}
 $lockPath=Join-Path $state 'upgrade.lock';$lockItem=Get-Item -LiteralPath $lockPath -Force;Check (!$lockItem.PSIsContainer -and !($lockItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) 'The existing ordinary product lock is required.';$lockHash=Hash $lockPath;$lockAcl=(Get-Acl -LiteralPath $lockPath).Sddl
 $phase='same corrected SYSTEM worker busy recovery and release';$heldLock=AcquireProbeLock
 try{$facts.fixed_worker=ObserveFixedRecovery}finally{if($heldLock){$heldLock.Dispose();$heldLock=$null}}
 Check ((Hash $lockPath) -ceq $lockHash -and (Get-Acl -LiteralPath $lockPath).Sddl -ceq $lockAcl) 'The diagnostic changed the existing lock content or ACL.'
 $phase='same corrected worker normal health after recovery';Start-Sleep -Seconds 2
 AssertHeldWorker $fixedWorkerHeld
 $health=Invoke-RestMethod 'http://127.0.0.1:8087/health' -TimeoutSec 10;Check ($health.state -ceq 'Running' -and $health.version -ceq '1.0.13') 'The original installed server must remain genuinely healthy.';foreach($name in 'OpenWebPBX-Database','OpenWebPBX','FreeSWITCH','OpenWebPBXUpdater'){Check ((Get-Service $name).Status -eq 'Running') 'The owned native services must remain healthy.'};NoHolds;AssertHeldWorker $fixedWorkerHeld
 RequireInventoryEqual $oldSlotBefore (ImmutableInventory $oldSlot);RequireInventoryEqual $stageBefore (ImmutableInventory $nativeStage)
 $facts.original_slot_preserved=$true;$facts.staged_program_preserved=$true;$facts.existing_lock_preserved=$true;$facts.state='observed'

}catch{
 $facts.state='failed';$facts.failed_phase=$phase;$facts.error_type=ErrorKind $_.Exception;$facts.source_line=[int]$_.InvocationInfo.ScriptLineNumber
 try{$observation=StartupFailureFields $_ $script:startupFailureRole;if($observation){$facts.failure_observation=$observation}}catch{}
 Write-Error 'The disposable startup-lock diagnostic failed; private messages and streams are not published.' -ErrorAction Continue
}finally{
 Remove-Item Env:\GH_TOKEN -ErrorAction SilentlyContinue
 if($heldLock){$heldLock.Dispose();$heldLock=$null}
 $cleanup=$true
 try{
  if($installed){
   $cleanupLock=AcquireProbeLock
   try{
    foreach($name in 'OpenWebPBX-Backups','OpenWebPBX-Cleanup','OpenWebPBX Outgoing Mail','OpenWebPBX Certificate Renewal','OpenWebPBX Pending Phone Certificate'){if(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue){Disable-ScheduledTask -TaskName $name|Out-Null}}
    $current=Get-CimInstance Win32_Service -Filter "Name='OpenWebPBXUpdater'";Check ($current.StartName -ceq 'LocalSystem' -and $current.StartMode -ceq 'Auto' -and $current.PathName.Trim('"') -cin @($selectedUpdaterExe,"$root\updater\slots\1.0.13\OpenWebPbx.Updater.exe")) 'Cleanup refused an unexpected updater binding.'
    Stop-Service OpenWebPBXUpdater -Force;(Get-Service OpenWebPBXUpdater).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(45))
    if($ownedCommand){Check ((ProbeSql ("select (action='check' and requested_by is null)::text from v_pbx_update_commands where command_uuid='"+$ownedCommand+"'") 'cleanup-row-guard') -ceq 'true') 'Cleanup refused a changed owned check command.';ProbeSql ("delete from v_pbx_update_commands where command_uuid='"+$ownedCommand+"' and action='check' and requested_by is null") 'cleanup-row-delete'|Out-Null;Check ((ProbeSql 'select count(*) from v_pbx_update_commands' 'cleanup-row-count') -ceq '0') 'The exact scoped check command was not removed.';$facts.owned_command_removed=$true}
    if($bindingChanged){CheckedProcess "$env:SystemRoot\System32\sc.exe" @('config','OpenWebPBXUpdater','binPath=',$originalServicePath) 'restore-original-binding' -Timeout 10000;$selectedUpdaterExe="$root\updater\slots\1.0.13\OpenWebPbx.Updater.exe";$restored=ServiceRecord;Check ($restored.PathName -ceq $originalServicePath) 'The original exact service path was not restored.';CheckedProcess "$env:SystemRoot\System32\sc.exe" @('qfailure','OpenWebPBXUpdater') 'failure-config-after' -Timeout 10000;CheckedProcess "$env:SystemRoot\System32\sc.exe" @('qc','OpenWebPBXUpdater') 'service-config-after' -Timeout 10000;foreach($label in 'failure-config','service-config'){Check ((Hash (Join-Path $work ($label+'-before.out'))) -ceq (Hash (Join-Path $work ($label+'-after.out')))) 'The original SCM configuration differs.'};$facts.service_configuration_restored=$true}
    if($oldSlotBefore){RequireInventoryEqual $oldSlotBefore (ImmutableInventory $oldSlot);$facts.original_slot_preserved=$true}
    if($nativeStage){Check ($nativeStage -ceq (Join-Path $root ('startup75-diagnostic-'+$scope))) 'Cleanup refused a foreign native stage.';RequireInventoryEqual $stageBefore (ImmutableInventory $nativeStage);Remove-Item -LiteralPath $nativeStage -Recurse -Force;Check (!(Test-Path -LiteralPath $nativeStage)) 'The exact staged native child was not removed.';$facts.staged_program_removed=$true}
    foreach($name in 'OpenWebPBX','FreeSWITCH'){if(Get-Service $name -ErrorAction SilentlyContinue){Stop-Service $name -Force;(Get-Service $name).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(45))}}
    Add-Type -Path "$env:SystemRoot\System32\inetsrv\Microsoft.Web.Administration.dll";$iis=[Microsoft.Web.Administration.ServerManager]::new()
    try{$site=$iis.Sites['OpenWebPBX'];$pool=$iis.ApplicationPools['OpenWebPBX'];Check ($site -and $pool -and $site.Applications['/'].ApplicationPoolName -ceq 'OpenWebPBX' -and $site.Applications['/'].VirtualDirectories['/'].PhysicalPath -ceq "$root\web") 'Cleanup refused an unexpected IIS application.';StopQualificationIis $site $pool}finally{$iis.Dispose()}
    if(Get-Service OpenWebPBX-Database -ErrorAction SilentlyContinue){Stop-Service OpenWebPBX-Database -Force;(Get-Service OpenWebPBX-Database).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(45))}
   }finally{$cleanupLock.Dispose()}
  }
 }catch{$cleanup=$false;$facts.cleanup_error_type=ErrorKind $_.Exception;$facts.cleanup_source_line=[int]$_.InvocationInfo.ScriptLineNumber}
 # Hostname/input cleanup remains independent of a refused service shutdown.
 try{
  if($ownHosts){$text=[IO.File]::ReadAllText($hosts);$text=[regex]::Replace($text,'(?m)^127\.0\.0\.1 windowsqa\.example\.invalid '+[regex]::Escape($marker)+'\r?\n','');$originalText=[Text.UTF8Encoding]::new($false).GetString($originalHosts);if($text -ceq ($originalText+"`r`n")){[IO.File]::WriteAllBytes($hosts,$originalHosts)}else{[IO.File]::WriteAllText($hosts,$text,[Text.UTF8Encoding]::new($false))};Check ((Get-Acl $hosts).Sddl -ceq $originalHostsAcl -and [IO.File]::ReadAllText($hosts) -notmatch [regex]::Escape($marker)) 'Owned hostname cleanup or original ACL preservation failed.';Clear-DnsClientCache}
  if($installInput -and (Test-Path -LiteralPath $installInput)){Remove-Item -LiteralPath $installInput -Force}
  $facts.hostname_cleanup='owned hostname mapping removed; original hosts ACL preserved'
 }catch{$cleanup=$false;$facts.hostname_cleanup='failed';$facts.hostname_cleanup_error_type=ErrorKind $_.Exception;$facts.hostname_cleanup_source_line=[int]$_.InvocationInfo.ScriptLineNumber}
 finally{foreach($process in $retainedProcesses){$process.Dispose()}}
 $facts.cleanup=if($cleanup){'owned disposable services stopped; owned hostname mapping removed; original hosts ACL preserved'}else{'failed'}
 if(!$cleanup){$facts.state='failed'}
 New-Item -ItemType Directory -Force $public|Out-Null;WriteJson (Join-Path $public 'qualification.json') $facts
}
if($facts.state -ceq 'failed'){exit 1}
Write-Output 'Disposable startup-lock observation completed; release and owner qualification remain unavailable.'
