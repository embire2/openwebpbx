#Requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PackageRoot,[switch]$DeferRestart,[switch]$DeferServiceSelection)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if($PSVersionTable.PSEdition -eq 'Core'){throw 'Run this helper in Windows PowerShell (powershell.exe) as administrator.'}
if(-not ('OpenWebUpdaterCommit' -as [type])){Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class OpenWebUpdaterCommit {
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
 public static extern bool MoveFileEx(string oldName,string newName,int flags);
}
'@}
function SaveState([string]$Path,$Value){
 $temp=$Path+'.'+[Guid]::NewGuid().ToString('N')+'.new';$bytes=(New-Object Text.UTF8Encoding($false)).GetBytes(($Value|ConvertTo-Json -Depth 5))
 try{$file=[IO.File]::Open($temp,'CreateNew','Write','None');try{$file.Write($bytes,0,$bytes.Length);$file.Flush($true)}finally{$file.Dispose()};if(![OpenWebUpdaterCommit]::MoveFileEx($temp,$Path,9)){throw 'Updater state could not be committed.'}}finally{Remove-Item $temp -Force -ErrorAction SilentlyContinue}
}
$root='C:\OpenWebPBX';$private=Join-Path $env:ProgramData OpenWebPBX
$version=(Get-Content "$PackageRoot\VERSION" -Raw).Trim()
if($version -notmatch '^\d+\.\d+\.\d+$' -or !(Test-Path "$PackageRoot\updater\OpenWebPbx.Updater.exe")){throw 'The release is missing its updater service.'}
$slot="$root\updater\slots\$version"
$public=Join-Path $env:ProgramData OpenWebPBX-Status
New-Item -ItemType Directory -Force $slot,"$root\tools","$private\updates","$private\updates\logs","$private\updates\downloads","$private\updates\staging",$public|Out-Null
foreach($directory in "$root\updater","$root\tools","$private\updates"){
 & icacls.exe $directory /inheritance:r /grant '*S-1-5-32-544:(OI)(CI)F' /grant '*S-1-5-18:(OI)(CI)F'|Out-Null
 if($LASTEXITCODE){throw 'Updater permissions could not be applied.'}
}
# Manager helper is fixed application code, readable/executable by local users.
& icacls.exe "$root\tools" /grant '*S-1-5-32-545:(OI)(CI)RX'|Out-Null
& icacls.exe $public /inheritance:r /grant '*S-1-5-32-544:(OI)(CI)F' /grant '*S-1-5-18:(OI)(CI)F' /grant '*S-1-5-32-545:(OI)(CI)RX'|Out-Null
if($LASTEXITCODE){throw 'Public update status permissions could not be applied.'}
$existing=Get-Service OpenWebPBXUpdater -ErrorAction SilentlyContinue
# Never overwrite the executable of a running updater. A same-version reinstall
# already has these immutable signed bytes and can retain its existing slot.
if(!(Test-Path "$slot\OpenWebPbx.Updater.exe")){
 & robocopy.exe "$PackageRoot\updater" $slot /E /COPY:DAT /DCOPY:T /R:1 /W:1 /NFL /NDL /NJH /NJS /NP|Out-Null
 if($LASTEXITCODE -ge 8){throw 'The independent updater could not be installed.'}
}else{
 foreach($file in Get-ChildItem "$PackageRoot\updater" -Recurse -File){
  $relative=$file.FullName.Substring((Get-Item "$PackageRoot\updater").FullName.Length+1)
  if(!(Test-Path (Join-Path $slot $relative)) -or (Get-FileHash $file.FullName).Hash -ne (Get-FileHash (Join-Path $slot $relative)).Hash){throw 'An updater slot with different bytes already exists for this version.'}
 }
}
foreach($name in 'Upgrade-OpenWebPBX.ps1','Register-ManagerRestart.ps1','Restart-Updater.ps1','Remove-Updater.ps1','Request-ServerUpdate.ps1','Watch-ServerUpdates.ps1',
 'Restore-Gates.ps1','Write-PrivateState.ps1','Support-Recovery.ps1','UpgradeRecovery.Common.ps1','CallRecords.Common.ps1','Web-Readiness.ps1','File-Security.ps1','Install-NativeEngine.ps1','Install-LocalCodec.ps1','configure-codec.php','check-call-engine.php','windows-log.php','Configure-PHP.ps1','PhpRuntime.Common.ps1',
 'configure-notifications.ps1','configure-music.php','Install-Dtls.ps1','Dtls.Common.ps1','configure-dtls.php','Enable-PhoneTLS.ps1','phone-tls.php','phone-tls-chain.php',
 'Test-PhoneTLS.ps1','Enable-PublicAccess.ps1','Renew-PhoneCertificate.ps1','PublicAccess.Common.ps1','public-listeners.php','public-listeners-policy.php','public-listeners-esl.php','Enable-Stun.ps1',
 'Install-Backups.ps1','Backup-Control.ps1','configure-backups.php','backups.py','cacert.pem','openssl.cnf'){
 Copy-Item (Join-Path $PackageRoot $name) (Join-Path "$root\tools" $name) -Force
}
foreach($name in 'Install-MailQueue.ps1','process-mail.php','Upgrade-LegacyWindows.ps1','Tenant-Domains.ps1','Install-TenantDomains.ps1','tenant-domains.py','tenant-domains.php'){Copy-Item (Join-Path $PackageRoot $name) (Join-Path "$root\tools" $name) -Force}
Import-Module WebAdministration
$startup="$private\updater-original-startup.json"
if(!(Test-Path $startup)){
 $saved=@{Services=@{};SiteAutoStart=(Get-ItemProperty IIS:\Sites\OpenWebPBX serverAutoStart).serverAutoStart;PoolAutoStart=(Get-ItemProperty IIS:\AppPools\OpenWebPBX autoStart).autoStart}
 foreach($name in 'OpenWebPBX','FreeSWITCH'){$saved.Services[$name]=(Get-CimInstance Win32_Service -Filter "Name='$name'").StartMode}
 SaveState $startup $saved
}
$executable="$slot\OpenWebPbx.Updater.exe"
# An upgrade stages its complete slot/helpers while SCM still selects the
# previous executable. Only its durable completed journal may advance SCM.
if(!$DeferServiceSelection){
 . (Join-Path $PackageRoot 'UpgradeRecovery.Common.ps1')
 $previous=@()
 if($existing){$service=Get-CimInstance Win32_Service -Filter "Name='OpenWebPBXUpdater'";$previous=@([string]$service.PathName.Trim('"'))}
 Set-OpenWebUpdaterServiceSelection -Root $root -Executable $executable -AllowedPreviousExecutable $previous
}
$action=New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\OpenWebPBX\tools\Restart-Updater.ps1"'
$principal=New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName OpenWebPBX-Updater-Restart -Action $action -Principal $principal -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 3)) -Force|Out-Null
SaveState "$private\updater-install.json" @{Version=$version;Executable=$executable}
# Launch the notification monitor in every interactive/RDP session at sign-in.
# Session 0 is deliberately excluded; this value grants no installation privileges.
$run='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$watch='"'+$env:SystemRoot+'\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\OpenWebPBX\tools\Watch-ServerUpdates.ps1"'
New-ItemProperty -Path $run -Name OpenWebPBXServerUpdates -PropertyType String -Value $watch -Force|Out-Null
# The updater checks durable recovery before starting only these owned services.
foreach($name in 'OpenWebPBX','FreeSWITCH'){Set-Service $name -StartupType Manual}
Set-ItemProperty IIS:\Sites\OpenWebPBX serverAutoStart $false
Set-ItemProperty IIS:\AppPools\OpenWebPBX autoStart $false
. "$root\tools\Restore-Gates.ps1"
$restoreGate=Get-OpenWebRestoreGate -StateRoot $private
if(!$DeferRestart -and !$restoreGate.Blocked -and !$restoreGate.Updates){
 if(!$existing){Start-Service OpenWebPBXUpdater}else{Start-ScheduledTask OpenWebPBX-Updater-Restart}
}
Write-Host 'Independent update service installed. Automatic installation follows the instance administrator policy.'
