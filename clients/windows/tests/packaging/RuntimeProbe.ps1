# SPDX-License-Identifier: AGPL-3.0-or-later
#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Ambient','Stock')][string]$Mode,[Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$Nonce,[Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$ParentShellRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
if($PSVersionTable.PSEdition-cne 'Desktop' -or $env:GITHUB_ACTIONS-cne 'true' -or $env:RUNNER_ENVIRONMENT-cne 'github-hosted' -or $env:RUNNER_OS-cne 'Windows' -or $env:GITHUB_REPOSITORY-cne 'embire2/openwebpbx'){throw 'Only the disposable native Windows runtime observer is allowed.'}
$Root=[IO.Path]::GetFullPath($Root);$expected=[IO.Path]::Combine([IO.Path]::GetFullPath($env:RUNNER_TEMP),'phone-package-runtime-'+$Nonce)
if($Root-ine $expected -or ![IO.Directory]::Exists($Root)){throw 'Runtime observer root differs.'}
$directory=[IO.DirectoryInfo]::new($Root);for($parent=$directory;$parent;$parent=$parent.Parent){if($parent.Attributes-band [IO.FileAttributes]::ReparsePoint){throw 'Runtime observer ancestry is linked.'}}
$nativeAcl=$directory.GetAccessControl();$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;$rules=@($nativeAcl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
if(!$nativeAcl.AreAccessRulesProtected -or $rules.Count-ne 2){throw 'Runtime observer ACL shape differs.'};foreach($rule in $rules){if($rule.IdentityReference.Value-notin @($sid,'S-1-5-18') -or $rule.AccessControlType-ne 'Allow' -or ($rule.FileSystemRights-band [Security.AccessControl.FileSystemRights]::FullControl)-ne [Security.AccessControl.FileSystemRights]::FullControl){throw 'Runtime observer ACL differs.'}}
$out=[IO.Path]::Combine($Root,('runtime-'+$Mode.ToLowerInvariant()+'.json'));if([IO.File]::Exists($out)){throw 'Runtime observation already exists.'}
$module=[IO.Path]::Combine([Environment]::SystemDirectory,'WindowsPowerShell\v1.0\Modules\Microsoft.PowerShell.Security');$stockHome=[IO.Path]::Combine([Environment]::SystemDirectory,'WindowsPowerShell\v1.0');$windows=[Environment]::GetFolderPath('Windows');$parentHome=[IO.Path]::GetFullPath($ParentShellRoot).TrimEnd('\')
. (Join-Path $PSScriptRoot 'NativeSecurity.ps1')
$result=[ordered]@{schema=1;producer='PackageRuntimeProbe';mode=$Mode;stage='observe_environment';getacl_invoked=$false;getacl_succeeded=$false;acl_matches_native_read=$false;explicit_stock_import=$false;command_observed=$false;certificate_mutation=$false;package_mutation=$false}
function RuntimeError([Management.Automation.ErrorRecord]$Record){
 $chain=@();$item=$Record.Exception
 for($i=0;$item -and $i-lt 8;$i++){
  $row=[ordered]@{type=$item.GetType().Name;hresult=[int]$item.HResult}
  if($item-is [Management.Automation.RuntimeException] -and $item.ErrorRecord){$row.category=[string]$item.ErrorRecord.CategoryInfo.Category;$id=[string]$item.ErrorRecord.FullyQualifiedErrorId;$row.id=if($id-in @('PropertyNotFoundStrict','CommandNotFoundException','CouldNotAutoloadMatchingModule','CouldNotAutoloadModule','Modules_ModuleNotFound','Modules_InvalidManifest','GetAcl_AclNotFound','GetAcl_NotSupported','GetAcl_SystemException','GetAcl_ArgumentException','GetAcl_UnauthorizedAccessException','GetAcl_PathNotFound','System.Management.Automation.CmdletInvocationException,Microsoft.PowerShell.Commands.GetAclCommand')){$id}else{'other'}}
  $chain+=,$row;$item=$item.InnerException
 };$chain
}

try{
 $paths=@($env:PSModulePath -split ';'|Where-Object{$_});if($paths.Count-gt 128){throw 'Module path count exceeds observer bound.'}
 $result.module_paths=[ordered]@{count=$paths.Count;parent_shell_count=@($paths|Where-Object {$_.TrimEnd('\')-ieq ($parentHome+'\Modules')}).Count;stock_count=@($paths|Where-Object {$_.TrimEnd('\')-ieq ($stockHome+'\Modules')}).Count}
 if($Mode-ceq 'Stock'){
  $result.stage='explicit_stock_import';$resolved=GetPackageNativeSecurityCommand $ParentShellRoot;$result.explicit_stock_import=$true;$command=$resolved.Command;$result.provenance=$resolved.Provenance;$result.command_observed=$true
  $result.stage='get_acl';$result.getacl_invoked=$true;$acl=& $command -LiteralPath $Root
 }else{
  # Observe the original invocation before command discovery can alter module loading.
  $result.stage='get_acl';$result.getacl_invoked=$true;$acl=Get-Acl -LiteralPath $Root
 }
 $result.getacl_succeeded=$true;$result.acl_matches_native_read=$acl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)-ceq $nativeAcl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)
}catch{$result.failure=@(RuntimeError $_)}
if($Mode-ceq 'Ambient'){
 try{$commands=@(Get-Command -Name Get-Acl -CommandType Cmdlet -All -ErrorAction Stop);$result.command_count=$commands.Count;if($commands.Count-eq 1){$result.provenance=GetPackageNativeSecurityProvenance $commands[0] $ParentShellRoot;$result.command_observed=$true}}catch{$result.discovery_failure=@(RuntimeError $_)}
}
$json=$result|ConvertTo-Json -Depth 8 -Compress;$bytes=[Text.Encoding]::UTF8.GetBytes($json);if($bytes.Length-gt 16384){throw 'Runtime observation exceeds its bound.'};$file=[IO.File]::Open($out,'CreateNew','Write','None');try{$file.Write($bytes,0,$bytes.Length);$file.Flush($true)}finally{$file.Dispose()}
if(!$result.getacl_succeeded -or !$result.acl_matches_native_read){exit 1}
