[CmdletBinding()]
param()
if($PSVersionTable.PSEdition -eq 'Core'){throw 'The manager helper requires Windows PowerShell (powershell.exe).'}
$env:PSModulePath=$PSHOME+'\Modules;'+[Environment]::GetFolderPath('ProgramFiles')+'\WindowsPowerShell\Modules'
$ErrorActionPreference='Stop'
# Called by the interactive manager itself. No password, elevation or SYSTEM UI.
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$sid=$identity.User.Value
$executable='C:\OpenWebPBX\desktop\OpenWebPbx.Desktop.exe'
if(!(Test-Path $executable)){return}
$principal=New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Limited
$action=New-ScheduledTaskAction -Execute $executable -WorkingDirectory (Split-Path $executable)
$settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName ('OpenWebPBX-Manager-'+$sid) -Action $action -Principal $principal -Settings $settings -Description 'Reopen the OpenWeb PBX manager for this user after a verified update.' -Force|Out-Null
# Cover the current session too; the machine Run value covers subsequent sign-ins.
$watch='C:\OpenWebPBX\tools\Watch-ServerUpdates.ps1'
if(Test-Path -LiteralPath $watch){Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -ArgumentList ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$watch+'"') -WindowStyle Hidden|Out-Null}
