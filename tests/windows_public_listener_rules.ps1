# Execute actual public-port planner/rule functions with explicit OS adapters.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest;$checks=0
function Check([bool]$Value){if(!$Value){throw ('Listener control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
function Refuse([scriptblock]$Action){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Check $failed}
. (Join-Path $SourceRoot 'packaging/windows/PublicAccess.Common.ps1')
$engine='fixture-engine.exe';$created=[datetime]'2026-10-22T00:00:00Z'
function Inventory {return [pscustomobject]@{schema=1;database_read_only=$true;rtp_supported_core_defaults=$true;rtp_proof='supported_core_configured_default';private_ports=@(3389,5432,5433,8021,8087);rtp_start=16384;rtp_end=32768;listeners=@([pscustomobject]@{address='198.18.0.1';port=5060;protocol='TCP';tls=$false},[pscustomobject]@{address='198.18.0.1';port=5060;protocol='UDP';tls=$false},[pscustomobject]@{address='198.18.0.1';port=5080;protocol='TCP';tls=$false},[pscustomobject]@{address='198.18.0.1';port=5080;protocol='UDP';tls=$false})}}
$plan=ConvertTo-OpenWebPublicListenerPlan (Inventory) $engine 4242 $created
Check (@($plan.specs).Count -eq 7);Check (@($plan.specs|Where-Object {$_.name -ceq 'OpenWebPBX-Public-SIP-TCP-5080' -and $_.port -ceq '5080'}).Count -eq 1)
Check (@($plan.specs|Where-Object {$_.name -ceq 'OpenWebPBX-Public-SIP-TLS'}).Count -eq 0)
foreach($port in 3389,5432,5433,8021,8087){$i=Inventory;$i.listeners[0].port=$port;Refuse {ConvertTo-OpenWebPublicListenerPlan $i $engine 4242 $created}}
foreach($bad in '5060',$true,0,65536){$i=Inventory;$i.listeners[0].port=$bad;Refuse {ConvertTo-OpenWebPublicListenerPlan $i $engine 4242 $created}}
foreach($bad in '127.0.0.1','::1','invalid'){$i=Inventory;$i.listeners[0].address=$bad;Refuse {ConvertTo-OpenWebPublicListenerPlan $i $engine 4242 $created}}
foreach($field in 'database_read_only','rtp_supported_core_defaults'){$i=Inventory;$i.$field='true';Refuse {ConvertTo-OpenWebPublicListenerPlan $i $engine 4242 $created}}
$i=Inventory;$i.private_ports=@(5433);Refuse {ConvertTo-OpenWebPublicListenerPlan $i $engine 4242 $created}
$i=Inventory;$i.listeners[0].port=5090;$i.private_ports+=5090;Refuse {ConvertTo-OpenWebPublicListenerPlan $i $engine 4242 $created}
$i=Inventory;$i.rtp_start=20000;Refuse {ConvertTo-OpenWebPublicListenerPlan $i $engine 4242 $created}
$i=Inventory;$i.listeners[0].port=5061;Refuse {ConvertTo-OpenWebPublicListenerPlan $i $engine 4242 $created}
$script:tcp=@(foreach($l in $plan.listeners|Where-Object protocol -CEQ TCP){[pscustomobject]@{LocalAddress=$l.address;LocalPort=$l.port;OwningProcess=4242}})
$script:udp=@(foreach($l in $plan.listeners|Where-Object protocol -CEQ UDP){[pscustomobject]@{LocalAddress=$l.address;LocalPort=$l.port;OwningProcess=4242}})
function Get-CimInstance { [CmdletBinding()]param($ClassName,$Filter)
 if($ClassName -ceq 'Win32_Service'){return [pscustomobject]@{State='Running';ProcessId=4242}}
 if($ClassName -ceq 'Win32_Process'){return [pscustomobject]@{ExecutablePath=$engine;CreationDate=$created}}
 throw 'Unexpected native identity query'
}
function Get-NetTCPConnection { [CmdletBinding()]param($State)return $script:tcp}
function Get-NetUDPEndpoint { [CmdletBinding()]param()return $script:udp}
Assert-OpenWebPublicListenerOwnership $plan;Check $true
$script:tcp+=[pscustomobject]@{LocalAddress='0.0.0.0';LocalPort=5061;OwningProcess=999};Refuse {Assert-OpenWebPublicListenerOwnership $plan};$script:tcp=$script:tcp|Where-Object LocalPort -NE 5061
$script:tcp[0].OwningProcess=999;Refuse {Assert-OpenWebPublicListenerOwnership $plan};$script:tcp[0].OwningProcess=4242
$script:rules=@{};$script:changed=0;$script:failure='';$script:cleanupNoop=$false
function Rule($Spec,[string]$Enabled='True'){
 return [pscustomobject]@{Name=$Spec.name;Description='OpenWeb PBX owned public access';Group='OpenWeb PBX owned public access';Direction='Inbound';Action='Allow';Enabled=$Enabled;Profile='Any';EdgeTraversalPolicy='Block';LooseSourceMapping=$false;LocalOnlyMapping=$false;ports=[pscustomobject]@{Protocol=$Spec.protocol;LocalPort=$Spec.port;RemotePort='Any'};apps=[pscustomobject]@{Program=$Spec.program};addresses=[pscustomobject]@{LocalAddress='Any';RemoteAddress='Any'};services=[pscustomobject]@{Service='Any'};interfaces=[pscustomobject]@{InterfaceAlias='Any'};types=[pscustomobject]@{InterfaceType='Any'};security=[pscustomobject]@{Authentication='NotRequired';Encryption='NotRequired';LocalUser='Any';RemoteUser='Any';RemoteMachine='Any';OverrideBlockRules=$false}}
}
foreach($pair in @(@('Get-NetFirewallPortFilter','ports'),@('Get-NetFirewallApplicationFilter','apps'),@('Get-NetFirewallAddressFilter','addresses'),@('Get-NetFirewallServiceFilter','services'),@('Get-NetFirewallInterfaceFilter','interfaces'),@('Get-NetFirewallInterfaceTypeFilter','types'),@('Get-NetFirewallSecurityFilter','security'))){
 $body='[CmdletBinding()]param([Parameter(ValueFromPipeline)]$InputObject)process{$InputObject.'+$pair[1]+'}'
 Set-Item ('Function:'+ $pair[0]) ([scriptblock]::Create($body))
}
function Get-OpenWebPublicOwnedRule([string]$Name){if($script:rules.ContainsKey($Name)){return $script:rules[$Name]}}
function New-NetFirewallRule { [CmdletBinding()]param($PolicyStore,$Name,$DisplayName,$Description,$Group,$Direction,$Action,$Protocol,$LocalPort,$Program,$Profile)
 $spec=[pscustomobject]@{name=$Name;protocol=$Protocol;port=$LocalPort;program=$Program};$script:rules[$Name]=Rule $spec;$script:changed++;if($script:failure -ceq 'create'){throw 'Deliberate after-create failure'}
}
function Enable-NetFirewallRule { [CmdletBinding()]param($PolicyStore,$Name)$script:rules[$Name].Enabled='True';$script:changed++;if($script:failure -ceq 'enable'){throw 'Deliberate after-enable failure'}}
function Disable-NetFirewallRule { [CmdletBinding()]param($PolicyStore,$Name)if(!$script:cleanupNoop){$script:rules[$Name].Enabled='False'}}
function Remove-NetFirewallRule { [CmdletBinding()]param($PolicyStore,$Name)if(!$script:cleanupNoop){$script:rules.Remove($Name)}}
function Assert-OpenWebPublicMaintenance {param($Context,$MaintenanceLock)}
$spec=$plan.specs[0];$good=Rule $spec;Assert-OpenWebPublicRule $good $spec;Check $true
foreach($pair in @(@('Description','foreign'),@('Profile','Private'),@('EdgeTraversalPolicy','Allow'),@('LooseSourceMapping',$true),@('LocalOnlyMapping',$true))){$r=Rule $spec;$r.($pair[0])=$pair[1];Refuse {Assert-OpenWebPublicRule $r $spec}}
foreach($pair in @(@('ports','RemotePort','5060'),@('apps','Program','foreign.exe'),@('addresses','RemoteAddress','198.18.0.1'),@('services','Service','foreign'),@('interfaces','InterfaceAlias','Ethernet'),@('types','InterfaceType','Wireless'),@('security','Authentication','Required'),@('security','Encryption','Required'),@('security','LocalUser','foreign'),@('security','RemoteUser','foreign'),@('security','RemoteMachine','foreign'),@('security','OverrideBlockRules',$true))){$r=Rule $spec;$r.($pair[0]).($pair[1])=$pair[2];Refuse {Assert-OpenWebPublicRule $r $spec}}
$script:rules=@{};$late=$plan.specs[-1];$script:rules[$late.name]=Rule $late;$script:rules[$late.name].Description='foreign';Refuse {Sync-OpenWebPublicListenerPlan @{} $plan $null};Check ($script:changed -eq 0 -and $script:rules.Count -eq 1)
$script:rules=@{};$intended=[pscustomobject]@{name='OpenWebPBX-Public-SIP-TLS';protocol='TCP';port='5061';program=$engine};$script:rules[$intended.name]=Rule $intended;$script:rules[$intended.name].Description='foreign';Refuse {Test-OpenWebPublicListenerRules $plan -IncludeIntendedTls};Check ($script:changed -eq 0)
foreach($failure in 'create','enable'){
 $script:rules=@{};if($failure -ceq 'enable'){$script:rules[$spec.name]=Rule $spec 'False'}
 $script:failure=$failure;Refuse {Sync-OpenWebPublicListenerPlan @{} $plan $null}
 Check ($(if($failure -ceq 'create'){$script:rules.Count -eq 0}else{$script:rules.Count -eq 1 -and $script:rules[$spec.name].Enabled -ceq 'False'}))
 $script:cleanupNoop=$true;$failed=$false;try{Sync-OpenWebPublicListenerPlan @{} $plan $null}catch{$failed=$_.Exception.Data['OpenWebPublicRuleCleanupFailed'] -eq $true};Check $failed;$script:cleanupNoop=$false
}
$script:rules=@{};$script:failure='';Sync-OpenWebPublicListenerPlan @{} $plan $null;Check ($script:rules.Count -eq $plan.specs.Count);$count=$script:changed;Sync-OpenWebPublicListenerPlan @{} $plan $null;Check ($script:changed -eq $count)
# Actual caller order and dependency inventories, without running the installer.
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'packaging/windows/Enable-PublicAccess.ps1'),[ref]$t,[ref]$e);Check ($e.Count -eq 0)
$text=$ast.Extent.Text;$pre=$text.IndexOf('$null=Test-OpenWebPublicListenerRules $listenerPlan -IncludeIntendedTls');Check ($pre -ge 0 -and $pre -lt $text.IndexOf('Write-OpenWebPublicJson $statePath') -and $pre -lt $text.IndexOf("Set-OpenWebPublicBinding `$DomainName 'http'"))
$copy=Get-Content (Join-Path $SourceRoot 'packaging/windows/Install-Updater.ps1') -Raw
foreach($name in 'public-listeners.php','public-listeners-policy.php','public-listeners-esl.php'){Check ($copy.Contains("'"+$name+"'"))}
[ordered]@{schema=1;state='passed';checks=$checks;actual_source_functions=$true;os_and_firewall_adapters=$true;actual_native_defender=$false;calling_or_installed_server_mutation=$false}|ConvertTo-Json -Compress
