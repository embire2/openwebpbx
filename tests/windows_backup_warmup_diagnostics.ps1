#Requires -Version 5.1
[CmdletBinding()]param([string]$SourceRoot)
# Source-extracted reporting only; no installed task, service or worker runs.
$ErrorActionPreference='Stop';$checks=0
if(!$SourceRoot){$SourceRoot=Split-Path $PSScriptRoot -Parent}
. (Join-Path $SourceRoot 'tests/windows-backup-warmup-diagnostics.ps1')
function Verify([bool]$Value){$script:checks++;if(!$Value){throw ('Warm-up diagnostics control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)}}
function SourceAst([string]$Name){$tokens=$null;$errors=$null;$result=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot ('tests/'+$Name)),[ref]$tokens,[ref]$errors);Verify (@($errors).Count -eq 0);return $result}
function FunctionText($Ast,[string]$Name){$nodes=@($Ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Name},$true));Verify ($nodes.Count -eq 1);return $nodes[0].Extent.Text}
$updater=SourceAst 'windows-updater-qualification.ps1';$manual=SourceAst 'windows-upgrade-acceptance.ps1';$suite=SourceAst 'windows-suite.ps1'
$initializer=@($updater.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'InitializeQualificationBackupWorker'},$true));Verify ($initializer.Count -eq 1)
$statements=$initializer[0].Body.EndBlock.Statements;Verify ($statements.Count -eq 1 -and $statements[0] -is [Management.Automation.Language.TryStatementAst])
$originalBody=$statements[0].Body.Extent.Text;$originalBody=$originalBody.Substring(1,$originalBody.Length-2).Replace("`r`n","`n").Trim()
$sha=[Security.Cryptography.SHA256]::Create();try{$bodyHash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($originalBody)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
Verify ($bodyHash -ceq 'df09a34eedf52fa9f05607574bf1a2aae07a00f442be0814a1869ceb86fef843')
foreach($name in 'QualificationFailureObservation','QualificationBackupWorkerFailureFields'){Invoke-Expression (FunctionText $updater $name)}
Invoke-Expression (FunctionText $suite 'SafeFailureFields')
foreach($name in 'HoldFailureFields','SafeQueueFailureFields','SafeVoicemailFailureFields','SafeMailboxFailureFields','SafeHotelFailureFields','SafeSmtpFailureFields','SafeMeetingOwnerPageFields','SafeMeetingMediaFields','SafeMeetingSignalingFields','SafeMeetingPathFields','SafeNativeCleanupFields'){Set-Item ('function:'+ $name) -Value {@{}}}
$manualCatch=@($manual.FindAll({param($n)$n -is [Management.Automation.Language.CatchClauseAst] -and $n.Body.Extent.Text.Contains("`$report.state='failed';`$report.failed_phase=`$phase")},$true));Verify ($manualCatch.Count -eq 1)
$forward=@($manualCatch[0].Body.Statements|Where-Object {$_ -is [Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text -ceq "`$phase -ceq 'ordinary SYSTEM backup worker baseline initialization'"});Verify ($forward.Count -eq 1)
$forwardBody=[ScriptBlock]::Create($forward[0].Extent.Text)
$private='PRIVATE_password_SDDL_arguments_customer'
$root=Join-Path ([IO.Path]::GetTempPath()) 'warmup-reporting-only';$python=Join-Path $root 'backup-runtime/python.exe';$arguments='PRIVATE expected arguments'
$task=@{TaskName='OpenWebPBX-Backups';TaskPath='\';Settings=@{Enabled=$true;MultipleInstances='IgnoreNew'};Principal=@{UserId='SYSTEM';LogonType='ServiceAccount';RunLevel='Highest'};Actions=@(@{Execute=$python;Arguments=$arguments;WorkingDirectory=(Join-Path $root 'tools')});State='Ready'}
$cases=[ordered]@{name={param($t)$t.TaskName=$private};path={param($t)$t.TaskPath=$private};enabled={param($t)$t.Settings.Enabled=$false};multiple={param($t)$t.Settings.MultipleInstances=$private};principal={param($t)$t.Principal.UserId=$private};logon={param($t)$t.Principal.LogonType=$private};runlevel={param($t)$t.Principal.RunLevel=$private};action_count={param($t)$t.Actions=@()};execute={param($t)$t.Actions[0].Execute=$private};arguments={param($t)$t.Actions[0].Arguments=$private};workdir={param($t)$t.Actions[0].WorkingDirectory=$private};state={param($t)$t.State=$private}}
foreach($field in $cases.Keys){
 $copy=$task|ConvertTo-Json -Depth 10|ConvertFrom-Json
 # Copy using JSON, as the real outer hook does on both PowerShell generations.
 & $cases[$field] $copy
 try{throw 'Backup warm-up refuses an unexpected normal SYSTEM task.'}catch{$errorRecord=$_}
 $detail=ObserveBackupWarmupFailure $errorRecord $copy $python $arguments $root $null $null $null $null $null $null
 Verify ($detail.stage -ceq 'task_identity' -and $detail.mismatches -ccontains $field)
 Verify (!(($detail|ConvertTo-Json -Depth 8 -Compress).Contains($private)))
}
foreach($message in (BackupWarmupStages).Keys){try{throw $message}catch{$detail=ObserveBackupWarmupFailure $_ $task $python $arguments $root @($python,'unused') @{PSIsContainer=$false;Attributes=0} @{PSIsContainer=$true;Attributes=0} @{PSIsContainer=$false;Attributes=0} @{} @{}};Verify ($detail.stage -ceq (BackupWarmupStages)[$message])}
try{throw $private}catch{$unknown=ObserveBackupWarmupFailure $_ $task $python $arguments $root $null $null $null $null $null $null};Verify ($unknown.stage -ceq 'unknown')
$worker=@{schema=1;last_task_result=1;task_state='Ready';last_run_advanced=$true;last_run_not_future=$true;prior_run_not_future=$true}
$detail=@{schema=1;stage='worker_result';runtime_component='unknown';mismatches=@()}
try{throw 'The actual normal backup task did not finish successfully.'}catch{
 $_.Exception.Data['openweb_qa_backup_warmup']=$detail;$_.Exception.Data['openweb_qa_backup_worker']=$worker
 $phase='ordinary SYSTEM backup worker baseline initialization';$report=@{};. $forwardBody
}
Verify ($report.backup_warmup.stage -ceq 'worker_result' -and $report.backup_worker.last_task_result -eq 1)
$trace="at Check, C:\private\windows-updater-qualification.ps1: line 49`nat InitializeQualificationBackupWorker, C:\private\windows-updater-qualification.ps1: line 450"
$signed=QualificationFailureObservation $trace $null $null $null $worker $null $detail
Verify ($signed.backup_warmup.stage -ceq 'worker_result' -and $signed.backup_worker.last_task_result -eq 1)
Verify (!(QualificationFailureObservation '' $null $null $null $worker $null $detail).ContainsKey('backup_warmup'))
$report.failed_phase=$phase;$report.source_basename='windows-upgrade-acceptance.ps1'
$decoded=$report|ConvertTo-Json -Depth 10|ConvertFrom-Json
$safe=SafeFailureFields $decoded;Verify ($safe.backup_warmup.stage -ceq 'worker_result' -and $safe.backup_worker.last_task_result -eq 1)
foreach($change in @(@('stage',@('worker_result',$private)),@('stage',$private),@('schema','1'),@('runtime_component',@('unknown',$private)),@('mismatches',@($private)),@('extra',$private))){$copy=@{};foreach($k in $detail.Keys){$copy[$k]=$detail[$k]};$copy[$change[0]]=$change[1];Verify ($null -eq (BackupWarmupFailureFields $copy))}
foreach($change in @(@('last_task_result','1'),@('last_task_result',0),@('task_state',@('Ready',$private)),@('last_run_advanced',$false),@('extra',$private))){$copy=@{};foreach($k in $worker.Keys){$copy[$k]=$worker[$k]};$copy[$change[0]]=$change[1];Verify ($null -eq (BackupWarmupWorkerFields $copy))}
$decoded.backup_warmup.stage=@('worker_result',$private);Verify (!(SafeFailureFields $decoded).ContainsKey('backup_warmup'))
$decoded.backup_warmup.stage='worker_result';$decoded.failed_phase='other';Verify (!(SafeFailureFields $decoded).ContainsKey('backup_warmup'))
@{schema=1;state='passed';checks=$checks;powershell_major=$PSVersionTable.PSVersion.Major;scope='actual source-extracted closed manual/signed/outer reporting; no Scheduler or worker invocation'}|ConvertTo-Json -Compress
