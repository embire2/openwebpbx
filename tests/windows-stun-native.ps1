# Real installed background service, native firewall, UDP and durable recovery.
# No call-engine restart, customer call or public internet connection is made.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PackageRoot,[Parameter(Mandatory)][string]$ReportPath,[string]$InputPath,[switch]$DisposableHostedRunner)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if(!$DisposableHostedRunner -or $env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows' -or $env:GITHUB_REPOSITORY -cne 'embire2/openwebpbx' -or $PSVersionTable.PSEdition -cne 'Desktop'){throw 'An explicitly disposable native Windows runner is required.'}
$root='C:\OpenWebPBX';$state=Join-Path $env:ProgramData 'OpenWebPBX';$exe=Join-Path $root 'server\OpenWebPbx.Server.exe';$helper=Join-Path $root 'tools\Enable-Stun.ps1';$path=Join-Path $state 'stun.json';$base=Join-Path $state 'stun-setup'
. (Join-Path $root 'tools\PublicAccess.Common.ps1');. (Join-Path $root 'tools\File-Security.ps1')
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($helper,[ref]$tokens,[ref]$errors);if($errors.Count){throw 'The installed STUN helper did not parse.'}
foreach($f in $ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){Invoke-Expression $f.Extent.Text}
$installed=Read-OpenWebPublicJson (Join-Path $state 'installation.json');if(!$installed.Completed -or !$installed.RestoreServer){throw 'A completed empty restore-server factory is required.'}
$manifest=Get-Content (Join-Path $PackageRoot 'release-manifest.json') -Raw|ConvertFrom-Json
if((Get-FileHash $helper).Hash.ToLowerInvariant() -cne $manifest.files.'Enable-Stun.ps1'){throw 'The installed STUN helper differs from the complete candidate.'}
$phoneTlsHelper=Join-Path $root 'tools\Enable-PhoneTLS.ps1'
if((Get-FileHash $phoneTlsHelper).Hash.ToLowerInvariant() -cne $manifest.files.'Enable-PhoneTLS.ps1'){throw 'The installed maintenance-lock helper differs from the complete candidate.'}
$lockTokens=$null;$lockErrors=$null;$lockAst=[Management.Automation.Language.Parser]::ParseFile($phoneTlsHelper,[ref]$lockTokens,[ref]$lockErrors)
$lockFunctions=@($lockAst.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Open-OpenWebPhoneTlsMaintenance'},$true))
if($lockErrors.Count -or $lockFunctions.Count -ne 1){throw 'The pinned bounded maintenance function is unavailable.'}
Invoke-Expression $lockFunctions[0].Extent.Text
. (Join-Path $PSScriptRoot 'windows-upgrade-lock-observer.ps1')
$work=Join-Path $state ('stun-native-qualification\'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $work -Force|Out-Null;Set-OpenWebPublicPrivateAcl $work
$facts=[ordered]@{schema=1;state='running';case='native_windows_stun_setup_udp_recovery';checks=0;actual_native=$true;modern_binding=$false;legacy_binding=$false;turn_refused=$false;idempotent=$false;late_rule_failure_recovered=$false;cleanup_exact=$false;call_engine_preserved=$false;stun_default_restored=$false;firewall_policy_exact=$false;external_firewall_reachability='unqualified';phase='preflight'}
$script:checks=0;$lock=$null;$lockClock=$null;$started=$false;$beforeService=$null;$beforeEngine=$null;$known=[Collections.Generic.List[string]]::new();$phase='preflight';$primary=$null
function Check([bool]$Value){if(!$Value){throw ('Native STUN assertion failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
function WaitDefaultStun {
 $ready=$false
 for($i=0;$i -lt 20;$i++){try{if((Invoke-RestMethod 'http://127.0.0.1:8087/health' -TimeoutSec 2).stun -ceq 'Disabled'){$ready=$true;break}}catch{};Start-Sleep -Milliseconds 250}
 Check $ready
 $ownedPid=(Get-OpenWebStunService $exe).pid;$endpoints=@()
 try{$endpoints=@(Get-NetUDPEndpoint -LocalPort 3478 -ErrorAction Stop)}catch{if(($_.FullyQualifiedErrorId -split ',')[0] -cne 'CmdletizationQuery_NotFound_LocalPort'){throw}}
 Check (@($endpoints|Where-Object {$_.OwningProcess -eq $ownedPid}).Count -eq 0)
}
function InvokeHelper {$log=Join-Path $work ('enable-'+[guid]::NewGuid().ToString('N')+'.private.log');& $helper -ListenAddress @($address) -MaintenanceLock $lock *> $log}
function Request([bool]$Modern){$b=New-Object byte[] 20;$b[1]=1;for($i=4;$i -lt 20;$i++){$b[$i]=[byte]($i*7)};if($Modern){$b[4]=0x21;$b[5]=0x12;$b[6]=0xa4;$b[7]=0x42};return ,$b}
function Probe([byte[]]$Request,[bool]$Modern){
 $client=[Net.Sockets.UdpClient]::new([Net.IPEndPoint]::new([Net.IPAddress]::Parse($address),0));$client.Client.ReceiveTimeout=2000
 try{$destination=[Net.IPEndPoint]::new([Net.IPAddress]::Parse($address),3478);$null=$client.Send($Request,$Request.Length,$destination);$peer=[Net.IPEndPoint]::new([Net.IPAddress]::Any,0);$reply=$client.Receive([ref]$peer)
 Check ($peer.Equals($destination) -and $reply.Length -eq $(if($Modern){44}else{32}) -and $reply[0] -eq 1 -and $reply[1] -eq 1)
 Check ([Convert]::ToBase64String($reply,4,16) -ceq [Convert]::ToBase64String($Request,4,16))
 $port=([int]$reply[26] -shl 8) -bor $reply[27];Check ($port -eq $client.Client.LocalEndPoint.Port)
 Check ([Net.IPAddress]::new([byte[]]$reply[28..31]).ToString() -ceq $address)
 if($Modern){Check (((([int]$reply[38] -shl 8) -bor $reply[39]) -bxor 0x2112) -eq $port);$bytes=New-Object byte[] 4;for($i=0;$i -lt 4;$i++){$bytes[$i]=$reply[40+$i] -bxor $Request[4+$i]};Check ([Net.IPAddress]::new($bytes).ToString() -ceq $address)}
 }finally{$client.Dispose()}
}
function FirewallPolicy {
 $result=[ordered]@{}
 foreach($command in 'Get-NetFirewallRule','Get-NetFirewallAddressFilter','Get-NetFirewallPortFilter','Get-NetFirewallApplicationFilter','Get-NetFirewallServiceFilter','Get-NetFirewallInterfaceFilter','Get-NetFirewallInterfaceTypeFilter','Get-NetFirewallSecurityFilter','Get-NetFirewallProfile'){
  $rows=@(& $command -PolicyStore PersistentStore -ErrorAction Stop|ForEach-Object {$item=[ordered]@{};foreach($property in $_.CimInstanceProperties|Sort-Object Name){$item[$property.Name]=$property.Value};[pscustomobject]$item}|Sort-Object InstanceID,Name)
  $result[$command]=$rows
 }
 return ($result|ConvertTo-Json -Depth 16 -Compress)
}
function RestoreTransactions {
 foreach($directory in @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue)){
  if($directory.Name -cnotmatch '^[a-f0-9]{32}$'){throw 'A foreign STUN recovery directory appeared.'}
  $j=Read-OpenWebStunJournal $directory.FullName $exe
  if($j.state -cne 'recovered'){$null=Undo-OpenWebStunTransaction $directory.FullName $state $exe}
  if(!$known.Contains($directory.Name)){$known.Add($directory.Name)}
 }
}
try{
 Check (!(Test-Path $path) -and !(Test-Path $base))
 WaitDefaultStun
 $beforeService=Get-OpenWebStunService $exe;$beforeEngine=Get-CimInstance Win32_Service -Filter "Name='FreeSWITCH'";Check ($beforeService.state -ceq 'Running' -and $beforeEngine.State -ceq 'Running')
 $address=@(Get-NetIPAddress -AddressFamily IPv4|Where-Object {$_.AddressState -eq 'Preferred' -and $_.IPAddress -notmatch '^(127\.|169\.254\.|0\.)'}|Select-Object -ExpandProperty IPAddress|Sort-Object)[0];Check (![string]::IsNullOrEmpty($address))
 Check (!(Get-OpenWebStunRule @($address) $exe).exists)
 $facts.maintenance_lock_probe=Read-OpenWebLockProbe (Join-Path $state 'upgrade.lock')
 $lockClock=[Diagnostics.Stopwatch]::StartNew()
 $lock=Open-OpenWebPhoneTlsMaintenance -Path (Join-Path $state 'upgrade.lock') -WaitMilliseconds 30000
 $facts.maintenance_lock_acquired=$true;$facts.maintenance_lock_elapsed_ms=[long]$lockClock.ElapsedMilliseconds
 $policyBefore=FirewallPolicy
 $rulesBefore=@(Get-NetFirewallRule -PolicyStore ActiveStore -ErrorAction Stop|Sort-Object Name|Select-Object Name,Description,Group,Enabled,Direction,Action,Profile|ConvertTo-Json -Depth 4 -Compress)
 $started=$true
 $phase='activation';InvokeHelper;Check ((Invoke-RestMethod 'http://127.0.0.1:8087/health' -TimeoutSec 3).stun -ceq 'Running')
 $transactions=@(Get-ChildItem $base -Directory);Check ($transactions.Count -eq 1);$known.Add($transactions[0].Name)
 $pidBefore=(Get-OpenWebStunService $exe).pid;$configHash=(Get-FileHash $path).Hash;$configAcl=(Get-Acl $path).Sddl
 $phase='modern_udp';Probe (Request $true) $true;$facts.modern_binding=$true
 $phase='legacy_udp';Probe (Request $false) $false;$facts.legacy_binding=$true
 $phase='turn_refusal';$client=[Net.Sockets.UdpClient]::new([Net.IPEndPoint]::new([Net.IPAddress]::Parse($address),0));$client.Client.ReceiveTimeout=400
 try{$turn=Request $true;$turn[1]=3;$null=$client.Send($turn,$turn.Length,[Net.IPEndPoint]::new([Net.IPAddress]::Parse($address),3478));$peer=[Net.IPEndPoint]::new([Net.IPAddress]::Any,0);$refused=$false;try{$null=$client.Receive([ref]$peer)}catch [Net.Sockets.SocketException]{$refused=$_.Exception.SocketErrorCode -eq 'TimedOut'};Check $refused;$facts.turn_refused=$true}finally{$client.Dispose()}
 $phase='idempotence';InvokeHelper;Check ((Get-OpenWebStunService $exe).pid -eq $pidBefore -and (Get-FileHash $path).Hash -ceq $configHash -and (Get-Acl $path).Sddl -ceq $configAcl -and @(Get-ChildItem $base -Directory).Count -eq 1);$facts.idempotent=$true
 $phase='rollback';$null=Undo-OpenWebStunTransaction $transactions[0].FullName $state $exe;Check (!(Test-Path $path) -and !(Get-OpenWebStunRule @($address) $exe).exists)
 $phase='late_rule_failure'
 function New-NetFirewallRule {param($Name,$DisplayName,$Description,$Group,$Direction,$Action,$Protocol,$LocalPort,$LocalAddress,$RemoteAddress,$Program,$Profile)
  NetSecurity\New-NetFirewallRule @PSBoundParameters|Out-Null
  throw 'Deliberate owned qualification failure after actual STUN rule creation.'
 }
 $failed=$false;try{InvokeHelper}catch{$failed=$true}finally{Remove-Item Function:\New-NetFirewallRule}
 Check ($failed -and !(Test-Path $path) -and !(Test-Path (Join-Path $base 'active.json')) -and !(Get-OpenWebStunRule @($address) $exe).exists);$facts.late_rule_failure_recovered=$true
 RestoreTransactions
 $facts.state='passed'
}catch{
 $primary=$_;$facts.state='failed';$facts.error_type=$_.Exception.GetType().Name;$facts.source_line=$_.InvocationInfo.ScriptLineNumber
 if(!$lock -and $lockClock){
  $native=$_.Exception;while($native.InnerException){$native=$native.InnerException}
  $facts.maintenance_lock_acquired=$false;$facts.maintenance_lock_elapsed_ms=[long]$lockClock.ElapsedMilliseconds
  $facts.maintenance_lock_error_type=$native.GetType().Name
  $facts.maintenance_lock_hresult=('{0:x8}' -f ([long]$native.HResult -band 4294967295L))
  $facts.maintenance_lock_busy=[bool]$_.Exception.Data.Contains('OpenWebPhoneTLSBusy')
 }
}
finally{
 try{
  if($started){
   RestoreTransactions
   Check (!(Test-Path $path) -and !(Test-Path (Join-Path $base 'active.json')) -and !(Get-OpenWebStunRule @($address) $exe).exists)
   WaitDefaultStun;$facts.stun_default_restored=$true
   $afterService=Get-OpenWebStunService $exe;Assert-OpenWebStunServiceIdentity $beforeService $afterService;Check ($afterService.state -ceq 'Running')
   $afterEngine=Get-CimInstance Win32_Service -Filter "Name='FreeSWITCH'";Check ($afterEngine.State -ceq 'Running' -and $afterEngine.ProcessId -eq $beforeEngine.ProcessId);$facts.call_engine_preserved=$true
   Check ((FirewallPolicy) -ceq $policyBefore);$facts.firewall_policy_exact=$true
   Check ((@(Get-NetFirewallRule -PolicyStore ActiveStore -ErrorAction Stop|Sort-Object Name|Select-Object Name,Description,Group,Enabled,Direction,Action,Profile|ConvertTo-Json -Depth 4 -Compress) -join '') -ceq ($rulesBefore -join ''))
   foreach($name in $known){$dir=Join-Path $base $name;Check ((Read-OpenWebStunJournal $dir $exe).state -ceq 'recovered');Copy-Item -LiteralPath $dir -Destination (Join-Path $work $name) -Recurse;foreach($entry in Get-ChildItem -LiteralPath $dir -Recurse -Force){$null=Assert-OpenWebOrdinaryPath $entry.FullName $entry.PSIsContainer};Remove-Item -LiteralPath $dir -Recurse -Force}
   Check (@(Get-ChildItem -LiteralPath $base -Force).Count -eq 0);Remove-Item -LiteralPath $base;Check (!(Test-Path $base));$facts.cleanup_exact=$true
  }
 }catch{$facts.cleanup_exact=$false;$facts.state='failed';$facts.cleanup_error_type=$_.Exception.GetType().Name;$facts.cleanup_source_line=$_.InvocationInfo.ScriptLineNumber}
 if($lock){$lock.Dispose()}
 $facts.phase=$phase;$facts.checks=$script:checks;[IO.File]::WriteAllText($ReportPath,($facts|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
}
if($facts.state -cne 'passed' -or !$facts.cleanup_exact){throw 'Native Windows STUN setup/UDP/recovery acceptance did not pass; private evidence retained.'}
