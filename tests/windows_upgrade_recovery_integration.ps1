# Execute actual journal/runtime-restoration blocks and inspect mutation order.
# The executable upgrade script itself never runs in these portable controls.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest;$script:checks=0
function Assert([bool]$Value){if(!$Value){throw ('Upgrade recovery integration control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
$tokens=$null;$errors=$null;$path=Join-Path $SourceRoot 'packaging/windows/Upgrade-OpenWebPBX.ps1';$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors);Assert ($errors.Count -eq 0)
$nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'SaveJournal'},$true));Assert ($nodes.Count -eq 1);Invoke-Expression $nodes[0].Extent.Text
function WriteState([string]$Path,$Value){$script:saved=$Value}
$version='1.0.20';$previousVersion='1.0.6';$backup='C:\fixture\backups\one';$journalPath='C:\fixture\updates\install-journal.json';$script:managerTasks=@('EXACT_MANAGER');$script:operatorRollback=$false;$script:upgradeFinalizationPhase=$null;$script:upgradeFinalizationFailed=$false;$script:callRecordsHold=$null
foreach($entry in @($null,[pscustomobject]@{schema=1;bundle_path='C:\fixture\updates\recovery-entry\owned';metadata_sha256=('a'*64);launcher_sha256=('b'*64)})){
 $script:upgradeRecoveryEntry=$entry
 foreach($phase in 'deploying','migrating','validating','rolling_back','recovery_required','completed','rolled_back'){
  SaveJournal $phase;Assert ($script:saved.state -ceq $phase -and $script:saved.version -ceq $version -and $script:saved.previous_version -ceq $previousVersion -and $script:saved.backup_path -ceq $backup)
  Assert (($null -eq $entry -and !$script:saved.ContainsKey('recovery_entry')) -or ($null -ne $entry -and [object]::ReferenceEquals($entry,$script:saved.recovery_entry)))
 }
}
$restore=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'RestorePbx'},$true));Assert ($restore.Count -eq 1)
$runtime=@($restore[0].Body.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.IfStatementAst] -and $_.Extent.Text.Contains('The restored runtime does not match')});Assert ($runtime.Count -eq 1)
$block=[scriptblock]::Create($runtime[0].Extent.Text)
function Get-OpenWebUpgradeRecoveryMetadata {param($Entry,[string]$Root,[string]$StateRoot,[string]$EngineRoot,[switch]$RequirePublished)Assert ([bool]$RequirePublished);return [pscustomobject]@{runtime_before_sha256='ORIGINAL_HASH'}}
function Read-OpenWebRecoveryBytes([string]$Path){Assert ($Path -ceq ($Backup+'\runtime.json'));return ,([byte[]]@(1,2,3))}
function Get-OpenWebRecoveryHash([byte[]]$Bytes){return $script:observedHash}
function Copy-Item {[CmdletBinding()]param([string]$Path,[string]$Destination,[switch]$Force)Assert ($Path -ceq ($Backup+'\runtime.json') -and $Destination -ceq ($private+'\runtime.json') -and [bool]$Force);$script:copies++}
$Backup='C:\fixture\backups\one';$root='C:\fixture\program';$private='C:\fixture\state';$switch='C:\fixture\engine'
foreach($active in $false,$true){foreach($hash in 'ORIGINAL_HASH','CHANGED_HASH'){
 $script:upgradeRecoveryEntry=if($active){[pscustomobject]@{schema=1}}else{$null};$script:observedHash=$hash;$script:copies=0;$caught=$false
 try{. $block}catch{$caught=$true}
 Assert ($caught -eq ($active -and $hash -ceq 'CHANGED_HASH'))
 Assert ($script:copies -eq $(if($active){0}else{1}))
}}
# Publication happens after a sealed backup, before any runtime/web/native
# mutation. Reset happens only after new installed helper copies and health.
$commands=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst]},$true))
function Calls([string]$Name){return @($commands|Where-Object {$_.GetCommandName() -ceq $Name})}
$seal=@(Calls SealBackup);$prepare=@(Calls New-OpenWebUpgradeRecovery);$publish=@(Calls Publish-OpenWebUpgradeRecovery);$php=@(Calls Install-OpenWebPhpRuntime)
Assert ($seal.Count -eq 1 -and $prepare.Count -eq 1 -and $publish.Count -eq 1 -and $php.Count -eq 1)
Assert ($seal[0].Extent.EndOffset -lt $prepare[0].Extent.StartOffset -and $prepare[0].Extent.EndOffset -lt $publish[0].Extent.StartOffset -and $publish[0].Extent.EndOffset -lt $php[0].Extent.StartOffset)
$deploy=@($commands|Where-Object {$_.GetCommandName() -ceq 'SaveJournal' -and $_.Extent.Text -ceq "SaveJournal 'deploying'"});Assert ($deploy.Count -eq 1 -and $prepare[0].Extent.EndOffset -lt $deploy[0].Extent.StartOffset -and $deploy[0].Extent.EndOffset -lt $publish[0].Extent.StartOffset)
$complete=@($commands|Where-Object {$_.GetCommandName() -ceq 'Complete-OpenWebUpgradeRecovery' -and $_.Extent.Text.EndsWith('-Outcome Success')});$install=@($commands|Where-Object {$_.Extent.Text -ceq '& "$payload\Install-Updater.ps1" -PackageRoot $payload -DeferRestart -DeferServiceSelection'});$completed=@($commands|Where-Object {$_.GetCommandName() -ceq 'SaveJournal' -and $_.Extent.Text -ceq "SaveJournal 'completed'" -and $_.Extent.StartOffset -gt $complete[0].Extent.EndOffset}|Sort-Object {$_.Extent.StartOffset}|Select-Object -First 1)
Assert ($complete.Count -eq 1 -and $install.Count -eq 1 -and $completed.Count -eq 1 -and $install[0].Extent.EndOffset -lt $complete[0].Extent.StartOffset -and $complete[0].Extent.EndOffset -lt $completed[0].Extent.StartOffset)
$restoreCommands=@($restore[0].FindAll({param($n)$n -is [Management.Automation.Language.CommandAst]},$true));$ensure=@($restoreCommands|Where-Object {$_.GetCommandName() -ceq 'Ensure-OpenWebUpgradeRecoveryPublished'});$firstCopy=@($restoreCommands|Where-Object {$_.GetCommandName() -ceq 'CopyTree'}|Sort-Object {$_.Extent.StartOffset}|Select-Object -First 1)
Assert ($ensure.Count -eq 1 -and $firstCopy.Count -eq 1 -and $ensure[0].Extent.EndOffset -lt $firstCopy[0].Extent.StartOffset)
$terminal=@($commands|Where-Object {$_.GetCommandName() -ceq 'SaveJournal' -and $_.Extent.Text -ceq "SaveJournal 'rolled_back'"})
foreach($node in $terminal){$prior=@($commands|Where-Object {$_.Extent.EndOffset -lt $node.Extent.StartOffset}|Sort-Object {$_.Extent.EndOffset} -Descending|Select-Object -First 1);Assert ($prior.Count -eq 1 -and $prior[0].GetCommandName() -ceq 'Complete-OpenWebUpgradeRecovery' -and $prior[0].Extent.Text.EndsWith('-Outcome Rollback'))}
. (Join-Path $SourceRoot 'packaging/windows/UpgradeRecovery.Common.ps1')
foreach($value in @([pscustomobject]@{String='KEEP';Flag=$false;Number=7;Null=$null;Array=@('a',12,$true)},[pscustomobject]@{Empty=[pscustomobject]@{}})){Assert-OpenWebRecoveryRuntimeShape $value;Assert $true}
foreach($value in @([DateTime]::UtcNow,9007199254740993L,0.125,[decimal]1.1,[pscustomobject]@{Nested=[DateTime]::UtcNow})){$failed=$false;try{Assert-OpenWebRecoveryRuntimeShape $value}catch{$failed=$true};Assert $failed}
$deep=[pscustomobject]@{Value='KEEP'};for($i=0;$i -lt 27;$i++){$deep=[pscustomobject]@{Child=$deep}};$failed=$false;try{Assert-OpenWebRecoveryRuntimeShape $deep}catch{$failed=$true};Assert $failed
Write-Output ('PASS '+$checks+' actual upgrade journal, active-runtime preservation, seal/publication/finalization order and conservative unknown-shape controls')
