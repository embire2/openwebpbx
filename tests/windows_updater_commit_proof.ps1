# Execute the real native commit-proof validator and child-exit capture.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$script:checks=0
function Assert([bool]$Value){if(!$Value){throw ('Commit evidence control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
function Refuses([scriptblock]$Action){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Assert $failed}
function Parse([string]$Path){$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$t,[ref]$e);Assert ($e.Count -eq 0);return $ast}
$suite=Parse (Join-Path $SourceRoot 'tests/windows-suite.ps1');$wrapper=Parse (Join-Path $SourceRoot 'tests/windows-upgrade-recovery-qualification.ps1')
$nodes=@($suite.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Read-UpdaterCommitSelectionReport'},$true));Assert ($nodes.Count -eq 1);Invoke-Expression $nodes[0].Extent.Text
function Record {return [pscustomobject]@{schema=1;producer='windows_updater_commit_selection.ps1';state='passed';checks=133;guard_checks=52;actual_commit_interruption_positions=3;actual_native_windows=$true;service_adapter_double=$true;slot_assembly_fixture=$true;actual_running_image_lock=$true;old_silent_exit3_proven=$true;exact_mirror_refusal_retry=$true;completed_finalizer_idempotent=$true;before_commit_old_scm=$true;after_commit_resume=$true;after_selection_idempotent=$true;absent_creation_deferred=$true;legacy_missing_dependency_recovery=$true;actual_installed_scm=$false;installed_server_changed=$false;private='PRIVATE'}}
$safe=Read-UpdaterCommitSelectionReport (Record);Assert ($safe.Count -eq 18 -and ($safe|ConvertTo-Json -Compress) -cnotmatch 'PRIVATE|producer|schema')
foreach($value in @((Record),(ConvertFrom-Json -InputObject (Record|ConvertTo-Json -Compress)))){Assert ((Read-UpdaterCommitSelectionReport $value).checks -eq 133)}
foreach($bad in @($null,@(),@((Record)),[pscustomobject]@{},'unqualified_historical_candidate',$true)){Refuses {Read-UpdaterCommitSelectionReport $bad}}
foreach($field in @((Record).PSObject.Properties.Name|Where-Object {$_ -cne 'private'})){
 $minimum=switch($field){'schema'{1};'checks'{133};'guard_checks'{52};'actual_commit_interruption_positions'{3};default{0}}
 $badValues=if($field -ceq 'state'){@($null,$true,1,'Passed','passed ','failed',@('passed'),@{})}elseif($field -ceq 'producer'){@($null,$true,1,'PRIVATE',@('windows_updater_commit_selection.ps1'),@{})}elseif($minimum){@($null,$true,0,($minimum-1),100001,1.5,([decimal]$minimum),([string]$minimum),@($minimum),@{})}else{@($null,1,'true',@($true),@{},(-not (Record).$field))}
 if($field -ceq 'schema'){$badValues+=2};if($field -ceq 'actual_commit_interruption_positions'){$badValues+=4}
 foreach($bad in $badValues){$row=Record;$row.$field=$bad;Refuses {Read-UpdaterCommitSelectionReport $row}}
 $row=Record;$row.PSObject.Properties.Remove($field);Refuses {Read-UpdaterCommitSelectionReport $row}
 if($minimum){foreach($value in $minimum,([long]$minimum)){$row=Record;$row.$field=$value;Assert ((Read-UpdaterCommitSelectionReport $row).state -ceq 'passed')}}
}
# Capture $? immediately, before any array wrapping/logging can replace it.
$body=@($wrapper.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})[0].Body.Statements
$assign=@($body|Where-Object {$_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -ceq '$commitOutput' -and $_.Right.Extent.Text.StartsWith('& ')})
$capture=@($body|Where-Object {$_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -ceq '$commitSucceeded'})
Assert ($assign.Count -eq 1 -and $capture.Count -eq 1 -and $capture[0].Right.Extent.Text -ceq '$?' -and $body.IndexOf($capture[0]) -eq $body.IndexOf($assign[0])+1)
$work=Join-Path ([IO.Path]::GetTempPath()) ('openweb-commit-proof-'+[Guid]::NewGuid().ToString('N'));$originalSourceRoot=$SourceRoot
try{
 $null=[IO.Directory]::CreateDirectory((Join-Path $work 'tests'));$SourceRoot=$work
 foreach($exit in 0,1){
  $path=Join-Path $work 'tests/windows_updater_commit_selection.ps1';[IO.File]::WriteAllText($path,('param([string]$SourceRoot)'+"`n"+"Write-Output 'passed'`nexit "+$exit))
  Invoke-Expression ($assign[0].Extent.Text+"`n"+$capture[0].Extent.Text);Assert ($commitSucceeded -eq ($exit -eq 0) -and $commitOutput -ceq 'passed')
 }
}finally{$SourceRoot=$originalSourceRoot;Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction Stop}
Write-Output ('PASS '+$checks+' actual typed native commit-selection receipt, old-proof refusal and immediate child-exit controls')
