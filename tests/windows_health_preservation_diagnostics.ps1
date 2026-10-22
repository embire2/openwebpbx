# QA-only digest diagnostics: no SQL connection, task, service or firewall action.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent),[string]$ObservedBefore,[string]$ObservedAfter)
$ErrorActionPreference='Stop';$checks=0
function Check([bool]$Value){$script:checks++;if(!$Value){throw ('Health preservation diagnostic control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)}}
foreach($pair in @(@('tests/windows_phone_health_acceptance.ps1','HealthPreservationDifference'),@('tests/windows-suite.ps1','SafePhoneHealthFailure'))){
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot $pair[0]),[ref]$tokens,[ref]$errors);Check ($errors.Count -eq 0)
 $nodes=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $pair[1]},$true));Check ($nodes.Count -eq 1);Invoke-Expression $nodes[0].Extent.Text
}
function CloneSnapshot($Value){return ($Value|ConvertTo-Json -Depth 12 -Compress)|ConvertFrom-Json}
function Project($Difference){return SafePhoneHealthFailure ([pscustomobject]@{schema=1;producer='windows_phone_health_acceptance.ps1';state='failed';gates=@{};native_worker_preservation_failure=$Difference})}
$before=CloneSnapshot @{state='observed';public_preservation_sha256=('a'*64);namespace_sha256=('b'*64);tables=2;complete_public_rows=$true;complete_namespace_inventory=$true;objects=@{v_pbx_phone_health_state=@{kind='r';shape_sha256=('c'*64);data_sha256=('d'*64);rows=1};v_user_logs=@{kind='r';shape_sha256=('e'*64);data_sha256=('f'*64);rows=3}}}
$same=HealthPreservationDifference $before (CloneSnapshot $before)
Check ($same.snapshot_valid -and !$same.namespace_changed -and !$same.inventory_changed -and !$same.global_digest_changed -and $same.changed_objects.Count -eq 0)
foreach($case in 'namespace','health_rows','other_rows','shape','inventory','count'){
 $after=CloneSnapshot $before;$after.public_preservation_sha256='0'*64
 switch($case){
  'namespace'{$after.namespace_sha256='1'*64}
  'health_rows'{$after.objects.v_pbx_phone_health_state.data_sha256='1'*64}
  'other_rows'{$after.objects.v_user_logs.data_sha256='1'*64;$after.objects.v_user_logs.rows=4}
  'shape'{$after.objects.v_user_logs.shape_sha256='1'*64}
  'inventory'{$after.objects.PSObject.Properties.Remove('v_user_logs')}
  'count'{$after.tables=3}
 }
 $difference=HealthPreservationDifference $before $after;Check ($difference.snapshot_valid -and $difference.global_digest_changed)
 switch($case){
  'namespace'{Check ($difference.namespace_changed -and $difference.data_changed_count -eq 0)}
  'health_rows'{Check ($difference.data_changed_count -eq 1 -and $difference.changed_objects[0].name -ceq 'v_pbx_phone_health_state' -and $difference.changed_objects[0].data_changed)}
  'other_rows'{Check ($difference.data_changed_count -eq 1 -and $difference.changed_objects[0].row_count_changed)}
  'shape'{Check ($difference.shape_changed_count -eq 1 -and $difference.changed_objects[0].shape_changed)}
  'inventory'{Check ($difference.inventory_changed -and $difference.object_count_after -eq 1)}
  'count'{Check $difference.table_count_changed}
 }
 $projected=Project (CloneSnapshot $difference);Check ($projected.ContainsKey('native_worker_preservation_failure'))
 Check (($projected|ConvertTo-Json -Depth 8 -Compress) -cnotmatch 'sha256|schema_owner|source_address|row_value')
}
foreach($field in 'state','public_preservation_sha256','namespace_sha256','tables','complete_public_rows','complete_namespace_inventory','objects'){
 $bad=CloneSnapshot $before;$bad.$field=$null;Check (!(HealthPreservationDifference $bad $before).snapshot_valid)
}
$difference=HealthPreservationDifference $before $before
foreach($name in 'snapshot_valid','namespace_changed','inventory_changed','table_count_changed','global_digest_changed'){$bad=CloneSnapshot $difference;$bad.$name='true';Check (!(Project $bad).ContainsKey('native_worker_preservation_failure'))}
foreach($name in 'shape_changed_count','data_changed_count','object_count_before','object_count_after'){foreach($value in -1,10001,'1',$true){$bad=CloneSnapshot $difference;$bad.$name=$value;Check (!(Project $bad).ContainsKey('native_worker_preservation_failure'))}}
$difference.changed_objects=@(@{name='v_user_logs';shape_changed=$false;data_changed=$true;row_count_changed=$false})
foreach($name in 'name','shape_changed','data_changed','row_count_changed'){
 $bad=CloneSnapshot $difference;$bad.changed_objects[0].$name=if($name -ceq 'name'){'PRIVATE-ROW-OR-OWNER'}else{'true'}
 Check (!(Project $bad).ContainsKey('native_worker_preservation_failure'))
}
$bad=CloneSnapshot $difference;$bad|Add-Member NoteProperty private_row 'DO-NOT-PUBLISH';$bad.changed_objects[0]|Add-Member NoteProperty private_source 'DO-NOT-PUBLISH'
Check (((Project $bad)|ConvertTo-Json -Depth 8 -Compress) -notmatch 'DO-NOT-PUBLISH|private_row|private_source')
if($ObservedBefore -or $ObservedAfter){
 Check ($ObservedBefore -and $ObservedAfter)
 $a=Get-Content -LiteralPath $ObservedBefore -Raw|ConvertFrom-Json;$b=Get-Content -LiteralPath $ObservedAfter -Raw|ConvertFrom-Json
 $observed=HealthPreservationDifference $a $b
 Check ($observed.snapshot_valid -and !$observed.namespace_changed -and !$observed.inventory_changed -and !$observed.global_digest_changed -and !$observed.table_count_changed -and $observed.shape_changed_count -eq 0 -and $observed.data_changed_count -eq 0)
}
Write-Output ('PASS '+$checks+' actual digest/projection and causal category controls; SQL/native acceptance is recorded separately')
