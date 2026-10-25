param([string]$Source=(Join-Path $PSScriptRoot 'windows-restore-qualification.ps1'))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Actual observer parent did not parse.'}
$helpers=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'SafeRestoreWaitFailure'},$true))
if($helpers.Count -ne 1){throw 'Exactly one actual closed helper required.'}
. ([scriptblock]::Create($helpers[0].Extent.Text))
$blocks=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.TryStatementAst] -and $n.Body.Extent.Text.Contains('$waitOutput=Get-Item')},$true)|Where-Object {$_.Body.Statements.Count -eq 1 -and $_.Body.Statements[0] -is [Management.Automation.Language.IfStatementAst]})
if($blocks.Count -ne 1){throw 'Exactly one actual failure-only projection required.'}
$projection=[scriptblock]::Create($blocks[0].Extent.Text)
$owned=Join-Path ([IO.Path]::GetTempPath()) ('restore-wait-parent-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $owned
$file=Join-Path $owned 'private.out';[IO.File]::WriteAllText($file,'{}')
$base=@{schema=1;wait_kind='manual_backup_complete';timeout_seconds=600;source_basename='windows-restore-qualification.py';caller_function='backup_request';caller_line=1018}
$task=@{state='Ready';last_result=2147942405L;expected_system_action=$true;last_run_available=$true}
$cases=0;$checks=0
function Check([bool]$Value){if(!$Value){throw 'Actual failure-only projection guard did not preserve its contract.'};$script:checks++}
try{
 $valids=@($base,($base+@{backup_task=$task}))
 foreach($row in $valids){
  $actual=SafeRestoreWaitFailure ($row|ConvertTo-Json -Depth 5|ConvertFrom-Json)
  Check ($null -ne $actual -and $actual.wait_kind -ceq 'manual_backup_complete')
  Check (@($actual.Keys).Count -eq @($row.Keys).Count)
  $cases++
 }
 $mutations=@('schema_bool','schema_version','kind_case','private_kind','timeout_bool','timeout_wrong','source_path','caller_private','line_bool','line_string','line_zero','line_large','private_extra','missing','task_private','task_code_bool','task_code_negative','task_code_large','task_flag_integer','task_last_run_string','task_state_private')
 foreach($case in $mutations){
  $row=($base|ConvertTo-Json|ConvertFrom-Json -AsHashtable)
  switch($case){
   schema_bool{$row.schema=$true};schema_version{$row.schema=2};kind_case{$row.wait_kind='MANUAL_BACKUP_COMPLETE'};private_kind{$row.wait_kind='SECRET'}
   timeout_bool{$row.timeout_seconds=$true};timeout_wrong{$row.timeout_seconds=120};source_path{$row.source_basename='C:/PRIVATE/key.pem'}
   caller_private{$row.caller_function='SECRET'};line_bool{$row.caller_line=$true};line_string{$row.caller_line='1018'};line_zero{$row.caller_line=0};line_large{$row.caller_line=1000000}
   private_extra{$row.private='SECRET'};missing{$row.Remove('caller_line')}
   default{
    $row.backup_task=($task|ConvertTo-Json|ConvertFrom-Json -AsHashtable)
    switch($case){task_private{$row.backup_task.private='SECRET'};task_code_bool{$row.backup_task.last_result=$true};task_code_negative{$row.backup_task.last_result=-1};task_code_large{$row.backup_task.last_result=4294967296L};task_flag_integer{$row.backup_task.expected_system_action=1};task_last_run_string{$row.backup_task.last_run_available='yes'};task_state_private{$row.backup_task.state='SECRET'}}
   }
  }
  $actual=SafeRestoreWaitFailure ($row|ConvertTo-Json -Depth 5|ConvertFrom-Json)
  Check ($null -eq $actual);$cases++
 }
 foreach($case in @('valid','wrong_action','wrong_type','wrong_source','wrong_state','empty_file','large_file','missing_file','malformed_wait')){
  $privateOutput=$file;[IO.File]::WriteAllText($file,'{}');$Action='export-source'
  $facts=@{native_failure=@{error_type='TimeoutError'}}
  $safe=[pscustomobject]@{state='failed';error_type='TimeoutError';source_basename='windows-restore-qualification.py';wait_failure=($base|ConvertTo-Json|ConvertFrom-Json)}
  switch($case){
   wrong_action{$Action='cleanup'};wrong_type{$safe.error_type='TimeoutExpired'};wrong_source{$safe.source_basename='PRIVATE.py'};wrong_state{$safe.state='passed'}
   empty_file{[IO.File]::WriteAllText($file,'')};large_file{[IO.File]::WriteAllBytes($file,[byte[]]::new(1048577))};missing_file{$privateOutput=Join-Path $owned 'absent'};malformed_wait{$safe.wait_failure=$null}
  }
  & $projection
  Check ($facts.native_failure.ContainsKey('wait_failure') -eq ($case -ceq 'valid'))
  Check ($facts.native_failure.error_type -ceq 'TimeoutError');$cases++
 }
 # Execute the exact fixed task script with explicit Scheduler doubles. This
 # checks JSON coercion boundaries without reading an installed task.
 $pythonSource=Get-Content -LiteralPath ([IO.Path]::ChangeExtension($Source,'.py')) -Raw
 $taskMatches=[regex]::Matches($pythonSource,"(?m)^    script = r'''(?<task>.*)'''$")
 Check ($taskMatches.Count -eq 1)
 $taskScript=[scriptblock]::Create($taskMatches[0].Groups['task'].Value)
 function Get-ScheduledTask {return $script:taskModel}
 function Get-ScheduledTaskInfo {param($InputObject);return $script:infoModel}
 foreach($case in @('zero','uint32','uint64max','null','bool','string','negative','large','bad_date')){
  $script:taskModel=[pscustomobject]@{State='Ready';Principal=[pscustomobject]@{UserId='SYSTEM';RunLevel='Highest'};Actions=@([pscustomobject]@{Execute='C:\OpenWebPBX\backup-runtime\python.exe';Arguments='-I "C:\OpenWebPBX\tools\backups.py" worker'})}
  $script:infoModel=[pscustomobject]@{LastTaskResult=0;LastRunTime=[DateTime]'2026-10-24'}
  switch($case){uint32{$script:infoModel.LastTaskResult=[uint32]2147942405};uint64max{$script:infoModel.LastTaskResult=[uint64]4294967295};null{$script:infoModel.LastTaskResult=$null};bool{$script:infoModel.LastTaskResult=$true};string{$script:infoModel.LastTaskResult='0'};negative{$script:infoModel.LastTaskResult=-1};large{$script:infoModel.LastTaskResult=4294967296L};bad_date{$script:infoModel.LastRunTime='PRIVATE'}}
  $accepted=$false;$result=$null;try{$result=@(& $taskScript);$accepted=$true}catch{}
  Check ($accepted -eq ($case -cin @('zero','uint32','uint64max')))
  if($accepted){Check ($result.Count -eq 1);$row=$result[0]|ConvertFrom-Json;Check ($row.expected_system_action -eq $true -and $row.last_run_available -eq $true -and $row.state -ceq 'Ready')}
  $cases++
 }
}finally{Remove-Item -LiteralPath $owned -Recurse -Force}
if(Test-Path -LiteralPath $owned){throw 'Owned private fixture survived.'}
@{schema=1;state='passed';cases=$cases;checks=$checks;actual_parent_helper_and_projection=$true;private_file_checks_actual=$true;installed_services_or_tasks_queried=$false;owned_fixture_removed=$true}|ConvertTo-Json -Compress
