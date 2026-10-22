# SPDX-License-Identifier: AGPL-3.0-or-later
# A sealed private boot entry for the interval before installed helpers advance.
# The caller owns upgrade.lock. No installed program helper is overwritten.
function Initialize-OpenWebUpgradeRecoveryNative {
 if('OpenWebPbx.UpgradeRecoveryNativeV1' -as [type]){return}
 Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace OpenWebPbx {
 public static class UpgradeRecoveryNativeV1 {
  [StructLayout(LayoutKind.Sequential)] struct Info { public uint Attributes;public System.Runtime.InteropServices.ComTypes.FILETIME Creation,Access,Write;public uint Volume,SizeHigh,SizeLow,Links,IndexHigh,IndexLow; }
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle file,out Info info);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFileW(string path,uint access,uint sharing,IntPtr security,uint disposition,uint flags,IntPtr template);
  public static void LockIdentity(SafeFileHandle handle){Info info;if(!GetFileInformationByHandle(handle,out info))throw new Win32Exception(Marshal.GetLastWin32Error());if((info.Attributes&0x410)!=0||info.Links!=1)throw new IOException("The recovery lock identity is invalid.");}
  public static bool Exclusive(string path){
   foreach(uint access in new uint[]{0x80000000,0x40000000}){using(var handle=CreateFileW(path,access,7,IntPtr.Zero,3,0x00200000,IntPtr.Zero)){if(!handle.IsInvalid)return false;int error=Marshal.GetLastWin32Error();if(error!=32)throw new Win32Exception(error);}}return true;
  }
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool MoveFileEx(string from,string to,int flags);
  public static byte[] Read(string path,int maximum){
   using(var stream=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read)){
    Info info;if(!GetFileInformationByHandle(stream.SafeFileHandle,out info))throw new Win32Exception(Marshal.GetLastWin32Error());
    if((info.Attributes&0x410)!=0||info.Links!=1||stream.Length>maximum)throw new IOException("The recovery file identity is invalid.");
    byte[] bytes=new byte[checked((int)stream.Length)];int count=0;while(count<bytes.Length){int read=stream.Read(bytes,count,bytes.Length-count);if(read==0)throw new EndOfStreamException();count+=read;}return bytes;
   }
  }
  public static void Commit(string from,string to){if(!MoveFileEx(from,to,9))throw new Win32Exception(Marshal.GetLastWin32Error(),"The recovery entry could not be committed.");}
 }
}
'@
}
function Assert-OpenWebRecoveryOrdinary {
 param([Parameter(Mandatory)][string]$Path,[switch]$Directory)
 $full=[IO.Path]::GetFullPath($Path)
 if($full -notmatch '^[A-Za-z]:\\' -or $full.IndexOf([char]0) -ge 0){throw 'A local recovery path is required.'}
 $item=Get-Item -LiteralPath $full -Force -ErrorAction Stop
 if([bool]$item.PSIsContainer -ne [bool]$Directory){throw 'A recovery path has changed its type.'}
 for($current=$full;$current;$current=[IO.Path]::GetDirectoryName($current)){
  if((Get-Item -LiteralPath $current -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Recovery links and junctions are refused.'}
 };return $full
}
function Get-OpenWebRecoveryPrivilegedSids {
 $cached=Get-Variable -Name OpenWebRecoveryPrivilegedSids -Scope Script -ErrorAction SilentlyContinue
 $until=Get-Variable -Name OpenWebRecoveryPrivilegedUntil -Scope Script -ErrorAction SilentlyContinue
 if($cached -and $until -and $until.Value -gt [DateTime]::UtcNow){return ,$cached.Value}
 $allowed=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
 foreach($sid in 'S-1-5-18','S-1-5-32-544'){$null=$allowed.Add($sid)}
 Import-Module -Name (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.LocalAccounts') -ErrorAction Stop
 foreach($member in @(Microsoft.PowerShell.LocalAccounts\Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop)){
  $sid=[string]$member.SID;if($sid -notmatch '^S-1-[0-9-]+$'){throw 'Recovery administrator membership needs review.'};$null=$allowed.Add($sid)
 };$script:OpenWebRecoveryPrivilegedSids=$allowed;$script:OpenWebRecoveryPrivilegedUntil=[DateTime]::UtcNow.AddSeconds(30);return ,$allowed
}
function Assert-OpenWebRecoveryProtected {
 param([Parameter(Mandatory)][string]$Path,[switch]$Directory,[switch]$Private)
 $full=Assert-OpenWebRecoveryOrdinary $Path -Directory:$Directory
 $privileged=Get-OpenWebRecoveryPrivilegedSids
 $acl=Get-Acl -LiteralPath $full -ErrorAction Stop
 $owner=$acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
 if(!$privileged.Contains($owner)){throw 'The recovery path owner needs review.'}
 $write=[int][Security.AccessControl.FileSystemRights]::Write -bor [int][Security.AccessControl.FileSystemRights]::Delete -bor [int][Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [int][Security.AccessControl.FileSystemRights]::ChangePermissions -bor [int][Security.AccessControl.FileSystemRights]::TakeOwnership
 $rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
 foreach($rule in $rules){
  if($rule.AccessControlType -ne 'Allow' -or ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)){continue}
  if(([int]$rule.FileSystemRights -band $write) -and !$privileged.Contains($rule.IdentityReference.Value)){throw 'A non-administrator can replace the recovery entry.'}
  if($Private -and $rule.IdentityReference.Value -cnotin 'S-1-5-18','S-1-5-32-544'){throw 'The recovery bundle is not private.'}
 }
 if($Private){
  if(!$acl.AreAccessRulesProtected -or $owner -cnotin 'S-1-5-18','S-1-5-32-544' -or $acl.GetGroup([Security.Principal.SecurityIdentifier]).Value -cne 'S-1-5-18' -or $rules.Count -ne 2){throw 'The recovery bundle permissions must remain exact and private.'}
  $seen=@{};$inheritance=if($Directory){[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'}else{[Security.AccessControl.InheritanceFlags]::None}
  foreach($rule in $rules){$sid=$rule.IdentityReference.Value;if($seen.ContainsKey($sid) -or $sid -cnotin 'S-1-5-18','S-1-5-32-544' -or $rule.IsInherited -or $rule.AccessControlType -ne 'Allow' -or [int64]$rule.FileSystemRights -ne [int64][Security.AccessControl.FileSystemRights]::FullControl -or $rule.InheritanceFlags -ne $inheritance -or $rule.PropagationFlags -ne [Security.AccessControl.PropagationFlags]::None){throw 'The private recovery descriptor changed.'};$seen[$sid]=$true}
 }
 return $full
}
function Read-OpenWebRecoveryBytes {
 param([Parameter(Mandatory)][string]$Path,[int]$Maximum=16777216)
 $null=Assert-OpenWebRecoveryOrdinary $Path
 Initialize-OpenWebUpgradeRecoveryNative
 return ,[OpenWebPbx.UpgradeRecoveryNativeV1]::Read($Path,$Maximum)
}
function Get-OpenWebRecoveryHash {
 param([Parameter(Mandatory)][byte[]]$Bytes)
 $hash=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($hash.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}
}
function Set-OpenWebRecoveryPrivate {
 param([Parameter(Mandatory)][string]$Path,[switch]$Directory)
 $null=Assert-OpenWebRecoveryOrdinary $Path -Directory:$Directory
 $acl=if($Directory){New-Object Security.AccessControl.DirectorySecurity}else{New-Object Security.AccessControl.FileSecurity}
 $sddl=if($Directory){'O:BAG:SYD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)'}else{'O:BAG:SYD:P(A;;FA;;;SY)(A;;FA;;;BA)'}
 $acl.SetSecurityDescriptorSddlForm($sddl);Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
 $null=Assert-OpenWebRecoveryProtected $Path -Directory:$Directory -Private
}
function Assert-OpenWebRecoveryLock {
 param([IO.FileStream]$MaintenanceLock,[string]$StateRoot)
 $expected=[IO.Path]::GetFullPath((Join-Path $StateRoot 'upgrade.lock'))
 if(!$MaintenanceLock -or !$MaintenanceLock.CanRead -or !$MaintenanceLock.CanWrite -or ![IO.Path]::GetFullPath($MaintenanceLock.Name).Equals($expected,[StringComparison]::OrdinalIgnoreCase)){throw 'The owned maintenance lock is required for the recovery handoff.'}
 Initialize-OpenWebUpgradeRecoveryNative
 $null=Assert-OpenWebRecoveryOrdinary $expected
 [OpenWebPbx.UpgradeRecoveryNativeV1]::LockIdentity($MaintenanceLock.SafeFileHandle)
 if(![OpenWebPbx.UpgradeRecoveryNativeV1]::Exclusive($expected)){throw 'The recovery handoff requires an exclusive native maintenance lock.'}
}
function Write-OpenWebRecoveryFile {
 param([string]$Path,[byte[]]$Bytes)
 $stream=[IO.File]::Open($Path,'CreateNew','Write','None')
 try{$stream.Write($Bytes,0,$Bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
 Set-OpenWebRecoveryPrivate $Path
}
function Write-OpenWebRecoveryRuntime {
 param([string]$Path,[byte[]]$Bytes,[string]$Sddl,[int]$Attributes,[string]$ExpectedHash)
 $null=Assert-OpenWebRecoveryProtected $Path
 if((Get-OpenWebRecoveryHash (Read-OpenWebRecoveryBytes $Path)) -cne $ExpectedHash){throw 'The private runtime configuration changed before the recovery handoff.'}
 $temporary=Join-Path ([IO.Path]::GetDirectoryName($Path)) ('.upgrade-runtime-'+[Guid]::NewGuid().ToString('N')+'.new')
 try{
  Write-OpenWebRecoveryFile $temporary $Bytes
  . (Join-Path $PSScriptRoot 'File-Security.ps1')
  Set-OpenWebFileSddl -LiteralPath $temporary -Sddl $Sddl
  [IO.File]::SetAttributes($temporary,[IO.FileAttributes]$Attributes)
  Initialize-OpenWebUpgradeRecoveryNative
  [OpenWebPbx.UpgradeRecoveryNativeV1]::Commit($temporary,$Path)
  if((Get-OpenWebRecoveryHash (Read-OpenWebRecoveryBytes $Path)) -cne (Get-OpenWebRecoveryHash $Bytes) -or (Get-Acl -LiteralPath $Path).Sddl -cne $Sddl -or [int](Get-Item -LiteralPath $Path -Force).Attributes -ne $Attributes){throw 'The committed recovery configuration needs administrator review.'}
 }finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force -ErrorAction Stop}}
}
function Assert-OpenWebRecoveryRuntimeShape {
 param($Value,[int]$Depth=0,[ref]$Count=([ref]0))
 $Count.Value++
 if($Depth -gt 24 -or $Count.Value -gt 10000){throw 'The custom runtime configuration exceeds the safe recovery serialization bound.'}
 if($null -eq $Value -or $Value -is [string] -or $Value -is [bool]){return}
 if($Value -is [int] -or $Value -is [long]){if($Value -gt 9007199254740991L -or $Value -lt -9007199254740991L){throw 'A custom runtime number cannot be preserved safely.'};return}
 if($Value -is [pscustomobject]){foreach($property in $Value.PSObject.Properties){Assert-OpenWebRecoveryRuntimeShape -Value $property.Value -Depth ($Depth+1) -Count $Count};return}
 if($Value -is [Array]){foreach($item in $Value){Assert-OpenWebRecoveryRuntimeShape -Value $item -Depth ($Depth+1) -Count $Count};return}
 # Native JSON coercion can turn an ISO string into DateTime, or a precise
 # number into floating point. Refuse unknown shapes before changing config.
 throw 'A custom runtime value cannot be preserved safely by this recovery handoff.'
}
function Assert-OpenWebUpgradeRecoveryIdle {
 param([string]$Root,[string]$StateRoot)
 $runtime=Join-Path $StateRoot 'runtime.json';$null=Assert-OpenWebRecoveryProtected $StateRoot -Directory;$null=Assert-OpenWebRecoveryProtected (Join-Path $StateRoot 'updates') -Directory
 $r=[Text.Encoding]::UTF8.GetString((Read-OpenWebRecoveryBytes $runtime 1048576))|ConvertFrom-Json
 Assert-OpenWebRecoveryRuntimeShape $r
 if($r.PSObject.Properties['Updater'] -and ($r.Updater -isnot [pscustomobject] -or ($r.Updater.PSObject.Properties['Helper'] -and ($r.Updater.Helper -isnot [string] -or $r.Updater.Helper -ine (Join-Path $Root 'tools\Upgrade-OpenWebPBX.ps1'))))){throw 'A custom or pending recovery helper must be resolved before updating.'}
 $journal=Join-Path $StateRoot 'updates\install-journal.json'
 if(Test-Path -LiteralPath $journal){$j=[Text.Encoding]::UTF8.GetString((Read-OpenWebRecoveryBytes $journal 1048576))|ConvertFrom-Json;if($j.state -cnotin 'completed','rolled_back'){throw 'Complete the interrupted upgrade recovery before starting another update.'}}
}
function Get-OpenWebUpgradeRecoveryMetadata {
 param($Entry,[string]$Root,[string]$StateRoot,[string]$EngineRoot,[switch]$RequirePublished)
 if(!$Entry -or @($Entry.PSObject.Properties).Count -ne 4 -or ($Entry.schema -isnot [int] -and $Entry.schema -isnot [long]) -or $Entry.schema -ne 1 -or $Entry.bundle_path -isnot [string] -or $Entry.metadata_sha256 -isnot [string] -or $Entry.metadata_sha256 -cnotmatch '^[a-f0-9]{64}$' -or $Entry.launcher_sha256 -isnot [string] -or $Entry.launcher_sha256 -cnotmatch '^[a-f0-9]{64}$'){throw 'The recovery journal entry is invalid.'}
 $prefix=[IO.Path]::GetFullPath((Join-Path $StateRoot 'updates\recovery-entry')).TrimEnd('\')+'\';$bundle=[IO.Path]::GetFullPath($Entry.bundle_path)
 if(!$bundle.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or $bundle.Substring($prefix.Length) -cnotmatch '^[a-f0-9]{32}$'){throw 'The recovery bundle is outside its protected transaction root.'}
 $null=Assert-OpenWebRecoveryProtected $StateRoot -Directory;$null=Assert-OpenWebRecoveryProtected (Join-Path $StateRoot 'updates') -Directory
 $null=Assert-OpenWebRecoveryProtected ([IO.Path]::GetDirectoryName($bundle)) -Directory -Private;$null=Assert-OpenWebRecoveryProtected $bundle -Directory -Private
 $meta=Join-Path $bundle 'entry.json';$null=Assert-OpenWebRecoveryProtected $meta -Private;$bytes=Read-OpenWebRecoveryBytes $meta 1048576
 if((Get-OpenWebRecoveryHash $bytes) -cne $Entry.metadata_sha256){throw 'The recovery bundle metadata changed.'}
 $m=[Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json
 if(($m.schema -isnot [int] -and $m.schema -isnot [long]) -or $m.schema -ne 1 -or $m.computer -cne [Environment]::MachineName -or $m.root -ine [IO.Path]::GetFullPath($Root) -or $m.state_root -ine [IO.Path]::GetFullPath($StateRoot) -or $m.engine_root -ine [IO.Path]::GetFullPath($EngineRoot) -or $m.bundle_path -ine $bundle -or $m.version -cnotmatch '^\d+\.\d+\.\d+$' -or $m.previous_version -cnotmatch '^\d+\.\d+\.\d+$' -or $m.runtime_sddl -isnot [string] -or ($m.runtime_attributes -isnot [int] -and $m.runtime_attributes -isnot [long]) -or $m.files -isnot [pscustomobject]){throw 'The recovery bundle belongs to another transaction or machine.'}
 foreach($name in 'computer','root','state_root','engine_root','bundle_path','backup_path','version','previous_version','runtime_sddl'){if($m.$name -isnot [string] -or [string]::IsNullOrEmpty($m.$name)){throw 'A recovery metadata field has an invalid type.'}}
 foreach($name in 'source_manifest_sha256','backup_manifest_sha256','backup_complete_sha256','runtime_before_sha256','runtime_after_sha256','original_helper_sha256'){if($m.$name -isnot [string] -or $m.$name -cnotmatch '^[a-f0-9]{64}$'){throw 'A recovery identity pin is invalid.'}}
 if($m.runtime_attributes -lt 0 -or $m.runtime_attributes -gt 65535 -or ($m.runtime_attributes -band 0x410) -or $m.runtime_sddl.Length -gt 131072 -or $m.files.'release-manifest.json' -cne $m.source_manifest_sha256 -or $m.files.'runtime.before.json' -cne $m.runtime_before_sha256 -or $m.files.'runtime.after.json' -cne $m.runtime_after_sha256){throw 'The recovery metadata identity is inconsistent.'}
 $backupPrefix=[IO.Path]::GetFullPath((Join-Path $StateRoot 'backups')).TrimEnd('\')+'\'
 if(![IO.Path]::GetFullPath($m.backup_path).StartsWith($backupPrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'The sealed recovery backup is outside its owned root.'}
 $files=@($m.files.PSObject.Properties);$actual=@(Get-ChildItem -LiteralPath $bundle -Force)
 if($files.Count -lt 4 -or $files.Count -gt 512 -or $actual.Count -ne $files.Count+2){throw 'The recovery bundle file inventory changed.'}
 foreach($item in $actual){if($item.PSIsContainer -or ($item.Name -cnotin @($files.Name)+@('entry.json','recovery-launcher.ps1'))){throw 'Unexpected recovery bundle content is refused.'};$null=Assert-OpenWebRecoveryProtected $item.FullName -Private}
 foreach($file in $files){if($file.Name -cnotmatch '^[a-zA-Z0-9_.-]+$' -or $file.Value -isnot [string] -or $file.Value -cnotmatch '^[a-f0-9]{64}$' -or (Get-OpenWebRecoveryHash (Read-OpenWebRecoveryBytes (Join-Path $bundle $file.Name))) -cne $file.Value){throw 'A pinned recovery dependency changed.'}}
 if((Get-OpenWebRecoveryHash (Read-OpenWebRecoveryBytes (Join-Path $bundle 'recovery-launcher.ps1') 1048576)) -cne $Entry.launcher_sha256){throw 'The private recovery launcher changed.'}
 foreach($pair in @(@('backup_manifest_sha256','backup-manifest.json'),@('backup_complete_sha256','complete.json'))){if($m.($pair[0]) -cnotmatch '^[a-f0-9]{64}$' -or (Get-OpenWebRecoveryHash (Read-OpenWebRecoveryBytes (Join-Path $m.backup_path $pair[1]) 16777216)) -cne $m.($pair[0])){throw 'The sealed recovery backup identity changed.'}}
 $journal=[Text.Encoding]::UTF8.GetString((Read-OpenWebRecoveryBytes (Join-Path $StateRoot 'updates\install-journal.json') 1048576))|ConvertFrom-Json
 if($journal.state -cnotin 'quiescing','deploying','migrating','validating','rolling_back','recovery_required' -or $journal.version -cne $m.version -or $journal.previous_version -cne $m.previous_version -or $journal.backup_path -ine $m.backup_path){throw 'The recovery journal no longer matches its sealed backup.'}
 if($RequirePublished){
  if(!$journal.recovery_entry -or $journal.recovery_entry.schema -ne 1 -or $journal.recovery_entry.bundle_path -cne $Entry.bundle_path -or $journal.recovery_entry.metadata_sha256 -cne $Entry.metadata_sha256 -or $journal.recovery_entry.launcher_sha256 -cne $Entry.launcher_sha256){throw 'The recovery journal does not pin this entry.'}
  $current=Read-OpenWebRecoveryBytes (Join-Path $StateRoot 'runtime.json') 1048576
  if((Get-OpenWebRecoveryHash $current) -cne $m.runtime_after_sha256 -or (Get-Acl -LiteralPath (Join-Path $StateRoot 'runtime.json')).Sddl -cne $m.runtime_sddl){throw 'The published recovery configuration changed.'}
 };return $m
}
function New-OpenWebUpgradeRecovery {
 param([string]$PackageRoot,[string]$Root,[string]$StateRoot,[string]$EngineRoot,[string]$Backup,[IO.FileStream]$MaintenanceLock)
 Assert-OpenWebRecoveryLock $MaintenanceLock $StateRoot
 $null=Assert-OpenWebRecoveryProtected $StateRoot -Directory;$null=Assert-OpenWebRecoveryProtected (Join-Path $StateRoot 'updates') -Directory
 $runtime=Join-Path $StateRoot 'runtime.json';$null=Assert-OpenWebRecoveryProtected $runtime
 $before=Read-OpenWebRecoveryBytes $runtime 1048576;$r=[Text.Encoding]::UTF8.GetString($before)|ConvertFrom-Json
 Assert-OpenWebRecoveryRuntimeShape $r
 $oldHelper=$null
 if($r.PSObject.Properties['Updater']){
  if($r.Updater -isnot [pscustomobject]){throw 'The updater runtime configuration needs review.'}
  if($r.Updater.PSObject.Properties['Helper']){$oldHelper=$r.Updater.Helper;if($oldHelper -isnot [string] -or $oldHelper -ine (Join-Path $Root 'tools\Upgrade-OpenWebPBX.ps1')){throw 'A custom recovery helper cannot be replaced automatically.'}}
 }
 $journal=[Text.Encoding]::UTF8.GetString((Read-OpenWebRecoveryBytes (Join-Path $StateRoot 'updates\install-journal.json') 1048576))|ConvertFrom-Json
 if($journal.state -cnotin 'quiescing','deploying' -or $journal.PSObject.Properties['recovery_entry'] -or $journal.backup_path -ine [IO.Path]::GetFullPath($Backup)){throw 'The new recovery handoff requires this newly sealed upgrade backup.'}
 $backupPrefix=[IO.Path]::GetFullPath((Join-Path $StateRoot 'backups')).TrimEnd('\')+'\'
 if(![IO.Path]::GetFullPath($Backup).StartsWith($backupPrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'The recovery backup is outside its owned root.'}
 $backupManifestBytes=Read-OpenWebRecoveryBytes (Join-Path $Backup 'backup-manifest.json')
 $backupCompleteBytes=Read-OpenWebRecoveryBytes (Join-Path $Backup 'complete.json')
 $sealed=[Text.Encoding]::UTF8.GetString($backupManifestBytes)|ConvertFrom-Json;$complete=[Text.Encoding]::UTF8.GetString($backupCompleteBytes)|ConvertFrom-Json
 if($complete.version -cne $journal.previous_version -or $complete.integrity_sha256 -cne (Get-OpenWebRecoveryHash $backupManifestBytes) -or $sealed.files.'runtime.json' -cne (Get-OpenWebRecoveryHash $before) -or (Get-OpenWebRecoveryHash (Read-OpenWebRecoveryBytes (Join-Path $Backup 'runtime.json'))) -cne (Get-OpenWebRecoveryHash $before)){throw 'The sealed backup and current runtime identity differ.'}
 $manifestPath=Join-Path $PackageRoot 'release-manifest.json';$manifestBytes=Read-OpenWebRecoveryBytes $manifestPath 4194304;$manifest=[Text.Encoding]::UTF8.GetString($manifestBytes)|ConvertFrom-Json
 if($manifest.version -cne $journal.version){throw 'The pinned release manifest version differs from the upgrade journal.'}
 $sourceFiles=@(Get-ChildItem -LiteralPath $PackageRoot -File -Force|Where-Object {$_.Extension -cin '.ps1','.psm1','.php' -or $_.Name -cin 'VERSION','release-manifest.json'})
 if($sourceFiles.Count -lt 4 -or $sourceFiles.Count -gt 500){throw 'The recovery source inventory is incomplete.'}
 foreach($required in 'Upgrade-OpenWebPBX.ps1','UpgradeRecovery.Common.ps1','Restore-Gates.ps1','Support-Recovery.ps1','File-Security.ps1','Web-Readiness.ps1','Dtls.Common.ps1','PhoneHealth-Security.ps1','PhpRuntime.Common.ps1','Write-PrivateState.ps1','check-call-engine.php','VERSION'){if($required -cnotin $sourceFiles.Name){throw 'A required boot recovery dependency is missing.'}}
 $parent=Join-Path $StateRoot 'updates\recovery-entry'
 if(!(Test-Path -LiteralPath $parent)){$null=[IO.Directory]::CreateDirectory($parent);Set-OpenWebRecoveryPrivate $parent -Directory}else{$null=Assert-OpenWebRecoveryProtected $parent -Directory -Private}
 $bundle=Join-Path $parent ([Guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($bundle);Set-OpenWebRecoveryPrivate $bundle -Directory
 $files=@{};$total=0
 foreach($file in $sourceFiles){
  if($file.Name -cnotmatch '^[a-zA-Z0-9_.-]+$'){throw 'A recovery dependency name is invalid.'}
  $bytes=Read-OpenWebRecoveryBytes $file.FullName;$hash=Get-OpenWebRecoveryHash $bytes
  if($file.Name -cne 'release-manifest.json' -and $manifest.files.($file.Name) -cne $hash){throw 'A recovery dependency differs from the verified release.'}
  $total+=$bytes.Length;if($total -gt 33554432){throw 'The private recovery bundle exceeds its bound.'}
  Write-OpenWebRecoveryFile (Join-Path $bundle $file.Name) $bytes;$files[$file.Name]=$hash
 }
 if(([Text.Encoding]::UTF8.GetString((Read-OpenWebRecoveryBytes (Join-Path $bundle 'VERSION'))) ).Trim() -cne $journal.version){throw 'The recovery version differs from the pending upgrade.'}
 Write-OpenWebRecoveryFile (Join-Path $bundle 'runtime.before.json') $before;$files['runtime.before.json']=Get-OpenWebRecoveryHash $before
 $updaterExisted=$null -ne $r.PSObject.Properties['Updater'];$helperExisted=$updaterExisted -and $null -ne $r.Updater.PSObject.Properties['Helper']
 if($updaterExisted -and $r.Updater -isnot [pscustomobject]){throw 'The updater runtime configuration needs review.'}
 if(!$updaterExisted){$r|Add-Member NoteProperty Updater ([pscustomobject]@{})}
 if($helperExisted){$r.Updater.Helper=Join-Path $bundle 'recovery-launcher.ps1'}else{$r.Updater|Add-Member NoteProperty Helper (Join-Path $bundle 'recovery-launcher.ps1')}
 $after=[Text.UTF8Encoding]::new($false).GetBytes(($r|ConvertTo-Json -Depth 32 -WarningAction Stop));Write-OpenWebRecoveryFile (Join-Path $bundle 'runtime.after.json') $after;$files['runtime.after.json']=Get-OpenWebRecoveryHash $after
 # Verify that the temporary Helper field is the only semantic config change.
 $roundtrip=[Text.Encoding]::UTF8.GetString($after)|ConvertFrom-Json
 if($helperExisted){$roundtrip.Updater.Helper=$oldHelper}else{$roundtrip.Updater.PSObject.Properties.Remove('Helper')}
 if(!$updaterExisted){$roundtrip.PSObject.Properties.Remove('Updater')}
 $original=[Text.Encoding]::UTF8.GetString($before)|ConvertFrom-Json
 if(($roundtrip|ConvertTo-Json -Depth 32 -Compress -WarningAction Stop) -cne ($original|ConvertTo-Json -Depth 32 -Compress -WarningAction Stop)){throw 'The recovery handoff would change another runtime setting.'}
 $metadata=[ordered]@{schema=1;computer=[Environment]::MachineName;root=[IO.Path]::GetFullPath($Root);state_root=[IO.Path]::GetFullPath($StateRoot);engine_root=[IO.Path]::GetFullPath($EngineRoot);bundle_path=$bundle;backup_path=[IO.Path]::GetFullPath($Backup);version=$journal.version;previous_version=$journal.previous_version;source_manifest_sha256=(Get-OpenWebRecoveryHash $manifestBytes);backup_manifest_sha256=(Get-OpenWebRecoveryHash (Read-OpenWebRecoveryBytes (Join-Path $Backup 'backup-manifest.json')));backup_complete_sha256=(Get-OpenWebRecoveryHash (Read-OpenWebRecoveryBytes (Join-Path $Backup 'complete.json')));runtime_before_sha256=(Get-OpenWebRecoveryHash $before);runtime_after_sha256=(Get-OpenWebRecoveryHash $after);runtime_sddl=(Get-Acl -LiteralPath $runtime).Sddl;runtime_attributes=[int](Get-Item -LiteralPath $runtime -Force).Attributes;original_helper_sha256=(Get-OpenWebRecoveryHash (Read-OpenWebRecoveryBytes (Join-Path $Root 'tools\Upgrade-OpenWebPBX.ps1')));files=$files}
 $metadataBytes=[Text.UTF8Encoding]::new($false).GetBytes(($metadata|ConvertTo-Json -Depth 12));Write-OpenWebRecoveryFile (Join-Path $bundle 'entry.json') $metadataBytes;$metadataHash=Get-OpenWebRecoveryHash $metadataBytes
 $definitions=@('Initialize-OpenWebUpgradeRecoveryNative','Assert-OpenWebRecoveryOrdinary','Get-OpenWebRecoveryPrivilegedSids','Assert-OpenWebRecoveryProtected','Read-OpenWebRecoveryBytes','Get-OpenWebRecoveryHash','Get-OpenWebUpgradeRecoveryMetadata')|ForEach-Object {'function '+$_+" {`n"+(Get-Command $_ -CommandType Function).Definition+"`n}"}
 $entryText=@'
#Requires -RunAsAdministrator
param([switch]$Recover)
$ErrorActionPreference='Stop'
trap {[Console]::Error.WriteLine('The pinned upgrade recovery entry refused its private inputs.');exit 2}
if(!$Recover -or $PSVersionTable.PSEdition -eq 'Core'){throw 'This private entry accepts only native Windows upgrade recovery.'}
'@ + "`n"+($definitions -join "`n")+"`n"
 $entryText+=('$entry=[pscustomobject]@{schema=1;bundle_path='+("'"+$bundle.Replace("'","''")+"'")+";metadata_sha256='"+$metadataHash+"';launcher_sha256=(Get-OpenWebRecoveryHash (Read-OpenWebRecoveryBytes `$PSCommandPath 1048576))}`n")
 $entryText+=('$m=Get-OpenWebUpgradeRecoveryMetadata -Entry $entry -Root '+("'"+$Root.Replace("'","''")+"'")+' -StateRoot '+("'"+$StateRoot.Replace("'","''")+"'")+' -EngineRoot '+("'"+$EngineRoot.Replace("'","''")+"'")+" -RequirePublished`n")
 $entryText+='$global:LASTEXITCODE=0'+"`n"+'& (Join-Path $PSScriptRoot ''Upgrade-OpenWebPBX.ps1'') -Recover'+"`n"+'$ok=$?;$code=$LASTEXITCODE;if(!$ok){if($code -is [int] -and $code -gt 0 -and $code -le 255){exit $code};exit 2};exit 0'+"`n"
 $launcher=[Text.UTF8Encoding]::new($false).GetBytes($entryText);Write-OpenWebRecoveryFile (Join-Path $bundle 'recovery-launcher.ps1') $launcher
 $entry=[pscustomobject]@{schema=1;bundle_path=$bundle;metadata_sha256=$metadataHash;launcher_sha256=(Get-OpenWebRecoveryHash $launcher)}
 $null=Get-OpenWebUpgradeRecoveryMetadata -Entry $entry -Root $Root -StateRoot $StateRoot -EngineRoot $EngineRoot
 return $entry
}
function Publish-OpenWebUpgradeRecovery {
 param($Entry,[string]$Root,[string]$StateRoot,[string]$EngineRoot,[IO.FileStream]$MaintenanceLock)
 Assert-OpenWebRecoveryLock $MaintenanceLock $StateRoot
 $m=Get-OpenWebUpgradeRecoveryMetadata -Entry $Entry -Root $Root -StateRoot $StateRoot -EngineRoot $EngineRoot
 $journal=[Text.Encoding]::UTF8.GetString((Read-OpenWebRecoveryBytes (Join-Path $StateRoot 'updates\install-journal.json') 1048576))|ConvertFrom-Json
 if(!$journal.recovery_entry -or $journal.recovery_entry.bundle_path -cne $Entry.bundle_path -or $journal.recovery_entry.metadata_sha256 -cne $Entry.metadata_sha256 -or $journal.recovery_entry.launcher_sha256 -cne $Entry.launcher_sha256){throw 'Pin the complete recovery entry in the durable journal before publishing it.'}
 Write-OpenWebRecoveryRuntime -Path (Join-Path $StateRoot 'runtime.json') -Bytes (Read-OpenWebRecoveryBytes (Join-Path $Entry.bundle_path 'runtime.after.json')) -Sddl $m.runtime_sddl -Attributes $m.runtime_attributes -ExpectedHash $m.runtime_before_sha256
 $null=Get-OpenWebUpgradeRecoveryMetadata -Entry $Entry -Root $Root -StateRoot $StateRoot -EngineRoot $EngineRoot -RequirePublished
}
function Complete-OpenWebUpgradeRecovery {
 param($Entry,[string]$Root,[string]$StateRoot,[string]$EngineRoot,[IO.FileStream]$MaintenanceLock,[Parameter(Mandatory)][ValidateSet('Success','Rollback')][string]$Outcome)
 if(!$Entry){return}
 Assert-OpenWebRecoveryLock $MaintenanceLock $StateRoot
 $m=Get-OpenWebUpgradeRecoveryMetadata -Entry $Entry -Root $Root -StateRoot $StateRoot -EngineRoot $EngineRoot -RequirePublished
 if($Outcome -ceq 'Success'){
  $null=Assert-OpenWebRecoveryProtected $Root -Directory;$null=Assert-OpenWebRecoveryProtected (Join-Path $Root 'tools') -Directory
  foreach($name in 'Upgrade-OpenWebPBX.ps1','UpgradeRecovery.Common.ps1','Restore-Gates.ps1','Support-Recovery.ps1','File-Security.ps1','Web-Readiness.ps1','Dtls.Common.ps1','PhoneHealth-Security.ps1','PhpRuntime.Common.ps1','Write-PrivateState.ps1','check-call-engine.php'){
   if((Get-OpenWebRecoveryHash (Read-OpenWebRecoveryBytes (Join-Path $Root ('tools\'+$name)))) -cne $m.files.$name){throw 'Installed boot recovery dependencies are not complete; retain the private recovery entry.'}
  }
 }else{
  if((Get-OpenWebRecoveryHash (Read-OpenWebRecoveryBytes (Join-Path $Root 'tools\Upgrade-OpenWebPBX.ps1'))) -cne $m.original_helper_sha256){throw 'The original boot recovery helper has not restored.'}
 }
 Write-OpenWebRecoveryRuntime -Path (Join-Path $StateRoot 'runtime.json') -Bytes (Read-OpenWebRecoveryBytes (Join-Path $Entry.bundle_path 'runtime.before.json')) -Sddl $m.runtime_sddl -Attributes $m.runtime_attributes -ExpectedHash $m.runtime_after_sha256
}
function Ensure-OpenWebUpgradeRecoveryPublished {
 param($Entry,[string]$Root,[string]$StateRoot,[string]$EngineRoot,[IO.FileStream]$MaintenanceLock)
 if(!$Entry){return}
 Assert-OpenWebRecoveryLock $MaintenanceLock $StateRoot
 $m=Get-OpenWebUpgradeRecoveryMetadata -Entry $Entry -Root $Root -StateRoot $StateRoot -EngineRoot $EngineRoot
 $hash=Get-OpenWebRecoveryHash (Read-OpenWebRecoveryBytes (Join-Path $StateRoot 'runtime.json'))
 if($hash -ceq $m.runtime_before_sha256){Publish-OpenWebUpgradeRecovery -Entry $Entry -Root $Root -StateRoot $StateRoot -EngineRoot $EngineRoot -MaintenanceLock $MaintenanceLock}
 elseif($hash -cne $m.runtime_after_sha256){throw 'The interrupted recovery configuration changed.'}
 $null=Get-OpenWebUpgradeRecoveryMetadata -Entry $Entry -Root $Root -StateRoot $StateRoot -EngineRoot $EngineRoot -RequirePublished
}
