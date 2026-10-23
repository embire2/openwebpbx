# Execute the actual closed STUN lock projection; raw errors and paths stay private.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-suite.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The suite must parse.'}
$nodes=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'SafeStunMaintenanceLockFields'},$true))
if($nodes.Count -ne 1){throw 'The exact STUN evidence projector is required.'};Invoke-Expression $nodes[0].Extent.Text
$script:checks=0
function Check([bool]$Value){if(!$Value){throw ('STUN lock projection refusal failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
Check ((SafeStunMaintenanceLockFields @{}).Count -eq 0)
foreach($name in 'maintenance_lock_acquired','maintenance_lock_busy'){
 foreach($value in $true,$false){$row=SafeStunMaintenanceLockFields @{$name=$value};Check ($row.Count -eq 1 -and $row[$name] -is [bool] -and $row[$name] -eq $value)}
 foreach($value in 'true',1,@($true),$null){Check (!(SafeStunMaintenanceLockFields @{$name=$value}).ContainsKey($name))}
}
foreach($value in 0,1,30000,60000){$row=SafeStunMaintenanceLockFields @{maintenance_lock_elapsed_ms=$value};Check ($row.maintenance_lock_elapsed_ms -eq $value)}
foreach($value in -1,60001,1.5,'30',@(1),$null){Check (!(SafeStunMaintenanceLockFields @{maintenance_lock_elapsed_ms=$value}).ContainsKey('maintenance_lock_elapsed_ms'))}
foreach($name in 'IOException','UnauthorizedAccessException','InvalidOperationException','DirectoryNotFoundException','FileNotFoundException','ArgumentException','SecurityException','NotSupportedException'){Check ((SafeStunMaintenanceLockFields @{maintenance_lock_error_type=$name}).maintenance_lock_error_type -ceq $name)}
foreach($value in 'secret path','IOException: secret','ioexception',@('IOException'),$null){Check (!(SafeStunMaintenanceLockFields @{maintenance_lock_error_type=$value}).ContainsKey('maintenance_lock_error_type'))}
foreach($field in 'maintenance_lock_hresult','lock_probe_hresult'){
 foreach($value in '80070020','80070021','80070005','00000000'){
  $inputRow=if($field -ceq 'maintenance_lock_hresult'){@{$field=$value}}else{@{maintenance_lock_probe=@{$field=$value}}}
  $row=SafeStunMaintenanceLockFields $inputRow;$out=if($field -ceq 'maintenance_lock_hresult'){$row[$field]}else{$row.maintenance_lock_probe[$field]};Check ($out -ceq $value)
 }
 foreach($value in '8007002','800700200','8007002A','secret',80070020,@('80070020'),$null){
  $inputRow=if($field -ceq 'maintenance_lock_hresult'){@{$field=$value}}else{@{maintenance_lock_probe=@{$field=$value}}}
  $row=SafeStunMaintenanceLockFields $inputRow;Check ($(if($field -ceq 'maintenance_lock_hresult'){!$row.ContainsKey($field)}else{!$row.ContainsKey('maintenance_lock_probe')}))
 }
}
foreach($value in 'available','sharing_violation','lock_violation','missing','access_denied','other_io','other_error','not_ordinary'){
 $row=SafeStunMaintenanceLockFields @{maintenance_lock_probe=@{lock_probe_result=$value;raw_error='secret';path='secret'}};Check ($row.maintenance_lock_probe.Count -eq 1 -and $row.maintenance_lock_probe.lock_probe_result -ceq $value)
}
foreach($value in 'secret',@('available'),1,$null){Check (!(SafeStunMaintenanceLockFields @{maintenance_lock_probe=@{lock_probe_result=$value}}).ContainsKey('maintenance_lock_probe'))}
$sample=@{maintenance_lock_acquired=$true;maintenance_lock_elapsed_ms=12L;maintenance_lock_probe=@{lock_probe_result='sharing_violation';lock_probe_hresult='80070020';raw='secret'};command='secret';password='secret'}
$safe=SafeStunMaintenanceLockFields $sample;Check ($safe.Count -eq 3 -and $safe.maintenance_lock_probe.Count -eq 2 -and ($safe|ConvertTo-Json -Compress) -cnotmatch 'secret')
$stunTokens=$null;$stunErrors=$null;$stunAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-stun-native.ps1'),[ref]$stunTokens,[ref]$stunErrors);Check ($stunErrors.Count -eq 0)
$locks=@($stunAst.FindAll({param($node)$node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$lock' -and $node.Right.Extent.Text -match '^Open-OpenWebPhoneTlsMaintenance '},$true));Check ($locks.Count -eq 1)
Check ($locks[0].Right.Extent.Text -ceq "Open-OpenWebPhoneTlsMaintenance -Path (Join-Path `$state 'upgrade.lock') -WaitMilliseconds 30000")
[ordered]@{schema=1;state='passed';checks=$script:checks;actual_source_projection=$true;private_data_exported=$false}|ConvertTo-Json -Compress
