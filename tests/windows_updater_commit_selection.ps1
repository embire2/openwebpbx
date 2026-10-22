#Requires -RunAsAdministrator
#Requires -Version 5.1
# Actual NTFS/image locks and process interruption; SCM calls are explicit doubles.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$WarningPreference='SilentlyContinue';Set-StrictMode -Version Latest;$script:checks=0
if($PSVersionTable.PSEdition -ne 'Desktop'){throw 'Native Windows PowerShell is required.'}
$guardOutput=& (Join-Path $SourceRoot 'tests\windows_updater_commit_selection_controls.ps1') -SourceRoot $SourceRoot
$guardSucceeded=$?
$guardOutput=@($guardOutput)
if(!$guardSucceeded -or $guardOutput.Count -ne 1 -or $guardOutput[0] -cnotmatch '^PASS ([1-9][0-9]{0,4}) actual commit ordering/irreversible failure/typed completion/owned boot-driver and external rollback stop controls$' -or [int]$Matches[1] -lt 52){throw 'The actual commit/owned-service guards did not pass.'};$guardChecks=[int]$Matches[1]
function Assert([bool]$Value){if(!$Value){throw ('Updater commit control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
function Refuses([scriptblock]$Action){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Assert $failed}
function Parse([string]$Path){$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$t,[ref]$e);Assert ($e.Count -eq 0);return $ast}
function Definition($Ast,[string]$Name){$nodes=@($Ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Name},$true));Assert ($nodes.Count -eq 1);return $nodes[0].Extent.Text}
. (Join-Path $SourceRoot 'packaging\windows\UpgradeRecovery.Common.ps1')
. (Join-Path $SourceRoot 'packaging\windows\File-Security.ps1')
$native=Parse (Join-Path $SourceRoot 'tests\windows_upgrade_recovery.ps1')
foreach($name in 'WriteText','Json','Case','NewEntry','Pin','Publish','Complete','Child','Finish'){Invoke-Expression (Definition $native $name)}
$main=Parse (Join-Path $SourceRoot 'packaging\windows\Upgrade-OpenWebPBX.ps1');$support=Parse (Join-Path $SourceRoot 'packaging\windows\Support-Recovery.ps1');$installer=Parse (Join-Path $SourceRoot 'packaging\windows\Install-Updater.ps1')
Invoke-Expression (Definition $main 'CopyTree');Invoke-Expression (Definition $support 'Assert-OpenWebUpdaterSlotsRestored')
$directoryLoop=@($support.FindAll({param($n)$n -is [Management.Automation.Language.ForEachStatementAst] -and $n.Condition.Extent.Text -ceq '$record.Directories.PSObject.Properties'},$true));Assert ($directoryLoop.Count -eq 1)
$nativeState=@($main.FindAll({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.StartsWith("if(-not ('OpenWebUpdateState'")},$true));Assert ($nativeState.Count -eq 1)
$work=Join-Path ([IO.Path]::GetTempPath()) ('openweb-updater-commit-'+[Guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($work);Set-OpenWebRecoveryPrivate $work -Directory
$fixtureCompleted=$false;$children=[Collections.Generic.List[Diagnostics.Process]]::new();$assembly=Join-Path $work 'fixture-version20.dll'
Add-Type -TypeDefinition ('using System.Reflection;[assembly:AssemblyVersion("1.0.20.0")]public sealed class Fixture'+[Guid]::NewGuid().ToString('N')+'{}') -OutputAssembly $assembly -OutputType Library
Set-OpenWebRecoveryPrivate $assembly
function ServiceMocks {
 @'
function Get-CimInstance { [CmdletBinding()]param([string]$ClassName,[string]$Filter)
 if($ClassName -cne 'Win32_Service' -or $Filter -cne "Name='OpenWebPBXUpdater'"){throw 'Unexpected service adapter request.'}
 $value=Get-Content -LiteralPath $script:serviceFile -Raw|ConvertFrom-Json
 if($value.exists){return [pscustomobject]@{PathName=$value.path;StartName=$value.identity;StartMode='Auto';State='Stopped';ProcessId=0}}
}
function sc.exe {param([Parameter(ValueFromRemainingArguments=$true)][string[]]$ServiceArguments)
 $script:serviceWrites++
 if($script:failSelection){$global:LASTEXITCODE=5;return}
 if($ServiceArguments[0] -ceq 'config'){
  $at=[array]::IndexOf($ServiceArguments,'binPath=');if($at -lt 0){throw 'Unexpected service selector.'}
  $value=Get-Content -LiteralPath $script:serviceFile -Raw|ConvertFrom-Json;$value.path=$ServiceArguments[$at+1].Trim('"');Json $script:serviceFile $value
 }elseif($ServiceArguments[0] -cnotin 'failure','failureflag'){throw 'Unexpected native adapter command.'}
 $global:LASTEXITCODE=0
}
function New-Service { [CmdletBinding()]param([string]$Name,[string]$BinaryPathName,[string]$DisplayName,[string]$StartupType,[string]$DependsOn)
 if($Name -cne 'OpenWebPBXUpdater' -or $DependsOn -cne 'OpenWebPBX-Database' -or $StartupType -cne 'Automatic'){throw 'Unexpected service creation.'}
 $script:serviceCreates++;Json $script:serviceFile @{exists=$true;path=$BinaryPathName.Trim('"');identity='LocalSystem'}
}
'@
}
Invoke-Expression (ServiceMocks)
function Prepared([bool]$Existing=$true,[string]$DllVersion='1.0.20'){
 $c=Case
 foreach($name in 'Restore-Gates.ps1','Support-Recovery.ps1','Web-Readiness.ps1','PhpRuntime.Common.ps1'){[IO.File]::WriteAllBytes((Join-Path $c.Package $name),[IO.File]::ReadAllBytes((Join-Path $SourceRoot ('packaging\windows\'+$name))))}
 $old=Join-Path $c.Root 'updater\slots\1.0.6\OpenWebPbx.Updater.exe';$new=Join-Path $c.Root 'updater\slots\1.0.20';$null=[IO.Directory]::CreateDirectory((Split-Path $old));Set-OpenWebRecoveryPrivate (Split-Path $old) -Directory
 Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\PING.EXE') -Destination $old;Set-OpenWebRecoveryPrivate $old
 $null=[IO.Directory]::CreateDirectory($new);Set-OpenWebRecoveryPrivate $new -Directory
 Copy-Item -LiteralPath $old -Destination (Join-Path $new 'OpenWebPbx.Updater.exe');Set-OpenWebRecoveryPrivate (Join-Path $new 'OpenWebPbx.Updater.exe')
 $selectedAssembly=$assembly
 if($DllVersion -cne '1.0.20'){$selectedAssembly=Join-Path $c.Base 'wrong-version.dll';Add-Type -TypeDefinition ('using System.Reflection;[assembly:AssemblyVersion("'+$DllVersion+'.0")]public sealed class Fixture'+[Guid]::NewGuid().ToString('N')+'{}') -OutputAssembly $selectedAssembly -OutputType Library}
 Copy-Item -LiteralPath $selectedAssembly -Destination (Join-Path $new 'OpenWebPbx.Updater.dll');Set-OpenWebRecoveryPrivate (Join-Path $new 'OpenWebPbx.Updater.dll')
 $originalTools=Join-Path $c.Backup 'tools';$null=[IO.Directory]::CreateDirectory($originalTools);Copy-Item (Join-Path $c.Root 'tools\Upgrade-OpenWebPBX.ps1') $originalTools
 if($Existing){WriteText (Join-Path $c.Backup 'updater-install.json') (@{Version='1.0.6';Executable=$old}|ConvertTo-Json)}
 $sealed=Get-Content (Join-Path $c.Backup 'backup-manifest.json') -Raw|ConvertFrom-Json
 foreach($name in 'updater-install.json','tools/Upgrade-OpenWebPBX.ps1'){if(Test-Path (Join-Path $c.Backup $name)){$sealed.files|Add-Member NoteProperty $name (Get-OpenWebRecoveryHash (Read-OpenWebRecoveryBytes (Join-Path $c.Backup $name)))}}
 Json (Join-Path $c.Backup 'backup-manifest.json') $sealed
 Json (Join-Path $c.Backup 'complete.json') @{version='1.0.6';integrity_sha256=(Get-OpenWebRecoveryHash (Read-OpenWebRecoveryBytes (Join-Path $c.Backup 'backup-manifest.json')))}
 $manifest=@{version='1.0.20';files=@{}}
 foreach($file in Get-ChildItem -LiteralPath $c.Package -File|Where-Object Name -cne 'release-manifest.json'){$manifest.files[$file.Name]=Get-OpenWebRecoveryHash (Read-OpenWebRecoveryBytes $file.FullName)}
 foreach($name in 'OpenWebPbx.Updater.exe','OpenWebPbx.Updater.dll'){$manifest.files['updater/'+$name]=Get-OpenWebRecoveryHash (Read-OpenWebRecoveryBytes (Join-Path $new $name))}
 Json (Join-Path $c.Package 'release-manifest.json') $manifest
 $c|Add-Member NoteProperty Slot $new;$c|Add-Member NoteProperty OldExecutable $old
 $script:serviceFile=Join-Path $c.Base 'scm-double.json';Json $script:serviceFile @{exists=$Existing;path=$old;identity='LocalSystem'};$c|Add-Member NoteProperty ServiceFile $script:serviceFile
 $script:serviceWrites=0;$script:serviceCreates=0;$script:failSelection=$false
 return $c
}
function InstalledClosure($c,$entry){foreach($name in 'Upgrade-OpenWebPBX.ps1','UpgradeRecovery.Common.ps1','Restore-Gates.ps1','Support-Recovery.ps1','File-Security.ps1','Web-Readiness.ps1','Dtls.Common.ps1','PhoneHealth-Security.ps1','PhpRuntime.Common.ps1','Write-PrivateState.ps1','check-call-engine.php'){Copy-Item (Join-Path $entry.bundle_path $name) (Join-Path $c.Root ('tools\'+$name)) -Force}}
function Finalize($c,$entry,$lock){Complete-OpenWebCommittedUpgrade -Entry $entry -Root $c.Root -StateRoot $c.State -EngineRoot $c.Engine -MaintenanceLock $lock}
function Commit($c,$entry){$j=Get-Content $c.Journal -Raw|ConvertFrom-Json;$j.state='completed';Json $c.Journal $j}
try{
 $stage=@($installer.FindAll({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -ceq '!$DeferServiceSelection'},$true));Assert ($stage.Count -eq 1)
 $c=Prepared $false;$DeferServiceSelection=$true;$PackageRoot=$c.Package;$root=$c.Root;$executable=Join-Path $c.Slot 'OpenWebPbx.Updater.exe';$existing=$null
 & ([scriptblock]::Create($stage[0].Extent.Text));Assert ($script:serviceCreates -eq 0 -and $script:serviceWrites -eq 0 -and !(Get-Content $c.ServiceFile -Raw|ConvertFrom-Json).exists)
 $DeferServiceSelection=$false;& ([scriptblock]::Create($stage[0].Extent.Text));Assert ($script:serviceCreates -eq 1)
 foreach($exists in $true,$false){
  $c=Prepared $exists;$lock=[IO.File]::Open((Join-Path $c.State 'upgrade.lock'),'OpenOrCreate','ReadWrite','None')
  try{
   $entry=NewEntry $c $lock;Pin $c $entry;Publish $c $entry $lock;InstalledClosure $c $entry
   Json (Join-Path $c.State 'installation.json') @{Version='1.0.20';Completed=$true};Json (Join-Path $c.State 'updater-install.json') @{Version='1.0.20';Executable=(Join-Path $c.Slot 'OpenWebPbx.Updater.exe')}
   Refuses {Finalize $c $entry $lock};Assert ($script:serviceWrites -eq 0 -and $script:serviceCreates -eq 0)
   Complete $c $entry $lock Success;Refuses {Finalize $c $entry $lock};Assert ($script:serviceWrites -eq 0)
   Commit $c $entry;$script:failSelection=$true;Refuses {Finalize $c $entry $lock};Assert ((Get-Content $c.Journal -Raw|ConvertFrom-Json).state -ceq 'completed');$script:failSelection=$false
   Finalize $c $entry $lock;Assert ((Get-Content $c.ServiceFile -Raw|ConvertFrom-Json).path -ceq (Join-Path $c.Slot 'OpenWebPbx.Updater.exe'))
   $created=$script:serviceCreates;Finalize $c $entry $lock;Assert ($script:serviceCreates -eq $created -and $created -eq $(if($exists){0}else{1}))
   foreach($bad in 'extra','missing','changed','type'){
    $path=if($bad -ceq 'extra'){Join-Path $c.Slot 'unexpected'}else{Join-Path $c.Slot 'OpenWebPbx.Updater.dll'}
    $saved=if(Test-Path $path){[IO.File]::ReadAllBytes($path)}else{$null}
    if($bad -ceq 'extra'){$null=[IO.Directory]::CreateDirectory($path)}elseif($bad -ceq 'changed'){[IO.File]::AppendAllText($path,'CHANGED')}else{[IO.File]::Delete($path);if($bad -ceq 'type'){$null=[IO.Directory]::CreateDirectory($path)}}
    $writes=$script:serviceWrites;Refuses {Finalize $c $entry $lock};Assert ($script:serviceWrites -eq $writes)
    if(Test-Path $path){Remove-Item -LiteralPath $path -Recurse -Force};if($saved){[IO.File]::WriteAllBytes($path,$saved);Set-OpenWebRecoveryPrivate $path}
   }
   foreach($foreign in 'C:\foreign\OpenWebPbx.Updater.exe',($c.OldExecutable+' --foreign')){$writes=$script:serviceWrites;Refuses {Set-OpenWebUpdaterServiceSelection -Root $c.Root -Executable (Join-Path $c.Slot 'OpenWebPbx.Updater.exe') -AllowedPreviousExecutable @($foreign)};Assert ($script:serviceWrites -eq $writes)}
  }finally{$lock.Dispose()}
 }
 $c=Prepared $true '1.0.19';$lock=[IO.File]::Open((Join-Path $c.State 'upgrade.lock'),'OpenOrCreate','ReadWrite','None')
 try{
  $entry=NewEntry $c $lock;Pin $c $entry;Publish $c $entry $lock;InstalledClosure $c $entry;Complete $c $entry $lock Success
  Json (Join-Path $c.State 'installation.json') @{Version='1.0.20';Completed=$true};Json (Join-Path $c.State 'updater-install.json') @{Version='1.0.20';Executable=(Join-Path $c.Slot 'OpenWebPbx.Updater.exe')};Commit $c $entry
  Refuses {Finalize $c $entry $lock};Assert ($script:serviceWrites -eq 0)
 }finally{$lock.Dispose()}
 # Reset-before-completed recovery rebinds actual dependencies to the bundle.
 $c=Prepared;$lock=[IO.File]::Open((Join-Path $c.State 'upgrade.lock'),'OpenOrCreate','ReadWrite','None')
 try{
  $entry=NewEntry $c $lock;Pin $c $entry;Publish $c $entry $lock;InstalledClosure $c $entry;Complete $c $entry $lock Success
  $journal=Get-Content $c.Journal -Raw|ConvertFrom-Json;$root=$c.Root;$private=$c.State;$switch=$c.Engine;$script:upgradeRecoveryEntry=$entry
  $rebind=@($main.FindAll({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -ceq "`$journal.PSObject.Properties['recovery_entry']"},$true));Assert ($rebind.Count -eq 1)
  . ([scriptblock]::Create($rebind[0].Extent.Text))
  Assert ($script:recoveryCodeRoot -ceq $entry.bundle_path)
  CopyTree (Join-Path $c.Backup 'tools') (Join-Path $c.Root 'tools') -Mirror
  foreach($name in 'File-Security.ps1','check-call-engine.php','PhpRuntime.Common.ps1','Support-Recovery.ps1','UpgradeRecovery.Common.ps1'){Assert (!(Test-Path (Join-Path $c.Root ('tools\'+$name))))}
  Assert ((Get-Command Write-OpenWebRecoveryRuntime).ScriptBlock.File -ieq (Join-Path $entry.bundle_path 'UpgradeRecovery.Common.ps1'))
  . (Join-Path $script:recoveryCodeRoot 'PhpRuntime.Common.ps1');Assert ((Get-OpenWebPhpRuntimeSource).Version -ceq '8.4.27')
  Complete $c $entry $lock Rollback;Assert ((Get-OpenWebRecoveryHash (Read-OpenWebRecoveryBytes $c.Runtime)) -ceq (Get-OpenWebRecoveryHash (Read-OpenWebRecoveryBytes (Join-Path $entry.bundle_path 'runtime.before.json'))))
 }finally{$lock.Dispose()}
 # Kill real owned children on both sides of the durable commit/selection.
 foreach($position in 'before_commit','after_commit','after_selection'){
  $c=Prepared;$lock=[IO.File]::Open((Join-Path $c.State 'upgrade.lock'),'OpenOrCreate','ReadWrite','None')
  try{
   $entry=NewEntry $c $lock;Pin $c $entry;Publish $c $entry $lock;InstalledClosure $c $entry
   Json (Join-Path $c.State 'installation.json') @{Version='1.0.20';Completed=$true};Json (Join-Path $c.State 'updater-install.json') @{Version='1.0.20';Executable=(Join-Path $c.Slot 'OpenWebPbx.Updater.exe')}
   Complete $c $entry $lock Success
  }finally{$lock.Dispose()}
  $input=Join-Path $c.Base 'interrupt-input.json';Json $input @{case=$c;entry=$entry;position=$position}
  $body=@'
param([string]$InputPath)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$r=Get-Content -LiteralPath $InputPath -Raw|ConvertFrom-Json;$c=$r.case;$entry=$r.entry
. (Join-Path $entry.bundle_path 'UpgradeRecovery.Common.ps1')
. (Join-Path $entry.bundle_path 'File-Security.ps1')
function Json([string]$Path,$Value){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 32),[Text.UTF8Encoding]::new($false))}
__MOCKS__
__NATIVE_STATE__
__WRITE_STATE__
__SAVE_JOURNAL__
$root=$c.Root;$private=$c.State;$switch=$c.Engine;$backup=$c.Backup;$version='1.0.20';$previousVersion='1.0.6';$journalPath=$c.Journal
$script:serviceFile=$c.ServiceFile;$script:serviceWrites=0;$script:serviceCreates=0;$script:failSelection=$false
$script:upgradeRecoveryEntry=$entry;$script:managerTasks=@();$script:operatorRollback=$false;$script:upgradeFinalizationPhase=$null;$script:upgradeFinalizationFailed=$false
$lock=[IO.File]::Open((Join-Path $c.State 'upgrade.lock'),'OpenOrCreate','ReadWrite','None')
SaveJournal 'validating'
if($r.position -cne 'before_commit'){SaveJournal 'completed'}
if($r.position -ceq 'after_selection'){Complete-OpenWebCommittedUpgrade -Entry $entry -Root $root -StateRoot $private -EngineRoot $switch -MaintenanceLock $lock}
[IO.File]::WriteAllText((Join-Path $c.Base 'commit-ready.json'),($r.position|ConvertTo-Json))
while($true){Start-Sleep -Milliseconds 100}
'@
  $body=$body.Replace('__MOCKS__',(ServiceMocks)).Replace('__NATIVE_STATE__',$nativeState[0].Extent.Text).Replace('__WRITE_STATE__',(Definition $main 'WriteState')).Replace('__SAVE_JOURNAL__',(Definition $main 'SaveJournal'))
  $path=Join-Path $c.Base 'interrupt.ps1';WriteText $path $body
  $child=Child (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$path,'-InputPath',$input) $c.Base
  $ready=Join-Path $c.Base 'commit-ready.json';$deadline=[DateTime]::UtcNow.AddSeconds(45)
  while(!(Test-Path $ready) -and !$child.Process.HasExited -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 50}
  Assert ((Test-Path $ready) -and !$child.Process.HasExited)
  $child.Process.Kill();Assert ($child.Process.WaitForExit(10000));$null=Finish $child
  $lock=[IO.File]::Open((Join-Path $c.State 'upgrade.lock'),'OpenOrCreate','ReadWrite','None')
  try{
   $journal=Get-Content $c.Journal -Raw|ConvertFrom-Json;$selection=Get-Content $c.ServiceFile -Raw|ConvertFrom-Json
   if($position -ceq 'before_commit'){
    Assert ($journal.state -ceq 'validating' -and $selection.path -ceq $c.OldExecutable)
    Refuses {Finalize $c $entry $lock}
    Ensure-OpenWebUpgradeRecoveryPublished -Entry $entry -Root $c.Root -StateRoot $c.State -EngineRoot $c.Engine -MaintenanceLock $lock
    Assert ((Get-Content $c.Runtime -Raw|ConvertFrom-Json).Updater.Helper -ceq (Join-Path $entry.bundle_path 'recovery-launcher.ps1'))
   }else{
    Assert ($journal.state -ceq 'completed')
    Assert ($selection.path -ceq $(if($position -ceq 'after_selection'){Join-Path $c.Slot 'OpenWebPbx.Updater.exe'}else{$c.OldExecutable}))
    Finalize $c $entry $lock;Finalize $c $entry $lock
    Assert ((Get-Content $c.ServiceFile -Raw|ConvertFrom-Json).path -ceq (Join-Path $c.Slot 'OpenWebPbx.Updater.exe'))
    Assert ((Get-Content $c.Journal -Raw|ConvertFrom-Json).state -ceq 'completed' -and (Test-Path $c.Slot))
   }
  }finally{$lock.Dispose()}
 }
 # Real running PE: retain the old silent exit3 negative, then exercise product
 # postcondition. It refuses without killing that image; retry after exact exit.
 $c=Prepared;$Backup=$c.Backup;$target=Join-Path $c.Root 'updater\slots';$beforeSlots=Join-Path $Backup 'updater-slots\1.0.6';$null=[IO.Directory]::CreateDirectory($beforeSlots);Copy-Item $c.OldExecutable $beforeSlots;[IO.File]::WriteAllText((Join-Path $beforeSlots 'copied-witness.fixture'),'COPY-WITNESS')
 function Check-SupportPath([string]$Path){Assert ([IO.Path]::GetFullPath($Path) -ieq $target);return $Path}
 $record=[pscustomobject]@{Directories=[pscustomobject]@{'updater-slots'=[pscustomobject]@{Path=$target;Exists=$true}}}
 $image=Child (Join-Path $c.Slot 'OpenWebPbx.Updater.exe') @('-t','127.0.0.1') $c.Base
 Assert (!$image.Process.WaitForExit(1000));CopyTree (Join-Path $Backup 'updater-slots') $target -Mirror
 Assert ($LASTEXITCODE -eq 3 -and (Test-Path (Join-Path $c.Slot 'OpenWebPbx.Updater.exe')) -and !$image.Process.HasExited)
 Refuses {& ([scriptblock]::Create($directoryLoop[0].Extent.Text))};Assert (!$image.Process.HasExited)
 $image.Process.Kill();Assert ($image.Process.WaitForExit(10000));$null=Finish $image
 & ([scriptblock]::Create($directoryLoop[0].Extent.Text));Assert (!(Test-Path $c.Slot))
 $fixtureCompleted=$true
 [ordered]@{schema=1;producer='windows_updater_commit_selection.ps1';state='passed';actual_native_windows=$true;checks=$checks;guard_checks=$guardChecks;service_adapter_double=$true;actual_installed_scm=$false;slot_assembly_fixture=$true;actual_running_image_lock=$true;old_silent_exit3_proven=$true;exact_mirror_refusal_retry=$true;completed_finalizer_idempotent=$true;actual_commit_interruption_positions=3;before_commit_old_scm=$true;after_commit_resume=$true;after_selection_idempotent=$true;absent_creation_deferred=$true;legacy_missing_dependency_recovery=$true;installed_server_changed=$false}|ConvertTo-Json -Compress
}finally{
 foreach($p in $children){try{if(!$p.HasExited){$p.Kill();$null=$p.WaitForExit(10000)}}finally{$p.Dispose()}}
 if($fixtureCompleted){Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction Stop}else{[Console]::Error.WriteLine('Failed private fixture retained: '+$work)}
}
