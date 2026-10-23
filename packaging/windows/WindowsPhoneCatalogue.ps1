#Requires -RunAsAdministrator
[CmdletBinding()]
param([ValidateSet('Refresh','Commit')][string]$Action='Refresh',[string]$StagePath,[ValidateSet('accepted.json','publication.json')][string]$TargetName='accepted.json')
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
. (Join-Path $PSScriptRoot 'WindowsPhoneCatalogue.Common.ps1')
$paths=Get-OpenWebWindowsPhoneCataloguePaths
if($Action -ceq 'Commit'){
 $full=[IO.Path]::GetFullPath($StagePath)
 $prefix=if($TargetName -ceq 'accepted.json'){'accepted'}else{'publication'}
 $digits=if($TargetName -ceq 'accepted.json'){64}else{32}
 if([IO.Path]::GetDirectoryName($full) -ine [IO.Path]::GetFullPath($paths.Directory) -or [IO.Path]::GetFileName($full) -cnotmatch ('^\.'+$prefix+'-[0-9a-f]{'+$digits+'}\.new$')){throw 'The catalogue commit stage is outside its fixed owned directory.'}
 Assert-OpenWebWindowsPhoneCatalogueState $paths -AllowedStage $full
 $null=Assert-OpenWebRecoveryProtected $full
 if((Get-Item -LiteralPath $full).Length -gt 1048576){throw 'The catalogue commit stage is too large.'}
 Assert-OpenWebWindowsPhoneCatalogueParentLease $paths
 if($TargetName -ceq 'accepted.json' -and [IO.Path]::GetFileName($full) -cne ('.accepted-'+(Get-OpenWebRecoveryHash (Read-OpenWebRecoveryBytes $full -Maximum 524288))+'.new')){throw 'The accepted catalogue stage changed before the native commit.'}
 Initialize-OpenWebUpgradeRecoveryNative
 [OpenWebPbx.UpgradeRecoveryNativeV1]::Commit($full,(Join-Path $paths.Directory $TargetName))
 exit 0
}
foreach($file in $paths.Php,$paths.Ini,$paths.Worker){$null=Assert-OpenWebRecoveryProtected $file}
function Invoke-CataloguePhp {
 param([string]$Extra='')
 $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$paths.Php;$start.Arguments='-c "'+$paths.Ini+'" "'+$paths.Worker+'"'+$Extra;$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $child=[Diagnostics.Process]::new();$child.StartInfo=$start
 try{
  if(!$child.Start()){throw 'The catalogue worker did not start.'}
  $output=$child.StandardOutput.ReadToEndAsync();$errorOutput=$child.StandardError.ReadToEndAsync()
  if(!$child.WaitForExit(90000)){try{$child.Kill()}catch{};throw 'The catalogue worker exceeded its deadline.'}
  if(!$output.Wait(2000) -or !$errorOutput.Wait(2000) -or $output.Result.Length -gt 32768 -or $errorOutput.Result.Length -gt 32768 -or $child.ExitCode -ne 0){throw 'The catalogue worker refused the refresh; verify its protected publication record before retry.'}
  return ($output.Result|ConvertFrom-Json -ErrorAction Stop)
 }finally{$child.Dispose()}
}
function Read-CataloguePreparedStage {
 param($Value)
 if($null -eq $Value -or $Value.GetType().FullName -cne 'System.Management.Automation.PSCustomObject' -or @($Value.PSObject.Properties).Count -ne 3){throw 'The read-only catalogue preflight returned an invalid result.'}
 foreach($field in $Value.PSObject.Properties.Name){if($field -cnotin 'schema','state','stage'){throw 'The read-only catalogue preflight returned an unknown field.'}}
 if(($Value.schema -isnot [int] -and $Value.schema -isnot [long]) -or $Value.schema -ne 1 -or $Value.state -isnot [string]){throw 'The read-only catalogue preflight returned an invalid result.'}
 if($Value.state -ceq 'ready' -and $null -eq $Value.stage){return $null}
 if($Value.state -ceq 'prepared_stage' -and $Value.stage -is [string] -and $Value.stage -cmatch '^\.accepted-[0-9a-f]{64}\.new$'){return $Value.stage}
 throw 'The read-only catalogue preflight did not identify an exact pinned stage.'
}
$preflight=Invoke-CataloguePhp ' --prepared-stage-check';$preparedStage=Read-CataloguePreparedStage $preflight
if($null -eq $preparedStage){Assert-OpenWebWindowsPhoneCatalogueState $paths}else{Assert-OpenWebWindowsPhoneCatalogueState $paths -AllowedStage (Join-Path $paths.Directory $preparedStage)}
$result=Invoke-CataloguePhp
if($result.schema -ne 1 -or $result.state -cnotin 'accepted','deferred'){throw 'The catalogue worker returned an invalid result.'}
