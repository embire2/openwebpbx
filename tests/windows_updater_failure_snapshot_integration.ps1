# Actual caller extraction with metadata/file-collector adapters only. No network,
# installed path, task, service, product process or private recipient key is used.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$checks=0
function Verify([bool]$Value){if(!$Value){throw ('Failure snapshot integration control '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
function Check([bool]$Value,[string]$Message){if(!$Value){throw $Message}}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-updater-qualification.ps1'),[ref]$tokens,[ref]$errors);Verify (!$errors.Count)
$node=@($ast.FindAll({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst]-and $n.Name-ceq 'GetQualificationFailureSnapshot'},$true));Verify ($node.Count-eq 1);Invoke-Expression $node[0].Extent.Text
$source=$ast.Extent.Text
Verify (($source.Split(@(". (Join-Path `$PSScriptRoot 'windows_updater_failure_snapshot.ps1')"),[StringSplitOptions]::None)).Count-eq 2)
$catch=@($ast.FindAll({param($n)$n-is [Management.Automation.Language.CatchClauseAst]-and $n.Body.Extent.Text.Contains("`$facts.state='failed';`$facts.failed_phase=`$phase")},$true));Verify ($catch.Count-eq 1)
$capture=@($catch[0].FindAll({param($n)$n-is [Management.Automation.Language.CommandAst]-and $n.GetCommandName()-ceq 'GetQualificationFailureSnapshot'},$true));Verify ($capture.Count-eq 1)
Verify ($catch[0].Body.Extent.Text.IndexOf('$primaryFailure=$_')-lt $catch[0].Body.Extent.Text.IndexOf('$facts.failure_observation='))
Verify ($catch[0].Body.Extent.Text.IndexOf('$facts.failure_observation=')-lt $catch[0].Body.Extent.Text.IndexOf('$snapshot=GetQualificationFailureSnapshot'))
Verify ($catch[0].Extent.EndOffset-lt $source.IndexOf('Remove-Item Env:\GH_TOKEN,Env:\WINDOWS_UPDATER_SIGNED_PACKETS_B64'))
Verify ($catch[0].Body.Extent.Text.Contains('$facts.failure_snapshot=$snapshot.record;$facts.failure_snapshot_reason=$snapshot.reason'))
Verify ($node[0].Extent.Text-cnotmatch 'CheckedProcess|Fixture |Start-(?:Process|Service|ScheduledTask)|Stop-(?:Process|Service|ScheduledTask)|Remove-Item|WriteAll|Set-Content')
$savedEnv=@{};foreach($name in 'GITHUB_ACTIONS','RUNNER_ENVIRONMENT','GITHUB_REPOSITORY','GITHUB_RUN_ID','GITHUB_SHA','GITHUB_JOB','GH_TOKEN'){$savedEnv[$name]=[Environment]::GetEnvironmentVariable($name)}
$state='SOURCE_ONLY_STATE';$work='SOURCE_ONLY_WORK';$private='PRIVATE_SNAPSHOT_SENTINEL'
function Invoke-RestMethod {param($Uri,$TimeoutSec,$Headers)
 $script:metadataCalls++;Verify ($Uri-ceq 'https://api.github.com/repos/embire2/openwebpbx/actions/runs/12345/jobs?per_page=100'-and $TimeoutSec-eq 10)
 Verify ($Headers.Authorization-ceq 'Bearer source-only-not-a-token')
 $script:qualificationFailedChild=@{changed='metadata'};$script:qualificationComparisonFailure=@{changed='metadata'};$script:qualificationFailedHash=@{changed='metadata'}
 if($mode-ceq 'metadata_error'){throw $private}
 $script:apiStart=switch($mode){future_start{[DateTimeOffset]::UtcNow.AddMinutes(1)}budget{[DateTimeOffset]::UtcNow.AddMinutes(-120).AddSeconds(20)}default{[DateTimeOffset]::UtcNow.AddMinutes(-10)}}
 $job=@{run_id=12345;head_sha=$env:GITHUB_SHA;name='qualification';status='in_progress';started_at=$script:apiStart.ToString('o')}
 switch($mode){foreign_head{$job.head_sha='a'*40}foreign_run{$job.run_id=54321}foreign_job{$job.name='foreign'}not_active{$job.status='completed'}}
 if($mode-ceq 'missing_job'){return @{jobs=@()}}
 if($mode-ceq 'duplicate_job'){return @{jobs=@($job,$job)}}
 return @{jobs=@($job)}
}
function Get-WindowsUpdaterFailureSnapshot {param($StateRoot,$WorkRoot,$JobDeadline,$PrimaryFailure)
 $script:collectorCalls++;Verify ($StateRoot-ceq $state-and $WorkRoot-ceq $work)
 Verify ($JobDeadline-eq $script:apiStart.AddMinutes(120)-and [DateTimeOffset]::UtcNow.AddSeconds(30)-lt $JobDeadline)
 Verify ([object]::ReferenceEquals($PrimaryFailure,$script:originalForCollector))
 $script:qualificationFailedChild=@{changed='collector'};$script:qualificationComparisonFailure=@{changed='collector'};$script:qualificationFailedHash=@{changed='collector'}
 if($mode-ceq 'helper_throw'){throw $private}
 if($mode-ceq 'malformed'){return @($private)}
 if($mode-ceq 'helper_unavailable'){return @{schema=1;state='unavailable';reason='private_evidence'}}
 return @{schema=1;state='captured';encrypted=@{fixture='opaque-source-adapter'}}
}
function Read-WindowsUpdaterFailureSnapshot($Record){
 if($mode-ceq 'reader_throw'){throw $private}
 if($Record-isnot [Collections.IDictionary]){return $null}
 if($Record.state-ceq 'unavailable'-and $Record.reason-ceq 'private_evidence'){return $Record}
 if($Record.state-ceq 'captured'-and $Record.encrypted.fixture-ceq 'opaque-source-adapter'){return $Record}
 return $null
}
try{
 foreach($script:mode in 'captured','not_installed','not_ci','metadata_error','future_start','budget','missing_job','foreign_head','foreign_run','foreign_job','not_active','duplicate_job','helper_throw','malformed','helper_unavailable','reader_throw'){
  $installed=$true;$script:metadataCalls=0;$script:collectorCalls=0
  $env:GITHUB_ACTIONS='true';$env:RUNNER_ENVIRONMENT='github-hosted';$env:GITHUB_REPOSITORY='embire2/openwebpbx';$env:GITHUB_RUN_ID='12345';$env:GITHUB_SHA='f'*40;$env:GITHUB_JOB='qualification';$env:GH_TOKEN='source-only-not-a-token'
  if($mode-ceq 'not_installed'){$installed=$false};if($mode-ceq 'not_ci'){$env:GITHUB_ACTIONS='false'}
  $child=@{original='child'};$comparison=@{original='comparison'};$hash=@{original='hash'};$script:qualificationFailedChild=$child;$script:qualificationComparisonFailure=$comparison;$script:qualificationFailedHash=$hash
  $original=[InvalidOperationException]::new($private)
  try{throw $original}catch{
   $primary=$_;$facts=@{state='failed';failed_phase='FIXED_ORIGINAL_PHASE';error_type='InvalidOperationException'}
   $script:originalForCollector=$primary;$result=GetQualificationFailureSnapshot -PrimaryFailure $primary;$facts.failure_snapshot=$result.record;$facts.failure_snapshot_reason=$result.reason
   Verify ([object]::ReferenceEquals($_,$primary)-and [object]::ReferenceEquals($_.Exception,$original))
   Verify ($facts.state-ceq 'failed'-and $facts.failed_phase-ceq 'FIXED_ORIGINAL_PHASE'-and $facts.error_type-ceq 'InvalidOperationException')
  }
  Verify ([object]::ReferenceEquals($script:qualificationFailedChild,$child)-and [object]::ReferenceEquals($script:qualificationComparisonFailure,$comparison)-and [object]::ReferenceEquals($script:qualificationFailedHash,$hash))
  Verify ($metadataCalls-le 1-and $collectorCalls-le 1)
  if($mode-ceq 'captured'){Verify ($result.reason-ceq 'captured'-and $result.record.state-ceq 'captured'-and $metadataCalls-eq 1-and $collectorCalls-eq 1)}
  else{
   $reason=if($mode-ceq 'not_installed'){'fixture_not_installed'}elseif($mode-ceq 'budget'){'current_job_budget'}elseif($mode-cin 'helper_throw','malformed','helper_unavailable','reader_throw'){'collector_unavailable'}else{'metadata_unavailable'}
   Verify ($result.record.state-ceq 'unavailable'-and $result.reason-ceq $reason)
   Verify ($result.record.reason-ceq $(if($mode-ceq 'helper_unavailable'){'private_evidence'}else{'context_guard'}))
   if($mode-cin 'not_installed','not_ci'){Verify ($metadataCalls-eq 0-and $collectorCalls-eq 0)}
   elseif($reason-cne 'collector_unavailable'){Verify ($metadataCalls-eq 1-and $collectorCalls-eq 0)}
   else{Verify ($metadataCalls-eq 1-and $collectorCalls-eq 1)}
  }
  Verify (($facts|ConvertTo-Json -Depth 10 -Compress)-cnotmatch $private)
 }
 # Exercise the actual Fixture body with only its process factory replaced.
 # Already-read status stdout is retained privately before parse/exit refusal.
 $fixture=@($ast.FindAll({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst]-and $n.Name-ceq 'Fixture'},$true));Verify ($fixture.Count-eq 1)
 $originalFixture=$fixture[0].Extent.Text;$needle='[Diagnostics.Process]::Start($start)';Verify (($originalFixture.Split(@($needle),[StringSplitOptions]::None)).Count-eq 2)
 $adapted=$originalFixture.Replace($needle,'(Start-OwnedFixtureProcess $start)');Verify ($adapted.Replace('(Start-OwnedFixtureProcess $start)',$needle)-ceq $originalFixture)
 $fixtureDirectory=Join-Path ([IO.Path]::GetTempPath()) ('failure-status-caller-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory $fixtureDirectory|Out-Null
 $fixtureImport=Join-Path $fixtureDirectory 'fixture-caller.ps1';[IO.File]::WriteAllText($fixtureImport,$adapted);. $fixtureImport
 $root='SOURCE_ONLY_ROOT';$inputFile='SOURCE_ONLY_INPUT';$work=Join-Path $fixtureDirectory 'work';New-Item -ItemType Directory $work|Out-Null
 function Start-OwnedFixtureProcess($Start){
  $script:fixtureStarts++;Verify ($Start.FileName-ceq 'SOURCE_ONLY_ROOT\php\php.exe'-and $Start.WorkingDirectory-ceq 'SOURCE_ONLY_ROOT\web'-and !$Start.UseShellExecute-and $Start.RedirectStandardOutput-and $Start.RedirectStandardError)
  Verify ($Start.ArgumentList.Count-eq 3-and $Start.ArgumentList[0]-ceq (Join-Path $fixtureDirectory 'windows-updater-fixture.php')-and $Start.ArgumentList[1]-ceq $script:fixtureAction-and $Start.ArgumentList[2]-ceq 'SOURCE_ONLY_INPUT')
  $stdout=[pscustomobject]@{};$stdout|Add-Member ScriptMethod ReadToEndAsync {return [Threading.Tasks.Task]::FromResult([string]$script:fixtureStdout)}
  $stderr=[pscustomobject]@{};$stderr|Add-Member ScriptMethod ReadToEndAsync {return [Threading.Tasks.Task]::FromResult([string]'PRIVATE_NATIVE_STDERR')}
  $process=[pscustomobject]@{StandardOutput=$stdout;StandardError=$stderr;ExitCode=$script:fixtureExit}
  $process|Add-Member ScriptMethod WaitForExit {param($Limit)Verify ($Limit-eq 90000);$script:fixtureWaits++;return $true}
  $process|Add-Member ScriptMethod Dispose {$script:fixtureDisposals++}
  return $process
 }
 try{
  foreach($case in 'status','other_action','write_refusal','native_failure','invalid_json'){
   foreach($item in @(Get-ChildItem -LiteralPath $work -Force)){Remove-Item -LiteralPath $item.FullName -Recurse -Force}
   $script:fixtureAction=if($case-ceq 'other_action'){'discover'}else{'status'};$script:fixtureStdout=if($case-ceq 'invalid_json'){'{'}else{'{"source_only":true,"private_marker":"PRIVATE_STATUS_SENTINEL"}'};$script:fixtureExit=if($case-ceq 'native_failure'){7}else{0}
   $script:fixtureStarts=0;$script:fixtureWaits=0;$script:fixtureDisposals=0;$statusPath=Join-Path $work 'status-private.out';if($case-ceq 'write_refusal'){New-Item -ItemType Directory $statusPath|Out-Null}
   $caught=$null;$result=$null;try{$result=Fixture $script:fixtureAction}catch{$caught=$_}
   Verify ($fixtureStarts-eq 1-and $fixtureWaits-eq 1-and $fixtureDisposals-eq 1)
   if($case-cin 'native_failure','invalid_json'){Verify ($null-ne $caught)}else{Verify ($null-eq $caught-and $result.source_only)}
   if($case-ceq 'other_action'){Verify (!(Test-Path -LiteralPath $statusPath))}
   elseif($case-ceq 'write_refusal'){Verify (Test-Path -LiteralPath $statusPath -PathType Container)}
   else{Verify ([IO.File]::ReadAllText($statusPath)-ceq $script:fixtureStdout)}
   if($case-ceq 'native_failure'){Verify ($script:qualificationFailedChild.label-ceq 'fixture-status'-and $script:qualificationFailedChild.exit_code-eq 7)}else{Verify ($null-eq $script:qualificationFailedChild)}
  }
 }finally{Remove-Item -LiteralPath $fixtureDirectory -Recurse -Force}
 @{schema=1;state='passed';checks=$checks;actual_source_caller=$true;native_network_and_file_collector_adapters=$true;primary_metadata_preserved=$true;original_job_bound_preserved=$true;product_or_host_actions=$false}|ConvertTo-Json -Compress
}finally{foreach($name in $savedEnv.Keys){[Environment]::SetEnvironmentVariable($name,$savedEnv[$name])}}
