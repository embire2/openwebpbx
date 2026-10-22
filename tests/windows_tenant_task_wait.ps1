# SPDX-License-Identifier: AGPL-3.0-or-later
# Actual waiter AST controls; -Native uses isolated real SYSTEM tasks only.
[CmdletBinding()]
param([string]$SourceFile=(Join-Path $PSScriptRoot 'windows-tenant-domains-native.ps1'),[switch]$Native,[string]$OriginalSource,[string]$ReportPath)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';$checks=0
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($SourceFile,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The actual tenant waiter source does not parse.'}
$nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Wait-OpenWebTenantTaskResult'},$true));if($nodes.Count -ne 1){throw 'One exact native task waiter is required.'};Invoke-Expression $nodes[0].Extent.Text
function Check([bool]$Value,[string]$Reason){if(!$Value){throw ('Tenant task completion control failed: '+$Reason)};$script:checks++}
function Refuses([scriptblock]$Action,[string]$Reason){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Check $failed $Reason}
if(!$Native){
 $script:infos=@();$script:states=@();$script:reads=0;$script:stateReads=0;$previous=[DateTime]'2026-10-22T12:00:00Z'
 function Get-ScheduledTaskInfo {param($TaskName,$TaskPath);$index=[Math]::Min($script:reads++,$script:infos.Count-1);return $script:infos[$index]}
 function Get-ScheduledTask {param($TaskName,$TaskPath);$index=[Math]::Min($script:stateReads++,$script:states.Count-1);return @{State=$script:states[$index]}}
 function Fixture($Results,$States='Ready',[bool]$Fresh=$true){$script:reads=0;$script:stateReads=0;$script:infos=@(foreach($result in $Results){@{LastRunTime=$previous.AddSeconds($(if($Fresh){1}else{0}));LastTaskResult=$result}});$script:states=@($States)}
 foreach($pending in 267009,267011,267045){Fixture @($pending,0);$o=@{};$r=Wait-OpenWebTenantTaskResult -Name 'owned-fixture' -PreviousRun $previous -Observation $o -TimeoutSeconds 2;Check ($r.LastTaskResult -eq 0 -and $script:reads -eq 2 -and $o.fresh_run -and $o.completed) 'Pending Scheduler snapshot must settle before success'}
 Fixture @(17);$o=@{};$r=Wait-OpenWebTenantTaskResult -Name 'owned-fixture' -PreviousRun $previous -Observation $o -TimeoutSeconds 1;Check ($r.LastTaskResult -eq 17 -and $script:reads -eq 1 -and $o.completed) 'A real failed task must not be retried into success'
 Fixture @(0) @('Running','Ready','Ready','Ready');$o=@{};$r=Wait-OpenWebTenantTaskResult -Name 'owned-fixture' -PreviousRun $previous -Observation $o -TimeoutSeconds 1;Check ($script:reads -eq 2 -and $r.LastTaskResult -eq 0) 'A Running state on either side must prevent completion'
 Fixture @(0) @('Ready') $false;$o=@{};Refuses {Wait-OpenWebTenantTaskResult -Name 'owned-fixture' -PreviousRun $previous -Observation $o -TimeoutSeconds .25} 'A stale old zero result cannot pass';Check (!$o.fresh_run -and !$o.completed) 'Stale observation must remain incomplete'
 Fixture @(267009);$o=@{};$timer=[Diagnostics.Stopwatch]::StartNew();Refuses {Wait-OpenWebTenantTaskResult -Name 'owned-fixture' -PreviousRun $previous -Observation $o -TimeoutSeconds .25} 'A permanently pending result cannot pass';Check ($timer.Elapsed.TotalSeconds -lt 1 -and !$o.completed -and $o.last_task_result -eq 267009) 'Pending refusal must remain bounded and observable'
 foreach($value in 0,-1,45.1,[double]::NaN,[double]::PositiveInfinity){Refuses {Wait-OpenWebTenantTaskResult -Name 'owned-fixture' -PreviousRun $previous -Observation @{} -TimeoutSeconds $value} 'An unbounded wait parameter must refuse'}
 $result=@{state='passed';checks=$checks;actual_waiter_ast=$true;actual_windows_scheduler=$false;no_pbx_or_task_mutations=$true}
}else{
 if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or ![Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -or ![IO.File]::Exists($OriginalSource)){throw 'An explicit native administrator fixture and original source are required.'}
 $env:PSModulePath=$PSHOME+'\Modules;'+[Environment]::GetFolderPath('ProgramFiles')+'\WindowsPowerShell\Modules'
 Import-Module ScheduledTasks -ErrorAction Stop
 $oldAst=[Management.Automation.Language.Parser]::ParseFile($OriginalSource,[ref]$tokens,[ref]$errors);if($errors.Count){throw 'The retained old source does not parse.'}
 $oldLoops=@($oldAst.FindAll({param($n)$n -is [Management.Automation.Language.DoWhileStatementAst] -and $n.Extent.Text.StartsWith('do{Start-Sleep -Milliseconds 250;$run=Get-ScheduledTaskInfo -TaskName $taskName;')},$true));if($oldLoops.Count -ne 1){throw 'The exact retained old polling loop is required.'}
 $oldBody=[scriptblock]::Create($oldLoops[0].Extent.Text+"`n return @{result=[long]`$run.LastTaskResult;fresh=(`$run.LastRunTime -gt `$last);ready=(!`$running)}")
 $work=Join-Path $env:ProgramData ('OpenWebPBX-test-20261022\task-result-'+[Guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($work)
 $acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetAccessRuleProtection($true,$false);$acl.SetOwner([Security.Principal.SecurityIdentifier]'S-1-5-32-544');foreach($sid in 'S-1-5-18','S-1-5-32-544'){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]$sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))};Set-Acl -LiteralPath $work -AclObject $acl
 $child=Join-Path $work 'child.ps1';$pidFile=Join-Path $work 'child.pid';$exitFile=Join-Path $work 'exit.code';$releaseFile=Join-Path $work 'release.flag'
 $body='$ErrorActionPreference="Stop";[IO.File]::WriteAllText((Join-Path $PSScriptRoot "child.pid"),[string]$PID);$timer=[Diagnostics.Stopwatch]::StartNew();while(!(Test-Path -LiteralPath (Join-Path $PSScriptRoot "release.flag"))){if($timer.Elapsed.TotalSeconds -ge 20){exit 250};Start-Sleep -Milliseconds 20};exit ([int]([IO.File]::ReadAllText((Join-Path $PSScriptRoot "exit.code"))))'
 [IO.File]::WriteAllText($child,$body,[Text.UTF8Encoding]::new($false))
 $taskName='OpenWebPBX-TaskResultQA-'+[Guid]::NewGuid().ToString('N');$description='OpenWeb PBX isolated Scheduler result snapshot qualification';$execute=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe';$arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$child+'"';$registered=$false;$ownedPids=[Collections.Generic.List[int]]::new();$script:delaySnapshot=$false;$script:delayedSnapshots=0
 function AssertTask {$t=ScheduledTasks\Get-ScheduledTask -TaskName $taskName -TaskPath '\';if($t.Description -cne $description -or $t.Principal.UserId -notin 'SYSTEM','S-1-5-18' -or @($t.Actions).Count -ne 1 -or $t.Actions[0].Execute -cne $execute -or $t.Actions[0].Arguments -cne $arguments -or $t.Actions[0].WorkingDirectory -cne $work){throw 'The isolated task ownership changed.'}}
 function Get-ScheduledTaskInfo {
  param($TaskName,$TaskPath='\')
  if($TaskName -cne $script:ownedTask){throw 'The native snapshot seam refuses another task.'}
  $info=ScheduledTasks\Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath $TaskPath
  if($script:delaySnapshot -and [long]$info.LastTaskResult -eq 267009){$script:delaySnapshot=$false;$script:delayedSnapshots++;[IO.File]::WriteAllText($releaseFile,'owned snapshot released');$timer=[Diagnostics.Stopwatch]::StartNew();while((ScheduledTasks\Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath).State -eq 'Running'){if($timer.Elapsed.TotalSeconds -gt 10){throw 'The isolated native task did not settle.'};Start-Sleep -Milliseconds 10}}
  return $info
 }
 function StartOwned([int]$Exit){
  AssertTask;$last=(ScheduledTasks\Get-ScheduledTaskInfo -TaskName $taskName -TaskPath '\').LastRunTime;Start-Sleep -Milliseconds 1100
  foreach($file in $pidFile,$releaseFile){if(Test-Path -LiteralPath $file){Remove-Item -LiteralPath $file -Force}};[IO.File]::WriteAllText($exitFile,[string]$Exit)
  Start-ScheduledTask -TaskName $taskName -TaskPath '\';$timer=[Diagnostics.Stopwatch]::StartNew()
  while(!(Test-Path -LiteralPath $pidFile) -or (ScheduledTasks\Get-ScheduledTask -TaskName $taskName -TaskPath '\').State -ne 'Running'){if($timer.Elapsed.TotalSeconds -gt 10){throw 'The exact SYSTEM task did not start.'};Start-Sleep -Milliseconds 20}
  $childPid=[int][IO.File]::ReadAllText($pidFile);$p=Get-CimInstance Win32_Process -Filter ('ProcessId='+$childPid);if(!$p){throw 'The exact native fixture child exited before ownership verification.'};$owner=Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid
  if($p.ExecutablePath -cne $execute -or !$p.CommandLine.Contains($child) -or $owner.ReturnValue -ne 0 -or $owner.Sid -cne 'S-1-5-18'){throw 'The native fixture child identity differs.'};$ownedPids.Add($childPid);return $last
 }
 try{
  if(Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue){throw 'The isolated task name is occupied.'}
  $action=New-ScheduledTaskAction -Execute $execute -Argument $arguments -WorkingDirectory $work;$principal=New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest;$settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::FromMinutes(1))
  Register-ScheduledTask -TaskName $taskName -TaskPath '\' -Description $description -Action $action -Principal $principal -Settings $settings|Out-Null;$registered=$true;$script:ownedTask=$taskName
  $last=StartOwned 0;$script:delaySnapshot=$true;$deadline=[DateTime]::UtcNow.AddSeconds(10);$old=& $oldBody
  Check ($old.result -eq 267009 -and $old.fresh -and $old.ready -and $script:delayedSnapshots -eq 1) 'Old source must reproduce the real Running-info/Ready-state pair'
  $last=StartOwned 0;$script:delaySnapshot=$true;$o=@{};$run=Wait-OpenWebTenantTaskResult -Name $taskName -PreviousRun $last -Observation $o -TimeoutSeconds 10
  Check ($run.LastTaskResult -eq 0 -and $o.completed -and $o.fresh_run -and $script:delayedSnapshots -eq 2) 'Fixed source must wait for the real terminal zero result'
  $last=StartOwned 17;$script:delaySnapshot=$true;$o=@{};$run=Wait-OpenWebTenantTaskResult -Name $taskName -PreviousRun $last -Observation $o -TimeoutSeconds 10
  Check ($run.LastTaskResult -eq 17 -and $o.completed -and $o.fresh_run -and $script:delayedSnapshots -eq 3) 'A real failed native task must remain failed'
  $last=$run.LastRunTime;$o=@{};Refuses {Wait-OpenWebTenantTaskResult -Name $taskName -PreviousRun $last -Observation $o -TimeoutSeconds .3} 'No fresh run must refuse';Check (!$o.completed -and !$o.fresh_run) 'The stale failure result must not become a new completion'
  $last=StartOwned 0;$script:delaySnapshot=$false;$o=@{};Refuses {Wait-OpenWebTenantTaskResult -Name $taskName -PreviousRun $last -Observation $o -TimeoutSeconds .3} 'A running native task must time out';Check (!$o.completed -and $o.last_task_result -eq 267009) 'A pending result must remain visible'
 }finally{
  if($registered){AssertTask;Stop-ScheduledTask -TaskName $taskName -TaskPath '\';$timer=[Diagnostics.Stopwatch]::StartNew();while((ScheduledTasks\Get-ScheduledTask -TaskName $taskName -TaskPath '\').State -eq 'Running'){if($timer.Elapsed.TotalSeconds -ge 10){throw 'The isolated task did not stop.'};Start-Sleep -Milliseconds 100};Unregister-ScheduledTask -TaskName $taskName -TaskPath '\' -Confirm:$false}
  foreach($childPid in $ownedPids){if(Get-Process -Id $childPid -ErrorAction SilentlyContinue){throw 'An exact owned SYSTEM child remained after task stop.'}}
 }
 Check (!(Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue)) 'The owned task must be absent after cleanup'
 $result=@{state='passed';checks=$checks;actual_waiter_ast=$true;actual_windows_scheduler=$true;actual_system_child_identity=$true;native_snapshots_straddle_completion=$true;old_source_negative=$true;failed_task_preserved=$true;stale_run_refused=$true;pending_timeout_refused=$true;owned_task_and_children_removed=$true;no_pbx_services_or_firewall_changes=$true;source_sha256=(Get-FileHash $SourceFile -Algorithm SHA256).Hash.ToLowerInvariant();original_source_sha256=(Get-FileHash $OriginalSource -Algorithm SHA256).Hash.ToLowerInvariant()}
 }
if($ReportPath){[IO.File]::WriteAllText($ReportPath,($result|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))};$result|ConvertTo-Json -Compress
