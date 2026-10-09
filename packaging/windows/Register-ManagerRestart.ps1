[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
# Called by the interactive manager itself. No password, elevation or SYSTEM UI.
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$sid=$identity.User.Value
$executable='C:\OpenWebPBX\desktop\OpenWebPbx.Desktop.exe'
if(!(Test-Path $executable)){return}
$principal=New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Limited
$action=New-ScheduledTaskAction -Execute $executable -WorkingDirectory (Split-Path $executable)
$settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName ('OpenWebPBX-Manager-'+$sid) -Action $action -Principal $principal -Settings $settings -Description 'Reopen this user’s OpenWeb PBX manager after a verified update.' -Force|Out-Null
