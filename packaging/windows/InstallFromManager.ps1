#Requires -RunAsAdministrator
param([Parameter(Mandatory)][string]$RequestFile)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$log=Join-Path (Split-Path -Parent $RequestFile) 'install.log'
try {
 if(Test-Path "$env:ProgramData\fusionpbx\config.conf"){throw 'A PBX is already installed. Open Admin to manage it; use the documented upgrade procedure for updates.'}
 $request=Get-Content -LiteralPath $RequestFile -Raw|ConvertFrom-Json
 $password=ConvertTo-SecureString $request.AdminPassword -AsPlainText -Force
 Remove-Item -LiteralPath $RequestFile -Force
 & "$PSScriptRoot\Install-OpenWebPBX.ps1" -DomainName $request.DomainName -AdminEmail $request.AdminEmail -AdminPassword $password -LocalCertificate:([bool]$request.LocalCertificate) -CertificateThumbprint $request.CertificateThumbprint *> $log
 exit 0
} catch {
 'Installation failed: '+$_.Exception.Message|Add-Content -LiteralPath $log
 exit 1
} finally { $request=$null;$password=$null }
