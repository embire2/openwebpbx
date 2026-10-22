# Exact production helper under two explicitly substituted owned roots. Real
# Windows files/ACL/raw restore and killed processes; firewall/service are doubles.
[CmdletBinding()]
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent),[string]$OutputDirectory)
$ErrorActionPreference='Stop'
if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or $PSVersionTable.PSEdition -ne 'Desktop'){throw 'Use native administrator Windows PowerShell for STUN transaction controls.'}
if(!$OutputDirectory){$OutputDirectory=Join-Path $env:TEMP ('openweb-stun-transactions-'+[guid]::NewGuid().ToString('N'))}
if(Test-Path -LiteralPath $OutputDirectory){throw 'Use a new owned output directory.'}
New-Item -ItemType Directory $OutputDirectory|Out-Null
$script:checks=0
function Check([bool]$Value){if(!$Value){throw ('STUN transaction assertion failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
$helper=Join-Path $SourceRoot 'packaging\windows\Enable-Stun.ps1';$original=[IO.File]::ReadAllText($helper)
$assignment='$root=''C:\OpenWebPBX'';$state=Join-Path $env:ProgramData ''OpenWebPBX'''
Check ([regex]::Matches($original,[regex]::Escape($assignment)).Count -eq 1)
$worker=Join-Path $OutputDirectory 'worker.ps1'
[IO.File]::WriteAllText($worker,@'
param([string]$CaseRoot,[string]$Mode)
$ErrorActionPreference='Stop'
$modelPath=Join-Path $CaseRoot 'model.json';$statePath=Join-Path $CaseRoot 'state';$exePath=Join-Path $CaseRoot 'root\server\OpenWebPbx.Server.exe'
function Model {Get-Content -LiteralPath $modelPath -Raw|ConvertFrom-Json}
function Save($m){[IO.File]::WriteAllText($modelPath,($m|ConvertTo-Json -Depth 8))}
function Get-CimInstance {param($ClassName,$Filter) $m=Model;[pscustomobject]@{PathName=$exePath;StartName='NT AUTHORITY\LocalService';StartMode=$m.start;State=$m.service;ProcessId=123}}
function Get-NetIPAddress {[pscustomobject]@{AddressState='Preferred';IPAddress='10.42.0.5'}}
function Get-NetUDPEndpoint {param($LocalPort,$ErrorAction) if($Mode -eq 'udp_query_denied'){throw [UnauthorizedAccessException]::new('Injected endpoint query denial')};return}
function Get-NetFirewallRule {param($Name,$ErrorAction) if($Mode -eq 'rule_query_denied'){throw [UnauthorizedAccessException]::new('Injected firewall query denial')};$m=Model;if($m.rule){[pscustomobject]@{Enabled=$m.enabled;Description=$m.description;Group='OpenWeb PBX owned STUN Binding service';Direction='Inbound';Action='Allow';Profile='Any';EdgeTraversalPolicy='Block'}}else{ $exception=[Exception]::new('Absent fictional rule');$record=[Management.Automation.ErrorRecord]::new($exception,'CmdletizationQuery_NotFound_Name',[Management.Automation.ErrorCategory]::ObjectNotFound,$Name);throw $record}}
function Get-NetFirewallPortFilter {process{[pscustomobject]@{Protocol='UDP';LocalPort='3478';RemotePort='Any'}}}
function Get-NetFirewallApplicationFilter {process{[pscustomobject]@{Program=$exePath}}}
function Get-NetFirewallAddressFilter {process{[pscustomobject]@{LocalAddress=@('10.42.0.5');RemoteAddress='Any'}}}
function New-NetFirewallRule {param($Name,$DisplayName,$Description,$Group,$Direction,$Action,$Protocol,$LocalPort,$LocalAddress,$RemoteAddress,$Program,$Profile)
 $m=Model;$m.rule=$true;$m.enabled=$true;$m.description=$Description;Save $m
 if($Mode -eq 'rule_create_after' -and !$m.faulted){$m.faulted=$true;Save $m;throw 'Injected rule creation result lost'}
 if($Mode -eq 'foreign_config' -and !$m.faulted){$m.faulted=$true;Save $m;[IO.File]::WriteAllText((Join-Path $statePath 'stun.json'),'foreign configuration');throw 'Injected foreign configuration'}
 if($Mode -eq 'foreign_acl' -and !$m.faulted){$m.faulted=$true;Save $m;$acl=Get-Acl (Join-Path $statePath 'stun.json');$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]'S-1-1-0','Read','Allow'));Microsoft.PowerShell.Security\Set-Acl -LiteralPath (Join-Path $statePath 'stun.json') -AclObject $acl;throw 'Injected foreign ACL'}
 if($Mode -eq 'foreign_rule' -and !$m.faulted){$m.description='foreign';$m.faulted=$true;Save $m;throw 'Injected foreign rule'}
}
function Enable-NetFirewallRule {param($Name) $m=Model;$m.enabled=$true;Save $m;if($Mode -eq 'rule_enable_after' -and !$m.faulted){$m.faulted=$true;Save $m;throw 'Injected enable result lost'}}
function Disable-NetFirewallRule {param($Name) $m=Model;$m.enabled=$false;Save $m}
function Remove-NetFirewallRule {param($Name,$ErrorAction) $m=Model;$m.rule=$false;Save $m}
function Restart-Service {param($Name,$ErrorAction) if($Name -cne 'OpenWebPBX'){throw 'Forbidden service mutation'};$m=Model;$m.restarts++;Save $m;if($Mode -eq 'service_once' -and !$m.faulted){$m.faulted=$true;Save $m;throw 'Injected background restart failure'}}
function Start-Service {param($Name,$ErrorAction)throw 'A previously stopped service must never start in this test'}
function Invoke-RestMethod {param($Uri,$TimeoutSec) $running=$false;$path=Join-Path $statePath 'stun.json';if(Test-Path $path){$c=Get-Content $path -Raw|ConvertFrom-Json;$running=$c.Stun.Enabled -eq $true};[pscustomobject]@{stun=$(if($running -and $Mode -ne 'readiness'){'Running'}else{'Disabled'})}}
function Start-Sleep {param($Seconds)}
function Invoke-OpenWebStunFixtureBoundary {
 $m=Model
 if(!$m.faulted -and $Mode -in 'write_acl','crash_acl'){$m.faulted=$true;Save $m;if($Mode -eq 'crash_acl'){[Environment]::Exit(73)};throw 'Injected post-replacement ACL failure'}
}
try{
 if($Mode -eq 'recover') {& (Join-Path $CaseRoot 'root\tools\Enable-Stun.ps1') -Recover}
 else {& (Join-Path $CaseRoot 'root\tools\Enable-Stun.ps1') -ListenAddress @('10.42.0.5')}
 exit 0
}catch{[IO.File]::WriteAllText((Join-Path $CaseRoot 'error.txt'),$_.Exception.Message);exit 1}
'@,[Text.UTF8Encoding]::new($false))
foreach($mode in 'success','write_acl','crash_acl','rule_create_after','rule_enable_after','service_once','readiness','foreign_config','foreign_acl','foreign_rule','stopped','disabled','rule_query_denied','udp_query_denied','foreign_base_acl'){
 $case=Join-Path $OutputDirectory $mode;$root=Join-Path $case 'root';$state=Join-Path $case 'state';$tools=Join-Path $root 'tools';New-Item -ItemType Directory -Path $tools,(Join-Path $root 'server'),$state|Out-Null
 foreach($file in 'PublicAccess.Common.ps1','Restore-Gates.ps1','File-Security.ps1'){Copy-Item (Join-Path $SourceRoot ('packaging\windows\'+$file)) (Join-Path $tools $file)}
 [IO.File]::WriteAllBytes((Join-Path $root 'server\OpenWebPbx.Server.exe'),[byte[]]@(1,2,3));[IO.File]::WriteAllText((Join-Path $state 'installation.json'),'{"Completed":true,"Version":"1.0.20"}')
 $mapped='$root='''+$root+''';$state='''+$state+''''
 $boundary='  if($Sddl){Set-OpenWebFileSddl';$instrumented='  Invoke-OpenWebStunFixtureBoundary'+"`r`n"+$boundary
 Check ([regex]::Matches($original,[regex]::Escape($boundary)).Count -eq 1)
 $source=$original.Replace($assignment,$mapped).Replace($boundary,$instrumented);Check ($source.Replace($mapped,$assignment).Replace($instrumented,$boundary) -ceq $original);[IO.File]::WriteAllText((Join-Path $tools 'Enable-Stun.ps1'),$source,[Text.UTF8Encoding]::new($false))
 . (Join-Path $tools 'PublicAccess.Common.ps1');Set-OpenWebPublicPrivateAcl $state
 $old=Join-Path $state 'stun.json';$bytes=[Text.UTF8Encoding]::new($false).GetBytes('{"Stun":{"Enabled":false}}');[IO.File]::WriteAllBytes($old,$bytes)
 $oldAcl=Get-Acl $old;$oldSddl=$oldAcl.Sddl
 if($mode -eq 'foreign_base_acl'){$foreignBase=Join-Path $state 'stun-setup';New-Item -ItemType Directory $foreignBase|Out-Null;Set-OpenWebPublicPrivateAcl $foreignBase;$acl=Get-Acl $foreignBase;$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]'S-1-1-0','Read','Allow'));Set-Acl -LiteralPath $foreignBase -AclObject $acl;$foreignBaseSddl=(Get-Acl $foreignBase).Sddl}
 $model=[ordered]@{start=$(if($mode -eq 'disabled'){'Disabled'}else{'Manual'});service=$(if($mode -eq 'stopped'){'Stopped'}else{'Running'});rule=($mode -eq 'rule_enable_after');enabled=$false;description='OpenWeb PBX owned STUN Binding service';restarts=0;faulted=$false};[IO.File]::WriteAllText((Join-Path $case 'model.json'),($model|ConvertTo-Json))
 & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $worker -CaseRoot $case -Mode $mode 1> (Join-Path $case 'first.log') 2> (Join-Path $case 'first.err');$exit=$LASTEXITCODE
 if($mode -eq 'success'){
  Check ($exit -eq 0);$m=Get-Content (Join-Path $case 'model.json') -Raw|ConvertFrom-Json;Check ($m.rule -and $m.enabled -and $m.restarts -eq 1)
  & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $worker -CaseRoot $case -Mode success 1> (Join-Path $case 'second.log') 2> (Join-Path $case 'second.err');Check ($LASTEXITCODE -eq 0);$m=Get-Content (Join-Path $case 'model.json') -Raw|ConvertFrom-Json;Check ($m.restarts -eq 1)
  continue
 }
 if($mode -eq 'foreign_base_acl'){
  Check ($exit -eq 1);Check ((Get-Acl $foreignBase).Sddl -ceq $foreignBaseSddl);Check (@(Get-ChildItem -LiteralPath $foreignBase -Force).Count -eq 0);Check (([Convert]::ToBase64String([IO.File]::ReadAllBytes($old))) -ceq [Convert]::ToBase64String($bytes));$m=Get-Content (Join-Path $case 'model.json') -Raw|ConvertFrom-Json;Check ($m.restarts -eq 0);continue
 }
 if($mode -in 'stopped','disabled','rule_query_denied','udp_query_denied'){
  Check ($exit -eq 1);Check (!(Test-Path (Join-Path $state 'stun-setup')));Check (([Convert]::ToBase64String([IO.File]::ReadAllBytes($old))) -ceq [Convert]::ToBase64String($bytes));$m=Get-Content (Join-Path $case 'model.json') -Raw|ConvertFrom-Json;Check ($m.restarts -eq 0);continue
 }
 if($mode -eq 'crash_acl'){Check ($exit -eq 73)}else{Check ($exit -eq 1)}
 $active=Join-Path $state 'stun-setup\active.json'
 if($mode -in 'crash_acl','foreign_config','foreign_acl','foreign_rule'){
  Check (Test-Path $active);$pointer=Get-Content $active -Raw|ConvertFrom-Json;$tx=Join-Path (Join-Path $state 'stun-setup') $pointer.transaction;$journal=Get-Content (Join-Path $tx 'journal.json') -Raw|ConvertFrom-Json
  Check (([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $tx 'previous.bin')))) -ceq [Convert]::ToBase64String($bytes));Check ($journal.config_before_sddl -ceq $oldSddl)
  if($mode -eq 'crash_acl'){
   . (Join-Path $tools 'File-Security.ps1')
   $backup=Join-Path $tx 'previous.bin';$priorSddl=(Get-Acl $backup).Sddl;$bad=Get-Acl $backup;$bad.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]'S-1-1-0','Read','Allow'));Set-Acl -LiteralPath $backup -AclObject $bad
   & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $worker -CaseRoot $case -Mode recover 1> (Join-Path $case 'private-acl-refusal.log') 2> (Join-Path $case 'private-acl-refusal.err');Check ($LASTEXITCODE -eq 1);Check (Test-Path $active);Check (([Convert]::ToBase64String([IO.File]::ReadAllBytes($old))) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $tx 'desired.bin'))))
   Set-OpenWebFileSddl -LiteralPath $backup -Sddl $priorSddl
  }
  if($mode -eq 'foreign_config'){Check ([IO.File]::ReadAllText($old) -ceq 'foreign configuration');[IO.File]::WriteAllBytes($old,[IO.File]::ReadAllBytes((Join-Path $tx 'desired.bin')))}
  if($mode -eq 'foreign_acl'){Check (@((Get-Acl $old).Access|Where-Object {$_.IdentityReference -eq 'Everyone'}).Count -gt 0);. (Join-Path $tools 'File-Security.ps1');Set-OpenWebFileSddl -LiteralPath $old -Sddl $journal.desired_sddl}
  if($mode -eq 'foreign_rule'){$m=Get-Content (Join-Path $case 'model.json') -Raw|ConvertFrom-Json;Check ($m.description -ceq 'foreign');$m.description='OpenWeb PBX owned STUN Binding service';[IO.File]::WriteAllText((Join-Path $case 'model.json'),($m|ConvertTo-Json))}
  & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $worker -CaseRoot $case -Mode recover 1> (Join-Path $case 'recover.log') 2> (Join-Path $case 'recover.err');Check ($LASTEXITCODE -eq 0)
 }
 Check (!(Test-Path $active));Check (([Convert]::ToBase64String([IO.File]::ReadAllBytes($old))) -ceq [Convert]::ToBase64String($bytes));Check ((Get-Acl $old).Sddl -ceq $oldSddl)
 $m=Get-Content (Join-Path $case 'model.json') -Raw|ConvertFrom-Json;Check ($m.rule -eq ($mode -eq 'rule_enable_after'));if($m.rule){Check (!$m.enabled)};Check ($m.service -ceq 'Running' -and $m.start -ceq 'Manual')
}
@{schema=1;state='passed';checks=$script:checks;actual_windows_files_and_acl=$true;actual_process_kill=$true;service_and_firewall_adapters='doubles';installed_services_touched=$false}|ConvertTo-Json -Compress
