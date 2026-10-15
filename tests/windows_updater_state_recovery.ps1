# Actual support inventory/restoration and pre-database RestorePbx statements.
# Fictional owned files only. The separate immutable-baseline control proves
# the actual Administrator -> SYSTEM replacement; this control injects that
# owner fault using the real raw file-security helper, without another task.
#Requires -Version 5.1
[CmdletBinding()]
param([string]$SourceRoot,[switch]$ExecuteReviewedFictionalControl)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';$checks=0
function Require([bool]$Value){if(!$Value){throw 'The isolated recovery control failed.'};$script:checks++}
Require ($env:OS -ceq 'Windows_NT' -and $PSVersionTable.PSEdition -ceq 'Desktop' -and $PSVersionTable.PSVersion.Major -eq 5 -and $ExecuteReviewedFictionalControl)
$env:PSModulePath="$env:SystemRoot\System32\WindowsPowerShell\v1.0\Modules;$env:ProgramFiles\WindowsPowerShell\Modules"
Require ($env:GITHUB_ACTIONS -ceq 'true' -and $env:RUNNER_ENVIRONMENT -ceq 'github-hosted' -and $env:RUNNER_OS -ceq 'Windows' -and $env:GITHUB_REPOSITORY -ceq 'embire2/openwebpbx' -and $env:RUNNER_TEMP)
$identity=[Security.Principal.WindowsIdentity]::GetCurrent();Require ($identity.User.Value -cne 'S-1-5-18' -and [Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
Require (!(Test-Path 'C:\OpenWebPBX') -and !(Test-Path "$env:ProgramData\OpenWebPBX\installation.json"))
if(!$SourceRoot){$SourceRoot=Join-Path (Split-Path $PSScriptRoot -Parent) 'packaging\windows'}
$tokens=$null;$errors=$null;$upgrade=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'Upgrade-OpenWebPBX.ps1'),[ref]$tokens,[ref]$errors);Require ($errors.Count -eq 0)
function UniqueFunction([string]$Name){$n=@($upgrade.FindAll({param($x)$x -is [Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -ceq $Name},$true));Require ($n.Count -eq 1);return $n[0]}
$write=UniqueFunction WriteState;$verify=UniqueFunction VerifyBackup;$restore=UniqueFunction RestorePbx
$types=@($upgrade.FindAll({param($x)$x -is [Management.Automation.Language.StringConstantExpressionAst] -and $x.Value.Contains('public static class OpenWebUpdateState')},$true));Require ($types.Count -eq 1);Add-Type -TypeDefinition $types[0].Value
. ([ScriptBlock]::Create($write.Extent.Text));$script:actualWrite=${function:WriteState};. ([ScriptBlock]::Create($verify.Extent.Text))
# Execute every original statement before tools restoration/database work.
# Never execute the upgrade entrypoint, service lifecycle or SQL restoration.
$statements=@($restore.Body.EndBlock.Statements);$stop=@(0..($statements.Count-1)|Where-Object {$statements[$_].Extent.Text.StartsWith('if(Test-Path "$Backup\tools")')});Require ($stop.Count -eq 1 -and $stop[0] -gt 0)
$prefix=[ScriptBlock]::Create(($statements[0..($stop[0]-1)]|ForEach-Object {$_.Extent.Text}) -join "`n")
. (Join-Path $SourceRoot 'Support-Recovery.ps1');. (Join-Path $SourceRoot 'File-Security.ps1')
$sourceHashes=@{};foreach($n in 'Upgrade-OpenWebPBX.ps1','Support-Recovery.ps1','File-Security.ps1'){$sourceHashes[$n]=(Get-FileHash -LiteralPath (Join-Path $SourceRoot $n)).Hash}
$scope=[Guid]::NewGuid().ToString('N');$work=Join-Path $env:RUNNER_TEMP ('ow-qa-metadata-recovery-'+$scope);Require (!(Test-Path -LiteralPath $work));[void][IO.Directory]::CreateDirectory($work)
$acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetAccessRuleProtection($true,$false);foreach($sid in 'S-1-5-18','S-1-5-32-544'){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))};Set-Acl -LiteralPath $work -AclObject $acl
$cases=0;$primary=$null
function Owned([string]$Path){$full=[IO.Path]::GetFullPath($Path);Require ($full.StartsWith($work+'\',[StringComparison]::OrdinalIgnoreCase));return $full}
function WriteBytes([string]$Path,[string]$Value){$full=Owned $Path;[void][IO.Directory]::CreateDirectory((Split-Path $full -Parent));[IO.File]::WriteAllBytes($full,[Text.UTF8Encoding]::new($false).GetBytes($Value))}
function Record([string]$Path){return @{hash=(Get-FileHash -LiteralPath $Path).Hash;sddl=(Get-Acl -LiteralPath $Path).Sddl}}
function OwnerFault([string]$Path){$d=[Security.AccessControl.RawSecurityDescriptor]::new((Get-Acl -LiteralPath $Path).Sddl);$d.Owner=[Security.Principal.SecurityIdentifier]::new('S-1-5-18');Set-OpenWebFileSddl -LiteralPath (Owned $Path) -Sddl $d.GetSddlForm('All')}
function WriteState([string]$Path,$Value){& $script:actualWrite $Path $Value;if($script:faultWriters -and $Path -in @("$private\installation.json","$private\updater-install.json")){OwnerFault $Path}}
# These unrelated platform actions are mocked, and never touch real IIS/tasks/SCM.
function Get-WindowsCapability{return [pscustomobject]@{State='NotPresent'}}
function Get-WebConfiguration{return $null}
function Get-ScheduledTask{return $null}
function Unregister-ScheduledTask{Require ($args -contains '-TaskName' -and @($args|Where-Object {$_ -in @('OpenWebPBX-Backups','OpenWebPBX Outgoing Mail','OpenWebPBX-Updater-Restart','OpenWebPBX-Cleanup')}).Count -eq 1)}
function Remove-WebConfigurationProperty{}
function sc.exe{Require ($args[0] -ceq 'config' -and $args[1] -ceq 'OpenWebPBXUpdater');$script:scmMockCalls++}
function CopyTree([string]$From,[string]$To,[switch]$Mirror){
 [void](Owned $From);[void](Owned $To);if(!(Test-Path -LiteralPath $From)){return};[void][IO.Directory]::CreateDirectory($To)
 if($Mirror){Get-ChildItem -LiteralPath $To -Force|Remove-Item -Recurse -Force}
 Get-ChildItem -LiteralPath $From -Force|Copy-Item -Destination $To -Recurse -Force
}
function SealBackup([string]$Backup){$files=@{};foreach($f in Get-ChildItem -LiteralPath $Backup -File -Recurse){if($f.Name -in @('backup-manifest.json','complete.json')){continue};$files[$f.FullName.Substring($Backup.Length+1).Replace('\','/')]=(Get-FileHash $f.FullName).Hash.ToLowerInvariant()};WriteState "$Backup\backup-manifest.json" @{schema=1;files=$files};WriteState "$Backup\complete.json" @{schema=1;integrity_sha256=(Get-FileHash "$Backup\backup-manifest.json").Hash.ToLowerInvariant()}}
try{
 foreach($case in 'existing','unusual','absent','old-schema'){
  $caseRoot=Join-Path $work $case;[void][IO.Directory]::CreateDirectory($caseRoot);$root=Join-Path $caseRoot 'program';$private=Join-Path $caseRoot 'state';$switch=Join-Path $caseRoot 'engine';$config=Join-Path $caseRoot 'config';$Backup=Join-Path $caseRoot 'backup';$package=Join-Path $caseRoot 'package'
  foreach($d in $root,$private,$switch,$config,$Backup,"$root\tools"){[void][IO.Directory]::CreateDirectory($d)}
  $script:faultWriters=$false;$script:scmMockCalls=0
  $label=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('WmHFvMOzxYLEhyDml6XmnKzoqp4='))
  WriteBytes "$package\engine\native-manifest.json" '{"files":{}}';WriteBytes "$private\installation.json" "{`n  `"Version`" : `"1.0.13`", `"Label`" : `"$label`"`n}`n";WriteBytes "$private\runtime.json" '{}';WriteBytes "$private\updater-original-startup.json" '{"marker":"original"}'
  if($case -ne 'absent'){WriteBytes "$private\updater-install.json" "{`n `"Version`" : `"1.0.13`", `"Executable`" : `"fictional.exe`"`n}`n"}
  $music="$private\storage\openweb-music";if($case -ne 'absent'){foreach($rate in 8000,16000,32000,48000){WriteBytes "$music\$rate\lofi-beat-loop-schmoop.wav" ('original-'+$rate)};WriteBytes "$music\README.md" 'original stock music notice';WriteBytes "$music\manifest.json" '{"fixture":"original"}'}
  if($case -eq 'unusual'){foreach($f in @("$private\installation.json","$private\updater-install.json")+@(Get-ChildItem $music -File -Recurse|ForEach-Object {$_.FullName})){$a=Get-Acl -LiteralPath $f;$a.SetAccessRuleProtection($true,$true);$a.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-19'),'Read','Allow'));Set-Acl -LiteralPath $f -AclObject $a}}
  $before=@{};foreach($f in @("$private\installation.json","$private\updater-install.json")+@(Get-ChildItem $music -File -Recurse -ErrorAction SilentlyContinue|ForEach-Object {$_.FullName})){if(Test-Path -LiteralPath $f){$before[$f]=Record $f}}
  $beforeDirectories=@{};if(Test-Path -LiteralPath $music){foreach($d in @($music)+@(Get-ChildItem $music -Directory -Recurse|ForEach-Object {$_.FullName})){$beforeDirectories[$d]=(Get-Acl -LiteralPath $d).Sddl}}
  Save-OpenWebSupport -Backup $Backup -PackageRoot $package -Root $root -StateRoot $private -EngineRoot $switch
  foreach($name in 'installation.json','runtime.json','updater-install.json'){if(Test-Path "$private\$name"){Copy-Item -LiteralPath "$private\$name" -Destination "$Backup\$name"}};WriteBytes "$Backup\database.dump" 'fictional-only'
  if($case -eq 'old-schema'){$r=Get-Content "$Backup\support-state.json" -Raw -Encoding UTF8|ConvertFrom-Json;foreach($name in 'installation.json','updater-install.json'){$r.Files.PSObject.Properties.Remove("$private\$name");$r.Acls.PSObject.Properties.Remove("$private\$name")};$r.Directories.PSObject.Properties.Remove('openweb-music');foreach($name in @($r.Acls.PSObject.Properties.Name)){if($name.StartsWith($music,[StringComparison]::OrdinalIgnoreCase)){$r.Acls.PSObject.Properties.Remove($name)}};WriteState "$Backup\support-state.json" $r}
  SealBackup $Backup
  $script:faultWriters=$true;WriteState "$private\installation.json" @{Version='1.0.14'};WriteState "$private\updater-install.json" @{Version='1.0.14';Executable='fictional-new.exe'};WriteBytes "$private\updater-original-startup.json" '{"marker":"fault"}'
  foreach($rate in 8000,16000,32000,48000){WriteBytes "$music\$rate\lofi-beat-loop-schmoop.wav" ('fault-'+$rate);OwnerFault "$music\$rate\lofi-beat-loop-schmoop.wav"}
  foreach($d in $beforeDirectories.Keys){OwnerFault $d}
  $recording="$private\storage\recordings\new-recording.wav";WriteBytes $recording 'new unrelated recording';$newRecording=Record $recording
  WriteBytes "$root\tools\Remove-Updater.ps1" '$marker=Get-Content "$private\updater-original-startup.json" -Raw|ConvertFrom-Json;if($marker.marker -cne ''original''){throw ''Original startup dependency was not restored.''};[IO.File]::WriteAllText((Join-Path $private ''fixture-removal-observed.txt''),''original'')'
  . $prefix
  Require ((Record $recording).hash -ceq $newRecording.hash -and (Record $recording).sddl -ceq $newRecording.sddl)
  if($case -eq 'old-schema'){
   $restoredInstallation=Get-Content "$private\installation.json" -Raw -Encoding UTF8|ConvertFrom-Json;$restoredUpdater=Get-Content "$private\updater-install.json" -Raw -Encoding UTF8|ConvertFrom-Json
   Require ($restoredInstallation.Version -ceq '1.0.13' -and $restoredInstallation.Label -ceq $label -and $restoredUpdater.Version -ceq '1.0.13' -and $restoredUpdater.Executable -ceq 'fictional.exe');Require ($script:scmMockCalls -eq 1)
  }else{
   foreach($path in $before.Keys){$after=Record $path;Require ($after.hash -ceq $before[$path].hash -and $after.sddl -ceq $before[$path].sddl)}
   foreach($d in $beforeDirectories.Keys){Require ((Get-Acl -LiteralPath $d).Sddl -ceq $beforeDirectories[$d])}
   if($case -eq 'absent'){Require (!(Test-Path "$private\updater-install.json") -and !(Test-Path $music) -and (Get-Content "$private\fixture-removal-observed.txt" -Raw) -ceq 'original' -and $script:scmMockCalls -eq 0)}else{Require ($script:scmMockCalls -eq 1)}
  }
  $cases++
 }
 foreach($n in $sourceHashes.Keys){Require ((Get-FileHash -LiteralPath (Join-Path $SourceRoot $n)).Hash -ceq $sourceHashes[$n])}
}catch{$primary=$_}finally{
 try{$entries=@(Get-ChildItem -LiteralPath $work -Recurse -Force);if(@($entries|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){if(!$primary){$primary='Unexpected owned-fixture reparse point.'}}else{Remove-Item -LiteralPath $work -Recurse -Force}}catch{if(!$primary){$primary=$_}}
}
if($primary){
 $failure=[ordered]@{schema=1;state='failed';scope='owned_native_files_support_and_pre_database_restore';active_case='preparation';error_type='Other';source_basename='unknown';source_line=0}
 if($case -in @('existing','unusual','absent','old-schema')){$failure.active_case=$case}
 if($primary.Exception -and $primary.Exception.GetType().Name -in @('RuntimeException','MethodInvocationException','UnauthorizedAccessException','IOException','ItemNotFoundException','ParameterBindingException','ParentContainsErrorRecordException')){$failure.error_type=$primary.Exception.GetType().Name}
 if($primary.InvocationInfo){$base=[IO.Path]::GetFileName($primary.InvocationInfo.ScriptName);if($base -in @('windows_updater_state_recovery.ps1','Support-Recovery.ps1','File-Security.ps1','Upgrade-OpenWebPBX.ps1')){$failure.source_basename=$base;if($primary.InvocationInfo.ScriptLineNumber -ge 1 -and $primary.InvocationInfo.ScriptLineNumber -le 10000){$failure.source_line=$primary.InvocationInfo.ScriptLineNumber}}}
 $failure|ConvertTo-Json -Compress;exit 1
}
Require (!(Test-Path -LiteralPath $work));[ordered]@{schema=1;state='passed';checks=$checks;cases=$cases;scope='owned_native_files_support_and_pre_database_restore';system_owner_fault_injected=$true;old_schema_missing_acl_recovery='unqualified';actual_database_or_scm_or_iis_or_scheduled_task_access=$false;fixture_removed=$true}|ConvertTo-Json -Compress
