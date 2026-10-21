# Actual diagnostic replay guards only; no service, credentials or downloads.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$tokens=$null;$errors=$null;$checks=0
$path=Join-Path $SourceRoot 'tests/windows-suite.ps1';$text=[IO.File]::ReadAllText($path)
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Actual Suite source must parse.'}
foreach($name in 'AssertSuiteReplayMode','AssertSuiteMode','SafeRelative','AssertReplaySourcePaths'){
 $nodes=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true))
 if($nodes.Count -ne 1){throw 'Unique actual diagnostic guards required.'};Invoke-Expression $nodes[0].Extent.Text
}
function Check([bool]$Value){$script:checks++;if(!$Value){throw ('Backup replay control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)}}
function Refuses([scriptblock]$Action){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Check $failed}
$sha='a'*40;$zip='b'*64;$ref='embire2/openwebpbx/.github/workflows/windows-backups-diagnostics.yml@refs/heads/customization'
AssertSuiteMode $false $ref $sha $sha '' $true;Check $true
AssertSuiteReplayMode '12345' '' $false $true $false '67890' $zip;Check $true
AssertSuiteReplayMode '' '' $false $true $false '' '';Check $true
AssertSuiteReplayMode '12345' '' $false $false $false '' '';Check $true
AssertSuiteReplayMode '12345' '' $true $false $false '67890' $zip;Check $true
foreach($case in @(
 @('12345','foreign',$false,$true,$false,'67890',$zip),@('012345','',$false,$true,$false,'67890',$zip),
 @('12345','',$false,$true,$true,'67890',$zip),@('12345','',$true,$true,$false,'67890',$zip),
 @('12345','',$false,$true,$false,'',$zip),@('12345','',$false,$true,$false,'67890',''),
 @('12345','',$false,$true,$false,'067890',$zip),@('12345','',$false,$true,$false,'67890',$zip.ToUpperInvariant()),
 @('12345','',$false,$false,$false,'67890',$zip),@('','',$false,$true,$false,'67890',$zip),
 @('','',$false,$true,$true,'',''))){Refuses {AssertSuiteReplayMode @case}}
foreach($badRef in 'embire2/openwebpbx/.github/workflows/windows-suite.yml@refs/heads/customization','embire2/openwebpbx/.github/workflows/windows-upgrade-diagnostics.yml@refs/heads/customization','foreign/repo/.github/workflows/windows-backups-diagnostics.yml@refs/heads/customization'){
 Refuses {AssertSuiteMode $false $badRef $sha $sha '' $true}
}
AssertReplaySourcePaths @('.github/workflows/windows-backups-diagnostics.yml');Check $true
foreach($product in 'packaging/windows/backups.py','packaging/debian/tenant-domains.py','.github/workflows/windows-native.yml','.github/workflows/windows-engine.yml'){Refuses {AssertReplaySourcePaths @($product)}}
$workflow=[IO.File]::ReadAllText((Join-Path $SourceRoot '.github/workflows/windows-backups-diagnostics.yml'))
Check ($workflow.Contains('REPLAY_SUITE_RUN_ID: ${{ inputs.replay_suite_run_id }}'))
Check ($workflow.Contains('REPLAY_CANDIDATE_ARTIFACT_ID: ${{ inputs.replay_candidate_artifact_id }}'))
Check ($workflow.Contains('REPLAY_CANDIDATE_SHA256: ${{ inputs.replay_candidate_sha256 }}'))
Check ($workflow.Contains('-ReplaySuiteRunId $env:REPLAY_SUITE_RUN_ID -ReplayCandidateArtifactId $env:REPLAY_CANDIDATE_ARTIFACT_ID -ReplayCandidateSha256 $env:REPLAY_CANDIDATE_SHA256 -DisposableHostedRunner -BackupsDiagnosticsOnly'))
Check (!$workflow.Contains('contents: write') -and !$workflow.Contains('replay_terminal_producers'))
Check ($text.Contains("if(`$candidate.run.head_sha -cne `$original.run.head_sha)"))
Check ($text.Contains('The diagnostic candidate artifact ID differs from its explicit immutable pin.'))
Check ($text.Contains('The authenticated original candidate facts differ from the explicit diagnostic ZIP hash.'))
Check ($text.Contains('if($UpgradeDiagnosticsOnly -or $BackupsDiagnosticsOnly){$facts.replay.expected_candidate_artifact_id=$ReplayCandidateArtifactId;$facts.replay.expected_candidate_sha256=$ReplayCandidateSha256}'))
Write-Output ('PASS '+$checks+' actual backup replay source/mode/pin/privacy guards; no PBX or network invoked')
