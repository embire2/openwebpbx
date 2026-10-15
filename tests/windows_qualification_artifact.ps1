#Requires -Version 5.1
[CmdletBinding()]param([string]$SourceRoot)
# Exact artifact-selection statements with fictional API responses; no network.
$ErrorActionPreference='Stop';$checks=0
if(!$SourceRoot){$SourceRoot=Split-Path $PSScriptRoot -Parent}
function Verify([bool]$Value){$script:checks++;if(!$Value){throw ('Artifact selection control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)}}
function Check([bool]$Value,[string]$Message){if(!$Value){throw $Message}}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-updater-qualification.ps1'),[ref]$tokens,[ref]$errors)
Verify (@($errors).Count -eq 0)
$functions=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Artifact'},$true));Verify ($functions.Count -eq 1)
$parts=@();$selected=$null
foreach($statement in $functions[0].Body.EndBlock.Statements){
 $parts+=$statement.Extent.Text
 if($statement -is [Management.Automation.Language.AssignmentStatementAst] -and $statement.Left.Extent.Text -ceq '$artifact'){$selected=$statement;break}
}
Verify ($null -ne $selected -and $selected.Right.Extent.Text -ceq '$artifacts[0]')
$prefixText="param([string]`$RunId,[string]`$Name,[string]`$Workflow)`n"+($parts -join "`n")+"`nreturn `$artifact"
$prefix=[ScriptBlock]::Create($prefixText)
# Reintroduce only the old local name to reproduce its automatic-variable defect.
$legacy=[ScriptBlock]::Create($prefixText.Replace('$artifacts','$matches'))
$runId='123';$name='openwebpbx-windows-suite-candidate-123';$workflow='.github/workflows/windows-suite.yml';$digest='sha256:'+('a'*64)
function ResetFixture {
 $script:runDocument=[pscustomobject]@{repository=[pscustomobject]@{full_name='embire2/openwebpbx'};head_repository=[pscustomobject]@{full_name='embire2/openwebpbx'};event='workflow_dispatch';path=$workflow;head_sha=('b'*40);status='completed';conclusion='success'}
 $script:artifactDocument=[pscustomobject]@{artifacts=@([pscustomobject]@{id=456;name=$name;digest=$digest;size_in_bytes=[long]1000;expired=$false})};$script:apiCalls=0
}
function Api([string]$Endpoint){
 $script:apiCalls++
 if($Endpoint -ceq ('actions/runs/'+$runId)){return $script:runDocument}
 if($Endpoint -ceq ('actions/runs/'+$runId+'/artifacts?per_page=100')){return $script:artifactDocument}
 throw 'Unexpected fictional API request.'
}
function Refuses([string]$Expected,[int]$Calls){
 $refused=$false;try{$null=& $prefix $runId $name $workflow}catch{$refused=$_.Exception.Message -ceq $Expected}
 Verify ($refused -and $apiCalls -eq $Calls)
}
ResetFixture;$old=& $legacy $runId $name $workflow
Verify ($old -is [string] -and $old -ceq $digest -and $null -eq $old.id)
ResetFixture;$actual=& $prefix $runId $name $workflow
Verify ($actual -is [pscustomobject] -and $actual.id -eq 456 -and $actual.name -ceq $name -and $actual.digest -ceq $digest -and $actual.size_in_bytes -eq 1000 -and !$actual.expired -and $apiCalls -eq 2)
foreach($case in 'repository','head_repository','event','path','head_sha','status','conclusion'){
 ResetFixture
 switch($case){
  'repository'{$runDocument.repository.full_name='unowned/repository'}
  'head_repository'{$runDocument.head_repository.full_name='unowned/repository'}
  'event'{$runDocument.event='push'}
  'path'{$runDocument.path='.github/workflows/windows-upgrade-diagnostics.yml'}
  'head_sha'{$runDocument.head_sha='invalid'}
  'status'{$runDocument.status='in_progress'}
  'conclusion'{$runDocument.conclusion='failure'}
 }
 Refuses 'The exact successful owned workflow is required.' 1
}
foreach($case in 'absent','multiple','expired','wrong_name','missing_digest','bad_digest','oversized'){
 ResetFixture
 switch($case){
  'absent'{$artifactDocument.artifacts=@()}
  'multiple'{$artifactDocument.artifacts=@($artifactDocument.artifacts[0],$artifactDocument.artifacts[0])}
  'expired'{$artifactDocument.artifacts[0].expired=$true}
  'wrong_name'{$artifactDocument.artifacts[0].name='different-artifact'}
  'missing_digest'{$artifactDocument.artifacts[0].digest=$null}
  'bad_digest'{$artifactDocument.artifacts[0].digest='sha256:invalid'}
  'oversized'{$artifactDocument.artifacts[0].size_in_bytes=[long]8GB+1}
 }
 Refuses 'One exact bounded artifact is required.' 2
}
ResetFixture;$artifactDocument.artifacts+=@([pscustomobject]@{id=999;name=$name;digest=$digest;size_in_bytes=1000;expired=$true},[pscustomobject]@{id=998;name='unrelated';digest=$digest;size_in_bytes=1000;expired=$false})
$actual=& $prefix $runId $name $workflow;Verify ($actual.id -eq 456 -and $apiCalls -eq 2)
# Restore imports the same whole Artifact function, including its retained gates.
$restore=[IO.File]::ReadAllText((Join-Path $SourceRoot 'tests/windows-restore-qualification.ps1'))
Verify ($restore.Contains("'Api','Artifact','CheckedProcess'"))
@{schema=1;state='passed';actual_source_controls=$checks;legacy_automatic_matches_collision_reproduced=$true;network_or_artifact_download_performed=$false}|ConvertTo-Json -Compress
