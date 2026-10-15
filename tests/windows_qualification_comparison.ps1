#Requires -Version 7.4
[CmdletBinding()]param([string]$SourceRoot)
# Exact qualification/comparator source, real owned Python children and private
# snapshots only. No installed product, Windows service, task or network access.
$ErrorActionPreference='Stop';$checks=0;$children=0
if(!$SourceRoot){$SourceRoot=Split-Path $PSScriptRoot -Parent}
function Verify([bool]$Value){$script:checks++;if(!$Value){throw ('Qualification comparison control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)}}
$pythonCommand=if($env:OPENWEB_TEST_PYTHON){Get-Command $env:OPENWEB_TEST_PYTHON -ErrorAction Stop}else{Get-Command python3,python -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1}
if(!$pythonCommand){@{schema=1;state='skipped';reason='Python runtime unavailable'}|ConvertTo-Json -Compress;exit 0}
$testPython=$pythonCommand.Source
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-updater-qualification.ps1'),[ref]$tokens,[ref]$errors)
Verify (@($errors).Count -eq 0)
$definitions=@{}
foreach($name in 'Check','Hash','WriteJson','CheckedProcess','QualificationComparisonFields','QualificationComparisonDetails','QualificationFailureObservation','Equal'){
 $nodes=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true))
 Verify ($nodes.Count -eq 1);$definitions[$name]=$nodes[0].Extent.Text
}
$other=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-upgrade-acceptance.ps1'),[ref]$tokens,[ref]$errors)
Verify (@($errors).Count -eq 0)
$original=@($other.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'ComparisonFields'},$true))
Verify ($original.Count -eq 1 -and $definitions.QualificationComparisonFields -ceq $original[0].Extent.Text.Replace('function ComparisonFields(','function QualificationComparisonFields('))
Verify ($definitions.Equal.Contains("@('-I','-B',(Join-Path `$PSScriptRoot 'windows-compare-json.py'),`$a,`$b)"))
Verify (!$definitions.Equal.Contains("'-c'") -and !$definitions.Equal.Contains('Remove(') -and !$definitions.Equal.Contains('Normalize'))
Verify ($definitions.CheckedProcess.Contains('$process.WaitForExit($Timeout)') -and $definitions.CheckedProcess.Contains('[int]$Timeout=2400000') -and !$definitions.CheckedProcess.Contains('.Kill('))
Verify ($ast.Extent.Text.Contains('$facts.failure_observation=QualificationFailureObservation $_.ScriptStackTrace $script:qualificationFailedChild $script:qualificationComparisonFailure'))
$sensitive='PRIVATE_SENTINEL_password_key_SDDL_S-1-5-21_customer_row'
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('OpenWebComparison-'+$sensitive+'-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $temporary
function Record([string]$Acl='original',[string]$Digest='same',[long]$Bytes=10){return @{directory=$false;acl=$Acl;sha256=$Digest;bytes=$Bytes}}
function JsonCopy($Value){return $Value|ConvertTo-Json -Depth 32|ConvertFrom-Json -AsHashtable}
function Observe($Caught){
 Verify ($null -ne $Caught -and $Caught.Exception.Message -ceq 'A private qualification operation failed; its streams remain private.')
 $report=QualificationFailureObservation $Caught.ScriptStackTrace $script:qualificationFailedChild $script:qualificationComparisonFailure
 Verify ($report.child.completion -ceq 'exit' -and $report.callsites.function -ccontains 'Equal')
 $text=$report|ConvertTo-Json -Depth 16 -Compress
 Verify (!$text.Contains($sensitive) -and !$text.Contains($temporary) -and !$text.Contains('S-1-5-21'))
 return $report
}
try{
 $script:work=Join-Path $temporary 'private-streams';$null=New-Item -ItemType Directory -Path $work
 $script:source=$temporary
 Copy-Item -LiteralPath (Join-Path $SourceRoot 'tests/windows-compare-json.py') -Destination (Join-Path $temporary 'windows-compare-json.py')
 Verify ((Get-FileHash (Join-Path $temporary 'windows-compare-json.py')).Hash -ceq (Get-FileHash (Join-Path $SourceRoot 'tests/windows-compare-json.py')).Hash)
 $fixture=Join-Path $temporary 'windows-updater-qualification.ps1'
 # The sole source binding replaces the fixed installed Python executable.
 # The actual static comparator is copied byte-exact beside these definitions.
 $equalBody=$definitions.Equal.Replace('"$root\backup-runtime\python.exe"','$script:testPython')
 Verify ($equalBody -cne $definitions.Equal -and $equalBody.Replace('$script:testPython','"$root\backup-runtime\python.exe"') -ceq $definitions.Equal)
 [IO.File]::WriteAllText($fixture,((@('Check','Hash','WriteJson','CheckedProcess','QualificationComparisonFields','QualificationComparisonDetails','QualificationFailureObservation'|ForEach-Object {$definitions[$_]})+@($equalBody)) -join "`n"))
 . $fixture
 $before=@{'C:\OpenWebPBX\web\private.php'=(Record $sensitive);'C:\ProgramData\OpenWebPBX\runtime.json'=(Record 'same');'C:\OpenWebPBX\desktop\manager.exe'=(Record 'same')}
 $beforeJson=$before|ConvertTo-Json -Depth 32 -Compress
 # Real equality, reordered dictionaries and cross-type roundtrip stay accepted.
 $script:qualificationComparisonFailure=@{label=$sensitive;report=$sensitive}
 $output=@(Equal $before (JsonCopy $before) 'fault-files');$children++
 Verify ($output.Count -eq 0 -and $null -eq $script:qualificationComparisonFailure -and $null -eq $script:qualificationFailedChild)
 $reverse=@{};foreach($key in @($before.Keys|Sort-Object -Descending)){$reverse[$key]=[pscustomobject]$before[$key]}
 Equal $before $reverse 'fault-files';$children++
 Verify (($before|ConvertTo-Json -Depth 32 -Compress) -ceq $beforeJson)
 foreach($caseName in 'acl','sha256','bytes','directory','added','removed','shape','other','null_vs_missing'){
  $after=JsonCopy $before
  switch($caseName){
   'acl'{$after['C:\OpenWebPBX\web\private.php'].acl='changed-'+$sensitive}
   'sha256'{$after['C:\OpenWebPBX\web\private.php'].sha256='changed-'+$sensitive}
   'bytes'{$after['C:\OpenWebPBX\web\private.php'].bytes=11}
   'directory'{$after['C:\OpenWebPBX\web\private.php'].directory=$true}
   'added'{$after['C:\OpenWebPBX\web\'+$sensitive]=(Record)}
   'removed'{$after.Remove('C:\OpenWebPBX\web\private.php')}
   'shape'{$after['C:\OpenWebPBX\web\private.php']=$sensitive}
   'other'{$after['C:\OpenWebPBX\web\private.php'][$sensitive]=$sensitive}
   'null_vs_missing'{$after['C:\OpenWebPBX\web\private.php']['new_null']=$null}
  }
  $caught=$null;try{Equal $before $after 'fault-files'}catch{$caught=$_};$children++
  $report=Observe $caught
  Verify ($report.child.exit_code -eq 1 -and $report.comparison.comparison_result -ceq 'different' -and $report.comparison.comparison_stage -ceq 'compare')
  Verify ($report.comparison.comparison_files_observed -eq $true -and $report.comparison.comparison_changed_file_entry_count -eq 1 -and $report.comparison.comparison_file_category_counts.web -eq 1)
  $field=if($caseName -ceq 'null_vs_missing'){'other'}else{$caseName}
  Verify ($report.comparison.comparison_file_field_counts[$field] -eq 1)
  Verify (($before|ConvertTo-Json -Depth 32 -Compress) -ceq $beforeJson)
 }
 # Changes in several categories and fields are counted without exporting paths.
 $after=JsonCopy $before;$after['C:\ProgramData\OpenWebPBX\runtime.json'].acl='new';$after['C:\OpenWebPBX\desktop\manager.exe'].bytes=20;$after['unrecognized-'+$sensitive]=(Record)
 $caught=$null;try{Equal $before $after 'normal-protected-files'}catch{$caught=$_};$children++
 $report=Observe $caught
 Verify ($report.comparison.comparison_changed_file_entry_count -eq 3 -and $report.comparison.comparison_file_category_counts.config -eq 1 -and $report.comparison.comparison_file_category_counts.desktop -eq 1 -and $report.comparison.comparison_file_category_counts.other -eq 1)
 Verify ($report.comparison.comparison_file_field_counts.acl -eq 1 -and $report.comparison.comparison_file_field_counts.bytes -eq 1 -and $report.comparison.comparison_file_field_counts.added -eq 1)
 # Identical marginal totals do not imply a category/field association.
 $tracks=@(8000,16000,32000,48000|ForEach-Object {'C:\ProgramData\OpenWebPBX\storage\openweb-music\'+$_+'\lofi-beat-loop-schmoop.wav'})
 foreach($variant in 'A','B'){
  $left=@{};foreach($path in $(if($variant -ceq 'A'){$tracks}else{$tracks[0..2]})){$left[$path]=Record}
  $left['C:\ProgramData\OpenWebPBX\installation.json']=Record
  if($variant -ceq 'B'){$left['C:\ProgramData\OpenWebPBX\updater-install.json']=Record}
  $right=JsonCopy $left;foreach($path in @($right.Keys)){$right[$path].acl='changed'}
  $extra=if($variant -ceq 'A'){'C:\ProgramData\OpenWebPBX\automatic-backups\'+$sensitive}else{'C:\ProgramData\OpenWebPBX\storage\'+$sensitive}
  $right[$extra]=Record
  $caught=$null;try{Equal $left $right 'fault-files'}catch{$caught=$_};$children++
  $detail=(Observe $caught).comparison
  Verify ($detail.comparison_file_field_counts.acl -eq 5 -and $detail.comparison_file_field_counts.added -eq 1 -and $detail.comparison_file_category_counts.config -eq 2 -and $detail.comparison_file_category_counts.media -eq 4)
  Verify ($detail.comparison_unknown_file_entry_count -eq 1)
  if($variant -ceq 'A'){Verify ($detail.comparison_file_category_field_counts.media.acl -eq 4 -and !$detail.comparison_file_category_field_counts.media.ContainsKey('added') -and $detail.comparison_file_category_field_counts.config.added -eq 1)}
  else{Verify ($detail.comparison_file_category_field_counts.media.acl -eq 3 -and $detail.comparison_file_category_field_counts.media.added -eq 1 -and $detail.comparison_file_category_field_counts.config.acl -eq 2)}
 }
 # Every known public label survives both actual comparator and final validator.
 $known=@{}
 foreach($file in 'installation','runtime','updater-install','native-engine','local-codec','phone-tls'){$known['C:\ProgramData\OpenWebPBX\'+$file+'.json']=Record}
 foreach($path in @('C:\ProgramData\OpenWebPBX\storage','C:\ProgramData\OpenWebPBX\storage\openweb-music','C:\ProgramData\OpenWebPBX\storage\openweb-music\README.md','C:\ProgramData\OpenWebPBX\storage\openweb-music\manifest.json','C:\Program Files\FreeSWITCH\sounds','C:\Program Files\FreeSWITCH\sounds\openwebpbx')+$tracks+@(8000,16000,32000,48000|ForEach-Object {'C:\ProgramData\OpenWebPBX\storage\openweb-music\'+$_})){$known[$path]=Record}
 $changed=JsonCopy $known;foreach($path in @($changed.Keys)){$changed[$path].acl='changed'}
 $caught=$null;try{Equal $known $changed 'fault-files'}catch{$caught=$_};$children++
 $detail=(Observe $caught).comparison
 Verify ($detail.comparison_known_file_field_counts.Count -eq 20 -and $detail.comparison_unknown_file_entry_count -eq 0)
 foreach($row in $detail.comparison_known_file_field_counts.Values){Verify ($row.Count -eq 1 -and $row.acl -eq 1)}
 $rawDetail=Get-Content -LiteralPath (Join-Path $work 'compare-fault-files.out') -Raw|ConvertFrom-Json -AsHashtable
 foreach($mutation in 'category','label','field','row_type','map_type','negative','string','boolean','large','unknown_count','partial'){
  $invalid=JsonCopy $rawDetail
  switch($mutation){
   'category'{$invalid.comparison_file_category_field_counts[$sensitive]=@{acl=1}}
   'label'{$invalid.comparison_known_file_field_counts[$sensitive]=@{acl=1}}
   'field'{$invalid.comparison_file_category_field_counts.config[$sensitive]=1}
   'row_type'{$invalid.comparison_known_file_field_counts.runtime=$sensitive}
   'map_type'{$invalid.comparison_known_file_field_counts=@()}
   'negative'{$invalid.comparison_file_category_field_counts.config.acl=-1}
   'string'{$invalid.comparison_known_file_field_counts.runtime.acl='1'}
   'boolean'{$invalid.comparison_known_file_field_counts.runtime.acl=$true}
   'large'{$invalid.comparison_file_category_field_counts.config.acl=100001}
   'unknown_count'{$invalid.comparison_unknown_file_entry_count=$true}
   'partial'{$invalid.Remove('comparison_unknown_file_entry_count')}
  }
  Verify ($null -eq (QualificationComparisonDetails $invalid))
  $projected=QualificationFailureObservation $caught.ScriptStackTrace $script:qualificationFailedChild @{label='fault-files';report=$invalid}
  Verify (!$projected.ContainsKey('comparison') -and !($projected|ConvertTo-Json -Depth 16 -Compress).Contains($sensitive))
 }
 # Database equality remains exact; private table/column names stay private.
 $database=@{roles=@{original=$sensitive};values=@{($sensitive)=@('same')}};$changed=JsonCopy $database;$changed.roles.original='changed';$changed.values[$sensitive]=@('changed')
 $caught=$null;try{Equal $database $changed 'fault-database'}catch{$caught=$_};$children++
 $report=Observe $caught
 Verify ($report.comparison.comparison_changed_sections -ccontains 'roles' -and $report.comparison.comparison_other_table_count -eq 1 -and !$report.comparison.ContainsKey('comparison_files_observed'))
 # Fault injection binds only the private snapshot writer. Actual Equal, child,
 # JSON parser, predicate, report and primary refusal still execute unchanged.
 $realWrite=(Get-Item Function:WriteJson).ScriptBlock
 foreach($side in 'before','after'){
  $script:invalidSide=$side
  function WriteJson([string]$Path,$Value){if($Path.EndsWith('-'+$script:invalidSide+'.json')){[IO.File]::WriteAllText($Path,'{'+$sensitive)}else{& $realWrite $Path $Value}}
  $caught=$null;try{Equal $before $before 'fault-files'}catch{$caught=$_};$children++
  $report=Observe $caught
  Verify ($report.child.exit_code -eq 2 -and $report.comparison.comparison_result -ceq 'error' -and $report.comparison.comparison_stage -ceq ('parse_'+$side) -and $report.comparison.comparison_error_type -ceq 'JSONDecodeError')
 }
 Set-Item Function:WriteJson $realWrite
 # Synthetic protocol negatives never run a different comparator or grant pass.
 $valid=$report.comparison;$trace=$caught.ScriptStackTrace;$child=$script:qualificationFailedChild
 foreach($mutation in 'result','stage','error','string_count','large_count','negative_count','bool_count','field_name','category_name','partial_file','bad_flag','duplicate_section','section_name','array_type'){
  $row=@{comparison_result='different';comparison_stage='compare';comparison_changed_sections=@();comparison_unknown_section_count=1;comparison_values_observed=$false;comparison_changed_values_table_count=0;comparison_critical_tables=@();comparison_other_table_count=0;comparison_counts_capped=$false;comparison_columns_observed=$false;comparison_changed_column_count=0;comparison_critical_columns=@();comparison_other_column_count=0;comparison_column_counts_capped=$false;comparison_files_observed=$true;comparison_changed_file_entry_count=1;comparison_file_counts_capped=$false;comparison_file_field_counts=@{acl=1};comparison_file_category_counts=@{web=1};private_extra=$sensitive}
  switch($mutation){
   'result'{$row.comparison_result=$sensitive}
   'stage'{$row.comparison_stage=$sensitive}
   'error'{$row=@{comparison_result='error';comparison_stage='parse_before';comparison_error_type=$sensitive}}
   'string_count'{$row.comparison_changed_file_entry_count='1'}
   'large_count'{$row.comparison_unknown_section_count=100001}
   'negative_count'{$row.comparison_file_field_counts.acl=-1}
   'bool_count'{$row.comparison_file_field_counts.acl=$true}
   'field_name'{$row.comparison_file_field_counts[$sensitive]=1}
   'category_name'{$row.comparison_file_category_counts[$sensitive]=1}
   'partial_file'{$row.Remove('comparison_files_observed')}
   'bad_flag'{$row.comparison_file_counts_capped='false'}
   'duplicate_section'{$row.comparison_changed_sections=@('roles','roles')}
   'section_name'{$row.comparison_changed_sections=@($sensitive)}
   'array_type'{$row.comparison_changed_sections='roles'}
  }
  Verify ($null -eq (QualificationComparisonFields $row))
  $invalid=QualificationFailureObservation $trace $child @{label='fault-files';report=$row}
  Verify (!$invalid.ContainsKey('comparison') -and !($invalid|ConvertTo-Json -Depth 16 -Compress).Contains($sensitive))
 }
 foreach($mutation in 'different_exit','error_exit','label','unrelated'){
  $childCopy=$child.Clone();$comparison=@{label='fault-files';report=$valid};$traceCopy=$trace
  switch($mutation){
   'different_exit'{$comparison.report=@{comparison_result='equal';comparison_stage='compare'}}
   'error_exit'{$childCopy.exit_code=1}
   'label'{$comparison.label='fault-database'}
   'unrelated'{$traceCopy='at Check, C:\private\windows-updater-qualification.ps1: line 31'}
  }
  $invalid=QualificationFailureObservation $traceCopy $childCopy $comparison
  Verify (!$invalid.ContainsKey('comparison'))
 }
 # Bind only the child-report boundary for protocol refusals. Equal and the
 # final source validator run unchanged; every case retains its primary failure.
 $realChecked=(Get-Item Function:CheckedProcess).ScriptBlock
 $validProtocol=[IO.File]::ReadAllText((Join-Path $work 'compare-fault-files.out'))
 $protocolBody=@'
function CheckedProcess([string]$Executable,[string[]]$Arguments,[string]$Label){
 $script:qualificationFailedChild=@{caller='CheckedProcess';label=$Label;completion='exit';exit_code=$script:protocolExit}
 $path=Join-Path $work ($Label+'.out');Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
 if($script:protocolKind -cne 'missing'){[IO.File]::WriteAllText($path,$script:protocolContent)}
 Check $false 'A private qualification operation failed; its streams remain private.'
}
'@
 [IO.File]::AppendAllText($fixture,"`n"+$protocolBody);. $fixture
 foreach($caseName in 'missing','malformed','oversized','schema_string','schema_bool','schema_other','producer','array','single_array','scalar','partial','valid_extra','wrong_exit'){
  $script:protocolKind=$caseName;$script:protocolExit=2;$row=$validProtocol|ConvertFrom-Json -AsHashtable;$row['private_extra']=$sensitive
  switch($caseName){
   'schema_string'{$row.schema='1'}
   'schema_bool'{$row.schema=$true}
   'schema_other'{$row.schema=2}
   'producer'{$row.producer=$sensitive}
   'partial'{$row.Remove('comparison_stage')}
   'wrong_exit'{$script:protocolExit=7}
  }
  $script:protocolContent=$row|ConvertTo-Json -Depth 16 -Compress
  if($caseName -ceq 'malformed'){$script:protocolContent='{'+$sensitive}
  if($caseName -ceq 'oversized'){$script:protocolContent='x'*65537}
  if($caseName -ceq 'array'){$script:protocolContent='[]'}
  if($caseName -ceq 'single_array'){$script:protocolContent='['+$validProtocol+']'}
  if($caseName -ceq 'scalar'){$script:protocolContent='"'+$sensitive+'"'}
  $caught=$null;try{Equal $before $before 'fault-files'}catch{$caught=$_}
  $report=Observe $caught
  if($caseName -ceq 'valid_extra'){Verify ($report.comparison.comparison_result -ceq 'error' -and $report.comparison.comparison_stage -ceq 'parse_after')}
  elseif($caseName -ceq 'wrong_exit'){Verify (!$report.ContainsKey('comparison'))}
  else{Verify ($report.comparison.comparison_result -ceq 'unavailable' -and $report.comparison.comparison_stage -ceq 'report_validation')}
 }
 Set-Item Function:CheckedProcess $realChecked
 # Success clears stale reports and does not export the successful report.
 Equal $before $before 'fault-files';$children++
 Verify ($null -eq $script:qualificationComparisonFailure -and $null -eq $script:qualificationFailedChild)
}finally{
 if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Recurse -Force}
}
Verify (!(Test-Path -LiteralPath $temporary))
@{schema=1;state='passed';actual_source_controls=$checks;real_owned_python_children=$children;fixture_test_bindings='fixed Python executable, malformed snapshots and protocol-negative child reports only';exact_existing_comparator=$true;private_values_excluded=$true;pbx_services_or_network_executed=$false}|ConvertTo-Json -Compress
