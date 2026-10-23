#Requires -RunAsAdministrator
[CmdletBinding()]
param([ValidateSet('Refresh','Commit')][string]$Action='Refresh',[string]$StagePath,[ValidateSet('accepted.json','publication.json')][string]$TargetName='accepted.json')
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
# Desktop children can inherit Core module paths. Resolve only actual stock
# dependencies without changing the parent or machine module environment.
function Assert-OpenWebCatalogueStockOrdinary([string]$Path){
 if(![IO.Path]::IsPathRooted($Path) -or (![IO.File]::Exists($Path) -and ![IO.Directory]::Exists($Path))){throw 'An ordinary absolute stock module input is required.'}
 for($entry=[IO.FileInfo]::new($Path);$null-ne $entry;){if($entry.Attributes-band [IO.FileAttributes]::ReparsePoint){throw 'Stock module ancestry must be ordinary.'};if($entry-is [IO.DirectoryInfo]){$entry=$entry.Parent}else{$entry=$entry.Directory}}
}
function Get-OpenWebCatalogueStockProvenance($Command,[ValidateSet('Get-Acl','ConvertFrom-Json','Add-Type')][string]$Name,[string]$NativeHome,[string]$WindowsRoot){
 $proof=[ordered]@{command_type=$false;command_name=$false;module_name=$false;module_path=$false;module_base=$false;module_version=$false;module_guid=$false;source_file=$false;implementation=$false}
 $proof.command_type=$Command-is [Management.Automation.CmdletInfo];if(!$proof.command_type){return $proof}
 $utility=$Name-cne 'Get-Acl';$module=if($utility){'Microsoft.PowerShell.Utility'}else{'Microsoft.PowerShell.Security'};$manifest=[IO.Path]::Combine($NativeHome,'Modules',$module,$module+'.psd1')
 $assembly=$Command.ImplementingType.Assembly;$nameInfo=$assembly.GetName();$location=$assembly.Location
 $proof.command_name=$Command.Name-ceq $Name;$proof.module_name=$Command.ModuleName-ceq $module;$proof.module_path=$Command.Module.Path-ieq $manifest
 $proof.module_base=$Command.Module.ModuleBase-ieq $NativeHome -or (!$utility -and $Command.Module.ModuleBase-ieq [IO.Path]::GetDirectoryName($location))
 $version=if($utility){[version]'3.1.0.0'}else{[version]'3.0.0.0'};$guid=if($utility){[Guid]'1da87e53-152b-403e-98dc-74d7b4d63d59'}else{[Guid]'a94c8c7e-9810-47c0-b8af-65089c13a35a'}
 $proof.module_version=$Command.Module.Version-eq $version;$proof.module_guid=$Command.Module.Guid-eq $guid
 $proof.source_file=$location.StartsWith($WindowsRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)
 $token=([BitConverter]::ToString($nameInfo.GetPublicKeyToken())).Replace('-','').ToLowerInvariant();$assemblyName=if($utility){'Microsoft.PowerShell.Commands.Utility'}else{'Microsoft.PowerShell.Security'}
 $type=switch($Name){'Get-Acl'{'Microsoft.PowerShell.Commands.GetAclCommand'}'ConvertFrom-Json'{'Microsoft.PowerShell.Commands.ConvertFromJsonCommand'}'Add-Type'{'Microsoft.PowerShell.Commands.AddTypeCommand'}}
 $proof.implementation=$Command.ImplementingType.FullName-ceq $type -and $nameInfo.Name-ceq $assemblyName -and $nameInfo.Version-eq [version]'3.0.0.0' -and $token-ceq '31bf3856ad364e35'
 return $proof
}
function Assert-OpenWebCatalogueStockProvenance($Proof){
 $fields=@('command_type','command_name','module_name','module_path','module_base','module_version','module_guid','source_file','implementation')
 if($Proof-isnot [Collections.IDictionary] -or $Proof.Count-ne $fields.Count){throw 'The stock command proof differs.'}
 foreach($field in $fields){if($Proof[$field]-isnot [bool] -or !$Proof[$field]){throw 'The exact stock command provenance differs.'}}
}
function Import-OpenWebCatalogueDesktopModules {
 if([Environment]::OSVersion.Platform-ne [PlatformID]::Win32NT -or $PSVersionTable.PSEdition-cne 'Desktop'){throw 'The stock bootstrap requires Windows PowerShell.'}
 $nativeHome=[IO.Path]::Combine([Environment]::SystemDirectory,'WindowsPowerShell','v1.0');$windows=[Environment]::GetFolderPath('Windows')
 foreach($kind in 'Security','Utility'){
  $module='Microsoft.PowerShell.'+$kind;$manifest=[IO.Path]::Combine($nativeHome,'Modules',$module,$module+'.psd1');Assert-OpenWebCatalogueStockOrdinary $manifest;Import-Module -Name $manifest -Global -Force -ErrorAction Stop
  $names=if($kind-ceq 'Security'){@('Get-Acl')}else{@('ConvertFrom-Json','Add-Type')}
  foreach($name in $names){
   $commands=@(Get-Command -Name ($module+'\'+$name) -All -ErrorAction Stop);if($commands.Count-ne 1){throw 'The stock command is absent or ambiguous.'};$command=$commands[0]
   Assert-OpenWebCatalogueStockProvenance (Get-OpenWebCatalogueStockProvenance $command $name $nativeHome $windows)
   Assert-OpenWebCatalogueStockOrdinary $command.Module.ModuleBase;Assert-OpenWebCatalogueStockOrdinary $command.Module.Path;Assert-OpenWebCatalogueStockOrdinary $command.ImplementingType.Assembly.Location
   $visible=Get-Command -Name $name -ErrorAction Stop;Assert-OpenWebCatalogueStockProvenance (Get-OpenWebCatalogueStockProvenance $visible $name $nativeHome $windows)
  }
 }
}
if($PSVersionTable.PSEdition-ceq 'Desktop'){Import-OpenWebCatalogueDesktopModules}
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
