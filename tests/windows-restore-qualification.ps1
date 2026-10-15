#Requires -RunAsAdministrator
#Requires -Version 7.4
<# SPDX-License-Identifier: AGPL-3.0-or-later.
Separate fictional source and genuinely empty replacement hosts. Supported CLI
restore with private input; real HTTPS/CSRF sign-in and SYSTEM scheduled backup.
No owner machine, public release, signer, carrier or actual OS reboot is used.
#>
[CmdletBinding()]
param(
 [Parameter(Mandatory)][ValidateSet('Source','Target')][string]$Role,
 [Parameter(Mandatory)][ValidatePattern('^[1-9][0-9]{0,19}$')][string]$BaseSuiteRunId,
 [switch]$DisposableHostedRunner
)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if(!$DisposableHostedRunner -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:RUNNER_OS -ne 'Windows' -or $env:GITHUB_REPOSITORY -ne 'embire2/openwebpbx' -or $env:GITHUB_EVENT_NAME -ne 'workflow_dispatch'){throw 'Only the explicitly disposable owned manually dispatched hosted Windows runner is authorized.'}
$os=Get-CimInstance Win32_OperatingSystem
if($os.ProductType -eq 1 -or $os.Caption -notmatch 'Windows Server 2025' -or [Environment]::OSVersion.Version.Build -lt 26100){throw 'A disposable Windows Server 2025 runner is required.'}
if(!$env:WINDOWS_RESTORE_FIXTURE_PASSPHRASE -or $env:WINDOWS_RESTORE_FIXTURE_PASSPHRASE.Length -lt 32){throw 'Root must temporarily supply the independent fictional-fixture encryption passphrase.'}
$source=Split-Path $PSScriptRoot -Parent;$root='C:\OpenWebPBX';$state=Join-Path $env:ProgramData 'OpenWebPBX';$configuration=Join-Path $env:ProgramData 'fusionpbx'
$work=Join-Path $env:RUNNER_TEMP ('openwebpbx-restore-'+$Role.ToLowerInvariant()+'-'+[Guid]::NewGuid().ToString('N'))
$public=Join-Path $env:RUNNER_TEMP ('openwebpbx-restore-'+$Role.ToLowerInvariant()+'-facts')
$transfer=Join-Path $env:RUNNER_TEMP 'openwebpbx-restore-transfer'
$phase='verified qualified package';$installed=$false;$pki=$null;$inputFile=$null;$hostsBefore=$null;$hostsExpected=$null;$settings=$null;$python=$null;$winps=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$facts=[ordered]@{schema=1;role=$Role.ToLowerInvariant();run_id=$env:GITHUB_RUN_ID;source_commit=$env:GITHUB_SHA;state='running';gates=@{};actual_os_boot='unqualified';carrier='unqualified';owner_upgrade='unqualified';cleanup='pending'}
# Import only the reviewed artifact/process and bounded IIS cleanup functions.
# Do not dot-source the executable updater stage or its environment guards.
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'windows-updater-qualification.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The independently reviewed artifact helper no longer parses.'}
foreach($name in 'Check','Hash','WriteJson','PrivateDirectory','SafeRelative','ExpandSafe','Api','Artifact','CheckedProcess','NativeVersions','StopQualificationIis'){
 $nodes=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true));if($nodes.Count -ne 1){throw 'One exact qualification helper is required.'};Invoke-Expression $nodes[0].Extent.Text
}
. (Join-Path $PSScriptRoot 'windows-suite-pki.ps1')
function Derived([string]$Label){
 $h=[Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes($env:WINDOWS_RESTORE_FIXTURE_PASSPHRASE))
 try{return $h.ComputeHash([Text.Encoding]::UTF8.GetBytes('openweb-restore-qualification/v1/'+$Label))}finally{$h.Dispose()}
}
function Fixture([string]$Action){
 CheckedProcess "$root\php\php.exe" @((Join-Path $PSScriptRoot 'windows-restore-qualification.php'),$Action,$inputFile) ('php-'+$Action) "$root\web" 120000
}
function SafeRestoreFixtureFailure($Record){
 if($null -eq $Record -or $Record -is [array]){return $null}
 $keys=@('schema','action','step','reason','error_type','source_basename','source_line')
 if($Record -is [System.Collections.IDictionary]){$actual=@($Record.Keys)}else{$actual=@($Record.PSObject.Properties.Name)}
 if($actual.Count -ne $keys.Count -or @($actual|Where-Object {$_ -cnotin $keys}).Count){return $null}
 if(($Record.schema -isnot [int] -and $Record.schema -isnot [long]) -or $Record.schema -ne 1 -or $Record.action -isnot [string] -or $Record.action -cne 'cleanup'){return $null}
 $steps=@('initialization','owned_lookup','gateway_guard','native_quiescence','native_contacts','backup_inventory','owned_rows_delete','update_commands_delete','backup_commands_delete','drafts_delete','archive_files_delete','cache_cleanup','native_reload','factory_guard','input_commit')
 $reasons=@('owned_service_lookup','enabled_gateway','active_calls','phone_identity','live_contact','missing_backup_command','backup_command_guard','backup_metadata_guard','backup_link','backup_integrity','original_command','command_ownership','backup_command_changed','original_draft','draft_ownership','archive_unlink','factory_not_empty','database_error','json_error','type_error','runtime_guard','external_error')
 $types=@('RuntimeException','PDOException','JsonException','TypeError','ValueError','Error','Exception','external_error')
 $sources=@('windows-restore-qualification.php','database.php','pbx_paths.php','cache.php','event_socket.php','config.php','external_component')
 if($Record.step -isnot [string] -or $Record.step -cnotin $steps -or $Record.reason -isnot [string] -or $Record.reason -cnotin $reasons -or $Record.error_type -isnot [string] -or $Record.error_type -cnotin $types -or $Record.source_basename -isnot [string] -or $Record.source_basename -cnotin $sources){return $null}
 if(($Record.source_line -isnot [int] -and $Record.source_line -isnot [long]) -or $Record.source_line -le 0 -or $Record.source_line -ge 1000000){return $null}
 return @{schema=1;action='cleanup';step=$Record.step;reason=$Record.reason;error_type=$Record.error_type;source_basename=$Record.source_basename;source_line=$Record.source_line}
}
function NativeFixture([string]$Action){
 $script:phase=$Action
 # The extracted interpreter remains independent of private installed state.
 try{CheckedProcess $python @('-I','-B',(Join-Path $PSScriptRoot 'windows-restore-qualification.py'),'--input',$inputFile,'--action',$Action) ('restore-'+$Action) $source 1200000}
 catch{
  $privateOutput=Join-Path $work ('restore-'+$Action+'.out')
  if(Test-Path $privateOutput){try{$safe=Get-Content $privateOutput -Raw|ConvertFrom-Json;if($safe.state -eq 'failed' -and $safe.error_type -match '^[A-Za-z0-9_.]{1,120}$' -and $safe.source_basename -match '^[A-Za-z0-9_.-]{1,120}$' -and ($safe.source_line -is [long] -or $safe.source_line -is [int]) -and $safe.source_line -ge 0 -and $safe.source_line -lt 1000000){$facts.native_failure=@{error_type=$safe.error_type;source_basename=$safe.source_basename;source_line=$safe.source_line;active_case=$Action};if($Action -ceq 'cleanup'){$observation=SafeRestoreFixtureFailure $safe.fixture_failure;if($observation){$facts.native_failure.fixture_failure=$observation}}}}catch{}}
  throw
 }
}
function AssertBackupTask {
 $task=Get-ScheduledTask -TaskName 'OpenWebPBX-Backups' -ErrorAction Stop
 Check ($task.Principal.UserId -in 'SYSTEM','S-1-5-18' -and $task.Principal.RunLevel -eq 'Highest' -and @($task.Actions).Count -eq 1 -and $task.Actions[0].Execute -eq "$root\backup-runtime\python.exe" -and $task.Actions[0].Arguments -eq '-I "C:\OpenWebPBX\tools\backups.py" worker') 'The real installed backup worker task must retain its exact SYSTEM action.'
 Check (@($task.Triggers|Where-Object {$_.CimClass.CimClassName -eq 'MSFT_TaskBootTrigger'}).Count -eq 1) 'The real owned task must retain its startup trigger; actual OS boot remains unqualified.'
 $deadline=[DateTime]::UtcNow.AddSeconds(60)
 do{$info=Get-ScheduledTaskInfo -InputObject $task;if($info.LastTaskResult -eq 0 -and $info.LastRunTime -gt [DateTime]::Now.AddMinutes(-15)){break};Start-Sleep -Milliseconds 500}while([DateTime]::UtcNow -lt $deadline)
 Check ($info.LastTaskResult -eq 0 -and $info.LastRunTime -gt [DateTime]::Now.AddMinutes(-15)) 'Actual scheduled SYSTEM backup must finish successfully.'
 $facts.gates.actual_system_task_principal_action_execution='passed'
}
function EnableTargetTls([switch]$Prepared){
 $script:phase=if($Prepared){'offline target TLS preparation'}else{'independent source phone TLS'}
 $arguments=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',"$root\tools\Enable-PhoneTLS.ps1",'-CertificateThumbprint',$pki.leaf.Thumbprint)
 if($Prepared){$arguments+='-PrepareRestored'}
 CheckedProcess $winps $arguments ('tls-'+$Role.ToLowerInvariant()) $source 300000
}
function HeldServiceRestart {
 $script:phase='controlled held updater-service restart'
 # This is service-start recovery proof, never an operating-system boot claim.
 $restore=Join-Path $state 'backup-restore'
 foreach($selection in 'calls','jobs','updates','backups'){Check (Test-Path "$restore\hold-$selection") 'Every restored class must remain held before the controlled service start.'}
 Check ((Get-Service FreeSWITCH).Status -eq 'Stopped' -and (Get-Service OpenWebPBX).Status -eq 'Stopped') 'Calls and jobs must be stopped before this held start.'
 $before=@(Get-Content $inputFile -Raw|ConvertFrom-Json);$before=$before[0]
 try{
  Set-Service OpenWebPBXUpdater -StartupType Manual;Start-Service OpenWebPBXUpdater
  $deadline=[DateTime]::UtcNow.AddSeconds(30)
  do{Start-Sleep -Milliseconds 500;$service=Get-Service OpenWebPBXUpdater;if($service.Status -ne 'Running'){throw 'The held genuine updater exited before its recovery gate.'}}while([DateTime]::UtcNow -lt $deadline)
  foreach($selection in 'calls','jobs','updates','backups'){Check (Test-Path "$restore\hold-$selection") 'Service startup removed a restore hold.'}
  Check ((Get-Service FreeSWITCH).Status -eq 'Stopped' -and (Get-Service OpenWebPBX).Status -eq 'Stopped') 'Held service startup must not start calls or jobs.'
  Fixture 'job-status';$job=Get-Content (Join-Path $work 'php-job-status.out') -Raw|ConvertFrom-Json
  Check ($job.state -eq 'waiting' -and $job.attempts -eq 0) 'Held worker startup claimed the restored future job.'
  $facts.gates.controlled_service_start_preserves_all_holds='passed'
 }finally{Stop-Service OpenWebPBXUpdater -ErrorAction SilentlyContinue;Set-Service OpenWebPBXUpdater -StartupType Disabled}
}
function SourceTransfer {
 # Same current workflow still runs in the target job. Require the exact
 # completed successful SOURCE JOB, not overall run success before target ends.
 $run=Api ('actions/runs/'+$env:GITHUB_RUN_ID)
 Check ($run.repository.full_name -eq 'embire2/openwebpbx' -and $run.head_repository.full_name -eq 'embire2/openwebpbx' -and $run.event -eq 'workflow_dispatch' -and $run.path -eq '.github/workflows/windows-restore-qualification.yml' -and $run.head_sha -eq $env:GITHUB_SHA) 'The exact owned current restore workflow is required.'
 $jobs=@((Api ('actions/runs/'+$env:GITHUB_RUN_ID+'/jobs?per_page=100')).jobs|Where-Object name -eq 'Fictional encrypted backup source')
 Check ($jobs.Count -eq 1 -and $jobs[0].status -eq 'completed' -and $jobs[0].conclusion -eq 'success') 'The independent source job must have passed and cleaned up.'
 $script:sourceHostedJobId=[string]$jobs[0].id
 $name='openwebpbx-windows-restore-transfer-'+$env:GITHUB_RUN_ID
 $items=@((Api ('actions/runs/'+$env:GITHUB_RUN_ID+'/artifacts?per_page=100')).artifacts|Where-Object {$_.name -eq $name -and !$_.expired})
 Check ($items.Count -eq 1 -and $items[0].digest -match '^sha256:[a-f0-9]{64}$' -and $items[0].size_in_bytes -le 8GB) 'One bounded exact fictional transfer artifact is required.'
 $item=$items[0];$handler=[Net.Http.HttpClientHandler]::new();$handler.AllowAutoRedirect=$false;$client=[Net.Http.HttpClient]::new($handler)
 $client.DefaultRequestHeaders.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$env:GH_TOKEN);$client.DefaultRequestHeaders.UserAgent.ParseAdd('OpenWebPBX-Private-Restore-Qualification')
 try{$response=$client.GetAsync('https://api.github.com/repos/embire2/openwebpbx/actions/artifacts/'+$item.id+'/zip').GetAwaiter().GetResult();Check ([int]$response.StatusCode -eq 302) 'The authenticated transfer redirect is unavailable.';$location=$response.Headers.Location}finally{$client.Dispose();$handler.Dispose()}
 Check ($location.IsAbsoluteUri -and $location.Scheme -eq 'https') 'Transfer artifact storage must use trusted HTTPS.'
 $archive=Join-Path $work 'transfer.zip';Invoke-WebRequest $location -MaximumRedirection 0 -OutFile $archive
 Check ((Get-Item $archive).Length -eq $item.size_in_bytes -and (Hash $archive) -eq $item.digest.Substring(7)) 'The complete artifact digest differs.'
 Check (!(Test-Path $transfer)) 'A previous transfer must not be reused.';PrivateDirectory $transfer;ExpandSafe $archive $transfer
 Check (@(Get-ChildItem -LiteralPath $transfer -Recurse -File).Count -eq 2 -and (Test-Path "$transfer\fixture.owpbx") -and (Test-Path "$transfer\capsule.json")) 'Only fictional ciphertext and authenticated redacted evidence may be transferred.'
}
try{
 PrivateDirectory $work
 Check (!(Test-Path $root) -and !(Test-Path "$state\installation.json") -and !(Test-Path "$configuration\config.conf") -and !(Get-Service FreeSWITCH -ErrorAction SilentlyContinue)) 'Each job must be genuinely empty and refuses an existing owner installation.'
 $candidate=Artifact $BaseSuiteRunId ('openwebpbx-windows-suite-candidate-'+$BaseSuiteRunId) '.github/workflows/windows-suite.yml'
 $report=Artifact $BaseSuiteRunId ('openwebpbx-windows-suite-facts-'+$BaseSuiteRunId) '.github/workflows/windows-suite.yml'
 $baseFacts=Get-Content (Join-Path $report.directory 'qualification.json') -Raw|ConvertFrom-Json
 Check ($baseFacts.schema -eq 1 -and $baseFacts.run_id -eq $BaseSuiteRunId -and $baseFacts.source_commit -eq $candidate.run.head_sha -and $baseFacts.state -in 'partial','passed') 'Exact qualified baseline facts are required.'
 foreach($gate in 'fresh','native_sip_audio','backups','direct_113_helper_reapply','direct_failure_rollback','restore_gate_startup'){Check ($baseFacts.gates.$gate -eq 'passed') 'Every essential real baseline gate must pass.'}
 Check ($baseFacts.cleanup -eq 'owned services stopped, SFTP receiver/account removed, hostname removed, activation holds preserved') 'The qualified baseline must have completed its exact owned cleanup.'
 $base=Join-Path $candidate.directory 'openwebpbx-1.0.13-windows-x64.zip'
 Check ((Hash $base) -eq $baseFacts.candidate_artifact.sha256 -and $baseFacts.artifacts.candidate_sha256 -eq $baseFacts.candidate_artifact.sha256 -and $baseFacts.candidate_artifact.filename -eq 'openwebpbx-1.0.13-windows-x64.zip' -and $baseFacts.candidate_artifact.private_exclusions -eq 'passed' -and $baseFacts.candidate_artifact.verified_before_credentials -eq $true) 'The exact independently audited package and BOTH candidate evidence fields must match the qualification.'
 CheckedProcess 'python.exe' @((Join-Path $PSScriptRoot 'windows_candidate_archive.py'),'--archive',$base,'--version','1.0.13','--sha256',$baseFacts.candidate_artifact.sha256) 'verify-qualified-package'
 $expanded=Join-Path $work 'package';PrivateDirectory $expanded;ExpandSafe $base $expanded
 $packages=@(Get-ChildItem $expanded -Directory);Check ($packages.Count -eq 1) 'One exact release package root is required.';$package=$packages[0].FullName;$python=Join-Path $package 'backup-runtime/python.exe';NativeVersions $package '1.0.13'|Out-Null
 if($Role -eq 'Target'){SourceTransfer}
 $binding=$env:GITHUB_RUN_ID+'/'+$env:GITHUB_SHA
 $scope=[Convert]::ToHexString((Derived ('scope/'+$binding))).ToLowerInvariant().Substring(0,24)
 $qa=Join-Path $state ('restore-qualification/'+$scope);PrivateDirectory $qa;$inputFile=Join-Path $qa 'input.json'
 $sourcePassword='A9!'+[Convert]::ToHexString((Derived ('administrator/source/'+$binding))).ToLowerInvariant()
 $targetPassword='A9!'+[Convert]::ToHexString((Derived ('administrator/target/'+$binding))).ToLowerInvariant()
 $password=if($Role -eq 'Source'){$sourcePassword}else{$targetPassword};$email='restoreqa@example.invalid'
 $settings=@{schema=1;disposable=$true;github_actions=$true;runner_environment='github-hosted';repository='embire2/openwebpbx';scope=$scope;run_id=$env:GITHUB_RUN_ID;source_commit=$env:GITHUB_SHA;role=$Role.ToLowerInvariant();admin_email=$email;admin_password=$password;source_admin_password=$sourcePassword;passphrase=$env:WINDOWS_RESTORE_FIXTURE_PASSPHRASE;service_name=('Fictional restore PBX '+$scope);source_root=$source;base_suite_run_id=$BaseSuiteRunId;candidate_sha256=(Hash $base);transfer_directory=$transfer}
 $jobName=if($Role -eq 'Source'){'Fictional encrypted backup source'}else{'Independent clean replacement restore'}
 $currentJobs=@((Api ('actions/runs/'+$env:GITHUB_RUN_ID+'/jobs?per_page=100')).jobs|Where-Object name -eq $jobName)
 Check ($currentJobs.Count -eq 1 -and $currentJobs[0].status -eq 'in_progress' -and $currentJobs[0].runner_name -eq $env:RUNNER_NAME -and $currentJobs[0].id -gt 0) 'The actual current authenticated hosted job and runner binding are required.'
 $settings.hosted_job_id=[string]$currentJobs[0].id
 if($Role -eq 'Target'){$settings.source_hosted_job_id=$sourceHostedJobId;Check ($settings.hosted_job_id -ne $sourceHostedJobId) 'The replacement cannot reuse the authenticated source job.'}
 WriteJson $inputFile $settings;[IO.File]::WriteAllBytes((Join-Path $qa 'audit.key'),(Derived 'audit'))
 $machineSid=(Get-LocalUser | Where-Object {$_.SID.Value -match '-500$'}).SID.Value -replace '-500$',''
 $h=[Security.Cryptography.HMACSHA256]::new((Derived 'machine-identity'));try{$settings.machine_sid_hmac=[Convert]::ToHexString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($machineSid))).ToLowerInvariant()}finally{$h.Dispose()}
 $hardware=[string](Get-CimInstance Win32_ComputerSystemProduct).UUID;$hardware=$hardware.ToUpperInvariant()
 Check ($hardware -match '^[A-F0-9]{8}(-[A-F0-9]{4}){3}-[A-F0-9]{12}$' -and $hardware.Replace('-','') -notin ('0'*32),('F'*32)) 'A validated nonplaceholder hardware UUID is required.'
 $h=[Security.Cryptography.HMACSHA256]::new((Derived 'machine-identity'))
 try{foreach($entry in @{hardware_uuid_hmac=$hardware;hostname_hmac=[Environment]::MachineName.ToUpperInvariant();runner_name_hmac=$env:RUNNER_NAME}.GetEnumerator()){$settings[$entry.Key]=[Convert]::ToHexString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($entry.Value))).ToLowerInvariant()}}finally{$h.Dispose()}
 Remove-Item Env:\WINDOWS_RESTORE_FIXTURE_PASSPHRASE
 $phase='actual separate fresh installer'
 $request=Join-Path $work 'install-input.json';WriteJson $request @{package=$package;admin=$email;password=$password}
 $wrapper=Join-Path $work 'install-private.ps1'
 [IO.File]::WriteAllText($wrapper,@'
param([string]$InputFile)
$ErrorActionPreference='Stop'
$r=Get-Content -LiteralPath $InputFile -Raw|ConvertFrom-Json
& (Join-Path $r.package 'Install-OpenWebPBX.ps1') -RestoreServer -LocalCertificate -DomainName windowsqa.example.invalid -PublicAddress 127.0.0.1 -AdminEmail $r.admin -AdminPassword (ConvertTo-SecureString $r.password -AsPlainText -Force)
'@,[Text.UTF8Encoding]::new($false))
 $installed=$true;CheckedProcess $winps @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$wrapper,$request) 'fresh-install' $source 2400000
 $password=$null;$sourcePassword=$null;$targetPassword=$null
 $hosts=Join-Path $env:SystemRoot 'System32/drivers/etc/hosts';$hostsBefore=[IO.File]::ReadAllBytes($hosts)
 Check ([Text.Encoding]::UTF8.GetString($hostsBefore) -notmatch 'windowsqa\.example\.invalid') 'Do not reuse an existing hostname fixture.'
 [IO.File]::AppendAllText($hosts,"`r`n127.0.0.1 windowsqa.example.invalid # OpenWeb PBX restore $scope`r`n",[Text.UTF8Encoding]::new($false))
 $hostsExpected=[IO.File]::ReadAllBytes($hosts)
 $phase='independent target-specific trusted PKI';$pki=Start-SuiteRecoveryPki $package $source $work
 $settings.web_ca=Join-Path $pki.directory 'evidence/fixture-root.pem';$settings.certificate_sha256=Hash (Join-Path $pki.directory 'evidence/fixture-leaf.pem')
 # Hash the actual native helper's leaf bytes; refuse absent evidence rather
 # than infer a thumbprint as a certificate-content checksum.
 WriteJson $inputFile $settings;$settings=$null
 $env:OPENWEB_WINDOWS_RESTORE_TEST='1';Fixture 'baseline';NativeFixture 'setup'
 $facts.base_suite_run_id=$BaseSuiteRunId;$facts.base_archive_sha256=Hash $base;$facts.base_source_commit=$baseFacts.source_commit
 if($Role -eq 'Source'){
  EnableTargetTls;NativeFixture 'native-source';NativeFixture 'export-source';AssertBackupTask
 }else{
  $originalTaskStates=@{}
  foreach($name in 'OpenWebPBX-Cleanup','OpenWebPBX Outgoing Mail','OpenWebPBX Certificate Renewal','OpenWebPBX Pending Phone Certificate'){$task=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue;if($task){$originalTaskStates[$name]=[bool]$task.Settings.Enabled}}
  NativeFixture 'late-restore';NativeFixture 'restore'
  $currentBinding=Set-SuiteFixtureBinding -Read
  Check ([Convert]::ToHexString($currentBinding.hash) -eq $pki.leaf.Thumbprint -and $currentBinding.store -eq 'My') 'Restore changed the replacement machine actual IIS certificate binding.'
  HeldServiceRestart
  EnableTargetTls -Prepared;NativeFixture 'activate-calls';NativeFixture 'native-target';NativeFixture 'job'
  NativeFixture 'activate-updates';NativeFixture 'activate-backups';NativeFixture 'target-backup';AssertBackupTask
  foreach($name in $originalTaskStates.Keys){Check ([bool](Get-ScheduledTask -TaskName $name).Settings.Enabled -eq $originalTaskStates[$name]) 'Explicit activation failed to preserve an original cleanup/mail/certificate task enabled state.'}
  foreach($name in 'FreeSWITCH','OpenWebPBX','OpenWebPBXUpdater'){$service=Get-CimInstance Win32_Service -Filter ("Name='"+$name+"'");Check ($service.State -eq 'Running' -and $service.StartMode -eq 'Auto') 'Every explicitly activated service must be Running with automatic startup.'}
  Check ((Get-CimInstance Win32_Service -Filter "Name='OpenWebPBX'").StartName -in 'NT AUTHORITY\LocalService','NT AUTHORITY\Local Service') 'Restored automatic jobs must still run under the actual LOCAL SERVICE identity.'
  $facts.gates.explicit_all_class_activation_preserves_owned_task_states_and_service_identities='passed'
 }
 # Finish actual task qualification before disabling only this fresh fixture's
 # timer, so cleanup cannot race another daily command at a UTC boundary.
 Disable-ScheduledTask -TaskName 'OpenWebPBX-Backups'|Out-Null
 Stop-ScheduledTask -TaskName 'OpenWebPBX-Backups' -ErrorAction SilentlyContinue
 NativeFixture 'cleanup'
 $nativeFacts=Get-Content (Join-Path (Split-Path $inputFile -Parent) 'facts.json') -Raw|ConvertFrom-Json
 foreach($property in $nativeFacts.gates.PSObject.Properties){$facts.gates[$property.Name]=$property.Value}
 $facts.state='passed'
}catch{
 $facts.state='failed';$facts.failed_phase=$phase;$facts.error_type=$_.Exception.GetType().Name
 $facts.source_basename=[IO.Path]::GetFileName($_.InvocationInfo.ScriptName);$facts.source_line=[int]$_.InvocationInfo.ScriptLineNumber
 throw
}finally{
 try{
  if($installed){
   foreach($name in 'OpenWebPBXUpdater','OpenWebPBX','FreeSWITCH'){Stop-Service $name -Force -ErrorAction SilentlyContinue}
   foreach($name in 'OpenWebPBX-Backups','OpenWebPBX Outgoing Mail','OpenWebPBX-Cleanup','OpenWebPBX Certificate Renewal','OpenWebPBX Pending Phone Certificate','OpenWebPBX-Updater-Restart'){$task=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue;if($task){Disable-ScheduledTask -InputObject $task|Out-Null;Stop-ScheduledTask -InputObject $task -ErrorAction SilentlyContinue}}
   # Stop only the installer-created PostgreSQL service, never another instance.
   $pg=@(Get-CimInstance Win32_Service|Where-Object {$_.Name -like 'OpenWebPBX*' -and $_.PathName -like '*C:\OpenWebPBX\pgsql*'})
   foreach($service in $pg){Stop-Service $service.Name -Force -ErrorAction SilentlyContinue}
  }
  if($pki){Stop-SuiteRecoveryPki $pki}
  if($installed -and (Test-Path "$env:SystemRoot\System32\inetsrv\Microsoft.Web.Administration.dll")){
   Add-Type -Path "$env:SystemRoot\System32\inetsrv\Microsoft.Web.Administration.dll"
   $manager=[Microsoft.Web.Administration.ServerManager]::new()
   try{StopQualificationIis $manager.Sites['OpenWebPBX'] $manager.ApplicationPools['OpenWebPBX']}finally{$manager.Dispose()}
  }
  if($hostsBefore){$hostsPath=Join-Path $env:SystemRoot 'System32/drivers/etc/hosts';Check ([Convert]::ToBase64String([IO.File]::ReadAllBytes($hostsPath)) -eq [Convert]::ToBase64String($hostsExpected)) 'Hostname cleanup refuses unexpected foreign changes.';[IO.File]::WriteAllBytes($hostsPath,$hostsBefore)}
  Check (@(Get-Service -Name FreeSWITCH,OpenWebPBX,OpenWebPBXUpdater -ErrorAction SilentlyContinue|Where-Object Status -eq 'Running').Count -eq 0) 'Owned fixture services remain active.'
  $facts.cleanup='owned fresh services/tasks stopped, exact original hostname and owned CA/binding restored; durable journals retained privately'
 }catch{
  $facts.state='failed';$facts.cleanup='failed';$facts.cleanup_error_type=$_.Exception.GetType().Name
 }
 Remove-Item Env:\OPENWEB_WINDOWS_RESTORE_TEST -ErrorAction SilentlyContinue;Remove-Item Env:\WINDOWS_RESTORE_FIXTURE_PASSPHRASE -ErrorAction SilentlyContinue
 New-Item -ItemType Directory -Force $public|Out-Null;WriteJson (Join-Path $public 'qualification.json') $facts
}
if($facts.state -ne 'passed' -or $facts.cleanup -eq 'failed'){throw 'The separate-server restore qualification did not pass; no Windows acceptance is implied.'}
