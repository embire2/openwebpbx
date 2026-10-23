# SPDX-License-Identifier: AGPL-3.0-or-later
# Executes real renewal control flow with explicit certificate/IIS/native fixtures.
# This does not establish Windows ACLs, outside ACME issuance or native TLS.
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$repository=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('openweb certificate workflow '+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $fixture
$checks=0
function Check([bool]$Result,[string]$Label) { if(-not $Result) { throw $Label };$script:checks++ }
function Refused([scriptblock]$Action,[string]$Label) { $failed=$false;try { & $Action|Out-Null } catch { $failed=$true };Check $failed $Label }
try {
 $tools=Join-Path $fixture 'tools';$null=New-Item -ItemType Directory -Path $tools
 $stateRoot=Join-Path $fixture 'private';$null=New-Item -ItemType Directory -Path $stateRoot
 $directory=Join-Path $stateRoot 'public-access';$null=New-Item -ItemType Directory -Path $directory
 Copy-Item (Join-Path $repository 'packaging/windows/Restore-Gates.ps1') $tools
 $common=[IO.File]::ReadAllText((Join-Path $repository 'packaging/windows/PublicAccess.Common.ps1'))
 $common+=@'
function Get-OpenWebPublicContext([string]$StateRoot,[string]$Root) { return @{StateRoot=$StateRoot;Root=$Root;Directory=(Join-Path $StateRoot 'public-access');LockPath=(Join-Path $StateRoot 'upgrade.lock')} }
function Set-OpenWebPublicPrivateAcl([string]$Directory) {}
function Get-OpenWebPublicCertificate([string]$Thumbprint,[string]$Hostname) {
 if($Thumbprint -ne ('a'*40) -or $Hostname -ne 'pbx.sample.org') { throw 'Fixture rejects incorrect certificate or hostname.' }
 $cert=[pscustomobject]@{Thumbprint=$Thumbprint;NotAfter=[DateTime]::UtcNow.AddDays(60)}
 $cert|Add-Member -MemberType ScriptMethod -Name Dispose -Value {} -PassThru
}
function Get-OpenWebPublicSite([string]$Hostname,[string]$Root) { return 1 }
function Get-OpenWebPublicBindingState([string]$Hostname) { return @{present=$true;hash='previous-fixture-hash'} }
function Set-OpenWebPublicBinding([string]$Hostname,[string]$Protocol,[string]$Thumbprint,[string]$Root) { $global:bindingApplied++;return $false }
function Restore-OpenWebPublicBinding([string]$Hostname,$Previous) { if($Previous.hash -ne 'previous-fixture-hash') { throw 'Incorrect fixture recovery' };$global:bindingRestored++ }
function Test-OpenWebPublicHttps([string]$Hostname,[string]$Thumbprint) { if($global:httpsFault) { throw 'Fixture HTTPS handshake fails' } }
function Get-OpenWebPublicListenerPlan($Context) {$global:listenerPlans++;return [pscustomobject]@{actually_bound=$global:tlsActuallyBound}}
function Test-OpenWebPublicListenerRules($Plan,[switch]$IncludeIntendedTls) {$global:listenerPreflight++;if(!$IncludeIntendedTls){throw 'The intendedTLS scope was not checked.'};if($global:listenerFault -ceq 'preflight'){throw 'Fixture foreign planned rule.'};return @{}}
function Sync-OpenWebPublicListenerPlan($Context,$Plan,$MaintenanceLock) {$global:listenerSync++;if(!$Plan.actually_bound -or $global:listenerFault -ceq 'sync'){throw 'Fixture actual-bound rule synchronization refused.'}}

'@
 [IO.File]::WriteAllText((Join-Path $tools 'PublicAccess.Common.ps1'),$common,[Text.UTF8Encoding]::new($false))
 $renew=[IO.File]::ReadAllText((Join-Path $repository 'packaging/windows/Renew-PhoneCertificate.ps1'))
 # Only the test copy removes elevation; product remains administrator-only.
 $renew=$renew -replace '(?m)^#Requires -RunAsAdministrator\r?\n',''
 [IO.File]::WriteAllText((Join-Path $tools 'Renew-PhoneCertificate.ps1'),$renew,[Text.UTF8Encoding]::new($false))
 $phone=@'
param([string]$CertificateThumbprint,[IO.FileStream]$MaintenanceLock)
if(-not $MaintenanceLock.CanWrite) { throw 'Fixture caller did not retain the maintenance lock' }
$global:phoneInvoked++
if($global:phoneMode -eq 'busy') { $error=[InvalidOperationException]::new('Actual-call fixture');$error.Data['OpenWebPhoneTLSBusy']=$true;throw $error }
if($global:phoneMode -eq 'fault') { throw 'Fixture rejects phone profile' }
$global:tlsActuallyBound=$global:phoneMode -cne 'missingBinding'
'@
 [IO.File]::WriteAllText((Join-Path $tools 'Enable-PhoneTLS.ps1'),$phone,[Text.UTF8Encoding]::new($false))
 . (Join-Path $tools 'PublicAccess.Common.ps1')
 $statePath=Join-Path $directory 'state.json';$pendingPath=Join-Path $directory 'pending.json'
 $helper=Join-Path $tools 'Renew-PhoneCertificate.ps1'
 function Seed {
  $global:listenerPlans=0;$global:listenerPreflight=0;$global:listenerSync=0;$global:listenerFault='';$global:tlsActuallyBound=$false;$global:phoneMode='success';$global:phoneInvoked=0;$global:bindingApplied=0;$global:bindingRestored=0;$global:httpsFault=$false
  Write-OpenWebPublicJson $statePath @{schema=1;hostname='pbx.sample.org';public_address='8.8.8.8';certificate_thumbprint='';web_certificate_not_after_utc='';web_certificate_verified_at_utc='';phone_certificate_pending=$true;phone_certificate_status='not_configured';phone_certificate_verified_at_utc=''}
  Write-OpenWebPublicJson $pendingPath @{schema=1;hostname='pbx.sample.org';thumbprint=('a'*40)}
 }
 Seed
 & $helper -Root $fixture -StateRoot $stateRoot|Out-Null
 Check ($global:phoneInvoked -eq 1 -and $global:bindingApplied -eq 1 -and -not (Test-Path $pendingPath) -and (Read-OpenWebPublicJson $statePath).phone_certificate_status -eq 'verified') 'Successful exact-host apply consumes the pending certificate'
 Check ($global:listenerPlans -eq 2 -and $global:listenerPreflight -eq 1 -and $global:listenerSync -eq 1) 'ImmediateTLS apply synchronizes only the fresh actually-bound plan'
 Seed;$global:phoneMode='busy'
 & $helper -Root $fixture -StateRoot $stateRoot|Out-Null
 Check ((Test-Path $pendingPath) -and (Read-OpenWebPublicJson $statePath).phone_certificate_pending -and (Read-OpenWebPublicJson $statePath).phone_certificate_status -eq 'waiting_for_idle') 'Only confirmed active calls defer SIP and retain pending work'
 Check ($global:listenerPlans -eq 1 -and $global:listenerPreflight -eq 1 -and $global:listenerSync -eq 0) 'Busy first setup never opens an unboundTLS rule'
 $global:phoneMode='success';& $helper -Root $fixture -StateRoot $stateRoot|Out-Null
 Check ($global:listenerPlans -eq 3 -and $global:listenerSync -eq 1 -and !(Test-Path $pendingPath)) 'Later idle retry actually synchronizes newly boundTLS before consuming pending work'
 Seed;$global:listenerFault='preflight';$beforeState=[IO.File]::ReadAllText($statePath)
 Refused { & $helper -Root $fixture -StateRoot $stateRoot } 'An unfamiliar planned rule refuses before public binding/state changes'
 Check ($global:bindingApplied -eq 0 -and $global:phoneInvoked -eq 0 -and $global:listenerSync -eq 0 -and [IO.File]::ReadAllText($statePath) -ceq $beforeState) 'Complete listener preflight preserves exact original public state'
 foreach($failure in 'sync','missingBinding'){
  Seed;if($failure -ceq 'sync'){$global:listenerFault='sync'}else{$global:phoneMode='missingBinding'}
  Refused { & $helper -Root $fixture -StateRoot $stateRoot } 'Failed or unboundTLS rule synchronization remains a failure'
  Check ((Test-Path $pendingPath) -and (Read-OpenWebPublicJson $statePath).phone_certificate_pending -and (Read-OpenWebPublicJson $statePath).phone_certificate_status -ceq 'apply_failed') 'Rule failures retain pending work and never claim verified'
 }
 Seed;$global:phoneMode='fault'
 Refused { & $helper -Root $fixture -StateRoot $stateRoot } 'A non-busy phone failure remains an error'
 Check ((Test-Path $pendingPath) -and (Read-OpenWebPublicJson $statePath).phone_certificate_status -eq 'apply_failed') 'Strict phone failures are not mislabeled as active calls or ready'
 Seed;$global:httpsFault=$true
 Refused { & $helper -Root $fixture -StateRoot $stateRoot } 'A bad HTTPS handshake is refused'
 Check ($global:bindingRestored -eq 1 -and $global:phoneInvoked -eq 0 -and (Test-Path $pendingPath)) 'The prior exact-host HTTPS binding is restored before any SIP change'
 Seed
 Write-OpenWebPublicJson $pendingPath @{schema=1;hostname='other.sample.org';thumbprint=('a'*40)}
 Refused { & $helper -Root $fixture -StateRoot $stateRoot } 'Cross-host pending certificates cannot be applied'
 Check ($global:phoneInvoked -eq 0 -and $global:bindingApplied -eq 0) 'Cross-host refusal has no certificate/listener mutations'
 Seed
 $restore=Join-Path $stateRoot 'backup-restore';$null=New-Item -ItemType Directory -Path $restore
 [IO.File]::WriteAllText((Join-Path $restore 'hold-jobs'),'fixture')
 Refused { & $helper -Root $fixture -StateRoot $stateRoot } 'A current backup/restore hold blocks certificate mutation'
 Check ($global:phoneInvoked -eq 0 -and $global:bindingApplied -eq 0) 'Restore holds refuse before touching listeners'
 Remove-Item -LiteralPath $restore -Recurse -Force
 Seed
 $lock=[IO.File]::Open((Join-Path $stateRoot 'upgrade.lock'),'OpenOrCreate','ReadWrite','None')
 try {
  Refused { & $helper -Root $fixture -StateRoot $stateRoot } 'Concurrent maintenance owns the shared lock'
  & $helper -Root $fixture -StateRoot $stateRoot -MaintenanceLock $lock|Out-Null
  Check ($lock.CanRead -and $lock.CanWrite -and $global:phoneInvoked -eq 1) 'Same-process apply passes the lock without reentry or disposing its owner'
 } finally { $lock.Dispose() }
 Seed
 Remove-Item -LiteralPath $pendingPath
 & $helper -Root $fixture -StateRoot $stateRoot -RecordOnly -CertificateThumbprint ('a'*40)|Out-Null
 Check ((Test-Path $pendingPath) -and $global:phoneInvoked -eq 0 -and $global:bindingApplied -eq 0) 'ACME child callback records only and does not mutate web/SIP or reenter a lock'
 Check ($global:listenerPlans -eq 0 -and $global:listenerPreflight -eq 0 -and $global:listenerSync -eq 0) 'RecordOnly never enters native listener collection or firewall synchronization'
 Write-Output "PASS: $checks executable renewal workflow checks (IIS/certificate/native fixtures explicit)"
} finally { Remove-Item -LiteralPath $fixture -Recurse -Force }
