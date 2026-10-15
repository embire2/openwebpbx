# Bounded actual caller allowlist controls. No Windows/PBX runtime is invoked.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-suite.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The reviewed caller must parse.'}
$nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'SafeFailureFields'},$true))
if($nodes.Count -ne 1){throw 'The actual caller allowlist must be uniquely identified.'}
Invoke-Expression $nodes[0].Extent.Text
$nativeAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-native-acceptance.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The reviewed native hook must parse.'}
$mediaNodes=@($nativeAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'CompletedMediaCases'},$true))
if($mediaNodes.Count -ne 1){throw 'The actual completed-media filter must be uniquely identified.'}
Invoke-Expression $mediaNodes[0].Extent.Text
$failureNodes=@($nativeAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'MediaFailureFields'},$true))
if($failureNodes.Count -ne 1){throw 'The actual native media failure filter must be uniquely identified.'}
Invoke-Expression $failureNodes[0].Extent.Text
$checks=0
function Check([bool]$Value){if(!$Value){throw 'The bounded native failure field check failed.'};$script:checks++}
$record=[pscustomobject]@{
 active_case='independent_g729_pcmu_transcoding';error_type='AssertionError';source_basename='pbx_v20_restore_native.py';source_line=236
 primary_substage='g729_peer_receiver';primary_error_type='AssertionError';primary_source_basename='windows-native-acceptance.py';primary_source_line=384;primary_caller_basename='windows-native-acceptance.py';primary_caller_line=653
 cleanup_substage='g729_alternate_unregister';cleanup_error_type='RuntimeError';cleanup_source_basename='pbx_v20_restore_native.py';cleanup_source_line=236;cleanup_caller_basename='windows-native-acceptance.py';cleanup_caller_line=661;cleanup_failure_count=2
 password='private-never-copy';error='private-never-copy';native_packets='private-never-copy'
}
$safe=SafeFailureFields $record
foreach($field in 'primary_substage','primary_error_type','primary_source_basename','primary_source_line','primary_caller_basename','primary_caller_line','cleanup_substage','cleanup_error_type','cleanup_source_basename','cleanup_source_line','cleanup_caller_basename','cleanup_caller_line','cleanup_failure_count'){Check ($safe[$field] -eq $record.$field)}
Check (!$safe.ContainsKey('password') -and !$safe.ContainsKey('error') -and !$safe.ContainsKey('native_packets'))
foreach($prefix in 'primary','cleanup'){
 $copy=$record.PSObject.Copy();$copy.($prefix+'_substage')='secret-shaped-unknown-stage';$filtered=SafeFailureFields $copy
 Check (!$filtered.ContainsKey($prefix+'_substage') -and !$filtered.ContainsKey($prefix+'_error_type') -and !$filtered.ContainsKey($prefix+'_source_basename'))
 $copy=$record.PSObject.Copy();$copy.($prefix+'_error_type')='secret message with spaces';Check (!(SafeFailureFields $copy).ContainsKey($prefix+'_error_type'))
 foreach($where in 'source','caller'){
  $copy=$record.PSObject.Copy();$copy.($prefix+'_'+$where+'_basename')='secret-file-name';Check (!(SafeFailureFields $copy).ContainsKey($prefix+'_'+$where+'_basename'))
  $copy=$record.PSObject.Copy();$copy.($prefix+'_'+$where+'_line')='384';Check (!(SafeFailureFields $copy).ContainsKey($prefix+'_'+$where+'_line'))
  $copy=$record.PSObject.Copy();$copy.($prefix+'_'+$where+'_line')=100000;Check (!(SafeFailureFields $copy).ContainsKey($prefix+'_'+$where+'_line'))
 }
}
foreach($bad in '2',0,33,$true){$copy=$record.PSObject.Copy();$copy.cleanup_failure_count=$bad;Check (!(SafeFailureFields $copy).ContainsKey('cleanup_failure_count'))}
$allowed=@('native_tls_signalling_two_way_decoded_rtp','native_g729_pcmu_independent_codec_two_way_transcoding','native_simultaneous_ring_group','native_hunting_ring_group','native_queue_agent_first')
$childChecks=@(foreach($name in $allowed){[pscustomobject]@{case=$name;passed=$true;password='private-never-copy';decoded_ratio=.99;error='private-never-copy'}})
$completed=@(CompletedMediaCases $childChecks)
Check (($completed -join '|') -ceq ($allowed -join '|'))
foreach($name in $allowed){
 foreach($bad in $false,'true',1,$null){Check (@(CompletedMediaCases @([pscustomobject]@{case=$name;passed=$bad})).Count -eq 0)}
}
foreach($bad in 'private-never-copy',$allowed[0].ToUpperInvariant(),($allowed[0]+' '),($allowed[0]+'_secret'),1,$true,@($allowed[0]),[pscustomobject]@{value=$allowed[0]}){
 Check (@(CompletedMediaCases @([pscustomobject]@{case=$bad;passed=$true})).Count -eq 0)
}
Check (@(CompletedMediaCases @([pscustomobject]@{case=$allowed[0]},$null,'private-never-copy')).Count -eq 0)
Check ((@(CompletedMediaCases @($childChecks[0],$childChecks[0])) -join '|') -ceq $allowed[0])
$partial=[pscustomobject]@{completed_media_cases=$completed;checks=$childChecks;password='private-never-copy';metrics=@{private='private-never-copy'}}
$filtered=SafeFailureFields $partial
Check ($filtered.Count -eq 1 -and ($filtered.completed_media_cases -join '|') -ceq ($allowed -join '|'))
Check (($filtered|ConvertTo-Json -Depth 8) -notmatch 'private-never-copy|decoded_ratio|password|metrics')
foreach($bad in 'private-never-copy',$allowed[0].ToUpperInvariant(),($allowed[0]+' '),($allowed[0]+'_secret'),1,$true,@($allowed[0]),[pscustomobject]@{case=$allowed[0];passed=$true}){
 $invalid=[pscustomobject]@{completed_media_cases=[object[]]::new(1)};$invalid.completed_media_cases[0]=$bad
 Check (!(SafeFailureFields $invalid).ContainsKey('completed_media_cases'))
}
$mixed=SafeFailureFields ([pscustomobject]@{completed_media_cases=@('private-never-copy',$allowed[4],$allowed[4],$allowed[0]);checks=$childChecks})
Check (($mixed.completed_media_cases -join '|') -ceq ($allowed[0]+'|'+$allowed[4]) -and $mixed.Count -eq 1)
Check (!(SafeFailureFields ([pscustomobject]@{checks=$childChecks})).ContainsKey('completed_media_cases'))
$media=[pscustomobject]@{media_peer='caller';media_direction='received';media_window_seconds=5.0;media_span_seconds=4.98;media_rate_pps=49.9;media_packets=250;media_window_private='private-never-copy';password='private-never-copy';decoded_pcm='private-never-copy'}
foreach($filter in 'MediaFailureFields','SafeFailureFields'){
 $safe=& $filter $media
 Check ($safe.Count -eq 6 -and ($safe|ConvertTo-Json) -notmatch 'private-never-copy|password|decoded_pcm|media_window_private')
 foreach($field in 'media_peer','media_direction','media_window_seconds','media_span_seconds','media_rate_pps','media_packets'){Check ($safe[$field] -ceq $media.$field)}
 foreach($field in 'media_peer','media_direction'){
  foreach($bad in 'secret-shaped-value',$media.$field.ToUpperInvariant(),1,$true,$null){$copy=$media.PSObject.Copy();$copy.$field=$bad;Check ((& $filter $copy).Count -eq 0)}
 }
 foreach($field in 'media_window_seconds','media_span_seconds','media_rate_pps'){
  foreach($bad in '5',$true,[double]::NaN,[double]::PositiveInfinity,[double]::NegativeInfinity,-1,1000001){$copy=$media.PSObject.Copy();$copy.$field=$bad;Check (!(& $filter $copy).ContainsKey($field))}
 }
 foreach($bad in '250',$true,1.5,-1,1000001){$copy=$media.PSObject.Copy();$copy.media_packets=$bad;Check (!(& $filter $copy).ContainsKey('media_packets'))}
 foreach($pair in @(@('media_window_seconds',.49),@('media_window_seconds',10.01),@('media_span_seconds',11.01),@('media_rate_pps',100000.01))){$copy=$media.PSObject.Copy();$copy.($pair[0])=$pair[1];Check (!(& $filter $copy).ContainsKey($pair[0]))}
}
Write-Output "PASS $checks actual caller native primary/cleanup/completed-media privacy allowlist checks; no PBX contacted"
