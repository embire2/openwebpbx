#Requires -Version 7.4
[CmdletBinding()]param([string]$SourceRoot)
# Portable actual-source checks, real owned JSON-comparison children, fictional
# task rows. No Scheduler, installed services, customer data or network access.
$ErrorActionPreference='Stop';$checks=0;$children=0
if(!$SourceRoot){$SourceRoot=Split-Path $PSScriptRoot -Parent}
function Must([bool]$Value){$script:checks++;if(!$Value){throw ('Task observation control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)}}
$testPython=(Get-Command python3 -CommandType Application -ErrorAction Stop|Select-Object -First 1).Source
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-updater-qualification.ps1'),[ref]$tokens,[ref]$errors)
Must (@($errors).Count -eq 0)
$names=@('Check','WriteJson','CheckedProcess','QualificationFailureObservation','QualificationComparisonFields','QualificationComparisonDetails','QualificationTaskDifference','QualificationTaskDifferenceFields','Equal','EqualTaskSnapshots','NormalTaskPreservation')
$defs=@{}
foreach($name in $names){$nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));Must ($nodes.Count -eq 1);$defs[$name]=$nodes[0].Extent.Text}
$taskNode=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'TaskSnapshot'},$true));Must ($taskNode.Count -eq 1)
$owned=@('OpenWebPBX-Backups','OpenWebPBX-Cleanup','OpenWebPBX-Updater-Restart','OpenWebPBX Outgoing Mail','OpenWebPBX-TenantDomains','OpenWebPBX-PhoneHealth','OpenWebPBX Certificate Renewal','OpenWebPBX Pending Phone Certificate')
foreach($name in $owned){Must ($taskNode[0].Extent.Text.Contains("'"+$name+"'") -and $defs.QualificationTaskDifference.Contains("'"+$name+"'") -and $defs.QualificationTaskDifferenceFields.Contains("'"+$name+"'"))}
Must ($defs.Equal.Contains("@('-I','-B',(Join-Path `$PSScriptRoot 'windows-compare-json.py'),`$a,`$b)"))
Must ($defs.NormalTaskPreservation.Contains("if(`$name -in 'OpenWebPBX-Backups','OpenWebPBX Outgoing Mail','OpenWebPBX-TenantDomains')"))
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('OpenWebTaskObservation-'+[guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Path $temporary
$sensitive='PRIVATE_TASK_SQL_password_XML_SDDL_credential'
$original='<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><RegistrationInfo><Date>2026-01-01T00:00:00</Date><Author>PRIVATE_TASK_SQL_password_XML_SDDL_credential</Author></RegistrationInfo><Triggers><TimeTrigger><StartBoundary>2026-01-01T00:00:00</StartBoundary><Repetition><Interval>PT1M</Interval></Repetition></TimeTrigger></Triggers><Actions><Exec><Command>PRIVATE_TASK_SQL_password_XML_SDDL_credential</Command></Exec></Actions><Settings><Enabled>true</Enabled></Settings></Task>'
$originalBoundary=[DateTime]::UtcNow.AddMinutes(1).ToString('o');$original=$original.Replace('2026-01-01T00:00:00',$originalBoundary)
function Row {return @{exists=$true;enabled=$true;xml=$original;acl=$sensitive}}
function CopyRows($Value){return $Value|ConvertTo-Json -Depth 32|ConvertFrom-Json -AsHashtable}
function Safe($Value){$text=$Value|ConvertTo-Json -Depth 16 -Compress;Must (!$text.Contains($sensitive) -and !$text.Contains($temporary) -and !$text.Contains('StartBoundary') -and !$text.Contains('<Task'))}
function Observe($Caught){
 Must ($null -ne $Caught -and $Caught.Exception.Message -ceq 'A private qualification operation failed; its streams remain private.')
 $value=QualificationFailureObservation $Caught.ScriptStackTrace $script:qualificationFailedChild $script:qualificationComparisonFailure
 Must ($value.child.label -ceq 'compare-normal-task-contract-security' -and $value.child.exit_code -eq 1 -and $value.comparison.comparison_result -ceq 'different');Safe $value;return $value
}
try{
 $script:work=Join-Path $temporary 'streams';$null=New-Item -ItemType Directory -Path $work;$script:source=$temporary
 $fixture=Join-Path $temporary 'windows-updater-qualification.ps1';$body=$defs.Equal.Replace('"$root\backup-runtime\python.exe"','$script:testPython')
 Must ($body -cne $defs.Equal -and $body.Replace('$script:testPython','"$root\backup-runtime\python.exe"') -ceq $defs.Equal)
 Copy-Item -LiteralPath (Join-Path $SourceRoot 'tests/windows-compare-json.py') -Destination (Join-Path $temporary 'windows-compare-json.py')
 Must ((Get-FileHash (Join-Path $temporary 'windows-compare-json.py')).Hash -ceq (Get-FileHash (Join-Path $SourceRoot 'tests/windows-compare-json.py')).Hash)
 [IO.File]::WriteAllText($fixture,((@($names|Where-Object {$_ -cne 'Equal'}|ForEach-Object {$defs[$_]})+@($body)) -join "`n"));. $fixture
 $started=[DateTime]::UtcNow.AddSeconds(-5)
 # Exact actual normalizer and comparator accept original rows without report.
 $before=@{};foreach($name in $owned){$before[$name]=Row};$originalBefore=$before|ConvertTo-Json -Depth 32 -Compress
 NormalTaskPreservation $before (CopyRows $before) $started;$children++
 Must ($null -eq $script:qualificationComparisonFailure -and $null -eq $script:qualificationFailedChild)
 # Every owned name and actual field passes through the original strict failure.
 foreach($name in $owned){foreach($field in 'enabled','xml','acl'){
  $after=CopyRows $before
  switch($field){'enabled'{$after[$name].enabled=$false};'xml'{$after[$name].xml=$after[$name].xml.Replace('<Command>','<Command>changed-')};'acl'{$after[$name].acl='changed-'+$sensitive}}
  $caught=$null;try{NormalTaskPreservation $before $after $started}catch{$caught=$_};$children++
  $report=Observe $caught;$detail=$report.task_difference
  Must ($detail.Count -eq 6 -and $detail.schema -eq 1 -and $detail.before_tasks -eq 8 -and $detail.after_tasks -eq 8 -and $detail.changed_tasks -eq 1 -and $detail.unknown_tasks -eq 0 -and $detail.known_tasks.Count -eq 1)
  Must ($detail.known_tasks[$name].Count -eq 1 -and $detail.known_tasks[$name][0] -ceq $field)
  Must (($before|ConvertTo-Json -Depth 32 -Compress) -ceq $originalBefore)
 }}
 $valid=CopyRows $report.task_difference;$validComparison=CopyRows $script:qualificationComparisonFailure;$validTrace=$caught.ScriptStackTrace;$validChild=$script:qualificationFailedChild.Clone()
 # The proposed timestamp cause is only a fixture possibility. Preserve refusal.
 $after=CopyRows $before;$after['OpenWebPBX-PhoneHealth'].xml=$original.Replace($originalBoundary,[DateTime]::UtcNow.AddSeconds(90).ToString('o'))
 $caught=$null;try{NormalTaskPreservation $before $after $started}catch{$caught=$_};$children++
 $report=Observe $caught;Must ($report.task_difference.known_tasks['OpenWebPBX-PhoneHealth'][0] -ceq 'xml')
 # Known/unknown names and presence changes: only closed identifiers leave the observer.
 $left=@{'OpenWebPBX-PhoneHealth'=(Row);'OpenWebPBX-Cleanup'=(Row);$sensitive=(Row)}
 $right=CopyRows $left;$right['OpenWebPBX-PhoneHealth']=@{exists=$false};$right.Remove('OpenWebPBX-Cleanup');$right['OpenWebPBX-Backups']=Row;$right[$sensitive].acl='new-'+$sensitive
 $detail=QualificationTaskDifference $left $right;Safe $detail
 Must ($detail.changed_tasks -eq 4 -and $detail.unknown_tasks -eq 1 -and $detail.known_tasks.Count -eq 3)
 Must ([string]::Join(',',$detail.known_tasks['OpenWebPBX-PhoneHealth']) -ceq 'exists,enabled,xml,acl')
 Must ($detail.known_tasks['OpenWebPBX-Cleanup'][0] -ceq 'removed' -and $detail.known_tasks['OpenWebPBX-Backups'][0] -ceq 'added')
 Must ($null -eq (QualificationTaskDifference $left (CopyRows $left)))
 # Strict protocol validation, independent of the in-memory producer.
 foreach($case in 'schema_string','schema_bool','schema_other','extra','missing','negative','large','bool_count','string_count','zero','sum','task_name','task_case','map_type','array_type','empty','field_name','duplicate','unordered','mixed_added','mixed_removed'){
  $row=CopyRows $valid;$name=$owned[-1]
  switch($case){
   'schema_string'{$row.schema='1'};'schema_bool'{$row.schema=$true};'schema_other'{$row.schema=2};'extra'{$row[$sensitive]=$sensitive};'missing'{$row.Remove('schema')}
   'negative'{$row.before_tasks=-1};'large'{$row.after_tasks=65};'bool_count'{$row.changed_tasks=$true};'string_count'{$row.unknown_tasks='0'};'zero'{$row.changed_tasks=0};'sum'{$row.changed_tasks=2}
   'task_name'{$row.known_tasks=@{$sensitive=@('xml')}};'task_case'{$row.known_tasks=@{'openwebpbx pending phone certificate'=@('xml')}};'map_type'{$row.known_tasks=@()}
   'array_type'{$row.known_tasks[$name]='xml'};'empty'{$row.known_tasks[$name]=@()};'field_name'{$row.known_tasks[$name]=@($sensitive)};'duplicate'{$row.known_tasks[$name]=@('xml','xml')}
   'unordered'{$row.known_tasks[$name]=@('acl','xml')};'mixed_added'{$row.known_tasks[$name]=@('added','xml')};'mixed_removed'{$row.known_tasks[$name]=@('removed','acl')}
  }
  Must ($null -eq (QualificationTaskDifferenceFields $row))
  $comparison=CopyRows $validComparison;$comparison.task=$row
  $projected=QualificationFailureObservation $validTrace $validChild $comparison
  Must (!$projected.ContainsKey('task_difference') -and $projected.comparison.comparison_result -ceq 'different');Safe $projected
 }
 # Malformed source rows do not produce guessed facts or change any comparison.
 foreach($case in 'top_type','too_many','unknown_field','row_array','exists_missing','exists_string','false_extra','enabled_string','xml_number','acl_number','xml_oversized','acl_oversized','name_oversized'){
  $left=@{'OpenWebPBX-PhoneHealth'=(Row)};$right=CopyRows $left;$right['OpenWebPBX-PhoneHealth'].xml+='changed'
  switch($case){
   'top_type'{$left=@()};'too_many'{1..65|ForEach-Object {$left['custom'+$_]=Row}};'unknown_field'{$left['OpenWebPBX-PhoneHealth'][$sensitive]=$sensitive}
   'row_array'{$left['OpenWebPBX-PhoneHealth']=@()};'exists_missing'{$left['OpenWebPBX-PhoneHealth'].Remove('exists')};'exists_string'{$left['OpenWebPBX-PhoneHealth'].exists='true'}
   'false_extra'{$left['OpenWebPBX-PhoneHealth'].exists=$false};'enabled_string'{$left['OpenWebPBX-PhoneHealth'].enabled='true'};'xml_number'{$left['OpenWebPBX-PhoneHealth'].xml=12};'acl_number'{$left['OpenWebPBX-PhoneHealth'].acl=12}
   'xml_oversized'{$left['OpenWebPBX-PhoneHealth'].xml='x'*1048577};'acl_oversized'{$left['OpenWebPBX-PhoneHealth'].acl='x'*65537};'name_oversized'{$left[('x'*257)]=Row}
  }
  Must ($null -eq (QualificationTaskDifference $left $right))
 }
 # Cross-label, missing-callsite, stale/equal/error/deadline evidence cannot qualify task fields.
 foreach($case in 'old_label','unknown_label','child_label','no_normal','no_task','no_equal','equal','error','deadline','wrong_exit'){
  $comparison=CopyRows $validComparison;$child=$validChild.Clone();$trace=$validTrace
  switch($case){
   'old_label'{$comparison.label='normal-tasks';$child.label='compare-normal-tasks'};'unknown_label'{$comparison.label=$sensitive;$child.label='compare-'+$sensitive};'child_label'{$child.label='compare-normal-tasks'}
   'no_normal'{$trace=($trace -split "`n"|Where-Object {$_ -notmatch '^at NormalTaskPreservation,'}) -join "`n"};'no_task'{$trace=($trace -split "`n"|Where-Object {$_ -notmatch '^at EqualTaskSnapshots,'}) -join "`n"};'no_equal'{$trace=($trace -split "`n"|Where-Object {$_ -notmatch '^at Equal,'}) -join "`n"}
   'equal'{$comparison.report=@{comparison_result='equal';comparison_stage='compare'}};'error'{$comparison.report=@{comparison_result='error';comparison_stage='parse_after';comparison_error_type='JSONDecodeError'};$child.exit_code=2}
   'deadline'{$child.completion='deadline';$child.exit_code=$null};'wrong_exit'{$child.exit_code=7}
  }
  $projected=QualificationFailureObservation $trace $child $comparison;Must (!$projected.ContainsKey('task_difference'));Safe $projected
 }
 # A task observer failure cannot replace or suppress the actual child's refusal.
 $realObserver=(Get-Item Function:QualificationTaskDifference).ScriptBlock
 try{
  function QualificationTaskDifference {throw $sensitive}
  $after=CopyRows $before;$after['OpenWebPBX-PhoneHealth'].acl='new'
  $caught=$null;try{NormalTaskPreservation $before $after $started}catch{$caught=$_};$children++
  $projected=Observe $caught;Must (!$projected.ContainsKey('task_difference'))
 }finally{Set-Item Function:QualificationTaskDifference $realObserver}
 # Original failure object survives even when this failure-only observer throws.
 $realChecked=(Get-Item Function:CheckedProcess).ScriptBlock;$script:primary=[InvalidOperationException]::new('PRIMARY private child failure')
 try{
  function CheckedProcess([string]$Executable,[string[]]$Arguments,[string]$Label){
   $script:qualificationFailedChild=@{caller='CheckedProcess';label=$Label;completion='exit';exit_code=1}
   $record=@{schema=1;producer='windows-exact-json-comparison'}+$validComparison.report
   WriteJson (Join-Path $work ($Label+'.out')) $record;throw $script:primary
  }
  function QualificationTaskDifference {throw $sensitive}
  $caught=$null;try{Equal @{} @{} 'normal-task-contract-security'}catch{$caught=$_}
  Must ([object]::ReferenceEquals($caught.Exception,$script:primary))
 }finally{Set-Item Function:CheckedProcess $realChecked;Set-Item Function:QualificationTaskDifference $realObserver}
 # Successful comparison never invokes the observer and clears stale state.
 try{
  function QualificationTaskDifference {throw $sensitive}
  NormalTaskPreservation $before (CopyRows $before) $started;$children++
  Must ($null -eq $script:qualificationComparisonFailure -and $null -eq $script:qualificationFailedChild)
 }finally{Set-Item Function:QualificationTaskDifference $realObserver}
}finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Recurse -Force}}
Must (!(Test-Path -LiteralPath $temporary))
@{schema=1;state='passed';actual_source_controls=$checks;real_owned_comparison_children=$children;fixture_binding='installed Python executable path only; fictional task rows';native_scheduler_or_services_or_network=$false;raw_task_values_projected=$false}|ConvertTo-Json -Compress
