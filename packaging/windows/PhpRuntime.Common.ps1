# SPDX-License-Identifier: AGPL-3.0-or-later
# Dot-sourced only by a verified installer, while its maintenance lock is held.
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
