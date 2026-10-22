# SPDX-License-Identifier: AGPL-3.0-or-later
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('State','Add','Remove')][string]$Operation,[Parameter(Mandatory)][string]$Address,[Parameter(Mandatory)][ValidateSet('sip-auth-fail','sip-auth-ip')][string]$Filter,[Parameter(Mandatory)][string]$TcpPorts,[Parameter(Mandatory)][string]$UdpPorts)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';$WarningPreference='SilentlyContinue'
try{
 if($PSScriptRoot -cne 'C:\OpenWebPBX\tools'){throw 'The installed security helper is required.'}
 . (Join-Path $PSScriptRoot 'PhoneHealth-Security.ps1')
 Assert-OpenWebHealthSystem
 $null=Assert-OpenWebHealthProtectedPath (Join-Path $env:ProgramData 'OpenWebPBX\phone-health-runtime') -Directory
 foreach($name in 'PhoneHealth-Firewall.ps1','PhoneHealth-Firewall.Common.ps1','PhoneHealth-Security.ps1'){$null=Assert-OpenWebHealthProtectedPath (Join-Path $PSScriptRoot $name)}
 $env:PSModulePath=$PSHOME+'\Modules;'+[Environment]::GetFolderPath('ProgramFiles')+'\WindowsPowerShell\Modules'
 Import-Module NetSecurity -ErrorAction Stop
 . (Join-Path $PSScriptRoot 'PhoneHealth-Firewall.Common.ps1')
 $state=Invoke-OpenWebHealthFirewall $Operation $Address $Filter $TcpPorts $UdpPorts
 [Console]::Out.WriteLine((@{state=$state}|ConvertTo-Json -Compress))
}catch{[Console]::Out.WriteLine('{"state":"unknown"}');exit 1}
