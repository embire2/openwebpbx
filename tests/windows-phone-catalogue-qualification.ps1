# Disposable component hook. Run only after root reviews the driver/source/output/cleanup.
#Requires -Version 7.4
param([Parameter(Mandatory)][string]$SourceRoot,[Parameter(Mandatory)][string]$SourceCommit,[string]$PackageRoot,[Parameter(Mandatory)][string]$ReportPath)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'windows_phone_catalogue_proof.ps1')
. (Join-Path $PSScriptRoot 'windows_phone_catalogue_sealed_output.ps1')
. (Join-Path $PSScriptRoot 'windows_phone_catalogue_commit_output.ps1')
$sealedChildOutput=$null;$sealedChildOutputRefused=$false;$sealedCommitOutput=$null;$sealedCommitOutputRefused=$false
$phase='preflight';$source='';$reportOwned=$false;$work=$null;$edition='';$childExit=$null;$childFailure=$null;$packageBound=$false;$stockExact=$false;$childEnded=$true
try{
if(!$IsWindows -or $PSVersionTable.PSEdition -cne 'Core' -or $env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_OS -cne 'Windows' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:GITHUB_REPOSITORY -cne 'embire2/openwebpbx' -or !$env:RUNNER_TEMP){throw 'Catalogue native qualification requires disposable Windows GitHub Actions and PowerShell7.'}
$runner=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')+'\'
$reportFull=[IO.Path]::GetFullPath($ReportPath)
if(!$reportFull.StartsWith($runner,[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $ReportPath)){throw 'A new qualification report inside the runner namespace is required.'}
$parent=[IO.DirectoryInfo]::new([IO.Path]::GetDirectoryName($reportFull));while($null -ne $parent){if(!$parent.Exists -or ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Ordinary qualification report ancestors are required.'};$parent=$parent.Parent};$reportOwned=$true
if($SourceCommit -cnotmatch '^[a-f0-9]{40}$'){throw 'An exact reviewed source commit is required.'}
$phase='source';$source=(git -C $SourceRoot rev-parse HEAD).Trim();if($LASTEXITCODE -or $source -cnotmatch '^[a-f0-9]{40}$' -or $source -cne $SourceCommit){throw 'The immutable checked-out source differs.'}
$names=@(
 'packaging/windows/WindowsPhoneCatalogue.Common.ps1','packaging/windows/WindowsPhoneCatalogue.ps1','packaging/windows/Install-WindowsPhoneCatalogue.ps1',
 'packaging/windows/openssl.cnf','packaging/windows/UpgradeRecovery.Common.ps1','packaging/windows/File-Security.ps1','packaging/windows/Restore-Gates.ps1','packaging/windows/Write-PrivateState.ps1','packaging/windows/PhpRuntime.Common.ps1',
 'packaging/updates/windows-phone-catalogue.php','resources/classes/pbx_windows_phone_catalogue.php','resources/windows-phone/release-public.pem',
 'tests/windows_phone_catalogue_proof.ps1','tests/windows_phone_catalogue_sealed_output.ps1','tests/windows_phone_catalogue_commit_output.ps1','tests/windows_phone_catalogue_commit_controls.ps1','tests/windows_phone_catalogue_sealed_controls.ps1','tests/windows_phone_catalogue_diagnostic_public.pem','tests/windows_phone_catalogue_native.ps1','tests/windows_phone_catalogue_native.php','tests/windows_phone_catalogue_stage.ps1','tests/windows_phone_catalogue_activation.ps1','tests/windows_phone_catalogue_lifecycle.ps1','tests/windows_phone_catalogue_qualification.ps1','tests/windows-phone-catalogue-qualification.ps1','tests/windows_phone_catalogue_failure_controls.ps1','tests/windows_phone_catalogue_failure_controls.php','tests/windows_phone_catalogue_stock_controls.ps1','tests/windows_phone_catalogue_output_controls.ps1')
foreach($name in $names){
 $blob=(git -C $SourceRoot rev-parse --verify ($source+':'+$name)).Trim();if($LASTEXITCODE -or $blob -cnotmatch '^[a-f0-9]{40}$'){throw 'Every native qualification input must be committed in the exact source.'}
 $actual=(git -C $SourceRoot hash-object --no-filters -- (Join-Path $SourceRoot $name)).Trim();if($LASTEXITCODE -or $actual -cne $blob){throw 'An uncommitted native qualification input differs.'}
}
$phase='package';if($PackageRoot){
$packageManifest=Get-Content -LiteralPath (Join-Path $PackageRoot 'release-manifest.json') -Raw|ConvertFrom-Json
foreach($name in $names|Where-Object {!$_.StartsWith('tests/')}){
 $relative=if($name.StartsWith('resources/')){'web/'+$name}else{[IO.Path]::GetFileName($name)}
 $expected=$packageManifest.files.PSObject.Properties[$relative]
 if(!$expected -or $expected.Value -cne (Get-FileHash -LiteralPath (Join-Path $SourceRoot $name) -Algorithm SHA256).Hash.ToLowerInvariant()){throw 'The catalogue source differs from the authenticated candidate manifest.'}
}
$packageBound=$true
}
if((Get-FileHash -LiteralPath (Join-Path $SourceRoot 'resources/windows-phone/release-public.pem') -Algorithm SHA256).Hash.ToLowerInvariant() -cne '608691b241a17352f58b13f7883b9409ddd9bd78c3d32e07ddbfb55b8fc721ed'){throw 'Only the reviewed production PUBLIC key may be copied as source material.'}
$phase='source_controls'
foreach($control in 'windows_phone_catalogue_qualification.ps1','windows_phone_catalogue_failure_controls.ps1','windows_phone_catalogue_stock_controls.ps1','windows_phone_catalogue_sealed_controls.ps1'){
 & (Join-Path $SourceRoot ('tests/'+$control)) -SourceRoot $SourceRoot
 if(!$?){throw 'The strict catalogue source and receipt controls did not pass.'}
}
$phase='preparation';$work=Join-Path $env:RUNNER_TEMP ('OpenWebPBX-Catalogue-Qualification-'+[Guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Path $work
. (Join-Path $SourceRoot 'packaging/windows/UpgradeRecovery.Common.ps1');Set-OpenWebRecoveryPrivate $work -Directory
$bundle=Join-Path $work 'source';$null=New-Item -ItemType Directory -Path $bundle;Set-OpenWebRecoveryPrivate $bundle -Directory
$files=[ordered]@{}
foreach($name in $names){
 $destination=Join-Path $bundle $name;$parent=Split-Path $destination -Parent;$null=[IO.Directory]::CreateDirectory($parent);Copy-Item -LiteralPath (Join-Path $SourceRoot $name) -Destination $destination
 $files[$name]=[ordered]@{bytes=(Get-Item -LiteralPath $destination).Length;sha256=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()}
}
foreach($item in Get-ChildItem -LiteralPath $bundle -Force -Recurse){Set-OpenWebRecoveryPrivate $item.FullName -Directory:$item.PSIsContainer}
$sourceManifest=Join-Path $bundle 'source-manifest.safe.json';[IO.File]::WriteAllText($sourceManifest,(@{schema=1;source_commit=$source;files=$files}|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false));Set-OpenWebRecoveryPrivate $sourceManifest
$manifestHash=(Get-FileHash -LiteralPath $sourceManifest -Algorithm SHA256).Hash.ToLowerInvariant()
. (Join-Path $bundle 'packaging/windows/PhpRuntime.Common.ps1')
$spec=Get-OpenWebPhpRuntimeSource
if($spec.Version -cne '8.4.27' -or $spec.Url -cne 'https://downloads.php.net/~windows/releases/archives/php-8.4.27-nts-Win32-vs17-x64.zip' -or $spec.Sha256 -cne '93bd8a815a52156606fb906d0573437908c61f96e2cc52c03a51e36a41bf5236'){throw 'The exact official PHP source pin differs.'}
$phase='php_runtime';$prepared=Prepare-OpenWebPhpRuntime -UpdatesRoot $work
if($prepared.Version -cne '8.4.27' -or $prepared.Files.Count -ne 79 -or $prepared.ArchiveSha256 -cne $spec.Sha256){throw 'The whole official PHP runtime inventory differs.'}
Set-OpenWebRecoveryPrivate $prepared.Directory -Directory
foreach($item in Get-ChildItem -LiteralPath $prepared.Directory -Force -Recurse){Set-OpenWebRecoveryPrivate $item.FullName -Directory:$item.PSIsContainer}
$phase='php_controls'
$probeStart=[Diagnostics.ProcessStartInfo]::new();$probeStart.FileName=Join-Path $prepared.Directory 'php.exe';$probeStart.Arguments='-n "'+(Join-Path $bundle 'tests/windows_phone_catalogue_failure_controls.php')+'"';$probeStart.UseShellExecute=$false;$probeStart.CreateNoWindow=$true;$probeStart.RedirectStandardOutput=$true;$probeStart.RedirectStandardError=$true
$childEnded=$false;$probe=[Diagnostics.Process]::Start($probeStart);$probeOut=$probe.StandardOutput.ReadToEndAsync();$probeErr=$probe.StandardError.ReadToEndAsync()
try{
 if(!$probe.WaitForExit(30000)){try{$probe.Kill();$childEnded=$probe.WaitForExit(5000)}catch{};throw 'The exact PHP diagnostic controls exceeded their deadline.'};$childEnded=$true;$childExit=[int]$probe.ExitCode
 if(!$probeOut.Wait(2000) -or !$probeErr.Wait(2000) -or $probe.ExitCode -ne 0 -or $probeErr.Result.Length -or $probeOut.Result.Trim() -cne 'PASS 9 actual PHP diagnostic producer/type/privacy/preparation controls; no Windows or production operation'){throw 'The actual PHP diagnostic controls did not pass.'}
}finally{$probe.Dispose()}
$childExit=$null
& (Join-Path $SourceRoot 'tests/windows_phone_catalogue_output_controls.ps1') -SourceRoot $SourceRoot -Php (Join-Path $prepared.Directory 'php.exe')
if(!$?){throw 'The actual pinned-PHP output controls did not pass.'}
& (Join-Path $SourceRoot 'tests/windows_phone_catalogue_commit_controls.ps1') -SourceRoot $SourceRoot -Php (Join-Path $prepared.Directory 'php.exe')
if(!$?){throw 'The actual pinned-PHP commit output controls did not pass.'}
$stock5=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe';$stock7=Join-Path $PSHOME 'pwsh.exe'
$null=Assert-OpenWebRecoveryOrdinary $stock5;$null=Assert-OpenWebRecoveryOrdinary $stock7
if(![IO.Path]::GetFullPath($stock7).StartsWith(([IO.Path]::GetFullPath($env:ProgramFiles).TrimEnd('\')+'\PowerShell\'),[StringComparison]::OrdinalIgnoreCase)){throw 'PowerShell7 must be the ordinary preinstalled runner runtime.'}
function StockRuntimeSnapshot([string]$Path){
 $rows=[ordered]@{};$items=@(Get-Item -LiteralPath $Path -Force)+@(Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction Stop)
 if($items.Count -gt 20000){throw 'The stock runner runtime inventory exceeds its bound.'}
 foreach($item in $items){$null=Assert-OpenWebRecoveryOrdinary $item.FullName -Directory:$item.PSIsContainer;$relative=$item.FullName.Substring($Path.Length).TrimStart('\');$rows[$relative]=[ordered]@{directory=[bool]$item.PSIsContainer;attributes=[int]$item.Attributes;sddl=(Get-Acl -LiteralPath $item.FullName).Sddl};if(!$item.PSIsContainer){$rows[$relative].bytes=$item.Length;$rows[$relative].sha256=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}}
 return ($rows|ConvertTo-Json -Depth 6 -Compress -WarningAction Stop)
}
$phase='runtime_inventory';$stockBefore=StockRuntimeSnapshot $PSHOME
[IO.File]::WriteAllText((Join-Path $work 'stock-ps7-before.private.json'),$stockBefore,[Text.UTF8Encoding]::new($false))
$stock7Hash=(Get-FileHash -LiteralPath $stock7 -Algorithm SHA256).Hash.ToLowerInvariant()
. (Join-Path $bundle 'tests/windows_phone_catalogue_proof.ps1')
$editions=[ordered]@{Desktop=$stock5;Core=$stock7};$results=[ordered]@{};$primary=$null
try{
 foreach($edition in $editions.Keys){
  $phase='native';$childExit=$null;$childFailure=$null;$childEnded=$false
  $childReport=Join-Path $work ('native-'+$edition+'.original.json')
  $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$editions[$edition];$start.Arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+(Join-Path $bundle 'tests/windows_phone_catalogue_native.ps1')+'" -SourceBundle "'+$bundle+'" -SourceManifest "'+$sourceManifest+'" -SourceManifestSha256 '+$manifestHash+' -PhpDirectory "'+$prepared.Directory+'" -ReportPath "'+$childReport+'"';$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
  $child=[Diagnostics.Process]::Start($start);$output=$child.StandardOutput.ReadToEndAsync();$errorOutput=$child.StandardError.ReadToEndAsync()
  try{
   if(!$child.WaitForExit(480000)){throw 'The exact native catalogue edition exceeded its deadline; retain its owned namespace.'};$childEnded=$true;$childExit=[int]$child.ExitCode
   [IO.File]::WriteAllText((Join-Path $work ('native-'+$edition+'.private.out')),$output.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText((Join-Path $work ('native-'+$edition+'.private.err')),$errorOutput.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($false))
   if($child.ExitCode -ne 0 -or $errorOutput.Result.Length -or $output.Result.Length -gt 32768){
    try{if((Get-Item -LiteralPath $childReport).Length -gt 16384){throw 'The native failure report is oversized.'};$childFailure=Read-WindowsPhoneCatalogueNativeFailure (Get-Content -LiteralPath $childReport -Raw|ConvertFrom-Json) $edition}catch{$childFailure=$null}
    if($null -ne $childFailure -and $null -ne $childFailure.php_original){try{$sealedChildOutput=Protect-WindowsPhoneCatalogueOriginal $childReport $childFailure.php_original (Join-Path $bundle 'tests/windows_phone_catalogue_diagnostic_public.pem') $source $env:GITHUB_RUN_ID $edition $childFailure.php_output}catch{$sealedChildOutputRefused=$true}}
    if($null -ne $childFailure -and $null -ne $childFailure.commit_original){try{$sealedCommitOutput=Protect-WindowsPhoneCatalogueCommitOriginal $childReport $childFailure.commit_original (Join-Path $bundle 'tests/windows_phone_catalogue_diagnostic_public.pem') $source $env:GITHUB_RUN_ID $edition $childFailure.php_child_exit}catch{$sealedCommitOutputRefused=$true}}
    throw 'The exact native catalogue component refused; preserve original evidence.'
   }
   $record=Get-Content -LiteralPath $childReport -Raw|ConvertFrom-Json
   $results[$edition]=Read-WindowsPhoneCatalogueQualificationRecord $record $edition $manifestHash $prepared.Files['php.exe']
  }finally{$child.Dispose()}
 }
 $phase='verification';$stockAfter=StockRuntimeSnapshot $PSHOME
 [IO.File]::WriteAllText((Join-Path $work 'stock-ps7-after.private.json'),$stockAfter,[Text.UTF8Encoding]::new($false))
 if($stockBefore -cne $stockAfter){throw 'The complete preinstalled PowerShell7 runtime inventory changed.'};$stockExact=$true
 $final=[ordered]@{schema=1;producer='windows-phone-catalogue-qualification.ps1';state='passed';source_commit=$source;package_source_bound=$packageBound;source_manifest_sha256=$manifestHash;php_version='8.4.27';php_archive_sha256=$spec.Sha256;php_vendor_files=79;stock_ps7_version=$PSVersionTable.PSVersion.ToString();stock_ps7_executable_sha256=$stock7Hash;stock_ps7_inventory_exact=$true;desktop=$results.Desktop;core=$results.Core;actual_iis_reader_tested=$false;full_upgrade_restore_qualified=$false;production_release_published=$false}
 $phase='report';[IO.File]::WriteAllText($ReportPath,($final|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
}catch{$primary=$_;try{$stockAfter=StockRuntimeSnapshot $PSHOME;[IO.File]::WriteAllText((Join-Path $work 'stock-ps7-after.private.json'),$stockAfter,[Text.UTF8Encoding]::new($false));if($stockBefore -cne $stockAfter){$primary.Exception.Data['stock_runtime_preservation_failed']=$true}else{$stockExact=$true}}catch{$primary.Exception.Data['stock_runtime_observation_failed']=$true};throw $primary}
# No recursive evidence cleanup or owner runtime reuse. The normal suite controls artifact retention.

}catch{
 $failure=$_
 if($reportOwned){try{
  $meta=Get-WindowsPhoneCatalogueFailureMetadata $failure
  $retained=[bool]($work -and (Test-Path -LiteralPath $work))
  $sourceSafe=if($source -cmatch '^[a-f0-9]{40}$'){$source}else{''}
  $nativeCleanup=($null -ne $childFailure -and !$childFailure.cleanup_required)
  $record=[ordered]@{schema=1;producer='windows-phone-catalogue-qualification.ps1';state='failed';source_commit=$sourceSafe;phase=$phase;source_basename=$meta.source_basename;source_line=$meta.source_line;error_type=$meta.error_type;edition=$edition;child_exit=$childExit;child_ended=$childEnded;child_failure=$childFailure;sealed_child_output=$sealedChildOutput;sealed_child_output_refused=$sealedChildOutputRefused;sealed_commit_output=$sealedCommitOutput;sealed_commit_output_refused=$sealedCommitOutputRefused;package_source_bound=$packageBound;stock_runtime_preservation_verified=$stockExact;owned_scope_retained=$retained;native_cleanup_verified=$nativeCleanup;full_upgrade_restore_qualified=$false;production_release_published=$false}
  $stream=[IO.File]::Open($ReportPath,'CreateNew','Write','None');try{$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($record|ConvertTo-Json -Depth 10));$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
 }catch{$failure.Exception.Data['catalogue_top_level_failure_report_failed']=$true}}
 throw $failure
}
