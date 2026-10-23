# Windows CDR paths, narrowly scoped service access and durable importer holds.
# Callers own upgrade.lock; no call-record bytes are copied, imported or removed.
. (Join-Path $PSScriptRoot 'UpgradeRecovery.Common.ps1')
. (Join-Path $PSScriptRoot 'Write-PrivateState.ps1')
function Assert-OpenWebCallRecordOrdinary {
 param([string]$Path,[switch]$Directory)
 $full=Assert-OpenWebRecoveryOrdinary -Path $Path -Directory:$Directory
 if(!$Directory){
  Initialize-OpenWebUpgradeRecoveryNative
  # A read binds the ordinary single-link node before any permission change.
  # XML bytes are not needed here; use the existing native handle identity check.
  $h=[IO.File]::Open($full,'Open','Read','ReadWrite')
  try{[OpenWebPbx.UpgradeRecoveryNativeV1]::LockIdentity($h.SafeFileHandle)}finally{$h.Dispose()}
 }
 return $full
}
function Assert-OpenWebCallRecordLock {
 param([string]$StateRoot,[IO.FileStream]$MaintenanceLock,[switch]$ExternalLockHeld)
 if(!$ExternalLockHeld){Assert-OpenWebRecoveryLock -MaintenanceLock $MaintenanceLock -StateRoot $StateRoot;return}
 $path=Assert-OpenWebRecoveryOrdinary (Join-Path $StateRoot 'upgrade.lock')
 Initialize-OpenWebUpgradeRecoveryNative
 if(![OpenWebPbx.UpgradeRecoveryNativeV1]::Exclusive($path)){throw 'The call-record controller requires its parent exclusive maintenance lock.'}
}
function Add-OpenWebCallRecordRight {
 param([string]$Path,[Security.AccessControl.FileSystemRights]$Rights,[Security.AccessControl.InheritanceFlags]$Inheritance=[Security.AccessControl.InheritanceFlags]::None,[Security.AccessControl.PropagationFlags]$Propagation=[Security.AccessControl.PropagationFlags]::None)
 $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
 $null=Assert-OpenWebCallRecordOrdinary $Path -Directory:$item.PSIsContainer
 $acl=Get-Acl -LiteralPath $Path -ErrorAction Stop
 foreach($existing in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){
  if($existing.IdentityReference.Value -cne 'S-1-5-19' -or $existing.AccessControlType -ne 'Allow' -or (([int64]$existing.FileSystemRights -band [int64]$Rights) -ne [int64]$Rights)){continue}
  if(!$item.PSIsContainer -and !($existing.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)){return}
  if($item.PSIsContainer -and $existing.InheritanceFlags -eq $Inheritance -and $existing.PropagationFlags -eq $Propagation){return}
 }
 $rule=[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-19'),$Rights,$Inheritance,$Propagation,[Security.AccessControl.AccessControlType]::Allow)
 $null=$acl.AddAccessRule($rule);Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}
function Get-OpenWebCallRecordPlan {
 param([string]$PackageRoot,[string]$Root,[string]$EngineRoot)
 $helper=Assert-OpenWebRecoveryProtected (Join-Path $PackageRoot 'windows-log.php')
 $php=Assert-OpenWebRecoveryOrdinary (Join-Path $Root 'php\php.exe')
 $ini=Assert-OpenWebRecoveryProtected (Join-Path $Root 'php\php.ini')
 $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$php
 $start.Arguments='-c "'+$ini+'" "'+$helper+'" "'+(Join-Path $Root 'web')+'" describe';$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $p=[Diagnostics.Process]::new();$p.StartInfo=$start
 try{
  if(!$p.Start()){throw 'The call-record directory reader did not start.'}
  $out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync()
  if(!$p.WaitForExit(15000)){try{$p.Kill()}catch{};throw 'The call-record directory reader exceeded its deadline.'}
  if(!$out.Wait(2000) -or !$err.Wait(2000) -or $p.ExitCode -ne 0 -or $out.Result.Length -gt 32768 -or $err.Result.Length -gt 32768){throw 'The call-record directory reader refused the configured directory.'}
  $plan=$out.Result|ConvertFrom-Json -ErrorAction Stop
 }finally{$p.Dispose()}
 if($plan.log_directory -isnot [string] -or $plan.spool_directory -isnot [string] -or $plan.owned_log_directory -isnot [string] -or $plan.setting_present -isnot [bool] -or $plan.custom -isnot [bool]){throw 'The call-record directory plan is invalid.'}
 $owned=[IO.Path]::GetFullPath((Join-Path $EngineRoot 'log'))
 if(![IO.Path]::GetFullPath($plan.owned_log_directory).Equals($owned,[StringComparison]::OrdinalIgnoreCase)){throw 'The call-record directory plan does not belong to this call engine.'}
 $log=[IO.Path]::GetFullPath($plan.log_directory)
 $logExists=Test-Path -LiteralPath $log
 if($logExists){$null=Assert-OpenWebRecoveryOrdinary $log -Directory}
 elseif($plan.custom -or !$log.Equals($owned,[StringComparison]::OrdinalIgnoreCase)){throw 'The configured custom call-engine log directory is unavailable.'}
 else{$null=Assert-OpenWebRecoveryOrdinary $EngineRoot -Directory}
 $spool=[IO.Path]::GetFullPath((Join-Path $log 'xml_cdr'))
 if(!$spool.Equals([IO.Path]::GetFullPath($plan.spool_directory),[StringComparison]::OrdinalIgnoreCase)){throw 'The native call-record spool path is ambiguous.'}
 return @{Path=$spool;Log=$log;LogExists=[bool]$logExists;Custom=$plan.custom}
}
function Get-OpenWebCallRecordAccessSnapshot {
 param([string]$PackageRoot,[string]$Root,[string]$StateRoot,[string]$EngineRoot,[IO.FileStream]$MaintenanceLock)
 Assert-OpenWebCallRecordLock -StateRoot $StateRoot -MaintenanceLock $MaintenanceLock
 $configRoot=Assert-OpenWebRecoveryOrdinary (Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($StateRoot))) 'fusionpbx') -Directory
 $configFile=Assert-OpenWebCallRecordOrdinary (Join-Path $configRoot 'config.conf')
 $plan=Get-OpenWebCallRecordPlan -PackageRoot $PackageRoot -Root $Root -EngineRoot $EngineRoot
 $path=$plan.Path;$exists=Test-Path -LiteralPath $path;$items=@()
 if($exists){
  $null=Assert-OpenWebCallRecordOrdinary $path -Directory
  $importer=Join-Path $path '.openweb-import.lock'
  if(Test-Path -LiteralPath $importer){$null=Assert-OpenWebCallRecordOrdinary $importer}
  $all=@((Get-Item -LiteralPath $path -Force)) + @(Get-ChildItem -LiteralPath $path -Force -Recurse -ErrorAction Stop)
  if($all.Count -gt 100000){throw 'The native call-record permission inventory requires administrator review.'}
  foreach($item in $all){
   $null=Assert-OpenWebCallRecordOrdinary $item.FullName -Directory:$item.PSIsContainer
   $items+=@{Path=$item.FullName;Directory=[bool]$item.PSIsContainer;Sddl=(Get-Acl -LiteralPath $item.FullName -ErrorAction Stop).Sddl}
  }
 }
 $lock=Join-Path $StateRoot 'upgrade.lock'
 return @{schema=1;Path=$path;Log=$plan.Log;LogExists=$plan.LogExists;Exists=[bool]$exists;Entries=@($items);ImporterLockExists=[bool](Test-Path -LiteralPath (Join-Path $path '.openweb-import.lock'));MaintenanceLockSddl=(Get-Acl -LiteralPath $lock -ErrorAction Stop).Sddl;ConfigRoot=$configRoot;ConfigRootSddl=(Get-Acl -LiteralPath $configRoot -ErrorAction Stop).Sddl;ConfigFileSddl=(Get-Acl -LiteralPath $configFile -ErrorAction Stop).Sddl}
}
function Install-OpenWebCallRecordAccess {
 param([string]$PackageRoot,[string]$Root,[string]$StateRoot,[string]$EngineRoot,[IO.FileStream]$MaintenanceLock)
 Assert-OpenWebCallRecordLock -StateRoot $StateRoot -MaintenanceLock $MaintenanceLock
 $configRoot=Assert-OpenWebRecoveryOrdinary (Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($StateRoot))) 'fusionpbx') -Directory
 $configFile=Assert-OpenWebCallRecordOrdinary (Join-Path $configRoot 'config.conf')
 $plan=Get-OpenWebCallRecordPlan -PackageRoot $PackageRoot -Root $Root -EngineRoot $EngineRoot
 if(!$plan.LogExists){$null=[IO.Directory]::CreateDirectory($plan.Log);$null=Assert-OpenWebRecoveryOrdinary $plan.Log -Directory}
 $spool=$plan.Path
 if(!(Test-Path -LiteralPath $spool)){$null=[IO.Directory]::CreateDirectory($spool)}
 $null=Assert-OpenWebCallRecordOrdinary $spool -Directory
 $importer=Join-Path $spool '.openweb-import.lock'
 if(Test-Path -LiteralPath $importer){$null=Assert-OpenWebCallRecordOrdinary $importer}
 $all=@((Get-Item -LiteralPath $spool -Force)) + @(Get-ChildItem -LiteralPath $spool -Force -Recurse -ErrorAction Stop)
 if($all.Count -gt 100000){throw 'The native call-record permission inventory requires administrator review.'}
 # Validate all nodes before the first security write. Future native records
 # receive Read + WriteAttributes, never file Modify. Directory Modify travels
 # only to directories; the importer lock receives its own explicit grant.
 foreach($item in $all){$null=Assert-OpenWebCallRecordOrdinary $item.FullName -Directory:$item.PSIsContainer}
 foreach($item in $all){
  $rights=if($item.PSIsContainer){[Security.AccessControl.FileSystemRights]::Modify -bor [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles}else{[Security.AccessControl.FileSystemRights]::Read -bor [Security.AccessControl.FileSystemRights]::WriteAttributes}
  if($item.PSIsContainer){
   Add-OpenWebCallRecordRight -Path $item.FullName -Rights $rights -Inheritance ContainerInherit
   Add-OpenWebCallRecordRight -Path $item.FullName -Rights ([Security.AccessControl.FileSystemRights]::Read -bor [Security.AccessControl.FileSystemRights]::WriteAttributes) -Inheritance 'ContainerInherit,ObjectInherit' -Propagation InheritOnly
  }else{Add-OpenWebCallRecordRight -Path $item.FullName -Rights $rights}
 }
 if(!(Test-Path -LiteralPath $importer)){$file=[IO.File]::Open($importer,'CreateNew','Write','None');$file.Dispose()}
 Add-OpenWebCallRecordRight -Path $importer -Rights ([Security.AccessControl.FileSystemRights]::Modify)
 # This is deliberately the one private state file made readable to the worker.
 # The live exclusive handle prevents a new child until the transaction releases it.
 $acl=Get-Acl -LiteralPath (Join-Path $StateRoot 'upgrade.lock') -ErrorAction Stop
 $rule=[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-19'),[Security.AccessControl.FileSystemRights]::Read,'Allow')
 $null=$acl.AddAccessRule($rule);Set-Acl -LiteralPath (Join-Path $StateRoot 'upgrade.lock') -AclObject $acl -ErrorAction Stop
 # The worker needs the existing application/ESL credentials, not installation
 # administrator credentials or the template key. No config inheritance changes.
 Add-OpenWebCallRecordRight -Path $configRoot -Rights ([Security.AccessControl.FileSystemRights]::ReadAndExecute)
 Add-OpenWebCallRecordRight -Path $configFile -Rights ([Security.AccessControl.FileSystemRights]::Read)
}
function Restore-OpenWebCallRecordAccess {
 param($Snapshot,[string]$StateRoot,[string]$EngineRoot,[IO.FileStream]$MaintenanceLock)
 Assert-OpenWebCallRecordLock -StateRoot $StateRoot -MaintenanceLock $MaintenanceLock
 if($null -eq $Snapshot -or ($Snapshot.schema -isnot [int] -and $Snapshot.schema -isnot [long]) -or $Snapshot.schema -ne 1 -or $Snapshot.Path -isnot [string] -or $Snapshot.Log -isnot [string] -or $Snapshot.LogExists -isnot [bool] -or $Snapshot.Exists -isnot [bool] -or $Snapshot.ImporterLockExists -isnot [bool] -or $Snapshot.MaintenanceLockSddl -isnot [string]){throw 'The original call-record access inventory is invalid.'}
 $log=[IO.Path]::GetFullPath($Snapshot.Log)
 if($Snapshot.LogExists -or (Test-Path -LiteralPath $log)){$null=Assert-OpenWebRecoveryOrdinary $log -Directory}
 if(!$Snapshot.LogExists){
  $null=Assert-OpenWebRecoveryOrdinary $EngineRoot -Directory
  if(!$log.Equals([IO.Path]::GetFullPath((Join-Path $EngineRoot 'log')),[StringComparison]::OrdinalIgnoreCase) -or $Snapshot.Exists -or @($Snapshot.Entries).Count){throw 'The original absent call-engine log parent is outside the owned layout.'}
 }
 $spool=[IO.Path]::GetFullPath((Join-Path $log 'xml_cdr'))
 if(!$spool.Equals($Snapshot.Path,[StringComparison]::OrdinalIgnoreCase)){throw 'The original call-record spool scope is invalid.'}
 $configRoot=Assert-OpenWebRecoveryOrdinary (Join-Path ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($StateRoot))) 'fusionpbx') -Directory
 $configFile=Assert-OpenWebCallRecordOrdinary (Join-Path $configRoot 'config.conf')
 if($Snapshot.ConfigRoot -isnot [string] -or !$Snapshot.ConfigRoot.Equals($configRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'The original application configuration scope is invalid.'}
 foreach($sddl in $Snapshot.ConfigRootSddl,$Snapshot.ConfigFileSddl,$Snapshot.MaintenanceLockSddl){
  if($sddl -isnot [string] -or !$sddl -or $sddl.Length -gt 131072){throw 'The complete original call-record configuration descriptors are required.'}
  $null=[Security.AccessControl.RawSecurityDescriptor]::new($sddl)
 }
 $checked=@();$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
 foreach($entry in @($Snapshot.Entries)){
  if($entry.Path -isnot [string] -or $entry.Directory -isnot [bool] -or $entry.Sddl -isnot [string] -or !$entry.Sddl -or $entry.Sddl.Length -gt 131072){throw 'The original call-record permission entry is invalid.'}
  $path=[IO.Path]::GetFullPath($entry.Path)
  if(!($path.Equals($spool,[StringComparison]::OrdinalIgnoreCase) -or $path.StartsWith($spool+'\',[StringComparison]::OrdinalIgnoreCase)) -or !$seen.Add($path)){throw 'The original call-record permission entry is outside its spool.'}
  $null=Assert-OpenWebCallRecordOrdinary $path -Directory:$entry.Directory
  $null=[Security.AccessControl.RawSecurityDescriptor]::new($entry.Sddl);$checked+=,$entry
 }
 if($Snapshot.Exists -and !$seen.Contains($spool)){throw 'The complete original call-record directory descriptor is required.'}
 . (Join-Path $PSScriptRoot 'File-Security.ps1')
 foreach($entry in $checked|Sort-Object @{Expression={if($_.Directory){0}else{1}}},@{Expression={$_.Path.Length}}){Set-OpenWebFileSddl -LiteralPath $entry.Path -Sddl $entry.Sddl}
 $importer=Join-Path $spool '.openweb-import.lock'
 if(!$Snapshot.ImporterLockExists -and (Test-Path -LiteralPath $importer)){
  $null=Assert-OpenWebCallRecordOrdinary $importer
  if((Get-Item -LiteralPath $importer -Force).Length -ne 0){throw 'An unexpected importer lock was preserved.'}
  Remove-Item -LiteralPath $importer -Force -ErrorAction Stop
  if(Test-Path -LiteralPath $importer){throw 'The original importer-lock absence did not restore.'}
 }
 if(!$Snapshot.Exists -and (Test-Path -LiteralPath $spool)){
  $null=Assert-OpenWebCallRecordOrdinary $spool -Directory
  if(@(Get-ChildItem -LiteralPath $spool -Force -ErrorAction Stop).Count){throw 'New call-record contents were preserved; recovery requires review.'}
  [IO.Directory]::Delete($spool,$false)
  if(Test-Path -LiteralPath $spool){throw 'The original call-record spool absence did not restore.'}
 }
 if(!$Snapshot.LogExists -and (Test-Path -LiteralPath $log)){
  if(@(Get-ChildItem -LiteralPath $log -Force -ErrorAction Stop).Count){throw 'New call-engine log contents were preserved; recovery requires review.'}
  [IO.Directory]::Delete($log,$false)
  if(Test-Path -LiteralPath $log){throw 'The original call-engine log parent absence did not restore.'}
 }
 Set-OpenWebFileSddl -LiteralPath (Join-Path $StateRoot 'upgrade.lock') -Sddl $Snapshot.MaintenanceLockSddl
 Set-OpenWebFileSddl -LiteralPath $configRoot -Sddl $Snapshot.ConfigRootSddl
 Set-OpenWebFileSddl -LiteralPath $configFile -Sddl $Snapshot.ConfigFileSddl
}
function Assert-OpenWebCallRecordHold {
 param($Hold)
 if($null -eq $Hold -or ($Hold.schema -isnot [int] -and $Hold.schema -isnot [long]) -or $Hold.schema -ne 1 -or $Hold.owner -isnot [string] -or $Hold.owner -cnotin 'install','upgrade','restore' -or $Hold.transaction -isnot [string] -or $Hold.transaction -cnotmatch '^[a-f0-9]{32}$'){throw 'The call-record hold identity is invalid.'}
}
function Set-OpenWebCallRecordHold {
 param([string]$StateRoot,$Hold,[IO.FileStream]$MaintenanceLock,[switch]$ExternalLockHeld)
 Assert-OpenWebCallRecordLock -StateRoot $StateRoot -MaintenanceLock $MaintenanceLock -ExternalLockHeld:$ExternalLockHeld
 Assert-OpenWebCallRecordHold $Hold
 $path=Join-Path $StateRoot 'call-records.hold'
 if(Test-Path -LiteralPath $path){
  $existing=Read-OpenWebCallRecordHold $StateRoot
  if($existing.owner -cne $Hold.owner -or $existing.transaction -cne $Hold.transaction){throw 'A different durable call-record hold requires recovery.'};return
 }
 $temporary=$path+'.'+[Guid]::NewGuid().ToString('N')+'.new'
 try{
  $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Hold|ConvertTo-Json -Depth 4 -Compress))
  $f=[IO.File]::Open($temporary,'CreateNew','Write','None');try{$f.Write($bytes,0,$bytes.Length);$f.Flush($true)}finally{$f.Dispose()}
  $acl=[Security.AccessControl.FileSecurity]::new();$acl.SetSecurityDescriptorSddlForm('O:BAG:SYD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FR;;;LS)');Set-Acl -LiteralPath $temporary -AclObject $acl -ErrorAction Stop
  [OpenWebPbx.UpgradeRecoveryNativeV1]::Commit($temporary,$path)
 }finally{Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue}
 $null=Read-OpenWebCallRecordHold $StateRoot
}
function Read-OpenWebCallRecordHold {
 param([string]$StateRoot)
 $path=Join-Path $StateRoot 'call-records.hold';$null=Assert-OpenWebRecoveryOrdinary $path
 $acl=Get-Acl -LiteralPath $path -ErrorAction Stop
 if(!$acl.AreAccessRulesProtected -or $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cnotin 'S-1-5-18','S-1-5-32-544'){throw 'The durable call-record hold is not protected.'}
 foreach($r in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){
  if($r.AccessControlType -ne 'Allow' -or ($r.IdentityReference.Value -cnotin 'S-1-5-18','S-1-5-32-544','S-1-5-19') -or ($r.IdentityReference.Value -ceq 'S-1-5-19' -and (([int]$r.FileSystemRights -band (-bnot ([int][Security.AccessControl.FileSystemRights]::Read -bor [int][Security.AccessControl.FileSystemRights]::Synchronize))) -ne 0))){throw 'The durable call-record hold grants unexpected access.'}
 }
 $bytes=Read-OpenWebRecoveryBytes -Path $path -Maximum 4096;$hold=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)|ConvertFrom-Json -ErrorAction Stop
 Assert-OpenWebCallRecordHold $hold;return $hold
}
function Remove-OpenWebCallRecordHold {
 param([string]$StateRoot,$Hold,[IO.FileStream]$MaintenanceLock,[switch]$ExternalLockHeld)
 Assert-OpenWebCallRecordLock -StateRoot $StateRoot -MaintenanceLock $MaintenanceLock -ExternalLockHeld:$ExternalLockHeld
 Assert-OpenWebCallRecordHold $Hold
 $path=Join-Path $StateRoot 'call-records.hold'
 if(!(Test-Path -LiteralPath $path)){return}
 $existing=Read-OpenWebCallRecordHold $StateRoot
 if($existing.owner -cne $Hold.owner -or $existing.transaction -cne $Hold.transaction){throw 'A different durable call-record hold was preserved.'}
 Remove-Item -LiteralPath $path -Force -ErrorAction Stop
 if(Test-Path -LiteralPath $path){throw 'The durable call-record hold could not be released.'}
}
