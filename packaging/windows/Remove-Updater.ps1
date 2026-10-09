#Requires -RunAsAdministrator
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$private=Join-Path $env:ProgramData OpenWebPBX
Stop-Service OpenWebPBXUpdater -ErrorAction SilentlyContinue
& sc.exe delete OpenWebPBXUpdater|Out-Null
Unregister-ScheduledTask OpenWebPBX-Updater-Restart -Confirm:$false -ErrorAction SilentlyContinue
if(Test-Path "$private\updater-original-startup.json"){
 $saved=Get-Content "$private\updater-original-startup.json" -Raw|ConvertFrom-Json
 foreach($item in $saved.Services.PSObject.Properties){$mode=switch($item.Value){'Auto'{'Automatic'};'Disabled'{'Disabled'};default{'Manual'}};Set-Service $item.Name -StartupType $mode}
 Import-Module WebAdministration
 Set-ItemProperty IIS:\Sites\OpenWebPBX serverAutoStart ([bool]$saved.SiteAutoStart)
 Set-ItemProperty IIS:\AppPools\OpenWebPBX autoStart ([bool]$saved.PoolAutoStart)
}
Write-Host 'The updater service was removed and original PBX startup settings restored. Backups and update history are preserved.'
