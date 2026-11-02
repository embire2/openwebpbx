#Requires -RunAsAdministrator
# SPDX-License-Identifier: AGPL-3.0-or-later
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$PackageRoot,[switch]$DeferStart,[IO.FileStream]$MaintenanceLock)
$ErrorActionPreference='Stop';$root='C:\OpenWebPBX';$state=Join-Path $env:ProgramData 'OpenWebPBX';$lockPath=Join-Path $state 'upgrade.lock'
function Install-OpenWebOnboardingCallGate([string]$PackageRoot,[string]$EngineRoot,$Manifest){
 # Immutable21 already calls this payload installer after sealing switch-scripts.
 # Install only this verified code leaf; its original mirror restores absence
 # on rollback. Existing/custom siblings and directory permissions stay intact.
 $relative='web/app/pbx_setup/resources/switch/scripts/app/pbx_onboarding/gate.lua'
 $source=Join-Path $PackageRoot $relative;$null=Assert-OpenWebOrdinaryPath $source
 $pin=$Manifest.files.$relative
 if($pin-isnot [string] -or $pin-cnotmatch '^[a-f0-9]{64}$' -or (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()-cne $pin){throw 'The onboarding call gate differs from the verified Windows release.'}
 $parent=Join-Path $EngineRoot 'scripts/app';$null=Assert-OpenWebOrdinaryPath $parent $true
 $directory=Join-Path $parent 'pbx_onboarding';$target=Join-Path $directory 'gate.lua'
 if(Test-Path -LiteralPath $directory){$null=Assert-OpenWebOrdinaryPath $directory $true}
 if(Test-Path -LiteralPath $target){$null=Assert-OpenWebOrdinaryPath $target}
 if(!(Test-Path -LiteralPath $directory)){New-Item -ItemType Directory -Path $directory|Out-Null}
 Copy-Item -LiteralPath $source -Destination $target -Force
 if((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()-cne $pin){throw 'The deployed onboarding call gate differs from the verified Windows release.'}
}
$owned=$null -eq $MaintenanceLock;$lock=$MaintenanceLock
if($owned){$lock=[IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite','None')}
try{
 if(!$lock.CanRead -or !$lock.CanWrite -or [IO.Path]::GetFullPath($lock.Name) -ne $lockPath){throw 'The owned maintenance lock is required.'}
 . (Join-Path $PSScriptRoot 'PublicAccess.Common.ps1')
 $null=Assert-OpenWebOrdinaryPath (Join-Path $root 'tools') $true
 $manifest=Get-Content -LiteralPath (Join-Path $PackageRoot 'release-manifest.json') -Raw|ConvertFrom-Json
 # The original signed21 helper already calls this installer. Stage the new
 # verified closure only; its existing worker installs the task after commit.
 foreach($name in 'tenant-domains.py','tenant-domains.php','Tenant-Domains.ps1','Install-TenantDomains.ps1','Install-Onboarding.ps1','Ensure-OnboardingUpgrade.ps1','Onboarding-Upgrade.Common.ps1','onboarding.py','onboarding.php','webhotel-onboarding.py'){
  $source=Join-Path $PackageRoot $name;$null=Assert-OpenWebOrdinaryPath $source
  if((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest.files.$name){throw 'A tenant-domain helper differs from the verified release.'}
  $target=Join-Path "$root\tools" $name;if(Test-Path -LiteralPath $target){$null=Assert-OpenWebOrdinaryPath $target}
  Copy-Item -LiteralPath $source -Destination $target -Force
 }
 Install-OpenWebOnboardingCallGate -PackageRoot $PackageRoot -EngineRoot 'C:\Program Files\FreeSWITCH' -Manifest $manifest
 $name='OpenWebPBX-TenantDomains';$description='OpenWeb PBX owned tenant HTTPS lease worker'
 $existing=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
 if($existing -and ($existing.Description -ne $description -or $existing.Principal.UserId -notin 'SYSTEM','S-1-5-18' -or @($existing.Actions).Count -ne 1 -or $existing.Actions[0].Execute -ne "$root\backup-runtime\python.exe" -or $existing.Actions[0].Arguments -cnotin @('-I "C:\OpenWebPBX\tools\tenant-domains.py"','-I -B "C:\OpenWebPBX\tools\tenant-domains.py"') -or $existing.Actions[0].WorkingDirectory -ne "$root\tools")){throw 'The tenant-domain task belongs to another configuration.'}
 $action=New-ScheduledTaskAction -Execute "$root\backup-runtime\python.exe" -Argument '-I -B "C:\OpenWebPBX\tools\tenant-domains.py"' -WorkingDirectory "$root\tools"
 $triggers=@((New-ScheduledTaskTrigger -AtStartup),(New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval ([TimeSpan]::FromMinutes(2))))
 $principal=New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
 $settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::FromMinutes(10))
 Register-ScheduledTask -TaskName $name -Description $description -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Force|Out-Null
 if($DeferStart -or ($existing -and !$existing.Settings.Enabled)){Disable-ScheduledTask -TaskName $name|Out-Null}
 # No HTTP/DNS/ACME or IIS mutations before the transaction commits. The
 # enabled worker prepares its bounded static proof URL under the shared lock.
}finally{if($owned -and $lock){$lock.Dispose()}}
