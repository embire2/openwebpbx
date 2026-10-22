#Requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Archive,[Parameter(Mandatory)][string]$FeedEnvelope,[Parameter(Mandatory)][string]$TargetVersion)
if($PSVersionTable.PSEdition -eq 'Core'){throw 'Run this transition in Windows PowerShell (powershell.exe) as administrator.'}
$env:PSModulePath=$PSHOME+'\Modules;'+[Environment]::GetFolderPath('ProgramFiles')+'\WindowsPowerShell\Modules'
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
function Assert-OpenWebLegacyTransition($Installation,[string]$Version){
 if($Installation.Completed -isnot [bool] -or !$Installation.Completed -or $Installation.Version -notmatch '^1\.0\.[3-7]$' -or $Version -cnotmatch '^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$' -or [version]$Version -lt [version]'1.0.20'){
  throw 'This transition supports completed Windows1.0.3 through1.0.7 installations to Windows1.0.20 or newer. Use the complete signed release package.'
 }
}
# The historical Windows helper cannot inventory new native modules. Verify the
# complete signed package using the already installed verifier, then invoke the
# verified new transaction helper. No helper is replaced before its own backup.
$private=Join-Path $env:ProgramData 'OpenWebPBX'
$installation=Get-Content "$private\installation.json" -Raw|ConvertFrom-Json
$updater=Get-Content "$private\updater-install.json" -Raw|ConvertFrom-Json
Assert-OpenWebLegacyTransition $installation $TargetVersion
if(!(Test-Path -LiteralPath $updater.Executable -PathType Leaf)){throw 'The installed release verifier is missing.'}
$transition=Join-Path "$private\updates\legacy-transition" ([Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $transition|Out-Null
& icacls.exe $transition /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F'|Out-Null
if($LASTEXITCODE){throw 'The transition staging directory could not be protected.'}
$wasRunning=(Get-Service OpenWebPBXUpdater).Status -eq 'Running'
$stopped=$false
try{
 $verification=& $updater.Executable --verify-package --archive $Archive --feed-envelope $FeedEnvelope --target-version $TargetVersion --extract-to "$transition\verified"
 if($LASTEXITCODE){throw 'The installed verifier rejected the new release. No PBX services were stopped.'}
 $verified=($verification -join "`n")|ConvertFrom-Json
 $payload=[IO.Path]::GetFullPath([string]$verified.package_path)
 $prefix=[IO.Path]::GetFullPath($transition).TrimEnd('\')+'\'
 if($verified.version -ne $TargetVersion -or !$payload.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'The verified transition payload is invalid.'}
 foreach($name in 'Upgrade-OpenWebPBX.ps1','Restore-Gates.ps1','Support-Recovery.ps1','File-Security.ps1','Install-NativeEngine.ps1','Install-LocalCodec.ps1','Install-TenantDomains.ps1','Tenant-Domains.ps1','tenant-domains.py','tenant-domains.php','Install-PhoneHealth.ps1','PhoneHealth-Security.ps1','Enable-Stun.ps1'){if(!(Test-Path -LiteralPath (Join-Path $payload $name) -PathType Leaf)){throw 'The verified release lacks its complete transaction helpers.'}}
 Stop-Service OpenWebPBXUpdater
 (Get-Service OpenWebPBXUpdater).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(40));$stopped=$true
 $command=[IO.Path]::Combine($env:SystemRoot,'System32\WindowsPowerShell\v1.0\powershell.exe')
 # Pass only bounded local paths/version. Credentials never appear in arguments.
 foreach($value in $payload,$Archive,$FeedEnvelope){if($value.Contains('"') -or $value -match '[\x00-\x1f]'){throw 'Use ordinary local release paths.'}}
 & $command -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$payload\Upgrade-OpenWebPBX.ps1" -Archive $Archive -FeedEnvelope $FeedEnvelope -TargetVersion $TargetVersion
 if($LASTEXITCODE){throw 'The transition did not complete. Review the private update journal and recovery backup.'}
 $current=Get-Content "$private\installation.json" -Raw|ConvertFrom-Json
 if($current.Version -ne $TargetVersion){throw 'The installed Windows version did not advance.'}
 Write-Host 'The new Windows release is installed. Future releases use the normal signed Windows update feed.'
}finally{
 if($stopped -and $wasRunning){
  $safe=$true
  if(Test-Path "$private\updates\install-journal.json"){$journal=Get-Content "$private\updates\install-journal.json" -Raw|ConvertFrom-Json;$safe=$journal.state -in 'completed','rolled_back'}
  if($safe -and (Get-Service OpenWebPBXUpdater).Status -ne 'Running'){Start-Service OpenWebPBXUpdater}
 }
 Remove-Item -LiteralPath $transition -Recurse -Force -ErrorAction SilentlyContinue
}
