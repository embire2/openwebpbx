# Actual commit/catch/boot-driver guards. No installed Windows service is called.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$WarningPreference='SilentlyContinue';$script:checks=0
function Assert([bool]$Value){if(!$Value){throw ('Commit guard control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
function Refuses([scriptblock]$Action){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Assert $failed}
function Parse([string]$Path){$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$t,[ref]$e);Assert ($e.Count -eq 0);return $ast}
function Definition($Ast,[string]$Name){$nodes=@($Ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Name},$true));Assert ($nodes.Count -eq 1);return $nodes[0].Extent.Text}
$main=Parse (Join-Path $SourceRoot 'packaging/windows/Upgrade-OpenWebPBX.ps1');$installer=Parse (Join-Path $SourceRoot 'packaging/windows/Install-Updater.ps1');$common=Parse (Join-Path $SourceRoot 'packaging/windows/UpgradeRecovery.Common.ps1');$support=Parse (Join-Path $SourceRoot 'packaging/windows/Support-Recovery.ps1')
$commands=@($main.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst]},$true))
$install=@($commands|Where-Object {$_.Extent.Text -ceq '& "$payload\Install-Updater.ps1" -PackageRoot $payload -DeferRestart -DeferServiceSelection'});Assert ($install.Count -eq 1)
$reset=@($commands|Where-Object {$_.GetCommandName() -ceq 'Complete-OpenWebUpgradeRecovery' -and $_.Extent.Text.EndsWith('-Outcome Success')});Assert ($reset.Count -eq 1)
$commit=@($commands|Where-Object {$_.GetCommandName() -ceq 'SaveJournal' -and $_.Extent.Text -ceq "SaveJournal 'completed'" -and $_.Extent.StartOffset -gt $reset[0].Extent.EndOffset}|Sort-Object {$_.Extent.StartOffset}|Select-Object -First 1)
$finish=@($commands|Where-Object {$_.GetCommandName() -ceq 'CompleteCommittedFinalization' -and $_.Extent.StartOffset -gt $commit[0].Extent.EndOffset});Assert ($finish.Count -eq 1)
Assert ($install[0].Extent.EndOffset -lt $reset[0].Extent.StartOffset -and $reset[0].Extent.EndOffset -lt $commit[0].Extent.StartOffset -and $commit[0].Extent.EndOffset -lt $finish[0].Extent.StartOffset)
$stage=@($installer.FindAll({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -ceq '!$DeferServiceSelection'},$true));Assert ($stage.Count -eq 1)
Assert (@($installer.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -cin 'New-Service','sc.exe'},$true)).Count -eq 0)
$DeferServiceSelection=$true;& ([scriptblock]::Create($stage[0].Extent.Text));Assert $true
# Execute the precise historical unconditional branch using service adapters.
$script:created=0;$script:configured=0;$existing=$null;$executable='fictional';function New-Service {param($Name,$BinaryPathName,$DisplayName,$StartupType,$DependsOn)$script:created++};function sc.exe {$script:configured++;$global:LASTEXITCODE=0}
. (Join-Path $SourceRoot 'tests/fixtures/windows-updater-selection-before-commit.ps1');Assert ($script:created -eq 1 -and $script:configured -eq 2)
# Completed-finalization failures retain the commit and never stop/restore PBX.
Invoke-Expression (Definition $main 'SaveJournal');function WriteState([string]$Path,$Value){$script:saved=$Value}
$catchGuard=@($main.FindAll({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -ceq '$script:upgradeCommitted'},$true));Assert ($catchGuard.Count -eq 1)
$script:upgradeCommitted=$true;$script:upgradeRecoveryEntry=[pscustomobject]@{schema=1};$script:managerTasks=@();$script:operatorRollback=$false;$version='1.0.20';$previousVersion='1.0.6';$backup='fictional';$journalPath='fictional'
function RestorePbx {throw 'Destructive restore reached after commit.'};function StopPbx {throw 'Destructive stop reached after commit.'}
foreach($phase in 'service_selection','background_tasks','manager_resume'){$script:upgradeFinalizationPhase=$phase;$script:upgradeFinalizationFailed=$false;& ([scriptblock]::Create($catchGuard[0].Extent.Text));Assert ($script:saved.state -ceq 'completed' -and $script:saved.finalization.phase -ceq $phase -and $script:saved.finalization.failed -eq $true)}
# A completed receipt is replayed only until finalization actually finishes.
$completedGuard=@($main.FindAll({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text.StartsWith("`$journal.state -ceq 'completed' -and")},$true));Assert ($completedGuard.Count -eq 1)
$condition=[scriptblock]::Create($completedGuard[0].Clauses[0].Item1.Extent.Text)
$journal=[pscustomobject]@{state='completed';recovery_entry=@{};finalization=[pscustomobject]@{phase='complete';failed=$false}};Assert (!(& $condition))
foreach($field in 'phase','failed'){foreach($bad in @($null,1,'false',@($false),@{})){$journal.finalization=[pscustomobject]@{phase='complete';failed=$false};$journal.finalization.$field=$bad;Assert (& $condition)}}
$journal.finalization=[pscustomobject]@{phase='complete';failed=$true};Assert (& $condition);$journal.finalization.phase='service_selection';Assert (& $condition);$journal.PSObject.Properties.Remove('finalization');Assert (& $condition)
# Exact guard function with explicit service/process adapters, including
# external-admin ancestry, identity and graceful-stop postconditions.
Invoke-Expression (Definition $common 'Assert-OpenWebInstalledUpdaterService')
function Assert-OpenWebRecoveryProtected {param($Path,[switch]$Directory)return $Path}
function Read-OpenWebRecoveryBytes {param($Path,$Maximum)return ,([Text.Encoding]::UTF8.GetBytes(($script:metadata|ConvertTo-Json)))}
$Root=Join-Path ([IO.Path]::GetTempPath()) 'fictional-never-created';$StateRoot=Join-Path $Root 'state';$expected=Join-Path $Root 'updater\slots\1.0.20\OpenWebPbx.Updater.exe'
function Reset {
 $script:metadata=[pscustomobject]@{Version='1.0.20';Executable=$expected};$script:service=[pscustomobject]@{PathName=('"'+$expected+'"');StartName='LocalSystem';StartMode='Auto';State='Stopped';ProcessId=0}
 $script:owner='S-1-5-18';$script:ancestorIsUpdater=$false;$script:remaining=$false;$script:stops=0;$script:waits=0
}
function Get-CimInstance { [CmdletBinding()]param($ClassName,$Filter)
 if($ClassName -ceq 'Win32_Service'){return $script:service}
 if($Filter -ceq "Name='OpenWebPbx.Updater.exe'"){if($script:remaining){return [pscustomobject]@{ExecutablePath=$expected}};return}
 $processId=[int]($Filter -replace '^ProcessId=','')
 if($processId -eq 424242){return [pscustomobject]@{ExecutablePath=$expected;CreationDate=[datetime]'2026-10-22T00:00:00Z';ParentProcessId=0}}
 if($processId -eq $PID){return [pscustomobject]@{ParentProcessId=$(if($script:ancestorIsUpdater){424242}else{0})}}
 throw 'Unexpected process adapter query.'
}
function Invoke-CimMethod { [CmdletBinding()]param($InputObject,$MethodName)return [pscustomobject]@{ReturnValue=0;Sid=$script:owner}}
function Stop-Service { [CmdletBinding()]param($Name)$script:stops++;$script:service.State='Stopped';$script:service.ProcessId=0}
function Get-Service { [CmdletBinding()]param($Name)$o=[pscustomobject]@{};$o|Add-Member ScriptMethod WaitForStatus {param($State,$Limit)$script:waits++;if($State -cne 'Stopped' -or $Limit.TotalSeconds -ne 120){throw 'Wrong bounded stop.'}};return $o}
Reset;Assert (!(Assert-OpenWebInstalledUpdaterService -Root $Root -StateRoot $StateRoot).WasRunning)
foreach($case in 'absent','foreign','identity','disabled','manual'){
 Reset;switch($case){'absent'{$script:service=$null};'foreign'{$script:service.PathName='C:\foreign\bad.exe'};'identity'{$script:service.StartName='LocalService'};'disabled'{$script:service.StartMode='Disabled'};'manual'{$script:service.StartMode='Manual'}}
 Refuses {Assert-OpenWebInstalledUpdaterService -Root $Root -StateRoot $StateRoot};Assert ($script:stops -eq 0)
}
foreach($case in 'disabled_running','ancestor','wrong_owner','remaining','external'){
 Reset;$script:service.State='Running';$script:service.ProcessId=424242
 switch($case){'disabled_running'{$script:service.StartMode='Disabled'};'ancestor'{$script:ancestorIsUpdater=$true};'wrong_owner'{$script:owner='S-1-5-19'};'remaining'{$script:remaining=$true}}
 if($case -ceq 'external'){$result=Assert-OpenWebInstalledUpdaterService -Root $Root -StateRoot $StateRoot -StopForOperatorRollback;Assert ($result.WasRunning -and $script:stops -eq 1 -and $script:waits -eq 1)}
 else{Refuses {Assert-OpenWebInstalledUpdaterService -Root $Root -StateRoot $StateRoot -StopForOperatorRollback};Assert ($script:stops -eq $(if($case -ceq 'remaining'){1}else{0}))}
}
Write-Output ('PASS '+$checks+' actual commit ordering/irreversible failure/typed completion/owned boot-driver and external rollback stop controls')
