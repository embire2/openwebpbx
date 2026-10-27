#Requires -RunAsAdministrator
[CmdletBinding()]
param([string]$RestoreBackup = '', [switch]$Check, [string]$Archive, [string]$FeedEnvelope, [string]$TargetVersion, [switch]$Recover, [switch]$Automatic)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if($PSVersionTable.PSEdition -eq 'Core'){throw 'Run server upgrades in Windows PowerShell (powershell.exe) as administrator. It provides native IIS management.'}
$env:PSModulePath=$PSHOME+'\Modules;'+[Environment]::GetFolderPath('ProgramFiles')+'\WindowsPowerShell\Modules'
$root = 'C:\OpenWebPBX'
$private = Join-Path $env:ProgramData 'OpenWebPBX'
$config = Join-Path $env:ProgramData 'fusionpbx'
$switch = 'C:\Program Files\FreeSWITCH'
$payload = $PSScriptRoot
$script:recoveryCodeRoot=$PSScriptRoot
$gateHelper=Join-Path $PSScriptRoot 'Restore-Gates.ps1'
if(!(Test-Path $gateHelper)){$gateHelper=Join-Path $root 'tools\Restore-Gates.ps1'}
if(Test-Path $gateHelper){. $gateHelper}else{throw 'The Windows restore safeguards are missing.'}
. (Join-Path (Split-Path $gateHelper -Parent) 'Support-Recovery.ps1')
. (Join-Path (Split-Path $gateHelper -Parent) 'Web-Readiness.ps1')
. (Join-Path (Split-Path $gateHelper -Parent) 'UpgradeRecovery.Common.ps1')
. (Join-Path (Split-Path $gateHelper -Parent) 'CallRecords.Common.ps1')
$script:callRecordsHold=$null
$script:upgradeRecoveryEntry=$null;$script:upgradeCommitted=$false;$script:upgradeFinalizationPhase=$null;$script:upgradeFinalizationFailed=$false;$script:operatorUpdaterWasRunning=$false;$script:operatorUpdaterStopped=$false
$updates = Join-Path $private 'updates'
$journalPath = Join-Path $updates 'install-journal.json'
$extracted = $null;$phpRuntime=$null
$exitCode=0;$script:deferred=$false;$script:enginePaused=$false;$restoreStarted=$false;$recoveryRestoreStarted=$false;$script:operatorRollback=$false
if(-not ('OpenWebUpdateState' -as [type])){Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class OpenWebUpdateState {
 [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
 public static extern bool MoveFileEx(string oldName,string newName,int flags);
}
'@}
function WriteState([string]$Path,$Value) {
 $temp=$Path+'.'+[Guid]::NewGuid().ToString('N')+'.new'
 $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes(($Value|ConvertTo-Json -Depth 8))
 try{
  $file=[IO.File]::Open($temp,'CreateNew','Write','None')
  try{$file.Write($bytes,0,$bytes.Length);$file.Flush($true)}finally{$file.Dispose()}
  if(![OpenWebUpdateState]::MoveFileEx($temp,$Path,9)){throw 'Durable update state could not be committed.'}
 }finally{Remove-Item $temp -Force -ErrorAction SilentlyContinue}
}
function SaveJournal([string]$Phase) {
 $record=@{schema=1;state=$Phase;version=$version;previous_version=$previousVersion;backup_path=$backup;updated_at=[DateTime]::UtcNow.ToString('o');manager_tasks=@($script:managerTasks);operator_rollback=[bool]$script:operatorRollback}
 if($script:upgradeRecoveryEntry){$record.recovery_entry=$script:upgradeRecoveryEntry}
 if($script:callRecordsHold){$record.call_records_hold=$script:callRecordsHold}
 if($script:upgradeFinalizationPhase){$record.finalization=@{phase=$script:upgradeFinalizationPhase;failed=[bool]$script:upgradeFinalizationFailed}}
 WriteState $journalPath $record
 if($Phase -ceq 'rolled_back' -and $script:callRecordsHold){Remove-OpenWebCallRecordHold -StateRoot $private -Hold $script:callRecordsHold -MaintenanceLock $lock}
}
function WaitPool([string]$Wanted) {
 for($i=0;$i -lt 160;$i++){if((Get-WebAppPoolState OpenWebPBX).Value -eq $Wanted){return};Start-Sleep -Milliseconds 250}
 throw 'The PBX web application pool did not reach its required state.'
}
function ResumeManagers {
 foreach($task in $script:managerTasks){try{Start-ScheduledTask -TaskName $task -ErrorAction Stop}catch{Write-Warning 'A previously open manager can be reopened from its normal shortcut.'}}
}
function CompleteCommittedFinalization {
 $script:upgradeFinalizationPhase='service_selection'
 Complete-OpenWebCommittedUpgrade -Entry $script:upgradeRecoveryEntry -Root $root -StateRoot $private -EngineRoot $switch -MaintenanceLock $lock
 $script:upgradeFinalizationPhase='background_tasks'
 $originalSupport=Get-Content "$backup\support-state.json" -Raw|ConvertFrom-Json
 foreach($name in 'OpenWebPBX-Backups','OpenWebPBX Outgoing Mail','OpenWebPBX-TenantDomains','OpenWebPBX-PhoneHealth'){
  $originalTask=$originalSupport.Tasks.PSObject.Properties[$name]
  if($originalTask -and ($originalTask.Value.Exists -isnot [bool] -or $originalTask.Value.Enabled -isnot [bool])){throw 'The original background-task enabled choice is invalid.'}
  if(!$originalTask -or !$originalTask.Value.Exists -or $originalTask.Value.Enabled){Enable-ScheduledTask -TaskName $name|Out-Null}
  else{Disable-ScheduledTask -TaskName $name|Out-Null}
  if($name -eq 'OpenWebPBX-PhoneHealth' -and (!$originalTask -or !$originalTask.Value.Exists -or $originalTask.Value.Enabled)){Start-ScheduledTask -TaskName $name}
 }
 if(Get-ScheduledTask -TaskName OpenWebPBX-Cleanup -ErrorAction SilentlyContinue){
  $support=Get-Content "$backup\support-state.json" -Raw|ConvertFrom-Json
  if($support.Tasks.'OpenWebPBX-Cleanup'.Enabled){Enable-ScheduledTask -TaskName OpenWebPBX-Cleanup|Out-Null}
 }
 $script:upgradeFinalizationPhase='manager_resume'
 ResumeManagers
 if($script:callRecordsHold){Remove-OpenWebCallRecordHold -StateRoot $private -Hold $script:callRecordsHold -MaintenanceLock $lock}
 $script:upgradeFinalizationPhase='complete';$script:upgradeFinalizationFailed=$false
 SaveJournal 'completed'
}
function Get-OpenWeb20GreetingCompatibilityPath {
 param([string]$Backup)
 $identity=[IO.Path]::GetFullPath($Backup).TrimEnd('\').ToUpperInvariant()+"`n"+(Get-OpenWebRecoveryHash (Read-OpenWebRecoveryBytes (Join-Path $Backup 'backup-manifest.json')))
 Join-Path $updates ('greetings-upgrade20-'+(Get-OpenWebRecoveryHash ([Text.Encoding]::UTF8.GetBytes($identity)))+'.json')
}
function Read-OpenWeb20GreetingCompatibility {
 param([string]$Backup)
 $path=Get-OpenWeb20GreetingCompatibilityPath $Backup
 if(!(Test-Path -LiteralPath $path)){return $null}
 $null=Assert-OpenWebRecoveryProtected $path -Private
 $record=[Text.Encoding]::UTF8.GetString((Read-OpenWebRecoveryBytes $path 16777216))|ConvertFrom-Json
 $fields=@('schema','State','Backup','BackupManifestSha256','BackupCompleteSha256','SourceManifestSha256','Version','PreviousVersion','GreetingAccess','OriginalRootExists','EngineDirectoryExists','EngineDirectorySddl','EngineFiles','Hold')
 if(@($record.PSObject.Properties).Count -ne $fields.Count -or @($record.PSObject.Properties.Name|Where-Object {$_ -cnotin $fields}).Count -or ($record.schema -isnot [int] -and $record.schema -isnot [long]) -or $record.schema -ne 1 -or $record.State -cnotin 'prepared','completed','rolled_back' -or $record.Backup -isnot [string] -or $record.Backup -ine $Backup -or $record.PreviousVersion -cne '1.0.20' -or $record.Version -isnot [string] -or $record.Version -cnotmatch '^\d+\.\d+\.\d+$' -or [version]$record.Version -lt [version]'1.0.21' -or $record.OriginalRootExists -isnot [bool] -or $record.EngineDirectoryExists -isnot [bool]){throw 'The original20 Greetings compatibility inventory is invalid.'}
 foreach($field in 'BackupManifestSha256','BackupCompleteSha256','SourceManifestSha256'){if($record.$field -isnot [string] -or $record.$field -cnotmatch '^[a-f0-9]{64}$'){throw 'A compatibility identity pin is invalid.'}}
 if($record.BackupManifestSha256 -cne (Get-OpenWebRecoveryHash (Read-OpenWebRecoveryBytes (Join-Path $Backup 'backup-manifest.json'))) -or $record.BackupCompleteSha256 -cne (Get-OpenWebRecoveryHash (Read-OpenWebRecoveryBytes (Join-Path $Backup 'complete.json')))){throw 'The original20 compatibility backup changed.'}
 Assert-OpenWebCallRecordHold $record.Hold
 if($record.Hold.owner -cne 'upgrade' -or @($record.Hold.PSObject.Properties).Count -ne 3){throw 'The compatibility hold is not upgrade-owned.'}
 if($record.EngineDirectoryExists){Assert-OpenWebGreetingDescriptor $record.EngineDirectorySddl}elseif($null -ne $record.EngineDirectorySddl){throw 'An absent script directory has an unexpected descriptor.'}
 if($record.EngineFiles -isnot [array] -or $record.EngineFiles.Count -ne 2 -or @($record.EngineFiles.Name|Sort-Object -Unique).Count -ne 2){throw 'Both fixed Greetings helper snapshots are required.'}
 foreach($file in $record.EngineFiles){
  if(@($file.PSObject.Properties).Count -ne 6 -or @($file.PSObject.Properties.Name|Where-Object {$_ -cnotin 'Name','Exists','OldSha256','NewSha256','Bytes','Sddl'}).Count -or $file.Name -cnotin 'call.lua','recording.lua' -or $file.Exists -isnot [bool] -or $file.NewSha256 -isnot [string] -or $file.NewSha256 -cnotmatch '^[a-f0-9]{64}$'){throw 'The fixed Greetings helper snapshot is invalid.'}
  if($file.Exists){
   if($file.Bytes -isnot [string] -or $file.Bytes.Length -gt 1398104 -or $file.OldSha256 -isnot [string] -or $file.OldSha256 -cnotmatch '^[a-f0-9]{64}$'){throw 'The original Greetings helper bytes are invalid.'}
   $bytes=[Convert]::FromBase64String($file.Bytes)
   if($bytes.Length -gt 1048576 -or [Convert]::ToBase64String($bytes) -cne $file.Bytes -or (Get-OpenWebRecoveryHash $bytes) -cne $file.OldSha256){throw 'The original Greetings helper bytes changed.'}
   Assert-OpenWebGreetingDescriptor $file.Sddl
  }elseif($null -ne $file.Bytes -or $null -ne $file.OldSha256 -or $null -ne $file.Sddl){throw 'An absent Greetings helper has an unexpected before-image.'}
 }
 return $record
}
function Write-OpenWeb20GreetingCompatibility {
 param($Record)
 $path=Get-OpenWeb20GreetingCompatibilityPath $Record.Backup
 $raw=[Text.UTF8Encoding]::new($false).GetBytes(($Record|ConvertTo-Json -Depth 8 -WarningAction Stop))
 if($raw.Length -gt 16777216){throw 'The bounded compatibility snapshot is too large.'}
 # Use the existing protected recovery writer before atomic publication. A
 # generic state file inherits the parent ACL and is not a private snapshot.
 $temporary=$path+'.'+[Guid]::NewGuid().ToString('N')+'.new';$failure=$null
 try{
  Write-OpenWebRecoveryFile -Path $temporary -Bytes $raw
  Initialize-OpenWebUpgradeRecoveryNative
  [OpenWebPbx.UpgradeRecoveryNativeV1]::Commit($temporary,$path)
 }catch{$failure=$_;throw}finally{
  if(Test-Path -LiteralPath $temporary){try{Remove-Item -LiteralPath $temporary -Force -ErrorAction Stop}catch{if($failure){$failure.Exception.Data['greeting_compatibility_temporary_cleanup_failed']=$true}else{throw}}}
 }
 $null=Assert-OpenWebRecoveryProtected $path -Private
}
function Set-OpenWeb20GreetingHelper {
 param([string]$Path,[byte[]]$Bytes,[string]$Sddl)
 $parent=Assert-OpenWebCallRecordOrdinary -Path (Split-Path $Path -Parent) -Directory
 if(Test-Path -LiteralPath $Path){$null=Assert-OpenWebCallRecordOrdinary -Path $Path}
 $temporary=Join-Path $parent ((Split-Path $Path -Leaf)+'.'+[Guid]::NewGuid().ToString('N')+'.new')
 $failure=$null
 try{
  $file=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  try{$file.Write($Bytes,0,$Bytes.Length);$file.Flush($true)}finally{$file.Dispose()}
  if($Sddl){Set-OpenWebFileSddl -LiteralPath $temporary -Sddl $Sddl}
  if(![OpenWebUpdateState]::MoveFileEx($temporary,$Path,9)){throw 'The Greetings helper could not be committed durably.'}
 }catch{$failure=$_;throw}finally{
  if(Test-Path -LiteralPath $temporary){try{Remove-Item -LiteralPath $temporary -Force -ErrorAction Stop}catch{if($failure){$failure.Exception.Data['greeting_helper_temporary_cleanup_failed']=$true}else{throw}}}
 }
}
function Restore-OpenWeb20GreetingCompatibility {
 param([string]$Backup,[switch]$OperatorRollback)
 Assert-OpenWebRecoveryLock -MaintenanceLock $lock -StateRoot $private
 $record=Read-OpenWeb20GreetingCompatibility $Backup
 if(!$record -or $record.State -ceq 'rolled_back'){return}
 # Original20 has no dedicated-root ACL snapshot. Its sealed backup remains
 # immutable; this separately durable before-image owns only this new grant.
 $greetingRoot=Join-Path $private 'storage\greetings'
 if(!(Test-Path -LiteralPath $greetingRoot)){$null=Get-OpenWebGreetingAccessSnapshot -StateRoot $private -MaintenanceLock $lock}
 $null=Assert-OpenWebGreetingAccessSnapshot -Snapshot $record.GreetingAccess -StateRoot $private
 $directory=Join-Path $switch 'scripts\app\pbx_greetings'
 if(!$OperatorRollback -and (Test-Path -LiteralPath $directory)){
  $null=Assert-OpenWebCallRecordOrdinary -Path $directory -Directory
  # Validate both current files before restoring either one. Atomic publication
  # permits only the captured old hash or the verified new hash after a crash.
  foreach($entry in $record.EngineFiles){$path=Join-Path $directory $entry.Name;if(Test-Path -LiteralPath $path){$null=Assert-OpenWebCallRecordOrdinary -Path $path;$hash=Get-OpenWebRecoveryHash (Read-OpenWebRecoveryBytes $path 1048576);if($hash -cne $entry.NewSha256 -and (!$entry.Exists -or $hash -cne $entry.OldSha256)){throw 'A foreign Greetings helper change prevents compatibility recovery.'}}elseif($entry.Exists){throw 'An original Greetings helper disappeared.'}}
  foreach($entry in $record.EngineFiles){$path=Join-Path $directory $entry.Name;if($entry.Exists){Set-OpenWeb20GreetingHelper -Path $path -Bytes ([Convert]::FromBase64String($entry.Bytes)) -Sddl $entry.Sddl}elseif(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force -ErrorAction Stop}}
 }
 if(Test-Path -LiteralPath $directory){
  $null=Assert-OpenWebCallRecordOrdinary -Path $directory -Directory
  if($record.EngineDirectoryExists){Set-OpenWebFileSddl -LiteralPath $directory -Sddl $record.EngineDirectorySddl}
  elseif(!$OperatorRollback -and @(Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop).Count -eq 0){[IO.Directory]::Delete($directory,$false)}
 }
 Restore-OpenWebGreetingAccess -Snapshot $record.GreetingAccess -StateRoot $private -MaintenanceLock $lock
 if(!$record.OriginalRootExists -and (Test-Path -LiteralPath $greetingRoot) -and @(Get-ChildItem -LiteralPath $greetingRoot -Force -ErrorAction Stop).Count -eq 0){$null=Assert-OpenWebCallRecordOrdinary -Path $greetingRoot -Directory;[IO.Directory]::Delete($greetingRoot,$false)}
 if($OperatorRollback){$record.State='rolled_back';Write-OpenWeb20GreetingCompatibility $record}
}
function Complete-OpenWeb20GreetingCompatibility {
 param($Journal)
 if($Journal.state -cne 'completed' -or $Journal.previous_version -cne '1.0.20' -or $Journal.version -isnot [string] -or $Journal.version -cnotmatch '^\d+\.\d+\.\d+$' -or [version]$Journal.version -lt [version]'1.0.21'){return}
 Assert-OpenWebRecoveryLock -MaintenanceLock $lock -StateRoot $private
 $metadata=Get-OpenWebUpgradeRecoveryMetadata -Entry $Journal.recovery_entry -Root $root -StateRoot $private -EngineRoot $switch -AllowCompleted
 if($state.Version -cne $metadata.version -or $Journal.version -cne $metadata.version -or $metadata.previous_version -cne '1.0.20' -or (Get-Content -LiteralPath (Join-Path $root 'web\VERSION') -Raw -Encoding UTF8).Trim() -cne $metadata.version){throw 'The original20 deployment has not committed its verified target version.'}
 $backupManifest=[Text.Encoding]::UTF8.GetString((Read-OpenWebRecoveryBytes (Join-Path $metadata.backup_path 'backup-manifest.json')))|ConvertFrom-Json
 $supportBytes=Read-OpenWebRecoveryBytes (Join-Path $metadata.backup_path 'support-state.json')
 if($backupManifest.files.'support-state.json' -cne (Get-OpenWebRecoveryHash $supportBytes)){throw 'The original20 support snapshot differs from its sealed backup.'}
 $originalSupport=[Text.Encoding]::UTF8.GetString($supportBytes)|ConvertFrom-Json
 if($originalSupport.PSObject.Properties.Name -ccontains 'GreetingAccess'){return} # Current21 transactions already own the ordinary path.
 $manifest=[Text.Encoding]::UTF8.GetString((Read-OpenWebRecoveryBytes (Join-Path $Journal.recovery_entry.bundle_path 'release-manifest.json') 4194304))|ConvertFrom-Json
 if($manifest.version -cne $metadata.version){throw 'The compatibility release manifest differs from its pinned entry.'}
 $sourceDirectory=Join-Path $root 'web\app\pbx_setup\resources\switch\scripts\app\pbx_greetings'
 $directory=Join-Path $switch 'scripts\app\pbx_greetings';$sources=@{}
 foreach($name in 'call.lua','recording.lua'){
  $path=Join-Path $sourceDirectory $name;$null=Assert-OpenWebCallRecordOrdinary -Path $path;$bytes=Read-OpenWebRecoveryBytes $path 1048576
  $pin=$manifest.files.('web/app/pbx_setup/resources/switch/scripts/app/pbx_greetings/'+$name)
  if($pin -isnot [string] -or $pin -cnotmatch '^[a-f0-9]{64}$' -or (Get-OpenWebRecoveryHash $bytes) -cne $pin){throw 'An installed Greetings source helper differs from its signed release.'}
  $sources[$name]=@{Bytes=$bytes;Sha256=$pin}
 }
 $record=Read-OpenWeb20GreetingCompatibility $metadata.backup_path
 if($record -and ($record.Version -cne $metadata.version -or $record.SourceManifestSha256 -cne $metadata.source_manifest_sha256)){throw 'The compatibility snapshot belongs to another target release.'}
 if($record){foreach($entry in $record.EngineFiles){if($entry.NewSha256 -cne $sources[$entry.Name].Sha256){throw 'A compatibility helper pin differs from the signed release.'}}}
 if($record -and $record.State -ceq 'completed'){
  $null=Assert-OpenWebGreetingAccessSnapshot -Snapshot $record.GreetingAccess -StateRoot $private
  foreach($entry in $record.EngineFiles){if((Get-OpenWebRecoveryHash (Read-OpenWebRecoveryBytes (Join-Path $directory $entry.Name) 1048576)) -cne $entry.NewSha256){throw 'A completed compatibility helper changed.'}}
  Remove-OpenWebCallRecordHold -StateRoot $private -Hold $record.Hold -MaintenanceLock $lock;return
 }
 if($record -and $record.State -ceq 'rolled_back'){throw 'This compatibility transaction was already rolled back.'}
 # The exclusive lease fences GreetingWorker before DB access/prepare/dispatch.
 # Existing dispatched Lua recording calls finish independently. Refuse busy
 # work before mutations; the unchanged updater retries recovery75 every5s.
 CheckIdle
 $probe='<?php require "C:/OpenWebPBX/web/resources/require.php"; $db=new database; $n=$db->select("select count(*) as n from v_pbx_greetings where state=''calling''",null,"column");if(!is_numeric($n))exit(1);if((int)$n!==0)exit(75);'
 $probePath=Join-Path $private ('upgrade-greeting-idle-'+[Guid]::NewGuid().ToString('N')+'.php')
 try{
  [IO.File]::WriteAllText($probePath,$probe,[Text.UTF8Encoding]::new($false));& "$root\php\php.exe" $probePath
  if($LASTEXITCODE -eq 75){$script:deferred=$true;throw 'An active greeting recording must finish before compatibility finalization.'}
  if($LASTEXITCODE -ne 0){throw 'The installed greeting recording state is unavailable.'}
 }finally{Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue}
 if(!$record){
  VerifyBackup $metadata.backup_path
  $null=Assert-OpenWebCallRecordOrdinary -Path (Split-Path $directory -Parent) -Directory
  $exists=Test-Path -LiteralPath $directory
  if($exists){$null=Assert-OpenWebCallRecordOrdinary -Path $directory -Directory}
  $entries=@();foreach($name in 'call.lua','recording.lua'){
   $path=Join-Path $directory $name;$present=Test-Path -LiteralPath $path;$bytes=$null;$sddl=$null;$hash=$null
   if($present){$null=Assert-OpenWebCallRecordOrdinary -Path $path;$bytes=Read-OpenWebRecoveryBytes $path 1048576;$hash=Get-OpenWebRecoveryHash $bytes;$sddl=(Get-Acl -LiteralPath $path -ErrorAction Stop).Sddl}
   $entries+=@{Name=$name;Exists=[bool]$present;OldSha256=$hash;NewSha256=$sources[$name].Sha256;Bytes=if($present){[Convert]::ToBase64String($bytes)}else{$null};Sddl=$sddl}
  }
  $access=Get-OpenWebGreetingAccessSnapshot -StateRoot $private -MaintenanceLock $lock
  try{
   Assert-OpenWebCallRecordHold $Journal.call_records_hold
   if($Journal.call_records_hold.owner -cne 'upgrade'){throw 'The original20 transaction hold is not upgrade-owned.'}
   $record=[pscustomobject]@{schema=1;State='prepared';Backup=$metadata.backup_path;BackupManifestSha256=$metadata.backup_manifest_sha256;BackupCompleteSha256=$metadata.backup_complete_sha256;SourceManifestSha256=$metadata.source_manifest_sha256;Version=$metadata.version;PreviousVersion='1.0.20';GreetingAccess=$access;OriginalRootExists=[bool](Test-Path -LiteralPath (Join-Path $metadata.backup_path 'storage\greetings') -PathType Container);EngineDirectoryExists=[bool]$exists;EngineDirectorySddl=if($exists){(Get-Acl -LiteralPath $directory -ErrorAction Stop).Sddl}else{$null};EngineFiles=$entries;Hold=$Journal.call_records_hold}
   Write-OpenWeb20GreetingCompatibility $record
  }catch{$failure=$_;try{Restore-OpenWebGreetingAccess -Snapshot $access -StateRoot $private -MaintenanceLock $lock}catch{$failure.Exception.Data['greeting_compatibility_pregrant_cleanup_failed']=$true};throw $failure}
 }
 Set-OpenWebCallRecordHold -StateRoot $private -Hold $record.Hold -MaintenanceLock $lock
 $writingCompletion=$false
 try{
  # A previous interrupted attempt has only old/new atomic helper states.
  Restore-OpenWeb20GreetingCompatibility -Backup $metadata.backup_path
  if(!(Test-Path -LiteralPath $directory)){$null=[IO.Directory]::CreateDirectory($directory)}
  $null=Assert-OpenWebCallRecordOrdinary -Path $directory -Directory
  foreach($entry in $record.EngineFiles){Set-OpenWeb20GreetingHelper -Path (Join-Path $directory $entry.Name) -Bytes $sources[$entry.Name].Bytes -Sddl $entry.Sddl}
  if(!(Test-Path -LiteralPath (Join-Path $private 'storage\greetings'))){$null=Get-OpenWebGreetingAccessSnapshot -StateRoot $private -MaintenanceLock $lock}
  Install-OpenWebGreetingAccess -Snapshot $record.GreetingAccess -StateRoot $private -MaintenanceLock $lock
  foreach($entry in $record.EngineFiles){if((Get-OpenWebRecoveryHash (Read-OpenWebRecoveryBytes (Join-Path $directory $entry.Name) 1048576)) -cne $entry.NewSha256){throw 'The deployed Greetings helper differs from its signed release.'}}
  $writingCompletion=$true;$record.State='completed';Write-OpenWeb20GreetingCompatibility $record
  Remove-OpenWebCallRecordHold -StateRoot $private -Hold $record.Hold -MaintenanceLock $lock
 }catch{
  $failure=$_
  $restoreAllowed=!$writingCompletion
  if($writingCompletion){
   # A completed marker is the compatibility commit. Hold cleanup may retry,
   # but must never roll files/ACLs back under that durable success identity.
   try{$durable=Read-OpenWeb20GreetingCompatibility $metadata.backup_path;$restoreAllowed=$durable -and $durable.State -ceq 'prepared';if(!$durable -or $durable.State -cnotin 'prepared','completed'){$failure.Exception.Data['greeting_compatibility_completion_indeterminate']=$true}}
   catch{$failure.Exception.Data['greeting_compatibility_completion_indeterminate']=$true}
  }
  if($restoreAllowed){try{Restore-OpenWeb20GreetingCompatibility -Backup $metadata.backup_path}catch{$failure.Exception.Data['greeting_compatibility_recovery_failed']=$true}}
  throw $failure
 }
}

function CompleteInstalledCallRecordHold {
 # A successful fresh installation can lose power after Completed commits but
 # before its marker is removed. The ordinary updater's first Recover retries
 # only this exact installation-owned marker, never an upgrade/restore hold.
 if(!(Test-Path -LiteralPath (Join-Path $private 'call-records.hold'))){return}
 if(Test-Path -LiteralPath $journalPath){throw 'A pending update must recover before the fresh-install call-record hold can be released.'}
 $installed=Get-Content -LiteralPath (Join-Path $private 'installation.json') -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
 $installedVersion=(Get-Content -LiteralPath (Join-Path $root 'web\VERSION') -Raw -Encoding UTF8 -ErrorAction Stop).Trim()
 if($installed.Completed -isnot [bool] -or !$installed.Completed -or $installed.Version -isnot [string] -or $installed.Version -cne $installedVersion -or !$installed.PSObject.Properties['CallRecordHold']){throw 'The fresh installation has not durably completed at its installed version.'}
 Assert-OpenWebCallRecordHold $installed.CallRecordHold
 if($installed.CallRecordHold.owner -cne 'install'){throw 'A different call-record hold requires its normal recovery.'}
 $gate=Get-OpenWebRestoreGate -StateRoot $private
 if($gate.Calls -or $gate.Jobs -or $gate.Updates -or $gate.Backups){throw 'Restore activation is required before call-record imports may resume.'}
 Assert-OpenWebUpgradeAllowed -StateRoot $private
 Remove-OpenWebCallRecordHold -StateRoot $private -Hold $installed.CallRecordHold -MaintenanceLock $lock
}
function ResumeHeldRestore {
 # A later restore owns its own CDR marker. Terminal install/update journals
 # must not try to remove that marker using an earlier transaction identity.
 # An unfinished restore still refuses all starts through the original gate.
 $gate=Get-OpenWebRestoreGate -StateRoot $private
 if($gate.Blocked){throw 'Complete interrupted backup recovery before restarting PBX services.'}
 if(!$gate.Calls -and !$gate.Jobs -and !$gate.Updates -and !$gate.Backups){return $false}
 if(Test-Path -LiteralPath $journalPath){
  $item=Get-Item -LiteralPath $journalPath -Force -ErrorAction Stop
  if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt 1048576){throw 'The previous update journal requires recovery before restore activation.'}
  $previous=Get-Content -LiteralPath $journalPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
  if(($previous.schema -isnot [int] -and $previous.schema -isnot [long]) -or $previous.schema -ne 1 -or $previous.state -isnot [string] -or $previous.state -cnotin 'completed','rolled_back'){throw 'The previous update must finish recovery before restore activation.'}
  if($previous.PSObject.Properties['call_records_hold']){Assert-OpenWebCallRecordHold $previous.call_records_hold}
  if($previous.state -ceq 'completed' -and $previous.PSObject.Properties['recovery_entry'] -and !($previous.PSObject.Properties['finalization'] -and $previous.finalization.phase -is [string] -and $previous.finalization.phase -ceq 'complete' -and $previous.finalization.failed -is [bool] -and !$previous.finalization.failed)){throw 'The committed update must finish finalization before restore activation.'}
 }
 $null=StartPbx
 Write-Host 'Update recovery checked. Restored services retain their activation holds.'
 return $true
}

$script:managerTasks=@()
function InstalledManagers {
 $expected=[IO.Path]::GetFullPath("$root\desktop\OpenWebPbx.Desktop.exe")
 foreach($process in Get-CimInstance Win32_Process -Filter "Name='OpenWebPbx.Desktop.exe'"){
  if($process.ExecutablePath -and [IO.Path]::GetFullPath($process.ExecutablePath).Equals($expected,[StringComparison]::OrdinalIgnoreCase)){$process}
 }
}
function PrepareManagers {
 # Each manager registers an interactive-token task for its own Windows user.
 # Only tasks for currently running manager owners are eligible to reopen.
 foreach($process in @(InstalledManagers)){
  $owner=Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid
  if($owner.ReturnValue -eq 0){
   $name='OpenWebPBX-Manager-'+$owner.Sid
   $task=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
   if(!$task){
    # Bootstrap managers from 1.0.3 did not register a restart task. Use the
    # existing process owner's interactive token, never the service identity.
    $principal=New-ScheduledTaskPrincipal -UserId $owner.Sid -LogonType Interactive -RunLevel Limited
    $action=New-ScheduledTaskAction -Execute "$root\desktop\OpenWebPbx.Desktop.exe" -WorkingDirectory "$root\desktop"
    $settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings $settings -Force|Out-Null
    $task=Get-ScheduledTask -TaskName $name
   }
   $taskSid=$null
   if($task){try{$taskSid=if($task.Principal.UserId -like 'S-1-*'){$task.Principal.UserId}else{(New-Object Security.Principal.NTAccount($task.Principal.UserId)).Translate([Security.Principal.SecurityIdentifier]).Value}}catch{}}
   $actions=@()
   if($task){$actions=@($task.Actions)}
   $expectedAction=$actions.Count -eq 1 -and $actions[0].Execute -eq "$root\desktop\OpenWebPbx.Desktop.exe" -and $actions[0].WorkingDirectory -eq "$root\desktop" -and !$actions[0].Arguments
   if($task -and $task.Principal.LogonType -eq 'Interactive' -and $taskSid -eq $owner.Sid -and $expectedAction){$script:managerTasks+=$name}
   else{throw 'The manager could not be prepared to reopen. Close it before requesting installation again.'}
  }
 }
}


function Run([string]$Exe, [string[]]$Arguments) {
 $prior = $ErrorActionPreference
 try { $ErrorActionPreference = 'Continue'; & $Exe @Arguments; $code = $LASTEXITCODE }
 finally { $ErrorActionPreference = $prior }
 if ($code -ne 0) {
  $failure=[InvalidOperationException]::new('A required update command failed. Review the private update log.')
  $failure.Data['command_basename']=[IO.Path]::GetFileName($Exe);$failure.Data['command_exit']=[int]$code
  $caller=@(Get-PSCallStack)[1]
  if($caller){$failure.Data['caller_basename']=[IO.Path]::GetFileName($caller.ScriptName);$failure.Data['caller_line']=[int]$caller.ScriptLineNumber}
  throw $failure
 }
}
function CopyTree([string]$From, [string]$To, [switch]$Mirror) {
 $mode = if ($Mirror) { '/MIR' } else { '/E' }
 & robocopy.exe $From $To $mode /COPY:DAT /DCOPY:T /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
 if ($LASTEXITCODE -ge 8) { throw 'A server folder could not be copied.' }
}
function StopPbx {
 if((Get-Website -Name OpenWebPBX).State -ne 'Stopped'){Stop-Website OpenWebPBX}
 if ((Get-WebAppPoolState OpenWebPBX).Value -ne 'Stopped') { Stop-WebAppPool OpenWebPBX }; WaitPool 'Stopped'
 foreach ($name in 'OpenWebPBX', 'FreeSWITCH') { Stop-Service $name; (Get-Service $name).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(40)) }
 foreach($manager in @(InstalledManagers)){Stop-Process -Id $manager.ProcessId -Force -ErrorAction SilentlyContinue}
}
function StartPbx {
 $gate=Get-OpenWebRestoreGate -StateRoot $private
 if($gate.Blocked){throw 'Complete interrupted backup recovery before restarting PBX services.'}
 if(!$gate.Calls -and (Get-Service FreeSWITCH).Status -ne 'Running'){Start-Service FreeSWITCH}
 if(!$gate.Jobs -and (Get-Service OpenWebPBX).Status -ne 'Running'){Start-Service OpenWebPBX}
 if ((Get-WebAppPoolState OpenWebPBX).Value -ne 'Started') { Start-WebAppPool OpenWebPBX }; WaitPool 'Started'
 if((Get-Website -Name OpenWebPBX).State -ne 'Started'){Start-Website OpenWebPBX}
}
function CheckHealth([string]$ExpectedVersion) {
 for ($attempt = 0; $attempt -lt 30; $attempt++) {
  try {
   $health = Invoke-RestMethod 'http://127.0.0.1:8087/health' -TimeoutSec 3
   if ($health.state -eq 'Running' -and $health.version -eq $ExpectedVersion) {
    if(Test-OpenWebTrustedLogin $state.DomainName $state.HttpsPort){
     if([version]$ExpectedVersion -lt [version]'1.0.13'){return}
     & "$root\php\php.exe" (Join-Path $script:recoveryCodeRoot 'check-call-engine.php') "$root\web"
     if($LASTEXITCODE -eq 0){return}
    }
   }
  } catch { }
  Start-Sleep -Seconds 2
 }
 throw 'The updated phone listener, call service or trusted HTTPS sign-in page did not become ready.'
}
function PauseEngine {
 $probe=@'
<?php
require "C:/OpenWebPBX/web/resources/require.php";
$paused=false;
try {
 if(trim(event_socket::api("fsctl pause_check"))!=="false")exit(75);
 if(!str_starts_with(event_socket::api("fsctl pause"),"+OK"))exit(1);
 $paused=true;
 foreach(["show channels as json","show calls as json"] as $command){$state=json_decode(event_socket::api($command),true);if(!isset($state["row_count"])||(int)$state["row_count"]!==0){event_socket::api("fsctl resume");exit(75);}}
}catch(Throwable){if($paused)event_socket::api("fsctl resume");exit(1);}
'@
 $file=Join-Path $private ('update-pause-'+[Guid]::NewGuid().ToString('N')+'.php')
 [IO.File]::WriteAllText($file,$probe,(New-Object Text.UTF8Encoding($false)))
 Push-Location "$root\web"
 try{& "$root\php\php.exe" $file;if($LASTEXITCODE -ne 0){$script:deferred=$true;throw 'Calls or existing maintenance prevent this update.'};$script:enginePaused=$true}finally{Pop-Location;Remove-Item $file -Force -ErrorAction SilentlyContinue}
}
function ResumeEngine {
 if(!$script:enginePaused){return}
 $file=Join-Path $private ('update-resume-'+[Guid]::NewGuid().ToString('N')+'.php')
 [IO.File]::WriteAllText($file,'<?php require "C:/OpenWebPBX/web/resources/require.php";event_socket::api("fsctl resume");',(New-Object Text.UTF8Encoding($false)))
 Push-Location "$root\web"
 try{& "$root\php\php.exe" $file|Out-Null}finally{Pop-Location;Remove-Item $file -Force -ErrorAction SilentlyContinue;$script:enginePaused=$false}
}
function CheckWindow {
 $probe = '<?php require "C:/OpenWebPBX/web/resources/require.php"; $r=$database->db->query("select mode,maintenance_hour,maintenance_duration from v_pbx_update_policies where scope_key=''instance''")->fetch(PDO::FETCH_ASSOC);if(!$r || $r["mode"]!=="automatic" || ((int)gmdate("G")-(int)$r["maintenance_hour"]+24)%24 >= (int)$r["maintenance_duration"])exit(75);'
 $file=Join-Path $private ('update-window-'+[Guid]::NewGuid().ToString('N')+'.php')
 [IO.File]::WriteAllText($file,$probe,(New-Object Text.UTF8Encoding($false)))
 Push-Location "$root\web"
 try{& "$root\php\php.exe" $file;if($LASTEXITCODE -ne 0){$script:deferred=$true;throw 'The automatic update is outside the allowed maintenance window.'}}finally{Pop-Location;Remove-Item $file -Force -ErrorAction SilentlyContinue}
}
function CheckIdle {
 $probe = '<?php require "C:/OpenWebPBX/web/resources/require.php"; $v=json_decode(event_socket::api("show channels as json"),true); if(!is_array($v)||!isset($v["row_count"])) {fwrite(STDERR,"The call engine is unavailable.\n");exit(1);} if((int)$v["row_count"]!==0) {fwrite(STDERR,"Finish active calls before updating.\n");exit(1);} echo "Call engine is idle.\n";'
 $probeFile = Join-Path $private ('upgrade-probe-' + [Guid]::NewGuid().ToString('N') + '.php')
 [IO.File]::WriteAllText($probeFile, $probe, (New-Object Text.UTF8Encoding($false)))
 Push-Location "$root\web"
 try { & "$root\php\php.exe" $probeFile; if($LASTEXITCODE -ne 0){$script:deferred=$true;throw 'Waiting for the call engine to be idle.'} } finally { Pop-Location; Remove-Item $probeFile -Force -ErrorAction SilentlyContinue }
}
function SealBackup([string]$Backup) {
 $schemaOwner=& "$root\pgsql\bin\psql.exe" -h 127.0.0.1 -p 5433 -U postgres -d fusionpbx -w -X -Atc "select pg_get_userbyid(nspowner) from pg_namespace where nspname='public'"
 if($LASTEXITCODE -or !$schemaOwner){throw 'The PBX schema owner could not be recorded.'}
 $files=@{}
 foreach($item in Get-ChildItem $Backup -Recurse -Force -File){
  $relative=$item.FullName.Substring($Backup.TrimEnd('\').Length+1).Replace('\','/')
  if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Backup links are not permitted.'}
  $handle=[IO.File]::Open($item.FullName,'Open','ReadWrite','Read')
  try{$handle.Flush($true)}finally{$handle.Dispose()}
  $files[$relative]=(Get-FileHash $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
 }
 WriteState "$Backup\backup-manifest.json" @{schema=1;files=$files}
 WriteState "$Backup\complete.json" @{version=$state.Version;created=[DateTime]::UtcNow.ToString('o');schema_owner=[string]$schemaOwner;integrity_sha256=(Get-FileHash "$Backup\backup-manifest.json" -Algorithm SHA256).Hash.ToLowerInvariant()}
}
function VerifyBackup([string]$Backup) {
 $marker=Get-Content "$Backup\complete.json" -Raw|ConvertFrom-Json
 if(!$marker.integrity_sha256 -or !(Test-Path "$Backup\backup-manifest.json") -or (Get-FileHash "$Backup\backup-manifest.json" -Algorithm SHA256).Hash -ne $marker.integrity_sha256){throw 'The recovery backup has no valid integrity record.'}
 $manifest=Get-Content "$Backup\backup-manifest.json" -Raw|ConvertFrom-Json
 $prefix=[IO.Path]::GetFullPath($Backup).TrimEnd('\')+'\'
 foreach($entry in $manifest.files.PSObject.Properties){
  $path=[IO.Path]::GetFullPath((Join-Path $Backup $entry.Name))
  if(!$path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or !(Test-Path $path -PathType Leaf) -or ((Get-Item $path).Attributes -band [IO.FileAttributes]::ReparsePoint) -or (Get-FileHash $path -Algorithm SHA256).Hash -ne $entry.Value){throw 'The recovery backup failed integrity verification.'}
 }
 if(!$manifest.files.'database.dump' -or !$manifest.files.'installation.json'){throw 'The recovery backup is incomplete.'}
}
function RestorePbx([string]$Backup) {
 if (!(Test-Path "$Backup\complete.json")) { throw 'The selected backup is incomplete.' }
 VerifyBackup $Backup
 # Restore the separate original20 compatibility ACL before-image while the
 # current helper paths still exist; unchanged mirrors restore original bytes.
 if(($RestoreBackup -or $script:operatorRollback) -and (Get-Content -LiteralPath (Join-Path $Backup 'complete.json') -Raw|ConvertFrom-Json).version -ceq '1.0.20'){Restore-OpenWeb20GreetingCompatibility -Backup $Backup -OperatorRollback}
 # Keep the private boot entry active until every rollback step and health
 # check finishes, including a second interruption while restoring tools/DB.
 if($script:upgradeRecoveryEntry){Ensure-OpenWebUpgradeRecoveryPublished -Entry $script:upgradeRecoveryEntry -Root $root -StateRoot $private -EngineRoot $switch -MaintenanceLock $lock}
 . (Join-Path $script:recoveryCodeRoot 'PhpRuntime.Common.ps1')
 $restorePhp=Test-OpenWebPhpBackup -Backup $Backup -Root $root
 foreach ($part in 'web', 'server', 'desktop') { CopyTree "$Backup\$part" "$root\$part" -Mirror }
 # Older immutable backups did not change PHP. New transactions preserve the
 # complete original runtime, including local configuration and extensions.
 if($restorePhp){CopyTree "$Backup\php" "$root\php" -Mirror}
 CopyTree "$Backup\config" $config -Mirror
 CopyTree "$Backup\switch-scripts" "$switch\scripts" -Mirror
 CopyTree "$Backup\switch-conf" "$switch\conf" -Mirror
 # Retain presence for removal even when support restores original absence.
 $hadUpdaterMetadata=Test-Path "$private\updater-install.json"
 Copy-Item "$Backup\installation.json" "$private\installation.json" -Force
 if($script:upgradeRecoveryEntry){
  $metadata=Get-OpenWebUpgradeRecoveryMetadata -Entry $script:upgradeRecoveryEntry -Root $root -StateRoot $private -EngineRoot $switch -RequirePublished
  if((Get-OpenWebRecoveryHash (Read-OpenWebRecoveryBytes "$Backup\runtime.json")) -cne $metadata.runtime_before_sha256){throw 'The restored runtime does not match the pinned pre-upgrade configuration.'}
 }else{Copy-Item "$Backup\runtime.json" "$private\runtime.json" -Force}
 if(Test-Path "$Backup\updater-install.json"){
  WriteState "$private\updater-install.json" (Get-Content "$Backup\updater-install.json" -Raw|ConvertFrom-Json)
 }
 # Select the sealed previous boot path before exact slot restoration. If a
 # running new image prevents removal, recovery refuses; its next SCM restart
 # then uses the old slot instead of repeatedly holding the removable image.
 if(Test-Path "$Backup\updater-install.json"){
  $previousUpdater=Get-Content "$Backup\updater-install.json" -Raw|ConvertFrom-Json
  if($previousUpdater.Version -isnot [string] -or $previousUpdater.Version -cnotmatch '^\d+\.\d+\.\d+$' -or $previousUpdater.Executable -isnot [string] -or $previousUpdater.Executable -ine (Join-Path $root ('updater\slots\'+$previousUpdater.Version+'\OpenWebPbx.Updater.exe'))){throw 'The sealed previous updater must select its fixed owned slot.'}
  & sc.exe config OpenWebPBXUpdater binPath= ('"'+$previousUpdater.Executable+'"')|Out-Null
  if($LASTEXITCODE){throw 'The previous updater boot slot could not be restored.'}
 }
 # Finish exact original bytes/security after SYSTEM has replaced metadata.
 Restore-OpenWebSupport -Backup $Backup -Root $root -StateRoot $private -EngineRoot $switch -MaintenanceLock $lock
 if(!(Test-Path "$Backup\updater-install.json") -and $hadUpdaterMetadata -and (Test-Path "$root\tools\Remove-Updater.ps1")){& "$root\tools\Remove-Updater.ps1"}
 if(Test-Path "$Backup\tools"){CopyTree "$Backup\tools" "$root\tools" -Mirror}
 if(Test-Path "$Backup\phone-tls"){CopyTree "$Backup\phone-tls" "$private\phone-tls" -Mirror}
 if(Test-Path "$Backup\phone-tls.json"){Copy-Item "$Backup\phone-tls.json" "$private\phone-tls.json" -Force}
 # Storage is preserved by an upgrade. Restore its snapshot only when an operator
 # explicitly chooses rollback; automatic recovery must not remove new media.
 if ($RestoreBackup -or $script:operatorRollback) { CopyTree "$Backup\storage" "$private\storage" -Mirror }
 # Preserve the database OID and the independent updater's connections. The
 # Windows installer owns this dedicated database/public schema; restore all
 # PBX objects in one transaction, including removing failed-migration objects.
 $restoreSql=Join-Path $updates ('restore-'+[Guid]::NewGuid().ToString('N')+'.sql')
 $transactionSql=$restoreSql+'.transaction'
 $backupState=Get-Content "$Backup\complete.json" -Raw|ConvertFrom-Json
 $schemaOwner=if($backupState.schema_owner){[string]$backupState.schema_owner}else{'pg_database_owner'}
 $quotedOwner='"'+$schemaOwner.Replace('"','""')+'"'
 try{
  Run "$root\pgsql\bin\pg_restore.exe" @('--exit-on-error','--file',$restoreSql,"$Backup\database.dump")
  $writer=New-Object IO.StreamWriter($transactionSql,$false,(New-Object Text.UTF8Encoding($false)))
  try{
   $writer.WriteLine('BEGIN; DROP SCHEMA public CASCADE; CREATE SCHEMA public AUTHORIZATION fusionpbx; GRANT USAGE ON SCHEMA public TO PUBLIC;')
   $reader=[IO.File]::OpenText($restoreSql);$buffer=New-Object char[] 65536
   try{while(($count=$reader.Read($buffer,0,$buffer.Length)) -gt 0){$writer.Write($buffer,0,$count)}}finally{$reader.Dispose()}
   $writer.WriteLine('ALTER SCHEMA public OWNER TO '+$quotedOwner+';')
   if($RestoreBackup -or $script:operatorRollback){$writer.WriteLine('DO $$ BEGIN IF to_regclass(''public.v_pbx_update_policies'') IS NOT NULL THEN UPDATE public.v_pbx_update_policies SET mode=''notify'',updated_at=now() WHERE scope_key=''instance''; END IF; END $$;')}
   $writer.WriteLine('COMMIT;')
  }finally{$writer.Dispose()}
  Run "$root\pgsql\bin\psql.exe" @('-h','127.0.0.1','-p','5433','-U','postgres','-d','fusionpbx','-w','-X','-v','ON_ERROR_STOP=1','-f',$transactionSql)
 }finally{Remove-Item $restoreSql,$transactionSql -Force -ErrorAction SilentlyContinue}
 Remove-Item "$private\cache\*" -Recurse -Force -ErrorAction SilentlyContinue
}

if (!(Test-Path "$private\installation.json")) { throw 'Install OpenWeb PBX before applying an update.' }
$installationText = Get-Content "$private\installation.json" -Raw
$state = $installationText | ConvertFrom-Json
$previousVersion = $state.Version
$version = $previousVersion
if (!$state.Completed) { throw 'Complete the existing installation before updating it.' }
Import-Module WebAdministration
$lock = $null; $stopped = $false; $backupReady = $false; $backup = ''; $success = $false
$priorPgPassword = $env:PGPASSWORD
try {
 try{$lock = Open-OpenWebUpgradeMaintenance -Path "$private\upgrade.lock"}catch{if($_.Exception.GetBaseException() -isnot [IO.IOException]){throw};$script:deferred=$true;throw 'Another PBX update is running.'}
 if((Get-Content "$private\installation.json" -Raw) -cne $installationText){$script:deferred=$true;throw 'The installed PBX changed while waiting for maintenance. Retry the update.'}
 New-Item -ItemType Directory -Force $updates|Out-Null
 $env:PGPASSWORD = $state.PostgresPassword
 if($Recover){
  if(ResumeHeldRestore){return}
  if(!(Test-Path -LiteralPath $journalPath)){CompleteInstalledCallRecordHold}
  if(Test-Path $journalPath){
   $journal=Get-Content $journalPath -Raw|ConvertFrom-Json
   if($journal.PSObject.Properties['call_records_hold']){$script:callRecordsHold=$journal.call_records_hold;Assert-OpenWebCallRecordHold $script:callRecordsHold}
   if($journal.state -ceq 'rolled_back' -and $script:callRecordsHold){Remove-OpenWebCallRecordHold -StateRoot $private -Hold $script:callRecordsHold -MaintenanceLock $lock}
   Complete-OpenWeb20GreetingCompatibility -Journal $journal
   if($journal.state -ceq 'completed' -and $journal.PSObject.Properties['recovery_entry'] -and !($journal.PSObject.Properties['finalization'] -and $journal.finalization.phase -is [string] -and $journal.finalization.phase -ceq 'complete' -and $journal.finalization.failed -is [bool] -and !$journal.finalization.failed)){
    $backup=$journal.backup_path;$version=$journal.version;$previousVersion=$journal.previous_version
    $script:managerTasks=@($journal.manager_tasks);$script:operatorRollback=[bool]$journal.operator_rollback
    $script:upgradeRecoveryEntry=$journal.recovery_entry;$script:upgradeCommitted=$true
    CompleteCommittedFinalization
   }
   if($journal.state -in 'prepared','quiescing','deploying','migrating','validating','rolling_back','recovery_required'){
    $backup=$journal.backup_path;$version=$journal.version;$previousVersion=$journal.previous_version
    $script:managerTasks=@($journal.manager_tasks)
    $script:operatorRollback=[bool]$journal.operator_rollback
    if($journal.PSObject.Properties['recovery_entry']){
     $script:upgradeRecoveryEntry=$journal.recovery_entry
     Ensure-OpenWebUpgradeRecoveryPublished -Entry $script:upgradeRecoveryEntry -Root $root -StateRoot $private -EngineRoot $switch -MaintenanceLock $lock
     # Installed tools can be mirrored back to a legacy version lacking these
     # dependencies. Keep the current recovery execution on its sealed bundle.
     $script:recoveryCodeRoot=$script:upgradeRecoveryEntry.bundle_path
     foreach($name in 'Restore-Gates.ps1','Support-Recovery.ps1','Web-Readiness.ps1','UpgradeRecovery.Common.ps1','File-Security.ps1','CallRecords.Common.ps1'){. (Join-Path $script:recoveryCodeRoot $name)}
    }
    if($script:callRecordsHold){Set-OpenWebCallRecordHold -StateRoot $private -Hold $script:callRecordsHold -MaintenanceLock $lock}
    if(!(Test-Path "$backup\complete.json")){
     if($journal.state -notin 'prepared','quiescing'){throw 'The interrupted update has no complete recovery backup.'}
     $script:enginePaused=($journal.state -eq 'quiescing');StartPbx;ResumeEngine;CheckHealth $previousVersion;Complete-OpenWebUpgradeRecovery -Entry $script:upgradeRecoveryEntry -Root $root -StateRoot $private -EngineRoot $switch -MaintenanceLock $lock -Outcome Rollback;SaveJournal 'rolled_back'
    }else{
     VerifyBackup $backup;SaveJournal 'rolling_back';$recoveryRestoreStarted=$true;$stopped=$true;StopPbx
     RestorePbx $backup;$state=Get-Content "$private\installation.json" -Raw|ConvertFrom-Json;StartPbx;$stopped=$false;CheckHealth $previousVersion;Complete-OpenWebUpgradeRecovery -Entry $script:upgradeRecoveryEntry -Root $root -StateRoot $private -EngineRoot $switch -MaintenanceLock $lock -Outcome Rollback;SaveJournal 'rolled_back'
    }
    ResumeManagers
    $state=Get-Content "$private\installation.json" -Raw|ConvertFrom-Json
   }
  }
  StartPbx
  $gate=Get-OpenWebRestoreGate -StateRoot $private
  if(!$gate.Calls -and !$gate.Jobs){CheckHealth $state.Version}
  if($gate.Calls -or $gate.Jobs){Write-Host 'Update recovery checked. Restored calling and background jobs remain held.'}else{Write-Host 'Update recovery checked; the phone system is running.'}
  return
 }
 if(!$Recover){Assert-OpenWebUpgradeAllowed -StateRoot $private;Assert-OpenWebUpgradeRecoveryIdle -Root $root -StateRoot $private;if(!$RestoreBackup){$null=Assert-OpenWebInstalledUpdaterService -Root $root -StateRoot $private}}
 if($Archive){
  if(!$FeedEnvelope -or !$TargetVersion){throw 'A signed feed and target version are required.'}
  $installedUpdater=Get-Content "$private\updater-install.json" -Raw|ConvertFrom-Json
  $extracted=Join-Path "$updates\staging" ([Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force "$updates\staging"|Out-Null
  $verify=& $installedUpdater.Executable --verify-package --archive $Archive --feed-envelope $FeedEnvelope --target-version $TargetVersion --extract-to $extracted
  if($LASTEXITCODE){throw 'The signed release package could not be verified. No services were stopped.'}
  $verified=($verify -join "`n")|ConvertFrom-Json
  $payload=$verified.package_path
  if($verified.version -ne $TargetVersion){throw 'The signed release version is incorrect.'}
 }

 if ($RestoreBackup) {
  if ($Check) { throw 'Use -Check for an update, or -RestoreBackup for recovery.' }
  $backup = [IO.Path]::GetFullPath($RestoreBackup).TrimEnd('\')
  $backupRoot = [IO.Path]::GetFullPath("$private\backups").TrimEnd('\') + '\'
  if (!$backup.StartsWith($backupRoot, [StringComparison]::OrdinalIgnoreCase) -or !(Test-Path "$backup\complete.json")) { throw 'Choose a completed private OpenWeb PBX update backup.' }
  $expected = (Get-Content "$backup\complete.json" -Raw | ConvertFrom-Json).version
  VerifyBackup $backup
  CheckIdle
  $operatorUpdater=Assert-OpenWebInstalledUpdaterService -Root $root -StateRoot $private -StopForOperatorRollback
  $script:operatorUpdaterWasRunning=$operatorUpdater.WasRunning;$script:operatorUpdaterStopped=[bool]$operatorUpdater.WasRunning
  PrepareManagers;PauseEngine
  $version=$expected;$previousVersion=$expected;$script:operatorRollback=$true;$restoreStarted=$true
  $script:callRecordsHold=@{schema=1;owner='upgrade';transaction=[Guid]::NewGuid().ToString('N')}
  SaveJournal 'rolling_back'
  Set-OpenWebCallRecordHold -StateRoot $private -Hold $script:callRecordsHold -MaintenanceLock $lock
  $stopped = $true; StopPbx
  RestorePbx $backup;$state=Get-Content "$private\installation.json" -Raw|ConvertFrom-Json
  StartPbx;ResumeEngine;$stopped = $false; CheckHealth $expected;Complete-OpenWebUpgradeRecovery -Entry $script:upgradeRecoveryEntry -Root $root -StateRoot $private -EngineRoot $switch -MaintenanceLock $lock -Outcome Rollback;SaveJournal 'rolled_back';ResumeManagers
  $success = $true
  if($script:operatorUpdaterWasRunning -and (Get-Service OpenWebPBXUpdater -ErrorAction SilentlyContinue)){Start-ScheduledTask OpenWebPBX-Updater-Restart}
  Write-Host "Previous installation restored. Backup: $backup"
  return
 }
 $version = (Get-Content "$payload\VERSION" -Raw).Trim()
 if ($version -notmatch '^\d+\.\d+\.\d+$' -or [version]$version -lt [version]$state.Version) { throw 'Choose a valid release at least as new as the installed version.' }
 if (!(Test-Path "$payload\release-manifest.json")) { throw 'Extract the complete release, including its file manifest.' }
 $manifest = Get-Content "$payload\release-manifest.json" -Raw | ConvertFrom-Json
 if ($manifest.version -ne $version) { throw 'The update manifest version does not match the release.' }
 $hashes = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
 foreach($entry in $manifest.files.PSObject.Properties){$hashes.Add($entry.Name,[string]$entry.Value)}
 Write-Host "Verifying $($hashes.Count) release files..."
 $packageRoot = [IO.Path]::GetFullPath($payload).TrimEnd('\') + '\'
 foreach ($entry in $hashes.GetEnumerator()) {
  $path = [IO.Path]::GetFullPath((Join-Path $payload $entry.Key))
  if (!$path.StartsWith($packageRoot, [StringComparison]::OrdinalIgnoreCase) -or !(Test-Path -LiteralPath $path -PathType Leaf) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry.Value) { throw 'Update file verification failed. Download and extract the release again.' }
 }
 foreach ($required in 'web/resources/require.php', 'server/OpenWebPbx.Server.exe', 'desktop/OpenWebPbx.Desktop.exe', 'bootstrap.php', 'PhpRuntime.Common.ps1') {
  if (!$hashes.ContainsKey($required)) { throw 'The release manifest is missing a required component.' }
 }
 foreach ($item in Get-ChildItem $payload -Force -Recurse) {
  if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Release links are not permitted.' }
  if (!$item.PSIsContainer -and $item.FullName -ne "$payload\release-manifest.json") {
   $relative = $item.FullName.Substring($packageRoot.Length).Replace('\','/')
   if (!$hashes.ContainsKey($relative)) { throw 'The extracted release contains files missing from its manifest.' }
  }
 }
 # Never stage private machine files or source-control data into the web root.
 foreach ($item in Get-ChildItem "$payload\web" -Force -Recurse) {
  if ($item.Name -eq '.git' -or $item.Name -like '.env*' -or $item.Extension -in '.dump','.key','.pfx') { throw 'The release contains a private configuration path.' }
 }
 & "$payload\Install-NativeEngine.ps1" -PackageRoot $payload -Check
 & "$payload\Install-LocalCodec.ps1" -PackageRoot $payload -Check
 & "$payload\Install-Voices.ps1" -PackageRoot $payload -Check
 . (Join-Path $payload 'PhpRuntime.Common.ps1')
 Assert-OpenWebPhpTree -Directory (Join-Path $root 'php')
 $phpRuntime=Prepare-OpenWebPhpRuntime -UpdatesRoot $updates
 # A stopped original engine remains stopped. When it is running, authenticate
 # its actual log_dir before any backup/deployment rather than guessing a path.
 $logEngine=Get-Service -Name FreeSWITCH -ErrorAction Stop
 if($logEngine.Status -notin 'Running','Stopped'){throw 'Wait for the call engine to finish its current startup or shutdown before updating.'}
 $logArguments=@("$payload\windows-log.php","$root\web",'check')
 if($logEngine.Status -eq 'Stopped'){$logArguments+='--engine-stopped'}
 Run "$root\php\php.exe" $logArguments
 CheckIdle
 if ($Check) { Write-Host "OpenWeb PBX $version update files and installed call engine passed preflight."; return }
 if($Automatic){CheckWindow}
 CheckIdle
 $backup = Join-Path "$private\backups" ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
 Write-Host 'Release verified. Saving a private backup before updating the server...'
 New-Item -ItemType Directory -Force $backup | Out-Null
 & icacls.exe $backup /inheritance:r /grant '*S-1-5-32-544:(OI)(CI)F' /grant '*S-1-5-18:(OI)(CI)F' | Out-Null
 if ($LASTEXITCODE) { throw 'Private backup access could not be secured.' }
 foreach ($part in 'web','server','desktop','php') { CopyTree "$root\$part" "$backup\$part" }
 CopyTree $config "$backup\config"
 CopyTree "$switch\scripts" "$backup\switch-scripts"
 CopyTree "$switch\conf" "$backup\switch-conf"
 CopyTree "$switch\sounds" "$backup\switch-sounds"
 CopyTree "$switch\mod" "$backup\switch-mod"
 CopyTree "$private\storage" "$backup\storage"
 Copy-Item "$private\installation.json","$private\runtime.json" $backup
 if(Test-Path "$private\updater-install.json"){Copy-Item "$private\updater-install.json" $backup}
 if(Test-Path "$root\tools"){CopyTree "$root\tools" "$backup\tools"}
 if(Test-Path "$private\phone-tls"){CopyTree "$private\phone-tls" "$backup\phone-tls"}
 if(Test-Path "$private\phone-tls.json"){Copy-Item "$private\phone-tls.json" $backup}
 $script:callRecordsHold=@{schema=1;owner='upgrade';transaction=[Guid]::NewGuid().ToString('N')}
 SaveJournal 'prepared'
 PrepareManagers
 if($Automatic){CheckWindow}
 PauseEngine
 SaveJournal 'quiescing'
 $stopped = $true; StopPbx
 # Capture media completed during the online copy before taking the matching
 # database snapshot. The second copy transfers only the changed files.
 CopyTree "$private\storage" "$backup\storage" -Mirror
 CopyTree "$switch\conf" "$backup\switch-conf" -Mirror
 CopyTree "$root\php" "$backup\php" -Mirror
 Save-OpenWebSupport -Backup $backup -PackageRoot $payload -Root $root -StateRoot $private -EngineRoot $switch -MaintenanceLock $lock
 Run "$root\pgsql\bin\pg_dump.exe" @('-h','127.0.0.1','-p','5433','-U','postgres','-d','fusionpbx','-w','-Fc',"--file=$backup\database.dump")
 SealBackup $backup
 $backupReady = $true
 $script:upgradeRecoveryEntry=New-OpenWebUpgradeRecovery -PackageRoot $payload -Root $root -StateRoot $private -EngineRoot $switch -Backup $backup -MaintenanceLock $lock
 SaveJournal 'deploying'
 Publish-OpenWebUpgradeRecovery -Entry $script:upgradeRecoveryEntry -Root $root -StateRoot $private -EngineRoot $switch -MaintenanceLock $lock
 Set-OpenWebCallRecordHold -StateRoot $private -Hold $script:callRecordsHold -MaintenanceLock $lock
 Write-Host 'Backup complete. Updating the application and call-engine scripts...'
 # Historical installations inherited writable system-drive permissions. Match
 # fresh-install program protection only after the original ACLs are sealed.
 # Reapplying an identical root policy can reorder restored descendant ACEs.
 # Preserve those descriptors when the exact fresh root rules already apply.
 if(!(Test-OpenWebProgramRootPolicy -Root $root)){
  Run icacls.exe @($root,'/inheritance:r','/grant:r','*S-1-5-32-544:(OI)(CI)F','*S-1-5-18:(OI)(CI)F','*S-1-5-32-545:(OI)(CI)RX')
 }
 # Preserve existing private/support security after intentional program hardening.
 # This in-memory success inventory never restores old contents or new objects.
 $upgradePermissions=@(Get-OpenWebUpgradePermissions -Root $root -StateRoot $private -EngineRoot $switch)
 Install-OpenWebPhpRuntime -Prepared $phpRuntime -Root $root
 # Keep local optional applications and server.json; only reviewed release files
 # are replaced. Database, settings, keys and existing media are never re-created.
 foreach ($part in 'web','server','desktop','acme') { CopyTree "$payload\$part" "$root\$part" }
 CopyTree "$root\web\app\switch\resources\scripts" "$switch\scripts"
 CopyTree "$root\web\app\pbx_setup\resources\switch\scripts\app\pbx_setup" "$switch\scripts\app\pbx_setup"
 CopyTree "$root\web\app\pbx_setup\resources\switch\scripts\app\pbx_greetings" "$switch\scripts\app\pbx_greetings"
 & "$payload\Install-NativeEngine.ps1" -PackageRoot $payload
 & "$payload\Install-LocalCodec.ps1" -PackageRoot $payload
 & "$payload\Configure-PHP.ps1" -PackageRoot $payload
 & "$payload\configure-notifications.ps1" -StateRoot $private
 SaveJournal 'migrating'
 Push-Location "$root\web"
 try {
  Run "$root\php\php.exe" @('core\upgrade\upgrade_schema.php')
  Run "$root\php\php.exe" @("$payload\bootstrap.php","$root\web",'migrate')
  Run "$root\php\php.exe" @("$payload\bootstrap.php","$root\web",'upgrade_defaults',"$backup\web")
 } finally { Pop-Location }
 Run "$root\php\php.exe" @("$payload\configure-codec.php","$root\web")
 Install-OpenWebCallRecordAccess -PackageRoot $payload -Root $root -StateRoot $private -EngineRoot $switch -MaintenanceLock $lock
 CopyTree "$root\web\app\switch\resources\scripts" "$switch\scripts"
 CopyTree "$root\web\app\pbx_setup\resources\switch\scripts\app\pbx_setup" "$switch\scripts\app\pbx_setup"
 CopyTree "$root\web\app\pbx_setup\resources\switch\scripts\app\pbx_greetings" "$switch\scripts\app\pbx_greetings"
 Copy-Item "$root\web\app\pbx_setup\resources\prompts\*.wav" "$switch\sounds\openwebpbx" -Force
 Copy-Item "$root\web\app\pbx_setup\resources\prompts\openweb.xml" "$switch\conf\languages\en\ivr\openweb.xml" -Force
 & "$payload\Install-Voices.ps1" -PackageRoot $payload
 & "$payload\Install-Meet.ps1" -PackageRoot $payload -MaintenanceLock $lock
 & "$payload\Install-Dtls.ps1" -PackageRoot $payload -MaintenanceLock $lock
 Run "$root\php\php.exe" @("$payload\configure-music.php","$payload\music","$root\web","$switch\conf\vars.xml")
 & "$payload\Install-Backups.ps1" -PackageRoot $payload -DeferRestart -UpgradeLockHeld
 & "$payload\Install-MailQueue.ps1" -PackageRoot $payload -DeferStart -MaintenanceLock $lock
 & "$payload\Install-TenantDomains.ps1" -PackageRoot $payload -DeferStart -MaintenanceLock $lock
 & "$payload\Install-PhoneHealth.ps1" -PackageRoot $payload -DeferStart -MaintenanceLock $lock
 Remove-Item "$private\cache\*" -Recurse -Force -ErrorAction SilentlyContinue
 $state.Version = $version
 WriteState "$private\installation.json" $state
 SaveJournal 'validating'
 Restore-OpenWebUpgradePermissions -Permissions $upgradePermissions -Root $root -StateRoot $private -EngineRoot $switch
 # Retain the intentional dedicated Greeting grant after unrelated ACL replay.
 $support=Get-Content -LiteralPath (Join-Path $backup 'support-state.json') -Raw|ConvertFrom-Json
 Install-OpenWebGreetingAccess -Snapshot $support.GreetingAccess -StateRoot $private -MaintenanceLock $lock
 StartPbx; ResumeEngine; $stopped = $false; CheckHealth $version
 if(Test-Path "$payload\updater\OpenWebPbx.Updater.exe"){& "$payload\Install-Updater.ps1" -PackageRoot $payload -DeferRestart -DeferServiceSelection}
 Complete-OpenWebUpgradeRecovery -Entry $script:upgradeRecoveryEntry -Root $root -StateRoot $private -EngineRoot $switch -MaintenanceLock $lock -Outcome Success
 $script:upgradeFinalizationPhase='service_selection'
 SaveJournal 'completed'
 $script:upgradeCommitted=$true
 CompleteCommittedFinalization
 $success = $true
 Write-Host "OpenWeb PBX $version is running. Private backup: $backup"
 Write-Host "To roll back: .\Upgrade-OpenWebPBX.ps1 -RestoreBackup '$backup'"
} catch {
 $failure = $_
 if($script:upgradeCommitted){
  # The durable commit is irreversible: a newly selected updater may already be
  # running its own image. Boot recovery finishes selection/tasks idempotently.
  $script:upgradeFinalizationFailed=$true
  try{SaveJournal 'completed'}catch{}
  Write-Warning 'The update is committed. Its remaining updater/background finalization will be retried by recovery.'
 } elseif($restoreStarted -or $recoveryRestoreStarted){
  try{$stopped=$true;StopPbx}catch{}
  SaveJournal 'recovery_required'
  Write-Warning 'The selected backup has not fully restored. Keep maintenance in place and run recovery after correcting the error.'
 } elseif ($backupReady -and !$RestoreBackup) {
  Write-Warning 'The update failed. Restoring the previous application and database.'
  try { SaveJournal 'rolling_back'; $stopped = $true; StopPbx; RestorePbx $backup; StartPbx; ResumeEngine; $stopped = $false; CheckHealth $previousVersion; Complete-OpenWebUpgradeRecovery -Entry $script:upgradeRecoveryEntry -Root $root -StateRoot $private -EngineRoot $switch -MaintenanceLock $lock -Outcome Rollback;SaveJournal 'rolled_back'; ResumeManagers }
  catch { SaveJournal 'recovery_required'; Write-Warning "Automatic recovery needs attention. The private backup is $backup" }
 } elseif ($stopped) { try { StartPbx; $stopped = $false; Complete-OpenWebUpgradeRecovery -Entry $script:upgradeRecoveryEntry -Root $root -StateRoot $private -EngineRoot $switch -MaintenanceLock $lock -Outcome Rollback;SaveJournal 'rolled_back'; ResumeManagers } catch { SaveJournal 'recovery_required' } }
 if($Archive -or $Recover){
  $exitCode=if($script:deferred){75}elseif($script:upgradeCommitted -or $Recover -or ((Test-Path $journalPath) -and (Get-Content $journalPath -Raw|ConvertFrom-Json).state -eq 'recovery_required')){2}else{1}
  Write-Warning 'The update did not complete. Review the private update log and status.'
 }else{throw $failure}
} finally {
 if ($null -eq $priorPgPassword) { Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue } else { $env:PGPASSWORD = $priorPgPassword }
 if($script:enginePaused -and !$stopped){try{ResumeEngine}catch{}}
 if ($extracted -and (Test-Path $extracted)) { Remove-Item $extracted -Recurse -Force -ErrorAction SilentlyContinue }
 if ($phpRuntime -and (Test-Path -LiteralPath $phpRuntime.Directory)) { Remove-Item -LiteralPath $phpRuntime.Directory -Recurse -Force -ErrorAction SilentlyContinue }
 if ($lock) { $lock.Dispose() }
 if($script:operatorUpdaterStopped -and !$restoreStarted -and $script:operatorUpdaterWasRunning){try{Start-Service -Name OpenWebPBXUpdater -ErrorAction Stop}catch{Write-Warning 'The unchanged updater service could not restart after rollback preflight refused.'}}
}

if($success -and !$Recover -and !$RestoreBackup){
 $updater=Get-Service OpenWebPBXUpdater -ErrorAction SilentlyContinue
 if($updater -and $updater.Status -ne 'Running'){Start-Service OpenWebPBXUpdater}
 elseif($updater -and !$Archive){Start-ScheduledTask OpenWebPBX-Updater-Restart}
}
if($Archive -or $Recover){exit $exitCode}
