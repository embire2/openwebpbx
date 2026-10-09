#Requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PackageRoot,[switch]$DeferRestart)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
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
foreach($name in 'Upgrade-OpenWebPBX.ps1','Register-ManagerRestart.ps1','Restart-Updater.ps1','Remove-Updater.ps1'){
 Copy-Item (Join-Path $PackageRoot $name) (Join-Path "$root\tools" $name) -Force
}
Import-Module WebAdministration
$startup="$private\updater-original-startup.json"
if(!(Test-Path $startup)){
 $saved=@{Services=@{};SiteAutoStart=(Get-ItemProperty IIS:\Sites\OpenWebPBX serverAutoStart).serverAutoStart;PoolAutoStart=(Get-ItemProperty IIS:\AppPools\OpenWebPBX autoStart).autoStart}
 foreach($name in 'OpenWebPBX','FreeSWITCH'){$saved.Services[$name]=(Get-CimInstance Win32_Service -Filter "Name='$name'").StartMode}
 SaveState $startup $saved
}
$executable="$slot\OpenWebPbx.Updater.exe"
if(!$existing){
 New-Service -Name OpenWebPBXUpdater -BinaryPathName ('"'+$executable+'"') -DisplayName 'OpenWeb PBX Updates' -StartupType Automatic -DependsOn OpenWebPBX-Database|Out-Null
}else{& sc.exe config OpenWebPBXUpdater binPath= ('"'+$executable+'"') start= auto depend= OpenWebPBX-Database|Out-Null;if($LASTEXITCODE){throw 'The updater service slot could not be selected.'}}
& sc.exe failure OpenWebPBXUpdater reset= 86400 actions= restart/15000/restart/30000/restart/60000|Out-Null
& sc.exe failureflag OpenWebPBXUpdater 1|Out-Null
$action=New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\OpenWebPBX\tools\Restart-Updater.ps1"'
$principal=New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName OpenWebPBX-Updater-Restart -Action $action -Principal $principal -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 3)) -Force|Out-Null
SaveState "$private\updater-install.json" @{Version=$version;Executable=$executable}
# The updater checks durable recovery before starting only these owned services.
foreach($name in 'OpenWebPBX','FreeSWITCH'){Set-Service $name -StartupType Manual}
Set-ItemProperty IIS:\Sites\OpenWebPBX serverAutoStart $false
Set-ItemProperty IIS:\AppPools\OpenWebPBX autoStart $false
if(!$existing -and !$DeferRestart){Start-Service OpenWebPBXUpdater}
elseif(!$DeferRestart){Start-ScheduledTask OpenWebPBX-Updater-Restart}
Write-Host 'Independent update service installed. Automatic installation follows the instance administrator policy.'
