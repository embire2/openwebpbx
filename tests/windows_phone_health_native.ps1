#Requires -RunAsAdministrator
# Native Defender tests use only exact, reserved-address fixture rules. They do
# not start services, change firewall profiles, call a phone or edit the PBX DB.
[CmdletBinding()]
param([string]$Helpers=(Join-Path $PSScriptRoot '..\packaging\windows'))
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'Native Windows is required.'}
Import-Module NetSecurity -ErrorAction Stop
. (Join-Path $Helpers 'PhoneHealth-Firewall.Common.ps1')
$checks=0;$source='198.18.0.254';$tcp='5090,5091';$udp='5090';$filter='sip-auth-fail';$base=Get-OpenWebHealthRuleName $source $filter
$alternate=Get-OpenWebHealthRuleName $source 'sip-auth-ip';$foreign='OpenWebPBX-HealthTest-'+[Guid]::NewGuid().ToString('N');$other='OpenWebPBX-HealthTest-'+[Guid]::NewGuid().ToString('N');$created=@();$baseline=$null
function Check([bool]$Value,[string]$Message){if(!$Value){throw $Message};$script:checks++}
function Policy {
 $result=[ordered]@{}
 foreach($command in 'Get-NetFirewallRule','Get-NetFirewallAddressFilter','Get-NetFirewallPortFilter','Get-NetFirewallApplicationFilter','Get-NetFirewallServiceFilter','Get-NetFirewallInterfaceFilter','Get-NetFirewallInterfaceTypeFilter','Get-NetFirewallSecurityFilter','Get-NetFirewallProfile'){
  $rows=@(& $command -PolicyStore PersistentStore -ErrorAction Stop|ForEach-Object {$item=[ordered]@{};foreach($p in $_.CimInstanceProperties|Sort-Object Name){$item[$p.Name]=$p.Value};[pscustomobject]$item}|Sort-Object InstanceID,Name)
  $result[$command]=$rows
 };return ($result|ConvertTo-Json -Depth 16 -Compress)
}
function RemoveFixture([string]$Name){
 $r=@(Get-OpenWebHealthExactRule $Name 'PersistentStore');if(!$r){return}
 if($Name -notin $script:created){throw 'The native test refuses an unowned cleanup target.'}
 Remove-NetFirewallRule -PolicyStore PersistentStore -Name $Name -ErrorAction Stop
}
try{
 foreach($name in @(($base+'-tcp'),($base+'-udp'),($alternate+'-tcp'),($alternate+'-udp'),$foreign,$other)){if(@(Get-OpenWebHealthExactRule $name 'PersistentStore').Count){throw 'A reserved fixture rule already exists; no rule changed.'}}
 $baseline=Policy
 Check ((Invoke-OpenWebHealthFirewall State $source $filter $tcp $udp) -eq 'absent') 'Native empty state wrong.'
 Check ((Invoke-OpenWebHealthFirewall State $source 'sip-auth-ip' $tcp $udp) -eq 'absent') 'Native alternate empty state wrong.'
 $null=New-NetFirewallRule -PolicyStore PersistentStore -Name $other -DisplayName 'OpenWebPBX isolated native fixture' -Direction Inbound -Action Block -Enabled True -Profile Any -RemoteAddress '198.18.0.253' -Protocol TCP -LocalPort 5090;$created+=$other
 $created+=@(($base+'-tcp'),($base+'-udp'))
 Check ((Invoke-OpenWebHealthFirewall Add $source $filter $tcp $udp) -eq 'present') 'Native scoped blocks failed.'
 foreach($protocol in 'TCP','UDP'){$name=$base+'-'+$protocol.ToLowerInvariant();$rows=@(Get-OpenWebHealthExactRule $name 'ActiveStore');$ports=if($protocol -eq 'TCP'){@('5090','5091')}else{@('5090')};Check ($rows.Count -eq 1 -and (Test-OpenWebHealthOwnedRule $rows[0] $name $source $filter $protocol $ports)) 'Native rule ownership/port/protocol differs.'}
 $stable=Policy;Check ((Invoke-OpenWebHealthFirewall Add $source $filter $tcp $udp) -eq 'present' -and (Policy) -ceq $stable) 'Repeat add changed native policy.'
 Check ((Invoke-OpenWebHealthFirewall State '198.18.0.25' $filter $tcp $udp) -eq 'absent') 'Native substring matched.'
 Check ((Invoke-OpenWebHealthFirewall State $source $filter '5090,5092' $udp) -eq 'unknown') 'Changed native portlist accepted.'
 $null=New-NetFirewallRule -PolicyStore PersistentStore -Name $foreign -DisplayName 'OpenWebPBX isolated native overlap fixture' -Direction Inbound -Action Block -Enabled True -Profile Any -RemoteAddress $source -Protocol UDP -LocalPort 5090;$created+=$foreign
 $blocked=Policy;Check ((Invoke-OpenWebHealthFirewall State $source 'sip-auth-ip' $tcp $udp) -eq 'present') 'Overlapping foreign block missed.'
 Check ((Invoke-OpenWebHealthFirewall Remove $source $filter $tcp $udp) -eq 'unknown' -and (Policy) -ceq $blocked) 'Foreign overlap changed policy.'
 RemoveFixture $foreign
 Set-NetFirewallRule -PolicyStore PersistentStore -Name ($base+'-tcp') -Description 'OpenWebPBX native fixture changed description' -ErrorAction Stop
 $changed=Policy;Check ((Invoke-OpenWebHealthFirewall Remove $source $filter $tcp $udp) -eq 'unknown' -and (Policy) -ceq $changed) 'Changed owner description removed.'
 Set-NetFirewallRule -PolicyStore PersistentStore -Name ($base+'-tcp') -Description ('OpenWebPBX owned '+$filter+' v1 '+$base+'-tcp') -ErrorAction Stop
 $created+=@(($alternate+'-tcp'),($alternate+'-udp'));Check ((Invoke-OpenWebHealthFirewall Add $source 'sip-auth-ip' $tcp $udp) -eq 'present') 'Alternate native block failed.'
 $both=Policy;Check ((Invoke-OpenWebHealthFirewall Remove $source $filter $tcp $udp) -eq 'unknown' -and (Policy) -ceq $both) 'Alternate block did not prevent recovery.'
 foreach($name in @(($alternate+'-tcp'),($alternate+'-udp'))){RemoveFixture $name}
 Check ((Invoke-OpenWebHealthFirewall Remove $source $filter $tcp $udp) -eq 'absent') 'Native exact recovery failed.'
 Check (@(Get-OpenWebHealthExactRule $other 'PersistentStore').Count -eq 1) 'Unrelated fixture disappeared.'
 $again=Policy;Check ((Invoke-OpenWebHealthFirewall Remove $source $filter $tcp $udp) -eq 'absent' -and (Policy) -ceq $again) 'Native repeat recovery changed policy.'
 RemoveFixture $other
 Check ((Invoke-OpenWebHealthFirewall State $source 'sip-auth-ip' $tcp $udp) -eq 'absent') 'Native empty overlap query refused after cleanup.'
 Check ((Policy) -ceq $baseline) 'Native firewall projection was not preserved.'
 @{checks=$checks;actual_native_windows_defender=$true;all_original_projected_policy_exact=$true;source='reserved test address';services_started=$false;customer_calls=$false}|ConvertTo-Json -Compress
}finally{
 foreach($name in $created){RemoveFixture $name}
 if($null -ne $baseline -and (Policy) -cne $baseline){throw 'Native test cleanup requires review; original firewall projection differs.'}
}
