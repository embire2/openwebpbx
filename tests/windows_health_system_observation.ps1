# Exact SYSTEM-observer literal and closed outer projection using private adapters.
[CmdletBinding()]param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$checks=0
function Check([bool]$x){if(!$x){throw ('Health SYSTEM diagnostic control refused at '+(@(Get-PSCallStack)[1].ScriptLineNumber))};$script:checks++}
function Ast([string]$p){$t=$null;$e=$null;$a=[Management.Automation.Language.Parser]::ParseFile($p,[ref]$t,[ref]$e);Check (!$e.Count);return $a}
$a=Ast (Join-Path $SourceRoot 'tests/windows_phone_health_acceptance.ps1');$outer=Ast (Join-Path $SourceRoot 'tests/windows-suite.ps1')
$n=@($a.FindAll({param($x)$x-is [Management.Automation.Language.AssignmentStatementAst] -and $x.Left.Extent.Text-ceq '$system'},$true));Check ($n.Count-eq 1)
$literal=@($n[0].Right.FindAll({param($x)$x-is [Management.Automation.Language.StringConstantExpressionAst]},$true));Check ($literal.Count-eq 1);$code=$literal[0].Value
Check ($code.Contains("`$output=& 'C:\OpenWebPBX\tools\Phone-Health.ps1' -Once`n  if(!`$? -or `$LASTEXITCODE)"))
Check ($code.Contains('for($attempt=0;$attempt -lt 3;$attempt++)') -and $code.Contains("if(`$parsed.state -ne 'deferred'){break};Start-Sleep -Seconds 2"))
Check ($code.Contains("if(`$parsed.state -ne 'observed' -or `$parsed.available -isnot [bool] -or !`$parsed.available)"))
Check ($a.Extent.Text.Contains('[DateTime]::UtcNow.AddMinutes(4)') -and $a.Extent.Text.Contains('$report.system_observer_failure=$result;throw'))
$fn=@($outer.FindAll({param($x)$x-is [Management.Automation.Language.FunctionDefinitionAst] -and $x.Name-ceq 'SafePhoneHealthFailure'},$true));Check ($fn.Count-eq 1);Invoke-Expression $fn[0].Extent.Text
function Project($r){SafePhoneHealthFailure ([pscustomobject]@{schema=1;producer='windows_phone_health_acceptance.ps1';state='failed';gates=@{};system_observer_failure=$r})}
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('openweb-health-system-controls-'+[Guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $tmp|Out-Null
try{
 $security=Join-Path $tmp 'security.ps1';$worker=Join-Path $tmp 'worker.ps1';$trace=Join-Path $tmp 'sleep.log';$target=Join-Path $tmp 'system.ps1';$result=Join-Path $tmp 'result.json'
 [IO.File]::WriteAllText($security,"function Assert-OpenWebHealthSystem{if(`$env:OPENWEB_QA_HEALTH_CASE-ceq 'identity'){throw 'owned adapter denial'}}`nfunction Start-Sleep([int]`$Seconds){if(`$Seconds-ne 2){throw 'unexpected spacing'};[IO.File]::AppendAllText('"+$trace.Replace("'","''")+"',`"2`n`")}",[Text.UTF8Encoding]::new($false))
 $adapter=@'
param([switch]$Once)
if(!$Once){throw 'exact Once contract required'}
$global:LASTEXITCODE=0
switch($env:OPENWEB_QA_HEALTH_CASE){
 invocation{throw 'owned invocation adapter refusal'}
 exit{$global:LASTEXITCODE=7;'{"state":"observed","available":true}'}
 parse{'not json'}
 unavailable{'{"state":"observed","available":false}'}
 wrongbool{'{"state":"observed","available":"true"}'}
 deferred{'{"state":"deferred"}'}
 deferred_then_throw{if(!$global:OPENWEB_QA_HEALTH_COUNT){$global:OPENWEB_QA_HEALTH_COUNT=1;'{"state":"deferred"}'}else{throw 'owned second attempt refusal'}}
 default{'{"state":"observed","available":true}'}
}
'@
 [IO.File]::WriteAllText($worker,$adapter,[Text.UTF8Encoding]::new($false))
 $prepared=$code.Replace("C:\OpenWebPBX\tools\PhoneHealth-Security.ps1",$security.Replace("'","''")).Replace("C:\OpenWebPBX\tools\Phone-Health.ps1",$worker.Replace("'","''")).Replace('__RESULT__',$result.Replace("'","''"));[IO.File]::WriteAllText($target,$prepared,[Text.UTF8Encoding]::new($false))
 $hostPath=(Get-Process -Id $PID).Path
 foreach($case in 'success','identity','invocation','exit','parse','unavailable','wrongbool','deferred','deferred_then_throw'){
  Remove-Item -LiteralPath $result,$trace -ErrorAction SilentlyContinue;$env:OPENWEB_QA_HEALTH_CASE=$case
  $pi=[Diagnostics.ProcessStartInfo]::new();$pi.FileName=$hostPath;$pi.Arguments='-NoProfile -NonInteractive -File "'+$target+'"';$pi.UseShellExecute=$false;$pi.RedirectStandardOutput=$true;$pi.RedirectStandardError=$true
  $child=[Diagnostics.Process]::new();$child.StartInfo=$pi;try{Check ($child.Start());$null=$child.Handle;$stdout=$child.StandardOutput.ReadToEnd();$stderr=$child.StandardError.ReadToEnd();Check ($child.WaitForExit(15000));$exit=$child.ExitCode}finally{$child.Dispose()}
  $r=Get-Content -LiteralPath $result -Raw|ConvertFrom-Json
  if($case-ceq 'success'){Check ($exit-eq 0 -and $r.state-ceq 'passed' -and $r.actual_system-eq $true -and $r.actual_installed_observer-eq $true);Check (!(Test-Path $trace));continue}
  Check ($exit-eq 1 -and $r.state-ceq 'failed');$safe=Project $r;Check ($safe.system_observer_failure.Count-eq 8)
  $expected=switch($case){identity{'system_identity'};invocation{'installed_invocation'};deferred_then_throw{'installed_invocation'};exit{'invocation_exit'};parse{'json_parse'};default{'availability'}}
  Check ($safe.system_observer_failure.phase-ceq $expected)
  if($case-ceq 'deferred_then_throw'){Check ($r.attempt-eq 2 -and $null-eq $r.native_exit -and $r.observed_state-ceq 'unavailable' -and $null-eq $r.available)}
  if($case-ceq 'exit'){Check ($safe.system_observer_failure.native_exit-eq 7)}
  if($case-ceq 'deferred'){Check ($r.attempt-eq 3 -and @(Get-Content $trace).Count-eq 3 -and $r.observed_state-ceq 'deferred')}
 }
 $valid=@{schema=1;state='failed';phase='availability';attempt=3;native_exit=0;observed_state='deferred';available=$null;error_type='RuntimeException'}
 foreach($mutation in @(@{field='state';value=@('failed','PRIVATE')},@{field='state';value=$true},@{field='schema';value=$true},@{field='phase';value='PRIVATE'},@{field='attempt';value=4},@{field='attempt';value=$true},@{field='native_exit';value='0'},@{field='native_exit';value=$false},@{field='native_exit';value=4294967296L},@{field='available';value='false'},@{field='observed_state';value='PRIVATE'},@{field='error_type';value='PRIVATE'})){
  $bad=@{};foreach($key in $valid.Keys){$bad[$key]=$valid[$key]};$bad[$mutation.field]=$mutation.value;Check (!(Project $bad).ContainsKey('system_observer_failure'))
 }
 $bad=@{};foreach($key in $valid.Keys){$bad[$key]=$valid[$key]};$bad.path='PRIVATE';Check (!(Project $bad).ContainsKey('system_observer_failure'))
 $transport=$valid|ConvertTo-Json -Compress|ConvertFrom-Json;Check ((Project $transport).system_observer_failure.Count-eq 8)
 [ordered]@{passed=$true;checks=$checks;actual_literal_and_outer_source=$true;observer_paths_are_explicit_test_adapters=$true;native_installed_worker_executed=$false;registered_task_service_or_product_changes=$false}|ConvertTo-Json -Compress
}finally{Remove-Item Env:\OPENWEB_QA_HEALTH_CASE -ErrorAction SilentlyContinue;if((Split-Path $tmp -Leaf)-cmatch '^openweb-health-system-controls-[a-f0-9]{32}$'){Remove-Item -LiteralPath $tmp -Recurse -Force}}
