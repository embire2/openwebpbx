#Requires -RunAsAdministrator
[CmdletBinding()]
param()
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
try{
 if($PSScriptRoot -cne 'C:\OpenWebPBX\tools'){throw 'Use the installed recovery worker.'}
 if([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -cne 'S-1-5-18'){throw 'The scheduled recovery worker must run as SYSTEM.'}
 . (Join-Path $PSScriptRoot 'PhoneHealth-Security.ps1')
 foreach($path in @('C:\OpenWebPBX\backup-runtime','C:\OpenWebPBX\tools')){$null=Assert-OpenWebHealthProtectedPath $path -Directory}
 foreach($path in @('C:\OpenWebPBX\backup-runtime\python.exe',(Join-Path $PSScriptRoot 'protection.py'),(Join-Path $PSScriptRoot 'backups.py'),(Join-Path $PSScriptRoot 'Backup-Control.ps1'))){$null=Assert-OpenWebHealthProtectedPath $path}
 # -I ignores user site-packages and environment injection. The installed tool
 # directory is deliberately added by runpy only after the ACL checks above.
 & 'C:\OpenWebPBX\backup-runtime\python.exe' -I -c 'import runpy,sys;sys.path.insert(0,r''C:\OpenWebPBX\tools'');sys.argv=[r''C:\OpenWebPBX\tools\protection.py'',''worker''];runpy.run_path(sys.argv[0],run_name=''__main__'')'
 if($LASTEXITCODE -ne 0){throw 'Protected recovery needs review.'}
}catch{[Console]::Error.WriteLine('Protected recovery could not finish. Private recovery evidence and current call holds were retained.');exit 1}
