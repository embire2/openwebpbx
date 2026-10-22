#Requires -RunAsAdministrator
#Requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PackageRoot,[Parameter(Mandatory)][string]$ReportPath,[switch]$DisposableHostedRunner)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if(!$DisposableHostedRunner -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:RUNNER_OS -ne 'Windows' -or $env:GITHUB_REPOSITORY -ne 'embire2/openwebpbx' -or [Environment]::OSVersion.Version.Build -lt 26100){throw 'The explicit disposable Windows Server factory is required.'}
$state=Join-Path $env:ProgramData 'OpenWebPBX';$root='C:\OpenWebPBX';$work=Join-Path $state ('health-qualification\'+[Guid]::NewGuid().ToString('N'));$taskName='OpenWebPBX-HealthComponent-'+[Guid]::NewGuid().ToString('N');$created=$false
$report=[ordered]@{schema=1;producer='windows_phone_health_acceptance.ps1';state='running';actual_native_windows=$true;gates=[ordered]@{installed_task='pending';installed_system_observer='pending';installed_collector='pending';installed_continuous_observer='pending';installed_restart='pending';native_worker='pending';postgresql_policy='pending';runtime='pending';custom_subscription='pending';firewall='pending';cleanup='pending'};policy_signalling_doubles=$true;physical_phone_audio=$false}
$workerRecoveryVerified=$false;$workerRecoveryFailure=$null;$workerPrimaryFailure=$null
function PrivateDirectory([string]$Path){New-Item -ItemType Directory -Force -Path $Path|Out-Null;$acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetAccessRuleProtection($true,$false);$acl.SetOwner([Security.Principal.SecurityIdentifier]'S-1-5-32-544');foreach($sid in 'S-1-5-18','S-1-5-32-544'){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]$sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))};Set-Acl -LiteralPath $Path -AclObject $acl}
function Php([string]$File,[string[]]$Arguments){$output=& "$root\php\php.exe" $File @Arguments 2>> (Join-Path $work 'php.private.err');if($LASTEXITCODE){throw 'The native health PHP check failed.'};return (($output -join "`n")|ConvertFrom-Json)}
function NativeHealthPolicy {
 $result=[ordered]@{}
 foreach($command in 'Get-NetFirewallRule','Get-NetFirewallAddressFilter','Get-NetFirewallPortFilter','Get-NetFirewallApplicationFilter','Get-NetFirewallServiceFilter','Get-NetFirewallInterfaceFilter','Get-NetFirewallInterfaceTypeFilter','Get-NetFirewallSecurityFilter','Get-NetFirewallProfile'){
  $rows=@(& $command -PolicyStore PersistentStore -ErrorAction Stop|ForEach-Object {$item=[ordered]@{};foreach($property in $_.CimInstanceProperties|Sort-Object Name){$item[$property.Name]=$property.Value};[pscustomobject]$item}|Sort-Object InstanceID,Name)
  $result[$command]=$rows
 };return ($result|ConvertTo-Json -Depth 16 -Compress)
}
function HealthProcess {
 $processes=@(Get-CimInstance Win32_Process -Filter "Name='php.exe'" -ErrorAction Stop|Where-Object {$_.ExecutablePath -ieq 'C:\OpenWebPBX\php\php.exe' -and $_.CommandLine -match 'phone-health\.php"?\s+service\b'})
 if($processes.Count -ne 1){return $null}
 $owner=Invoke-CimMethod -InputObject $processes[0] -MethodName GetOwnerSid -ErrorAction Stop;if($owner.ReturnValue -ne 0 -or $owner.Sid -cne 'S-1-5-18'){throw 'The installed observer process is not SYSTEM.'}
 $connections=@(Get-NetTCPConnection -OwningProcess $processes[0].ProcessId -RemoteAddress '127.0.0.1' -RemotePort 5433 -State Established -ErrorAction SilentlyContinue)
 $rows=@((Php (Join-Path $PSScriptRoot 'windows_phone_health_installed.php') @('heartbeat')).workers)
 foreach($row in $rows){if(@($connections|Where-Object {$_.LocalPort -eq [int]$row.client_port}).Count){return @{pid=[int]$processes[0].ProcessId;database_pid=[int]$row.pid;changed=[double]$row.changed}}}
 return $null
}
function HealthPreservationDifference($Before,$After) {
 $out=[ordered]@{schema=1;snapshot_valid=$false;namespace_changed=$false;inventory_changed=$false;table_count_changed=$false;global_digest_changed=$false;shape_changed_count=0;data_changed_count=0;object_count_before=0;object_count_after=0;changed_objects=@()}
 foreach($snapshot in $Before,$After){
  if($null -eq $snapshot -or $snapshot.state -cne 'observed' -or $snapshot.complete_public_rows -isnot [bool] -or !$snapshot.complete_public_rows -or $snapshot.complete_namespace_inventory -isnot [bool] -or !$snapshot.complete_namespace_inventory -or $snapshot.public_preservation_sha256 -isnot [string] -or $snapshot.public_preservation_sha256 -cnotmatch '^[a-f0-9]{64}$' -or $snapshot.namespace_sha256 -isnot [string] -or $snapshot.namespace_sha256 -cnotmatch '^[a-f0-9]{64}$' -or ($snapshot.tables -isnot [int] -and $snapshot.tables -isnot [long]) -or $snapshot.tables -lt 0 -or $snapshot.tables -gt 10000 -or $null -eq $snapshot.objects -or $snapshot.objects -is [array]){return $out}
 }
 $maps=@()
 foreach($snapshot in $Before,$After){
  $map=@{};$properties=@($snapshot.objects.PSObject.Properties)
  if($properties.Count -gt 10000){return $out}
  foreach($property in $properties){
   $value=$property.Value
   if($property.Name.Length -gt 256 -or $null -eq $value -or $value.kind -isnot [string] -or $value.kind -cnotin 'r','p','S','v','m' -or ($value.rows -isnot [int] -and $value.rows -isnot [long]) -or $value.rows -lt 0 -or $value.rows -gt 100000 -or $value.shape_sha256 -isnot [string] -or $value.shape_sha256 -cnotmatch '^[a-f0-9]{64}$' -or $value.data_sha256 -isnot [string] -or $value.data_sha256 -cnotmatch '^[a-f0-9]{64}$'){return $out}
   $map[$property.Name]=$value
  };$maps+=,$map
 }
 $out.snapshot_valid=$true;$out.namespace_changed=$Before.namespace_sha256 -cne $After.namespace_sha256;$out.table_count_changed=$Before.tables -ne $After.tables;$out.global_digest_changed=$Before.public_preservation_sha256 -cne $After.public_preservation_sha256
 $out.object_count_before=$maps[0].Count;$out.object_count_after=$maps[1].Count
 $names=@(@($maps[0].Keys)+@($maps[1].Keys)|Sort-Object -Unique)
 foreach($name in $names){
  $left=$maps[0][$name];$right=$maps[1][$name]
  if(!$left -or !$right){$out.inventory_changed=$true;continue}
  $shape=$left.kind -cne $right.kind -or $left.shape_sha256 -cne $right.shape_sha256;$data=$left.data_sha256 -cne $right.data_sha256 -or $left.rows -ne $right.rows
  if($shape){$out.shape_changed_count++};if($data){$out.data_changed_count++}
  # Public product object names only; never rows, schema names, owners, ACLs,
  # identity values, source addresses or raw query/error text.
  if(($shape -or $data) -and $name -cmatch '^v_[a-z0-9_]{1,90}$' -and $out.changed_objects.Count -lt 12){$out.changed_objects+=@{name=[string]$name;shape_changed=[bool]$shape;data_changed=[bool]$data;row_count_changed=[bool]($left.rows -ne $right.rows)}}
 }
 return $out
}
try{
 & (Join-Path $PSScriptRoot 'windows_health_preservation_diagnostics.ps1') -SourceRoot (Split-Path $PSScriptRoot -Parent)
 if(!$?){throw 'The closed complete-preservation diagnostics controls did not pass.'}
 & (Join-Path $PSScriptRoot 'windows_health_updater_quiescence.ps1') -SourceRoot (Split-Path $PSScriptRoot -Parent)
 if(!$?){throw 'The updater quiescence controls did not pass.'}
 . (Join-Path $PSScriptRoot 'windows-health-updater-quiescence.ps1')
 $installation=Get-Content -LiteralPath (Join-Path $state 'installation.json') -Raw|ConvertFrom-Json
 if(!$installation.Completed -or !$installation.RestoreServer){throw 'A completed empty restore factory is required.'}
 PrivateDirectory $work;PrivateDirectory (Join-Path $work 'spool');PrivateDirectory (Join-Path $work 'identity')
 [IO.File]::WriteAllText((Join-Path $work 'identity\phone-health-instance.json'),('{"schema":1,"instance_id":"'+('a'*64)+'"}'),[Text.UTF8Encoding]::new($false))
 . (Join-Path $root 'tools\PhoneHealth-Security.ps1')
 $task=Get-ScheduledTask -TaskName 'OpenWebPBX-PhoneHealth' -TaskPath '\' -ErrorAction Stop;Assert-OpenWebHealthTask $task
 if(!$task.Settings.Enabled -or $task.State -ne 'Running'){throw 'The installed persistent health task is not running.'};$report.gates.installed_task='passed'
 $initialHealthTaskXml=Export-ScheduledTask -TaskName 'OpenWebPBX-PhoneHealth' -TaskPath '\'
 $systemFile=Join-Path $work 'system-observer.ps1';$systemResult=Join-Path $work 'system-result.json'
 $system=@'
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$result='__RESULT__'
try{
 . 'C:\OpenWebPBX\tools\PhoneHealth-Security.ps1';Assert-OpenWebHealthSystem
 $parsed=$null
 for($attempt=0;$attempt -lt 3;$attempt++){
  $output=& 'C:\OpenWebPBX\tools\Phone-Health.ps1' -Once
  if(!$? -or $LASTEXITCODE){throw 'The installed SYSTEM observer failed.'}
  $parsed=($output -join "`n")|ConvertFrom-Json
  if($parsed.state -ne 'deferred'){break};Start-Sleep -Seconds 2
 }
 if($parsed.state -ne 'observed' -or $parsed.available -isnot [bool] -or !$parsed.available){throw 'The installed SYSTEM observer is unavailable.'}
 [IO.File]::WriteAllText($result,(@{state='passed';actual_system=$true;actual_installed_observer=$true}|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
}catch{[IO.File]::WriteAllText($result,(@{state='failed';error_type=$_.Exception.GetType().Name}|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false));exit 1}
'@
 [IO.File]::WriteAllText($systemFile,$system.Replace('__RESULT__',$systemResult),[Text.UTF8Encoding]::new($false))
 $execute=Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe';$arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$systemFile+'"'
 if(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue){throw 'The isolated SYSTEM task name is occupied.'}
 $action=New-ScheduledTaskAction -Execute $execute -Argument $arguments -WorkingDirectory $work;$principal=New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest;$settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::FromMinutes(5))
 Register-ScheduledTask -TaskName $taskName -TaskPath '\' -Action $action -Principal $principal -Settings $settings -Description 'OpenWeb PBX isolated phone health qualification'|Out-Null;$created=$true;Start-ScheduledTask -TaskName $taskName -TaskPath '\'
 $deadline=[DateTime]::UtcNow.AddMinutes(4);while(!(Test-Path -LiteralPath $systemResult)){if([DateTime]::UtcNow -ge $deadline){throw 'The native SYSTEM health observer timed out.'};Start-Sleep -Milliseconds 250}
 $result=Get-Content -LiteralPath $systemResult -Raw|ConvertFrom-Json
 if($result.state -ne 'passed' -or $result.actual_system -ne $true -or $result.actual_installed_observer -ne $true){throw 'The native SYSTEM health observer did not pass.'};$report.gates.installed_system_observer='passed'
 $native=Php (Join-Path $PSScriptRoot 'windows_phone_health_installed.php') @();if($native.state -ne 'passed' -or $native.actual_installed_collector -ne $true){throw 'The installed native collector failed.'};$report.gates.installed_collector='passed'
 $first=$null;$deadline=[DateTime]::UtcNow.AddSeconds(90);while(!$first){$first=HealthProcess;if(!$first){if([DateTime]::UtcNow -ge $deadline){throw 'The persistent health worker has no native PostgreSQL scan evidence.'};Start-Sleep -Milliseconds 500}}
 $second=$null;$deadline=[DateTime]::UtcNow.AddSeconds(75)
 while(!$second){Start-Sleep -Seconds 1;$candidate=HealthProcess;if($candidate){if($candidate.pid -ne $first.pid -or $candidate.database_pid -ne $first.database_pid){throw 'The persistent observer restarted instead of completing its next scan.'};if($candidate.changed -gt $first.changed){$second=$candidate}};if([DateTime]::UtcNow -ge $deadline){throw 'The installed persistent observer did not complete another scan.'}};$report.gates.installed_continuous_observer='passed'
 $maintenance=$null;$deadline=[DateTime]::UtcNow.AddSeconds(30)
 while(!$maintenance){try{$maintenance=[IO.File]::Open((Join-Path $state 'upgrade.lock'),'OpenOrCreate','ReadWrite','None')}catch [IO.IOException]{if([DateTime]::UtcNow -ge $deadline){throw 'The observer restart could not acquire the maintenance lock.'};Start-Sleep -Milliseconds 250}}
 try{Stop-OpenWebHealthTask -MaintenanceLock $maintenance -Disable;if((Get-ScheduledTask -TaskName 'OpenWebPBX-PhoneHealth' -TaskPath '\').Settings.Enabled -or (Get-Process -Id $first.pid -ErrorAction SilentlyContinue)){throw 'The owned observer did not stop cleanly.'};if(@(Get-ChildItem -LiteralPath (Join-Path $state 'phone-health-runtime') -Force).Count){throw 'Stopping the observer left private response files.'}}
 finally{$maintenance.Dispose();Enable-ScheduledTask -TaskName 'OpenWebPBX-PhoneHealth' -TaskPath '\' -ErrorAction Stop|Out-Null;Start-ScheduledTask -TaskName 'OpenWebPBX-PhoneHealth' -TaskPath '\' -ErrorAction Stop}
 $restarted=$null;$deadline=[DateTime]::UtcNow.AddSeconds(90);while(!$restarted){$restarted=HealthProcess;if(!$restarted){if([DateTime]::UtcNow -ge $deadline){throw 'The installed observer did not restart and scan.'};Start-Sleep -Milliseconds 500}}
 if($restarted.pid -eq $first.pid){throw 'The observer restart retained its old resident process.'};$report.gates.installed_restart='passed'
 # Actual ESL event -> real installed Defender adapter -> durable SQL ->
 # exact authorised removal, in a disposable schema. The normal observer is
 # stopped under the shared lock so it cannot consume the synthetic event.
 $maintenance=$null;$deadline=[DateTime]::UtcNow.AddSeconds(30)
 while(!$maintenance){try{$maintenance=[IO.File]::Open((Join-Path $state 'upgrade.lock'),'OpenOrCreate','ReadWrite','None')}catch [IO.IOException]{if([DateTime]::UtcNow -ge $deadline){throw 'The native worker gate could not acquire the maintenance lock.'};Start-Sleep -Milliseconds 250}}
 $publicBefore=$null;$workerPhp=Join-Path $PSScriptRoot 'windows_phone_health_worker.php';$workerProcessExited=$false;$updaterOriginal=$null
 try{
  Stop-OpenWebHealthTask -MaintenanceLock $maintenance -Disable
  # The independent updater heartbeat writes outside this lock. Quiesce only
  # its exact candidate-bound service before the complete, unfiltered baseline.
  Suspend-HealthQualificationUpdater ([ref]$updaterOriginal)
  $policyBefore=NativeHealthPolicy;$engineBefore=Get-CimInstance Win32_Service -Filter "Name='FreeSWITCH'" -ErrorAction Stop
  $publicBefore=Php (Join-Path $PSScriptRoot 'windows_phone_health_installed.php') @('preservation')
  if($publicBefore.state -cne 'observed' -or $publicBefore.public_preservation_sha256 -cnotmatch '^[a-f0-9]{64}$' -or $publicBefore.complete_public_rows -ne $true -or $publicBefore.complete_namespace_inventory -ne $true){throw 'The complete pre-worker factory inventory is unavailable.'}
  $identityBefore=(Get-FileHash -LiteralPath (Join-Path $state 'phone-health-instance.json') -Algorithm SHA256).Hash
  $identityAclBefore=(Get-Acl -LiteralPath (Join-Path $state 'phone-health-instance.json')).Sddl
  $taskBefore=Export-ScheduledTask -TaskName 'OpenWebPBX-PhoneHealth' -TaskPath '\'
  $deadline=[DateTime]::UtcNow.AddSeconds(30);while((Get-ScheduledTask -TaskName $taskName -TaskPath '\').State -eq 'Running'){if([DateTime]::UtcNow -ge $deadline){throw 'The first owned SYSTEM fixture is still running.'};Start-Sleep -Milliseconds 250}
  $workerResult=Join-Path $work 'native-worker-result.json';$workerPhp=Join-Path $PSScriptRoot 'windows_phone_health_worker.php'
  $worker=@'
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
try{
 . 'C:\OpenWebPBX\tools\PhoneHealth-Security.ps1';Assert-OpenWebHealthSystem
 $env:GITHUB_ACTIONS='true';$env:RUNNER_ENVIRONMENT='github-hosted';$env:GITHUB_REPOSITORY='embire2/openwebpbx'
 $output=& 'C:\OpenWebPBX\php\php.exe' '__PHP__' --native-windows-worker 2> '__ERROR__';$workerExit=$LASTEXITCODE
 $parsed=($output -join "`n")|ConvertFrom-Json
 [IO.File]::WriteAllText('__RESULT__',($parsed|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
 if($workerExit){exit 1}
}catch{[IO.File]::WriteAllText('__RESULT__',(@{state='failed';error_type=$_.Exception.GetType().Name;source_line=$_.InvocationInfo.ScriptLineNumber}|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false));exit 1}
'@
  [IO.File]::WriteAllText($systemFile,$worker.Replace('__PHP__',$workerPhp).Replace('__ERROR__',(Join-Path $work 'native-worker.private.err')).Replace('__RESULT__',$workerResult),[Text.UTF8Encoding]::new($false))
  Start-ScheduledTask -TaskName $taskName -TaskPath '\'
  $deadline=[DateTime]::UtcNow.AddMinutes(4);while(!(Test-Path -LiteralPath $workerResult)){if([DateTime]::UtcNow -ge $deadline){throw 'The actual native health worker timed out.'};Start-Sleep -Milliseconds 250}
  $workerReport=Get-Content -LiteralPath $workerResult -Raw|ConvertFrom-Json
  foreach($name in 'native_worker_failure','native_worker_cleanup_failure','native_worker_firewall_preflight'){if($workerReport.$name){$report[$name]=$workerReport.$name}}
  if($workerReport.state -ceq 'failed' -and $workerReport.error_type -is [string] -and ($workerReport.source_line -is [int] -or $workerReport.source_line -is [long])){$report.native_worker_launcher_failure=@{error_type=$workerReport.error_type;source_line=$workerReport.source_line}}
  foreach($field in 'actual_native_windows_worker','actual_esl_event','actual_defender_adapter','actual_postgresql','synthetic_office_history','post_native_fault_reconciled','revoked_role_refused','authorised_recovery_acknowledged'){if($workerReport.$field -ne $true){throw 'The native worker result is incomplete.'}}
  if($workerReport.state -ne 'passed' -or $workerReport.physical_phone_audio -ne $false -or $workerReport.checks -lt 13){throw 'The native worker did not pass.'}
  if((NativeHealthPolicy) -cne $policyBefore){throw 'The native worker changed original firewall policy.'}
  $engineAfter=Get-CimInstance Win32_Service -Filter "Name='FreeSWITCH'" -ErrorAction Stop;if($engineAfter.ProcessId -ne $engineBefore.ProcessId -or $engineAfter.State -ne $engineBefore.State){throw 'The native worker changed the call engine.'}
  $report.gates.native_worker='passed';$report.native_worker_checks=[int]$workerReport.checks;$report.native_worker_firewall_policy_exact=$true
 }catch{$workerPrimaryFailure=$_;throw}
 finally{
  try{
   # These strict comparisons run even when the worker failed. The whole public
   # baseline was taken after stopping the observer under the shared lock.
   if($publicBefore){
    $fixtureTask=Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction Stop
    if($fixtureTask.Description -cne 'OpenWeb PBX isolated phone health qualification' -or @($fixtureTask.Actions).Count -ne 1 -or $fixtureTask.Actions[0].Execute -ine $execute -or $fixtureTask.Actions[0].Arguments -cne $arguments -or $fixtureTask.Principal.UserId -notin 'SYSTEM','S-1-5-18'){throw 'The isolated native task changed.'}
    if($fixtureTask.State -eq 'Running'){Stop-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction Stop}
    $deadline=[DateTime]::UtcNow.AddSeconds(30)
    do{
     $remaining=@(Get-CimInstance Win32_Process -Filter "Name='php.exe' OR Name='powershell.exe'" -ErrorAction Stop|Where-Object {($_.ExecutablePath -ieq "$root\php\php.exe" -and $_.CommandLine -and $_.CommandLine.Contains($workerPhp)) -or ($_.ExecutablePath -ieq $execute -and $_.CommandLine -and $_.CommandLine.Contains($systemFile))})
     $running=(Get-ScheduledTask -TaskName $taskName -TaskPath '\').State -eq 'Running'
     if($remaining.Count -eq 0 -and !$running){$workerProcessExited=$true;break}
     if([DateTime]::UtcNow -ge $deadline){throw 'An exact native worker child remains.'};Start-Sleep -Milliseconds 100
    }while($true)
    if(@(Get-ChildItem -LiteralPath (Join-Path $state 'phone-health-runtime') -Force).Count){throw 'Native worker response files remain.'}
    if((NativeHealthPolicy) -cne $policyBefore){throw 'Native worker recovery changed original firewall policy.'}
    $engineAfter=Get-CimInstance Win32_Service -Filter "Name='FreeSWITCH'" -ErrorAction Stop
    if($engineAfter.ProcessId -ne $engineBefore.ProcessId -or $engineAfter.State -ne $engineBefore.State){throw 'Native worker recovery changed the call engine.'}
    $publicAfter=Php (Join-Path $PSScriptRoot 'windows_phone_health_installed.php') @('preservation')
    if($publicAfter.state -cne 'observed' -or $publicAfter.public_preservation_sha256 -cne $publicBefore.public_preservation_sha256 -or $publicAfter.tables -ne $publicBefore.tables -or $publicAfter.complete_public_rows -ne $true -or $publicAfter.complete_namespace_inventory -ne $true){$report.native_worker_preservation_failure=HealthPreservationDifference $publicBefore $publicAfter;throw 'Native worker recovery changed the complete public factory state.'}
    if((Get-FileHash -LiteralPath (Join-Path $state 'phone-health-instance.json') -Algorithm SHA256).Hash -cne $identityBefore -or (Get-Acl -LiteralPath (Join-Path $state 'phone-health-instance.json')).Sddl -cne $identityAclBefore -or (Export-ScheduledTask -TaskName 'OpenWebPBX-PhoneHealth' -TaskPath '\') -cne $taskBefore){throw 'Native worker recovery changed its protected identity or task.'}
    $workerRecoveryVerified=$true
   }
  }catch{$workerRecoveryVerified=$false;$workerRecoveryFailure=$_;if(!$workerPrimaryFailure){throw}}
  finally{
   try{Resume-HealthQualificationUpdater $updaterOriginal}
   finally{
    $maintenance.Dispose()
    if($workerProcessExited){Enable-ScheduledTask -TaskName 'OpenWebPBX-PhoneHealth' -TaskPath '\' -ErrorAction Stop|Out-Null;Start-ScheduledTask -TaskName 'OpenWebPBX-PhoneHealth' -TaskPath '\' -ErrorAction Stop}
   }
  }
  if($workerRecoveryVerified){
   $resumed=$null;$deadline=[DateTime]::UtcNow.AddSeconds(90)
   while(!$resumed){$resumed=HealthProcess;if(!$resumed){if([DateTime]::UtcNow -ge $deadline){$workerRecoveryVerified=$false;throw 'The installed observer did not resume after the native worker.'};Start-Sleep -Milliseconds 500}}
   $owned=Get-ScheduledTask -TaskName 'OpenWebPBX-PhoneHealth' -TaskPath '\' -ErrorAction Stop;Assert-OpenWebHealthTask $owned
   if(!$owned.Settings.Enabled -or $owned.State -ne 'Running' -or (Export-ScheduledTask -TaskName 'OpenWebPBX-PhoneHealth' -TaskPath '\') -cne $initialHealthTaskXml){$workerRecoveryVerified=$false;throw 'The installed observer task did not resume with its exact definition.'}
  }
 }
 $oldPassword=$env:OPENWEB_HEALTH_TEST_PASSWORD;$oldState=$env:OPENWEB_HEALTH_TEST_STATE;$oldSpool=$env:OPENWEB_HEALTH_TEST_SPOOL
 try{
  $env:OPENWEB_HEALTH_TEST_PASSWORD=$installation.PostgresPassword;$env:OPENWEB_HEALTH_TEST_STATE=Join-Path $work 'identity';$env:OPENWEB_HEALTH_TEST_SPOOL=Join-Path $work 'spool'
  $policy=Php (Join-Path $PSScriptRoot 'pbx_phone_health.php') @('pgsql:host=127.0.0.1;port=5433;dbname=fusionpbx','--windows-guard-controls')
  if($policy.checks -lt 96 -or $policy.actual_isolated_postgresql -ne $true -or $policy.windows_guard_policy -ne $true -or $policy.no_customer_calls_or_host_firewall_changes -ne $true){throw 'The native PostgreSQL health policy failed.'};$report.gates.postgresql_policy='passed';$report.postgresql_checks=[int]$policy.checks
  $runtime=Php (Join-Path $PSScriptRoot 'windows_phone_health_runtime.php') @();if($runtime.checks -lt 49 -or $runtime.actual_windows_native -ne $true -or $runtime.actual_files_and_locks -ne $true -or $runtime.actual_loopback_tcp_frames -ne $true){throw 'The native health runtime failed.'};$report.gates.runtime='passed';$report.runtime_checks=[int]$runtime.checks
  $subscription=Php (Join-Path $PSScriptRoot 'windows_health_subscription.php') @((Join-Path $root 'web\resources\classes\pbx_windows_health_stream.php'))
  if($subscription.state -cne 'passed' -or ($subscription.checks -isnot [int] -and $subscription.checks -isnot [long]) -or $subscription.checks -lt 26 -or $subscription.checks -gt 100000){throw 'The installed custom-event subscription controls failed.'}
  foreach($field in 'actual_loopback_tcp','actual_php_child','subscription_peer_double','actual_windows_native','no_pbx_or_firewall_mutation'){if($subscription.$field -isnot [bool] -or !$subscription.$field){throw 'The installed stream subscription evidence is invalid.'}}
  $report.gates.custom_subscription='passed';$report.subscription_checks=[int]$subscription.checks
 }finally{foreach($item in @(@('OPENWEB_HEALTH_TEST_PASSWORD',$oldPassword),@('OPENWEB_HEALTH_TEST_STATE',$oldState),@('OPENWEB_HEALTH_TEST_SPOOL',$oldSpool))){if($null -eq $item[1]){Remove-Item -LiteralPath ('Env:\'+$item[0]) -ErrorAction SilentlyContinue}else{Set-Item -LiteralPath ('Env:\'+$item[0]) -Value $item[1]}}}
 $firewallOutput=& (Join-Path $PSScriptRoot 'windows_phone_health_native.ps1') -Helpers (Join-Path $root 'tools');$firewall=($firewallOutput -join "`n")|ConvertFrom-Json
 if(!$? -or $firewall.actual_native_windows_defender -ne $true -or $firewall.all_original_projected_policy_exact -ne $true -or $firewall.checks -lt 18){throw 'The native phone firewall gate failed.'}
 $emptyOutput=& (Join-Path $PSScriptRoot 'windows_phone_health_empty_rules.ps1') -Helpers (Join-Path $root 'tools');$empty=($emptyOutput -join "`n")|ConvertFrom-Json
 if(!$? -or $empty.state -cne 'passed' -or ($empty.checks -isnot [int] -and $empty.checks -isnot [long]) -or $empty.checks -lt 4 -or $empty.checks -gt 100000){throw 'The native empty phone-security query control failed.'}
 foreach($field in 'actual_native_windows','actual_empty_native_query','foreign_query_store_seam','no_pbx_or_firewall_mutation'){if($empty.$field -isnot [bool] -or !$empty.$field){throw 'The native empty-query scope is invalid.'}}
 $report.gates.firewall='passed';$report.firewall_checks=[int]$firewall.checks;$report.firewall_empty_query_checks=[int]$empty.checks
 $task=Get-ScheduledTask -TaskName 'OpenWebPBX-PhoneHealth' -TaskPath '\' -ErrorAction Stop;Assert-OpenWebHealthTask $task;if(!$task.Settings.Enabled -or $task.State -ne 'Running'){throw 'The persistent health task stopped during qualification.'}
 $report.state='passed'
}catch{$report.state='failed';$report.error_type=$_.Exception.GetType().Name;throw}
finally{
 try{if($created){$task=Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction Stop;if($task.Description -ne 'OpenWeb PBX isolated phone health qualification' -or @($task.Actions).Count -ne 1 -or $task.Actions[0].Execute -ine $execute -or $task.Actions[0].Arguments -cne $arguments -or $task.Principal.UserId -notin 'SYSTEM','S-1-5-18'){throw 'The isolated task changed before cleanup.'};Stop-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction Stop;Unregister-ScheduledTask -TaskName $taskName -TaskPath '\' -Confirm:$false -ErrorAction Stop};$report.gates.cleanup='passed'}catch{$report.state='failed';$report.gates.cleanup='failed';throw}
 finally{
  $report.diagnostic_recovery_exact=[bool]($workerRecoveryVerified -and $workerPrimaryFailure -and !$workerRecoveryFailure -and $report.gates.cleanup -ceq 'passed')
  if($workerRecoveryFailure){$report.diagnostic_recovery_failure=@{error_type=$workerRecoveryFailure.Exception.GetType().Name;source_line=[int]$workerRecoveryFailure.InvocationInfo.ScriptLineNumber}}
  [IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
 }
}
