#Requires -Version 7.4
[CmdletBinding()]param([string]$SourceRoot)
# Exact helper + actual restore-gate/file/hash operations, with Task Scheduler
# bound to fictional lifecycle records. No installed runtime, task or service runs.
$ErrorActionPreference='Stop';$checks=0
if(!$SourceRoot){$SourceRoot=Split-Path $PSScriptRoot -Parent}
function Verify([bool]$Value){$script:checks++;if(!$Value){throw ('Backup warm-up control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)}}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-updater-qualification.ps1'),[ref]$tokens,[ref]$errors)
Verify (@($errors).Count -eq 0)
$defs=@{}
foreach($name in 'Check','Hash','InitializeQualificationBackupWorker','QualificationFailureObservation'){
 $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));Verify ($nodes.Count -eq 1);$defs[$name]=$nodes[0].Extent.Text
}
$body=$defs.InitializeQualificationBackupWorker
Verify ($body.Contains('Start-ScheduledTask -TaskName OpenWebPBX-Backups') -and $body.Contains('$info.LastRunTime -gt $prior.LastRunTime') -and $body.Contains('$info.LastTaskResult -eq 0'))
Verify ($body.Contains('$remaining=120') -and $body.Contains('Start-Sleep -Milliseconds 500'))
Verify ($body.Contains('(Get-Date) -le $prior.LastRunTime.AddSeconds(1)'))
Verify ($body -notmatch '(?:New|Set|Remove|Disable|Enable|Stop|Unregister)-ScheduledTask|\[IO\.File\]::(?:Write|Create|Open)|New-Item|Remove-Item')
Verify ($body.Contains('(TaskSnapshot)') -and $body.Contains("'exists','enabled','xml','acl','security'"))
$source=$ast.Extent.Text;$call=$source.IndexOf('InitializeQualificationBackupWorker -Root $root -StateRoot $state -PackageRoot $package')
Verify ($call -gt $source.IndexOf('$heldOriginalManager=RetainQualificationProcess'))
foreach($text in @("`$beforeDb=DatabaseSnapshot 'before-fault'",'$beforeFiles=FileSnapshot','$beforeTasks=TaskSnapshot','$protected=FileSnapshot -Protected',"Python 'request';`$failure=WaitInstall")){Verify ($source.IndexOf($text) -gt $call)}
$private='PRIVATE_SENTINEL_password_SDDL_S-1-5-21_customer'
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('BackupWarmup-'+$private+'-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory $temporary
function Get-ScheduledTask {
 param($TaskName,$ErrorAction)
 Verify ($TaskName -ceq 'OpenWebPBX-Backups');$script:reads++
 if($script:mode -ceq 'initial_running' -and !$script:started){$script:task.State=if($script:reads -lt 3){'Running'}else{'Ready'}}
 elseif($script:started){$script:task.State=if($script:mode -ceq 'deadline'){'Running'}else{'Ready'}}
 if($script:mode -ceq 'late_identity' -and $script:started){$script:task.Principal.UserId=$private}
 return $script:task
}
function Get-ScheduledTaskInfo {
 param($TaskName,$ErrorAction)
 Verify ($TaskName -ceq 'OpenWebPBX-Backups')
 $time=[DateTime]'2026-01-01T00:00:00Z'
 if($script:mode -ceq 'coarse_time'){$time=if($script:started){$script:invocationTime}else{[DateTime]'2026-01-01T00:00:00Z'}}
 elseif($script:mode -ceq 'clock_deadline'){$time=$time.AddMinutes(5)}
 elseif($script:started -and $script:mode -cne 'stale'){$time=$time.AddMinutes(1)}
 return @{LastRunTime=$(if($script:mode -ceq 'bad_time'){$private}else{$time});LastTaskResult=$(if($script:mode -ceq 'nonzero'){1}else{0})}
}
function Start-ScheduledTask {
 param($TaskName,$ErrorAction)
 Verify ($TaskName -ceq 'OpenWebPBX-Backups');$script:starts++;$script:started=$true
 $script:invocationTime=$script:clock.AddTicks(-($script:clock.Ticks%[TimeSpan]::TicksPerSecond))
 if($script:mode -ceq 'coarse_time'){Verify ($invocationTime -gt [DateTime]'2026-01-01T00:00:00Z')}
 # Fixture binding only: actual product worker file creation is tested separately.
 if($script:mode -ceq 'missing_lock'){return}
 if($script:mode -ceq 'directory_lock'){$null=New-Item -ItemType Directory $script:worker;return}
 if($script:mode -ceq 'linked_lock'){$null=New-Item -ItemType SymbolicLink -Path $script:worker -Target $script:target;return}
 [IO.File]::WriteAllBytes($script:worker,[byte[]]@())
}
function Get-Date {return $script:clock}
function Start-Sleep {param($Milliseconds) Verify ($Milliseconds -eq 500);$script:sleeps++;$script:clock=$script:clock.AddMilliseconds(500)}
function TaskSnapshot {
 $script:snapshots++
 $record=@{exists=$true;enabled=$true;xml=$private+'-xml';acl=$private+'-file';security=$private+'-com'}
 if($script:started -and $script:mode -cin @('changed_xml','changed_acl','changed_security')){$record[$script:mode.Substring(8)]='changed'}
 return @{'OpenWebPBX-Backups'=$record}
}
try{
 $script:root=Join-Path $temporary 'installed';$script:state=Join-Path $temporary 'state';$script:package=Join-Path $temporary 'package'
 $null=New-Item -ItemType Directory -Force (Join-Path $root 'tools'),(Join-Path $root 'backup-runtime'),(Join-Path $package 'backup-runtime'),(Join-Path $state 'automatic-backups'),(Join-Path $state 'backup-restore'),(Join-Path $state 'updates')
 $script:worker=Join-Path $state 'automatic-backups/worker.lock';$script:target=Join-Path $temporary 'owned-link-target';[IO.File]::WriteAllText($target,'untouched')
 Copy-Item (Join-Path $SourceRoot 'packaging/windows/Restore-Gates.ps1') (Join-Path $package 'Restore-Gates.ps1')
 $fixture=Join-Path $temporary 'windows-updater-qualification.ps1';[IO.File]::WriteAllText($fixture,(@('Check','Hash','InitializeQualificationBackupWorker','QualificationFailureObservation'|ForEach-Object {$defs[$_]}) -join "`n"));. $fixture
 function ResetCase([string]$Name){
  $script:mode=$Name;$script:started=$false;$script:starts=0;$script:reads=0;$script:sleeps=0;$script:snapshots=0;$script:clock=[DateTime]'2026-01-01T00:01:02Z'
  if($Name -ceq 'coarse_time'){$script:clock=[DateTime]'2026-01-01T00:00:00.200Z'}
  foreach($p in @(Get-ChildItem (Join-Path $state 'backup-restore') -Force)+@(Get-ChildItem (Join-Path $state 'updates') -Force)){Remove-Item -LiteralPath $p.FullName -Force}
  if(Test-Path -LiteralPath $worker){Remove-Item -LiteralPath $worker -Recurse -Force}
  foreach($p in @((Join-Path $root 'backup-runtime/python.exe'),(Join-Path $package 'backup-runtime/python.exe'))){[IO.File]::WriteAllText($p,'fictional runtime')}
  foreach($p in @((Join-Path $root 'tools/backups.py'),(Join-Path $package 'backups.py'))){[IO.File]::WriteAllText($p,'fictional worker')}
  $script:task=[pscustomobject]@{TaskName='OpenWebPBX-Backups';TaskPath='\';State='Ready';Settings=@{Enabled=$true;MultipleInstances='IgnoreNew'};Principal=@{UserId='SYSTEM';LogonType='ServiceAccount';RunLevel='Highest'};Actions=@(@{Execute=(Join-Path $root 'backup-runtime/python.exe');Arguments=('-I "'+(Join-Path $root 'tools/backups.py')+'" worker');WorkingDirectory=(Join-Path $root 'tools')})}
 }
 function InvokeControl([bool]$Pass,[int]$ExpectedStarts){
  $caught=$null;$output=@();try{$output=@(InitializeQualificationBackupWorker $root $state $package)}catch{$caught=$_}
  if(($null -eq $caught) -ne $Pass){throw ('Unexpected warm-up outcome for fixed control '+$mode)}
  Verify (($null -eq $caught) -eq $Pass);Verify ($starts -eq $ExpectedStarts);Verify ($output.Count -eq 0)
  Verify ($sleeps -le 120 -and [IO.File]::ReadAllText($target) -ceq 'untouched')
  if($caught){
   $observed=QualificationFailureObservation $caught.ScriptStackTrace $null $null
   $safe=$observed|ConvertTo-Json -Depth 16 -Compress
   Verify (!$safe.Contains($private) -and !$safe.Contains($temporary) -and !$safe.Contains('worker.lock'))
  }else{Verify ((Test-Path -LiteralPath $worker -PathType Leaf) -and $snapshots -eq 2)}
 }
 foreach($name in 'success','initial_running','coarse_time'){ResetCase $name;InvokeControl $true 1;if($name -cin @('initial_running','coarse_time')){Verify ($sleeps -eq 2)}}
 foreach($name in 'disabled','principal','logon','level','execute','arguments','working_directory','actions','task_path','task_name','multiple','state','runtime_hash','script_hash','bad_time','clock_deadline'){
  ResetCase $name
  switch($name){
   'disabled'{$task.Settings.Enabled=$false};'principal'{$task.Principal.UserId=$private};'logon'{$task.Principal.LogonType='Interactive'};'level'{$task.Principal.RunLevel='Limited'}
   'execute'{$task.Actions[0].Execute=$private};'arguments'{$task.Actions[0].Arguments=$private};'working_directory'{$task.Actions[0].WorkingDirectory=$private};'actions'{$task.Actions+=@($task.Actions[0])}
   'task_path'{$task.TaskPath='\foreign\'};'task_name'{$task.TaskName=$private};'multiple'{$task.Settings.MultipleInstances='Parallel'};'state'{$task.State='Unknown'}
   'runtime_hash'{[IO.File]::AppendAllText((Join-Path $root 'backup-runtime/python.exe'),'changed')};'script_hash'{[IO.File]::AppendAllText((Join-Path $root 'tools/backups.py'),'changed')}
  }
  InvokeControl $false 0
 }
 foreach($hold in 'calls','jobs','updates','backups'){ResetCase 'held';[IO.File]::WriteAllText((Join-Path $state ('backup-restore/hold-'+$hold)),$private);InvokeControl $false 0;Verify (Test-Path (Join-Path $state ('backup-restore/hold-'+$hold)))}
 foreach($status in 'prepared','restoring','recovery_required','private_json'){
  ResetCase 'journal';$text=if($status -ceq 'private_json'){$private}else{@{schema=1;state=$status}|ConvertTo-Json -Compress};[IO.File]::WriteAllText((Join-Path $state 'backup-restore/journal.json'),$text);InvokeControl $false 0
 }
 ResetCase 'maintenance';[IO.File]::WriteAllText((Join-Path $state 'updates/maintenance'),$private);InvokeControl $false 0;Verify (Test-Path (Join-Path $state 'updates/maintenance'))
 foreach($name in 'late_identity','nonzero','stale','deadline','missing_lock','directory_lock','linked_lock','changed_xml','changed_acl','changed_security'){
  ResetCase $name;InvokeControl $false 1
  if($name -cin @('stale','deadline')){Verify ($sleeps -eq 119)}
 }
 @{schema=1;state='passed';actual_source_controls=$checks;task_scheduler_binding='fictional lifecycle records only';normal_worker_proof='separate owned-file Python controls; native SYSTEM acceptance remains pending';private_values_excluded=$true;product_or_windows_task_executed=$false}|ConvertTo-Json -Compress
}finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Recurse -Force}}
