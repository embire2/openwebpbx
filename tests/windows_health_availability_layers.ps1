#Requires -Version 7.4
# Closed failure-only metadata; native paths below are explicit private adapters.
$ErrorActionPreference='Stop';$checks=0
function Check([bool]$x){if(!$x){throw ('Health layer control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
function Ast($p){$t=$null;$e=$null;$a=[Management.Automation.Language.Parser]::ParseFile($p,[ref]$t,[ref]$e);Check (!$e.Count);return $a}
$a=Ast (Join-Path $PSScriptRoot 'windows_phone_health_acceptance.ps1');$outer=Ast (Join-Path $PSScriptRoot 'windows-suite.ps1')
$fn=@($outer.FindAll({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-ceq 'SafePhoneHealthFailure'},$true));Check ($fn.Count-eq 1);Invoke-Expression $fn[0].Extent.Text
$base=@{schema=1;state='failed';phase='availability';attempt=1;native_exit=0;observed_state='observed';available=$false;error_type='RuntimeException'}
function Project($layer){$s=@{};foreach($k in $base.Keys){$s[$k]=$base[$k]};if($null-ne $layer){$s.layers=$layer};return SafePhoneHealthFailure ([pscustomobject]@{schema=1;producer='windows_phone_health_acceptance.ps1';state='failed';gates=@{};system_observer_failure=$s})}
function Clone($x){return($x|ConvertTo-Json -Depth 20|ConvertFrom-Json -AsHashtable)}
$layer=@{schema=1;scope='PRIVATE_RAW_SIP_METADATA';no_monitor_collect_reconcile_called=$true;no_add_remove_or_worker_invocation=$true;runtime_ready=$true;registrations_parser=$false;pending_intents=0;registration_count=0;original_state_elapsed_ms=15002;listener_counts=$null;original_firewall_state='unknown';sofia_profile_summary=@{valid=$true;running=2;loopback=2;non_loopback=0;unparseable=0;loopback_only=$true};state_transport=@();neutral_transport=@{started=$true;process_created=$true;cutoff='none';native_exit=0;close_exit=0;last_running=$false;output_bytes=7;raw_returned=$true;json_state='other';elapsed_ms=292}}
$p=Project $layer;Check ($p.system_observer_failure.Count-eq 9 -and !$p.system_observer_failure.available);Check ($p.system_observer_failure.layers.sofia_profile_summary.loopback_only -and !$p.system_observer_failure.layers.registrations_parser);Check (!$p.system_observer_failure.layers.state_transport.observed);Check (($p|ConvertTo-Json -Depth 20)-cnotmatch 'PRIVATE_RAW_SIP_METADATA')
$legacy=Project $null;Check ($legacy.system_observer_failure.Count-eq 8)
foreach($mutation in 'unknown','bool','count','write','transport_key','transport_exit','transport_time','transport_cutoff','transport_json','shape','original_elapsed'){
 $bad=Clone $layer
 switch($mutation){unknown{$bad.raw='PRIVATE'};bool{$bad.runtime_ready='true'};count{$bad.registration_count=20001};write{$bad.no_monitor_collect_reconcile_called=$false};transport_key{$bad.neutral_transport.raw='PRIVATE'};transport_exit{$bad.neutral_transport.native_exit='0'};transport_time{$bad.neutral_transport.elapsed_ms=90001};transport_cutoff{$bad.neutral_transport.cutoff='PRIVATE'};transport_json{$bad.neutral_transport.json_state='PRIVATE'};shape{$bad.sofia_profile_summary.loopback_only='true'};original_elapsed{$bad.original_state_elapsed_ms=90001}}
 $projected=Project $bad;Check ($projected.system_observer_failure.Count-eq 8 -and !$projected.system_observer_failure.ContainsKey('layers'))
}
$assignment=@($a.FindAll({param($n)$n-is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text-ceq '$system'},$true));Check ($assignment.Count-eq 1);$literal=@($assignment[0].Right.FindAll({param($n)$n-is [Management.Automation.Language.StringConstantExpressionAst]},$true));Check ($literal.Count-eq 1);$code=$literal[0].Value
Check ($code.Contains("if(`$parsed.state -ne 'observed' -or `$parsed.available -isnot [bool] -or !`$parsed.available){throw 'The installed SYSTEM observer is unavailable.'}"));Check ($code.Contains('for($attempt=0;$attempt -lt 3;$attempt++)') -and $code.Contains("if(`$parsed.state -ne 'deferred'){break};Start-Sleep -Seconds 2"))
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('health-layers-'+[Guid]::NewGuid().ToString('N'));New-Item -ItemType Directory $tmp|Out-Null
try{
 $security=Join-Path $tmp 'security.ps1';$worker=Join-Path $tmp 'worker.ps1';$php=Join-Path $tmp 'php.ps1';$result=Join-Path $tmp 'result.json';$target=Join-Path $tmp 'system.ps1';$dummy=Join-Path $tmp 'layer.php';$adapter=Join-Path $tmp 'adapter.php';$trace=Join-Path $tmp 'layer.trace'
 [IO.File]::WriteAllText($security,'function Assert-OpenWebHealthSystem{}');[IO.File]::WriteAllText($dummy,'owned-source');[IO.File]::WriteAllText($adapter,'owned-adapter')
 [IO.File]::WriteAllText($worker,'param([switch]$Once);$global:LASTEXITCODE=0;if($env:OPENWEB_LAYER_CASE -ceq "success"){''{"state":"observed","available":true}''}else{''{"state":"observed","available":false}''}')
 [IO.File]::WriteAllText($php,"[IO.File]::AppendAllText('"+$trace+"','1');`$global:LASTEXITCODE=0;'"+($layer|ConvertTo-Json -Depth 20 -Compress)+"'")
 $prepared=$code.Replace('C:\OpenWebPBX\tools\PhoneHealth-Security.ps1',$security).Replace('C:\OpenWebPBX\tools\Phone-Health.ps1',$worker).Replace('C:\OpenWebPBX\php\php.exe',$php).Replace('__RESULT__',$result).Replace('__LAYER__',$dummy).Replace('__LAYER_HASH__',(Get-FileHash $dummy).Hash.ToLowerInvariant()).Replace('__ADAPTER__',$adapter).Replace('__ADAPTER_HASH__',(Get-FileHash $adapter).Hash.ToLowerInvariant()).Replace('__LAYER_OUTPUT__',(Join-Path $tmp 'output.private')).Replace('__LAYER_ERROR__',(Join-Path $tmp 'error.private'))
 [IO.File]::WriteAllText($target,$prepared);$hostPath=(Get-Process -Id $PID).Path
 foreach($case in 'unavailable','success','source_mismatch'){
  Remove-Item -LiteralPath $result,$trace -ErrorAction SilentlyContinue;$env:OPENWEB_LAYER_CASE=$case;if($case-ceq 'source_mismatch'){[IO.File]::WriteAllText($dummy,'changed')}
  $pi=[Diagnostics.ProcessStartInfo]::new();$pi.FileName=$hostPath;$pi.Arguments='-NoProfile -NonInteractive -File "'+$target+'"';$pi.UseShellExecute=$false;$pi.RedirectStandardOutput=$true;$pi.RedirectStandardError=$true;$child=[Diagnostics.Process]::new();$child.StartInfo=$pi
  try{Check ($child.Start());$null=$child.Handle;$stdout=$child.StandardOutput.ReadToEnd();$stderr=$child.StandardError.ReadToEnd();Check ($child.WaitForExit(15000));$exit=$child.ExitCode}finally{$child.Dispose()}
  $r=Get-Content -LiteralPath $result -Raw|ConvertFrom-Json
  if($case-ceq 'success'){Check ($exit-eq 0 -and $r.state-ceq 'passed' -and !(Test-Path $trace))}else{Check ($exit-eq 1 -and $r.state-ceq 'failed' -and $r.phase-ceq 'availability' -and !$r.available -and $r.error_type-ceq 'RuntimeException');if($case-ceq 'unavailable'){Check ($r.layers.schema-eq 1 -and (Get-Content $trace -Raw)-ceq '1')}else{Check ($null-eq $r.layers -and !(Test-Path $trace))}}
 }
}finally{Remove-Item Env:\OPENWEB_LAYER_CASE -ErrorAction SilentlyContinue;Remove-Item -LiteralPath $tmp -Recurse -Force}
[ordered]@{passed=$true;checks=$checks;actual_literal_and_closed_projection=$true;private_process_and_PHP_paths='explicit adapters';native_worker_or_task_executed=$false;original_availability_failure_retained=$true}|ConvertTo-Json -Compress
