# SPDX-License-Identifier: AGPL-3.0-or-later
# Pure identity/overlap functions also run in portable tests. All mutations use
# exact local owned rule names; no profile policy or unrelated rule is changed.
function Get-OpenWebHealthRuleName([string]$Address,[string]$Filter){
 $ip=$null
 if(![Net.IPAddress]::TryParse($Address,[ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $Filter -cnotin 'sip-auth-fail','sip-auth-ip'){throw 'A supported exact security source is required.'}
 $canonical=$ip.ToString();if($canonical -cne $Address){throw 'A canonical exact security source is required.'}
 $sha=[Security.Cryptography.SHA256]::Create()
 try{$hash=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($env:COMPUTERNAME.ToLowerInvariant()+"`n"+$Filter+"`n"+$canonical)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
 return 'OpenWebPBX-PhoneSecurity-'+$hash
}
function ConvertTo-OpenWebHealthPorts([string]$Csv){
 if($Csv -cnotmatch '^[0-9]{1,5}(,[0-9]{1,5}){0,31}$'){throw 'Bounded phone listener ports are required.'}
 $ports=@($Csv.Split(',')|ForEach-Object {$n=[int]$_;if($n -lt 1 -or $n -gt 65535 -or $n -in 22,80,443,3389,5985,5986){throw 'The phone listener overlaps a protected administration port.'};[string]$n}|Sort-Object -Unique)
 if($ports.Count -ne $Csv.Split(',').Count -or ($ports -join ',') -cne ((@($Csv.Split(',')|Sort-Object -Unique)) -join ',')){throw 'Canonical phone listener ports are required.'};return $ports
}
function Test-OpenWebHealthOwnedRule($Rule,[string]$Name,[string]$Address,[string]$Filter,[string]$Protocol,[string[]]$ExpectedPorts){
 if($null -eq $Rule -or $Rule.Name -cne $Name -or $Rule.Group -cne 'OpenWebPBX Phone Security' -or $Rule.Description -cne ('OpenWebPBX owned '+$Filter+' v1 '+$Name) -or [string]$Rule.Enabled -ne 'True' -or [string]$Rule.Direction -ne 'Inbound' -or [string]$Rule.Action -ne 'Block' -or [string]$Rule.Profile -ne 'Any' -or [string]$Rule.PolicyStoreSourceType -ne 'Local'){return $false}
 $addresses=@($Rule|Get-NetFirewallAddressFilter -ErrorAction Stop);$ports=@($Rule|Get-NetFirewallPortFilter -ErrorAction Stop);$apps=@($Rule|Get-NetFirewallApplicationFilter -ErrorAction Stop);$services=@($Rule|Get-NetFirewallServiceFilter -ErrorAction Stop)
 return $addresses.Count -eq 1 -and @($addresses[0].RemoteAddress).Count -eq 1 -and @($addresses[0].RemoteAddress)[0] -in @($Address,($Address+'/32')) -and @($addresses[0].LocalAddress).Count -eq 1 -and @($addresses[0].LocalAddress)[0] -eq 'Any' -and $ports.Count -eq 1 -and [string]$ports[0].Protocol -in @($Protocol, $(if($Protocol -eq 'TCP'){'6'}else{'17'})) -and ((@($ports[0].LocalPort|Sort-Object)) -join ',') -ceq ((@($ExpectedPorts|Sort-Object)) -join ',') -and [string]$ports[0].RemotePort -eq 'Any' -and $apps.Count -eq 1 -and $apps[0].Program -eq 'Any' -and $services.Count -eq 1 -and $services[0].Service -eq 'Any'
}
function Test-OpenWebHealthSourceOverlap([string]$Address,[string]$Scope){
 if($Scope -eq 'Any'){return $true}
 $target=[Net.IPAddress]::Parse($Address).GetAddressBytes()
 $ip=$null
 if([Net.IPAddress]::TryParse($Scope,[ref]$ip)){return $ip.Equals([Net.IPAddress]::Parse($Address))}
 if($Scope -match '^([0-9.]+)/([0-9]{1,2})$'){
  $base=$null;$bits=[int]$Matches[2];if($bits -gt 32 -or ![Net.IPAddress]::TryParse($Matches[1],[ref]$base) -or $base.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){throw 'An ambiguous firewall scope needs review.'}
  $bytes=$base.GetAddressBytes();for($i=0;$i -lt 4;$i++){$take=[Math]::Max(0,[Math]::Min(8,$bits-8*$i));$mask=if($take){256-(1 -shl (8-$take))}else{0};if(($target[$i] -band $mask) -ne ($bytes[$i] -band $mask)){return $false}};return $true
 }
 if($Scope -match '^([0-9.]+)-([0-9.]+)$'){
  $low=[Net.IPAddress]::Parse($Matches[1]).GetAddressBytes();$high=[Net.IPAddress]::Parse($Matches[2]).GetAddressBytes();if($low.Length -ne 4 -or $high.Length -ne 4){throw 'An ambiguous firewall scope needs review.'}
  $n=0L;$a=0L;$b=0L;for($i=0;$i -lt 4;$i++){$n=$n*256+$target[$i];$a=$a*256+$low[$i];$b=$b*256+$high[$i]};if($a -gt $b){throw 'An ambiguous firewall scope needs review.'};return $n -ge $a -and $n -le $b
 }
 # IPv6-only scopes do not contain an IPv4 source. Dynamic keywords may;
 # refuse rather than claiming an overlapping security restriction is absent.
 if($Scope.Contains(':')){return $false};throw 'An ambiguous firewall scope needs review.'
}
function Get-OpenWebHealthExactRule([string]$Name,[string]$Store){
 try{Get-NetFirewallRule -PolicyStore $Store -Name $Name -ErrorAction Stop}
 catch{
  if([string]$_.CategoryInfo.Category -eq 'ObjectNotFound' -and $_.FullyQualifiedErrorId -cin @('CmdletizationQuery_NotFound_Name,Get-NetFirewallRule','CmdletizationQuery_NotFound_InstanceID,Get-NetFirewallRule')){return}
  throw
 }
}
function Get-OpenWebHealthFirewallState([string]$Address,[string]$Filter,[hashtable]$Listeners){
 $base=Get-OpenWebHealthRuleName $Address $Filter;$found=0
 foreach($protocol in 'TCP','UDP'){
  $name=$base+'-'+$protocol.ToLowerInvariant();$rules=@(Get-OpenWebHealthExactRule $name 'ActiveStore')
  if($rules.Count -gt 1){return 'unknown'}
  if($rules.Count -eq 1){if(!(Test-OpenWebHealthOwnedRule $rules[0] $name $Address $Filter $protocol $Listeners[$protocol])){return 'unknown'};$found++}
 }
 if($found -gt 0){return 'present'};return 'absent'
}
function Test-OpenWebHealthPortOverlap($Scopes,[string[]]$Listeners){
 foreach($scope in @($Scopes)){
  if([string]$scope -eq 'Any'){return $true}
  if([string]$scope -match '^([0-9]{1,5})(?:-([0-9]{1,5}))?$'){
   $low=[int]$Matches[1];$high=if($Matches[2]){[int]$Matches[2]}else{$low}
   if($low -lt 1 -or $high -gt 65535 -or $low -gt $high){throw 'An ambiguous firewall port range needs review.'}
   foreach($port in $Listeners){if([int]$port -ge $low -and [int]$port -le $high){return $true}}
  }else{throw 'An ambiguous firewall port needs review.'}
 };return $false
}
function Get-OpenWebHealthInboundBlocks {
 try{Get-NetFirewallRule -PolicyStore ActiveStore -Enabled True -Direction Inbound -Action Block -ErrorAction Stop}
 catch{
  # A clean Windows policy returns this exact native empty-query error rather
  # than an empty pipeline. Permission, provider and other query failures must
  # remain unavailable, never become proof that a restriction is absent.
  if([string]$_.CategoryInfo.Category -ceq 'ObjectNotFound' -and $_.FullyQualifiedErrorId -ceq 'CmdletizationQuery_NotFound,Get-NetFirewallRule'){return}
  throw
 }
}
function Test-OpenWebHealthForeignBlock([string]$Address,[hashtable]$Listeners){
 $owned=@();foreach($filter in 'sip-auth-fail','sip-auth-ip'){$base=Get-OpenWebHealthRuleName $Address $filter;$owned+=@(($base+'-tcp'),($base+'-udp'))}
 foreach($rule in @(Get-OpenWebHealthInboundBlocks)){
  if($rule.Name -cin $owned){continue}
  $app=@($rule|Get-NetFirewallApplicationFilter -ErrorAction Stop)
  if($app.Count -ne 1){throw 'An ambiguous firewall rule needs review.'}
  if($app[0].Program -ne 'Any' -and $app[0].Program -notlike '*\FreeSWITCH.exe'){continue}
  $port=@($rule|Get-NetFirewallPortFilter -ErrorAction Stop)
  if($port.Count -ne 1){throw 'An ambiguous firewall rule needs review.'}
  if([string]$port[0].Protocol -notin 'Any','TCP','UDP','6','17'){continue}
  $protocol=[string]$port[0].Protocol;$targets=if($protocol -in 'TCP','6'){$Listeners['TCP']}elseif($protocol -in 'UDP','17'){$Listeners['UDP']}else{@($Listeners['TCP'])+@($Listeners['UDP'])}
  if(!(Test-OpenWebHealthPortOverlap $port[0].LocalPort $targets)){continue}
  foreach($scope in @($rule|Get-NetFirewallAddressFilter -ErrorAction Stop|ForEach-Object {$_.RemoteAddress})){if(Test-OpenWebHealthSourceOverlap $Address ([string]$scope)){return $true}}
 };return $false
}
function Invoke-OpenWebHealthFirewall([string]$Operation,[string]$Address,[string]$Filter,[string]$TcpPorts,[string]$UdpPorts){
 $base=Get-OpenWebHealthRuleName $Address $Filter;$listeners=@{TCP=@(ConvertTo-OpenWebHealthPorts $TcpPorts);UDP=@(ConvertTo-OpenWebHealthPorts $UdpPorts)}
 if($Operation -cnotin 'State','Add','Remove'){throw 'An exact security operation is required.'}
 $profiles=@(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop)
 if($profiles.Count -ne 3 -or @($profiles|Where-Object {$_.Name -notin 'Domain','Private','Public' -or [string]$_.Enabled -ne 'True'}).Count -or @($profiles.Name|Sort-Object -Unique).Count -ne 3){throw 'Enable Windows Defender Firewall before using managed phone security.'}
 $state=Get-OpenWebHealthFirewallState $Address $Filter $listeners
 # Asking for the alternate filter also detects non-owned restrictions. The
 # shared recovery consumer refuses before touching its own auth-fail rule.
 if($Operation -eq 'State' -and $Filter -eq 'sip-auth-ip' -and (Test-OpenWebHealthForeignBlock $Address $listeners)){return 'present'}
 if($Operation -eq 'State' -or $state -eq 'unknown'){return $state}
 if($Operation -eq 'Add'){
  if($state -eq 'absent'){
   $created=@()
   try{foreach($protocol in 'TCP','UDP'){$name=$base+'-'+$protocol.ToLowerInvariant();$null=New-NetFirewallRule -PolicyStore PersistentStore -Name $name -DisplayName 'OpenWeb PBX phone sign-in security' -Group 'OpenWebPBX Phone Security' -Description ('OpenWebPBX owned '+$Filter+' v1 '+$name) -Direction Inbound -Action Block -Enabled True -Profile Any -RemoteAddress $Address -Protocol $protocol -LocalPort $listeners[$protocol] -ErrorAction Stop;$created+=$name}}
   catch{foreach($name in $created){$protocol=if($name.EndsWith('-tcp')){'TCP'}else{'UDP'};$row=@(Get-OpenWebHealthExactRule $name 'PersistentStore');if($row.Count -eq 1 -and (Test-OpenWebHealthOwnedRule $row[0] $name $Address $Filter $protocol $listeners[$protocol])){Remove-NetFirewallRule -PolicyStore PersistentStore -Name $name -ErrorAction Stop}};throw}
  }
  return Get-OpenWebHealthFirewallState $Address $Filter $listeners
 }
 if($Filter -ne 'sip-auth-fail' -or (Test-OpenWebHealthForeignBlock $Address $listeners) -or (Get-OpenWebHealthFirewallState $Address 'sip-auth-ip' $listeners) -ne 'absent'){return 'unknown'}
 if($state -eq 'present'){
  # Re-read and verify immediately before deleting exactly the local name.
  foreach($protocol in 'TCP','UDP'){
   $name=$base+'-'+$protocol.ToLowerInvariant();$current=@(Get-OpenWebHealthExactRule $name 'PersistentStore')
   if($current.Count -eq 0){continue}
   if($current.Count -ne 1 -or !(Test-OpenWebHealthOwnedRule $current[0] $name $Address $Filter $protocol $listeners[$protocol])){return 'unknown'}
   Remove-NetFirewallRule -PolicyStore PersistentStore -Name $name -ErrorAction Stop
  }
 }
 return Get-OpenWebHealthFirewallState $Address $Filter $listeners
}
