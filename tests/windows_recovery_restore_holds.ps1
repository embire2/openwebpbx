# Actual restore-gate/recovery functions, real temporary files, explicit SCM/IIS adapters.
# This checks startup policy; it does not restore a database or qualify native Windows.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest;$checks=0
function Check([bool]$Value){if(!$Value){throw ('Restore recovery check '+($script:checks+1)+' failed.')};$script:checks++}
function Refuse([scriptblock]$Action){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Check $failed}
function Load([string]$File,[string]$Name){
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot $File),[ref]$tokens,[ref]$errors);Check (!$errors)
 $nodes=@($ast.FindAll({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-ceq $Name},$true));Check ($nodes.Count-eq 1)
 Invoke-Expression ('function global:'+$Name+$nodes[0].Extent.Text.Substring(('function '+$Name).Length))
}
Load 'packaging/windows/Restore-Gates.ps1' 'Get-OpenWebRestoreGate'
Load 'packaging/windows/CallRecords.Common.ps1' 'Assert-OpenWebCallRecordHold'
Load 'packaging/windows/Upgrade-OpenWebPBX.ps1' 'ResumeHeldRestore'
Load 'packaging/windows/Upgrade-OpenWebPBX.ps1' 'StartPbx'
function Get-Service {param($Name) [pscustomobject]@{Status='Stopped'}}
function Start-Service {param($Name) $script:started.Add($Name)}
function Get-WebAppPoolState {param($Name) [pscustomobject]@{Value='Stopped'}}
function Start-WebAppPool {param($Name) $script:started.Add('pool')}
function WaitPool {param($Wanted) if($Wanted-cne 'Started'){throw 'Unexpected pool state.'}}
function Get-Website {param($Name) [pscustomobject]@{State='Stopped'}}
function Start-Website {param($Name) $script:started.Add('website')}
$work=Join-Path ([IO.Path]::GetTempPath()) ('recovery-restore-holds-'+[Guid]::NewGuid().ToString('N'))
$private=Join-Path $work 'state';$restore=Join-Path $private 'backup-restore';$journalPath=Join-Path $private 'install-journal.json';$marker=Join-Path $private 'call-records.hold'
$null=[IO.Directory]::CreateDirectory($restore)
$oldHold=[ordered]@{schema=1;owner='upgrade';transaction=('a'*32)};$restoreHold=[ordered]@{schema=1;owner='restore';transaction=('b'*32)}
function Reset([string]$Phase='restored'){
 foreach($f in @(Get-ChildItem -LiteralPath $restore -File)){[IO.File]::Delete($f.FullName)}
 [IO.File]::Delete($journalPath);[IO.File]::WriteAllText($marker,($restoreHold|ConvertTo-Json -Compress))
 [IO.File]::WriteAllText((Join-Path $restore 'journal.json'),([ordered]@{schema=1;state=$Phase;call_records_hold=$restoreHold}|ConvertTo-Json -Compress -Depth 4))
 foreach($name in 'calls','jobs','updates','backups'){[IO.File]::WriteAllText((Join-Path $restore ('hold-'+$name)), 'owned hold')}
 $script:started=[Collections.Generic.List[string]]::new()
}
function Snapshot{
 (@(Get-ChildItem -LiteralPath $private -File -Recurse|Sort-Object FullName|ForEach-Object {[ordered]@{path=$_.FullName;bytes=[Convert]::ToBase64String([IO.File]::ReadAllBytes($_.FullName))}})|ConvertTo-Json -Compress -Depth 4)
}
function SavedJournal($Value){[IO.File]::WriteAllText($journalPath,($Value|ConvertTo-Json -Compress -Depth 6))}
try{
 foreach($state in 'prepared','restoring','recovery_required'){
  Reset $state;$before=Snapshot;Check ((Get-OpenWebRestoreGate $private).Blocked);Refuse {ResumeHeldRestore};Check ($started.Count-eq 0 -and (Snapshot)-ceq $before)
 }
 foreach($state in 'restored','recovered'){
  foreach($previous in 'absent','rolled_back','legacy_completed','completed'){
   Reset $state
   if($previous-cne 'absent'){$journal=[ordered]@{schema=1;state=$(if($previous-ceq 'rolled_back'){'rolled_back'}else{'completed'});call_records_hold=$oldHold};if($previous-ceq 'completed'){$journal.recovery_entry=@{owned='fixture'};$journal.finalization=@{phase='complete';failed=$false}};SavedJournal $journal}
   $before=Snapshot;Check (ResumeHeldRestore);Check (($started.ToArray()-join ',')-ceq 'pool,website');Check ((Snapshot)-ceq $before)
  }
 }
 foreach($state in 'prepared','quiescing','deploying','migrating','validating','rolling_back','recovery_required','unknown'){
  Reset;SavedJournal @{schema=1;state=$state;call_records_hold=$oldHold};$before=Snapshot;Refuse {ResumeHeldRestore};Check ($started.Count-eq 0 -and (Snapshot)-ceq $before)
 }
 foreach($kind in 'bad_schema','bad_hold','missing_finalization','pending_finalization','failed_finalization','string_failed','malformed','oversized','directory'){
  Reset;$journal=@{schema=1;state='completed';recovery_entry=@{owned='fixture'};finalization=@{phase='complete';failed=$false};call_records_hold=$oldHold}
  switch($kind){
   'bad_schema'{$journal.schema=$true};'bad_hold'{$journal.call_records_hold=@{schema=1;owner='foreign';transaction=('a'*32)}}
   'missing_finalization'{$journal.Remove('finalization')};'pending_finalization'{$journal.finalization.phase='background_tasks'}
   'failed_finalization'{$journal.finalization.failed=$true};'string_failed'{$journal.finalization.failed='false'}
  };SavedJournal $journal
  if($kind-ceq 'malformed'){[IO.File]::WriteAllText($journalPath,'{')}
  if($kind-ceq 'oversized'){[IO.File]::WriteAllText($journalPath,('x'*1048577))}
  if($kind-ceq 'directory'){[IO.File]::Delete($journalPath);$null=[IO.Directory]::CreateDirectory($journalPath)}
  $before=Snapshot;Refuse {ResumeHeldRestore};Check ($started.Count-eq 0 -and (Snapshot)-ceq $before)
  if($kind-ceq 'directory'){[IO.Directory]::Delete($journalPath)}
 }
 # Every partial activation preserves the original call/job gate semantics.
 for($mask=1;$mask-lt 16;$mask++){
  Reset;$names=@('calls','jobs','updates','backups')
  for($i=0;$i-lt 4;$i++){if(!($mask-band (1-shl $i))){[IO.File]::Delete((Join-Path $restore ('hold-'+$names[$i])))}}
  $before=Snapshot;Check (ResumeHeldRestore);Check ($started.Contains('FreeSWITCH')-eq ![bool]($mask-band 1));Check ($started.Contains('OpenWebPBX')-eq ![bool]($mask-band 2));Check ((Snapshot)-ceq $before)
 }
 Reset;foreach($name in 'calls','jobs','updates','backups'){[IO.File]::Delete((Join-Path $restore ('hold-'+$name)))}
 $before=Snapshot;Check (!(ResumeHeldRestore));Check ($started.Count-eq 0 -and (Snapshot)-ceq $before)
 # Do not turn this into a bypass of the normal recovery/maintenance lock.
 $text=[IO.File]::ReadAllText((Join-Path $SourceRoot 'packaging/windows/Upgrade-OpenWebPBX.ps1'))
 Check ($text.IndexOf('if(ResumeHeldRestore){return}')-gt $text.IndexOf('$lock = [IO.File]::Open('))
 Check ($text.Contains("if(`$Recover){`n  if(ResumeHeldRestore){return}`n  if(!(Test-Path -LiteralPath `$journalPath)){CompleteInstalledCallRecordHold}"))
 "PASS $checks actual restore gate/startup/file-preservation controls; SCM/IIS are explicit adapters; no native or backup-restore acceptance"
}finally{[IO.Directory]::Delete($work,$true)}
