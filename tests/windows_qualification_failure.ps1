#Requires -Version 7.4
[CmdletBinding()]param([string]$SourceRoot)
# Actual qualification helpers and owned child processes only; no PBX or services.
$ErrorActionPreference='Stop';$checks=0
if(!$SourceRoot){$SourceRoot=Split-Path $PSScriptRoot -Parent}
function Verify([bool]$Value){$script:checks++;if(!$Value){throw ('Qualification failure control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)}}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-updater-qualification.ps1'),[ref]$tokens,[ref]$errors)
Verify (@($errors).Count -eq 0)
$definitions=@{}
foreach($name in 'Check','QualificationFailureObservation','CheckedProcess','Fixture'){
 $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))
 Verify ($nodes.Count -eq 1);$definitions[$name]=$nodes[0].Extent.Text
}
Verify ($definitions.Check -ceq 'function Check([bool]$Value,[string]$Message){if(!$Value){throw $Message}}')
Verify ($definitions.CheckedProcess.Contains('[int]$Timeout=2400000') -and [regex]::Matches($definitions.CheckedProcess,'\$process\.WaitForExit\(\$Timeout\)').Count -eq 1)
Verify ($definitions.Fixture.Contains('$process.WaitForExit(90000)') -and [regex]::Matches($definitions.Fixture,'\$process\.WaitForExit\(90000\)').Count -eq 1)
foreach($body in @($definitions.CheckedProcess,$definitions.Fixture)){
 Verify (!$body.Contains('.Kill(') -and !$body.Contains('Stop-Process') -and $body.Contains('$process.Dispose();'))
 Verify ($body.Contains('$script:qualificationFailedChild=$null'))
}
Verify ($definitions.CheckedProcess.Contains("'A private qualification operation failed; its streams remain private.'"))
Verify ($definitions.Fixture.Contains("'The private scoped audit failed.'"))
Verify ($ast.Extent.Text.Contains('$facts.failure_observation=QualificationFailureObservation $_.ScriptStackTrace $script:qualificationFailedChild'))
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('OpenWebQualificationFailure-PRIVATE_SENTINEL_'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $temporary
$sensitive='PRIVATE_SENTINEL_password_token_SDDL_S-1-5-21_customer_row'
$held=$null
try{
 $script:work=Join-Path $temporary 'streams';$null=New-Item -ItemType Directory -Path $work
 $script:source=$temporary;$script:testExecutable=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
 # A fictional Python wrapper supplies fixed child paths/labels. All helper
 # function bodies below are loaded byte-exact from the actual source AST.
 $fixture=Join-Path $temporary 'windows-updater-qualification.ps1'
 $wrapper=@'
function Python([string]$Child,[string]$Label='python-setup',[int]$Timeout=2400000){
 CheckedProcess $script:testExecutable @('-NoProfile','-NonInteractive','-File',$Child) $Label $script:source $Timeout
}
'@
 [IO.File]::WriteAllText($fixture,(@('Check','QualificationFailureObservation','CheckedProcess'|ForEach-Object {$definitions[$_]}) -join "`n")+"`n"+$wrapper)
 . $fixture
 $child=Join-Path $temporary 'private-child.ps1'
 [IO.File]::WriteAllText($child,"[Console]::Out.WriteLine('$sensitive');[Console]::Error.WriteLine('$sensitive');exit 23")
 $caught=$null;try{Python $child}catch{$caught=$_}
 Verify ($null -ne $caught -and $caught.Exception.Message -ceq 'A private qualification operation failed; its streams remain private.')
 $failedChild=$script:qualificationFailedChild
 $report=QualificationFailureObservation $caught.ScriptStackTrace $failedChild
 Verify ($report.child.label -ceq 'python-setup' -and $report.child.completion -ceq 'exit' -and $report.child.exit_code -eq 23)
 Verify ($report.callsites.function -ccontains 'Check' -and $report.callsites.function -ccontains 'CheckedProcess' -and $report.callsites.function -ccontains 'Python')
 Verify (@($report.callsites|Where-Object {$_.source_basename -cne 'windows-updater-qualification.ps1' -or $_.source_line -lt 1}).Count -eq 0)
 $encoded=$report|ConvertTo-Json -Depth 8 -Compress
 Verify (!$encoded.Contains($sensitive) -and !$encoded.Contains($temporary) -and !$encoded.Contains('PRIVATE_SENTINEL'))
 Verify ([IO.File]::ReadAllText((Join-Path $work 'python-setup.out')).Contains($sensitive) -and [IO.File]::ReadAllText((Join-Path $work 'python-setup.err')).Contains($sensitive))
 Verify ((@($report.Keys|Sort-Object) -join ',') -ceq 'callsites,child,schema')
 foreach($frame in $report.callsites){Verify ((@($frame.Keys|Sort-Object) -join ',') -ceq 'function,source_basename,source_line')}
 [IO.File]::WriteAllText($child,"[Console]::Out.WriteLine('$sensitive');exit 0")
 $output=@(Python $child 'python-request')
 Verify ($output.Count -eq 0 -and $null -eq $script:qualificationFailedChild)
 Verify ($null -eq (QualificationFailureObservation $caught.ScriptStackTrace $script:qualificationFailedChild).child)
 # Bind only the fixed executable/argv/working directory to an owned child;
 # retain the complete actual Fixture wait, stream, failure and JSON boundary.
 $fixtureBody=$definitions.Fixture.Replace('"$root\php\php.exe"','$script:testExecutable').Replace('"$root\web"','$script:source').Replace("@((Join-Path `$PSScriptRoot 'windows-updater-fixture.php'),`$Action,`$inputFile)","@('-NoProfile','-NonInteractive','-File',`$script:fixtureChild)")
 Verify ($fixtureBody -cne $definitions.Fixture -and !$fixtureBody.Contains('windows-updater-fixture.php'))
 [IO.File]::AppendAllText($fixture,"`n"+$fixtureBody);. $fixture
 $script:fixtureChild=Join-Path $temporary 'owned-php-child.ps1'
 [IO.File]::WriteAllText($fixtureChild,"[Console]::Out.WriteLine('{`"normal_setup_discovered`":true}');[Console]::Error.WriteLine('$sensitive');exit 0")
 $success=Fixture 'discover'
 Verify ($success.normal_setup_discovered -eq $true -and $null -eq $script:qualificationFailedChild)
 Verify ([IO.File]::ReadAllText((Join-Path $work 'discover-private.err')).Contains($sensitive))
 [IO.File]::WriteAllText($fixtureChild,"[Console]::Out.WriteLine('$sensitive');[Console]::Error.WriteLine('$sensitive');exit 23")
 $fixtureError=$null;try{Fixture 'discover'}catch{$fixtureError=$_}
 Verify ($null -ne $fixtureError -and $fixtureError.Exception.Message -ceq 'The private scoped audit failed.')
 $fixtureReport=QualificationFailureObservation $fixtureError.ScriptStackTrace $script:qualificationFailedChild
 Verify ($fixtureReport.child.label -ceq 'fixture-discover' -and $fixtureReport.child.exit_code -eq 23 -and $fixtureReport.callsites.function -ccontains 'Fixture')
 Verify (!($fixtureReport|ConvertTo-Json -Depth 8 -Compress).Contains($sensitive))
 # A stale caught child must not be attributed to a later unrelated assertion.
 $other=$null;try{Check $false $sensitive}catch{$other=$_}
 $unrelated=QualificationFailureObservation $other.ScriptStackTrace $failedChild
 Verify ($null -eq $unrelated.child -and !($unrelated|ConvertTo-Json -Depth 8 -Compress).Contains($sensitive))
 $trace="at Check, C:\private\$sensitive\windows-updater-qualification.ps1: line 30`nat CheckedProcess, C:\private\$sensitive\windows-updater-qualification.ps1: line 100`nat Python, C:\private\$sensitive\windows-updater-qualification.ps1: line 130"
 $accepted=QualificationFailureObservation $trace $failedChild
 Verify ($accepted.callsites.Count -eq 3 -and $accepted.child.exit_code -eq 23)
 foreach($mutation in 'label','caller','completion','zero','string_exit','long_exit'){
  $record=$failedChild.Clone();$record['private_extra']=$sensitive
  switch($mutation){
   'label'{$record.label=$sensitive}
   'caller'{$record.caller=$sensitive}
   'completion'{$record.completion=$sensitive}
   'zero'{$record.exit_code=0}
   'string_exit'{$record.exit_code='23'}
   'long_exit'{$record.exit_code=[long]23}
  }
  $negative=QualificationFailureObservation $trace $record
  Verify ($null -eq $negative.child -and !($negative|ConvertTo-Json -Depth 8 -Compress).Contains($sensitive))
 }
 foreach($invalid in @('',('x'*16385),"at $sensitive, C:\private\windows-updater-qualification.ps1: line 40",'at Check, C:\private\unknown.ps1: line 40','at Check, C:\private\windows-updater-qualification.ps1: line 0','at Check, C:\private\windows-updater-qualification.ps1: line 100000')){
  $negative=QualificationFailureObservation $invalid $failedChild
  Verify ($negative.callsites.Count -eq 0 -and $null -eq $negative.child)
 }
 $duplicates=QualificationFailureObservation (($trace+"`n")*3) $failedChild
 Verify ($duplicates.callsites.Count -eq 3)
 $many=(1..10|ForEach-Object {"at Check, C:\private\windows-updater-qualification.ps1: line $_"}) -join "`n"
 Verify ((QualificationFailureObservation $many $null).callsites.Count -eq 6)
 $late=((@('unrecognized')*64)+@('at Check, C:\private\windows-updater-qualification.ps1: line 30')) -join "`n"
 Verify ((QualificationFailureObservation $late $null).callsites.Count -eq 0)
 $native=QualificationFailureObservation 'at GetManagerOriginalExitProof, C:\private\windows-upgrade-acceptance.ps1: line 800' $null
 Verify ($native.callsites.Count -eq 1 -and $native.callsites[0].function -ceq 'GetManagerOriginalExitProof')
 # Deadline refusal retains the existing no-kill behavior. The exact owned
 # child writes its PID, then exits naturally; retain its handle to prove exit.
 $pidFile=Join-Path $temporary 'owned-child.pid'
 [IO.File]::WriteAllText($child,"[IO.File]::WriteAllText('"+$pidFile.Replace("'","''")+"',[string]`$PID);Start-Sleep -Milliseconds 2000;exit 0")
 $started=[DateTime]::UtcNow;$deadlineError=$null
 try{Python $child 'python-setup' 10}catch{$deadlineError=$_}
 Verify ($null -ne $deadlineError -and $deadlineError.Exception.Message -ceq 'A private qualification child exceeded its deadline; do not interrupt its transaction.')
 $deadlineReport=QualificationFailureObservation $deadlineError.ScriptStackTrace $script:qualificationFailedChild
 Verify ($deadlineReport.child.label -ceq 'python-setup' -and $deadlineReport.child.completion -ceq 'deadline' -and $null -eq $deadlineReport.child.exit_code)
 $until=[DateTime]::UtcNow.AddSeconds(5)
 while(!(Test-Path -LiteralPath $pidFile) -and [DateTime]::UtcNow -lt $until){Start-Sleep -Milliseconds 25}
 Verify (Test-Path -LiteralPath $pidFile)
 $held=[Diagnostics.Process]::GetProcessById([int][IO.File]::ReadAllText($pidFile));$null=$held.Handle
 Verify ($held.StartTime.ToUniversalTime() -ge $started.AddSeconds(-1) -and $held.MainModule.FileName -ceq $testExecutable)
 Verify ($held.WaitForExit(5000) -and $held.HasExited -and $held.ExitCode -eq 0)
 $held.Dispose();$held=$null
}finally{
 if($held){$null=$held.WaitForExit(5000);$held.Dispose()}
 if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Recurse -Force}
}
Verify (!(Test-Path -LiteralPath $temporary))
@{schema=1;state='passed';actual_source_controls=$checks;real_owned_children=5;fixture_test_binding='owned executable/argv/cwd only';private_streams_retained=$true;sentinel_excluded_from_facts=$true;deadline_child_exited_naturally=$true;pbx_services_or_network_executed=$false}|ConvertTo-Json -Compress
