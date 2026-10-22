#Requires -Version 7.4
# SPDX-License-Identifier: AGPL-3.0-or-later
$ErrorActionPreference='Stop'
$source=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'windows-suite.ps1') -Raw
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Suite parse failed.'}
foreach($name in 'SafeTenantDomainsProof','SafePhoneHealthFailure'){
 $nodes=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true));if($nodes.Count -ne 1){throw 'One exact projection required.'};Invoke-Expression $nodes[0].Extent.Text
}
$count=0
function Check([bool]$v){if(!$v){throw "Projection control failed at $count"};$script:count++}
function Clone($r){return ($r|ConvertTo-Json -Depth 12|ConvertFrom-Json)}
$tenant=[pscustomobject]@{task_observation=[pscustomobject]@{last_task_result=1;fresh_run=$true;completed=$true;held_worker_exit=1;held_worker_state='deferred';held_worker_reason='unavailable';held_worker_error_type='BackupError';raw_stderr='forbidden-private-value'}}
$r=SafeTenantDomainsProof $tenant;Check ($r.task_observation.last_task_result -eq 1 -and $r.task_observation.Count -eq 7 -and ($r|ConvertTo-Json -Depth 8) -notmatch 'forbidden-private-value')
foreach($case in @(@('last_task_result',-1),@('last_task_result',4294967296L),@('last_task_result','1'),@('fresh_run','true'),@('completed',1),@('held_worker_exit',-2147483649L),@('held_worker_exit',4294967296L),@('held_worker_state','private-value'),@('held_worker_reason','private-value'),@('held_worker_error_type','private-value'))){$bad=Clone $tenant;$bad.task_observation.($case[0])=$case[1];Check (!(SafeTenantDomainsProof $bad).ContainsKey('task_observation'))}
foreach($value in 0,1,267009,267011,4294967295L){$r=Clone $tenant;$r.task_observation.last_task_result=$value;Check ((SafeTenantDomainsProof $r).task_observation.last_task_result -eq $value)}
$health=[pscustomobject]@{schema=1;producer='windows_phone_health_acceptance.ps1';state='failed';gates=[pscustomobject]@{installed_task='passed';native_worker='pending';private='forbidden-private-value'};native_worker_failure=[pscustomobject]@{phase='schema';error_type='PDOException';source_basename='windows_phone_health_worker.php';source_line=31;sqlstate='42501';message='forbidden-private-value'}}
$r=SafePhoneHealthFailure $health;Check ($r.native_worker_failure.sqlstate -ceq '42501' -and $r.native_worker_failure.Count -eq 5 -and $r.gates.Count -eq 2 -and ($r|ConvertTo-Json -Depth 8) -notmatch 'forbidden-private-value')
foreach($case in @(@('phase','private-value'),@('error_type','private-value'),@('source_basename','C:\private\database.php'),@('source_line',0),@('source_line',100000),@('source_line','31'),@('sqlstate','42p01'),@('sqlstate','42601 extra'),@('sqlstate',42601))){$bad=Clone $health;$bad.native_worker_failure.($case[0])=$case[1];Check (!(SafePhoneHealthFailure $bad).ContainsKey('native_worker_failure'))}
foreach($case in @(@('producer','private-value'),@('state','passed'),@('schema',2))){$bad=Clone $health;$bad.($case[0])=$case[1];Check ((SafePhoneHealthFailure $bad).Count -eq 0)}
foreach($name in 'windows_phone_health_acceptance.ps1','windows-tenant-domains-native.ps1'){$path=Join-Path $PSScriptRoot $name;$tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors);Check ($errors.Count -eq 0)}
@{state='passed';actual_powershell_ast=$true;checks=$count;closed_projection_only=$true}|ConvertTo-Json -Compress
