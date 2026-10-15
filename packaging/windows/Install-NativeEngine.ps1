#Requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PackageRoot,[string]$EngineRoot='C:\Program Files\FreeSWITCH',[string]$StateRoot=(Join-Path $env:ProgramData 'OpenWebPBX'),[switch]$Check)
$ErrorActionPreference='Stop'
$manifestPath=Join-Path $PackageRoot 'engine\native-manifest.json'
$manifest=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if($manifest.schema -ne 1 -or $manifest.core_version -ne '1.11.3' -or
 $manifest.upstream_commit -ne 'ef32e205295e29f034f1453ad245ba5efb07b94a' -or
 $manifest.patch_sha256 -ne '1191411f00efb2ca763a41721207923ffc92f8777aa2ebfa23b342a5e801c26f' -or
 $manifest.source_reg_sha256 -ne '8cee43d5f88b7e1cd158f125b2780409b0c52c7cbac37fd3039a2a8981ddc317' -or
 $manifest.source_msi_sha256 -ne 'f5649e33ad46be2ebdb1d98019bd149c86519f0dca9f47fb881207045203a34d'){
 throw 'The release does not contain the verified Windows call-engine build.'
}
$core=Join-Path $EngineRoot 'FreeSwitch.dll'
if(!(Test-Path -LiteralPath $core -PathType Leaf) -or (Get-FileHash -LiteralPath $core -Algorithm SHA256).Hash -ne $manifest.core_sha256){
 throw 'The installed call engine differs from the supported Windows build. Keep the current engine and review the installation.'
}
if(!$manifest.files.'mod/mod_sofia.dll'){throw 'The patched phone-registration module is missing.'}
$prefix=[IO.Path]::GetFullPath((Join-Path $PackageRoot 'engine')).TrimEnd('\')+'\'
foreach($entry in $manifest.files.PSObject.Properties){
 if($entry.Name -ne 'mod/mod_sofia.dll' -or $entry.Value -notmatch '^[a-f0-9]{64}$'){throw 'The native module inventory is invalid.'}
 $file=[IO.Path]::GetFullPath((Join-Path $prefix $entry.Name))
 if(!$file.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or !(Test-Path -LiteralPath $file -PathType Leaf) -or
  ((Get-Item -LiteralPath $file).Attributes -band [IO.FileAttributes]::ReparsePoint) -or
  (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $entry.Value){throw 'Native call-engine file verification failed.'}
}
if($manifest.core_sha256 -ne '8553d88348093d5067d93369aa9793b38fe9e3c9c9ca0c38216791700bd7f726' -or !$manifest.runtime_dependencies){throw 'The native runtime dependency inventory is incomplete.'}
foreach($entry in $manifest.runtime_dependencies.PSObject.Properties){
 if($entry.Name -notmatch '^[A-Za-z0-9_.-]+\.dll$' -or $entry.Value -notmatch '^[a-f0-9]{64}$'){throw 'The native runtime dependency inventory is invalid.'}
 $file=Join-Path $EngineRoot $entry.Name
 if(!(Test-Path -LiteralPath $file -PathType Leaf) -or ((Get-Item -LiteralPath $file).Attributes -band [IO.FileAttributes]::ReparsePoint) -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $entry.Value){throw 'An installed native dependency differs from the supported Windows build.'}
}
if($Check){Write-Host 'Native call-engine files match the installed Windows core.';return}
$service=Get-Service FreeSWITCH -ErrorAction Stop
if($service.Status -ne 'Stopped'){throw 'Stop the call engine before installing its native modules.'}
# The upgrade helper snapshots these exact destinations before invoking this
# helper. A fresh installer has not yet enabled the PBX call profiles.
foreach($entry in $manifest.files.PSObject.Properties){
 $target=Join-Path $EngineRoot $entry.Name
 New-Item -ItemType Directory -Force (Split-Path $target -Parent) | Out-Null
 Copy-Item -LiteralPath (Join-Path $prefix $entry.Name) -Destination $target -Force
 if((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $entry.Value){throw 'The installed native module failed verification.'}
}
New-Item -ItemType Directory -Force $StateRoot | Out-Null
Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $StateRoot 'native-engine.json') -Force
Write-Host 'Verified native phone-registration modules installed.'
