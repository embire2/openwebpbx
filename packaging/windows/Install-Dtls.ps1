#Requires -RunAsAdministrator
# SPDX-License-Identifier: AGPL-3.0-or-later
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PackageRoot,[IO.FileStream]$MaintenanceLock,[switch]$Recover)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
. (Join-Path $PSScriptRoot 'File-Security.ps1')
. (Join-Path $PSScriptRoot 'Write-PrivateState.ps1')
. (Join-Path $PSScriptRoot 'Dtls.Common.ps1')
$root='C:\OpenWebPBX';$state=Join-Path $env:ProgramData 'OpenWebPBX';$certificate='C:\Program Files\FreeSWITCH\cert\dtls-srtp.pem'
if(!$MaintenanceLock -or !$MaintenanceLock.CanRead -or !$MaintenanceLock.CanWrite -or [IO.Path]::GetFullPath($MaintenanceLock.Name) -cne [IO.Path]::GetFullPath((Join-Path $state 'upgrade.lock'))){throw 'The owned exclusive PBX maintenance lock is required to prepare DTLS.'}
foreach($path in $PackageRoot,$root,$state,$certificate,$MaintenanceLock.Name){Assert-OpenWebDtlsOrdinary $path}
$exclusive=$true
foreach($access in 'Read','Write'){
 $blocked=$false
 try{$probe=[IO.File]::Open($MaintenanceLock.Name,'Open',$access,'ReadWrite');$probe.Dispose()}catch [IO.IOException]{$fault=$_.Exception;while($fault.InnerException){$fault=$fault.InnerException};if(($fault.HResult -band 65535) -in 32,33){$blocked=$true}else{throw}}
 if(!$blocked){$exclusive=$false}
}
if(!$exclusive){throw 'The PBX maintenance stream does not hold an exclusive native file lock.'}
Install-OpenWebDtls -PackageRoot $PackageRoot -Root $root -State $state -Certificate $certificate -Recover:$Recover
