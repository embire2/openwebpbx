# Actual shared cache getter under a fresh strict-mode caller. OS membership is
# an explicit module adapter; no ACL, service, account or firewall is changed.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$checks=0
function Check([bool]$Value){if(!$Value){throw 'Privileged cache control failed.'};$script:checks++}
$module=New-Module -Name Microsoft.PowerShell.LocalAccounts -ScriptBlock {
 function Get-LocalGroupMember {[CmdletBinding()]param($SID)if($SID -cne 'S-1-5-32-544'){throw 'Unexpected group query.'};[pscustomobject]@{SID='S-1-5-21-111-222-333-1001'}}
 Export-ModuleMember -Function Get-LocalGroupMember
}
Microsoft.PowerShell.Core\Import-Module $module -Force
try {
 & {
  param($Root)
  Set-StrictMode -Version Latest
  . (Join-Path $Root 'packaging/windows/PhoneHealth-Security.ps1')
  Remove-Variable -Scope Script -Name OpenWebHealthPrivilegedSids,OpenWebHealthPrivilegedUntil -ErrorAction SilentlyContinue
  $script:imports=0
  function Import-Module {[CmdletBinding()]param($Name)if($Name -cne (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.LocalAccounts')){throw 'Unexpected module source.'};$script:imports++}
  $fresh=Get-OpenWebHealthPrivilegedSids
  Check ($fresh -is [Collections.Generic.HashSet[string]] -and $fresh.Contains('S-1-5-18') -and $fresh.Contains('S-1-5-21-111-222-333-1001') -and $script:imports -eq 1)
  $cached=Get-OpenWebHealthPrivilegedSids
  Check ([object]::ReferenceEquals($fresh,$cached) -and $script:imports -eq 1)
  $script:OpenWebHealthPrivilegedUntil=[DateTime]::UtcNow.AddSeconds(-1)
  $expired=Get-OpenWebHealthPrivilegedSids
  Check (![object]::ReferenceEquals($fresh,$expired) -and $script:imports -eq 2)
  Remove-Variable -Scope Script -Name OpenWebHealthPrivilegedUntil
  $missing=Get-OpenWebHealthPrivilegedSids
  Check ($missing.Contains('S-1-5-18') -and $script:imports -eq 3)
  $script:OpenWebHealthPrivilegedUntil='invalid'
  $invalid=Get-OpenWebHealthPrivilegedSids
  Check ($invalid.Contains('S-1-5-18') -and $script:imports -eq 4)
  $script:OpenWebHealthPrivilegedSids='invalid'
  $wrong=Get-OpenWebHealthPrivilegedSids
  Check ($wrong -is [Collections.Generic.HashSet[string]] -and $script:imports -eq 5)
 } $SourceRoot
} finally {Microsoft.PowerShell.Core\Remove-Module Microsoft.PowerShell.LocalAccounts -Force -ErrorAction SilentlyContinue}
[ordered]@{schema=1;state='passed';checks=$checks;actual_shared_getter=$true;fresh_strict_scope=$true;os_membership_adapter=$true;installed_server_changed=$false}|ConvertTo-Json -Compress
