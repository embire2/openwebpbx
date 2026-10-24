#Requires -Version 7.4
[CmdletBinding()]param(
 [string]$Source=(Join-Path $PSScriptRoot 'windows-updater-qualification.ps1'),
 [Parameter(Mandatory)][string]$OriginalSource
)
# Actual extracted functions; Scheduler and sleep are explicit portable adapters.
# No installed worker, native scheduled task, product configuration or signing.
$ErrorActionPreference='Stop';$checks=0
function Must([bool]$Value,[string]$Why){$script:checks++;if(!$Value){throw ('Control refused: '+$Why)}}
function Definitions([string]$Path){
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
 Must (@($errors).Count -eq 0) 'actual source parses'
 $defs=@{};foreach($node in $ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){$defs[$node.Name]=$node.Extent.Text};return $defs
}
$current=Definitions $Source;$old=Definitions $OriginalSource
Must ($current.Check -ceq $old.Check -and $current.Hash -ceq $old.Hash) 'original Check and hash helper exact'
$originalCheck="   Check (`$info.LastTaskResult -eq 0) 'The actual normal backup task did not finish successfully.'"
$diagnostic=@'
   try{Check ($info.LastTaskResult -eq 0) 'The actual normal backup task did not finish successfully.'}catch{
    $primary=$_
    try{$observed=ObserveQualificationBackupWorkerFailure $task $info $prior;if($observed){$primary.Exception.Data['openweb_qa_backup_worker']=$observed}}catch{}
    throw
   }
'@
Must ($current.InitializeQualificationBackupWorker.Replace($diagnostic,$originalCheck) -ceq $old.InitializeQualificationBackupWorker) 'complete original worker body exact except failure-only wrap'
Must ([regex]::Matches($current.InitializeQualificationBackupWorker,'Start-ScheduledTask -TaskName OpenWebPBX-Backups -ErrorAction Stop').Count -eq 1) 'one original start'
Must ($current.InitializeQualificationBackupWorker.Contains('$remaining=120') -and $current.InitializeQualificationBackupWorker.Contains('Start-Sleep -Milliseconds 500')) 'original bounded poll budget'
$work=Join-Path ([IO.Path]::GetTempPath()) ('openweb-updater-observation-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $work
try{
 $fixture=Join-Path $work 'windows-updater-qualification.ps1'
 $names=@('Check','Hash','QualificationBackupWorkerFailureFields','ObserveQualificationBackupWorkerFailure','QualificationFailureObservation','InitializeQualificationBackupWorker')
 [IO.File]::WriteAllText($fixture,(@($names|ForEach-Object {$current[$_]}) -join "`n"));. $fixture
 $script:productionCheck=${function:Check}
 $root=Join-Path $work 'root';$state=Join-Path $work 'state';$package=Join-Path $work 'package'
 foreach($path in @((Join-Path $root 'backup-runtime'),(Join-Path $root 'tools'),(Join-Path $state 'automatic-backups'),(Join-Path $package 'backup-runtime'))){$null=New-Item -ItemType Directory -Path $path -Force}
 [IO.File]::WriteAllText((Join-Path $package 'Restore-Gates.ps1'),'function Assert-OpenWebUpgradeAllowed {param($StateRoot)}')
 foreach($path in @((Join-Path $root 'backup-runtime/python.exe'),(Join-Path $package 'backup-runtime/python.exe'))){[IO.File]::WriteAllText($path,'fictional identical runtime bytes')}
 foreach($path in @((Join-Path $root 'tools/backups.py'),(Join-Path $package 'backups.py'))){[IO.File]::WriteAllText($path,'fictional identical worker bytes')}
 [IO.File]::WriteAllText((Join-Path $state 'automatic-backups/worker.lock'),'unchanged fixture lock')
 $script:clock=[DateTime]::new(2026,10,24,12,0,0,[DateTimeKind]::Local)
 function Get-Date {return $script:clock}
 function Start-Sleep {param($Milliseconds);Must ($Milliseconds -eq 500) 'sleep adapter preserves original interval';$script:sleeps++}
 function TaskSnapshot {return @{'OpenWebPBX-Backups'=@{exists=$true;enabled=$true;xml='unchanged';acl='unchanged';security='unchanged'}}}
 function Get-ScheduledTask {param($TaskName,$ErrorAction)
  Must ($TaskName -ceq 'OpenWebPBX-Backups' -and $ErrorAction -ceq 'Stop') 'only exact task read'
  $script:taskReads++
  $stateValue=if($script:started -and $script:scenario -ceq 'busy-timeout'){'Running'}else{'Ready'}
  return [pscustomobject]@{TaskName=$TaskName;TaskPath='\';Settings=@{Enabled=$true;MultipleInstances='IgnoreNew'};Principal=@{UserId='SYSTEM';LogonType='ServiceAccount';RunLevel='Highest'};Actions=@(@{Execute=(Join-Path $root 'backup-runtime/python.exe');Arguments=('-I "'+(Join-Path $root 'tools/backups.py')+'" worker');WorkingDirectory=(Join-Path $root 'tools')});State=$stateValue}
 }
 function Get-ScheduledTaskInfo {param($TaskName,$ErrorAction)
  Must ($TaskName -ceq 'OpenWebPBX-Backups' -and $ErrorAction -ceq 'Stop') 'only exact task info read';$script:infoReads++
  $time=if(!$script:started -or $script:scenario -ceq 'stale-timeout'){$script:clock.AddMinutes(-10)}elseif($script:scenario -ceq 'future'){$script:clock.AddSeconds(10)}else{$script:clock.AddSeconds(-5)}
  return [pscustomobject]@{LastRunTime=$time;LastTaskResult=$script:result;Private='PRIVATE process argument and date'}
 }
 function Start-ScheduledTask {param($TaskName,$ErrorAction)
  Must ($TaskName -ceq 'OpenWebPBX-Backups' -and $ErrorAction -ceq 'Stop') 'exact original start invocation';$script:starts++;$script:started=$true
 }
 function RunCase([string]$Scenario,$Result){
  $script:scenario=$Scenario;$script:result=$Result;$script:started=$false;$script:starts=0;$script:sleeps=0;$script:taskReads=0;$script:infoReads=0
  $caught=$null;try{InitializeQualificationBackupWorker -Root $root -StateRoot $state -PackageRoot $package}catch{$caught=$_}
  Must ($script:starts -eq 1) 'one start even on refusal';return $caught
 }
 $originalObserver=${function:ObserveQualificationBackupWorkerFailure}
 # The actual untouched Check executes inside an exception-observation adapter
 # for these identity controls; the thrown ErrorRecord/Exception are retained.
 function Check([bool]$Value,[string]$Message){try{& $script:productionCheck $Value $Message}catch{$script:checkError=$_;throw}}
 foreach($result in @([uint32]1,[uint32]267009,[uint32]267011,[uint32]2147942405,[uint32]4294967295,[int]1,[long]267009,[int]-2147024891,[int]::MinValue)){
  $caughtRecord=RunCase 'nonzero' $result;Must ($null -ne $caughtRecord) 'nonzero refuses'
  Must ([object]::ReferenceEquals($caughtRecord.Exception,$script:checkError.Exception)) 'original Check exception identity retained'
  Must ($caughtRecord.Exception.Message -ceq 'The actual normal backup task did not finish successfully.') 'original Check message retained'
  $row=$caughtRecord.Exception.Data['openweb_qa_backup_worker'];Must ($row.last_task_result -eq [long]$result -and $row.task_state -ceq 'Ready' -and $row.last_run_advanced -and $row.last_run_not_future -and $row.prior_run_not_future) 'exact native number and time flags'
  $roundtrip=$row|ConvertTo-Json -Compress|ConvertFrom-Json -AsHashtable;Must ($roundtrip.last_task_result -eq [long]$result -and $roundtrip.last_task_result -isnot [string]) 'unsigned Scheduler result survives numeric JSON projection exactly'
  Must ($script:taskReads -eq 2 -and $script:infoReads -eq 2 -and $script:sleeps -eq 0) 'observer performs no additional scheduler reads or sleeps'
 }
 $caughtRecord=RunCase 'future' ([uint32]1);Must (!$caughtRecord.Exception.Data['openweb_qa_backup_worker'].last_run_not_future) 'future observation is boolean, not a raw timestamp'
 $trace="at Check, C:\private\windows-updater-qualification.ps1: line 38`nat InitializeQualificationBackupWorker, C:\private\windows-updater-qualification.ps1: line 281"
 $row=$caughtRecord.Exception.Data['openweb_qa_backup_worker'];$safe=QualificationFailureObservation $trace $null $null $null $row
 Must ($safe.backup_worker.last_task_result -eq 1 -and @($safe.backup_worker.Keys).Count -eq 6) 'matching actual callsites project only closed worker fields'
 $json=$safe|ConvertTo-Json -Depth 8 -Compress;Must ($json -cnotmatch 'PRIVATE|2026|C:|process argument|LastRunTime') 'no raw paths dates arguments or messages'
 foreach($wrongTrace in @('',"at Check, C:\private\foreign.ps1: line 38",'at Other, windows-updater-qualification.ps1: line 38',"at Check, windows-updater-qualification.ps1: line 38","at InitializeQualificationBackupWorker, windows-updater-qualification.ps1: line 281")){
  Must (!(QualificationFailureObservation $wrongTrace $null $null $null $row).ContainsKey('backup_worker')) 'unrelated and stale observations omitted'
 }
 $invalid=@($null,@{},($row+@{extra='PRIVATE'}))
 foreach($key in $row.Keys){$copy=@{}+$row;$copy.Remove($key);$invalid+=,$copy}
 foreach($bad in @($true,'1',1.0,[long]4294967296,[long]-2147483649,0,@(1),@{})){$copy=@{}+$row;$copy.last_task_result=$bad;$invalid+=,$copy}
 foreach($bad in @($true,'1',2,@{})){$copy=@{}+$row;$copy.schema=$bad;$invalid+=,$copy}
 foreach($bad in @('ready','Running','PRIVATE',$true,@{})){$copy=@{}+$row;$copy.task_state=$bad;$invalid+=,$copy}
 foreach($key in @('last_run_advanced','last_run_not_future','prior_run_not_future')){foreach($bad in @(1,'true',$null,@{})){$copy=@{}+$row;$copy[$key]=$bad;$invalid+=,$copy}}
 $copy=@{}+$row;$copy.last_run_advanced=$false;$invalid+=,$copy
 foreach($bad in $invalid){Must ($null -eq (QualificationBackupWorkerFailureFields $bad)) 'malformed or overbroad direct proof refuses';Must (!(QualificationFailureObservation $trace $null $null $null $bad).ContainsKey('backup_worker')) 'malformed proof is not published'}
 foreach($first in @($true,$false)){foreach($second in @($true,$false)){
  $copy=@{}+$row;$copy.last_run_not_future=$first;$copy.prior_run_not_future=$second;$retained=QualificationBackupWorkerFailureFields $copy
  Must ($retained.last_run_not_future -eq $first -and $retained.prior_run_not_future -eq $second) 'clock flags are observed independently, not forced to success'
 }}
 foreach($value in @($null,'PRIVATE date',1,@{})){
  Must ($null -eq (ObserveQualificationBackupWorkerFailure @{State='Ready'} @{LastRunTime=$value;LastTaskResult=[uint32]1} @{LastRunTime=$script:clock.AddSeconds(-2)})) 'malformed observed current date cannot be projected'
  Must ($null -eq (ObserveQualificationBackupWorkerFailure @{State='Ready'} @{LastRunTime=$script:clock;LastTaskResult=[uint32]1} @{LastRunTime=$value})) 'malformed observed prior date cannot be projected'
 }
 foreach($scenario in 'stale-timeout','busy-timeout'){
  $caughtRecord=RunCase $scenario ([int]9);Must ($null -ne $caughtRecord -and $caughtRecord.Exception.Message -ceq 'The actual normal backup task did not finish before the baseline deadline.') 'original bounded timeout retained'
  Must (!$caughtRecord.Exception.Data.Contains('openweb_qa_backup_worker') -and $script:sleeps -eq 119) 'other refusal has no stale worker observation or new retry'
 }
 function ObserveQualificationBackupWorkerFailure {throw 'PRIVATE observer failure'}
 $caughtRecord=RunCase 'nonzero' ([int]5);Must ([object]::ReferenceEquals($caughtRecord.Exception,$script:checkError.Exception) -and $caughtRecord.Exception.Message -ceq 'The actual normal backup task did not finish successfully.' -and !$caughtRecord.Exception.Data.Contains('openweb_qa_backup_worker')) 'failed observer cannot replace primary exception or create stale evidence'
 $caughtRecord=RunCase 'success' ([int]0);Must ($null -eq $caughtRecord -and $script:starts -eq 1 -and $script:taskReads -eq 2 -and $script:infoReads -eq 2 -and $script:sleeps -eq 0) 'success executes no observer and unchanged original body'
 Set-Item Function:ObserveQualificationBackupWorkerFailure -Value $originalObserver
 # Restore the actual original Check for a full original refusal and projection.
 Set-Item Function:Check -Value $script:productionCheck
 $caughtRecord=RunCase 'nonzero' ([uint32]267009)
 $actual=QualificationFailureObservation $caughtRecord.ScriptStackTrace $null $null $null $caughtRecord.Exception.Data['openweb_qa_backup_worker']
 Must ($actual.backup_worker.last_task_result -eq 267009) 'actual original stack and Check publish the bounded observation'
 Must ([IO.File]::ReadAllText((Join-Path $state 'automatic-backups/worker.lock')) -ceq 'unchanged fixture lock') 'fixture lock bytes unchanged'
}finally{if(Test-Path -LiteralPath $work){Remove-Item -LiteralPath $work -Recurse -Force}}
Write-Output ('PASS '+$checks+' extracted-function, original-body, privacy and primary-error controls; Scheduler/filesystem boundary adapters remain explicit')
