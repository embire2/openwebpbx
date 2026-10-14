#Requires -RunAsAdministrator
# SPDX-License-Identifier: AGPL-3.0-or-later
[CmdletBinding()]
param([string]$PackageRoot,[switch]$Tick,[switch]$DeferStart,[IO.FileStream]$MaintenanceLock)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$root='C:\OpenWebPBX';$state=Join-Path $env:ProgramData 'OpenWebPBX';$lockPath=Join-Path $state 'upgrade.lock'
if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'Windows is required.'}
$lock=$MaintenanceLock;$ownsLock=$null -eq $lock
if($ownsLock){
 try{$lock=[IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite','None')}
 catch [IO.IOException]{if($Tick){'{"deferred":true,"reason":"maintenance"}';return};throw 'Another PBX maintenance operation is running.'}
}
try{
 if(-not $lock.CanRead -or -not $lock.CanWrite -or [IO.Path]::GetFullPath($lock.Name) -ne [IO.Path]::GetFullPath($lockPath)){throw 'The owned PBX maintenance lock is required.'}
 . (Join-Path $PSScriptRoot 'Restore-Gates.ps1')
 $gate=Get-OpenWebRestoreGate -StateRoot $state
 if($gate.Blocked -or $gate.Calls -or $gate.Jobs -or $gate.Updates -or $gate.Backups){if($Tick){'{"deferred":true,"reason":"restore"}';return};throw 'Complete backup recovery before enabling outgoing mail.'}
 if($Tick){
  $installationPath=Join-Path $state 'installation.json'
  if(-not (Test-Path -LiteralPath $installationPath)){throw 'Complete installation before dispatching mail.'}
  $installation=Get-Content -LiteralPath $installationPath -Raw|ConvertFrom-Json
  if(-not $installation.Completed){throw 'Complete installation before dispatching mail.'}
  $journalPath=Join-Path $state 'updates\install-journal.json'
  if(Test-Path -LiteralPath $journalPath){$journal=Get-Content -LiteralPath $journalPath -Raw|ConvertFrom-Json;if($journal.state -notin 'completed','rolled_back'){throw 'Complete update recovery before dispatching mail.'}}
  $before=$env:OPENSSL_CONF;$env:OPENSSL_CONF=Join-Path $root 'php\extras\ssl\openssl.cnf'
  try{& "$root\php\php.exe" (Join-Path $PSScriptRoot 'process-mail.php') "$root\web";if($LASTEXITCODE){throw 'Windows mail dispatch did not finish.'}}
  finally{if($null -eq $before){Remove-Item Env:\OPENSSL_CONF -ErrorAction SilentlyContinue}else{$env:OPENSSL_CONF=$before}}
  return
 }
 if(-not $PackageRoot -or -not (Test-Path -LiteralPath (Join-Path $PackageRoot 'process-mail.php'))){throw 'Use the complete Windows release.'}
 $parentAcl=(Get-Acl -LiteralPath $state).Sddl
 $directory=Join-Path $state 'mail'
 if(Test-Path -LiteralPath $directory){$item=Get-Item -LiteralPath $directory -Force;if(-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Private mail storage must be ordinary local storage.'}}
 else{New-Item -ItemType Directory -Path $directory|Out-Null}
 function SetMailAcl([string]$Path,[bool]$Directory){
  $acl=if($Directory){[Security.AccessControl.DirectorySecurity]::new()}else{[Security.AccessControl.FileSecurity]::new()}
  $acl.SetAccessRuleProtection($true,$false);$acl.SetOwner([Security.Principal.SecurityIdentifier]'S-1-5-32-544')
  $inheritance=if($Directory){[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'}else{[Security.AccessControl.InheritanceFlags]::None}
  foreach($sid in 'S-1-5-18','S-1-5-32-544'){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]$sid,'FullControl',$inheritance,'None','Allow'))}
  Set-Acl -LiteralPath $Path -AclObject $acl
 }
 SetMailAcl $directory $true
 foreach($file in Get-ChildItem -LiteralPath $directory -Force){
  if($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $file.Name -notmatch '^dispatch\.[a-f0-9-]{36}\.lock$' -or $file.Length -ne 0){throw 'Private mail storage contains an unexpected object.'}
  SetMailAcl $file.FullName $false
 }
 if((Get-Acl -LiteralPath $state).Sddl -ne $parentAcl){throw 'The containing private-state ACL changed.'}
 New-Item -ItemType Directory -Force "$root\tools"|Out-Null
 foreach($name in 'Install-MailQueue.ps1','process-mail.php','Restore-Gates.ps1'){Copy-Item -LiteralPath (Join-Path $PackageRoot $name) -Destination (Join-Path "$root\tools" $name) -Force}
 $name='OpenWebPBX Outgoing Mail';$description='OpenWeb PBX owned global outgoing mail task'
 $existing=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
 if($existing -and $existing.Description -ne $description){throw 'A task with this name belongs to another configuration.'}
 $action=New-ScheduledTaskAction -Execute "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\OpenWebPBX\tools\Install-MailQueue.ps1" -Tick'
 $trigger=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval ([TimeSpan]::FromMinutes(1))
 $principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
 $settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::FromMinutes(2))
 Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description $description -Force|Out-Null
 if($DeferStart){Disable-ScheduledTask -TaskName $name|Out-Null}else{Start-ScheduledTask -TaskName $name}
 Write-Host 'The global outgoing mail queue is scheduled.'
}finally{if($ownsLock -and $null -ne $lock){$lock.Dispose()}}
