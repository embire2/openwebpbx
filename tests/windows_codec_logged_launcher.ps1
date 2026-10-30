# Actual stock PS5/native-process boundary; owned temporary emitters only.
# This does not compile/install a codec or access a task, service or database.
[CmdletBinding()]
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent),[string]$Python='')
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';$checks=0
function Verify([bool]$Value,[string]$Label){if(!$Value){throw ('Logged codec launcher control refused: '+$Label)};$script:checks++}
Verify ($PSVersionTable.PSEdition -ceq 'Desktop' -and $PSVersionTable.PSVersion.Major -eq 5) 'actual stock Windows PowerShell5 required'
if(!$Python){$Python=(Get-Command python.exe -CommandType Application -ErrorAction Stop|Select-Object -First 1).Source}
$pythonFile=Get-Item -LiteralPath $Python -Force
Verify (!$pythonFile.PSIsContainer -and !($pythonFile.Attributes-band [IO.FileAttributes]::ReparsePoint) -and $pythonFile.Name -ieq 'python.exe') 'ordinary actual Python executable required'
$interpreter=$Python
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'packaging/windows/Install-LocalCodec.ps1'),[ref]$tokens,[ref]$errors)
Verify (!$errors.Count) 'actual product source must parse'
$commands=@($ast.FindAll({param($n)$n-is [Management.Automation.Language.CommandAst] -and $n.Extent.Text.StartsWith('& $python -I -B ') -and $n.Extent.Text.Contains('build-windows-local.py')},$true))
Verify ($commands.Count -eq 1) 'one exact isolated native launcher required'
$native=$commands[0];$owner=$native.Parent
while($owner -and $owner-isnot [Management.Automation.Language.TryStatementAst]){$owner=$owner.Parent}
Verify ($null-ne $owner -and $owner.Parent-is [Management.Automation.Language.NamedBlockAst]) 'launcher must be in the top-level protected block'
$statements=@($owner.Parent.Statements);$index=[array]::IndexOf($statements,$owner)
Verify ($index-ge 2 -and $index+2-lt $statements.Count) 'complete adjacent launcher contract required'
$saved=$statements[$index-2];$initial=$statements[$index-1];$guard=$statements[$index+1];$manifest=$statements[$index+2]
Verify ($saved-is [Management.Automation.Language.AssignmentStatementAst] -and $saved.Right.Extent.Text-ceq '$ErrorActionPreference' -and $saved.Left.Extent.Text-cmatch '^\$[A-Za-z][A-Za-z0-9]*$') 'original preference must be saved'
Verify ($initial-is [Management.Automation.Language.AssignmentStatementAst] -and $initial.Left.Extent.Text-ceq '$codecBuildExitCode' -and $initial.Right.Extent.Text-ceq '$null') 'exit result must start unset'
$body=@($owner.Body.Statements)
Verify ($body.Count-eq 4 -and ($body[0].Extent.Text-replace '\s','')-ceq "`$ErrorActionPreference='Continue'" -and ($body[1].Extent.Text-replace '\s','')-ceq '$global:LASTEXITCODE=$null' -and $body[2].Extent.Text-ceq $native.Extent.Text -and ($body[3].Extent.Text-replace '\s','')-ceq '$codecBuildExitCode=$global:LASTEXITCODE') 'only native execution receives Continue and a fresh result'
Verify ($owner.CatchClauses.Count-eq 0 -and @($owner.Finally.Statements).Count-eq 1 -and ($owner.Finally.Statements[0].Extent.Text-replace '\s','')-ceq ('$ErrorActionPreference='+$saved.Left.Extent.Text)) 'finally must restore the exact prior preference'
Verify ($guard-is [Management.Automation.Language.IfStatementAst] -and $guard.Clauses.Count-eq 1 -and !$guard.ElseClause -and ($guard.Clauses[0].Item1.Extent.Text-replace '\s','')-ceq '$null-eq$codecBuildExitCode-or$codecBuildExitCode-ne0' -and $guard.Clauses[0].Item2.Statements.Count-eq 1 -and $guard.Clauses[0].Item2.Statements[0]-is [Management.Automation.Language.ThrowStatementAst]) 'unset/nonzero exit must refuse before manifest or copying'
Verify ($manifest-is [Management.Automation.Language.AssignmentStatementAst] -and $manifest.Left.Extent.Text-ceq '$built' -and $manifest.Extent.Text.Contains('local-codec-manifest.json') -and $manifest.Extent.Text.Contains('Get-Content')) 'actual manifest read must immediately follow the exit guard'
$copies=@($ast.FindAll({param($n)$n-is [Management.Automation.Language.CommandAst] -and $n.GetCommandName()-ceq 'Copy-Item'},$true))
Verify ($copies.Count-eq 1 -and $copies[0].Extent.StartOffset-gt $guard.Extent.EndOffset) 'all product copying stays after the guarded exit'
$launcher=$ast.Extent.Text.Substring($saved.Extent.StartOffset,$guard.Extent.EndOffset-$saved.Extent.StartOffset)
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('OpenWeb-CodecLogged-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $temporary
$priorCase=$env:OPENWEB_CODEC_LOGGED_FIXTURE
try{
 foreach($case in 'old_stderr_zero','fixed_stderr_zero','fixed_stderr_seven','fixed_missing_exe_stale_zero','fixed_missing_manifest'){
  $caseRoot=Join-Path $temporary ($case+" package's spaced path");$null=New-Item -ItemType Directory -Path $caseRoot
  $PackageRoot=$caseRoot;$recipeRoot=Join-Path $caseRoot 'recipe';$null=New-Item -ItemType Directory -Path $recipeRoot
  $work=$caseRoot;$output=Join-Path $caseRoot 'output';$EngineRoot=Join-Path $caseRoot 'unused-engine';$StateRoot=Join-Path $caseRoot 'unused-state'
  $recipe=[pscustomobject]@{source_manifest_sha256='unused';core_sha256='unused';apr_sha256='unused'}
  [IO.File]::WriteAllText((Join-Path $recipeRoot 'build-windows-local.py'),@'
import os,sys
from pathlib import Path
mode=os.environ['OPENWEB_CODEC_LOGGED_FIXTURE']
os.write(1,b'OPENWEB_CODEC_QA_STDOUT\n')
os.write(2,b'OPENWEB_CODEC_QA_STDERR\n')
output=Path(sys.argv[sys.argv.index('--output')+1])
if mode!='fixed_missing_manifest':
    output.mkdir(exist_ok=True)
    (output/'local-codec-manifest.json').write_text('{"owned_emitter":true}')
sys.exit(7 if mode=='fixed_stderr_seven' else 0)
'@,[Text.UTF8Encoding]::new($false))
  if($case-ceq 'fixed_missing_exe_stale_zero'){
   $python=Join-Path $caseRoot 'missing.exe';$null=New-Item -ItemType Directory -Path $output
   [IO.File]::WriteAllText((Join-Path $output 'local-codec-manifest.json'),'{"owned_emitter":true}')
  }else{$python=$interpreter}
  $env:OPENWEB_CODEC_LOGGED_FIXTURE=$case
  $script:launcherFinished=$false;$script:manifestFinished=$false;$script:preferenceRestored=$false
  $run={
   $ErrorActionPreference='Stop';$global:LASTEXITCODE=0
   try{
    if($case-ceq 'old_stderr_zero'){Invoke-Expression $native.Extent.Text}else{Invoke-Expression $launcher}
    $script:launcherFinished=$true
    Invoke-Expression $manifest.Extent.Text
    Verify ($built.owned_emitter-is [bool] -and $built.owned_emitter) 'owned actual manifest read required'
    $script:manifestFinished=$true
   }finally{$script:preferenceRestored=($ErrorActionPreference-ceq 'Stop')}
  }
  $caught=$null;$log=Join-Path $caseRoot 'merged.private.log'
  try{& $run *> $log}catch{$caught=$_}
  Verify $script:preferenceRestored ('Stop restoration '+$case)
  if($case-ceq 'fixed_stderr_zero'){
   Verify ($null-eq $caught -and $script:launcherFinished -and $script:manifestFinished) 'stderr with real exit0 must succeed under merged logging'
  }elseif($case-ceq 'fixed_missing_manifest'){
   Verify ($null-ne $caught -and $script:launcherFinished -and !$script:manifestFinished) 'successful process cannot bypass a missing manifest'
  }else{
   Verify ($null-ne $caught -and !$script:launcherFinished -and !$script:manifestFinished) ('old/refused process cannot reach manifest '+$case)
  }
  if($case-ceq 'fixed_stderr_zero'){
   $text=[IO.File]::ReadAllText($log)
   Verify ($text.Contains('OPENWEB_CODEC_QA_STDOUT') -and $text.Contains('OPENWEB_CODEC_QA_STDERR')) 'both actual native streams must remain logged'
  }
 }
 [ordered]@{schema=1;state='passed';checks=$checks;actual_windows_powershell5=$true;actual_native_process=$true;source_launcher_extracted=$true;old_merged_stderr_refusal_reproduced=$true;stderr_zero_succeeds=$true;nonzero_and_unset_refused=$true;missing_manifest_refused=$true;preference_restored=$true;installed_server_changed=$false;codec_compilation_qualified=$false}|ConvertTo-Json -Compress
}finally{
 if($null-eq $priorCase){Remove-Item Env:\OPENWEB_CODEC_LOGGED_FIXTURE -ErrorAction SilentlyContinue}else{$env:OPENWEB_CODEC_LOGGED_FIXTURE=$priorCase}
 if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Recurse -Force}
}
