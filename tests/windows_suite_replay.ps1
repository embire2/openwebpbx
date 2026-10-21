# Actual replay source/facts guards. No download, service or PBX is invoked.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-suite.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The actual suite must parse.'}
foreach($name in 'SafeRelative','AssertReplaySourcePaths','ReplayFacts','Artifact'){
 $nodes=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true))
 if($nodes.Count -ne 1){throw 'Actual replay guards must be unique.'};Invoke-Expression $nodes[0].Extent.Text
}
$checks=0
function Check([bool]$Value){if(!$Value){throw 'The exact-candidate replay guard failed.'};$script:checks++}
function Refuses([scriptblock]$Action){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Check $failed}
foreach($path in 'tests/windows_meet_proxy.ps1','tests/owned-qa.py','docs/installing-1.0.20.md','AGENTS.md','README.md','readme.md','3CX.md','packaging/BUILDING.md','.github/workflows/windows-suite.yml','packaging/debian/install-tenant-domains.py'){
 AssertReplaySourcePaths @($path);Check $true
}
AssertReplaySourcePaths @();Check $true
foreach($path in 'VERSION','ADMIN_VERSION','app/pbx_setup/index.php','core/desktop/index.php','resources/functions.php','platform/Directory.Build.props','packaging/windows/Tenant-Domains.ps1','packaging/windows/bootstrap.php','packaging/debian/tenant-domains.py','packaging/debian/tenant-domains.php','packaging/build-release.py','packaging/voices/catalog.json','packaging/updates/release-public.pem','packaging/freeswitch/core-exports.py','tests/pbx_bcg729_codec.c','tests/pbx_windows_pthread.c','.github/workflows/windows-engine.yml','tests/../VERSION','docs//invalid.md'){
 Refuses {AssertReplaySourcePaths @($path)}
}
$run=[pscustomobject]@{head_sha=('a'*40)}
function Record {
 [pscustomobject]@{schema=1;run_id='12345';source_commit=('a'*40);state='failed';candidate_artifact=[pscustomobject]@{filename='openwebpbx-1.0.20-windows-x64.zip';sha256=('b'*64);verified_before_credentials=$true;private_exclusions='passed'};artifacts=[pscustomobject]@{candidate_sha256=('b'*64);native_run='111';engine_run='222';native_digest=('sha256:'+('c'*64));engine_digest=('sha256:'+('d'*64));music_digest=('sha256:'+('e'*64));password='PRIVATE_NEVER_PUBLISH'};password='PRIVATE_NEVER_PUBLISH'}
}
$safe=ReplayFacts (Record) $run '1.0.20' '12345'
Check ($safe.Count -eq 6 -and $safe.candidate_sha256 -ceq ('b'*64))
Check (($safe|ConvertTo-Json) -cnotmatch 'PRIVATE_NEVER_PUBLISH|password')
foreach($state in 'failed','partial','passed'){$record=Record;$record.state=$state;$null=ReplayFacts $record $run '1.0.20' '12345';Check $true}
foreach($field in 'schema','run_id','source_commit','state'){
 foreach($bad in $null,$true,'PRIVATE_NEVER_PUBLISH',@('PRIVATE_NEVER_PUBLISH')){
  $record=Record;$record.$field=$bad;Refuses {ReplayFacts $record $run '1.0.20' '12345'}
 }
}
foreach($field in 'filename','sha256','verified_before_credentials','private_exclusions'){
 foreach($bad in $null,$false,'PRIVATE_NEVER_PUBLISH',@('PRIVATE_NEVER_PUBLISH')){
  $record=Record;$record.candidate_artifact.$field=$bad;Refuses {ReplayFacts $record $run '1.0.20' '12345'}
 }
}
foreach($field in 'candidate_sha256','native_run','engine_run','native_digest','engine_digest','music_digest'){
 foreach($bad in $null,$true,'PRIVATE_NEVER_PUBLISH',@('PRIVATE_NEVER_PUBLISH')){
  $record=Record;$record.artifacts.$field=$bad;Refuses {ReplayFacts $record $run '1.0.20' '12345'}
 }
}
foreach($field in 'replay','product_source_commit'){
 $record=Record;$record|Add-Member -NotePropertyName $field -NotePropertyValue $false
 Refuses {ReplayFacts $record $run '1.0.20' '12345'}
}
$text=[IO.File]::ReadAllText((Join-Path $SourceRoot 'tests/windows-suite.ps1'))
Check ($text.Contains('diff --name-only --no-renames') -and $text.Contains('AssertReplaySourcePaths $changed'))
Check ($text.Contains('$facts.product_source_commit=$candidate.run.head_sha') -and $text.Contains('windows_runtime_source_identical=$true;runtime_overlays=$false'))
Check ($text.Contains("'--archive',`$archive,'--version',`$version,'--sha256',`$provenance.candidate_sha256"))
$workflow=[IO.File]::ReadAllText((Join-Path $SourceRoot '.github/workflows/windows-suite.yml'))
Check ($workflow.Contains('REPLAY_SUITE_RUN_ID: ${{ inputs.replay_suite_run_id }}') -and $workflow.Contains('-ReplaySuiteRunId $env:REPLAY_SUITE_RUN_ID'))
function OriginalRun([string]$State='completed',[string]$Conclusion='failure'){
 [pscustomobject]@{repository=[pscustomobject]@{full_name='embire2/openwebpbx'};head_repository=[pscustomobject]@{full_name='embire2/openwebpbx'};event='workflow_dispatch';path='.github/workflows/windows-suite.yml';head_sha=('a'*40);status=$State;conclusion=$Conclusion}
}
function Start-Sleep([int]$Seconds){Check ($Seconds -eq 10);$script:waits++}
function Api([string]$Endpoint){
 $script:apiCalls++
 if($Endpoint.EndsWith('/artifacts?per_page=100')){$script:artifactQueries++;return [pscustomobject]@{artifacts=@()}}
 $index=[Math]::Min($script:apiCalls-1,$script:runs.Count-1);return $script:runs[$index]
}
$script:runs=@((OriginalRun 'in_progress' ''),(OriginalRun));$script:waits=0;$script:apiCalls=0;$script:artifactQueries=0
# Empty owned artifact inventory deliberately stops after the terminal guard,
# before any file/network download. The real queued-to-completed wait executes.
Refuses {Artifact '12345' 'replay_candidate'}
Check ($waits -eq 1 -and $apiCalls -eq 3 -and $artifactQueries -eq 1)
$changed=OriginalRun;$changed.head_sha='f'*40;$script:runs=@((OriginalRun 'in_progress' ''),$changed);$script:waits=0;$script:apiCalls=0;$script:artifactQueries=0
Refuses {Artifact '12345' 'replay_candidate'};Check ($waits -eq 1 -and $apiCalls -eq 2 -and $artifactQueries -eq 0)
$script:runs=@((OriginalRun 'completed' 'cancelled'));$script:waits=0;$script:apiCalls=0;$script:artifactQueries=0
Refuses {Artifact '12345' 'replay_candidate'};Check ($waits -eq 0 -and $apiCalls -eq 1 -and $artifactQueries -eq 0)
$foreign=OriginalRun 'in_progress' '';$foreign.repository.full_name='foreign/project';$script:runs=@($foreign);$script:waits=0;$script:apiCalls=0;$script:artifactQueries=0
Refuses {Artifact '12345' 'replay_candidate'};Check ($waits -eq 0 -and $artifactQueries -eq 0)
$build=OriginalRun 'in_progress' '';$build.path='.github/workflows/windows-native.yml';$script:runs=@($build);$script:waits=0;$script:apiCalls=0;$script:artifactQueries=0
Refuses {Artifact '12345' 'native'};Check ($waits -eq 0 -and $artifactQueries -eq 0)
$ownedRepo=Join-Path ([IO.Path]::GetTempPath()) ('openweb-replay-git-'+[Guid]::NewGuid().ToString('N'))
try{
 [void][IO.Directory]::CreateDirectory($ownedRepo);[void][IO.Directory]::CreateDirectory((Join-Path $ownedRepo 'packaging/windows'))
 [IO.File]::WriteAllText((Join-Path $ownedRepo 'app.php'),'owned fixture');[IO.File]::WriteAllText((Join-Path $ownedRepo 'packaging/windows/fixture.ps1'),'owned fixture')
 & git init --quiet $ownedRepo;if($LASTEXITCODE){throw 'Owned Git fixture initialization failed.'}
 & git -C $ownedRepo add .;if($LASTEXITCODE){throw 'Owned Git fixture staging failed.'}
 & git -C $ownedRepo -c user.name=Qualification -c user.email=qualification@example.invalid -c commit.gpgsign=false commit --quiet -m baseline;if($LASTEXITCODE){throw 'Owned Git fixture baseline failed.'}
 $baseline=(& git -C $ownedRepo rev-parse HEAD).Trim()
 & git -C $ownedRepo rm --quiet app.php;if($LASTEXITCODE){throw 'Owned Git fixture deletion failed.'}
 & git -C $ownedRepo update-index --chmod=+x packaging/windows/fixture.ps1;if($LASTEXITCODE){throw 'Owned Git fixture mode change failed.'}
 & git -C $ownedRepo -c user.name=Qualification -c user.email=qualification@example.invalid -c commit.gpgsign=false commit --quiet -m changed;if($LASTEXITCODE){throw 'Owned Git fixture mutation failed.'}
 $changed=@(& git -C $ownedRepo diff --name-only --no-renames $baseline HEAD --);if($LASTEXITCODE){throw 'Owned Git fixture tree comparison failed.'}
 Check ($changed.Count -eq 2 -and $changed -ccontains 'app.php' -and $changed -ccontains 'packaging/windows/fixture.ps1')
 Refuses {AssertReplaySourcePaths $changed}
}finally{if([IO.Directory]::Exists($ownedRepo)){[IO.Directory]::Delete($ownedRepo,$true)}}
Write-Output ('PASS '+$checks+' actual original-facts/source-drift/privacy/workflow replay controls; no PBX invoked')
