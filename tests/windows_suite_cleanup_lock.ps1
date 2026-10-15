#Requires -Version 5.1
[CmdletBinding()]param([string]$SourceRoot)
# Actual acquisition/finalizer source, real owned FileStream contenders only.
$ErrorActionPreference='Stop';$checks=0
if(!$SourceRoot){$SourceRoot=Split-Path $PSScriptRoot -Parent}
function Verify([bool]$Value){$script:checks++;if(!$Value){throw ('Cleanup lock control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)}}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-suite.ps1'),[ref]$tokens,[ref]$errors)
Verify (@($errors).Count -eq 0)
$definitions=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Acquire-SuiteCleanupLock'},$true))
Verify ($definitions.Count -eq 1);. ([ScriptBlock]::Create($definitions[0].Extent.Text))
$assignments=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$cleanupLock' -and $n.Right.Extent.Text -ceq 'Acquire-SuiteCleanupLock $state $work'},$true))
Verify ($assignments.Count -eq 1)
$cleanup=$assignments[0].Parent
while($cleanup -and $cleanup -isnot [Management.Automation.Language.TryStatementAst]){$cleanup=$cleanup.Parent}
Verify ($null -ne $cleanup -and $null -ne $cleanup.Finally)
$releases=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Expression.Extent.Text -ceq '$cleanupLock' -and $n.Member.Value -ceq 'Dispose'},$true))
Verify ($releases.Count -eq 1 -and $releases[0].Extent.StartOffset -gt $cleanup.Finally.Extent.StartOffset -and $releases[0].Extent.EndOffset -lt $cleanup.Finally.Extent.EndOffset)
$installed=$cleanup.Body.Statements[0]
Verify ($installed -is [Management.Automation.Language.IfStatementAst] -and $installed.Clauses[0].Item1.Extent.Text -ceq '$installed')
Verify ($installed.Clauses[0].Item2.Statements[0].Extent.Text -ceq $assignments[0].Extent.Text)
$initializers=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$cleanupLock' -and $n.Right.Extent.Text -ceq '$null'},$true))
Verify ($initializers.Count -eq 1 -and $initializers[0].Extent.EndOffset -lt $cleanup.Extent.StartOffset)
$guard=[ScriptBlock]::Create("param([scriptblock]`$Action)`n"+$initializers[0].Extent.Text+"`ntry{`n"+$assignments[0].Extent.Text+"`n& `$Action`n}finally"+$cleanup.Finally.Extent.Text)
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('openweb-suite-lock-'+[Guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $temporary|Out-Null
$state=Join-Path $temporary 'state';New-Item -ItemType Directory -Path $state|Out-Null;$work=$temporary;$lockPath="$state\upgrade.lock"
$original=[Text.Encoding]::UTF8.GetBytes('Owned cleanup lock original bytes');[IO.File]::WriteAllBytes($lockPath,$original)
$target=Join-Path $temporary 'untouched.bin';[IO.File]::WriteAllBytes($target,$original)
$children=[Collections.Generic.List[Diagnostics.Process]]::new();$childFile=Join-Path $temporary 'contender.ps1';$executable=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
[IO.File]::WriteAllText($childFile,@'
param([string]$LockPath,[string]$ResultPath,[string]$ReleasePath,[int]$HoldMilliseconds)
$ErrorActionPreference='Stop';$handle=$null;$result='denied'
try{$handle=[IO.File]::Open($LockPath,'Open','ReadWrite','None');$result='acquired'}catch [IO.IOException]{}
try{
 [IO.File]::WriteAllText($ResultPath,$result)
 if($handle -and $HoldMilliseconds -gt 0){$timer=[Diagnostics.Stopwatch]::StartNew();while($timer.ElapsedMilliseconds -lt $HoldMilliseconds -and ![IO.File]::Exists($ReleasePath)){Start-Sleep -Milliseconds 20}}
}finally{if($handle){$handle.Dispose()}}
'@,[Text.UTF8Encoding]::new($false))
function StartContender([string]$Label,[int]$HoldMilliseconds=0){
 $result=Join-Path $temporary ($Label+'.result');$release=Join-Path $temporary ($Label+'.release')
 $start=[Diagnostics.ProcessStartInfo]::new($executable);$start.UseShellExecute=$false;$start.CreateNoWindow=$true
 $start.Arguments='-NoProfile -NonInteractive -File "'+$childFile+'" -LockPath "'+$lockPath+'" -ResultPath "'+$result+'" -ReleasePath "'+$release+'" -HoldMilliseconds '+$HoldMilliseconds
 $child=[Diagnostics.Process]::Start($start);$children.Add($child);$deadline=[DateTime]::UtcNow.AddSeconds(15)
 while(![IO.File]::Exists($result) -and !$child.HasExited -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 20}
 Verify ([IO.File]::Exists($result));$record=@{process=$child;result=[IO.File]::ReadAllText($result);release=$release}
 if(!$HoldMilliseconds){Verify ($child.WaitForExit(15000) -and $child.ExitCode -eq 0)}
 return $record
}
function Read-OpenWebUpdaterGeneration($Directory){return $null}
function Get-OpenWebUpgradeLockObservation($StateRoot,$Directory,$Generation){$script:observations++;return @{schema=1}}
function SafeOpenWebUpgradeLockFields($Record){return @{schema=1}}
function ResetFacts {$script:facts=@{};$script:observations=0;$script:actions=0}
function ExactBytes {Verify ([Convert]::ToBase64String([IO.File]::ReadAllBytes($target)) -ceq [Convert]::ToBase64String($original))}
try{
 # The former probe-and-release equivalent admits a real second process.
 $old=[IO.File]::Open($lockPath,'Open','ReadWrite','None');$old.Dispose();$contender=StartContender 'old-release';Verify ($contender.result -ceq 'acquired')
 ResetFacts
 & $guard {$script:actions++;$contender=StartContender 'held';Verify ($contender.result -ceq 'denied');ExactBytes}
 Verify ($actions -eq 1 -and $facts.cleanup_lock_acquisition.acquired -and !$facts.cleanup_lock_acquisition.initial_contended -and $observations -eq 0)
 Verify ((StartContender 'after-finally').result -ceq 'acquired')
 ResetFacts;$threw=$false
 try{& $guard {$script:actions++;Verify ((StartContender 'exception-held').result -ceq 'denied');throw 'Owned deliberate cleanup exception'}}catch{$threw=$_.Exception.Message -ceq 'Owned deliberate cleanup exception'}
 Verify ($threw -and $actions -eq 1);Verify ((StartContender 'after-exception').result -ceq 'acquired');ExactBytes
 # An actual owned foreign holder releases while the exact helper is waiting.
 ResetFacts;$holder=StartContender 'release-while-waiting' 2500
 Verify ($holder.result -ceq 'acquired');$timer=[Diagnostics.Stopwatch]::StartNew()
 & $guard {$script:actions++;Verify ((StartContender 'after-wait-held').result -ceq 'denied')}
 Verify ($holder.process.WaitForExit(15000) -and $holder.process.ExitCode -eq 0)
 Verify ($actions -eq 1 -and $facts.cleanup_lock_acquisition.acquired -and $facts.cleanup_lock_acquisition.initial_contended -and $facts.cleanup_lock_acquisition.attempts -gt 1 -and $observations -eq 1 -and $timer.Elapsed.TotalSeconds -lt 15)
 Verify ((StartContender 'after-wait-finally').result -ceq 'acquired');ExactBytes
 # Real elapsed deadline: no fake timer/sleep and no action before acquisition.
 ResetFacts;$holder=StartContender 'deadline' 60000;Verify ($holder.result -ceq 'acquired');$timer=[Diagnostics.Stopwatch]::StartNew();$refused=$false
 try{& $guard {$script:actions++;[IO.File]::WriteAllText($target,'must never run')}}catch{$refused=$_.Exception.Message -ceq 'An owned transaction is still running; cleanup must not interrupt it.'}
 Verify ($refused -and $actions -eq 0 -and !$facts.cleanup_lock_acquisition.acquired -and $facts.cleanup_lock_acquisition.initial_contended -and $facts.cleanup_lock_acquisition.attempts -gt 1 -and $observations -eq 1)
 Verify ($timer.Elapsed.TotalSeconds -ge 40 -and $timer.Elapsed.TotalSeconds -lt 48);ExactBytes
 [IO.File]::WriteAllText($holder.release,'release');Verify ($holder.process.WaitForExit(15000) -and $holder.process.ExitCode -eq 0)
 Verify ((StartContender 'after-deadline-holder').result -ceq 'acquired')
 Verify ([Convert]::ToBase64String([IO.File]::ReadAllBytes($lockPath)) -ceq [Convert]::ToBase64String($original))
}finally{
 foreach($child in $children){try{if(!$child.HasExited){$child.Kill();$null=$child.WaitForExit(10000)}}finally{$child.Dispose()}}
 Remove-Item -LiteralPath $temporary -Recurse -Force
}
Verify (!(Test-Path -LiteralPath $temporary))
@{schema=1;state='passed';actual_source_and_owned_process_controls=$checks;real_deadline_seconds=40;owned_children_and_files_removed=$true;services_or_tasks_executed=$false}|ConvertTo-Json -Compress
