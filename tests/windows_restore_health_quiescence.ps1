# QA-only restore ordering controls. Native Scheduler/continuous operation is
# qualified separately; these retain complete Health row/file comparisons.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$checks=0
function AssertControl([bool]$Value){$script:checks++;if(!$Value){throw ('Restore Health quiescence control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)}}
function RestoreHealthOrdering([string]$Text){
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errors)
 if($errors.Count){throw 'The restore qualification source must parse.'}
 $commands=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst]},$true))
 $suspend=@($commands|Where-Object {$_.GetCommandName() -ceq 'Suspend-OpenWebQualificationHealth'})
 $resume=@($commands|Where-Object {$_.GetCommandName() -ceq 'Resume-OpenWebQualificationHealth'})
 if($suspend.Count -ne 2 -or $resume.Count -ne 1){throw 'Both pre-baseline and final disposable quiescence are required.'}
 $pin=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$PackageRoot' -and $node.Right.Extent.Text -ceq '$package'},$true))
 if($pin.Count -ne 1 -or $pin[0].Extent.EndOffset -gt $suspend[0].Extent.StartOffset){throw 'Health helper hashes must bind the exact authenticated candidate package.'}
 $baseline=@($commands|Where-Object {$_.GetCommandName() -ceq 'Fixture' -and $_.Extent.Text -ceq "Fixture 'baseline'"})
 if($baseline.Count -ne 1 -or $suspend[0].Extent.EndOffset -gt $baseline[0].Extent.StartOffset){throw 'Health must stop before the first factory baseline.'}
 $native=@($commands|Where-Object {$_.GetCommandName() -ceq 'NativeFixture'})
 foreach($action in 'setup','native-source','export-source','late-restore','restore','activate-calls','native-target','job','activate-updates-backups','target-backup','cleanup'){
  $call=@($native|Where-Object {$_.Extent.Text -ceq ("NativeFixture '"+$action+"'")})
  if($call.Count -ne 1 -or $call[0].Extent.StartOffset -lt $suspend[0].Extent.EndOffset -or $call[0].Extent.EndOffset -gt $resume[0].Extent.StartOffset){throw 'The complete source/target lifecycle must remain quiescent until comparisons finish.'}
 }
 $outer=@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})[-1]
 if(!$outer.Finally -or $resume[0].Extent.StartOffset -lt $outer.Finally.Extent.StartOffset -or $resume[0].Extent.EndOffset -gt $suspend[1].Extent.StartOffset){throw 'Original choices must restore only in cleanup, then the owned worker must stop again.'}
 $locks=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$cleanupLock'},$true))
 if($locks.Count -ne 1 -or $locks[0].Extent.StartOffset -lt $outer.Finally.Extent.StartOffset -or $locks[0].Extent.EndOffset -gt $resume[0].Extent.StartOffset -or !$locks[0].Extent.Text.Contains("'ReadWrite','None'")){throw 'Exclusive maintenance ownership must cover original-state replay and teardown.'}
 $shutdown=@($commands|Where-Object {$_.GetCommandName() -ceq 'Stop-Service' -and $_.Extent.StartOffset -gt $outer.Finally.Extent.StartOffset})
 if(!$shutdown.Count -or $shutdown[0].Extent.StartOffset -lt $suspend[1].Extent.EndOffset){throw 'Exact worker/process quiescence must finish before disposable services stop.'}
 if(!$Text.Contains("'OpenWebPBX-TenantDomains','OpenWebPBX-PhoneHealth','OpenWebPBX Certificate Renewal'") -or !$Text.Contains("foreach(`$name in `$originalTaskStates.Keys)")){throw 'Explicit activation must still verify the disabled Health task choice.'}
 if(!$Text.Contains('original_choice_restored=$true') -or !$Text.Contains('quiescent_before_shutdown=$true')){throw 'Closed cleanup evidence must distinguish restoring a choice from stopping a disposable worker.'}
 return $true
}
$text=[IO.File]::ReadAllText((Join-Path $SourceRoot 'tests/windows-restore-qualification.ps1'))
AssertControl (RestoreHealthOrdering $text)
foreach($pair in @(
 @('missing first stop',"Suspend-OpenWebQualificationHealth ([ref]`$qualificationHealthOriginal)",''),
 @('missing last stop',"`$cleanupHealth=`$null;Suspend-OpenWebQualificationHealth ([ref]`$cleanupHealth)",''),
 @('missing package pin',';$PackageRoot=$package;',';'),
 @('resume before source snapshot',"NativeFixture 'export-source'","Resume-OpenWebQualificationHealth `$qualificationHealthOriginal;NativeFixture 'export-source'"),
 @('unlocked teardown',"'OpenOrCreate','ReadWrite','None'","'OpenOrCreate','ReadWrite','ReadWrite'"),
 @('activation ignores Health',"'OpenWebPBX-TenantDomains','OpenWebPBX-PhoneHealth','OpenWebPBX Certificate Renewal'","'OpenWebPBX-TenantDomains','OpenWebPBX Certificate Renewal'")
)){
 AssertControl ($text.Contains($pair[1]));$changed=$text.Replace($pair[1],$pair[2]);$refused=$false
 try{$null=RestoreHealthOrdering $changed}catch{$refused=$true};AssertControl $refused
}
# Exercise the actual shared helper's enabled/disabled/missing choices,
# helper hash binding, SYSTEM identity, process/spool and timeout refusals.
& (Join-Path $SourceRoot 'tests/windows_upgrade_health_quiescence.ps1') -SourceRoot $SourceRoot
AssertControl $?
Write-Output ('PASS '+$checks+' restore source/target/package/lock/activation ordering and causal omission controls; exact shared Scheduler/CIM control matrix also passed')
