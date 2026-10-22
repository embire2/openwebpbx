#Requires -RunAsAdministrator
#Requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PackageRoot,[Parameter(Mandatory)][string]$ReportPath,[switch]$DisposableHostedRunner)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if(!$DisposableHostedRunner -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:RUNNER_OS -ne 'Windows' -or $env:GITHUB_REPOSITORY -ne 'embire2/openwebpbx' -or [Environment]::OSVersion.Version.Build -lt 26100){throw 'The explicit disposable Windows Server factory is required.'}
$state=Join-Path $env:ProgramData 'OpenWebPBX';$root='C:\OpenWebPBX';$work=Join-Path $state ('health-qualification\'+[Guid]::NewGuid().ToString('N'));$taskName='OpenWebPBX-HealthComponent-'+[Guid]::NewGuid().ToString('N');$created=$false
$report=[ordered]@{schema=1;producer='windows_phone_health_acceptance.ps1';state='running';actual_native_windows=$true;gates=[ordered]@{installed_task='pending';installed_system_observer='pending';installed_collector='pending';postgresql_policy='pending';runtime='pending';firewall='pending';cleanup='pending'};policy_signalling_doubles=$true;physical_phone_audio=$false}
function PrivateDirectory([string]$Path){New-Item -ItemType Directory -Force -Path $Path|Out-Null;$acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetAccessRuleProtection($true,$false);$acl.SetOwner([Security.Principal.SecurityIdentifier]'S-1-5-32-544');foreach($sid in 'S-1-5-18','S-1-5-32-544'){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]$sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))};Set-Acl -LiteralPath $Path -AclObject $acl}
function Php([string]$File,[string[]]$Arguments){$output=& "$root\php\php.exe" $File @Arguments 2>> (Join-Path $work 'php.private.err');if($LASTEXITCODE){throw 'The native health PHP check failed.'};return (($output -join "`n")|ConvertFrom-Json)}
try{
 $installation=Get-Content -LiteralPath (Join-Path $state 'installation.json') -Raw|ConvertFrom-Json
 if(!$installation.Completed -or !$installation.RestoreServer){throw 'A completed empty restore factory is required.'}
 PrivateDirectory $work;PrivateDirectory (Join-Path $work 'spool');PrivateDirectory (Join-Path $work 'identity')
 [IO.File]::WriteAllText((Join-Path $work 'identity\phone-health-instance.json'),('{"schema":1,"instance_id":"'+('a'*64)+'"}'),[Text.UTF8Encoding]::new($false))
 . (Join-Path $root 'tools\PhoneHealth-Security.ps1')
 $task=Get-ScheduledTask -TaskName 'OpenWebPBX-PhoneHealth' -TaskPath '\' -ErrorAction Stop;Assert-OpenWebHealthTask $task
 if(!$task.Settings.Enabled -or $task.State -ne 'Running'){throw 'The installed persistent health task is not running.'};$report.gates.installed_task='passed'
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
 $oldPassword=$env:OPENWEB_HEALTH_TEST_PASSWORD;$oldState=$env:OPENWEB_HEALTH_TEST_STATE;$oldSpool=$env:OPENWEB_HEALTH_TEST_SPOOL
 try{
  $env:OPENWEB_HEALTH_TEST_PASSWORD=$installation.PostgresPassword;$env:OPENWEB_HEALTH_TEST_STATE=Join-Path $work 'identity';$env:OPENWEB_HEALTH_TEST_SPOOL=Join-Path $work 'spool'
  $policy=Php (Join-Path $PSScriptRoot 'pbx_phone_health.php') @('pgsql:host=127.0.0.1;port=5433;dbname=fusionpbx','--windows-guard-controls')
  if($policy.checks -lt 83 -or $policy.actual_isolated_postgresql -ne $true -or $policy.windows_guard_policy -ne $true -or $policy.no_customer_calls_or_host_firewall_changes -ne $true){throw 'The native PostgreSQL health policy failed.'};$report.gates.postgresql_policy='passed';$report.postgresql_checks=[int]$policy.checks
  $runtime=Php (Join-Path $PSScriptRoot 'windows_phone_health_runtime.php') @();if($runtime.checks -lt 49 -or $runtime.actual_windows_native -ne $true -or $runtime.actual_files_and_locks -ne $true -or $runtime.actual_loopback_tcp_frames -ne $true){throw 'The native health runtime failed.'};$report.gates.runtime='passed';$report.runtime_checks=[int]$runtime.checks
 }finally{foreach($item in @(@('OPENWEB_HEALTH_TEST_PASSWORD',$oldPassword),@('OPENWEB_HEALTH_TEST_STATE',$oldState),@('OPENWEB_HEALTH_TEST_SPOOL',$oldSpool))){if($null -eq $item[1]){Remove-Item -LiteralPath ('Env:\'+$item[0]) -ErrorAction SilentlyContinue}else{Set-Item -LiteralPath ('Env:\'+$item[0]) -Value $item[1]}}}
 $firewallOutput=& (Join-Path $PSScriptRoot 'windows_phone_health_native.ps1') -Helpers (Join-Path $root 'tools');$firewall=($firewallOutput -join "`n")|ConvertFrom-Json
 if(!$? -or $firewall.actual_native_windows_defender -ne $true -or $firewall.all_original_projected_policy_exact -ne $true -or $firewall.checks -lt 16){throw 'The native phone firewall gate failed.'};$report.gates.firewall='passed';$report.firewall_checks=[int]$firewall.checks
 $task=Get-ScheduledTask -TaskName 'OpenWebPBX-PhoneHealth' -TaskPath '\' -ErrorAction Stop;Assert-OpenWebHealthTask $task;if(!$task.Settings.Enabled -or $task.State -ne 'Running'){throw 'The persistent health task stopped during qualification.'}
 $report.state='passed'
}catch{$report.state='failed';$report.error_type=$_.Exception.GetType().Name;throw}
finally{
 try{if($created){$task=Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction Stop;if($task.Description -ne 'OpenWeb PBX isolated phone health qualification' -or @($task.Actions).Count -ne 1 -or $task.Actions[0].Execute -ine $execute -or $task.Actions[0].Arguments -cne $arguments -or $task.Principal.UserId -notin 'SYSTEM','S-1-5-18'){throw 'The isolated task changed before cleanup.'};Stop-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction Stop;Unregister-ScheduledTask -TaskName $taskName -TaskPath '\' -Confirm:$false -ErrorAction Stop};$report.gates.cleanup='passed'}catch{$report.state='failed';$report.gates.cleanup='failed';throw}
 finally{[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))}
}
