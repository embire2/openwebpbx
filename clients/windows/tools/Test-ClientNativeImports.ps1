# SPDX-License-Identifier: AGPL-3.0-or-later
#Requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string]$AppRoot,[Parameter(Mandatory)][string]$DumpBin,[Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string]$SourceCommit,[Parameter(Mandatory)][string]$Report)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
if(!$IsWindows -or $env:GITHUB_ACTIONS-cne 'true' -or $env:RUNNER_ENVIRONMENT-cne 'github-hosted' -or $env:RUNNER_OS-cne 'Windows' -or $env:GITHUB_REPOSITORY-cne 'embire2/openwebpbx'){throw 'Only the disposable hosted Windows dependency inventory is allowed.'}
$client=Split-Path $PSScriptRoot -Parent;$repo=Split-Path (Split-Path $client -Parent) -Parent
. (Join-Path $client 'tests/packaging/NativeImports.ps1')
Add-Type -Path (Join-Path $client 'tests/packaging/NativeImportProcess.cs')
$temp=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\');$AppRoot=[IO.Path]::GetFullPath($AppRoot).TrimEnd('\');$DumpBin=[IO.Path]::GetFullPath($DumpBin);$Report=[IO.Path]::GetFullPath($Report)
if(!$AppRoot.StartsWith($temp+'\',[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($AppRoot)-cne 'app' -or [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($AppRoot))-cnotmatch '^phone-package-[a-f0-9]{32}$' -or [IO.Path]::GetDirectoryName($Report)-ine $temp -or [IO.Path]::GetFileName($Report)-cnotmatch '^phone-native-imports-[a-f0-9]{32}\.json$' -or (Test-Path $Report)){throw 'The dependency inventory paths differ.'}
function Ordinary([string]$Path,[bool]$Directory){$item=Get-Item -LiteralPath $Path -Force;if($item.PSIsContainer-ne $Directory){throw 'An ordinary inventory input is required.'};$parent=if($Directory){[IO.DirectoryInfo]::new($Path)}else{[IO.FileInfo]::new($Path)};while($parent){if($parent.Attributes-band [IO.FileAttributes]::ReparsePoint){throw 'Dependency inventory refuses linked inputs.'};$parent=if($parent-is [IO.FileInfo]){$parent.Directory}else{$parent.Parent}};$item}
[void](Ordinary $AppRoot $true);[void](Ordinary (Join-Path $AppRoot 'OpenWebPbx.Phone.App.exe') $false);[void](Ordinary (Join-Path $AppRoot 'updater/OpenWebPbx.Phone.Updater.exe') $false)
$tool=Ordinary $DumpBin $false;$toolRoot=[Environment]::GetFolderPath('ProgramFiles');$toolRoot86=[Environment]::GetFolderPath('ProgramFilesX86')
if($tool.Name-ine 'dumpbin.exe' -or !($DumpBin.StartsWith((Join-Path $toolRoot 'Microsoft Visual Studio')+'\',[StringComparison]::OrdinalIgnoreCase) -or $DumpBin.StartsWith((Join-Path $toolRoot86 'Microsoft Visual Studio')+'\',[StringComparison]::OrdinalIgnoreCase))){throw 'Use the ordinary installed Microsoft Visual Studio DUMPBIN.'}
$signature=Get-AuthenticodeSignature -LiteralPath $DumpBin;if($signature.Status-ne 'Valid' -or !$signature.SignerCertificate -or $signature.SignerCertificate.Subject-cnotmatch '(^|, )CN=Microsoft Corporation(,|$)'){throw 'The native dependency reader is not a verified Microsoft tool.'}
$version=$tool.VersionInfo.FileVersion;if($version-cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'){throw 'The native dependency reader version is unrecognised.'}
Push-Location $repo;try{if((git rev-parse HEAD).Trim()-cne $SourceCommit -or (git status --porcelain)){throw 'Exact clean committed source is required.'}}finally{Pop-Location}
$result=[ordered]@{schema=1;producer='Test-ClientNativeImports.ps1';source_commit=$SourceCommit;state='failed';payload_kind='development_package';development_managed_binary=$true;production_binary_tested=$false;actual_native_windows=$true;read_only_import_inventory=$true;loader_tested=$false;clean_machine_qualified=$false;dynamic_loads_covered=$false;store_accepted=$false;tool_sha256=(Get-FileHash $DumpBin -Algorithm SHA256).Hash.ToLowerInvariant();tool_version=$version;tool_microsoft_signature=$true;stage='enumeration'}
$failure=$null;$relative=$null;$started=[DateTime]::UtcNow;$rows=[Collections.Generic.List[object]]::new()
try{
 $entries=@(Get-ChildItem -LiteralPath $AppRoot -Recurse -Force);if($entries.Count-gt 10000 -or @($entries|Where-Object {$_.Attributes-band [IO.FileAttributes]::ReparsePoint}).Count){throw 'The ordinary payload inventory exceeds its scope.'}
 $files=@($entries|Where-Object {!$_.PSIsContainer -and $_.Extension-iin @('.exe','.dll')}|Sort-Object FullName);if($files.Count-lt 2 -or $files.Count-gt 2048){throw 'The native image inventory exceeds its bound.'};$inventory=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase);foreach($image in $files){$inventory.Add($image.FullName,[IO.Path]::GetRelativePath($AppRoot,$image.FullName).Replace('\','/'))}
 foreach($file in $files){
  [void](Ordinary $file.FullName $false)
  if(([DateTime]::UtcNow-$started).TotalSeconds-gt 600 -or $file.Length-lt 64 -or $file.Length-gt 512MB){throw 'The native import inventory deadline or image bound was exceeded.'}
  $relative=[IO.Path]::GetRelativePath($AppRoot,$file.FullName).Replace('\','/');if($relative-cnotmatch '^[A-Za-z0-9_.+/-]{1,240}$' -or $relative.Contains('..')){throw 'The payload image has an unsupported relative name.'}
  $scope=if($relative.StartsWith('updater/',[StringComparison]::Ordinal)){'updater'}else{'app'};$scopeRoot=if($scope-ceq 'updater'){Join-Path $AppRoot 'updater'}else{$AppRoot}
  $before=(Get-FileHash $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant();$result.stage='dumpbin';$read=[OpenWebPbx.PackageAudit.NativeImportProcess]::Run($DumpBin,@('/NOLOGO','/IMPORTS',$file.FullName),[Environment]::SystemDirectory,15)
  if($read.ExitCode-ne 0){$result.child_exit_code=$read.ExitCode;throw 'The actual native dependency reader refused.'};if($read.Stderr.Length-ne 0){throw 'The native dependency reader reported an error.'};$result.stage='parse';$imports=ReadPackageNativeImports $read.Stdout
  if((Get-FileHash $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()-cne $before){throw 'A payload image changed during the inventory.'}
  $dependencies=@();foreach($kind in @('normal','delay')){foreach($name in $imports[$kind]){
   $candidates=@();foreach($directory in @($file.DirectoryName,$scopeRoot)|Select-Object -Unique){$candidate=Join-Path $directory $name;if($inventory.ContainsKey($candidate)){[void](Ordinary $candidate $false);$candidates+=$inventory[$candidate]}}
   $hostImage=Join-Path ([Environment]::SystemDirectory) $name;$hostPresent=Test-Path -LiteralPath $hostImage -PathType Leaf;if($hostPresent){[void](Ordinary $hostImage $false)};$classification=GetPackageImportKind $name ($candidates.Count-gt 0) $hostPresent
   $dependencies+=[ordered]@{name=$name;import_kind=$kind;classification=$classification.kind;vc_runtime=$classification.vc_runtime;host_system32_present=$classification.host_system32_present;bundled_candidates=$candidates}
  }}
  $rows.Add([ordered]@{path=$relative;scope=$scope;bytes=$file.Length;sha256=$before;descriptor_count=$imports.descriptor_count;dependencies=$dependencies})
 }
 foreach($row in $rows){$imagePath=Join-Path $AppRoot $row.path;[void](Ordinary $imagePath $false);if((Get-FileHash $imagePath -Algorithm SHA256).Hash.ToLowerInvariant()-cne $row.sha256){throw 'A payload image changed before the inventory completed.'}}
 if((Get-FileHash $DumpBin -Algorithm SHA256).Hash.ToLowerInvariant()-cne $result.tool_sha256){throw 'The dependency reader changed during the inventory.'}
 $result.stage='complete';$result.state='observed_unqualified';$result.image_count=$rows.Count;$result.images=$rows.ToArray()
}catch{$failure=$_;$result.error_type=$_.Exception.GetType().Name;$result.hresult=[int]$_.Exception.HResult;$result.source_line=[int]$_.InvocationInfo.ScriptLineNumber;$result.completed_image_count=$rows.Count;if($relative -and $relative-cmatch '^[A-Za-z0-9_.+/-]{1,240}$' -and !$relative.Contains('..')){$result.image_relative=$relative};$exception=$_.Exception;for($depth=0;$depth-lt 8 -and $exception;$depth++){if($exception.Data.Contains('reader_cleanup_error_type')){$result.reader_cleanup_failure=[ordered]@{error_type=[string]$exception.Data['reader_cleanup_error_type'];hresult=[int]$exception.Data['reader_cleanup_hresult']}};if($exception.InnerException){$result.inner_error_type=$exception.InnerException.GetType().Name;$result.inner_hresult=[int]$exception.InnerException.HResult};$exception=$exception.InnerException}}
finally{
 try{$bytes=[Text.Encoding]::UTF8.GetBytes(($result|ConvertTo-Json -Depth 9 -Compress));if($bytes.Length-gt 4MB){throw 'The closed import receipt exceeds its bound.'};$file=[IO.File]::Open($Report,'CreateNew','Write','None');try{$file.Write($bytes);$file.Flush($true)}finally{$file.Dispose()}}catch{if($failure){try{$failure.Exception.Data['receipt_write_failed']=$true}catch{}}else{$failure=$_}}
}
if($failure){throw $failure}
