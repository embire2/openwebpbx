param([string]$Helper=(Join-Path $PSScriptRoot 'windows-original21-prebaseline-core.ps1'))
$ErrorActionPreference='Stop';$script:O21Checks=0
function Check([bool]$O21Value,[string]$O21Label){if(!$O21Value){throw ('Control failed: '+$O21Label)};$script:O21Checks++}
. $Helper
# Only local read-only filesystem/SCM doubles. No Windows service/provider calls occur.
function Assert-Original21CoreFixture {}
function Assert-Original21CoreOrdinary([string]$O21Path){}
function Reset-Case {
 $script:O21Mode='normal';$script:O21Actions=@();$script:O21State='Running';$script:O21ServicePID=41;$script:O21ProcessPID=41;$script:O21OldAlive=$true;$script:O21Created='2026-11-03T00:00:00Z';$script:O21Account='NT AUTHORITY\LocalService';$script:O21Startup='Manual';$script:O21Name='OpenWebPBX';$script:O21Path='C:\OpenWebPBX\server\OpenWebPbx.Server.exe';$script:O21SID='S-1-5-19';$script:O21Version='1.0.21';$script:O21Hash=('1'*64);$script:O21BodyRecord=$null;$script:O21StopRecord=$null;$script:O21ControllerName='OpenWebPBX';$script:O21ControllerMachine='.'
}
function Get-Content {param($LiteralPath,[switch]$Raw,$ErrorAction) return ('{"version":"'+$script:O21Version+'","files":{"server/OpenWebPbx.Server.exe":"'+('1'*64)+'","server/OpenWebPbx.Server.dll":"'+('1'*64)+'"}}')}
function Get-FileHash {param($LiteralPath,$Algorithm,$ErrorAction) return @{Hash=$script:O21Hash}}
function Get-CimInstance {param($ClassName,$Filter,$OperationTimeoutSec,$ErrorAction)
 if($ClassName -ceq 'Win32_Service'){Check ($Filter -ceq "Name='OpenWebPBX'") 'only exact Core queried';return [pscustomobject]@{Name=$script:O21Name;PathName=$script:O21Path;StartName=$script:O21Account;StartMode=$script:O21Startup;State=$script:O21State;ProcessId=[uint32]$script:O21ServicePID}}
 if($Filter -like 'ProcessId=*'){if($script:O21OldAlive){return [pscustomobject]@{ProcessId=41}};return}
 Check ($Filter -ceq "Name='OpenWebPbx.Server.exe'") 'only exact Core image queried'
 if($script:O21ServicePID){return [pscustomobject]@{ProcessId=[uint32]$script:O21ProcessPID;ExecutablePath='C:\OpenWebPBX\server\OpenWebPbx.Server.exe';CreationDate=$script:O21Created}}
}
function Invoke-CimMethod {param($InputObject,$MethodName,$OperationTimeoutSec,$ErrorAction) Check ($MethodName -ceq 'GetOwnerSid') 'owner query only';return @{ReturnValue=0;Sid=$script:O21SID}}
function Stop-Service {param([switch]$NoWait,$Name,$ErrorAction)
 Check $NoWait.IsPresent 'stop request must not wait internally'
 Check ($Name -ceq 'OpenWebPBX') 'no wrong service stop';$script:O21Actions+=,'stop'
 if($script:O21Mode -ceq 'stop_before'){try{throw 'ORIGINAL_STOP'}catch{$script:O21StopRecord=$_;throw}}
 $script:O21State='Stopped';$script:O21ServicePID=0;$script:O21OldAlive=$false
 if($script:O21Mode -ceq 'stop_partial'){try{throw 'ORIGINAL_STOP'}catch{$script:O21StopRecord=$_;throw}}
}
function Invoke-CoreStartDouble {
 $script:O21Actions+=,'start'
 if($script:O21Mode -ceq 'start_error'){throw 'RESTORE_ERROR'}
 $script:O21State='Running';$script:O21ServicePID=42;$script:O21ProcessPID=42;$script:O21Created='2026-11-03T00:01:00Z'
}
function Get-Service {param($Name,$ErrorAction)
 Check ($Name -ceq 'OpenWebPBX') 'only exact Core controller requested'
 $O21Double=[pscustomobject]@{ServiceName=$script:O21ControllerName;MachineName=$script:O21ControllerMachine}
 $O21Double|Add-Member ScriptMethod Start {Invoke-CoreStartDouble}
 $O21Double|Add-Member ScriptMethod Dispose {}
 return $O21Double
}
# Join-Path is solely a portable drive-layout adapter; production uses fixed native paths.
function Join-Path {param($Path,$ChildPath) return ($Path.TrimEnd('\','/')+'\'+$ChildPath.Replace('/','\'))}
function Main-Shape([switch]$ThrowBody,[switch]$FailRestore){
 $root='MAIN_ROOT';$state='MAIN_STATE';$package='MAIN_PACKAGE';$facts=@{main=$true};$phase='before';$O21MainToken=$null;$O21MainPrimary=$null
 try{
  $O21MainToken=Suspend-Original21PrebaselineCore -PackageRoot 'Q:\Original21'
  $phase='natural tenant';Check ($script:O21State -ceq 'Stopped') 'same natural tenant body sees quiet Core'
  $phase='ordinary warmup';Check ($root -ceq 'MAIN_ROOT' -and $state -ceq 'MAIN_STATE' -and $package -ceq 'MAIN_PACKAGE' -and $facts.main) 'main bindings not shadowed'
  if($FailRestore){$script:O21Mode='start_error'}
  if($ThrowBody){try{throw 'ORIGINAL_BODY'}catch{$script:O21BodyRecord=$_;throw}}
 }catch{$O21MainPrimary=$_}
 finally{if($O21MainToken){try{Resume-Original21PrebaselineCore -Token $O21MainToken}catch{if(!$O21MainPrimary){$O21MainPrimary=$_}else{$O21MainPrimary.Exception.Data['original21_core_restore_failed']=$true}}}}
 Check ($phase -ceq 'ordinary warmup') 'direct main phase assignment preserved'
 if($O21MainPrimary){throw $O21MainPrimary}
}
Reset-Case;Main-Shape;Check (($script:O21Actions -join ',') -ceq 'stop,start') 'one ordinary stop/start';Check ($script:O21State -ceq 'Running' -and $script:O21ServicePID -eq 42) 'fresh owned PID restored'
Reset-Case;$script:O21State='Stopped';$script:O21ServicePID=0;$script:O21OldAlive=$false;Main-Shape;Check ($script:O21Actions.Count -eq 0 -and $script:O21State -ceq 'Stopped') 'originally stopped never started'
foreach($O21Bad in 'name','path','account','startup','sid','pid','hash','version'){
 Reset-Case
 switch($O21Bad){'name'{$script:O21Name='OpenWebPBX-Database'}'path'{$script:O21Path+=' --foreign'}'account'{$script:O21Account='LocalSystem'}'startup'{$script:O21Startup='Auto'}'sid'{$script:O21SID='S-1-5-18'}'pid'{$script:O21ProcessPID=99}'hash'{$script:O21Hash=('f'*64)}'version'{$script:O21Version='1.0.22'}}
 $O21Refused=$false;try{Suspend-Original21PrebaselineCore -PackageRoot 'Q:\Original21'|Out-Null}catch{$O21Refused=$true}
 Check ($O21Refused -and $script:O21Actions.Count -eq 0) ('wrong '+$O21Bad+' refuses before action')
}
foreach($O21StopMode in 'stop_before','stop_partial'){
 Reset-Case;$script:O21Mode=$O21StopMode;$O21Caught=$null;try{Suspend-Original21PrebaselineCore -PackageRoot 'Q:\Original21'|Out-Null}catch{$O21Caught=$_}
 Check ($O21Caught.Exception.Message -ceq 'ORIGINAL_STOP') 'stop primary retained';Check ([object]::ReferenceEquals($O21Caught.Exception,$script:O21StopRecord.Exception)) 'stop exception identity retained'
 Check ($script:O21State -ceq 'Running') 'ambiguous stop original running restored';Check (($script:O21Actions -join ',') -ceq $(if($O21StopMode -ceq 'stop_before'){'stop'}else{'stop,start'})) 'no extra restart for pre-change stop refusal'
}
foreach($O21RestoreFailure in $false,$true){
 Reset-Case;$O21Caught=$null;try{Main-Shape -ThrowBody -FailRestore:$O21RestoreFailure}catch{$O21Caught=$_}
 Check ($O21Caught.Exception.Message -ceq 'ORIGINAL_BODY') 'body primary never replaced';Check ([object]::ReferenceEquals($O21Caught.Exception,$script:O21BodyRecord.Exception)) 'body exception identity retained'
 if($O21RestoreFailure){Check ($O21Caught.Exception.Data['original21_core_restore_failed'] -eq $true) 'secondary restore failure retained'}else{Check ($script:O21State -ceq 'Running') 'body error still restores Core'}
}
Reset-Case;$O21Token=Suspend-Original21PrebaselineCore -PackageRoot 'Q:\Original21';$script:O21Hash=('f'*64);$O21Refused=$false;try{Resume-Original21PrebaselineCore -Token $O21Token}catch{$O21Refused=$true};Check ($O21Refused -and ($script:O21Actions -join ',') -ceq 'stop') 'changed restore hash cannot start service'
$O21Tokens=$null;$O21Errors=$null;$O21Ast=[Management.Automation.Language.Parser]::ParseFile($Helper,[ref]$O21Tokens,[ref]$O21Errors);Check ($O21Errors.Count -eq 0) 'helper parses'
$O21Commands=@($O21Ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst]},$true))
foreach($O21Forbidden in 'Start-Service','Restart-Service','Set-Service','Stop-Process','Stop-ScheduledTask','Disable-ScheduledTask','Enable-ScheduledTask','Start-ScheduledTask','New-NetFirewallRule','Remove-Item'){Check (!@($O21Commands|Where-Object {$_.GetCommandName() -ceq $O21Forbidden}).Count) ('no '+$O21Forbidden)}
foreach($O21Command in @($O21Commands|Where-Object {$_.GetCommandName() -cin 'Stop-Service','Start-Service'})){Check ($O21Command.Extent.Text -cmatch '-Name OpenWebPBX(?:\s|$)' -and $O21Command.Extent.Text -cnotmatch '-Force') 'only ordinary exact Core SCM action'}
$O21Stops=@($O21Commands|Where-Object {$_.GetCommandName() -ceq 'Stop-Service'});Check ($O21Stops.Count -eq 1 -and $O21Stops[0].Extent.Text -cmatch '-NoWait(?:\s|$)') 'one nonwaiting ordinary Stop request'
$O21Starts=@($O21Ast.FindAll({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Extent.Text -ceq 'Start'},$true));Check ($O21Starts.Count -eq 1 -and $O21Starts[0].Expression.Extent.Text -ceq '$O21Controller') 'one ordinary validated controller Start request'
foreach($O21BadController in 'name','machine'){
 Reset-Case;$O21Token=Suspend-Original21PrebaselineCore -PackageRoot 'Q:\Original21'
 if($O21BadController -ceq 'name'){$script:O21ControllerName='FreeSWITCH'}else{$script:O21ControllerMachine='REMOTE'}
 $O21Refused=$false;try{Resume-Original21PrebaselineCore -Token $O21Token}catch{$O21Refused=$true}
 Check ($O21Refused -and ($script:O21Actions -join ',') -ceq 'stop') 'foreign or remote controller cannot start'
}
$O21Guards=@($O21Ast.FindAll({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.Contains('$O21Clock.Elapsed.TotalSeconds -ge 60')},$true));Check ($O21Guards.Count -eq 2) 'two exact native deadline checks'
foreach($O21Guard in $O21Guards){$O21Clock=[pscustomobject]@{Elapsed=[pscustomobject]@{TotalSeconds=60}};$O21Refused=$false;try{Invoke-Expression $O21Guard.Extent.Text}catch{$O21Refused=$true};Check $O21Refused 'deadline denies late success'}
Write-Output ('PASS '+$script:O21Checks+' actual-source SCM doubles/hash/identity/direct-scope/error/finally controls; no native service action')
