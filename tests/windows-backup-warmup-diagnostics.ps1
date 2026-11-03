# QA metadata only. Never include messages, paths, principals, XML or arguments.
function BackupWarmupStages {
 return @{
  'Backup warm-up refuses an active maintenance marker.'='maintenance_marker'
  'Backup warm-up refuses linked state storage.'='state_storage'
  'Backup warm-up requires the exact ordinary installed runtime.'='runtime_path'
  'Backup warm-up refuses a changed installed runtime.'='runtime_hash'
  'Backup warm-up refuses an unexpected normal SYSTEM task.'='task_identity'
  'The normal backup task definition is unavailable.'='task_definition'
  'The normal backup task did not become idle before the baseline.'='initial_idle_deadline'
  'The normal backup task execution time is unavailable.'='task_time'
  'The normal backup task execution clock did not advance before the baseline.'='clock_deadline'
  'The normal backup task did not become ready before the baseline deadline.'='ready_deadline'
  'The actual normal backup task did not finish successfully.'='worker_result'
  'The actual normal backup task did not finish before the baseline deadline.'='completion_deadline'
  'The actual backup worker did not initialize its ordinary runtime lock.'='worker_lock'
  'Backup warm-up changed the normal task definition or security.'='task_preservation'
 }
}
function BackupWarmupFailureFields($Record){
 if($Record -is [Collections.IDictionary]){$keys=@($Record.Keys)}elseif($Record -is [pscustomobject]){$keys=@($Record.PSObject.Properties.Name)}else{return $null}
 if($keys.Count -ne 4){return $null}
 foreach($key in $keys){if($key -isnot [string] -or $key -cnotin 'schema','stage','runtime_component','mismatches'){return $null}}
 if(($Record.schema -isnot [int] -and $Record.schema -isnot [long]) -or $Record.schema -ne 1){return $null}
 if($Record.stage -isnot [string] -or $Record.stage -cnotin (@('unknown')+@((BackupWarmupStages).Values))){return $null}
 if($Record.runtime_component -isnot [string] -or $Record.runtime_component -cnotin 'unknown','python','worker'){return $null}
 if($Record.stage -cnotin 'runtime_path','runtime_hash' -and $Record.runtime_component -cne 'unknown'){return $null}
 $allowed=switch -CaseSensitive ($Record.stage){
  'task_identity'{@('name','path','enabled','multiple','principal','logon','runlevel','action_count','execute','arguments','workdir','state')}
  'task_preservation'{@('exists','enabled','xml','acl','security')}
  'worker_lock'{@('directory','directory_reparse','lock_file','lock_reparse')}
  'runtime_path'{@('file','reparse')}
  default{@()}
 }
 if($Record.mismatches -isnot [Array] -or $Record.mismatches.Count -gt $allowed.Count){return $null}
 $seen=@{};foreach($field in $Record.mismatches){if($field -isnot [string] -or $field -cnotin $allowed -or $seen.ContainsKey($field)){return $null};$seen[$field]=$true}
 return @{schema=1;stage=$Record.stage;runtime_component=$Record.runtime_component;mismatches=@($Record.mismatches)}
}
function ObserveBackupWarmupFailure($Failure,$Task,$Python,$Arguments,$Root,$Pair,$Item,$Directory,$Worker,$Before,$After){
 $stages=BackupWarmupStages;$message=$Failure.Exception.Message
 $stage=if($stages.ContainsKey($message)){$stages[$message]}else{'unknown'}
 $component='unknown';$mismatches=@()
 if($stage -cin 'runtime_path','runtime_hash'){
  if($Pair -is [Array] -and $Pair.Count -eq 2){if($Pair[0] -ceq $Python){$component='python'}elseif($Pair[0] -ceq (Join-Path $Root 'tools/backups.py')){$component='worker'}}
 }
 if($stage -ceq 'task_identity'){
  $action=if(@($Task.Actions).Count){$Task.Actions[0]}else{$null}
  $matches=[ordered]@{
   name=($Task.TaskName -eq 'OpenWebPBX-Backups');path=($Task.TaskPath -eq '\');enabled=[bool]$Task.Settings.Enabled
   multiple=([string]$Task.Settings.MultipleInstances -eq 'IgnoreNew');principal=([string]$Task.Principal.UserId -in 'SYSTEM','S-1-5-18','NT AUTHORITY\SYSTEM')
   logon=([string]$Task.Principal.LogonType -eq 'ServiceAccount');runlevel=([string]$Task.Principal.RunLevel -eq 'Highest');action_count=(@($Task.Actions).Count -eq 1)
   execute=($action.Execute -eq $Python);arguments=($action.Arguments -eq $Arguments);workdir=($action.WorkingDirectory -eq (Join-Path $Root 'tools'));state=([string]$Task.State -in 'Ready','Running','Queued')
  }
  $mismatches=@(foreach($field in $matches.Keys){if(!$matches[$field]){$field}})
 }elseif($stage -ceq 'task_preservation'){$mismatches=@(foreach($field in 'exists','enabled','xml','acl','security'){if($After[$field] -cne $Before[$field]){$field}})}
 elseif($stage -ceq 'worker_lock'){
  if(!$Directory.PSIsContainer){$mismatches+=,'directory'};if($Directory.Attributes -band [IO.FileAttributes]::ReparsePoint){$mismatches+=,'directory_reparse'}
  if($Worker.PSIsContainer){$mismatches+=,'lock_file'};if($Worker.Attributes -band [IO.FileAttributes]::ReparsePoint){$mismatches+=,'lock_reparse'}
 }elseif($stage -ceq 'runtime_path'){if($Item.PSIsContainer){$mismatches+=,'file'};if($Item.Attributes -band [IO.FileAttributes]::ReparsePoint){$mismatches+=,'reparse'}}
 return BackupWarmupFailureFields @{schema=1;stage=$stage;runtime_component=$component;mismatches=$mismatches}
}
function BackupWarmupWorkerFields($Record){
 if($Record -is [Collections.IDictionary]){$keys=@($Record.Keys)}elseif($Record -is [pscustomobject]){$keys=@($Record.PSObject.Properties.Name)}else{return $null}
 if($keys.Count -ne 6){return $null}
 foreach($key in $keys){if($key -isnot [string] -or $key -cnotin 'schema','last_task_result','task_state','last_run_advanced','last_run_not_future','prior_run_not_future'){return $null}}
 if(($Record.schema -isnot [int] -and $Record.schema -isnot [long]) -or $Record.schema -ne 1){return $null}
 $result=$Record.last_task_result
 if(($result -isnot [int] -and $result -isnot [uint32] -and $result -isnot [long]) -or $result -eq 0 -or $result -lt [int]::MinValue -or $result -gt [uint32]::MaxValue){return $null}
 if($Record.task_state -isnot [string] -or $Record.task_state -cne 'Ready'){return $null}
 foreach($flag in 'last_run_advanced','last_run_not_future','prior_run_not_future'){if($Record.$flag -isnot [bool]){return $null}}
 if(!$Record.last_run_advanced){return $null}
 return @{schema=1;last_task_result=[long]$result;task_state='Ready';last_run_advanced=$true;last_run_not_future=$Record.last_run_not_future;prior_run_not_future=$Record.prior_run_not_future}
}
