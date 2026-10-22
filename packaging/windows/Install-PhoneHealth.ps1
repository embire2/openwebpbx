#Requires -RunAsAdministrator
# SPDX-License-Identifier: AGPL-3.0-or-later
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PackageRoot,[switch]$DeferStart,[IO.FileStream]$MaintenanceLock)
$ErrorActionPreference='Stop';$root='C:\OpenWebPBX';$state=Join-Path $env:ProgramData 'OpenWebPBX';$lockPath=Join-Path $state 'upgrade.lock'
$owned=$null -eq $MaintenanceLock;$lock=$MaintenanceLock
if($owned){$lock=[IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite','None')}
try{
 if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or !$lock.CanRead -or !$lock.CanWrite -or [IO.Path]::GetFullPath($lock.Name) -ne [IO.Path]::GetFullPath($lockPath)){throw 'The owned Windows maintenance lock is required.'}
 $manifest=Get-Content -LiteralPath (Join-Path $PackageRoot 'release-manifest.json') -Raw|ConvertFrom-Json
 $names=@('Install-PhoneHealth.ps1','Phone-Health.ps1','phone-health.php','PhoneHealth-Security.ps1','PhoneHealth-Firewall.ps1','PhoneHealth-Firewall.Common.ps1')
 foreach($name in $names){$source=Join-Path $PackageRoot $name;$item=Get-Item -LiteralPath $source -Force;if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -cne $manifest.files.$name){throw 'A health helper differs from the verified Windows release.'}}
 . (Join-Path $PackageRoot 'PhoneHealth-Security.ps1')
 $null=Assert-OpenWebHealthProtectedPath (Join-Path $root 'tools') -Directory
 $identity=Join-Path $state 'phone-health-instance.json'
 if(Test-Path -LiteralPath $identity){
  $null=Assert-OpenWebHealthProtectedPath $identity
  if((Get-Item -LiteralPath $identity).Length -gt 256){throw 'The phone health instance identity needs review.'}
  $old=Get-Content -LiteralPath $identity -Raw|ConvertFrom-Json
  if(@($old.PSObject.Properties).Count -ne 2 -or $old.schema -ne 1 -or $old.instance_id -cnotmatch '^[a-f0-9]{64}$'){throw 'The phone health instance identity needs review.'}
 }else{
  $bytes=New-Object byte[] 32;$rng=[Security.Cryptography.RandomNumberGenerator]::Create();try{$rng.GetBytes($bytes)}finally{$rng.Dispose()}
  $value=[ordered]@{schema=1;instance_id=[BitConverter]::ToString($bytes).Replace('-','').ToLowerInvariant()}
  $stream=[IO.File]::Open($identity,'CreateNew','Write','None');try{$data=[Text.UTF8Encoding]::new($false).GetBytes(($value|ConvertTo-Json -Compress));$stream.Write($data,0,$data.Length);$stream.Flush($true)}finally{$stream.Dispose()}
  $acl=[Security.AccessControl.FileSecurity]::new();$acl.SetAccessRuleProtection($true,$false);$acl.SetOwner([Security.Principal.SecurityIdentifier]'S-1-5-32-544')
  foreach($sid in 'S-1-5-18','S-1-5-32-544'){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]$sid,'FullControl','Allow'))}
  $pool=([Security.Principal.NTAccount]'IIS AppPool\OpenWebPBX').Translate([Security.Principal.SecurityIdentifier]);$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($pool,'Read','Allow'));Set-Acl -LiteralPath $identity -AclObject $acl
  $null=Assert-OpenWebHealthProtectedPath $identity
 }
 $name='OpenWebPBX-PhoneHealth';$description='OpenWeb PBX owned phone health and Windows security observer'
 $existing=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
 $execute="$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe";$arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\OpenWebPBX\tools\Phone-Health.ps1"'
 Assert-OpenWebHealthTask $existing
 # The shared exclusive maintenance lock proves no operation is in progress;
 # never keep old resident PHP running after installing a new source tree.
 Stop-OpenWebHealthTask -MaintenanceLock $lock
 foreach($file in $names){
  $target=Join-Path "$root\tools" $file;Copy-Item -LiteralPath (Join-Path $PackageRoot $file) -Destination $target -Force
  $acl=[Security.AccessControl.FileSecurity]::new();$acl.SetAccessRuleProtection($true,$false);$acl.SetOwner([Security.Principal.SecurityIdentifier]'S-1-5-32-544')
  foreach($sid in 'S-1-5-18','S-1-5-32-544'){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]$sid,'FullControl','Allow'))};Set-Acl -LiteralPath $target -AclObject $acl
  $null=Assert-OpenWebHealthProtectedPath $target
 }
 $action=New-ScheduledTaskAction -Execute $execute -Argument $arguments -WorkingDirectory "$root\tools"
 $triggers=@((New-ScheduledTaskTrigger -AtStartup),(New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval ([TimeSpan]::FromMinutes(1))))
 $principal=New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
 $settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval ([TimeSpan]::FromMinutes(1))
 Register-ScheduledTask -TaskName $name -Description $description -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Force|Out-Null
 if($DeferStart -or ($existing -and !$existing.Settings.Enabled)){Disable-ScheduledTask -TaskName $name|Out-Null}
 # The transaction enables/starts the task only after commit. Workers recheck
 # the shared lock, complete installation and update/restore hold journals.
}finally{if($owned -and $lock){$lock.Dispose()}}
