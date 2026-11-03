# Source/caller controls only. Native task, CI metadata and clock-expiry adapters
# operate in an owned temporary folder; no worker, product path or network call.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$checks=0
function Verify([bool]$value){if(!$value){throw ('Original21 observation control '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
function Clone($value){return $value|ConvertTo-Json -Depth 20|ConvertFrom-Json -AsHashtable}
function Check([bool]$value,[string]$message){if(!$value){throw $message}}
function Hash([string]$path){return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
function WriteJson([string]$path,$value){[IO.File]::WriteAllText($path,($value|ConvertTo-Json -Depth 20))}
$work=Join-Path ([IO.Path]::GetTempPath()) ('original21-observer-controls-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory $work|Out-Null
$savedEnv=@{};foreach($name in 'GITHUB_ACTIONS','RUNNER_ENVIRONMENT','GITHUB_REPOSITORY','GITHUB_RUN_ID','GITHUB_SHA','GITHUB_JOB','RUNNER_TEMP','GH_TOKEN'){$savedEnv[$name]=[Environment]::GetEnvironmentVariable($name)}
try{
 $source=Join-Path $SourceRoot 'tests/windows-updater-qualification.ps1';$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors);Verify (!$errors.Count)
 $fixtureSource=Join-Path $work 'source';New-Item -ItemType Directory $fixtureSource|Out-Null;$definitions=@()
 foreach($name in 'ReadQualificationOriginal21Preamble','InvokeQualificationOriginal21Preamble','QualificationBackupWorkerFailureFields'){
  $node=@($ast.FindAll({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst]-and $n.Name-ceq $name},$true));Verify ($node.Count-eq 1);$text=$node[0].Extent.Text
  if($name-ceq 'InvokeQualificationOriginal21Preamble'){
   $needle='& $operator -Context $contextPath *> $privateLog';Verify (($text.Split(@($needle),[StringSplitOptions]::None)).Count-eq 2)
   $adapted=$text.Replace($needle,'Invoke-ReadOnlyFixture -Context $contextPath *> $privateLog');Verify ($adapted.Replace('Invoke-ReadOnlyFixture -Context $contextPath *> $privateLog',$needle)-ceq $text);$text=$adapted
  };$definitions+=$text
 }
 $import=Join-Path $fixtureSource 'windows-updater-qualification.ps1';[IO.File]::WriteAllText($import,($definitions-join "`n"));. $import
 . (Join-Path $SourceRoot 'tests/windows-backup-warmup-diagnostics.ps1')
 foreach($leaf in 'Invoke-OriginalPublic21-ReadOnlyPreamble.ps1','readonly-preamble.py','Run-ReadOnlyPython.ps1'){[IO.File]::WriteAllBytes((Join-Path $fixtureSource $leaf),[IO.File]::ReadAllBytes((Join-Path $SourceRoot ('tests/'+$leaf))))}
 $valid=@{observation_completed=$true;production_worker_success_claim=$false;old_failure_cause_still_unknown=$true;actual_system=$true;original_helper_a1b_exact=$true;elapsed_seconds=0.4;only_static_select1_and_existing_file_open_close=$true;worker_secure_status_queue_or_lifecycle_invoked=$false;stages=@{
  module_import=@{result='observed';elapsed_ms=1;helper_hash_exact=$true}
  read_settings=@{result='observed';elapsed_ms=1;read_settings_succeeded=$true;credential_values_never_projected=$true}
  native_psql_readonly_select1=@{result='observed';elapsed_ms=1;native_exit_code=0;select1_exact=$true;read_only_transaction=$true}
  upgrade_open_existing=@{result='native_refusal';elapsed_ms=1;path_exists=$true;native_error=32;sharing_or_byte_lock_code=$true}
  store_worker_open_existing=@{result='missing_not_created';elapsed_ms=1;path_exists=$false}
 }}
 foreach($record in $valid,($valid|ConvertTo-Json -Depth 20|ConvertFrom-Json)){Verify ($null-ne (ReadQualificationOriginal21Preamble $record))}
 $moduleErrorRecord=Clone $valid;$moduleErrorRecord.stages.module_import=@{result='error';elapsed_ms=2;exception_type='ModuleNotFoundError';source_basename='backups.py';source_line=14;native_error=$null;hresult=$null};$moduleErrorRecord.stages.read_settings=@{result='not_observed_prerequisite_failed'};$moduleErrorRecord.stages.native_psql_readonly_select1=@{result='not_observed_prerequisite_failed'};Verify ($null-ne (ReadQualificationOriginal21Preamble $moduleErrorRecord))
 foreach($case in 'extra','missing','false_system','true_worker','elapsed_bool','elapsed_limit','stage_array','stage_unknown','field_unknown','result_array','exception_array','source_private','source_line','native_bool','lock_code','lock_missing','psql_readwrite','psql_false_exit','prerequisite'){
  $bad=Clone $valid
  switch($case){extra{$bad.PRIVATE_VALUE='PRIVATE_EXCEPTION_MARKER'}missing{$bad.Remove('actual_system')}false_system{$bad.actual_system=$false}true_worker{$bad.production_worker_success_claim=$true}elapsed_bool{$bad.elapsed_seconds=$true}elapsed_limit{$bad.elapsed_seconds=75}stage_array{$bad.stages=@($true)}stage_unknown{$bad.stages.PRIVATE_STAGE=@{result='observed'}}field_unknown{$bad.stages.module_import.PRIVATE_VALUE='PRIVATE_EXCEPTION_MARKER'}result_array{$bad.stages.module_import.result=@('observed')}exception_array{$bad=Clone $moduleErrorRecord;$bad.stages.module_import.exception_type=@('ModuleNotFoundError')}source_private{$bad=Clone $moduleErrorRecord;$bad.stages.module_import.source_basename='PRIVATE_PATH'}source_line{$bad=Clone $moduleErrorRecord;$bad.stages.module_import.source_line=-1}native_bool{$bad.stages.upgrade_open_existing.native_error=$true}lock_code{$bad.stages.upgrade_open_existing.sharing_or_byte_lock_code=$false}lock_missing{$bad.stages.store_worker_open_existing.path_exists=$true}psql_readwrite{$bad.stages.native_psql_readonly_select1.read_only_transaction=$false}psql_false_exit{$bad.stages.native_psql_readonly_select1.native_exit_code=1}prerequisite{$bad.stages.read_settings=@{result='not_observed_prerequisite_failed'}}}
  Verify ($null-eq (ReadQualificationOriginal21Preamble $bad))
 }
 $wrapper=@($ast.FindAll({param($n)$n-is [Management.Automation.Language.TryStatementAst]-and $n.Body.Statements.Count-eq 1-and @($n.Body.FindAll({param($c)$c-is [Management.Automation.Language.CommandAst]-and $c.GetCommandName()-ceq 'InitializeQualificationBackupWorker'},$true)).Count-eq 1-and $n.CatchClauses.Extent.Text.Contains('InvokeQualificationOriginal21Preamble')},$true));Verify ($wrapper.Count-eq 1)
 $caller=Join-Path $fixtureSource 'caller.ps1';[IO.File]::WriteAllText($caller,$wrapper[0].Extent.Text)
 $package=Join-Path $work 'package';New-Item -ItemType Directory $package|Out-Null;[IO.File]::WriteAllText((Join-Path $package 'release-manifest.json'),'{}')
 $env:GITHUB_ACTIONS='true';$env:RUNNER_ENVIRONMENT='github-hosted';$env:GITHUB_REPOSITORY='embire2/openwebpbx';$env:GITHUB_RUN_ID='12345';$env:GITHUB_SHA='f'*40;$env:GITHUB_JOB='qualification';$env:RUNNER_TEMP=$work;$env:GH_TOKEN='source-only-adapter-no-network'
 function Invoke-RestMethod {param($Uri,$TimeoutSec,$Headers)
  Verify ($Uri-ceq 'https://api.github.com/repos/embire2/openwebpbx/actions/runs/12345/jobs?per_page=100'-and $TimeoutSec-eq 10)
  $started=switch($script:mode){budget{[DateTimeOffset]::UtcNow.AddMinutes(-119).ToString('o')}future{[DateTimeOffset]::UtcNow.AddMinutes(1).ToString('o')}default{[DateTimeOffset]::UtcNow.AddMinutes(-10).ToString('o')}}
  return @{jobs=@(@{run_id=12345;head_sha=$env:GITHUB_SHA;name='qualification';status='in_progress';started_at=$started})}
 }
 function Invoke-ReadOnlyFixture {param([string]$Context)
  $script:diagnosticCalls++;$ctx=Get-Content -LiteralPath $Context -Raw|ConvertFrom-Json
  Verify ($ctx.RootAuthorizedReadOnlyOriginalPublic21BaselineDiagnostic-is [bool]-and $ctx.RootAuthorizedReadOnlyOriginalPublic21BaselineDiagnostic-and $ctx.originalLastTaskResult-eq 1-and $ctx.originalFreshRun-and ([guid]$ctx.operationUUID).ToString()-ceq $ctx.operationUUID)
  New-Item -ItemType Directory $ctx.privateEvidenceRoot|Out-Null
  if($script:mode-ceq 'throw'){throw 'PRIVATE_EXCEPTION_MARKER'}
  $child=@{observationChildFinished=$true;nativeExitCode=0;childPID=123;elapsedSeconds=0.5;noWorkerOrProductLifecycle=$true;noKillOrRetry=$true;childMayStillBeRunning=$false};$record=Clone $valid
  switch($script:mode){child_exit{$child.nativeExitCode=1}malformed{$record.PRIVATE_FIELD='PRIVATE_EXCEPTION_MARKER'}late{Set-Variable -Name jobDeadline -Scope 1 -Value ([DateTimeOffset]::UtcNow.AddSeconds(-1))}}
  WriteJson (Join-Path $ctx.privateEvidenceRoot 'diagnostic-child-result.safe.json') $child;WriteJson (Join-Path $ctx.privateEvidenceRoot 'closed-observation.safe.json') $record
  $script:qualificationFailedChild='DIAGNOSTIC_CHILD_MARKER';$script:qualificationComparisonFailure='DIAGNOSTIC_COMPARISON_MARKER';$script:qualificationFailedHash='DIAGNOSTIC_HASH_MARKER'
 }
 function InitializeQualificationBackupWorker {param($Root,$StateRoot,$PackageRoot)$script:workerCalls++;if($script:mode-cne 'warmup_success'){throw $script:originalFailure}}
 foreach($script:mode in 'observed','ineligible','enabled','other_base','budget','future','throw','child_exit','malformed','late','warmup_success'){
  $actualCandidate=$true;$OriginalTenantDomainsDisabled=$true;$BaseVersion='1.0.21';$BaseSuiteRunId='40435466441';$facts=@{};$script:workerCalls=0;$script:diagnosticCalls=0
  $exception=[InvalidOperationException]::new('ORIGINAL_PRIVATE_WARMUP_FAILURE');$script:originalFailure=[Management.Automation.ErrorRecord]::new($exception,'original',[Management.Automation.ErrorCategory]::NotSpecified,$null)
  $exception.Data['openweb_qa_backup_warmup']=@{schema=1;stage='worker_result';runtime_component='unknown';mismatches=@()};$exception.Data['openweb_qa_backup_worker']=@{schema=1;last_task_result=1;task_state='Ready';last_run_advanced=$true;last_run_not_future=$true;prior_run_not_future=$true}
  switch($mode){ineligible{$exception.Data['openweb_qa_backup_worker'].last_run_advanced=$false}enabled{$OriginalTenantDomainsDisabled=$false}other_base{$BaseVersion='1.0.20'}}
  $childBefore=@{original='child'};$compareBefore=@{original='comparison'};$hashBefore=@{original='hash'};$script:qualificationFailedChild=$childBefore;$script:qualificationComparisonFailure=$compareBefore;$script:qualificationFailedHash=$hashBefore;$caught=$null
  try{. $caller}catch{$caught=$_}
  Verify ($workerCalls-eq 1)
  if($mode-ceq 'warmup_success'){Verify ($null-eq $caught-and $diagnosticCalls-eq 0-and !$facts.ContainsKey('original21_preamble_observation'));continue}
  Verify ($null-ne $caught-and [object]::ReferenceEquals($caught.Exception,$exception)-and $caught.Exception.Message-ceq 'ORIGINAL_PRIVATE_WARMUP_FAILURE')
  Verify ([object]::ReferenceEquals($script:qualificationFailedChild,$childBefore)-and [object]::ReferenceEquals($script:qualificationComparisonFailure,$compareBefore)-and [object]::ReferenceEquals($script:qualificationFailedHash,$hashBefore))
  if($mode-cin 'ineligible','other_base'){Verify ($diagnosticCalls-eq 0-and !$facts.ContainsKey('original21_preamble_observation'))}
  elseif($mode-cin 'observed','enabled'){Verify ($diagnosticCalls-eq 1-and $facts.original21_preamble_observation.state-ceq 'observed'-and !$facts.original21_preamble_observation.observation.production_worker_success_claim)}
  else{Verify ($facts.original21_preamble_observation.state-ceq 'unavailable');if($mode-cin 'budget','future'){Verify ($diagnosticCalls-eq 0)}}
  Verify (($facts|ConvertTo-Json -Depth 20 -Compress)-cnotmatch 'PRIVATE_EXCEPTION_MARKER|DIAGNOSTIC_CHILD_MARKER|PRIVATE_FIELD')
 }
 @{state='passed';checks=$checks;actual_native=$false;task_ci_metadata_and_expiry_adapters=$true;primary_failure_preserved=$true;no_worker_or_network_or_product_action=$true}|ConvertTo-Json -Compress
}finally{foreach($name in $savedEnv.Keys){[Environment]::SetEnvironmentVariable($name,$savedEnv[$name])};Remove-Item -LiteralPath $work -Recurse -Force}
