#Requires -RunAsAdministrator
# SPDX-License-Identifier: AGPL-3.0-or-later
[CmdletBinding()]
param(
 [string]$CertificateThumbprint,
 [switch]$RecordOnly,
 [switch]$Renew,
 [string]$StateRoot=(Join-Path $env:ProgramData 'OpenWebPBX'),
 [string]$Root='C:\OpenWebPBX',
 [IO.FileStream]$MaintenanceLock
)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'PublicAccess.Common.ps1')
$context=Get-OpenWebPublicContext $StateRoot $Root
$statePath=Join-Path $context.Directory 'state.json'
$pendingPath=Join-Path $context.Directory 'pending.json'
$null=Assert-OpenWebOrdinaryPath $context.Directory $true
$state=Read-OpenWebPublicJson $statePath
if($state.schema -ne 1) { throw 'The public-access state is unsupported.' }
$hostname=Assert-OpenWebPublicHostname $state.hostname
$null=Assert-OpenWebPublicAddress $state.public_address
if($RecordOnly) {
 # simple-acme invokes this in a child process while its parent owns upgrade.lock.
 # This callback cannot apply IIS/PHP/native changes or acquire the parent's lock.
 if($Renew -or $null -ne $MaintenanceLock -or -not $CertificateThumbprint) { throw 'The certificate callback requires only its issued thumbprint.' }
 $certificate=Get-OpenWebPublicCertificate $CertificateThumbprint $hostname
 try { Write-OpenWebPublicJson $pendingPath @{schema=1;hostname=$hostname;thumbprint=$certificate.Thumbprint;not_after_utc=$certificate.NotAfter.ToUniversalTime().ToString('o');recorded_at_utc=[DateTime]::UtcNow.ToString('o')} } finally { $certificate.Dispose() }
 return
}
$ownsLock=$null -eq $MaintenanceLock
if($ownsLock) {
 if(Test-Path -LiteralPath $context.LockPath) { $null=Assert-OpenWebOrdinaryPath $context.LockPath }
 try { $MaintenanceLock=[IO.File]::Open($context.LockPath,'OpenOrCreate','ReadWrite','None') } catch [IO.IOException] { throw 'Another PBX update, backup, restore or certificate operation is running. Retry later.' }
}
try {
 Initialize-OpenWebPublicDirectory $context $MaintenanceLock
 if($Renew) {
  $client=Initialize-OpenWebAcme $context
  Invoke-OpenWebAcme $context $client @('--renew','--friendlyname','OpenWebPBX-public','--notaskscheduler')
 }
 if($CertificateThumbprint) {
  $certificate=Get-OpenWebPublicCertificate $CertificateThumbprint $hostname
  try { Write-OpenWebPublicJson $pendingPath @{schema=1;hostname=$hostname;thumbprint=$certificate.Thumbprint;not_after_utc=$certificate.NotAfter.ToUniversalTime().ToString('o');recorded_at_utc=[DateTime]::UtcNow.ToString('o')} } finally { $certificate.Dispose() }
 }
 if(-not (Test-Path -LiteralPath $pendingPath)) {
  if($state.certificate_thumbprint) {
   $certificate=Get-OpenWebPublicCertificate $state.certificate_thumbprint $hostname
   $certificate.Dispose()
  }
  @{certificate_pending=$false;certificate_change_applied=$false}|ConvertTo-Json -Compress
  return
 }
 $pending=Read-OpenWebPublicJson $pendingPath
 if($pending.schema -ne 1 -or $pending.hostname -ne $hostname) { throw 'The pending certificate does not belong to this public-access setup.' }
 $certificate=Get-OpenWebPublicCertificate $pending.thumbprint $hostname
 try {
  $listenerPlan=Get-OpenWebPublicListenerPlan $context
  $null=Test-OpenWebPublicListenerRules $listenerPlan -IncludeIntendedTls
  $null=Get-OpenWebPublicSite $hostname $context.Root
  Assert-OpenWebPublicMaintenance $context $MaintenanceLock
  # Only the exact hostname binding is updated. Local-test and foreign bindings remain.
  $previousBinding=Get-OpenWebPublicBindingState $hostname
  try {
   $null=Set-OpenWebPublicBinding $hostname 'https' $certificate.Thumbprint $context.Root
   Test-OpenWebPublicHttps $hostname $certificate.Thumbprint
  } catch { Restore-OpenWebPublicBinding $hostname $previousBinding;throw }
  $state.certificate_thumbprint=$certificate.Thumbprint
  $state.web_certificate_not_after_utc=$certificate.NotAfter.ToUniversalTime().ToString('o')
  $state.web_certificate_verified_at_utc=[DateTime]::UtcNow.ToString('o')
  $state.phone_certificate_pending=$true
  Write-OpenWebPublicJson $statePath $state
  Assert-OpenWebPublicMaintenance $context $MaintenanceLock
  try {
   & (Join-Path $PSScriptRoot 'Enable-PhoneTLS.ps1') -CertificateThumbprint $certificate.Thumbprint -MaintenanceLock $MaintenanceLock
   # A deferred first certificate can bind5061 on this later retry. Add
   # its allow rule only after current native ownership is actually proved.
   $boundPlan=Get-OpenWebPublicListenerPlan $context
   Sync-OpenWebPublicListenerPlan $context $boundPlan $MaintenanceLock
  } catch {
   if($_.Exception.Data['OpenWebPhoneTLSBusy'] -eq $true) {
    # IIS can use the renewed certificate while the existing SIP certificate stays
    # in service. The retry task never restarts FreeSWITCH with a live call.
    $state.phone_certificate_pending=$true
    $state.phone_certificate_status='waiting_for_idle'
    Write-OpenWebPublicJson $statePath $state
    @{web_https_verified=$true;phone_certificate_pending=$true;phone_restart_deferred_for_calls=$true}|ConvertTo-Json -Compress
    return
   }
   $state.phone_certificate_status='apply_failed'
   Write-OpenWebPublicJson $statePath $state
   throw
  }
  $state.phone_certificate_pending=$false
  $state.phone_certificate_status='verified'
  $state.phone_certificate_verified_at_utc=[DateTime]::UtcNow.ToString('o')
  Write-OpenWebPublicJson $statePath $state
  Remove-Item -LiteralPath $pendingPath -Force
  @{web_https_verified=$true;phone_tls_verified=$true;phone_certificate_pending=$false}|ConvertTo-Json -Compress
 } finally { $certificate.Dispose() }
} finally { if($ownsLock -and $null -ne $MaintenanceLock) { $MaintenanceLock.Dispose() } }
