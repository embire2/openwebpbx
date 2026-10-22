#Requires -RunAsAdministrator
# SPDX-License-Identifier: AGPL-3.0-or-later
[CmdletBinding()]
param([string[]]$ListenAddress,[switch]$Recover,[IO.FileStream]$MaintenanceLock)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$root='C:\OpenWebPBX';$state=Join-Path $env:ProgramData 'OpenWebPBX'
. (Join-Path $PSScriptRoot 'PublicAccess.Common.ps1')
. (Join-Path $PSScriptRoot 'Restore-Gates.ps1')
. (Join-Path $PSScriptRoot 'File-Security.ps1')

# Every mutation follows a flushed, administrator-only recovery journal. Recovery
# uses actual old/desired identities, not a changed flag that can be lost on exit.
function Get-OpenWebStunHash([byte[]]$Bytes){
 $sha=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}
function Write-OpenWebStunBytes([string]$Path,[byte[]]$Bytes){
 $stream=[IO.FileStream]::new($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
 try{$stream.Write($Bytes,0,$Bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
}
function Get-OpenWebStunService([string]$Exe){
 $s=Get-CimInstance Win32_Service -Filter "Name='OpenWebPBX'"
 if(!$s -or $s.PathName.Trim('"') -ine $Exe -or $s.StartName -ine 'NT AUTHORITY\LocalService' -or $s.StartMode -notin 'Auto','Manual','Disabled'){throw 'The owned LOCAL SERVICE background service is required; custom choices were preserved.'}
 return [ordered]@{path=[string]$s.PathName;account=[string]$s.StartName;start_mode=[string]$s.StartMode;state=[string]$s.State;pid=[int]$s.ProcessId}
}
function Get-OpenWebStunRule([string[]]$Addresses,[string]$Exe){
 $name='OpenWebPBX-STUN-Binding-UDP';$marker='OpenWeb PBX owned STUN Binding service'
 $r=@()
 try{$r=@(Get-NetFirewallRule -Name $name -ErrorAction Stop)}catch{if(($_.FullyQualifiedErrorId -split ',')[0] -cnotin 'CmdletizationQuery_NotFound_InstanceID','CmdletizationQuery_NotFound_Name'){throw 'The STUN firewall rule cannot be inspected; no absent-rule assumption was made.'}}
 if(!$r.Count){return [ordered]@{exists=$false}}
 if($r.Count -ne 1){throw 'The named STUN firewall rule is ambiguous; it was preserved.'}
 $port=$r|Get-NetFirewallPortFilter;$app=$r|Get-NetFirewallApplicationFilter;$addr=$r|Get-NetFirewallAddressFilter
 if($r[0].Description -cne $marker -or $r[0].Group -cne $marker -or [string]$r[0].Direction -ne 'Inbound' -or [string]$r[0].Action -ne 'Allow' -or [string]$port.Protocol -notin 'UDP','17' -or [string]$port.LocalPort -ne '3478' -or [string]$port.RemotePort -ne 'Any' -or $app.Program -ine $Exe -or (@($addr.LocalAddress|Sort-Object) -join ',') -cne ($Addresses -join ',') -or [string]$addr.RemoteAddress -ne 'Any' -or [string]$r[0].Enabled -notin 'True','False'){throw 'The STUN firewall rule belongs to another configuration; it was preserved.'}
 return [ordered]@{exists=$true;enabled=([string]$r[0].Enabled -eq 'True');name=$name;description=$marker;group=$marker;direction='Inbound';action='Allow';protocol='UDP';local_port='3478';remote_port='Any';program=$Exe;local_addresses=@($Addresses);remote_addresses='Any';profile=[string]$r[0].Profile;edge=[string]$r[0].EdgeTraversalPolicy}
}
function Assert-OpenWebStunServiceIdentity($Before,$Current){
 foreach($name in 'path','account','start_mode'){if($Before.$name -cne $Current.$name){throw 'The background service changed during STUN setup; automatic recovery refused.'}}
}
function New-OpenWebStunFileAcl {
 $acl=[Security.AccessControl.FileSecurity]::new();$acl.SetAccessRuleProtection($true,$false);$acl.SetOwner([Security.Principal.SecurityIdentifier]'S-1-5-32-544');$acl.SetGroup([Security.Principal.SecurityIdentifier]'S-1-5-32-544')
 foreach($sid in 'S-1-5-18','S-1-5-32-544'){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]$sid,'FullControl','Allow'))}
 $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]'S-1-5-19','Read','Allow'));return $acl
}
function Set-OpenWebStunFileAcl([string]$Path){Set-OpenWebFileSddl -LiteralPath $Path -Sddl (New-OpenWebStunFileAcl).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)}
function Assert-OpenWebStunRecoveryAcl([string]$Path){
 $acl=Get-Acl -LiteralPath $Path
 if(!$acl.AreAccessRulesProtected -or $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cnotin 'S-1-5-32-544','S-1-5-18'){throw 'The STUN recovery directory is not owned and protected by administrators.'}
 $rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]));$seen=@()
 foreach($entry in $rules){if($entry.IsInherited -or $entry.IdentityReference.Value -cnotin 'S-1-5-32-544','S-1-5-18' -or $entry.AccessControlType -ne 'Allow' -or $entry.FileSystemRights -ne 'FullControl'){throw 'The STUN recovery directory has foreign access; it was preserved.'};$seen+=@($entry.IdentityReference.Value)}
 if(($seen|Sort-Object -Unique) -join ',' -cne 'S-1-5-18,S-1-5-32-544'){throw 'The STUN recovery directory needs both administrator and SYSTEM access.'}
}
function Assert-OpenWebStunRecoveryFileAcl([string]$Path){
 $acl=Get-Acl -LiteralPath $Path
 if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cnotin 'S-1-5-32-544','S-1-5-18'){throw 'A STUN recovery file has a foreign owner.'}
 $seen=@();foreach($entry in @($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))){if($entry.IdentityReference.Value -cnotin 'S-1-5-32-544','S-1-5-18' -or $entry.AccessControlType -ne 'Allow' -or $entry.FileSystemRights -ne 'FullControl'){throw 'A STUN recovery file has foreign access; recovery refused.'};$seen+=@($entry.IdentityReference.Value)}
 if(($seen|Sort-Object -Unique) -join ',' -cne 'S-1-5-18,S-1-5-32-544'){throw 'A STUN recovery file needs administrator and SYSTEM access.'}
}
function Move-OpenWebStunFile([string]$Temporary,[string]$Path){
 if(-not ('OpenWebPbx.StunAtomicFile' -as [type])){
  Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace OpenWebPbx {
 public static class StunAtomicFile {
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, ExactSpelling=true, SetLastError=true)]
  [return:MarshalAs(UnmanagedType.Bool)] static extern bool MoveFileExW(string source,string target,uint flags);
  public static void Replace(string source,string target) {
   if(!MoveFileExW(source,target,9))throw new Win32Exception(Marshal.GetLastWin32Error());
  }
 }
}
'@
 }
 [OpenWebPbx.StunAtomicFile]::Replace($Temporary,$Path)
}
function Set-OpenWebStunFile([string]$Path,[byte[]]$Bytes,[string]$Sddl,[string]$Directory){
 $null=Assert-OpenWebOrdinaryPath $Directory $true;Assert-OpenWebStunRecoveryAcl $Directory
 if(Test-Path -LiteralPath $Path){$null=Assert-OpenWebOrdinaryPath $Path}
 $temporary=$Path+'.'+[Guid]::NewGuid().ToString('N')+'.new'
 try{
  Write-OpenWebStunBytes $temporary $Bytes
  Set-OpenWebStunFileAcl $temporary
  # File.Replace merges source owner/group with destination DACL on Windows.
  # A same-directory native replacement preserves the complete source security
  # descriptor; the flushed private backup remains available after a crash.
  Move-OpenWebStunFile $temporary $Path
  if($Sddl){Set-OpenWebFileSddl -LiteralPath $Path -Sddl $Sddl}else{Set-OpenWebStunFileAcl $Path}
 }finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
}
function Read-OpenWebStunJournal([string]$Directory,[string]$Exe){
 $null=Assert-OpenWebOrdinaryPath $Directory $true
 Assert-OpenWebStunRecoveryAcl $Directory
 Assert-OpenWebStunRecoveryFileAcl (Join-Path $Directory 'journal.json')
 $j=Read-OpenWebPublicJson (Join-Path $Directory 'journal.json')
 if($j.schema -ne 1 -or $j.kind -cne 'openwebpbx-stun-enable' -or $j.transaction -cnotmatch '^[a-f0-9]{32}$' -or [IO.Path]::GetFileName($Directory) -cne $j.transaction -or $j.computer -cne [Environment]::MachineName -or $j.exe -cne $Exe -or $j.state -cnotin 'prepared','applying','committed','recovering','recovered','recovery_required' -or $j.config_before_exists -isnot [bool] -or $j.desired_sha256 -cnotmatch '^[a-f0-9]{64}$' -or $j.service_before.state -cne 'Running' -or $j.service_before.start_mode -cnotin 'Auto','Manual'){throw 'The machine-bound STUN recovery journal requires administrator review.'}
 if($j.rule_before.exists -isnot [bool] -or ($j.rule_before.exists -and $j.rule_before.enabled -isnot [bool])){throw 'The previous STUN firewall choice is invalid.'}
 $canonical=@();foreach($value in @($j.addresses)){if($value -isnot [string]){throw 'The STUN recovery addresses are invalid.'};$ip=$null;if(![Net.IPAddress]::TryParse($value,[ref]$ip) -or $ip.ToString() -cne $value -or [Net.IPAddress]::IsLoopback($ip) -or $ip.IsIPv6Multicast -or $ip.IsIPv4MappedToIPv6 -or $value -in '0.0.0.0','::' -or $value -match '^(169\.254\.|fe80:)'){throw 'The STUN recovery addresses are not canonical unicast addresses.'};$canonical+=@($value)}
 if(!$canonical.Count -or $canonical.Count -gt 16 -or (@($canonical|Sort-Object -Unique) -join ',') -cne ($canonical -join ',') -or !$j.desired_sddl){throw 'The STUN recovery address or permission inventory is invalid.'}
 $desired=Join-Path $Directory 'desired.bin';$null=Assert-OpenWebOrdinaryPath $desired
 Assert-OpenWebStunRecoveryFileAcl $desired
 if((Get-Item -LiteralPath $desired).Length -gt 2048 -or (Get-OpenWebStunHash ([IO.File]::ReadAllBytes($desired))) -cne $j.desired_sha256){throw 'The durable desired STUN configuration differs from its journal.'}
 if($j.config_before_exists){
  $prior=Join-Path $Directory 'previous.bin';$null=Assert-OpenWebOrdinaryPath $prior
  Assert-OpenWebStunRecoveryFileAcl $prior
  if($j.config_before_sha256 -cnotmatch '^[a-f0-9]{64}$' -or !$j.config_before_sddl -or (Get-Item -LiteralPath $prior).Length -gt 2048 -or (Get-OpenWebStunHash ([IO.File]::ReadAllBytes($prior))) -cne $j.config_before_sha256){throw 'The durable previous STUN configuration differs from its journal.'}
 }
 return $j
}
function Restart-OpenWebStunBackground($Before,[string]$Exe){
 $current=Get-OpenWebStunService $Exe;Assert-OpenWebStunServiceIdentity $Before $current
 if($current.state -eq 'Running'){Restart-Service -Name OpenWebPBX -ErrorAction Stop}
 elseif($current.state -eq 'Stopped'){Start-Service -Name OpenWebPBX -ErrorAction Stop}
 else{throw 'Wait for the owned background service to settle before STUN recovery.'}
}
function Undo-OpenWebStunTransaction([string]$Directory,[string]$StateRoot,[string]$Exe){
 $j=Read-OpenWebStunJournal $Directory $Exe;$path=Join-Path $StateRoot 'stun.json'
 $current=Get-OpenWebStunService $Exe;Assert-OpenWebStunServiceIdentity $j.service_before $current
 $rule=Get-OpenWebStunRule @($j.addresses) $Exe
 if($j.rule_before.exists -and !$rule.exists){throw 'The previous STUN firewall rule is missing; automatic recovery refused.'}
 if($j.rule_before.exists){foreach($name in 'profile','edge'){if($j.rule_before.$name -cne $rule.$name){throw 'The STUN firewall policy changed; automatic recovery refused.'}}}
 elseif($rule.exists -and ($rule.profile -cne 'Any' -or $rule.edge -cne 'Block')){throw 'The newly created STUN firewall policy changed; automatic recovery refused.'}
 if(Test-Path -LiteralPath $path){$null=Assert-OpenWebOrdinaryPath $path;$hash=Get-OpenWebStunHash ([IO.File]::ReadAllBytes($path));if($hash -cne $j.desired_sha256 -and (!$j.config_before_exists -or $hash -cne $j.config_before_sha256)){throw 'The STUN configuration changed outside this transaction; it was preserved.'};$sddl=(Get-Acl -LiteralPath $path).Sddl;if($sddl -cne $j.desired_sddl -and (!$j.config_before_exists -or $sddl -cne $j.config_before_sddl)){throw 'The STUN file permissions changed outside this transaction; they were preserved.'}}
 $j.state='recovering';Write-OpenWebPublicJson (Join-Path $Directory 'journal.json') $j
 if($j.config_before_exists){Set-OpenWebStunFile $path ([IO.File]::ReadAllBytes((Join-Path $Directory 'previous.bin'))) $j.config_before_sddl $Directory}
 elseif(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force}
 if($j.rule_before.exists){if($j.rule_before.enabled){Enable-NetFirewallRule -Name 'OpenWebPBX-STUN-Binding-UDP'|Out-Null}else{Disable-NetFirewallRule -Name 'OpenWebPBX-STUN-Binding-UDP'|Out-Null}}
 elseif($rule.exists){Remove-NetFirewallRule -Name 'OpenWebPBX-STUN-Binding-UDP' -ErrorAction Stop}
 Restart-OpenWebStunBackground $j.service_before $Exe
 $restored=Get-OpenWebStunService $Exe;Assert-OpenWebStunServiceIdentity $j.service_before $restored
 if($restored.state -cne 'Running'){throw 'The previous background service has not resumed.'}
 if($j.config_before_exists){if((Get-OpenWebStunHash ([IO.File]::ReadAllBytes($path))) -cne $j.config_before_sha256 -or (Get-Acl -LiteralPath $path).Sddl -cne $j.config_before_sddl){throw 'The original STUN bytes or permissions have not recovered exactly.'}}elseif(Test-Path -LiteralPath $path){throw 'The original absent STUN configuration was not restored.'}
 $restoredRule=Get-OpenWebStunRule @($j.addresses) $Exe
 if($restoredRule.exists -ne $j.rule_before.exists -or ($restoredRule.exists -and $restoredRule.enabled -ne $j.rule_before.enabled)){throw 'The previous STUN firewall choice has not recovered.'}
 $j.state='recovered';Write-OpenWebPublicJson (Join-Path $Directory 'journal.json') $j
 return $j
}
function Resolve-OpenWebStunPending([string]$Base,[string]$StateRoot,[string]$Exe){
 $active=Join-Path $Base 'active.json'
 if(!(Test-Path -LiteralPath $active)){return}
 Assert-OpenWebStunRecoveryAcl $Base
 Assert-OpenWebStunRecoveryFileAcl $active
 $pointer=Read-OpenWebPublicJson $active
 if($pointer.schema -ne 1 -or $pointer.transaction -cnotmatch '^[a-f0-9]{32}$' -or $pointer.computer -cne [Environment]::MachineName){throw 'The pending STUN setup belongs to another machine or invalid transaction.'}
 $directory=Join-Path $Base $pointer.transaction;$j=Read-OpenWebStunJournal $directory $Exe
 if($j.state -cnotin 'committed','recovered'){$j=Undo-OpenWebStunTransaction $directory $StateRoot $Exe}
 Remove-Item -LiteralPath $active -Force
}

$lock=$MaintenanceLock;$owned=$null -eq $lock
if($owned){$lock=[IO.File]::Open((Join-Path $state 'upgrade.lock'),'OpenOrCreate','ReadWrite','None')}
try{
 if(!$lock.CanRead -or !$lock.CanWrite -or [IO.Path]::GetFullPath($lock.Name) -ine (Join-Path $state 'upgrade.lock')){throw 'The owned Windows maintenance lock is required.'}
 Assert-OpenWebUpgradeAllowed -StateRoot $state
 $exe=Join-Path $root 'server\OpenWebPbx.Server.exe';$null=Assert-OpenWebOrdinaryPath $exe
 $base=Join-Path $state 'stun-setup'
 if(Test-Path -LiteralPath $base){$null=Assert-OpenWebOrdinaryPath $base $true;Assert-OpenWebStunRecoveryAcl $base;Resolve-OpenWebStunPending $base $state $exe}
 if($Recover){Write-Host 'Pending STUN setup recovery is complete. Existing PBX calling settings were preserved.';return}
 $installed=Read-OpenWebPublicJson (Join-Path $state 'installation.json')
 if(!$installed.Completed -or [version]$installed.Version -lt [version]'1.0.20'){throw 'Install the Windows release with native STUN before enabling it.'}
 $addresses=@($ListenAddress|ForEach-Object {([Net.IPAddress]::Parse($_)).ToString()}|Sort-Object -Unique)
 if(!$addresses.Count -or $addresses.Count -gt 16 -or $addresses.Count -ne $ListenAddress.Count){throw 'Choose unique local STUN listening addresses.'}
 $local=@(Get-NetIPAddress|Where-Object {$_.AddressState -eq 'Preferred'}|Select-Object -ExpandProperty IPAddress)
 foreach($value in $addresses){$ip=[Net.IPAddress]::Parse($value);if($value -notin $local -or [Net.IPAddress]::IsLoopback($ip) -or $ip.IsIPv6Multicast -or $ip.IsIPv4MappedToIPv6 -or $value -in '0.0.0.0','::' -or $value -match '^(169\.254\.|fe80:)'){throw 'STUN requires an installed non-loopback unicast address.'}}
 $service=Get-OpenWebStunService $exe
 if($service.state -cne 'Running' -or $service.start_mode -ceq 'Disabled'){throw 'Start the background PBX service in the manager before enabling STUN. Its stopped or disabled choice was preserved.'}
 $health=Invoke-RestMethod 'http://127.0.0.1:8087/health' -TimeoutSec 5
 if(!$health.PSObject.Properties['stun']){throw 'The installed background service does not contain native STUN.'}
 $rule=Get-OpenWebStunRule $addresses $exe
 $endpoints=@()
 try{$endpoints=@(Get-NetUDPEndpoint -LocalPort 3478 -ErrorAction Stop)}catch{if(($_.FullyQualifiedErrorId -split ',')[0] -cne 'CmdletizationQuery_NotFound_LocalPort'){throw 'STUN listener ownership cannot be inspected; setup was refused.'}}
 foreach($endpoint in $endpoints){
  if($endpoint.LocalAddress -in @('0.0.0.0','::')+$addresses -and $endpoint.OwningProcess -ne $service.pid){throw 'STUN port3478 already belongs to another process.'}
 }
 $path=Join-Path $state 'stun.json';$had=Test-Path -LiteralPath $path;$before=$null;$sddl=''
 if($had){$null=Assert-OpenWebOrdinaryPath $path;if((Get-Item -LiteralPath $path).Length -gt 2048){throw 'The existing STUN configuration needs review.'};$before=[IO.File]::ReadAllBytes($path);$sddl=(Get-Acl -LiteralPath $path).Sddl}
 $desired=[Text.UTF8Encoding]::new($false).GetBytes(([ordered]@{Stun=[ordered]@{Enabled=$true;ListenAddresses=$addresses}}|ConvertTo-Json -Depth 4))
 $desiredSddl=(New-OpenWebStunFileAcl).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)
 if($had -and (Get-OpenWebStunHash $before) -ceq (Get-OpenWebStunHash $desired) -and $sddl -ceq $desiredSddl -and $rule.exists -and $rule.enabled -and $health.stun -ceq 'Running'){
  Write-Host 'STUN Binding is already ready; its configuration, firewall rule and background service were unchanged.';return
 }
 if(!(Test-Path -LiteralPath $base)){New-Item -ItemType Directory -Path $base|Out-Null}
 Set-OpenWebPublicPrivateAcl $base
 $transaction=[Guid]::NewGuid().ToString('N');$directory=Join-Path $base $transaction;New-Item -ItemType Directory -Path $directory|Out-Null;Set-OpenWebPublicPrivateAcl $directory
 if($had){Write-OpenWebStunBytes (Join-Path $directory 'previous.bin') $before}
 Write-OpenWebStunBytes (Join-Path $directory 'desired.bin') $desired
 $j=[pscustomobject][ordered]@{schema=1;kind='openwebpbx-stun-enable';computer=[Environment]::MachineName;transaction=$transaction;exe=$exe;state='prepared';addresses=$addresses;config_before_exists=[bool]$had;config_before_sha256=$(if($had){Get-OpenWebStunHash $before}else{''});config_before_sddl=$sddl;desired_sha256=(Get-OpenWebStunHash $desired);desired_sddl=$desiredSddl;rule_before=$rule;service_before=$service}
 Write-OpenWebPublicJson (Join-Path $directory 'journal.json') $j
 Write-OpenWebPublicJson (Join-Path $base 'active.json') @{schema=1;transaction=$transaction;computer=[Environment]::MachineName}
 try{
  $j.state='applying';Write-OpenWebPublicJson (Join-Path $directory 'journal.json') $j
  Set-OpenWebStunFile $path $desired '' $directory
  if(!$rule.exists){$marker='OpenWeb PBX owned STUN Binding service';New-NetFirewallRule -Name 'OpenWebPBX-STUN-Binding-UDP' -DisplayName 'OpenWeb PBX STUN Binding UDP3478' -Description $marker -Group $marker -Direction Inbound -Action Allow -Protocol UDP -LocalPort 3478 -LocalAddress $addresses -RemoteAddress Any -Program $exe -Profile Any|Out-Null}else{Enable-NetFirewallRule -Name 'OpenWebPBX-STUN-Binding-UDP'|Out-Null}
  Restart-OpenWebStunBackground $service $exe
  $ready=$false
  for($i=0;$i -lt 30;$i++){try{$health=Invoke-RestMethod 'http://127.0.0.1:8087/health' -TimeoutSec 2;if($health.stun -ceq 'Running'){$ready=$true;break}}catch{};Start-Sleep -Seconds 1}
  if(!$ready){throw 'The native STUN listener did not become ready.'}
  if((Get-OpenWebStunHash ([IO.File]::ReadAllBytes($path))) -cne $j.desired_sha256 -or !(Get-OpenWebStunRule $addresses $exe).enabled){throw 'The desired STUN configuration or owned firewall rule changed during activation.'}
  $j.state='committed';Write-OpenWebPublicJson (Join-Path $directory 'journal.json') $j
  Remove-Item -LiteralPath (Join-Path $base 'active.json') -Force
  Write-Host 'STUN Binding is ready on the selected addresses, UDP3478. TURN relay is not enabled.'
 }catch{
  $failure=$_
  if($j.state -cne 'committed'){
   try{$null=Undo-OpenWebStunTransaction $directory $state $exe;Remove-Item -LiteralPath (Join-Path $base 'active.json') -Force}
   catch{
    $recoveryFailure=$_
    try{$j.state='recovery_required';Write-OpenWebPublicJson (Join-Path $directory 'journal.json') $j;Write-OpenWebPublicJson (Join-Path $directory ('recovery-error-'+[guid]::NewGuid().ToString('N')+'.json')) @{error_type=$recoveryFailure.Exception.GetType().Name;source_line=$recoveryFailure.InvocationInfo.ScriptLineNumber;message=$recoveryFailure.Exception.Message}}catch{}
    throw 'STUN setup needs recovery. Its protected previous bytes and permissions remain in ProgramData\OpenWebPBX\stun-setup. Run Enable-Stun.ps1 -Recover; FreeSWITCH was not restarted.'
   }
  }
  throw $failure
 }
}finally{if($owned -and $lock){$lock.Dispose()}}
