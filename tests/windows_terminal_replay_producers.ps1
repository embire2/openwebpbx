# Actual terminal-producer provenance controls; never qualifies a PBX instance.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent),[string]$ActualRunJson,[string]$ActualJobsJson,[string]$ActualArtifactsJson)
$ErrorActionPreference='Stop';$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-suite.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The actual suite must parse.'}
foreach($name in 'TerminalReplayProducers','AssertTerminalReplayArtifact'){
 $nodes=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true))
 if($nodes.Count -ne 1){throw 'The actual producer guard must be unique.'};Invoke-Expression $nodes[0].Extent.Text
}
$checks=0
function Check([bool]$Value){if(!$Value){throw 'The original terminal-producer guard failed.'};$script:checks++}
function Refuses([scriptblock]$Action){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Check $failed}
function Run {
 [pscustomobject]@{id=[long]12345;run_attempt=1;status='in_progress';conclusion=$null;repository=[pscustomobject]@{id=1406074259;full_name='embire2/openwebpbx'};head_repository=[pscustomobject]@{id=1406074259;full_name='embire2/openwebpbx'};event='workflow_dispatch';path='.github/workflows/windows-suite.yml';head_sha=('a'*40);secret='PRIVATE_NEVER_PUBLISH'}
}
function Step([string]$Name,[string]$Conclusion='success'){[pscustomobject]@{name=$Name;status='completed';conclusion=$Conclusion}}
function Jobs {
 [pscustomobject]@{total_count=2;jobs=@(
  [pscustomobject]@{id=[long]111;run_id=[long]12345;run_attempt=1;head_sha=('a'*40);name='music';status='completed';conclusion='success';labels=@('ubuntu-22.04');steps=@((Step 'Stage the immutable public Nathaniel system prompts'),(Step 'Store only canonical prepared audio and build provenance'),(Step 'Post Check out the candidate source'),(Step 'Complete job'))},
  [pscustomobject]@{id=[long]222;run_id=[long]12345;run_attempt=1;head_sha=('a'*40);name='suite';status='completed';conclusion='failure';labels=@('windows-2025');steps=@((Step 'Verify build inputs and qualify the isolated server' 'failure'),(Step 'Store only credential-free acceptance facts'),(Step 'Preserve only the original verified candidate package and checksum'),(Step 'Complete job'))}
 )}
}
$proof=TerminalReplayProducers (Run) (Jobs) '12345'
Check ($proof.readiness -ceq 'terminal_producer_jobs' -and $proof.original_run_status -ceq 'in_progress' -and $proof.original_run_conclusion -ceq 'unreported' -and $proof.attempt -eq 1 -and $proof.jobs.Count -eq 2)
Check (($proof|ConvertTo-Json -Depth 8) -cnotmatch 'PRIVATE_NEVER_PUBLISH|secret|passed|qualified')
$run=(Run)|ConvertTo-Json -Depth 8|ConvertFrom-Json;$jobs=(Jobs)|ConvertTo-Json -Depth 8|ConvertFrom-Json
$proof=TerminalReplayProducers $run $jobs '12345';Check ($proof.jobs[0].id -eq 111 -and $proof.jobs[1].id -eq 222)
foreach($field in 'id','run_attempt','status','event','path','head_sha'){
 foreach($bad in $null,$true,'PRIVATE_NEVER_PUBLISH',@('PRIVATE_NEVER_PUBLISH')){$run=Run;$run.$field=$bad;Refuses {TerminalReplayProducers $run (Jobs) '12345'}}
}
foreach($field in 'full_name','id'){
 foreach($repository in 'repository','head_repository'){
  foreach($bad in $null,$true,'PRIVATE_NEVER_PUBLISH',@('PRIVATE_NEVER_PUBLISH')){$run=Run;$run.$repository.$field=$bad;Refuses {TerminalReplayProducers $run (Jobs) '12345'}}
 }
}
foreach($attempt in 0,2,'1'){$run=Run;$run.run_attempt=$attempt;Refuses {TerminalReplayProducers $run (Jobs) '12345'}}
foreach($state in 'queued','waiting','completed','cancelled'){$run=Run;$run.status=$state;Refuses {TerminalReplayProducers $run (Jobs) '12345'}}
foreach($conclusion in 'success','failure','cancelled'){$run=Run;$run.conclusion=$conclusion;Refuses {TerminalReplayProducers $run (Jobs) '12345'}}
foreach($index in 0,1){
 foreach($field in 'id','run_id','run_attempt','head_sha','name','status','conclusion','labels','steps'){
  foreach($bad in $null,$true,'PRIVATE_NEVER_PUBLISH',@('PRIVATE_NEVER_PUBLISH')){$jobs=Jobs;$jobs.jobs[$index].$field=$bad;Refuses {TerminalReplayProducers (Run) $jobs '12345'}}
 }
 foreach($state in 'queued','in_progress','waiting'){$jobs=Jobs;$jobs.jobs[$index].status=$state;Refuses {TerminalReplayProducers (Run) $jobs '12345'}}
 foreach($attempt in 0,2,'1'){$jobs=Jobs;$jobs.jobs[$index].run_attempt=$attempt;Refuses {TerminalReplayProducers (Run) $jobs '12345'}}
 foreach($field in 'name','status','conclusion'){
  foreach($bad in $null,$true,'PRIVATE_NEVER_PUBLISH',@('PRIVATE_NEVER_PUBLISH')){$jobs=Jobs;$jobs.jobs[$index].steps[0].$field=$bad;Refuses {TerminalReplayProducers (Run) $jobs '12345'}}
 }
}
foreach($count in 0,1,3,'2'){$jobs=Jobs;$jobs.total_count=$count;Refuses {TerminalReplayProducers (Run) $jobs '12345'}}
$jobs=Jobs;$jobs.jobs+=($jobs.jobs[0]);$jobs.total_count=3;Refuses {TerminalReplayProducers (Run) $jobs '12345'}
$jobs=Jobs;$jobs.jobs[1].name='music';Refuses {TerminalReplayProducers (Run) $jobs '12345'}
$jobs=Jobs;$jobs.jobs[1].id=$jobs.jobs[0].id;Refuses {TerminalReplayProducers (Run) $jobs '12345'}
$jobs=Jobs;$jobs.jobs[1].steps[1].conclusion='failure';Refuses {TerminalReplayProducers (Run) $jobs '12345'}
$jobs=Jobs;$jobs.jobs[1].steps[2].conclusion='skipped';Refuses {TerminalReplayProducers (Run) $jobs '12345'}
$jobs=Jobs;$jobs.jobs[1].steps=@($jobs.jobs[1].steps|Where-Object {$_.name -cne 'Preserve only the original verified candidate package and checksum'});Refuses {TerminalReplayProducers (Run) $jobs '12345'}
function Artifact {
 [pscustomobject]@{id=[long]333;size_in_bytes=[long]1024;expired=$false;digest=('sha256:'+('b'*64));workflow_run=[pscustomobject]@{id=[long]12345;repository_id=1406074259;head_repository_id=1406074259;head_sha=('a'*40)}}
}
AssertTerminalReplayArtifact (Artifact) (Run);Check $true
foreach($field in 'id','size_in_bytes','expired','digest'){
 foreach($bad in $null,$true,'PRIVATE_NEVER_PUBLISH',@('PRIVATE_NEVER_PUBLISH')){$artifact=Artifact;$artifact.$field=$bad;Refuses {AssertTerminalReplayArtifact $artifact (Run)}}
}
foreach($field in 'id','repository_id','head_repository_id','head_sha'){
 foreach($bad in $null,$true,'PRIVATE_NEVER_PUBLISH',@('PRIVATE_NEVER_PUBLISH')){$artifact=Artifact;$artifact.workflow_run.$field=$bad;Refuses {AssertTerminalReplayArtifact $artifact (Run)}}
}
foreach($size in -1,0,8589934593){$artifact=Artifact;$artifact.size_in_bytes=[long]$size;Refuses {AssertTerminalReplayArtifact $artifact (Run)}}
$artifact=Artifact;$artifact.workflow_run.id=12346;Refuses {AssertTerminalReplayArtifact $artifact (Run)}
$artifact=Artifact;$artifact.workflow_run.head_sha='f'*40;Refuses {AssertTerminalReplayArtifact $artifact (Run)}
if($ActualRunJson -or $ActualJobsJson){
 if(!$ActualRunJson -or !$ActualJobsJson){throw 'Both independently captured actual API snapshots are required.'}
 $run=Get-Content -LiteralPath $ActualRunJson -Raw|ConvertFrom-Json;$jobs=Get-Content -LiteralPath $ActualJobsJson -Raw|ConvertFrom-Json
 $proof=TerminalReplayProducers $run $jobs ([string]$run.id);Check ($proof.original_run_status -ceq 'in_progress' -and $proof.jobs.Count -eq 2)
 if($ActualArtifactsJson){$artifacts=Get-Content -LiteralPath $ActualArtifactsJson -Raw|ConvertFrom-Json;$selected=@($artifacts.artifacts|Where-Object {$_.name -ceq ('openwebpbx-windows-suite-candidate-'+$run.id) -or $_.name -ceq ('openwebpbx-windows-suite-facts-'+$run.id)});Check ($selected.Count -eq 2);foreach($artifact in $selected){AssertTerminalReplayArtifact $artifact $run;Check $true}}
}
Write-Output ('PASS '+$checks+' actual terminal-producer identity/attempt/job/export/privacy controls; original PBX remains unqualified')
