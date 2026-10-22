#Requires -RunAsAdministrator
# SPDX-License-Identifier: AGPL-3.0-or-later
# Real Windows empty-query semantics, without editing a firewall rule/profile.
[CmdletBinding()]
param([string]$Helpers=(Join-Path $PSScriptRoot '..\packaging\windows'))
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'Native Windows is required.'}
Import-Module NetSecurity -ErrorAction Stop
. (Join-Path $Helpers 'PhoneHealth-Firewall.Common.ps1')
$checks=0
function Check([bool]$Value,[string]$Message){if(!$Value){throw $Message};$script:checks++}
$before=@(NetSecurity\Get-NetFirewallRule -PolicyStore PersistentStore -ErrorAction Stop|Select-Object Name,Enabled,Direction,Action|Sort-Object Name)|ConvertTo-Json -Depth 5 -Compress
$empty=$false
try{$rows=@(NetSecurity\Get-NetFirewallRule -PolicyStore SystemDefaults -Enabled True -Direction Inbound -Action Block -ErrorAction Stop)}
catch{
 if([string]$_.CategoryInfo.Category -cne 'ObjectNotFound' -or $_.FullyQualifiedErrorId -cne 'CmdletizationQuery_NotFound,Get-NetFirewallRule'){throw}
 $empty=$true
}
Check $empty 'The actual native default-policy query must be empty for this isolated control.'
# Only the foreign-rule query selects the OS default store. Exact owned-name
# reads, profile reads and the native cmdlet itself remain real and unchanged.
function Get-NetFirewallRule {
 param($PolicyStore,$Name,$Enabled,$Direction,$Action,$ErrorAction)
 if($Name){return NetSecurity\Get-NetFirewallRule -PolicyStore $PolicyStore -Name $Name -ErrorAction Stop}
 if($PolicyStore -cne 'ActiveStore' -or [string]$Enabled -cne 'True' -or [string]$Direction -cne 'Inbound' -or [string]$Action -cne 'Block'){throw 'The native empty-query seam changed.'}
 NetSecurity\Get-NetFirewallRule -PolicyStore SystemDefaults -Enabled True -Direction Inbound -Action Block -ErrorAction Stop
}
Check ((Invoke-OpenWebHealthFirewall State '198.18.0.252' 'sip-auth-fail' '5090,5091' '5090') -ceq 'absent') 'The exact native fixture identity is occupied.'
Check ((Invoke-OpenWebHealthFirewall State '198.18.0.252' 'sip-auth-ip' '5090,5091' '5090') -ceq 'absent') 'The actual native empty overlap query was refused.'
$after=@(NetSecurity\Get-NetFirewallRule -PolicyStore PersistentStore -ErrorAction Stop|Select-Object Name,Enabled,Direction,Action|Sort-Object Name)|ConvertTo-Json -Depth 5 -Compress
Check ($before -ceq $after) 'The read-only native query control changed firewall rules.'
@{state='passed';checks=$checks;actual_native_windows=$true;actual_empty_native_query=$true;foreign_query_store_seam=$true;no_pbx_or_firewall_mutation=$true}|ConvertTo-Json -Compress
