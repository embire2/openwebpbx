# Verified payload compatibility for the original Windows21 signed helper.
# No registration policy, account, database or runtime setting is changed here.
function Get-OpenWebOnboardingTaskSnapshot {
 $tasks=@(Get-ScheduledTask -TaskName 'OpenWebPBX-Onboarding' -TaskPath '\' -ErrorAction SilentlyContinue)
 if(!$tasks.Count){return $null};if($tasks.Count -ne 1){throw 'One exact root onboarding task is required.'};$task=$tasks[0]
 $scheduler=New-Object -ComObject Schedule.Service;$scheduler.Connect()
 $registered=$scheduler.GetFolder('\').GetTask('OpenWebPBX-Onboarding')
 return @{xml=(Export-ScheduledTask -TaskName 'OpenWebPBX-Onboarding' -TaskPath '\');security=$registered.GetSecurityDescriptor(7);fileAcl=(Get-Acl -LiteralPath (Join-Path $env:SystemRoot 'System32\Tasks\OpenWebPBX-Onboarding')).Sddl;enabled=[bool]$task.Settings.Enabled}
}
function Assert-OpenWebOnboardingTaskSecurity {
 param([string[]]$Descriptors)
 foreach($sddl in $Descriptors){
  $acl=[Security.AccessControl.RawSecurityDescriptor]::new($sddl)
  if($acl.Owner.Value -cnotin 'S-1-5-18','S-1-5-32-544' -or !$acl.DiscretionaryAcl){throw 'The onboarding task owner differs.'}
  foreach($ace in $acl.DiscretionaryAcl){if($ace -isnot [Security.AccessControl.CommonAce] -or $ace.IsCallback -or ($ace.AceQualifier -eq [Security.AccessControl.AceQualifier]::AccessAllowed -and $ace.SecurityIdentifier.Value -cnotin 'S-1-5-18','S-1-5-32-544' -and ($ace.AccessMask -band 0x500D0156))){throw 'The onboarding task permits unrelated mutation.'}}
 }
}
function Assert-OpenWebOnboardingTaskSnapshot {
 param($Snapshot,[string]$Root)
 if(!$Snapshot -or $Snapshot.xml -isnot [string] -or $Snapshot.xml.Length -gt 65536 -or $Snapshot.xml -match '<!DOCTYPE'){throw 'The onboarding task requires review.'}
 [xml]$xml=$Snapshot.xml;$ns=[Xml.XmlNamespaceManager]::new($xml.NameTable);$ns.AddNamespace('t','http://schemas.microsoft.com/windows/2004/02/mit/task')
 function Value([string]$Path){$n=$xml.SelectSingleNode('/t:Task/'+$Path,$ns);if($n){return $n.InnerText};return ''}
 if((Value 't:RegistrationInfo/t:Description') -cne 'OpenWeb PBX owned installation registration and activation worker' -or @($xml.SelectNodes('/t:Task/t:Principals/t:Principal',$ns)).Count -ne 1 -or (Value 't:Principals/t:Principal/t:UserId') -cnotin 'SYSTEM','S-1-5-18' -or (Value 't:Principals/t:Principal/t:LogonType') -cne 'ServiceAccount' -or (Value 't:Principals/t:Principal/t:RunLevel') -cne 'HighestAvailable'){throw 'The onboarding principal differs.'}
 if(@($xml.SelectNodes('/t:Task/t:Actions/*',$ns)).Count -ne 1 -or (Value 't:Actions/t:Exec/t:Command') -cne (Join-Path $Root 'backup-runtime\python.exe') -or (Value 't:Actions/t:Exec/t:Arguments') -cne ('-I -B "'+(Join-Path $Root 'tools\onboarding.py')+'" --tick') -or (Value 't:Actions/t:Exec/t:WorkingDirectory') -cne (Join-Path $Root 'tools')){throw 'The onboarding action differs.'}
 if(@($xml.SelectNodes('/t:Task/t:Triggers/*',$ns)).Count -ne 2 -or @($xml.SelectNodes('/t:Task/t:Triggers/t:BootTrigger',$ns)).Count -ne 1 -or @($xml.SelectNodes('/t:Task/t:Triggers/t:TimeTrigger',$ns)).Count -ne 1 -or (Value 't:Triggers/t:TimeTrigger/t:Repetition/t:Interval') -cne 'PT1M' -or (Value 't:Settings/t:MultipleInstancesPolicy') -cne 'IgnoreNew' -or (Value 't:Settings/t:ExecutionTimeLimit') -cne 'PT20M' -or (Value 't:Settings/t:StartWhenAvailable') -cne 'true' -or (Value 't:Settings/t:Enabled') -cnotin 'true','false'){throw 'The onboarding schedule differs.'}
 foreach($kind in 'BootTrigger','TimeTrigger'){
  if((Value ('t:Triggers/t:'+$kind+'/t:Enabled')) -cnotin '','true' -or (Value ('t:Triggers/t:'+$kind+'/t:EndBoundary')) -cne '' -or (Value ('t:Triggers/t:'+$kind+'/t:ExecutionTimeLimit')) -cnotin '','PT20M'){throw 'The onboarding trigger is disabled, expires or overrides its execution bound.'}
 }
 $source=Value 't:RegistrationInfo/t:Source';$stop=Value 't:Triggers/t:TimeTrigger/t:Repetition/t:StopAtDurationEnd'
 # Native CIM's legacy default is true even with no duration. Preserve an
 # existing untagged task with that indefinite schedule; our tagged factory
 # explicitly writes false, so an altered tagged task cannot be deleted.
 $invalidStop=$stop -cnotin '','false' -and !(!$source.StartsWith('openwebpbx-onboarding-v1:',[StringComparison]::Ordinal) -and $stop -ceq 'true')
 if((Value 't:Triggers/t:TimeTrigger/t:Repetition/t:Duration') -cne '' -or $invalidStop -or (Value 't:Triggers/t:TimeTrigger/t:RandomDelay') -cnotin '','PT0S' -or (Value 't:Triggers/t:BootTrigger/t:Delay') -cnotin '','PT0S' -or !(Value 't:Triggers/t:TimeTrigger/t:StartBoundary')){throw 'The onboarding repeating schedule is not indefinite.'}
 Assert-OpenWebOnboardingTaskSecurity @($Snapshot.security,$Snapshot.fileAcl)
 return $source
}
function Get-OpenWebOnboardingSourceEntry {
 param([string]$Source,[string]$StateRoot)
 $match=[regex]::Match($Source,'\Aopenwebpbx-onboarding-v1:([a-f0-9]{32}):([a-f0-9]{64}):([a-f0-9]{64})\z')
 if(!$match.Success){throw 'The onboarding task has no owned upgrade provenance.'}
 return [pscustomobject]@{schema=1;bundle_path=(Join-Path (Join-Path $StateRoot 'updates\recovery-entry') $match.Groups[1].Value);metadata_sha256=$match.Groups[2].Value;launcher_sha256=$match.Groups[3].Value}
}
function Get-OpenWebOnboardingUpgradeOrigin {
 param($Entry,[string]$Root,[string]$StateRoot,[string]$EngineRoot,[string]$Backup)
 # This validation intentionally does not require the CURRENT upgrade journal:
 # an operator rollback has a new journal. The task's immutable source tag pins
 # the original sealed21 backup and complete recovery source instead.
 $prefix=[IO.Path]::GetFullPath((Join-Path $StateRoot 'updates\recovery-entry')).TrimEnd([char[]]@('\','/'))+[IO.Path]::DirectorySeparatorChar;$bundle=[IO.Path]::GetFullPath($Entry.bundle_path)
 if($Entry.schema -ne 1 -or $Entry.metadata_sha256 -cnotmatch '^[a-f0-9]{64}$' -or $Entry.launcher_sha256 -cnotmatch '^[a-f0-9]{64}$' -or !$bundle.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or $bundle.Substring($prefix.Length) -cnotmatch '^[a-f0-9]{32}$'){throw 'Invalid onboarding recovery provenance.'}
 $null=Assert-OpenWebRecoveryProtected $StateRoot -Directory;$null=Assert-OpenWebRecoveryProtected ([IO.Path]::GetDirectoryName($bundle)) -Directory -Private;$null=Assert-OpenWebRecoveryProtected $bundle -Directory -Private
 $bytes=Read-OpenWebRecoveryBytes (Join-Path $bundle 'entry.json') 1048576
 if((Get-OpenWebRecoveryHash $bytes) -cne $Entry.metadata_sha256){throw 'The onboarding recovery seal changed.'}
 $m=[Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json
 if($m.schema -ne 1 -or $m.computer -cne [Environment]::MachineName -or $m.root -ine [IO.Path]::GetFullPath($Root) -or $m.state_root -ine [IO.Path]::GetFullPath($StateRoot) -or $m.engine_root -ine [IO.Path]::GetFullPath($EngineRoot) -or $m.bundle_path -ine $bundle -or $m.previous_version -cne '1.0.21' -or $m.version -cne '1.0.22' -or $m.files -isnot [pscustomobject]){throw 'The onboarding origin is not this original21 upgrade.'}
 $backupPrefix=[IO.Path]::GetFullPath((Join-Path $StateRoot 'backups')).TrimEnd([char[]]@('\','/'))+[IO.Path]::DirectorySeparatorChar;$actualBackup=[IO.Path]::GetFullPath($m.backup_path)
 if(!$actualBackup.StartsWith($backupPrefix,[StringComparison]::OrdinalIgnoreCase) -or ($Backup -and $actualBackup -ine [IO.Path]::GetFullPath($Backup))){throw 'The onboarding task belongs to another backup.'}
 $null=Assert-OpenWebRecoveryProtected $actualBackup -Directory -Private
 $files=@($m.files.PSObject.Properties);$actual=@(Get-ChildItem -LiteralPath $bundle -Force)
 if($files.Count -lt 4 -or $files.Count -gt 512 -or $actual.Count -ne $files.Count+2){throw 'The onboarding recovery inventory changed.'}
 foreach($f in $actual){if($f.PSIsContainer -or $f.Name -cnotin @($files.Name)+@('entry.json','recovery-launcher.ps1')){throw 'Unexpected onboarding recovery content.'};$null=Assert-OpenWebRecoveryProtected $f.FullName -Private}
 foreach($f in $files){if($f.Name -cnotmatch '^[a-zA-Z0-9_.-]+$' -or $f.Value -cnotmatch '^[a-f0-9]{64}$' -or (Get-OpenWebRecoveryHash (Read-OpenWebRecoveryBytes (Join-Path $bundle $f.Name))) -cne $f.Value){throw 'A sealed onboarding dependency changed.'}}
 if((Get-OpenWebRecoveryHash (Read-OpenWebRecoveryBytes (Join-Path $bundle 'recovery-launcher.ps1'))) -cne $Entry.launcher_sha256 -or $m.files.'release-manifest.json' -cne $m.source_manifest_sha256){throw 'The onboarding launcher or manifest seal changed.'}
 $backupManifestBytes=Read-OpenWebRecoveryBytes (Join-Path $actualBackup 'backup-manifest.json') 16777216;$completeBytes=Read-OpenWebRecoveryBytes (Join-Path $actualBackup 'complete.json') 1048576
 if((Get-OpenWebRecoveryHash $backupManifestBytes) -cne $m.backup_manifest_sha256 -or (Get-OpenWebRecoveryHash $completeBytes) -cne $m.backup_complete_sha256){throw 'The original21 backup seal changed.'}
 $backupManifest=[Text.Encoding]::UTF8.GetString($backupManifestBytes)|ConvertFrom-Json;$complete=[Text.Encoding]::UTF8.GetString($completeBytes)|ConvertFrom-Json
 if($complete.version -cne '1.0.21' -or $complete.integrity_sha256 -cne $m.backup_manifest_sha256 -or $m.original_helper_sha256 -cne 'b54d22c469ca2cbd8747787835c0056a562162cc3e5682b25106bd805826d4e2' -or $backupManifest.files.'tools/Upgrade-OpenWebPBX.ps1' -cne $m.original_helper_sha256 -or $backupManifest.files.'tools/Support-Recovery.ps1' -cne '0a0e6236362e1bb5907075d0bc80d10ffb6250c097322ff71221b4d8a4523b7d'){throw 'The original public21 helper/support identity differs.'}
 foreach($n in 'support-state.json','tools/Upgrade-OpenWebPBX.ps1','tools/Support-Recovery.ps1'){if((Get-OpenWebRecoveryHash (Read-OpenWebRecoveryBytes (Join-Path $actualBackup $n))) -cne $backupManifest.files.$n){throw 'An original21 support before-image changed.'}}
 $support=[Text.Encoding]::UTF8.GetString((Read-OpenWebRecoveryBytes (Join-Path $actualBackup 'support-state.json')))|ConvertFrom-Json
 if($support.schema -ne 1 -or $support.Tasks -isnot [pscustomobject] -or $support.Tasks.PSObject.Properties['OpenWebPBX-Onboarding']){throw 'The original task inventory already covers onboarding or is invalid.'}
 return $m
}
function New-OpenWebCommittedOnboardingTask {
 param([string]$Root,[string]$Source)
 # TASK_CREATE is atomic and refuses a task created since our absence check.
 # Provenance enters the same Task Scheduler transaction as the definition.
 $scheduler=New-Object -ComObject Schedule.Service;$scheduler.Connect();$definition=$scheduler.NewTask(0)
 $definition.RegistrationInfo.Description='OpenWeb PBX owned installation registration and activation worker';$definition.RegistrationInfo.Source=$Source
 $definition.Principal.UserId='SYSTEM';$definition.Principal.LogonType=5;$definition.Principal.RunLevel=1
 $definition.Settings.Enabled=$true;$definition.Settings.StartWhenAvailable=$true;$definition.Settings.MultipleInstances=2;$definition.Settings.ExecutionTimeLimit='PT20M'
 $boot=$definition.Triggers.Create(8);$boot.Enabled=$true;$boot.ExecutionTimeLimit='PT20M';$trigger=$definition.Triggers.Create(1);$trigger.Enabled=$true;$trigger.ExecutionTimeLimit='PT20M';$trigger.StartBoundary=(Get-Date).AddMinutes(1).ToString("yyyy-MM-dd'T'HH:mm:ss",[Globalization.CultureInfo]::InvariantCulture);$trigger.Repetition.Interval='PT1M';$trigger.Repetition.StopAtDurationEnd=$false
 $action=$definition.Actions.Create(0);$action.Path=Join-Path $Root 'backup-runtime\python.exe';$action.Arguments='-I -B "'+(Join-Path $Root 'tools\onboarding.py')+'" --tick';$action.WorkingDirectory=Join-Path $Root 'tools'
 $null=$scheduler.GetFolder('\').RegisterTaskDefinition('OpenWebPBX-Onboarding',$definition,2,'SYSTEM',$null,5,'O:SYG:SYD:P(A;;FA;;;SY)(A;;FA;;;BA)')
}
function Ensure-OpenWebCommittedOnboardingTask {
 param([string]$Root,[string]$StateRoot,[string]$EngineRoot,[IO.FileStream]$MaintenanceLock)
 Assert-OpenWebRecoveryLock $MaintenanceLock $StateRoot
 $existing=Get-OpenWebOnboardingTaskSnapshot
 if($existing){$null=Assert-OpenWebOnboardingTaskSnapshot $existing $Root;return @{state='existing';enabled=$existing.enabled}}
 $path=Join-Path $StateRoot 'updates\install-journal.json'
 if(!(Test-Path -LiteralPath $path)){return @{state='not_needed'}}
 $j=[Text.Encoding]::UTF8.GetString((Read-OpenWebRecoveryBytes $path 1048576))|ConvertFrom-Json
 if($j.state -cne 'completed' -or !$j.finalization -or $j.finalization.phase -cne 'complete' -or $j.finalization.failed -isnot [bool] -or $j.finalization.failed){return @{state='deferred';reason='upgrade_not_finalized'}}
 if($j.previous_version -cne '1.0.21' -or $j.version -cne '1.0.22' -or $j.operator_rollback){return @{state='not_needed'}}
 $m=Get-OpenWebUpgradeRecoveryMetadata -Entry $j.recovery_entry -Root $Root -StateRoot $StateRoot -EngineRoot $EngineRoot -AllowCompleted
 $null=Get-OpenWebOnboardingUpgradeOrigin -Entry $j.recovery_entry -Root $Root -StateRoot $StateRoot -EngineRoot $EngineRoot -Backup $j.backup_path
 if(!$j.recovery_entry -or $j.recovery_entry.bundle_path -cne $m.bundle_path -or (Get-OpenWebRestoreGate -StateRoot $StateRoot).Blocked -or (Test-Path (Join-Path $StateRoot 'updates\maintenance')) -or (Test-Path (Join-Path $StateRoot 'call-records.hold'))){return @{state='deferred';reason='maintenance_or_restore_hold'}}
 $installed=[Text.Encoding]::UTF8.GetString((Read-OpenWebRecoveryBytes (Join-Path $StateRoot 'installation.json') 1048576))|ConvertFrom-Json
 $runtime=Join-Path $StateRoot 'runtime.json'
 if($installed.Completed -isnot [bool] -or !$installed.Completed -or $installed.Version -cne $m.version -or (Get-OpenWebRecoveryHash (Read-OpenWebRecoveryBytes $runtime 1048576)) -cne $m.runtime_before_sha256 -or (Get-Acl -LiteralPath $runtime).Sddl -cne $m.runtime_sddl -or [int](Get-Item -LiteralPath $runtime -Force).Attributes -ne $m.runtime_attributes){throw 'Committed onboarding runtime identity differs.'}
 $manifest=[Text.Encoding]::UTF8.GetString((Read-OpenWebRecoveryBytes (Join-Path $m.bundle_path 'release-manifest.json') 4194304))|ConvertFrom-Json
 foreach($name in 'Install-Onboarding.ps1','Ensure-OnboardingUpgrade.ps1','Onboarding-Upgrade.Common.ps1','onboarding.py','onboarding.php','webhotel-onboarding.py','tenant-domains.py'){
  $p=Join-Path (Join-Path $Root 'tools') $name;$null=Assert-OpenWebRecoveryProtected $p
  if($manifest.files.$name -cnotmatch '^[a-f0-9]{64}$' -or (Get-OpenWebRecoveryHash (Read-OpenWebRecoveryBytes $p)) -cne $manifest.files.$name){throw 'Committed onboarding helpers differ from sealed source.'}
 }
 $source='openwebpbx-onboarding-v1:'+([IO.Path]::GetFileName($m.bundle_path))+':'+$j.recovery_entry.metadata_sha256+':'+$j.recovery_entry.launcher_sha256
 New-OpenWebCommittedOnboardingTask $Root $source
 $created=Get-OpenWebOnboardingTaskSnapshot
 if((Assert-OpenWebOnboardingTaskSnapshot $created $Root) -cne $source -or !$created.enabled){throw 'The committed onboarding task did not register exactly.'}
 return @{state='created';enabled=$true}
}
function Remove-OpenWebLegacyOnboardingTask {
 param([string]$Backup,$Record,[string]$Root,[string]$StateRoot,[string]$EngineRoot,[IO.FileStream]$MaintenanceLock)
 Assert-OpenWebRecoveryLock $MaintenanceLock $StateRoot
 if($Record.Tasks.PSObject.Properties['OpenWebPBX-Onboarding']){return}
 $task=Get-OpenWebOnboardingTaskSnapshot;if(!$task){return}
 # Legacy recovery never owned an untagged/pre-existing task. Preserve it,
 # including a task owned by another application, just as the old helper did.
 if($task.xml -isnot [string] -or $task.xml.Length -gt 65536 -or $task.xml -match '<!DOCTYPE'){throw 'The rollback task XML requires review.'}
 [xml]$xml=$task.xml;$ns=[Xml.XmlNamespaceManager]::new($xml.NameTable);$ns.AddNamespace('t','http://schemas.microsoft.com/windows/2004/02/mit/task');$tag=$xml.SelectSingleNode('/t:Task/t:RegistrationInfo/t:Source',$ns)
 if(!$tag -or !$tag.InnerText.StartsWith('openwebpbx-onboarding-v1:',[StringComparison]::Ordinal)){return}
 $source=Assert-OpenWebOnboardingTaskSnapshot $task $Root
 $entry=Get-OpenWebOnboardingSourceEntry $source $StateRoot
 $null=Get-OpenWebOnboardingUpgradeOrigin -Entry $entry -Root $Root -StateRoot $StateRoot -EngineRoot $EngineRoot -Backup $Backup
 Unregister-ScheduledTask -TaskName 'OpenWebPBX-Onboarding' -TaskPath '\' -Confirm:$false -ErrorAction Stop
 if(Get-OpenWebOnboardingTaskSnapshot){throw 'The owned postcommit onboarding task remains registered.'}
}
