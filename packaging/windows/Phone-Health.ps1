# SPDX-License-Identifier: AGPL-3.0-or-later
[CmdletBinding()]
param([switch]$Once)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
try{
 if($PSScriptRoot -cne 'C:\OpenWebPBX\tools'){throw 'The installed health worker is required.'}
 . (Join-Path $PSScriptRoot 'PhoneHealth-Security.ps1')
 Assert-OpenWebHealthSystem
 $null=Assert-OpenWebHealthProtectedPath (Join-Path $env:ProgramData 'OpenWebPBX\phone-health-runtime') -Directory
 foreach($path in @('C:\OpenWebPBX\php\php.exe','C:\OpenWebPBX\php\php.ini',(Join-Path $PSScriptRoot 'phone-health.php'),(Join-Path $PSScriptRoot 'Phone-Health.ps1'),(Join-Path $PSScriptRoot 'PhoneHealth-Security.ps1'))){$null=Assert-OpenWebHealthProtectedPath $path}
 # Web sources run as SYSTEM only when the installed source tree and all PHP
 # files are protected against IIS/users replacing executable health code.
 $null=Assert-OpenWebHealthProtectedPath 'C:\OpenWebPBX\web' -Directory
 foreach($file in Get-ChildItem -LiteralPath 'C:\OpenWebPBX\web' -Filter '*.php' -File -Recurse -Force){$null=Assert-OpenWebHealthProtectedPath $file.FullName}
 $before=$env:OPENSSL_CONF;$env:OPENSSL_CONF='C:\OpenWebPBX\php\extras\ssl\openssl.cnf'
 try{
  $arguments=@('-d','memory_limit=128M','-d','display_errors=0','-d','log_errors=0',(Join-Path $PSScriptRoot 'phone-health.php'))
  if($Once){$arguments+='once'}else{$arguments+='service'}
  & 'C:\OpenWebPBX\php\php.exe' @arguments
  if($LASTEXITCODE -ne 0){throw 'The health worker needs review.'}
 }finally{if($null -eq $before){Remove-Item Env:\OPENSSL_CONF -ErrorAction SilentlyContinue}else{$env:OPENSSL_CONF=$before}}
}catch{[Console]::Error.WriteLine('Phone Health observation failed; existing incidents and security rules are retained.');exit 1}
