# SPDX-License-Identifier: AGPL-3.0-or-later
# Administrator-only installation helper. The containing private state ACL is unchanged.
[CmdletBinding()]
param(
 [Parameter(Mandatory=$true)][string]$StateRoot,
 [string]$WebIdentity='IIS AppPool\OpenWebPBX',
 [string]$ServiceIdentity='S-1-5-19'
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'Windows is required.'}
if(-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run this installation helper as an administrator.'}
function AssertOrdinaryDirectory([string]$Path){
 $item=Get-Item -LiteralPath $Path -Force
 if(-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'The private notification directory must be ordinary local storage.'}
}
$StateRoot=[IO.Path]::GetFullPath($StateRoot).TrimEnd('\')
if($StateRoot.StartsWith('\\') -or -not [IO.Path]::IsPathRooted($StateRoot)){throw 'Local private storage is required.'}
$ancestor=$StateRoot
while($ancestor){AssertOrdinaryDirectory $ancestor;$ancestor=[IO.Path]::GetDirectoryName($ancestor)}
$parentAcl=(Get-Acl -LiteralPath $StateRoot).Sddl
$webSid=([Security.Principal.NTAccount]$WebIdentity).Translate([Security.Principal.SecurityIdentifier])
$serviceSid=if($ServiceIdentity -match '^S-1-') {[Security.Principal.SecurityIdentifier]$ServiceIdentity}else{([Security.Principal.NTAccount]$ServiceIdentity).Translate([Security.Principal.SecurityIdentifier])}
if($webSid.Value -notmatch '^S-1-5-82-' -or $serviceSid.Value -ne 'S-1-5-19'){throw 'Use the dedicated IIS pool and LOCAL SERVICE identities.'}
if(-not ('OpenWebNotificationFileInfo' -as [type])){
 Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class OpenWebNotificationFileInfo {
 [StructLayout(LayoutKind.Sequential)] struct Info {
  public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Creation, Access, Write;
  public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
 }
 [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle file,out Info info);
 public static bool SingleLink(string path){
  using(var file=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete)){
   Info info;return GetFileInformationByHandle(file.SafeFileHandle,out info)&&info.Links==1;
  }
 }
}
'@
}
function AssertOrdinaryFile([string]$Path,[bool]$EmptyAllowed=$false){
 $item=Get-Item -LiteralPath $Path -Force
 if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt 65536 -or (-not $EmptyAllowed -and $item.Length -lt 1) -or -not [OpenWebNotificationFileInfo]::SingleLink($Path)){throw 'Notification settings must be a bounded ordinary single-link file.'}
}
function SetStoreAcl([string]$Path,[bool]$Directory){
 $acl=if($Directory){[System.Security.AccessControl.DirectorySecurity]::new()}else{[System.Security.AccessControl.FileSecurity]::new()}
 $acl.SetAccessRuleProtection($true,$false)
 $administrators=[Security.Principal.SecurityIdentifier]'S-1-5-32-544'
 $acl.SetOwner($administrators)
 $inheritance=if($Directory){[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'}else{[Security.AccessControl.InheritanceFlags]::None}
 foreach($entry in @(@('S-1-5-18','FullControl'),@('S-1-5-32-544','FullControl'),@($webSid.Value,'Modify'),@($serviceSid.Value,'ReadAndExecute'))){
  $sid=[Security.Principal.SecurityIdentifier]$entry[0]
  $rule=[System.Security.AccessControl.FileSystemAccessRule]::new($sid,[Security.AccessControl.FileSystemRights]$entry[1],$inheritance,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)
  $acl.AddAccessRule($rule)
 }
 Set-Acl -LiteralPath $Path -AclObject $acl
 $actual=Get-Acl -LiteralPath $Path
 if(-not $actual.AreAccessRulesProtected -or $actual.Access.Count -ne 4){throw 'The private notification ACL was not applied.'}
}
$child=Join-Path $StateRoot 'mobile-notifications'
if(Test-Path -LiteralPath $child){AssertOrdinaryDirectory $child}else{New-Item -ItemType Directory -Path $child | Out-Null}
SetStoreAcl $child $true
$legacy=Join-Path $StateRoot 'mobile-push.json'
$current=Join-Path $child 'config.json'
$lock=Join-Path $child 'config.json.lock'
$migrated=$false
if(Test-Path -LiteralPath $current){AssertOrdinaryFile $current}
elseif(Test-Path -LiteralPath $legacy){
 AssertOrdinaryFile $legacy
 $bytes=[IO.File]::ReadAllBytes($legacy)
 $temporary=Join-Path $child ('migration-'+[Guid]::NewGuid().ToString('N')+'.tmp')
 try{
  $file=[IO.FileStream]::new($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
  try{$file.Write($bytes,0,$bytes.Length);$file.Flush($true)}finally{$file.Dispose()}
  SetStoreAcl $temporary $false
  [IO.File]::Move($temporary,$current)
  if((Get-FileHash -LiteralPath $current -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $legacy -Algorithm SHA256).Hash){throw 'Legacy notification settings did not migrate exactly.'}
  $migrated=$true
 }finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
}
if(Test-Path -LiteralPath $current){AssertOrdinaryFile $current;SetStoreAcl $current $false}
if(Test-Path -LiteralPath $lock){AssertOrdinaryFile $lock $true;SetStoreAcl $lock $false}
if((Get-Acl -LiteralPath $StateRoot).Sddl -ne $parentAcl){throw 'The containing private-state ACL changed.'}
@{notification_store_configured=$true;legacy_bytes_migrated=$migrated;legacy_file_retained=(Test-Path -LiteralPath $legacy);current_config_present=(Test-Path -LiteralPath $current);parent_acl_unchanged=$true;service_access='read';web_access='modify'} | ConvertTo-Json -Compress
