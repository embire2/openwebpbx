#Requires -Version 7.4
# Actual-source diagnostic controls with explicit native API doubles only.
[CmdletBinding()]
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$script:checks=0;$script:mode='bootstrap'
function Check([bool]$Value){if(!$Value){throw ('A restart diagnostic control failed at line '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
$definitions=@{};$acceptanceAst=$null;$script:observerTestsRoot=$PSScriptRoot
foreach($source in @(@{Path='tests/windows_phone_health_acceptance.ps1';Name='HealthRestartObservation'},@{Path='tests/windows-suite.ps1';Name='SafePhoneHealthFailure'})){
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot $source.Path),[ref]$tokens,[ref]$errors);Check ($errors.Count -eq 0)
 $nodes=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $source.Name},$true));Check ($nodes.Count -eq 1)
 $definitions[$source.Name]=$nodes[0].Extent.Text
 # Extracted definitions have no source-file automatic variable. Adapt only
 # that path lookup; the PHP action itself remains an explicit read-only double.
 Invoke-Expression ($definitions[$source.Name].Replace('$PSScriptRoot','$script:observerTestsRoot'))
 if($source.Name -ceq 'HealthRestartObservation'){$acceptanceAst=$ast}
}
function Get-ScheduledTask {
 if($script:mode -ceq 'task_failure'){throw 'PRIVATE_TASK'}
 [pscustomobject]@{State=$(if($script:mode -ceq 'stale'){'Ready'}elseif($script:mode -ceq 'unknown_state'){'PRIVATE_STATE'}else{'Running'});Settings=[pscustomobject]@{Enabled=$true}}
}
function Assert-OpenWebHealthTask($Task){if($script:mode -ceq 'foreign_task'){throw 'PRIVATE_FOREIGN_TASK'}}
function Get-ScheduledTaskInfo {
 if($script:mode -ceq 'info_failure'){throw 'PRIVATE_INFO'}
 [pscustomobject]@{LastTaskResult=[uint32]267009;LastRunTime=$(if($script:mode -ceq 'stale'){$script:requested.AddSeconds(-10)}else{$script:requestedSecond})}
}
function Get-OpenWebHealthOwnedProcesses {
 if($script:mode -ceq 'process_failure'){throw 'PRIVATE_OWNER_OR_PROCESS'}
 if($script:mode -ceq 'stale'){return}
 [pscustomobject]@{ExecutablePath='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe';CommandLine='-File "C:\OpenWebPBX\tools\Phone-Health.ps1"';ProcessId=101}
 if($script:mode -cne 'bootstrap'){
  [pscustomobject]@{ExecutablePath='C:\OpenWebPBX\php\php.exe';CommandLine='"C:\OpenWebPBX\tools\phone-health.php" service';ProcessId=102}
  if($script:mode -ceq 'duplicate_php'){[pscustomobject]@{ExecutablePath='C:\OpenWebPBX\php\php.exe';CommandLine='"C:\OpenWebPBX\tools\phone-health.php" service';ProcessId=103}}
 }
}
function Get-NetTCPConnection {if($script:mode -ceq 'connection_failure'){throw 'PRIVATE_CONNECTION'};[pscustomobject]@{LocalPort=55001}}
function Php($File,$Arguments){
 if($script:mode -ceq 'heartbeat_failure'){throw 'PRIVATE_HEARTBEAT'}
 $port=if($script:mode -ceq 'string_port'){'55001'}elseif($script:mode -ceq 'bad_port'){'055001'}else{55001}
 [pscustomobject]@{state='observed';workers=[object[]]@([pscustomobject]@{client_port=$port;pid=900;changed=1.0})}
}
function Project($Observation,$Producer='windows_phone_health_acceptance.ps1',$State='failed',$Schema=1){
 SafePhoneHealthFailure ([pscustomobject]@{schema=$Schema;producer=$Producer;state=$State;gates=@{};diagnostic_recovery_exact=$false;restart_observation=$Observation})
}
$script:requested=[DateTime]::new(2026,10,23,10,0,0,567,[DateTimeKind]::Utc);$script:requestedSecond=[DateTime]::new(2026,10,23,10,0,0,[DateTimeKind]::Utc)
$script:mode='bootstrap';$bootstrap=HealthRestartObservation $script:requested
Check ($bootstrap.task_observed -and $bootstrap.fresh_start -and $bootstrap.owned_wrappers -eq 1 -and $bootstrap.owned_php -eq 0 -and $bootstrap.system_verified -and !$bootstrap.connections_observed -and $bootstrap.error_kind -ceq 'none')
Check ((Project $bootstrap).restart_observation.owned_wrappers -eq 1)
foreach($mode in 'idle','string_port'){
 $script:mode=$mode;$row=HealthRestartObservation $script:requested
 Check ($row.owned_php -eq 1 -and $row.pg_connections -eq 1 -and $row.matching_heartbeats -eq 1 -and $row.heartbeat_observed -and $row.error_kind -ceq 'none')
 Check ((Project $row).restart_observation.matching_heartbeats -eq 1)
}
foreach($pair in @(@('task_failure','task'),@('foreign_task','task'),@('info_failure','task_info'),@('process_failure','processes'),@('connection_failure','connections'),@('heartbeat_failure','heartbeat'),@('bad_port','heartbeat'))){
 $script:mode=$pair[0];$row=HealthRestartObservation $script:requested
 Check ($row.error_kind -ceq $pair[1]);Check ((Project $row).restart_observation.error_kind -ceq $pair[1]);Check (($row|ConvertTo-Json -Compress) -notmatch 'PRIVATE')
}
$script:mode='stale';$row=HealthRestartObservation $script:requested;Check (!$row.fresh_start -and $row.processes_observed -and !$row.system_verified -and $row.owned_php -eq 0)
$script:mode='duplicate_php';$row=HealthRestartObservation $script:requested;Check ($row.owned_php -eq 2 -and !$row.connections_observed)
$script:mode='unknown_state';$row=HealthRestartObservation $script:requested;Check ($row.task_state -ceq 'other' -and ($row|ConvertTo-Json -Compress) -notmatch 'PRIVATE')
$script:mode='idle';$valid=HealthRestartObservation $script:requested
foreach($field in $valid.Keys){$bad=@{};foreach($key in $valid.Keys){if($key -cne $field){$bad[$key]=$valid[$key]}};Check (!(Project $bad).ContainsKey('restart_observation'))}
foreach($field in 'task_observed','task_enabled','task_info_observed','fresh_start','processes_observed','system_verified','connections_observed','heartbeat_observed'){
 foreach($value in @($null,0,'true',@($true))){$bad=@{};foreach($key in $valid.Keys){$bad[$key]=$valid[$key]};$bad[$field]=$value;Check (!(Project $bad).ContainsKey('restart_observation'))}
}
foreach($pair in @(@('last_result',4294967296L),@('owned_wrappers',17),@('owned_php',17),@('pg_connections',33),@('matching_heartbeats',33),@('task_state','PRIVATE'),@('error_kind','PRIVATE'))){$bad=@{};foreach($key in $valid.Keys){$bad[$key]=$valid[$key]};$bad[$pair[0]]=$pair[1];Check (!(Project $bad).ContainsKey('restart_observation'))}
$bad=@{};foreach($key in $valid.Keys){$bad[$key]=$valid[$key]};$bad.raw='PRIVATE';Check (!(Project $bad).ContainsKey('restart_observation'))
Check ((Project $valid 'foreign').Count -eq 0);Check ((Project $valid 'windows_phone_health_acceptance.ps1' 'passed').Count -eq 0);Check ((Project $valid 'windows_phone_health_acceptance.ps1' 'failed' 2).Count -eq 0)
$catches=@($acceptanceAst.FindAll({param($node)$node -is [Management.Automation.Language.CatchClauseAst] -and $node.Extent.Text.Contains('$report.restart_observation=HealthRestartObservation')},$true));Check ($catches.Count -eq 1)
$script:report=@{};$restartRequestedAt=$script:requested;$primary=$null
try{& ([scriptblock]::Create("try{throw 'PRIVATE_PRIMARY'} "+$catches[0].Extent.Text))}catch{$primary=$_}
Check ($primary.Exception.Message -ceq 'PRIVATE_PRIMARY');Check ($script:report.restart_observation.matching_heartbeats -eq 1)
function HealthRestartObservation {throw 'PRIVATE_OBSERVER_FAILURE'}
$script:report=@{};$primary=$null;try{& ([scriptblock]::Create("try{throw 'PRIVATE_PRIMARY'} "+$catches[0].Extent.Text))}catch{$primary=$_}
Check ($primary.Exception.Message -ceq 'PRIVATE_PRIMARY');Check (!$script:report.ContainsKey('restart_observation'))
Write-Output "PASS $script:checks actual-source restart diagnostic/primary-preservation controls; native APIs are doubles; no server contacted"
