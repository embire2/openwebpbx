# Execute actual transaction/hold functions with explicit journal/service adapters.
# No installed script, database, task, service or filesystem node is mutated.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$script:checks=0
function Check([bool]$Value){if(!$Value){throw ('CDR lifecycle control '+$script:checks+' failed at '+((Get-PSCallStack|Select-Object -Skip 1 -First 3|ForEach-Object {$_.ScriptLineNumber}) -join '/'))};$script:checks++}
function Refuse([scriptblock]$Action){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Check $failed}
function Parse([string]$Name){$t=$null;$e=$null;$a=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot ('packaging/windows/'+$Name)),[ref]$t,[ref]$e);Check ($e.Count -eq 0);return $a}
function Load($Ast,[string]$Name){$n=@($Ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Name},$true));Check ($n.Count -eq 1);Invoke-Expression ('function global:'+ $n[0].Name +$n[0].Extent.Text.Substring(('function '+$n[0].Name).Length))}
$main=Parse 'Upgrade-OpenWebPBX.ps1';$install=Parse 'Install-OpenWebPBX.ps1';$backupAst=Parse 'Backup-Control.ps1';$common=Parse 'CallRecords.Common.ps1';$support=Parse 'Support-Recovery.ps1'
Load $common 'Assert-OpenWebCallRecordHold'
$good=[pscustomobject]@{schema=1;owner='upgrade';transaction=('a'*32)};Assert-OpenWebCallRecordHold $good;Check $true
foreach($bad in @($null,0,'1',$true,@(1))){$h=[pscustomobject]@{schema=$bad;owner='upgrade';transaction=('a'*32)};Refuse {Assert-OpenWebCallRecordHold $h}}
foreach($bad in @('Upgrade','other','',@('upgrade'),1)){$h=[pscustomobject]@{schema=1;owner=$bad;transaction=('a'*32)};Refuse {Assert-OpenWebCallRecordHold $h}}
foreach($bad in @(('a'*31),('A'*32),('a'*33),'../bad',1,@('a'*32))){$h=[pscustomobject]@{schema=1;owner='upgrade';transaction=$bad};Refuse {Assert-OpenWebCallRecordHold $h}}
foreach($owner in 'install','upgrade','restore'){Assert-OpenWebCallRecordHold ([pscustomobject]@{schema=[long]1;owner=$owner;transaction=('a'*32)});Check $true}
Load $main 'SaveJournal';Load $main 'CompleteCommittedFinalization'
$version='1.0.20';$previousVersion='1.0.6';$backup='fictional';$journalPath='fictional';$private='fictional';$root='fictional';$switch='fictional';$lock=$null
$script:upgradeRecoveryEntry=$null;$script:upgradeFinalizationPhase=$null;$script:upgradeFinalizationFailed=$false;$script:managerTasks=@();$script:operatorRollback=$false;$script:callRecordsHold=$good
function WriteState($Path,$Value){$script:events+='write/'+$Value.state;if($script:failWrite){throw 'Intentional durable-write refusal.'};$script:saved=$Value}
function Remove-OpenWebCallRecordHold {param($StateRoot,$Hold,$MaintenanceLock)Check ($script:saved.state -cin 'completed','rolled_back');Check ([object]::ReferenceEquals($Hold,$good));$script:events+='clear';if($script:failClear){throw 'Intentional held-delete refusal.'}}
function Complete-OpenWebCommittedUpgrade {param($Entry,$Root,$StateRoot,$EngineRoot,$MaintenanceLock)$script:events+='service_selection';if($script:failSelection){throw 'Intentional SCM refusal.'}}
function Get-Content {param($Path,[switch]$Raw)return '{"Tasks":{}}'}
function Enable-ScheduledTask {param($TaskName)$script:events+='enable/'+$TaskName}
function Disable-ScheduledTask {param($TaskName)throw 'No pre-existing disabled task in this fixture.'}
function Start-ScheduledTask {param($TaskName)$script:events+='start/'+$TaskName}
function Get-ScheduledTask {param($TaskName,$ErrorAction)return $null}
function ResumeManagers {$script:events+='managers';if($script:failManagers){throw 'Intentional manager refusal.'}}
foreach($phase in 'prepared','deploying','migrating','validating','rolling_back','recovery_required','completed'){
 $script:events=@();$script:failWrite=$false;$script:failClear=$false;SaveJournal $phase;Check ($script:events.Count -eq 1 -and $script:saved.state -ceq $phase -and [object]::ReferenceEquals($script:saved.call_records_hold,$good))
}
$script:events=@();SaveJournal 'rolled_back';Check (($script:events -join ',') -ceq 'write/rolled_back,clear')
$script:events=@();$script:failWrite=$true;Refuse {SaveJournal 'rolled_back'};Check (($script:events -join ',') -ceq 'write/rolled_back');$script:failWrite=$false
$script:events=@();$script:failClear=$true;Refuse {SaveJournal 'rolled_back'};Check ($script:saved.state -ceq 'rolled_back' -and ($script:events -join ',') -ceq 'write/rolled_back,clear');$script:failClear=$false
foreach($failure in 'selection','managers','clear','none'){
 $script:events=@();$script:failSelection=$failure -ceq 'selection';$script:failManagers=$failure -ceq 'managers';$script:failClear=$failure -ceq 'clear';SaveJournal 'completed'
 if($failure -ceq 'none'){CompleteCommittedFinalization;Check ($script:saved.finalization.phase -ceq 'complete' -and !$script:saved.finalization.failed);Check ($script:events[-2] -ceq 'clear' -and $script:events[-1] -ceq 'write/completed')}
 else{Refuse {CompleteCommittedFinalization};Check ($script:saved.state -ceq 'completed');Check (@($script:events|Where-Object {$_ -ceq 'clear'}).Count -eq $(if($failure -ceq 'clear'){1}else{0}))}
}
$script:failClear=$false;$script:callRecordsHold=$null;$script:events=@();SaveJournal 'rolled_back';Check (($script:events -join ',') -ceq 'write/rolled_back' -and !$script:saved.ContainsKey('call_records_hold'))
# Exact current producer order: marker cannot precede durable private recovery.
$cmd=@($main.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst]},$true))
$publish=@($cmd|Where-Object {$_.GetCommandName() -ceq 'Publish-OpenWebUpgradeRecovery'});Check ($publish.Count -eq 1)
$hold=@($cmd|Where-Object {$_.GetCommandName() -ceq 'Set-OpenWebCallRecordHold' -and $_.Extent.StartOffset -gt $publish[0].Extent.EndOffset});$php=@($cmd|Where-Object {$_.GetCommandName() -ceq 'Install-OpenWebPhpRuntime'})
Check ($hold.Count -eq 1 -and $php.Count -eq 1 -and $hold[0].Extent.EndOffset -lt $php[0].Extent.StartOffset)
$access=@($cmd|Where-Object {$_.GetCommandName() -ceq 'Install-OpenWebCallRecordAccess'});$migrate=@($cmd|Where-Object {$_.GetCommandName() -ceq 'Run' -and $_.Extent.Text.Contains("'migrate'")});Check ($access.Count -eq 1 -and $migrate.Count -eq 1 -and $migrate[0].Extent.EndOffset -lt $access[0].Extent.StartOffset)
# Source and target restore retain durable hold until recovered or all explicit gates.
Load $backupAst 'RestoreCallRecordHold'
function OrdinaryPath($Path){return $Path};function Get-Item {param($LiteralPath,[switch]$Force,$ErrorAction)return [pscustomobject]@{PSIsContainer=$false;Length=1024}}
function Get-Content {param($LiteralPath,[switch]$Raw,$Encoding,$ErrorAction)return ($script:restoreRecord|ConvertTo-Json -Depth 8)}
$restore='fictional';$script:restoreRecord=[pscustomobject]@{state='prepared';call_records_hold=[pscustomobject]@{schema=1;owner='restore';transaction=('b'*32)}}
foreach($state in 'prepared','restoring','recovery_required','recovering'){$script:restoreRecord.state=$state;$r=RestoreCallRecordHold @('prepared','restoring','recovery_required','recovering');Check ($r.owner -ceq 'restore')}
foreach($state in 'failed','restored','recovered','Prepared','',$null){$script:restoreRecord.state=$state;Refuse {RestoreCallRecordHold @('prepared','restoring','recovery_required','recovering')}}
$script:restoreRecord.state='restored';Check ((RestoreCallRecordHold @('restored')).transaction -ceq ('b'*32));$script:restoreRecord.state='recovered';Check ((RestoreCallRecordHold @('recovered')).transaction -ceq ('b'*32))
$script:restoreRecord.call_records_hold.owner='upgrade';Refuse {RestoreCallRecordHold @('recovered')};$script:restoreRecord.PSObject.Properties.Remove('call_records_hold');Check ($null -eq (RestoreCallRecordHold @('recovered')))
# A failure after the durable recovered write must remain retryable. Execute
# the actual hold case with the real journal reader and explicit SCM adapters.
$holdSwitch=@($backupAst.FindAll({param($n)$n -is [Management.Automation.Language.SwitchStatementAst]},$true));Check ($holdSwitch.Count -eq 1)
$holdClause=@($holdSwitch[0].Clauses|Where-Object {$_.Item1.Extent.Text -ceq "'hold'"});Check ($holdClause.Count -eq 1)
$script:restoreRecord=[pscustomobject]@{state='recovered';call_records_hold=[pscustomobject]@{schema=1;owner='restore';transaction=('b'*32)}};$script:restoreEvents=@();$value=[pscustomobject]@{}
function ValidPlan($Value){$script:restoreEvents+='validate'}
function Set-OpenWebCallRecordHold {param($StateRoot,$Hold,[switch]$ExternalLockHeld)Check ($ExternalLockHeld -and $Hold.owner -ceq 'restore');$script:restoreEvents+='hold'}
function HoldSelection($Selection){$script:restoreEvents+='stop/'+$Selection}
function StopWeb {$script:restoreEvents+='stop/web'}
& ([scriptblock]::Create(($holdClause[0].Item2.Statements.Extent.Text -join "`n")));Check (($script:restoreEvents -join ',') -ceq 'validate,hold,stop/updates,stop/jobs,stop/calls,stop/backups,stop/web')

# Fault after fresh Completed: first ordinary no-journal Recover clears only its
# same-version installation marker; every ambiguous state retains the marker.
Load $main 'CompleteInstalledCallRecordHold'
$private='fictional-state';$root='fictional-root';$journalPath='fictional-journal';$script:freshExists=$true;$script:journalExists=$false;$script:freshVersion='1.0.20';$script:freshBlocked=$false;$script:freshClears=0
$script:freshRecord=[pscustomobject]@{Completed=$true;Version='1.0.20';CallRecordHold=[pscustomobject]@{schema=1;owner='install';transaction=('c'*32)}}
function Test-Path {param($LiteralPath)if($LiteralPath -ceq $journalPath){return $script:journalExists};return $script:freshExists}
function Get-Content {param($LiteralPath,[switch]$Raw,$Encoding,$ErrorAction)if($LiteralPath.EndsWith('installation.json')){return ($script:freshRecord|ConvertTo-Json -Depth 8)};return $script:freshVersion}
function Get-OpenWebRestoreGate {param($StateRoot)return [pscustomobject]@{Calls=$script:freshBlocked;Jobs=$false;Updates=$false;Backups=$false}}
function Assert-OpenWebUpgradeAllowed {param($StateRoot)if($script:freshBlocked){throw 'Fixture restore hold.'}}
function Remove-OpenWebCallRecordHold {param($StateRoot,$Hold,$MaintenanceLock)Check ($Hold.owner -ceq 'install' -and $Hold.transaction -ceq ('c'*32));$script:freshClears++}
CompleteInstalledCallRecordHold;Check ($script:freshClears -eq 1)
foreach($case in 'pending_journal','incomplete','string_completed','wrong_version','wrong_owner','restore_hold'){
 $script:freshRecord.Completed=$true;$script:freshRecord.Version='1.0.20';$script:freshRecord.CallRecordHold.owner='install';$script:journalExists=$false;$script:freshBlocked=$false;$script:freshClears=0
 switch($case){'pending_journal'{$script:journalExists=$true};'incomplete'{$script:freshRecord.Completed=$false};'string_completed'{$script:freshRecord.Completed='true'};'wrong_version'{$script:freshRecord.Version='1.0.19'};'wrong_owner'{$script:freshRecord.CallRecordHold.owner='restore'};'restore_hold'{$script:freshBlocked=$true}}
 Refuse {CompleteInstalledCallRecordHold};Check ($script:freshClears -eq 0)
}
$script:freshExists=$false;$script:freshClears=0;CompleteInstalledCallRecordHold;Check ($script:freshClears -eq 0)
# Run the exact inherited-rights skip loop on closed ACL adapters. This keeps
# correct future-file descriptors byte-stable while retaining directory scope.
$rightNode=@($common.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Add-OpenWebCallRecordRight'},$true));Check ($rightNode.Count -eq 1)
$loops=@($rightNode[0].Body.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.ForEachStatementAst]});Check ($loops.Count -eq 1)
$skip=[scriptblock]::Create($loops[0].Extent.Text+"`n`$script:needsWrite=`$true")
$readWrite=[Security.AccessControl.FileSystemRights]::Read -bor [Security.AccessControl.FileSystemRights]::WriteAttributes
foreach($case in 'inherited_file','explicit_file','file_modify','file_read_only','file_inherit_only','foreign_sid','deny','directory_exact','directory_effective_only','directory_wrong_propagation'){
 $Inheritance=[Security.AccessControl.InheritanceFlags]::None;$Propagation=[Security.AccessControl.PropagationFlags]::None;$Rights=$readWrite;$item=[pscustomobject]@{PSIsContainer=$false};$ace=[pscustomobject]@{IdentityReference=[pscustomobject]@{Value='S-1-5-19'};AccessControlType='Allow';FileSystemRights=$readWrite;InheritanceFlags=[Security.AccessControl.InheritanceFlags]::None;PropagationFlags=[Security.AccessControl.PropagationFlags]::None;IsInherited=$true}
 switch($case){
  'explicit_file'{$ace.IsInherited=$false};'file_modify'{$ace.FileSystemRights=[Security.AccessControl.FileSystemRights]::Modify};'file_read_only'{$ace.FileSystemRights=[Security.AccessControl.FileSystemRights]::Read};'file_inherit_only'{$ace.PropagationFlags=[Security.AccessControl.PropagationFlags]::InheritOnly};'foreign_sid'{$ace.IdentityReference.Value='S-1-5-18'};'deny'{$ace.AccessControlType='Deny'}
  'directory_exact'{$item.PSIsContainer=$true;$Inheritance=[Security.AccessControl.InheritanceFlags]::ContainerInherit;$ace.InheritanceFlags=$Inheritance};'directory_effective_only'{$item.PSIsContainer=$true;$Inheritance=[Security.AccessControl.InheritanceFlags]::ContainerInherit};'directory_wrong_propagation'{$item.PSIsContainer=$true;$Inheritance=[Security.AccessControl.InheritanceFlags]::ContainerInherit;$ace.InheritanceFlags=$Inheritance;$ace.PropagationFlags=[Security.AccessControl.PropagationFlags]::InheritOnly}
 }
 $acl=[pscustomobject]@{Rules=@($ace)};$acl|Add-Member ScriptMethod GetAccessRules {param($Explicit,$Inherited,$Kind)return $this.Rules}
 $script:needsWrite=$false;& $skip;Check ($script:needsWrite -eq ($case -cin 'file_read_only','file_inherit_only','foreign_sid','deny','directory_effective_only','directory_wrong_propagation'))
}
# Causal directory-lock negative must execute before any permission writes.
Load $common 'Install-OpenWebCallRecordAccess'
function Assert-OpenWebCallRecordLock {param($StateRoot,$MaintenanceLock)}
function Get-OpenWebCallRecordPlan {param($PackageRoot,$Root,$EngineRoot)return @{Path='fictional-spool';Log='fictional-log';LogExists=$true}}
function Assert-OpenWebRecoveryOrdinary {param($Path,[switch]$Directory)return $Path}
function Test-Path {param($LiteralPath)return $true}
function Join-Path {param($Path,$ChildPath)return $Path+'/'+$ChildPath}
function Assert-OpenWebCallRecordOrdinary {param($Path,[switch]$Directory)if($Path.EndsWith('/.openweb-import.lock') -and !$Directory){throw 'Fixture lock is an ordinary directory.'};return $Path}
function Add-OpenWebCallRecordRight {param($Path,$Rights)$script:securityWrites++}
$script:securityWrites=0;$caught=$null;try{Install-OpenWebCallRecordAccess -PackageRoot fake -Root fake -StateRoot fake -EngineRoot fake}catch{$caught=$_.Exception.Message};Check ($caught -ceq 'Fixture lock is an ordinary directory.');Check ($script:securityWrites -eq 0)
Write-Output ('PASS '+$checks+' actual CDR hold/journal/commit/restore-state and pre-write importer-lock controls; service/filesystem adapters only')
