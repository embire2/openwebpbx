# Portable policy/adapter control fixture. This never touches an OS firewall.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\packaging\windows\PhoneHealth-Firewall.Common.ps1')
$env:COMPUTERNAME='OPENWEB-HEALTH-FIXTURE';$script:checks=0;$script:rules=@{};$script:deletes=@();$script:profiles=$true;$script:failCreate=$false;$script:queryFail='';$script:foreignFail='';$script:foreignCategory=[Management.Automation.ErrorCategory]::ObjectNotFound
function Check([bool]$Value,[string]$Message){if(!$Value){throw $Message};$script:checks++}
function Refuses([scriptblock]$Action,[string]$Message){try{& $Action}catch{$script:checks++;return};throw $Message}
function Get-NetFirewallProfile {param($PolicyStore,$ErrorAction);foreach($name in 'Domain','Private','Public'){[pscustomobject]@{Name=$name;Enabled=$script:profiles}}}
function Get-NetFirewallRule {param($PolicyStore,$Name,$Enabled,$Direction,$Action,$ErrorAction);if($script:queryFail){$category=if($script:queryFail -like '*NotFound*'){[Management.Automation.ErrorCategory]::ObjectNotFound}else{[Management.Automation.ErrorCategory]::PermissionDenied};throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('Owned query fixture'),$script:queryFail,$category,$Name)};if($Name){if($script:rules.ContainsKey($Name)){$script:rules[$Name]};return};if($script:foreignFail){throw [Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('Owned foreign-query fixture'),$script:foreignFail,$script:foreignCategory,$null)};$script:rules.Values|Where-Object {$_.Enabled -eq 'True' -and $_.Direction -eq 'Inbound' -and $_.Action -eq 'Block'}}
function Get-NetFirewallAddressFilter {param([Parameter(ValueFromPipeline)]$Rule);process{[pscustomobject]@{RemoteAddress=@($Rule.Remote);LocalAddress=@('Any')}}}
function Get-NetFirewallPortFilter {param([Parameter(ValueFromPipeline)]$Rule);process{[pscustomobject]@{Protocol=$Rule.Protocol;LocalPort=$Rule.Ports;RemotePort='Any'}}}
function Get-NetFirewallApplicationFilter {param([Parameter(ValueFromPipeline)]$Rule);process{[pscustomobject]@{Program='Any'}}}
function Get-NetFirewallServiceFilter {param([Parameter(ValueFromPipeline)]$Rule);process{[pscustomobject]@{Service='Any'}}}
function New-NetFirewallRule {
 param($PolicyStore,$Name,$DisplayName,$Group,$Description,$Direction,$Action,$Enabled,$Profile,$RemoteAddress,$Protocol,$LocalPort,$ErrorAction)
 if($script:failCreate -and $Protocol -eq 'UDP'){throw 'Owned simulated second-create failure.'}
 if($script:rules.ContainsKey($Name)){throw 'Collision.'}
 $script:rules[$Name]=[pscustomobject]@{Name=$Name;DisplayName=$DisplayName;Group=$Group;Description=$Description;Direction=$Direction;Action=$Action;Enabled=[string]$Enabled;Profile=[string]$Profile;PolicyStoreSourceType='Local';Remote=@($RemoteAddress);Protocol=$Protocol;Ports=@($LocalPort)}
}
function Remove-NetFirewallRule {param($PolicyStore,$Name,$ErrorAction);$script:deletes+=$Name;$script:rules.Remove($Name)}
$address='198.51.100.10';$filter='sip-auth-fail';$tcp='5060,5061,5080';$udp='5060,5080'
$base=Get-OpenWebHealthRuleName $address $filter
Check ($base -cmatch '^OpenWebPBX-PhoneSecurity-[a-f0-9]{64}$') 'Unbounded owned identity.'
Check ($base -ceq (Get-OpenWebHealthRuleName $address $filter)) 'Identity not stable.'
Check ($base -cne (Get-OpenWebHealthRuleName '198.51.100.100' $filter)) 'Similar sources collide.'
Check ($base -cne (Get-OpenWebHealthRuleName $address 'sip-auth-ip')) 'Security filters collide.'
foreach($scope in @('5060','5059-5062','Any')){Check (Test-OpenWebHealthPortOverlap @($scope) @('5060')) 'Applicable native port scope missed.'}
foreach($scope in @('5353','49152-65535','5090')){Check (!(Test-OpenWebHealthPortOverlap @($scope) @('5060','5061'))) 'Unrelated native port scope matched.'}
foreach($scope in @('RPC','0','65536','5090-5060')){Refuses {Test-OpenWebHealthPortOverlap @($scope) @('5060')} 'Unknown native port scope accepted.'}
Check ((Invoke-OpenWebHealthFirewall State $address $filter $tcp $udp) -ceq 'absent') 'Empty state not absent.'
foreach($id in @('CmdletizationQuery_NotFound_Name,Get-NetFirewallRule','CmdletizationQuery_NotFound_InstanceID,Get-NetFirewallRule')){$script:queryFail=$id;Check ((Invoke-OpenWebHealthFirewall State $address $filter $tcp $udp) -ceq 'absent') 'Exact native missing-rule response refused.'}
$script:queryFail='AccessDenied,Get-NetFirewallRule';Refuses {Invoke-OpenWebHealthFirewall State $address $filter $tcp $udp} 'Firewall read denial promoted to absence.';$script:queryFail=''
$script:foreignFail='CmdletizationQuery_NotFound,Get-NetFirewallRule'
Check ((Invoke-OpenWebHealthFirewall State $address 'sip-auth-ip' $tcp $udp) -ceq 'absent') 'Exact empty inbound-block query refused.'
Check ((Invoke-OpenWebHealthFirewall Remove $address $filter $tcp $udp) -ceq 'absent' -and $script:deletes.Count -eq 0) 'Empty native policy changed during repeat recovery.'
foreach($id in 'AccessDenied,Get-NetFirewallRule','CmdletizationQuery_NotFound_Name,Get-NetFirewallRule','CmdletizationQuery_NotFound,Other-FirewallRule'){$script:foreignFail=$id;Refuses {Invoke-OpenWebHealthFirewall State $address 'sip-auth-ip' $tcp $udp} 'Unexpected foreign-query failure became absence.'}
$script:foreignFail='CmdletizationQuery_NotFound,Get-NetFirewallRule';$script:foreignCategory=[Management.Automation.ErrorCategory]::PermissionDenied
Refuses {Invoke-OpenWebHealthFirewall State $address 'sip-auth-ip' $tcp $udp} 'Foreign-query permission denial became absence.'
$script:foreignFail='';$script:foreignCategory=[Management.Automation.ErrorCategory]::ObjectNotFound
Check ((Invoke-OpenWebHealthFirewall Add $address $filter $tcp $udp) -ceq 'present') 'Owned native shape not created.'
Check ($script:rules.Count -eq 2) 'Expected two scoped transports.'
Check ($script:rules[$base+'-tcp'].Protocol -ceq 'TCP' -and ($script:rules[$base+'-tcp'].Ports -join ',') -ceq $tcp) 'TCP ports differ.'
Check ($script:rules[$base+'-udp'].Protocol -ceq 'UDP' -and ($script:rules[$base+'-udp'].Ports -join ',') -ceq $udp) 'UDP ports differ.'
Check ((Invoke-OpenWebHealthFirewall Add $address $filter $tcp $udp) -ceq 'present' -and $script:rules.Count -eq 2) 'Repeat add changes rules.'
$before=$script:rules|ConvertTo-Json -Depth 5
Check ((Invoke-OpenWebHealthFirewall State '198.51.100.1' $filter $tcp $udp) -ceq 'absent') 'Substring address matched.'
Check ((Invoke-OpenWebHealthFirewall Remove $address 'sip-auth-ip' $tcp $udp) -ceq 'unknown' -and ($script:rules|ConvertTo-Json -Depth 5) -ceq $before) 'Wrong filter removed.'
$script:rules[$base+'-tcp'].Description='Foreign owner'
Check ((Invoke-OpenWebHealthFirewall Remove $address $filter $tcp $udp) -ceq 'unknown' -and $script:deletes.Count -eq 0) 'Foreign rule removed.'
$script:rules[$base+'-tcp'].Description='OpenWebPBX owned '+$filter+' v1 '+$base+'-tcp'
Check ((Invoke-OpenWebHealthFirewall State $address $filter '5060,5090' $udp) -ceq 'unknown') 'Changed listener set accepted.'
$script:rules['foreign']=[pscustomobject]@{Name='foreign';Enabled='True';Direction='Inbound';Action='Block';Remote=@('198.51.100.0/24');Protocol='TCP';Ports=@('5060')}
Check ((Invoke-OpenWebHealthFirewall State $address 'sip-auth-ip' $tcp $udp) -ceq 'present') 'Foreign overlapping block ignored.'
Check ((Invoke-OpenWebHealthFirewall Remove $address $filter $tcp $udp) -ceq 'unknown' -and $script:deletes.Count -eq 0) 'Overlapping block removed.'
$script:rules['foreign'].Remote=@('203.0.113.0/24')
Check ((Invoke-OpenWebHealthFirewall Remove $address $filter $tcp $udp) -ceq 'absent') 'Exact recovery failed.'
Check ($script:rules.Count -eq 1 -and $script:rules.ContainsKey('foreign')) 'Foreign rule not preserved.'
Check ($script:deletes.Count -eq 2 -and @($script:deletes|Where-Object {$_ -cnotin @(($base+'-tcp'),($base+'-udp'))}).Count -eq 0) 'Recovery selected non-owned rules.'
Check ((Invoke-OpenWebHealthFirewall Remove $address $filter $tcp $udp) -ceq 'absent' -and $script:deletes.Count -eq 2) 'Repeat remove is not idempotent.'
foreach($scope in @('198.51.100.10','198.51.100.0/24','198.51.0.0/16','198.51.100.1-198.51.100.20','Any')){Check (Test-OpenWebHealthSourceOverlap $address $scope) 'Applicable scope missed.'}
foreach($scope in @('198.51.100.100','203.0.113.0/24','198.51.100.11-198.51.100.20','2001:db8::/32')){Check (!(Test-OpenWebHealthSourceOverlap $address $scope)) 'Unrelated scope matched.'}
foreach($scope in @('LocalSubnet','Internet','198.51.100.10/99','198.51.100.20-198.51.100.1')){Refuses {Test-OpenWebHealthSourceOverlap $address $scope} 'Ambiguous scope accepted.'}
foreach($source in @('2001:db8::1','198.51.100.10/32','127.0.0.1;calc','198.051.100.10')){Refuses {Invoke-OpenWebHealthFirewall Add $source $filter $tcp $udp} 'Invalid source accepted.'}
foreach($ports in @('22','3389','80','443','5985','5986','0','65536','5060;calc','5060,5060','05060','')){Refuses {Invoke-OpenWebHealthFirewall Add $address $filter $ports $udp} 'Invalid/protected ports accepted.'}
$script:profiles=$false
Refuses {Invoke-OpenWebHealthFirewall Add $address $filter $tcp $udp} 'Disabled firewall accepted.'
Check ($script:rules.Count -eq 1) 'Disabled profile mutated rules.'
$script:profiles=$true;$script:failCreate=$true
Refuses {Invoke-OpenWebHealthFirewall Add $address $filter $tcp $udp} 'Second-create failure accepted.'
Check ($script:rules.Count -eq 1 -and $script:rules.ContainsKey('foreign')) 'Owned partial creation not recovered.'
$script:failCreate=$false
Check ((Invoke-OpenWebHealthFirewall Add $address $filter $tcp $udp) -ceq 'present') 'Create after recovery failed.'
$script:rules.Remove($base+'-tcp')
Check ((Invoke-OpenWebHealthFirewall Remove $address $filter $tcp $udp) -ceq 'absent' -and $script:rules.Count -eq 1) 'Partial previous deletion cannot recover.'
@{checks=$script:checks;portable_adapter_controls=$true;actual_windows_firewall=$false;no_host_firewall_changes=$true}|ConvertTo-Json -Compress
