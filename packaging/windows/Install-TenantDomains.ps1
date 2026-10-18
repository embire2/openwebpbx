#Requires -RunAsAdministrator
# SPDX-License-Identifier: AGPL-3.0-or-later
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$PackageRoot,[switch]$DeferStart,[IO.FileStream]$MaintenanceLock)
$ErrorActionPreference='Stop';$root='C:\OpenWebPBX';$state=Join-Path $env:ProgramData 'OpenWebPBX';$lockPath=Join-Path $state 'upgrade.lock'
$owned=$null -eq $MaintenanceLock;$lock=$MaintenanceLock
if($owned){$lock=[IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite','None')}
try{
 if(!$lock.CanRead -or !$lock.CanWrite -or [IO.Path]::GetFullPath($lock.Name) -ne $lockPath){throw 'The owned maintenance lock is required.'}
 . (Join-Path $PSScriptRoot 'PublicAccess.Common.ps1')
 $null=Assert-OpenWebOrdinaryPath (Join-Path $root 'tools') $true
 $manifest=Get-Content -LiteralPath (Join-Path $PackageRoot 'release-manifest.json') -Raw|ConvertFrom-Json
 foreach($name in 'tenant-domains.py','tenant-domains.php','Tenant-Domains.ps1','Install-TenantDomains.ps1'){
  $source=Join-Path $PackageRoot $name;$null=Assert-OpenWebOrdinaryPath $source
  if((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -ne $manifest.files.$name){throw 'A tenant-domain helper differs from the verified release.'}
  Copy-Item -LiteralPath $source -Destination (Join-Path "$root\tools" $name) -Force
 }
 $name='OpenWebPBX-TenantDomains';$description='OpenWeb PBX owned tenant HTTPS lease worker'
 $existing=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
 if($existing -and ($existing.Description -ne $description -or $existing.Principal.UserId -notin 'SYSTEM','S-1-5-18' -or @($existing.Actions).Count -ne 1 -or $existing.Actions[0].Execute -ne "$root\backup-runtime\python.exe" -or $existing.Actions[0].Arguments -cne '-I "C:\OpenWebPBX\tools\tenant-domains.py"' -or $existing.Actions[0].WorkingDirectory -ne "$root\tools")){throw 'The tenant-domain task belongs to another configuration.'}
 $action=New-ScheduledTaskAction -Execute "$root\backup-runtime\python.exe" -Argument '-I "C:\OpenWebPBX\tools\tenant-domains.py"' -WorkingDirectory "$root\tools"
 $triggers=@((New-ScheduledTaskTrigger -AtStartup),(New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval ([TimeSpan]::FromMinutes(2))))
 $principal=New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
 $settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::FromMinutes(10))
 Register-ScheduledTask -TaskName $name -Description $description -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Force|Out-Null
 if($DeferStart -or ($existing -and !$existing.Settings.Enabled)){Disable-ScheduledTask -TaskName $name|Out-Null}
 # No HTTP/DNS/ACME or IIS mutations before the transaction commits. The
 # enabled worker prepares its bounded static proof URL under the shared lock.
}finally{if($owned -and $lock){$lock.Dispose()}}
