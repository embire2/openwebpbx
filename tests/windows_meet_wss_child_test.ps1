# Failure-only actual source/child and closed parent-reader controls; no network/IIS access.
param([string]$Source=(Join-Path $PSScriptRoot 'windows-restore-qualification.ps1'))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest;$script:checks=0;$script:cases=0
function Assert([bool]$Value){if(!$Value){throw ('A WSS child control failed at line '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
function CopyValue($Value){return ConvertFrom-Json -InputObject ($Value|ConvertTo-Json -Depth 16 -Compress) -AsHashtable}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Source,[ref]$tokens,[ref]$errors);Assert ($errors.Count -eq 0)
foreach($name in 'SafeRestoredConferenceWssChildFields','SafeRestoredConferencePathFields','SafeRestoredConferenceFailure','ReadRestoredConferenceFailure'){
 $node=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));Assert ($node.Count -eq 1);. ([scriptblock]::Create($node[0].Extent.Text))
}
$psRecord=@{schema=1;state='failed';producer='windows-meet-wss-path.ps1';error_type='RuntimeException';source_basename='windows-meet-wss-path.ps1';source_line=73;hresult=-2146233087}
$child=@{schema=1;label='before';reason='report_missing';outcome=@{exit_code=1;error_type='Error';code_kind='exit';errno=$null;killed=$false;signal='none';elapsed_ms=12;powershell_state='closed';powershell=$psRecord}}
$base=@{schema=1;state='failed';producer='windows_restored_meeting.py';error_type='RuntimeError';cleanup_verified=$true;source_frames=@(@{source_basename='windows_restored_meeting.py';source_line=123});active_case='native_windows_meeting_browser_start';owned_process_cleanup_failed=$null;owned_processes_closed=$null;meeting_wss_child_failure=@($child)}
$owned=Join-Path ([IO.Path]::GetTempPath()) ('openweb-wss-child-'+[guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Path $owned
try{
 Assert ($null -ne (SafeRestoredConferenceWssChildFields @($child)));Assert ((SafeRestoredConferenceFailure $base).Count -eq 10);$cases++
 foreach($container in 'root','outcome','powershell'){
  $target=switch($container){root{$child}outcome{$child.outcome}powershell{$child.outcome.powershell}}
  foreach($key in $target.Keys){foreach($edit in 'missing','private','wrong'){
   $value=CopyValue $child;$current=switch($container){root{$value}outcome{$value.outcome}powershell{$value.outcome.powershell}}
   switch($edit){missing{$current.Remove($key)}private{$current['raw_private']='PRIVATE PASSWORD SQL URL'}wrong{$current[$key]=@('PRIVATE')}}
   Assert ($null -eq (SafeRestoredConferenceWssChildFields @($value)));$cases++
  }}
 }
 foreach($edit in @(@{exit_code=$true},@{exit_code=4294967296L},@{errno=-2147483649L},@{killed=1},@{elapsed_ms=32001},@{elapsed_ms=1.5},@{powershell_state='absent'},@{powershell=$null},@{signal='PRIVATE'},@{code_kind='PRIVATE'})){
  $value=CopyValue $child;foreach($key in $edit.Keys){$value.outcome[$key]=$edit[$key]};Assert ($null -eq (SafeRestoredConferenceWssChildFields @($value)));$cases++
 }
 foreach($edit in @(@{hresult=$true},@{hresult=2147483648L},@{source_line=0},@{source_line=1000000},@{source_line='73'},@{source_basename='unavailable'})){
  $value=CopyValue $child;foreach($key in $edit.Keys){$value.outcome.powershell[$key]=$edit[$key]};Assert ($null -eq (SafeRestoredConferenceWssChildFields @($value)));$cases++
 }
 foreach($value in @(@(),@($child,$child),@($child,$child,$child))){Assert ($null -eq (SafeRestoredConferenceWssChildFields $value));$cases++}
 foreach($stage in 'unavailable','native_windows_meeting_owner_page','native_windows_meeting_decoded_media'){$value=CopyValue $base;$value.active_case=$stage;Assert ($null -eq (SafeRestoredConferenceFailure $value));$cases++}
 foreach($kind in 'absent','invalid'){$value=CopyValue $child;$value.outcome.powershell_state=$kind;$value.outcome.powershell=$null;Assert ($null -ne (SafeRestoredConferenceWssChildFields @($value)));$cases++}
 $value=CopyValue $child;$value.label='after';$value.outcome.exit_code=4294967295L;$value.outcome.errno=-2147483648L;$value.outcome.elapsed_ms=32000;$value.outcome.powershell.source_basename='unavailable';$value.outcome.powershell.source_line=0;$value.outcome.powershell.hresult=-2147483648L
 $max=CopyValue $base;$max.meeting_wss_child_failure=@($child,$value);$max.source_frames=@($base.source_frames[0])*4
 $pathJson=& node -e "const d=require(process.argv[1]);process.stdout.write(JSON.stringify({before:d.defaults(),after:d.defaults()}));" (Join-Path $PSScriptRoot 'windows-meet-path-diagnostics.cjs');Assert ($LASTEXITCODE -eq 0)
 $max.meeting_path=ConvertFrom-Json -InputObject $pathJson -AsHashtable
 foreach($side in 'before','after'){
  foreach($name in 'backend','frontend','fragmented_backend','fragmented_frontend'){$max.meeting_path[$side][$name].elapsed_ms=6000;$max.meeting_path[$side][$name].status_code=699;$max.meeting_path[$side][$name].large_status_code=699}
  foreach($key in @($max.meeting_path[$side].database.Keys)){if($max.meeting_path[$side].database[$key] -is [int]){$max.meeting_path[$side].database[$key]=512}}
  foreach($name in 'host_http','guest_http'){$max.meeting_path[$side][$name].elapsed_ms=5000;$max.meeting_path[$side][$name].http_status=599}
 }
 Assert ((SafeRestoredConferenceFailure $max).Count -eq 11);$cases++
 $work=Join-Path $owned 'private-output';$null=New-Item -ItemType Directory -Path $work;$path=Join-Path $work 'restored-conference-supplement.out'
 $script:qualificationFailedChild=@{caller='CheckedProcess';label='restored-conference-supplement';completion='exit';exit_code=1}
 $json=$max|ConvertTo-Json -Depth 12 -Compress;Assert ([Text.Encoding]::UTF8.GetByteCount($json) -lt 8192)
 foreach($case in 'valid','valid-bound','duplicate-child','duplicate-ps','private','oversized','malformed'){
  $raw=$json
  switch($case){valid-bound{$raw=$raw.PadRight(8192,' ')}duplicate-child{$raw=$raw.Replace('"elapsed_ms":12','"elapsed_ms":12,"elapsed_ms":12')}duplicate-ps{$raw=$raw.Replace('"source_line":73','"source_line":73,"source_line":73')}private{$copy=CopyValue $max;$copy.meeting_wss_child_failure[0].outcome.password='PRIVATE';$raw=$copy|ConvertTo-Json -Depth 12 -Compress}oversized{$raw=$raw.PadRight(8193,' ')}malformed{$raw='{PRIVATE'}}
  [IO.File]::WriteAllText($path,$raw,[Text.UTF8Encoding]::new($false));$result=ReadRestoredConferenceFailure;Assert (($null -ne $result) -eq ($case -cin @('valid','valid-bound')));$cases++
 }
 # Exact original guards remain positive for8443, while443 refuses before platform/I/O.
 $wss=Join-Path $PSScriptRoot 'windows-meet-wss-path.ps1';$tokens=$null;$errors=$null;$wssAst=[Management.Automation.Language.Parser]::ParseFile($wss,[ref]$tokens,[ref]$errors);Assert ($errors.Count -eq 0)
 foreach($name in 'Assert-MeetWssPathTarget','Assert-MeetWssPathReport','Get-MeetWssPathFailure'){$node=@($wssAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));Assert ($node.Count -eq 1);. ([scriptblock]::Create($node[0].Extent.Text))}
 Assert-MeetWssPathTarget 'windowsqa.example.invalid' 8443;$cases++
 $refused=$false;try{Assert-MeetWssPathTarget 'windowsqa.example.invalid' 443}catch{$refused=$true};Assert $refused;$cases++
 $wssSource=[IO.File]::ReadAllText($wss);$helper=@($wssAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Get-MeetWssPathFailure'},$true))[0].Extent.Text
 $oldSource=$wssSource.Replace($helper+"`n",'');$catchStart=$oldSource.LastIndexOf("}catch{`n try{`n  `$failure=Get-MeetWssPathFailure `$_");Assert ($catchStart -ge 0)
 $oldSource=$oldSource.Substring(0,$catchStart)+"}catch{throw 'The owned WSS path observation could not run completely; inspect its closed report if present.'}`n"
 $sha=[Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($oldSource));Assert ([Convert]::ToHexString($sha).ToLowerInvariant() -ceq '20a8a8fbfdecbda40b6a61d5aa23561adbeb6ac350694c6ff6423bec9135ffbd')
 $oldDirectory=Join-Path $owned 'old';$null=New-Item -ItemType Directory -Path $oldDirectory;$oldWss=Join-Path $oldDirectory 'windows-meet-wss-path.ps1';[IO.File]::WriteAllText($oldWss,$oldSource,[Text.UTF8Encoding]::new($false))
 $shell=(Get-Process -Id $PID).Path
 foreach($tested in @($oldWss,$wss)){
 $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$shell;$start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 foreach($arg in @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$tested,'-Hostname','windowsqa.example.invalid','-Port','443','-ReportPath',(Join-Path $owned 'must-not-exist.json'),'-DisposableHostedRunner')){$start.ArgumentList.Add($arg)}
 $process=[Diagnostics.Process]::Start($start);if(!$process.WaitForExit(10000)){$process.Kill($true);$process.WaitForExit();throw 'Owned early-refusal control timed out.'};$stdout=$process.StandardOutput.ReadToEnd();$stderr=$process.StandardError.ReadToEnd();Assert ($process.ExitCode -ne 0);$process.Dispose()
 if($tested -ceq $oldWss){Assert ([string]::IsNullOrWhiteSpace($stdout))}else{
 $value=ConvertFrom-Json -InputObject $stdout -AsHashtable;Assert ($value.Count -eq 7 -and $value.state -ceq 'failed' -and $value.error_type -ceq 'RuntimeException' -and $value.source_basename -ceq 'windows-meet-wss-path.ps1' -and $value.source_line -gt 0 -and $value.hresult -eq -2146233087);Assert (!(Test-Path -LiteralPath (Join-Path $owned 'must-not-exist.json')));Assert ($stderr.Contains('The owned WSS path observation could not run completely'));$cases++
 }
 }
}finally{Remove-Item -LiteralPath $owned -Recurse -Force}
Assert (!(Test-Path -LiteralPath $owned))
@{schema=1;state='passed';cases=$cases;checks=$checks;actual_closed_nonzero_child=$true;actual_nested_reader_files=$true;network_or_iis_called=$false;owned_fixture_removed=$true}|ConvertTo-Json -Compress
