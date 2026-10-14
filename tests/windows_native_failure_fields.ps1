# Bounded actual caller allowlist controls. No Windows/PBX runtime is invoked.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-suite.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The reviewed caller must parse.'}
$nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'SafeFailureFields'},$true))
if($nodes.Count -ne 1){throw 'The actual caller allowlist must be uniquely identified.'}
Invoke-Expression $nodes[0].Extent.Text
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
Write-Output "PASS $checks actual caller native primary/cleanup/privacy allowlist checks; no PBX contacted"
