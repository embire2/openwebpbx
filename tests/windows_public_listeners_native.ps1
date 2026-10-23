#Requires -RunAsAdministrator
#Requires -Version 5.1
# Native Defender/NTFS/socket proof; installed service identity is an explicit
# adapter for this owned PowerShell process. No installed server is modified.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest;$checks=0
if($PSVersionTable.PSEdition -ne 'Desktop'){throw 'Native Windows PowerShell is required.'}
function Check([bool]$Value){if(!$Value){throw ('Native public-listener control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
function Refuse([scriptblock]$Action){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Check $failed}
. (Join-Path $SourceRoot 'packaging/windows/PublicAccess.Common.ps1')
function Policy {
 $r=[ordered]@{}
 foreach($command in 'Get-NetFirewallRule','Get-NetFirewallAddressFilter','Get-NetFirewallPortFilter','Get-NetFirewallApplicationFilter','Get-NetFirewallServiceFilter','Get-NetFirewallInterfaceFilter','Get-NetFirewallInterfaceTypeFilter','Get-NetFirewallSecurityFilter','Get-NetFirewallProfile'){
  $r[$command]=@(& $command -PolicyStore PersistentStore -ErrorAction Stop|ForEach-Object {$v=[ordered]@{};foreach($p in $_.CimInstanceProperties|Sort-Object Name){$v[$p.Name]=$p.Value};[pscustomobject]$v}|Sort-Object InstanceID,Name)
 };return ($r|ConvertTo-Json -Depth 16 -Compress)
}
$before=Policy;$socket=$null;$datagram=$null;$lock=$null;$work=$null;$known=@();$done=$false
try{
 $profiles=@(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop)
 if($profiles.Count -ne 3 -or (($profiles|Sort-Object Name|ForEach-Object {[string]$_.Name}) -join ',') -cne 'Domain,Private,Public' -or @($profiles|Where-Object {[string]$_.Enabled -cnotin 'True','False'}).Count){throw 'The current Defender profile observation is incomplete or ambiguous.'}
 $profilesAllEnabled=@($profiles|Where-Object {[string]$_.Enabled -cne 'True'}).Count -eq 0;Check $true
 Check (@(Get-NetTCPConnection -State Listen|Where-Object {$_.LocalPort -eq 5061}).Count -eq 0)
 $address=@(Get-NetIPAddress -AddressFamily IPv4 -AddressState Preferred|Where-Object {$_.IPAddress -notmatch '^(127\.|169\.254\.)'}|Sort-Object IPAddress|Select-Object -ExpandProperty IPAddress)[0]
 for($attempt=0;$attempt -lt 20;$attempt++){
  $socket=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Parse($address),0);$socket.Start();$port=$socket.LocalEndpoint.Port
  try{$datagram=[Net.Sockets.UdpClient]::new([Net.IPEndPoint]::new([Net.IPAddress]::Parse($address),$port));break}catch{$socket.Stop();$socket=$null}
 }
 Check ($null -ne $socket -and $null -ne $datagram -and $port -ge 1024)
 $engine=(Get-Process -Id $PID).Path;$process=CimCmdlets\Get-CimInstance Win32_Process -Filter ('ProcessId='+$PID);$created=$process.CreationDate
 $inventory=[pscustomobject]@{schema=1;database_read_only=$true;rtp_supported_core_defaults=$true;rtp_proof='supported_core_configured_default';private_ports=@(3389,5432,5433,8021,8087);rtp_start=16384;rtp_end=32768;listeners=@([pscustomobject]@{address=$address;port=$port;protocol='TCP';tls=$false},[pscustomobject]@{address=$address;port=$port;protocol='UDP';tls=$false})}
 $plan=ConvertTo-OpenWebPublicListenerPlan $inventory $engine $PID $created
 # Only these two new temporary program/port-scoped rules may be changed.
 $plan.specs=@($plan.specs|Where-Object {$_.port -ceq [string]$port})
 Check ($plan.specs.Count -eq 2)
 Check (@($plan.specs|Where-Object {$_.port -cin '3389','5432','5433','8021','8087'}).Count -eq 0)
 foreach($spec in $plan.specs){Check (@(Get-OpenWebPublicOwnedRule $spec.name).Count -eq 0);$known+=$spec.name}
 function Get-CimInstance { [CmdletBinding()]param($ClassName,$Filter)
  if($ClassName -ceq 'Win32_Service' -and $Filter -ceq "Name='FreeSWITCH'"){return [pscustomobject]@{State='Running';ProcessId=$PID}}
  return CimCmdlets\Get-CimInstance $ClassName -Filter $Filter -ErrorAction Stop
 }
 Assert-OpenWebPublicListenerOwnership $plan;Check $true
 $work=Join-Path ([IO.Path]::GetTempPath()) ('openweb-public-ports-'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($work);Set-OpenWebPublicPrivateAcl $work
 $context=@{StateRoot=$work;Root=$work;LockPath=(Join-Path $work 'upgrade.lock')};$lock=[IO.File]::Open($context.LockPath,'OpenOrCreate','ReadWrite','None')
 Sync-OpenWebPublicListenerPlan $context $plan $lock
 foreach($spec in $plan.specs){$r=@(Get-OpenWebPublicOwnedRule $spec.name);Assert-OpenWebPublicRule $r $spec;Check ([string]$r[0].Enabled -ceq 'True')}
 $once=Policy;Sync-OpenWebPublicListenerPlan $context $plan $lock;Check ((Policy) -ceq $once)
 foreach($spec in $plan.specs){NetSecurity\Remove-NetFirewallRule -PolicyStore PersistentStore -Name $spec.name -ErrorAction Stop}
 # Real cmdlet mutation followed by a deliberate exception: actual production
 # rollback must remove/disable exact owned state, rather than trust exit status.
 $script:failCreate=$true;$script:realCreates=0;$script:realEnables=0
 function New-NetFirewallRule { [CmdletBinding()]param($PolicyStore,$Name,$DisplayName,$Description,$Group,$Direction,$Action,$Protocol,$LocalPort,$Program,$Profile)
  $row=NetSecurity\New-NetFirewallRule @PSBoundParameters;$script:realCreates++
  if($script:failCreate){throw 'Deliberate failure after real native creation.'};return $row
 }
 Refuse {Sync-OpenWebPublicListenerPlan $context $plan $lock};Check ($script:realCreates -eq 1)
 foreach($spec in $plan.specs){Check (@(Get-OpenWebPublicOwnedRule $spec.name).Count -eq 0)}
 $script:failCreate=$false;$spec=$plan.specs[0]
 $null=NetSecurity\New-NetFirewallRule -PolicyStore PersistentStore -Name $spec.name -DisplayName 'Owned temporary native public-port fixture' -Description 'OpenWeb PBX owned public access' -Group 'OpenWeb PBX owned public access' -Direction Inbound -Action Allow -Protocol $spec.protocol -LocalPort $spec.port -Program $spec.program -Profile Any -Enabled False
 function Enable-NetFirewallRule { [CmdletBinding()]param($PolicyStore,$Name)NetSecurity\Enable-NetFirewallRule @PSBoundParameters|Out-Null;$script:realEnables++;throw 'Deliberate failure after real native enable.'}
 Refuse {Sync-OpenWebPublicListenerPlan $context $plan $lock};Check ($script:realEnables -eq 1);Check ([string](@(Get-OpenWebPublicOwnedRule $spec.name))[0].Enabled -ceq 'False')
 NetSecurity\Remove-NetFirewallRule -PolicyStore PersistentStore -Name $spec.name
 # A native unfamiliar same-name rule is preserved exactly before any mutation.
 $spec=$plan.specs[-1];$null=NetSecurity\New-NetFirewallRule -PolicyStore PersistentStore -Name $spec.name -DisplayName 'Owned fixture foreign-rule negative' -Description 'OpenWebPBX QA foreign-rule negative' -Group 'OpenWebPBX QA foreign-rule negative' -Direction Inbound -Action Allow -Protocol $spec.protocol -LocalPort $spec.port -Program $spec.program -Profile Any
 $foreign=Policy;Refuse {Sync-OpenWebPublicListenerPlan $context $plan $lock};Check ((Policy) -ceq $foreign)
 NetSecurity\Remove-NetFirewallRule -PolicyStore PersistentStore -Name $spec.name
 Check ((Policy) -ceq $before);$done=$true
 [ordered]@{schema=1;producer='windows_public_listeners_native.ps1';state='passed';checks=$checks;actual_native_defender=$true;actual_os_listener_ownership=$true;service_identity_adapter_double=$true;global_policy_exact=$true;actual_throw_after_create_and_enable=$true;idempotent=$true;foreign_named_rule_preserved=$true;configured_private_ports_excluded=$true;profiles_all_enabled_at_observation=[bool]$profilesAllEnabled;firewall_enforcement_tested=$false;firewall_profiles_changed=$false;installed_server_changed=$false;calls_placed=$false}|ConvertTo-Json -Compress
}finally{
 foreach($name in $known){
  $rows=@(Get-OpenWebPublicOwnedRule $name)
  if($rows.Count){$spec=@($plan.specs|Where-Object name -CEQ $name)[0];$r=$rows[0];$app=@($r|Get-NetFirewallApplicationFilter);$ports=@($r|Get-NetFirewallPortFilter)
   if($rows.Count -ne 1 -or $app.Count -ne 1 -or $app[0].Program -ine $engine -or $ports.Count -ne 1 -or [string]$ports[0].LocalPort -cne $spec.port -or $r.Description -cnotin 'OpenWeb PBX owned public access','OpenWebPBX QA foreign-rule negative'){throw 'A fixture rule changed ownership; cleanup refused.'}
   NetSecurity\Remove-NetFirewallRule -PolicyStore PersistentStore -Name $name -ErrorAction Stop
  }
 }
 if($lock){$lock.Dispose()};if($socket){$socket.Stop()};if($datagram){$datagram.Dispose()}
 if((Policy) -cne $before){throw 'The complete native firewall policy did not restore exactly.'}
 if($done -and $work){Remove-Item -LiteralPath $work -Recurse -Force}
}
