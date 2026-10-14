#Requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PackageRoot,[switch]$DeferRestart,[switch]$UpgradeLockHeld)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$root='C:\OpenWebPBX';$private=Join-Path $env:ProgramData 'OpenWebPBX'
$lock=$null
function NoReparse([string]$Path){
 $current=[IO.Path]::GetFullPath($Path)
 while($current){
  if(Test-Path -LiteralPath $current){$item=Get-Item -LiteralPath $current -Force;if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Backup installation paths must not contain links or junctions.'}}
  $parent=[IO.Path]::GetDirectoryName($current);if($parent -eq $current){break};$current=$parent
 }
}
function ClosedDirectory([string]$Path,[switch]$Download,[switch]$Code){
 NoReparse $Path
 New-Item -ItemType Directory -Path $Path -Force|Out-Null
 $acl=New-Object Security.AccessControl.DirectorySecurity;$acl.SetAccessRuleProtection($true,$false)
 $inherit=[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
 foreach($sid in 'S-1-5-32-544','S-1-5-18'){$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)),[Security.AccessControl.FileSystemRights]::FullControl,$inherit,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)))}
 if($Code){$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')),[Security.AccessControl.FileSystemRights]::ReadAndExecute,$inherit,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)))}
 if($Download){$web=(New-Object Security.Principal.NTAccount('IIS AppPool\OpenWebPBX')).Translate([Security.Principal.SecurityIdentifier]);$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($web,[Security.AccessControl.FileSystemRights]::ReadAndExecute,$inherit,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)))}
 Set-Acl -LiteralPath $Path -AclObject $acl
}
try{
 foreach($path in $PackageRoot,$root,$private,"$private\upgrade.lock","$root\backup-runtime","$root\tools"){NoReparse $path}
 if(!(Test-Path "$private\installation.json") -or !(Test-Path "$root\web\resources\require.php")){throw 'Install the PBX application and its local database first.'}
 foreach($path in "$PackageRoot\backup-runtime\python.exe","$PackageRoot\backups.py","$PackageRoot\Backup-Control.ps1"){if(!(Test-Path -LiteralPath $path -PathType Leaf)){throw 'The release is missing its isolated encrypted-backup runtime or helper.'}}
 if(!$UpgradeLockHeld){try{$lock=[IO.File]::Open("$private\upgrade.lock",'OpenOrCreate','ReadWrite','None')}catch [IO.IOException]{throw 'Another backup, restore or update is running. Wait for it to finish.'}}
 $task=Get-ScheduledTask -TaskName OpenWebPBX-Backups -ErrorAction SilentlyContinue
 if($task){Disable-ScheduledTask -TaskName OpenWebPBX-Backups|Out-Null;for($i=0;$i -lt 40 -and (Get-ScheduledTask -TaskName OpenWebPBX-Backups).State -eq 'Running';$i++){Start-Sleep -Milliseconds 250};if((Get-ScheduledTask -TaskName OpenWebPBX-Backups).State -eq 'Running'){throw 'The previous backup task has not stopped; no runtime was replaced.'}}
 ClosedDirectory "$root\tools" -Code
 foreach($path in "$root\backup-runtime","$private\automatic-backups","$private\backup-restore","$private\backup-control"){ClosedDirectory $path}
 ClosedDirectory "$private\backup-downloads" -Download
 foreach($item in Get-ChildItem "$PackageRoot\backup-runtime" -Recurse -Force){if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'The backup runtime must not contain links or junctions.'}}
 & robocopy.exe "$PackageRoot\backup-runtime" "$root\backup-runtime" /MIR /COPY:DAT /DCOPY:T /R:1 /W:1 /NFL /NDL /NJH /NJS /NP|Out-Null
 if($LASTEXITCODE -ge 8){throw 'The isolated backup runtime could not be copied.'}
 Copy-Item "$PackageRoot\backups.py","$PackageRoot\Backup-Control.ps1" "$root\tools" -Force
 & "$root\backup-runtime\python.exe" -I -c 'import sys; from cryptography.hazmat.primitives.ciphers.aead import AESGCM; assert sys.version_info[:2] == (3,13)'
 if($LASTEXITCODE){throw 'The isolated Python3.13 encryption runtime is incomplete.'}
 foreach($name in 'psql','pg_dump','pg_restore'){if(!(Test-Path "$root\pgsql\bin\$name.exe")){throw 'The built-in PostgreSQL backup tools are unavailable.'}}
 $client=Get-WindowsCapability -Online -Name 'OpenSSH.Client~~~~0.0.1.0'
 if($client.State -ne 'Installed'){$installed=Add-WindowsCapability -Online -Name 'OpenSSH.Client~~~~0.0.1.0';if($installed.RestartNeeded){throw 'Restart Windows to finish installing its SFTP client before enabling backups.'}}
 foreach($name in 'sftp','ssh-keygen'){if(!(Test-Path "$env:SystemRoot\System32\OpenSSH\$name.exe")){throw 'The Windows OpenSSH client is incomplete.'}}
 Push-Location "$root\web"
 try{& "$root\php\php.exe" -r 'require "C:/OpenWebPBX/web/resources/require.php"; database::new()->db->exec(file_get_contents("C:/OpenWebPBX/web/app/pbx_backups/resources/install.sql"));';if($LASTEXITCODE){throw 'The instance backup schema could not be prepared.'}}finally{Pop-Location}
 $action=New-ScheduledTaskAction -Execute "$root\backup-runtime\python.exe" -Argument '-I "C:\OpenWebPBX\tools\backups.py" worker' -WorkingDirectory "$root\tools"
 $trigger=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)
 $boot=New-ScheduledTaskTrigger -AtStartup
 $principal=New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
 $settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 6) -MultipleInstances IgnoreNew -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
 Register-ScheduledTask -TaskName OpenWebPBX-Backups -Action $action -Trigger @($trigger,$boot) -Principal $principal -Settings $settings -Force|Out-Null
 $blocked=$false
 foreach($name in 'calls','jobs','updates','backups'){if(Test-Path "$private\backup-restore\hold-$name"){$blocked=$true}}
 if(Test-Path "$private\backup-restore\journal.json"){$journal=Get-Content "$private\backup-restore\journal.json" -Raw -Encoding UTF8|ConvertFrom-Json;if($journal.state -in 'prepared','restoring','recovery_required'){$blocked=$true}}
 if($blocked -or $DeferRestart){Disable-ScheduledTask -TaskName OpenWebPBX-Backups|Out-Null}
 else{Start-ScheduledTask -TaskName OpenWebPBX-Backups}
 Write-Host 'Encrypted instance backups installed. In Backups, save a password separately and choose the UTC schedule and retention.'
}finally{if($lock){$lock.Dispose()}}
