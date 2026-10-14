#Requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PackageRoot,[string]$Root='C:\OpenWebPBX')
$ErrorActionPreference='Stop'
$ssl=Join-Path $Root 'php\extras\ssl'
New-Item -ItemType Directory -Force $ssl | Out-Null
if((Get-FileHash -LiteralPath (Join-Path $PackageRoot 'cacert.pem') -Algorithm SHA256).Hash -ne 'a41b5d356aea97a529fe27e0f7316d2f9d946d75927476cf9cf1b90637d00505'){
 throw 'The Windows HTTPS certificate bundle does not match this release.'
}
Copy-Item -LiteralPath (Join-Path $PackageRoot 'cacert.pem') -Destination (Join-Path $ssl 'cacert.pem') -Force
Copy-Item -LiteralPath (Join-Path $PackageRoot 'openssl.cnf') -Destination (Join-Path $ssl 'openssl.cnf') -Force
$ini=Join-Path $Root 'php\php.ini'
$text=[IO.File]::ReadAllText($ini)
$text=[regex]::Replace($text,'(?m)^\s*(openssl\.cafile|curl\.cainfo)\s*=.*(?:\r?\n|$)','')
$text=$text.TrimEnd()+"`r`nopenssl.cafile=`"$ssl\cacert.pem`"`r`ncurl.cainfo=`"$ssl\cacert.pem`"`r`n"
[IO.File]::WriteAllText($ini,$text,[Text.UTF8Encoding]::new($false))
# Set the environment only on our PHP FastCGI application. Other IIS websites
# and services retain their own OpenSSL settings.
Import-Module WebAdministration
$fastcgi=Join-Path $Root 'php\php-cgi.exe'
$filter="system.webServer/fastCgi/application[@fullPath='$fastcgi']/environmentVariables"
$existing=Get-WebConfiguration -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter "$filter/environmentVariable[@name='OPENSSL_CONF']"
if($existing){Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter "$filter/environmentVariable[@name='OPENSSL_CONF']" -Name value -Value (Join-Path $ssl 'openssl.cnf')}
else{Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter $filter -Name '.' -Value @{name='OPENSSL_CONF';value=(Join-Path $ssl 'openssl.cnf')}}
$env:OPENSSL_CONF=Join-Path $ssl 'openssl.cnf'
Write-Host 'PHP HTTPS trust and private key generation configured.'
