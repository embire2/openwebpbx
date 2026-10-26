# QA only. The real backup/restore lock and calls remain unchanged.
. (Join-Path $PSScriptRoot 'windows-health-updater-quiescence.ps1')
function Assert-BackupUpdaterQualificationContext {
 if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or $env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:GITHUB_REPOSITORY -cne 'embire2/openwebpbx' -or $root -cne 'C:\OpenWebPBX' -or [IO.Path]::GetFullPath($state) -ine [IO.Path]::GetFullPath((Join-Path $env:ProgramData 'OpenWebPBX'))){throw 'Only the owned disposable backup factory may isolate its updater.'}
}
function Read-BackupUpdaterBoundedJson([string]$Path,[long]$Limit) {
 $item=Assert-HealthUpdaterOrdinary $Path $false
 if($item.Length -le 0 -or $item.Length -gt $Limit){throw 'The backup isolation evidence exceeded its bound.'}
 return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json)
}
function Get-BackupUpdaterRestoreState {
 $directory=Join-Path $state 'backup-restore';$journal=Join-Path $directory 'journal.json';$holds=@{}
 if(Test-Path -LiteralPath $directory -ErrorAction Stop){$null=Assert-HealthUpdaterOrdinary $directory $true}
 foreach($selection in 'calls','jobs','updates','backups'){
  $path=Join-Path $directory ('hold-'+$selection)
  if(Test-Path -LiteralPath $path -ErrorAction Stop){
   $value=Read-BackupUpdaterBoundedJson $path 1024
   if(@($value.PSObject.Properties.Name).Count -ne 2 -or ($value.schema -isnot [int] -and $value.schema -isnot [long]) -or $value.schema -ne 1 -or $value.selection -isnot [string] -or $value.selection -cne $selection){throw 'A restore activation hold is not the exact product record.'}
   if((Get-Content -LiteralPath $path -Raw -Encoding UTF8) -cne ('{"schema": 1, "selection": "'+$selection+'"}')){throw 'The hold is not the exact product serialization.'}
   $holds[$selection]=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
  }
 }
 if(!(Test-Path -LiteralPath $journal -ErrorAction Stop)){
  if($holds.Count){throw 'Restore holds have no owning journal.'}
  return @{State='absent';Holds=$holds;JournalHash='';CreatedTicks=0L;Gates=$null}
 }
 $item=Assert-HealthUpdaterOrdinary $journal $false;$value=Read-BackupUpdaterBoundedJson $journal 67108864
 if(($value.schema -isnot [int] -and $value.schema -isnot [long]) -or $value.schema -ne 1 -or $value.state -isnot [string] -or $value.state -cnotin 'prepared','restoring','recovery_required','recovering','recovered','restored' -or $value.database -cne 'fusionpbx' -or $value.user -cne 'fusionpbx' -or $value.source_host -cne 'windowsqa.example.invalid' -or ($value.factory_security_version -isnot [int] -and $value.factory_security_version -isnot [long]) -or $value.factory_security_version -ne 1 -or ($value.gates.schema -isnot [int] -and $value.gates.schema -isnot [long]) -or $value.gates.schema -ne 1 -or ($value.call_records_hold.schema -isnot [int] -and $value.call_records_hold.schema -isnot [long]) -or $value.call_records_hold.schema -ne 1 -or $value.call_records_hold.owner -cne 'restore' -or $value.call_records_hold.transaction -isnot [string] -or $value.call_records_hold.transaction -cnotmatch '^[a-f0-9]{32}$'){throw 'The restore journal is not the owned current factory operation.'}
 return @{State=$value.state;Holds=$holds;JournalHash=(Get-FileHash -LiteralPath $journal -Algorithm SHA256).Hash;CreatedTicks=[long]$item.CreationTimeUtc.Ticks;Gates=$value.gates}
}
function New-BackupUpdaterQualificationReceipt([string]$InputPath) {
 Assert-BackupUpdaterQualificationContext
 $item=Assert-HealthUpdaterOrdinary $InputPath $false
 $private=Join-Path $state 'backup-qualification'
 if($item.DirectoryName -ine [IO.Path]::GetFullPath($private) -or $item.Name -cnotmatch '^[a-f0-9]{32}\.json$'){throw 'A fresh owned backup input is required.'}
 if((Get-BackupUpdaterRestoreState).State -cne 'absent'){throw 'A prior restore is not an empty qualification baseline.'}
 return @{Schema=1;InputPath=$item.FullName;InputCreatedTicks=[long]$item.CreationTimeUtc.Ticks;StartedTicks=[long]$item.CreationTimeUtc.Ticks;Version=(Get-Content -LiteralPath (Join-Path $PackageRoot 'VERSION') -Raw).Trim()}
}
function Assert-BackupUpdaterReceipt($Receipt) {
 Assert-BackupUpdaterQualificationContext
 if($Receipt -isnot [Collections.IDictionary] -or $Receipt.Count -ne 5 -or $Receipt.Schema -isnot [int] -or $Receipt.Schema -ne 1 -or $Receipt.InputPath -isnot [string] -or $Receipt.InputCreatedTicks -isnot [long] -or $Receipt.StartedTicks -isnot [long] -or $Receipt.InputCreatedTicks -le 0 -or $Receipt.StartedTicks -ne $Receipt.InputCreatedTicks -or $Receipt.StartedTicks -gt [DateTime]::UtcNow.Ticks -or $Receipt.Version -isnot [string] -or $Receipt.Version -cnotmatch '^\d+\.\d+\.\d+$' -or $Receipt.Version -cne (Get-Content -LiteralPath (Join-Path $PackageRoot 'VERSION') -Raw).Trim()){throw 'The backup isolation receipt changed.'}
 $item=Assert-HealthUpdaterOrdinary $Receipt.InputPath $false
 if($item.DirectoryName -ine [IO.Path]::GetFullPath((Join-Path $state 'backup-qualification')) -or $item.Name -cnotmatch '^[a-f0-9]{32}\.json$' -or [long]$item.CreationTimeUtc.Ticks -ne $Receipt.InputCreatedTicks){throw 'The owned backup input was replaced.'}
}
function Assert-BackupUpdaterTaskDefinition($Original) {
 $task=Get-ScheduledTask -TaskName 'OpenWebPBX-Updater-Restart' -TaskPath '\' -ErrorAction Stop;Assert-HealthUpdaterRestartTask $task
 $currentXml=Export-ScheduledTask -TaskName 'OpenWebPBX-Updater-Restart' -TaskPath '\'
 $oldXml=[xml]$Original.TaskXml;$pausedXml=[xml]$currentXml
 $oldEnabled=@($oldXml.SelectNodes('/*[local-name()="Task"]/*[local-name()="Settings"]/*[local-name()="Enabled"]'))
 $pausedEnabled=@($pausedXml.SelectNodes('/*[local-name()="Task"]/*[local-name()="Settings"]/*[local-name()="Enabled"]'))
 if($oldEnabled.Count -ne 1 -or $pausedEnabled.Count -ne 1 -or $oldEnabled[0].InnerText -cne ([string]$Original.TaskEnabled).ToLowerInvariant() -or $pausedEnabled[0].InnerText -cnotin 'true','false'){throw 'The original restart task definition is unavailable.'}
 if(!$Original.TaskEnabled -and $pausedEnabled[0].InnerText -cne 'false'){throw 'The originally disabled restart task was re-enabled by another operation.'}
 $oldLiteral='<Enabled>'+$oldEnabled[0].InnerText+'</Enabled>';$pausedLiteral='<Enabled>'+$pausedEnabled[0].InnerText+'</Enabled>'
 if([regex]::Matches($Original.TaskXml,[regex]::Escape($oldLiteral)).Count -ne 1 -or [regex]::Matches($currentXml,[regex]::Escape($pausedLiteral)).Count -ne 1 -or $currentXml.Replace($pausedLiteral,$oldLiteral) -cne $Original.TaskXml){throw 'The restart task changed beyond the owned enabled choice.'}
}
function Complete-BackupQualificationUpdater($Original,$Receipt) {
 if($null -eq $Original){return} # The exact Suspend helper refused before mutation.
 Assert-BackupUpdaterReceipt $Receipt
 if($Original -isnot [Collections.IDictionary] -or $Original.Count -ne 7 -or $Original.Running -isnot [bool] -or $Original.TaskEnabled -isnot [bool] -or $Original.TaskXml -isnot [string] -or !$Original.TaskXml -or $Original.TaskXml.Length -gt 1048576){throw 'The original updater choice is not available.'}
 $restore=Get-BackupUpdaterRestoreState
 if($restore.State -cne 'absent' -and $restore.CreatedTicks -lt $Receipt.StartedTicks){throw 'A stale restore cannot own updater isolation.'}
 if($restore.Holds.Count -eq 0){
  if($restore.State -cnotin 'absent','recovered'){throw 'An unfinished restore does not permit updater resumption.'}
  $now=Get-HealthUpdaterQualificationState;Assert-HealthUpdaterOriginal $Original $now
  if($now.Running -and !$Original.Running){throw 'The original stopped updater was started by another operation.'}
  Assert-BackupUpdaterTaskDefinition $Original
  Resume-HealthQualificationUpdater $Original
  return
 }
 # A product-created restore hold supersedes the temporary QA running choice.
 # Never start a service or rewrite its startup mode through this branch.
 if(!$restore.Holds.ContainsKey('updates') -or $restore.State -cnotin 'prepared','restoring','recovery_required','recovering','restored' -or $restore.Gates.services.OpenWebPBXUpdater -cne $Original.StartMode -or @($restore.Gates.running) -ccontains 'OpenWebPBXUpdater'){throw 'The updater hold is not bound to the paused factory choice.'}
 $now=Get-HealthUpdaterQualificationState
 foreach($name in 'Executable','StartName','MetadataHash'){if($now[$name] -cne $Original[$name]){throw 'The held updater identity changed.'}}
 if($now.StartMode -cne 'Disabled' -or $now.Running -or $now.TaskEnabled){throw 'The restored updater is not safely held and quiescent.'}
 # Check the full original task XML before touching even its enabled choice.
 # Enabled=false is the sole change made by the exact Suspend helper.
 Assert-BackupUpdaterTaskDefinition $Original
 if($Original.TaskEnabled){Enable-ScheduledTask -TaskName 'OpenWebPBX-Updater-Restart' -TaskPath '\' -ErrorAction Stop|Out-Null}else{Disable-ScheduledTask -TaskName 'OpenWebPBX-Updater-Restart' -TaskPath '\' -ErrorAction Stop|Out-Null}
 if((Export-ScheduledTask -TaskName 'OpenWebPBX-Updater-Restart' -TaskPath '\') -cne $Original.TaskXml){throw 'The restart task definition did not recover exactly.'}
 $after=Get-HealthUpdaterQualificationState
 foreach($name in 'Executable','StartName','MetadataHash'){if($after[$name] -cne $Original[$name]){throw 'The held updater identity changed during completion.'}}
 if($after.StartMode -cne 'Disabled' -or $after.Running -or $after.TaskEnabled -ne $Original.TaskEnabled){throw 'The restore hold was not preserved.'}
 $final=Get-BackupUpdaterRestoreState
 if($final.State -cne $restore.State -or $final.JournalHash -cne $restore.JournalHash -or $final.Holds.Count -ne $restore.Holds.Count){throw 'The owning restore changed during completion.'}
 foreach($name in $restore.Holds.Keys){if(!$final.Holds.ContainsKey($name) -or $final.Holds[$name] -cne $restore.Holds[$name]){throw 'The owning activation hold changed during completion.'}}
}
