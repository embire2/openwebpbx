#Requires -RunAsAdministrator
# SPDX-License-Identifier: AGPL-3.0-or-later
[CmdletBinding()]
param(
 [Parameter(Mandatory=$true)][string]$DomainName,
 [Parameter(Mandatory=$true)][Alias('Email')][string]$EmailAddress,
 [string]$PublicAddress='',
 [string]$StateRoot=(Join-Path $env:ProgramData 'OpenWebPBX'),
 [string]$Root='C:\OpenWebPBX'
)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'PublicAccess.Common.ps1')
$DomainName=Assert-OpenWebPublicHostname $DomainName
$EmailAddress=Assert-OpenWebPublicEmail $EmailAddress
$context=Get-OpenWebPublicContext $StateRoot $Root
if(Test-Path -LiteralPath $context.LockPath) { $null=Assert-OpenWebOrdinaryPath $context.LockPath }
try { $lock=[IO.File]::Open($context.LockPath,'OpenOrCreate','ReadWrite','None') } catch [IO.IOException] { throw 'Another PBX update, backup, restore or certificate operation is running. Retry later.' }
try {
 Initialize-OpenWebPublicDirectory $context $lock
 $null=Get-OpenWebPublicSite $DomainName $context.Root
 $addresses=@(Resolve-DnsName -Name $DomainName -Type A -DnsOnly -NoHostsFile -ErrorAction Stop|Where-Object {$_.Type -eq 'A'}|Select-Object -ExpandProperty IPAddress)
 $PublicAddress=Resolve-OpenWebPublicAddress $PublicAddress $addresses
 # Let ACME perform its actual outside port-80 reachability/ownership test. No DNS
 # credential is collected, and a successful local probe is never called issuance.
 $statePath=Join-Path $context.Directory 'state.json'
 if(Test-Path -LiteralPath $statePath) {
  $state=Read-OpenWebPublicJson $statePath
  if($state.schema -ne 1 -or $state.hostname -ne $DomainName) { throw 'This server already has a different public hostname. Preserve it and resolve the requested hostname change explicitly.' }
  $state.public_address=$PublicAddress;$state.email_address=$EmailAddress
  Write-OpenWebPublicJson $statePath $state
 } else {
  $state=[pscustomobject]@{schema=1;hostname=$DomainName;public_address=$PublicAddress;email_address=$EmailAddress;certificate_thumbprint='';web_certificate_not_after_utc='';web_certificate_verified_at_utc='';phone_certificate_pending=$true;phone_certificate_status='not_configured';phone_certificate_verified_at_utc=''}
  Write-OpenWebPublicJson $statePath $state
 }
 $client=Initialize-OpenWebAcme $context
 $null=Set-OpenWebPublicBinding $DomainName 'http' '' $context.Root
 $service=Get-CimInstance Win32_Service -Filter "Name='FreeSWITCH'"
 if(-not $service -or $service.State -ne 'Running') { throw 'Start the installed PBX call engine before public access setup.' }
 $match=[regex]::Match($service.PathName,'^\s*(?:"([^"]+\.exe)"|([^\s]+\.exe))(?:\s|$)')
 if(-not $match.Success) { throw 'The installed call-engine executable could not be identified.' }
 $engine=if($match.Groups[1].Success){$match.Groups[1].Value}else{$match.Groups[2].Value}
 $null=Assert-OpenWebOrdinaryPath $engine
 $marker='OpenWeb PBX owned public access'
 foreach($spec in @(@('HTTP','TCP','80','System'),@('HTTPS','TCP','443','System'),@('SIP TCP','TCP','5060',$engine),@('SIP UDP','UDP','5060',$engine),@('SIP TLS','TCP','5061',$engine),@('RTP','UDP','16384-32768',$engine))) {
  $name='OpenWebPBX-Public-'+($spec[0] -replace ' ','-')
  $rule=Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue
  if($rule) {
   $port=$rule|Get-NetFirewallPortFilter;$program=$rule|Get-NetFirewallApplicationFilter
   $protocol=if($spec[1] -eq 'TCP'){'6'}else{'17'}
   if($rule.Description -ne $marker -or $rule.Group -ne $marker -or $rule.Direction -ne 'Inbound' -or $rule.Action -ne 'Allow' -or [string]$port.Protocol -notin @($spec[1],$protocol) -or [string]$port.LocalPort -ne $spec[2] -or $program.Program -ne $spec[3]) { throw 'A firewall rule with this name belongs to another configuration. It was preserved.' }
   Enable-NetFirewallRule -Name $name|Out-Null
  } else {
   New-NetFirewallRule -Name $name -DisplayName ('OpenWeb PBX public '+$spec[0]) -Description $marker -Group $marker -Direction Inbound -Action Allow -Protocol $spec[1] -LocalPort $spec[2] -Program $spec[3] -Profile Any|Out-Null
  }
 }
 Register-OpenWebPublicTasks $context.Root $context.StateRoot
 Assert-OpenWebPublicMaintenance $context $lock
 $callback=Join-Path $context.Root 'tools\Renew-PhoneCertificate.ps1'
 $null=Assert-OpenWebOrdinaryPath $callback
 if($context.Root -match "['\r\n]" -or $context.StateRoot -match "['\r\n]") { throw 'The installed path cannot be represented safely in the certificate callback.' }
 $parameters="-RecordOnly -CertificateThumbprint '{CertThumbprint}' -Root '$($context.Root)' -StateRoot '$($context.StateRoot)'"
 Invoke-OpenWebAcme $context $client @('--source','manual','--host',$DomainName,'--friendlyname','OpenWebPBX-public','--validation','selfhosting','--validationmode','http-01','--store','certificatestore','--certificatestore','My','--keepexisting','--installation','script','--script',$callback,'--scriptparameters',$parameters,'--emailaddress',$EmailAddress,'--accepttos','--notaskscheduler')
 $pending=Read-OpenWebPublicJson (Join-Path $context.Directory 'pending.json')
 if($pending.hostname -ne $DomainName) { throw 'The certificate client did not return the requested hostname.' }
 $null=Set-OpenWebPublicConfiguration $context.Configuration $DomainName $PublicAddress
 & $callback -Root $context.Root -StateRoot $context.StateRoot -MaintenanceLock $lock
 # Public DNS may name the router rather than a local NIC. Bind only actual
 # installed IPv4 interfaces; the router forwards UDP3478 to this instance.
 $stunAddresses=@(Get-NetIPAddress -AddressFamily IPv4 -AddressState Preferred|Where-Object {$_.IPAddress -notmatch '^(127\.|169\.254\.)'}|Select-Object -ExpandProperty IPAddress|Sort-Object -Unique)
 if($PublicAddress -in $stunAddresses){$stunAddresses=@($PublicAddress)}
 & (Join-Path $context.Root 'tools\Enable-Stun.ps1') -ListenAddress $stunAddresses -MaintenanceLock $lock
 Write-Host 'Public web access is configured. The certificate status reports whether secure phones are ready or waiting for existing calls to finish.'
} finally { $lock.Dispose() }
