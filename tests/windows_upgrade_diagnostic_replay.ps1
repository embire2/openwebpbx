# Actual replay mode/provenance guards; fictional private JSON only, no downloads.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$tokens=$null;$errors=$null
$path=Join-Path $SourceRoot 'tests/windows-suite.ps1';$text=[IO.File]::ReadAllText($path)
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Actual Suite source must parse.'}
foreach($name in 'AssertSuiteMode','AssertSuiteReplayMode','ReplayFacts','PrepareReplayCandidate'){
 $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))
 if($nodes.Count -ne 1){throw 'Actual replay functions must be unique.'};Invoke-Expression $nodes[0].Extent.Text
}
$checks=0
function Check([bool]$Value){$script:checks++;if(!$Value){throw ('Diagnostic replay control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)}}
function Refuses([scriptblock]$Action){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Check $failed}
$sha='a'*40;$zip='b'*64;$workflow='embire2/openwebpbx/.github/workflows/windows-upgrade-diagnostics.yml@refs/heads/customization'
AssertSuiteMode $true $workflow $sha $sha ''
AssertSuiteReplayMode '12345' '' $true $false $false '67890' $zip;Check $true
AssertSuiteReplayMode '12345' '' $false $false $false '' '';Check $true
AssertSuiteReplayMode '12345' '' $false $false $true '' '';Check $true
AssertSuiteReplayMode '' '' $true $false $false '' '';Check $true
foreach($case in @(
 @('12345','foreign-package',$true,$false,$false,'67890',$zip),
 @('12345','',$true,$true,$false,'67890',$zip),
 @('12345','',$true,$false,$true,'67890',$zip),
 @('12345','',$true,$false,$false,'',$zip),
 @('12345','',$true,$false,$false,'67890',''),
 @('012345','',$true,$false,$false,'67890',$zip),
 @('12345','',$true,$false,$false,'067890',$zip),
 @('12345','',$true,$false,$false,'67890',$zip.ToUpperInvariant()),
 @('12345','',$false,$false,$false,'67890',$zip),
 @('','',$true,$false,$false,'67890',$zip),
 @('','',$false,$false,$true,'',''))){Refuses {AssertSuiteReplayMode @case}}
foreach($ref in 'foreign/repo/.github/workflows/windows-upgrade-diagnostics.yml@refs/heads/customization','embire2/openwebpbx/.github/workflows/windows-suite.yml@refs/heads/customization','embire2/openwebpbx/.github/workflows/windows-upgrade-diagnostics.yml@refs/pull/1/merge'){
 Refuses {AssertSuiteMode $true $ref $sha $sha ''}
}
Check ($text.IndexOf('AssertSuiteMode $UpgradeDiagnosticsOnly') -lt $text.IndexOf('AssertSuiteReplayMode $ReplaySuiteRunId'))
$work=Join-Path ([IO.Path]::GetTempPath()) ('openweb-diagnostic-replay-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
try{
 $source=Join-Path $work 'source';$candidateDir=Join-Path $work 'candidate';$factsDir=Join-Path $work 'original-facts'
 foreach($directory in $source,$candidateDir,$factsDir){[void][IO.Directory]::CreateDirectory($directory)}
 [IO.File]::WriteAllText((Join-Path $source 'VERSION'),'1.0.20')
 $record=@{schema=1;run_id='12345';source_commit=$sha;state='failed';candidate_artifact=@{filename='openwebpbx-1.0.20-windows-x64.zip';sha256=$zip;verified_before_credentials=$true;private_exclusions='passed'};artifacts=@{candidate_sha256=$zip;native_run='111';engine_run='222';native_digest=('sha256:'+('c'*64));engine_digest=('sha256:'+('d'*64));music_digest=('sha256:'+('e'*64))}}
 [IO.File]::WriteAllText((Join-Path $factsDir 'qualification.json'),($record|ConvertTo-Json -Depth 8))
 $ReplaySuiteRunId='12345';$ReplayCandidateArtifactId='67890';$ReplayCandidateSha256=$zip
 $script:artifactCalls=[Collections.Generic.List[string]]::new();$script:gitReached=$false
 function Artifact([string]$RunId,[string]$Kind){
  Check ($RunId -ceq '12345');$script:artifactCalls.Add($Kind)
  return @{directory=$(if($Kind -ceq 'replay_candidate'){$candidateDir}else{$factsDir});run=[pscustomobject]@{head_sha=$sha};artifact=[pscustomobject]@{id=67890};producer_proof=$null}
 }
 function git {$script:gitReached=$true;throw 'owned_replay_source_boundary'}
 function RunBoundary {
  $script:artifactCalls.Clear();$script:gitReached=$false;$script:caught=''
  try{PrepareReplayCandidate|Out-Null}catch{$script:caught=$_.Exception.Message}
 }
 # The real function checks the immutable ID before even fetching facts.
 $ReplayCandidateArtifactId='67891';RunBoundary
 Check (!$gitReached -and $artifactCalls.Count -eq 1 -and $caught -ceq 'The diagnostic candidate artifact ID differs from its explicit immutable pin.')
 # Authentic original facts must agree with the explicit expected inner hash.
 $ReplayCandidateArtifactId='67890';$ReplayCandidateSha256='f'*64;RunBoundary
 Check (!$gitReached -and $artifactCalls.Count -eq 2 -and $caught -ceq 'The authenticated original candidate facts differ from the explicit diagnostic ZIP hash.')
 $ReplayCandidateSha256=$zip;$ReplaySuiteRunId='12346';RunBoundary
 Check (!$gitReached -and $caught -ne 'owned_replay_source_boundary')
 $ReplaySuiteRunId='12345';RunBoundary
 Check ($gitReached -and $caught -ceq 'owned_replay_source_boundary' -and $artifactCalls.Count -eq 2)
 # Source drift, full ZIP validation, exact extraction and no-overlay checks
 # remain after the binding assertions and before any normal installer call.
 Check ($text.Contains('AssertReplaySourcePaths $changed') -and $text.Contains('(Hash $archive) -cne $provenance.candidate_sha256'))
 Check ($text.Contains('windows_runtime_source_identical=$true;runtime_overlays=$false'))
 $workflowText=[IO.File]::ReadAllText((Join-Path $SourceRoot '.github/workflows/windows-upgrade-diagnostics.yml'))
 Check ($workflowText.Contains('REPLAY_SUITE_RUN_ID: ${{ inputs.replay_suite_run_id }}') -and $workflowText.Contains('REPLAY_CANDIDATE_ARTIFACT_ID: ${{ inputs.replay_candidate_artifact_id }}') -and $workflowText.Contains('REPLAY_CANDIDATE_SHA256: ${{ inputs.replay_candidate_sha256 }}'))
 Check ($workflowText.Contains('-ReplaySuiteRunId $env:REPLAY_SUITE_RUN_ID -ReplayCandidateArtifactId $env:REPLAY_CANDIDATE_ARTIFACT_ID -ReplayCandidateSha256 $env:REPLAY_CANDIDATE_SHA256'))
 Check ($workflowText.Contains("if: `$`{{ inputs.replay_suite_run_id == '' }}"))
 Check ($workflowText.Contains("needs.music.result == 'success'") -and $workflowText.Contains("needs.music.result == 'skipped' && inputs.replay_suite_run_id != ''"))
 Check (!$workflowText.Contains('replay_terminal_producers') -and !$workflowText.Contains('contents: write'))
 Check ($text.Contains("`$facts.release_eligible=`$false;`$facts.owner_transaction_eligible=`$false}"))
 Check ($text.Contains("elseif(`$UpgradeDiagnosticsOnly -or `$BackupsDiagnosticsOnly){'partial'}"))
}finally{[IO.Directory]::Delete($work,$true)}
Write-Output ('PASS '+$checks+' exact diagnostic replay/mode/pin/source/privacy controls; no PBX or network invoked')
