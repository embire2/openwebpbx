# SPDX-License-Identifier: AGPL-3.0-or-later
# Dot-sourced only by a verified installer, while its maintenance lock is held.
function Get-OpenWebUpgradeDelegationPlan {
 param([Parameter(Mandatory)]$Context,[switch]$Original23)
 $stock23='527e17a9349fd5e9f3b1d048fd2f4526495e2cdc5e28f836fe79d8fd17ff1eec'
 if($Original23 -and ($Context.CallerPath -ine 'C:\OpenWebPBX\tools\Upgrade-OpenWebPBX.ps1' -or $Context.CallerSha256 -cne $stock23 -or $Context.InstalledVersion -cne '1.0.23' -or $Context.TargetVersion -cne '1.0.27')){throw 'The original Windows23 compatibility entry does not match its qualified source and version.'}
 if($Context.Recover -isnot [bool] -or $Context.Recover -or $Context.RestoreBackup -isnot [string] -or $Context.RestoreBackup){throw 'Recovery and explicit rollback never delegate to a different installer.'}
 foreach($name in 'CallerPath','CallerSha256','HelperSha256','ManifestHelperSha256','PackageRoot','Payload','VerifiedPackagePath','Archive','FeedEnvelope','TargetVersion','VerifiedVersion','PackageVersion','InstalledVersion','ParentExtraction'){
  if($Context.$name -isnot [string] -or !$Context.$name -or $Context.$name -match '["\x00-\x1f]'){throw 'The verified update delegation context is incomplete.'}
 }
 foreach($name in 'CallerSha256','HelperSha256','ManifestHelperSha256'){if($Context.$name -cnotmatch '^[a-f0-9]{64}$'){throw 'The update helper identity is invalid.'}}
 if($Context.HelperSha256 -cne $Context.ManifestHelperSha256 -or $Context.VerifiedVersion -cne $Context.TargetVersion -or $Context.PackageVersion -cne $Context.TargetVersion -or $Context.Payload -ine $Context.PackageRoot -or $Context.VerifiedPackagePath -ine $Context.PackageRoot -or $Context.TargetVersion -cnotmatch '^\d+\.\d+\.\d+$' -or $Context.InstalledVersion -cnotmatch '^\d+\.\d+\.\d+$' -or [version]$Context.TargetVersion -lt [version]$Context.InstalledVersion -or $Context.Completed -isnot [bool] -or !$Context.Completed){throw 'The delegation must use this same verified signed release and installed server.'}
 foreach($name in 'EnginePaused','Stopped','BackupReady','Success','OperatorUpdaterStopped','OperatorUpdaterWasRunning','RestoreStarted','RecoveryRestoreStarted','OperatorRollback','UpgradeCommitted'){
  if($Context.$name -isnot [bool] -or $Context.$name){throw 'Installer delegation is allowed only before any PBX transaction or service change.'}
 }
 if($Context.Backup -cne '' -or $null -ne $Context.PhpRuntime -or $null -ne $Context.CallRecordsHold -or $null -ne $Context.RecoveryEntry){throw 'The parent update has already prepared persistent transaction state.'}
 foreach($name in 'Check','Automatic'){if($Context.$name -isnot [bool]){throw 'Update options must retain their original boolean values.'}}
 if($Context.HelperSha256 -ceq $Context.CallerSha256){return $null}
 $arguments=@('-NoProfile','-NonInteractive','-Mta','-ExecutionPolicy','Bypass','-File',([IO.Path]::Combine($Context.PackageRoot,'Upgrade-OpenWebPBX.ps1')),'-Archive',$Context.Archive,'-FeedEnvelope',$Context.FeedEnvelope,'-TargetVersion',$Context.TargetVersion)
 if($Context.Check){$arguments+='-Check'}
 if($Context.Automatic){$arguments+='-Automatic'}
 return [pscustomobject]@{Arguments=$arguments;PackageRoot=$Context.PackageRoot;CallerPath=$Context.CallerPath;CallerSha256=$Context.CallerSha256;HelperSha256=$Context.HelperSha256;ParentExtraction=$Context.ParentExtraction;Original23=[bool]$Original23}
}
function New-OpenWebUpgradeDelegationContext {
 param([Parameter(Mandatory)][string]$PackageRoot,[Parameter(Mandatory)][string]$CallerPath)
 $delegationManifest=Get-Content -LiteralPath (Join-Path $PackageRoot 'release-manifest.json') -Raw -Encoding UTF8|ConvertFrom-Json
 [pscustomobject]@{
  CallerPath=$CallerPath;CallerSha256=(Get-FileHash -LiteralPath $CallerPath -Algorithm SHA256).Hash.ToLowerInvariant()
  HelperSha256=(Get-FileHash -LiteralPath (Join-Path $PackageRoot 'Upgrade-OpenWebPBX.ps1') -Algorithm SHA256).Hash.ToLowerInvariant();ManifestHelperSha256=$delegationManifest.files.'Upgrade-OpenWebPBX.ps1'
  PackageRoot=$PackageRoot;Payload=$payload;VerifiedPackagePath=$verified.package_path;VerifiedVersion=$verified.version;TargetVersion=$TargetVersion;PackageVersion=(Get-Content -LiteralPath (Join-Path $PackageRoot 'VERSION') -Raw).Trim()
  InstalledVersion=$state.Version;Completed=$state.Completed;Archive=$Archive;FeedEnvelope=$FeedEnvelope;ParentExtraction=$extracted
  Check=[bool]$Check;Automatic=[bool]$Automatic;Recover=[bool]$Recover;RestoreBackup=[string]$RestoreBackup
  EnginePaused=$script:enginePaused;Stopped=$stopped;BackupReady=$backupReady;Success=$success;OperatorUpdaterStopped=$script:operatorUpdaterStopped;OperatorUpdaterWasRunning=$script:operatorUpdaterWasRunning
  RestoreStarted=$restoreStarted;RecoveryRestoreStarted=$recoveryRestoreStarted;OperatorRollback=$script:operatorRollback;UpgradeCommitted=$script:upgradeCommitted
  Backup=$backup;PhpRuntime=$phpRuntime;CallRecordsHold=$script:callRecordsHold;RecoveryEntry=$script:upgradeRecoveryEntry
 }
}
function Invoke-OpenWebUpgradeDelegationProcess {
 param([Parameter(Mandatory)][string]$Command,[Parameter(Mandatory)][string[]]$Arguments)
 $previousPreference=$ErrorActionPreference;$delegationExit=$null
 try{$ErrorActionPreference='Continue';$global:LASTEXITCODE=$null;& $Command @Arguments|ForEach-Object {Write-Host $_};$delegationExit=$global:LASTEXITCODE}
 finally{$ErrorActionPreference=$previousPreference}
 if($null -eq $delegationExit){throw 'The verified release installer could not be started.'}
 return [int]$delegationExit
}
function Invoke-OpenWebUpgradeDelegation {
 param([Parameter(Mandatory)]$Plan,[Parameter(Mandatory)][IO.FileStream]$MaintenanceLock,[Parameter(Mandatory)][string]$StateRoot)
 Assert-OpenWebRecoveryLock -MaintenanceLock $MaintenanceLock -StateRoot $StateRoot
 $staging=[IO.Path]::GetFullPath((Join-Path $StateRoot 'updates\staging')).TrimEnd('\')
 $parent=[IO.Path]::GetFullPath($Plan.ParentExtraction).TrimEnd('\')
 $package=[IO.Path]::GetFullPath($Plan.PackageRoot).TrimEnd('\')
 if([IO.Path]::GetDirectoryName($parent) -ine $staging -or [IO.Path]::GetFileName($parent) -cnotmatch '^[a-f0-9]{32}$' -or !$package.StartsWith($parent+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'The original verified extraction must remain in its own staging leaf.'}
 $null=Assert-OpenWebRecoveryProtected $parent -Directory
 $null=Assert-OpenWebRecoveryProtected $package -Directory
 $null=Assert-OpenWebRecoveryProtected $Plan.CallerPath
 $helper=Join-Path $package 'Upgrade-OpenWebPBX.ps1';$null=Assert-OpenWebRecoveryProtected $helper
 if((Get-FileHash -LiteralPath $helper -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Plan.HelperSha256 -or (Get-FileHash -LiteralPath $Plan.CallerPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Plan.CallerSha256){throw 'An update helper changed before verified delegation.'}
 # No backup, journal or service changes exist in the wrapper. The child owns
 # a new sibling extraction, acquires upgrade.lock and re-verifies the original
 # archive/envelope under the unchanged installed version and trust history.
 $MaintenanceLock.Dispose()
 Write-Host 'Using the verified release installer for the complete update transaction.'
 Invoke-OpenWebUpgradeDelegationProcess -Command (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Arguments $Plan.Arguments
}
function Get-OpenWebPhpRuntimeSource {
 [pscustomobject]@{Version='8.4.27';Url='https://downloads.php.net/~windows/releases/archives/php-8.4.27-nts-Win32-vs17-x64.zip';Sha256='93bd8a815a52156606fb906d0573437908c61f96e2cc52c03a51e36a41bf5236'}
}
function Assert-OpenWebPhpOrdinary {
 param([Parameter(Mandatory)][string]$Path,[switch]$Directory)
 $full=[IO.Path]::GetFullPath($Path)
 $item=Get-Item -LiteralPath $full -Force -ErrorAction Stop
 if($Directory -and !$item.PSIsContainer){throw 'The PHP runtime directory is not an ordinary folder.'}
 $current=$item
 while($null -ne $current){
  if($current.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'The PHP runtime path contains a link or junction.'}
  $parent=[IO.Path]::GetDirectoryName($current.FullName)
  if(!$parent -or $parent -eq $current.FullName){break}
  $current=Get-Item -LiteralPath $parent -Force -ErrorAction Stop
 }
 return $full
}
function Expand-OpenWebPhpArchive {
 param([Parameter(Mandatory)][string]$Archive,[Parameter(Mandatory)][string]$Destination)
 Add-Type -AssemblyName System.IO.Compression.FileSystem
 $zip=[IO.Compression.ZipFile]::OpenRead($Archive)
 try{
  $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $entries=[Collections.Generic.List[object]]::new();$total=[long]0
  foreach($entry in $zip.Entries){
   $relative=$entry.FullName.Replace('\','/')
   if(!$relative -or $relative.Length -gt 240 -or $relative -cmatch '[\x00-\x1f\x7f:]' -or $relative.StartsWith('/') -or $relative -match '(^|/)(\.{1,2}|[^/]*[ .])(/|$)' -or !$seen.Add($relative.TrimEnd('/'))){throw 'The PHP archive contains an unsafe or repeated path.'}
   if(($entry.ExternalAttributes -band 0x400) -or (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000){throw 'PHP runtime archive links are not allowed.'}
   if($relative -ieq 'php.ini'){throw 'The runtime archive must not replace local PHP configuration.'}
   $total+=$entry.Length
   if($entries.Count -ge 10000 -or $total -gt 536870912 -or $entry.Length -lt 0){throw 'The PHP archive exceeds its bounded runtime inventory.'}
   $entries.Add(@{Entry=$entry;Relative=$relative;Directory=$relative.EndsWith('/')})
  }
  if(!$seen.Contains('php.exe') -or !$seen.Contains('php-cgi.exe') -or !$seen.Contains('php8.dll')){throw 'The PHP archive is missing its native runtime.'}
  # Validate every name before creating any output. The caller owns a new leaf.
  $prefix=[IO.Path]::GetFullPath($Destination).TrimEnd('\')+'\'
  foreach($row in $entries){
   $target=[IO.Path]::GetFullPath((Join-Path $Destination $row.Relative))
   if(!$target.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'The PHP runtime escapes its staged directory.'}
   if($row.Directory){$null=[IO.Directory]::CreateDirectory($target);continue}
   $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
   $entryStream=$row.Entry.Open();$output=$null
   try{$output=[IO.File]::Open($target,'CreateNew','Write','None');$entryStream.CopyTo($output);$output.Flush($true)}finally{if($output){$output.Dispose()};$entryStream.Dispose()}
  }
 }finally{$zip.Dispose()}
}
function Assert-OpenWebPhpTree {
 param([Parameter(Mandatory)][string]$Directory)
 $null=Assert-OpenWebPhpOrdinary -Path $Directory -Directory
 if(!('OpenWebPhpFileIdentityV1' -as [type])){
  Add-Type -TypeDefinition @'
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class OpenWebPhpFileIdentityV1 {
 [StructLayout(LayoutKind.Sequential)] struct Info {
  public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Creation,Access,Write;
  public uint Volume,SizeHigh,SizeLow,Links,IndexHigh,IndexLow;
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
 $pending=[Collections.Generic.Stack[string]]::new();$pending.Push($Directory)
 while($pending.Count){
  foreach($item in Get-ChildItem -LiteralPath $pending.Pop() -Force -ErrorAction Stop){
   if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'The installed PHP runtime contains a link or junction.'}
   if($item.PSIsContainer){$pending.Push($item.FullName)}
   elseif(![OpenWebPhpFileIdentityV1]::SingleLink($item.FullName)){throw 'The PHP runtime contains a hard link or unreadable file identity.'}
  }
 }
}
function Prepare-OpenWebPhpRuntime {
 param([Parameter(Mandatory)][string]$UpdatesRoot)
 $null=Assert-OpenWebPhpOrdinary -Path $UpdatesRoot -Directory
 $spec=Get-OpenWebPhpRuntimeSource
 $archive=Join-Path $UpdatesRoot ('php-'+$spec.Sha256+'.zip')
 if(Test-Path -LiteralPath $archive){$null=Assert-OpenWebPhpOrdinary -Path $archive}
 else{
  $temporary=Join-Path $UpdatesRoot ('php-download-'+[Guid]::NewGuid().ToString('N')+'.zip')
  try{
   & curl.exe --fail --location --proto '=https' --tlsv1.2 --max-time 180 --retry 2 --output $temporary $spec.Url | Out-Null
   if($LASTEXITCODE -ne 0 -or (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash -ine $spec.Sha256){throw 'The PHP runtime download failed its pinned integrity check.'}
   [IO.File]::Move($temporary,$archive)
  }finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force -ErrorAction Stop}}
 }
 if((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ine $spec.Sha256){throw 'The cached PHP runtime does not match this release.'}
 $directory=Join-Path $UpdatesRoot ('php-stage-'+[Guid]::NewGuid().ToString('N'))
 $null=[IO.Directory]::CreateDirectory($directory)
 try{
  Expand-OpenWebPhpArchive -Archive $archive -Destination $directory
  $executable=Join-Path $directory 'php.exe'
  $version=& $executable -n -r 'echo PHP_VERSION,chr(47),PHP_INT_SIZE,chr(47),(int)PHP_ZTS;'
  if($LASTEXITCODE -ne 0 -or ($version -join '') -cne ($spec.Version+'/8/0')){throw 'The staged PHP runtime is not the required native x64 NTS version.'}
  $files=@{}
  foreach($file in Get-ChildItem -LiteralPath $directory -File -Recurse -Force){$files[$file.FullName.Substring($directory.Length+1)]=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
  $directories=@(Get-ChildItem -LiteralPath $directory -Directory -Recurse -Force|ForEach-Object {$_.FullName.Substring($directory.Length+1)})
  return [pscustomobject]@{Directory=$directory;Version=$spec.Version;ArchiveSha256=$spec.Sha256;Files=$files;Directories=$directories}
 }catch{Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction Stop;throw}
}
function Install-OpenWebPhpRuntime {
 param([Parameter(Mandatory)]$Prepared,[Parameter(Mandatory)][string]$Root)
 $null=Assert-OpenWebPhpOrdinary -Path $Prepared.Directory -Directory
 Assert-OpenWebPhpTree -Directory $Prepared.Directory
 $target=Join-Path $Root 'php';$null=Assert-OpenWebPhpOrdinary -Path $target -Directory
 Assert-OpenWebPhpTree -Directory $target
 $prefix=[IO.Path]::GetFullPath($Prepared.Directory).TrimEnd('\')+'\'
 $currentFiles=@(Get-ChildItem -LiteralPath $Prepared.Directory -File -Recurse -Force)
 if($currentFiles.Count -ne $Prepared.Files.Count){throw 'The staged PHP file inventory changed before deployment.'}
 foreach($file in $currentFiles){if(!$Prepared.Files.ContainsKey($file.FullName.Substring($prefix.Length))){throw 'An unexpected PHP file was added before deployment.'}}
 $currentDirectories=@(Get-ChildItem -LiteralPath $Prepared.Directory -Directory -Recurse -Force|ForEach-Object {$_.FullName.Substring($prefix.Length)})
 if(@(Compare-Object @($Prepared.Directories) $currentDirectories).Count){throw 'The staged PHP directory inventory changed before deployment.'}
 foreach($entry in $Prepared.Files.GetEnumerator()){
  $path=[IO.Path]::GetFullPath((Join-Path $Prepared.Directory $entry.Key))
  if(!$path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or $entry.Key -ieq 'php.ini' -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $entry.Value){throw 'The staged PHP runtime changed before deployment.'}
 }
 # Existing php.ini, custom extensions and extra trust files remain. Copying
 # data onto existing files also preserves their current NTFS descriptors.
 CopyTree $Prepared.Directory $target
 foreach($entry in $Prepared.Files.GetEnumerator()){
  if((Get-FileHash -LiteralPath (Join-Path $target $entry.Key) -Algorithm SHA256).Hash -ine $entry.Value){throw 'The installed PHP runtime is incomplete; recovery is required.'}
 }
}
function Test-OpenWebPhpBackup {
 param([Parameter(Mandatory)][string]$Backup,[Parameter(Mandatory)][string]$Root)
 $manifest=Get-Content -LiteralPath (Join-Path $Backup 'backup-manifest.json') -Raw|ConvertFrom-Json
 $entries=@($manifest.files.PSObject.Properties|Where-Object {$_.Name.StartsWith('php/',[StringComparison]::OrdinalIgnoreCase)})
 $directory=Join-Path $Backup 'php'
 if(!$entries.Count){
  if(Test-Path -LiteralPath $directory){throw 'An unsealed PHP runtime was added to an older recovery backup.'}
  return $false
 }
 Assert-OpenWebPhpTree -Directory $directory
 $files=@(Get-ChildItem -LiteralPath $directory -File -Recurse -Force)
 if($files.Count -ne $entries.Count){throw 'The PHP recovery file inventory differs from its sealed manifest.'}
 $expected=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
 foreach($entry in $entries){$expected.Add($entry.Name,[string]$entry.Value)}
 foreach($file in $files){
  $name='php/'+$file.FullName.Substring($directory.Length+1).Replace('\','/')
  if(!$expected.ContainsKey($name) -or (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ine $expected[$name]){throw 'The sealed PHP recovery runtime changed.'}
 }
 # The sealed support record also binds empty directories and their original
 # target names. Never let an added folder enter a mirror recovery unnoticed.
 $support=Get-Content -LiteralPath (Join-Path $Backup 'support-state.json') -Raw|ConvertFrom-Json
 $prefix=[IO.Path]::GetFullPath((Join-Path $Root 'php')).TrimEnd('\')
 $paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
 foreach($entry in $support.Acls.PSObject.Properties){if($entry.Name.Equals($prefix,[StringComparison]::OrdinalIgnoreCase) -or $entry.Name.StartsWith($prefix+'\',[StringComparison]::OrdinalIgnoreCase)){$null=$paths.Add($entry.Name)}}
 $current=@((Get-Item -LiteralPath $directory -Force))+@(Get-ChildItem -LiteralPath $directory -Force -Recurse)
 if($paths.Count -ne $current.Count){throw 'The sealed PHP recovery directory inventory changed.'}
 foreach($item in $current){if(!$paths.Contains($prefix+$item.FullName.Substring($directory.Length))){throw 'A PHP recovery path lacks its original sealed descriptor.'}}
 return $true
}

# Original23 already verifies the complete signed archive before dot-sourcing
# this candidate helper, but its transaction predates newer Windows components.
# Only that exact stock installed caller takes this compatibility entry. Its
# finally block owns only the parent extraction, environment and disposed lock;
# every service, snapshot, journal, rollback and child extraction belongs to the
# newly verified installer. New helpers have their explicit forward entry below.
$openWebUpgradeFrames=@(Get-PSCallStack);$openWebUpgradeCaller=$null
if($openWebUpgradeFrames.Count -gt 1){$openWebUpgradeCaller=$openWebUpgradeFrames[1]}
if($openWebUpgradeCaller -and $openWebUpgradeCaller.ScriptName -ieq 'C:\OpenWebPBX\tools\Upgrade-OpenWebPBX.ps1'){
 $openWebCallerHash=(Get-FileHash -LiteralPath $openWebUpgradeCaller.ScriptName -Algorithm SHA256).Hash.ToLowerInvariant()
 $openWebDelegationMarker=Get-Variable -Name OpenWebVerifiedDelegation -Scope Script -ErrorAction SilentlyContinue
 if($openWebCallerHash -cne '527e17a9349fd5e9f3b1d048fd2f4526495e2cdc5e28f836fe79d8fd17ff1eec'){
  if($state.Version -ceq '1.0.23' -and (!$openWebDelegationMarker -or $openWebDelegationMarker.Value -cne 'v1')){throw 'The installed Windows23 helper differs from the supported original. Preserve it and review its update source.'}
 }else{
 $openWebUpgradeContext=New-OpenWebUpgradeDelegationContext -PackageRoot $PSScriptRoot -CallerPath $openWebUpgradeCaller.ScriptName
 $openWebUpgradePlan=Get-OpenWebUpgradeDelegationPlan -Context $openWebUpgradeContext -Original23
 if(!$openWebUpgradePlan){throw 'The verified Windows27 installer must include its current transaction.'}
 $openWebUpgradeExit=Invoke-OpenWebUpgradeDelegation -Plan $openWebUpgradePlan -MaintenanceLock $lock -StateRoot $private
 exit $openWebUpgradeExit
 }
}
