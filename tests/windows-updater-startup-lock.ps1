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
$script:startupFailureRole=$null
$facts=[ordered]@{schema=1;run_id=$env:GITHUB_RUN_ID;source_commit=$env:GITHUB_SHA;state='running';scope='disposable Windows Server 2025 installed SYSTEM updater startup contention';release_eligible=$false;owner_eligible=$false;base_suite_run_id='38826730298';base_source_commit='97825554dbfe0e01689a9bc796c57884b0623fe3';base_archive_sha256='33d9a52375f27736149898599f0dbf621748e94f4820bd230801ab86e13e958d';locked_start=$null;unlocked_restart=$null;cleanup='pending'}

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
 $functions=@('Check','ServiceRecord','NoHolds','RetainStarted','ObserveStart','RetainQualificationProcess','GetManagerOriginalExitProof','<ScriptBlock>');$frames=[Collections.Generic.List[object]]::new()
 $trace=$Record.ScriptStackTrace
 if($trace -and $trace.Length -le 16384){foreach($line in @([regex]::Split($trace,'\r?\n')|Select-Object -First 64)){
  if($frames.Count -ge 6){break}
  $match=[regex]::Match($line.Trim(),'\Aat (?<function>[^,\r\n]{1,80}), (?:(?:[^\r\n]*[\\/])?(?<source>windows-updater-startup-lock\.ps1|windows-updater-qualification\.ps1)|(?<imported><No file>)): line (?<line>[0-9]{1,5})\z')
  if(!$match.Success -or $match.Groups['function'].Value -cnotin $functions){continue}
  $number=[int]$match.Groups['line'].Value;if($number -lt 1 -or $number -gt 10000){continue}
  $frames.Add(@{function=$match.Groups['function'].Value;source_basename=if($match.Groups['imported'].Success){'imported_scriptblock'}else{$match.Groups['source'].Value};source_line=$number})
 }}
 $command=$Record.InvocationInfo.MyCommand.Name;if($command -cnotin @('Get-CimInstance','Invoke-CimMethod','Check','RetainStarted','RetainQualificationProcess','ObserveStart')){$command='other'}
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
 Check ($service -and $service.Name -ceq 'OpenWebPBXUpdater' -and $service.StartName -ceq 'LocalSystem' -and $service.StartMode -ceq 'Auto' -and $service.PathName.Trim('"') -ceq "$root\updater\slots\1.0.13\OpenWebPbx.Updater.exe") 'The exact ordinary installed SYSTEM service is required.'
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
function ObserveStart([bool]$Locked){
 # Both attempts use ordinary SCM startup with unchanged account/action/recovery
 # configuration. Retained original handles establish exit, not a bare PID lookup.
 $before=ServiceRecord;Check ($before.State -ceq 'Stopped' -and $before.ProcessId -eq 0) 'The owned updater must be stopped before startup.'
 NoHolds;$started=[DateTime]::UtcNow;$clock=[Diagnostics.Stopwatch]::StartNew();$worker=$null;$child=$null;$states=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$pids=[Collections.Generic.HashSet[int]]::new();$statusSeen=$false;$startError=$false
 try{Start-Service OpenWebPBXUpdater}catch{$startError=$true}
 $limit=if($Locked){30000}else{60000}
 do{
  $service=ServiceRecord;$states.Add([string]$service.State)|Out-Null
  if($service.ProcessId -gt 0){
   $processId=[int]$service.ProcessId
   if(!$pids.Contains($processId)){
    $record=Get-CimInstance Win32_Process -Filter ('ProcessId='+$processId);$held=RetainStarted $record $started "$root\updater\slots\1.0.13\OpenWebPbx.Updater.exe" 'worker'
    Check ($record.CommandLine -notmatch '--run-once|--check-once|--skip-recovery|--verify-package') 'The diagnostic requires the ordinary installed worker.'
    $pids.Add($processId)|Out-Null;if(!$worker){$worker=$held}
   }
   if($worker -and !$child -and !$worker.process.HasExited){
    $children=@(Get-CimInstance Win32_Process -Filter ('ParentProcessId='+$worker.pid)|Where-Object {$_.Name -ieq 'powershell.exe'})
    Check ($children.Count -le 1) 'The ordinary startup has an ambiguous recovery child.'
    if($children.Count){
     $record=$children[0];$helper="$root\tools\Upgrade-OpenWebPBX.ps1";$expected='\A(?:"(?:[^"\r\n]*\\)?powershell\.exe"|(?:[^"\s]*\\)?powershell\.exe) -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (?:"'+[regex]::Escape($helper)+'"|'+[regex]::Escape($helper)+') -Recover\z'
     Check ($record.CommandLine.Length -le 8192 -and $record.CommandLine -imatch $expected) 'The exact installed recovery child is required.'
     $child=RetainStarted $record $started "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" 'helper'
    }
   }
  }
  $statusPath="$state\updates\status.json"
  if($Locked -and (Test-Path -LiteralPath $statusPath)){
   try{$item=Get-Item -LiteralPath $statusPath -Force;Check (!$item.PSIsContainer -and !($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $item.Length -le 262144) 'A bounded ordinary update status is required.';$status=Get-Content -LiteralPath $statusPath -Raw|ConvertFrom-Json
    if($status.state -ceq 'installing' -and $status.message -ceq 'Another update is still completing' -and $status.installed_version -ceq '1.0.13' -and [DateTimeOffset]::Parse($status.checked_at).UtcDateTime -ge $started){$statusSeen=$true}
   }catch{}
  }
  if(!$Locked -and $child -and $child.process.HasExited){break}
  Start-Sleep -Milliseconds 50
 }while($clock.ElapsedMilliseconds -lt $limit)
 $workerProof=GetManagerOriginalExitProof $worker $(if($worker){$worker.pid}else{0});$childProof=GetManagerOriginalExitProof $child $(if($child){$child.pid}else{0})
 $complete=($workerProof.manager_original_handle_pinned -and $workerProof.manager_original_identity_verified -and $workerProof.manager_original_exit_observed -and $childProof.manager_original_handle_pinned -and $childProof.manager_original_identity_verified -and $childProof.manager_original_exit_observed)
 $service=ServiceRecord
 return [ordered]@{observation_complete=[bool]$complete;observation_ms=[int]$clock.ElapsedMilliseconds;start_command_threw=[bool]$startError;system_identity_verified=[bool]$complete;worker_pid=if($worker){[int]$worker.pid}else{$null};helper_pid=if($child){[int]$child.pid}else{$null};distinct_worker_pid_count=[int]$pids.Count;scm_states=@($states|Sort-Object);scm_final_state=[string]$service.State;scm_win32_exit=[uint32]$service.ExitCode;scm_service_exit=[uint32]$service.ServiceSpecificExitCode;worker_has_exited=if($workerProof.manager_original_exit_observed){[bool]$workerProof.manager_original_has_exited}else{$null};worker_exit_code=if($workerProof.manager_original_has_exited){[int]$worker.process.ExitCode}else{$null};helper_has_exited=if($childProof.manager_original_exit_observed){[bool]$childProof.manager_original_has_exited}else{$null};helper_exit_code=if($childProof.manager_original_has_exited){[int]$child.process.ExitCode}else{$null};fresh_contention_status=[bool]$statusSeen}
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
 $phase='owned updater stopped before contention';Stop-Service OpenWebPBXUpdater;(Get-Service OpenWebPBXUpdater).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(45));$serviceBefore=ServiceRecord
 CheckedProcess "$env:SystemRoot\System32\sc.exe" @('qfailure','OpenWebPBXUpdater') 'failure-config-before' -Timeout 10000
 $lockPath=Join-Path $state 'upgrade.lock';$lockItem=Get-Item -LiteralPath $lockPath -Force;Check (!$lockItem.PSIsContainer -and !($lockItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) 'The existing ordinary product lock is required.';$lockHash=Hash $lockPath;$lockAcl=(Get-Acl -LiteralPath $lockPath).Sddl
 $phase='ordinary SYSTEM startup under actual exclusive product lock';$heldLock=AcquireProbeLock
 try{$facts.locked_start=ObserveStart $true}finally{$heldLock.Dispose();$heldLock=$null}
 Check ((Hash $lockPath) -ceq $lockHash -and (Get-Acl -LiteralPath $lockPath).Sddl -ceq $lockAcl) 'The diagnostic changed the existing lock content or ACL.'
 $phase='normal unlocked SYSTEM restart and recovery';if((ServiceRecord).State -cne 'Stopped'){Stop-Service OpenWebPBXUpdater;(Get-Service OpenWebPBXUpdater).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(45))}
 $facts.unlocked_restart=ObserveStart $false
 Check ($facts.unlocked_restart.observation_complete -and $facts.unlocked_restart.helper_has_exited -and $facts.unlocked_restart.helper_exit_code -eq 0 -and !$facts.unlocked_restart.worker_has_exited -and $facts.unlocked_restart.scm_final_state -ceq 'Running' -and $facts.unlocked_restart.distinct_worker_pid_count -eq 1) 'Unlocked ordinary startup must complete actual recovery and remain running.'
 Start-Sleep -Seconds 2;Check ((InstalledVersions '1.0.13') -eq $facts.unlocked_restart.worker_pid) 'The recovered ordinary worker must remain healthy under the same PID.';NoHolds
 CheckedProcess "$env:SystemRoot\System32\sc.exe" @('qfailure','OpenWebPBXUpdater') 'failure-config-after' -Timeout 10000
 Check ((Hash (Join-Path $work 'failure-config-before.out')) -ceq (Hash (Join-Path $work 'failure-config-after.out')) -and (ServiceRecord).StartName -ceq $serviceBefore.StartName -and (ServiceRecord).PathName -ceq $serviceBefore.PathName -and (ServiceRecord).StartMode -ceq $serviceBefore.StartMode) 'The probe must not alter actual service identity, startup or failure configuration.'
 $facts.service_configuration_preserved=$true;$facts.existing_lock_preserved=$true
 Check $facts.locked_start.observation_complete 'The actual locked startup process observation is incomplete; no conditional behavior is proved.'
 $facts.state='observed'
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
    ServiceRecord|Out-Null;Stop-Service OpenWebPBXUpdater -Force;(Get-Service OpenWebPBXUpdater).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(45))
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
