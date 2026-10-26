param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
. (Join-Path $SourceRoot 'tests/windows-backup-updater-quiescence.ps1')
$checks=0
function Check([bool]$Value){if(!$Value){throw ('Backup updater isolation control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
function Refuses([scriptblock]$Action){$failed=$false;try{&$Action}catch{$failed=$true};Check $failed}
function Assert-BackupUpdaterQualificationContext {$script:contexts++} # explicit non-Windows provider adapter
function Get-HealthUpdaterQualificationState {return $script:current.Clone()}
function Export-ScheduledTask {return ('<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><RegistrationInfo><Description>'+$script:description+'</Description></RegistrationInfo><Settings><Enabled>'+([string]$script:current.TaskEnabled).ToLowerInvariant()+'</Enabled></Settings></Task>')}
function Get-ScheduledTask {return @{TaskName='OpenWebPBX-Updater-Restart';TaskPath='\';Actions=@(@{Execute=($env:SystemRoot+'\System32\WindowsPowerShell\v1.0\powershell.exe');Arguments=('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$root+'\tools\Restart-Updater.ps1"')});Principal=@{UserId='SYSTEM';RunLevel='Highest';LogonType='ServiceAccount'};Settings=@{Enabled=[bool]$script:current.TaskEnabled};State=$(if($script:current.TaskEnabled){'Ready'}else{'Disabled'});Triggers=@()}}
function Disable-ScheduledTask {$script:taskActions++;$script:current.TaskEnabled=$false}
function Enable-ScheduledTask {$script:taskActions++;$script:current.TaskEnabled=$true}
function Stop-Service {$script:serviceActions++;$script:current.Running=$false}
function Start-Service {$script:serviceActions++;$script:current.Running=$true}
$work=Join-Path ([IO.Path]::GetTempPath()) ('backup-updater-controls-'+[guid]::NewGuid().ToString('N'))
$root=Join-Path $work 'installed';$state=Join-Path $work 'private';$PackageRoot=Join-Path $work 'candidate';$script:contexts=0
function Reset([bool]$Running=$true,[bool]$Enabled=$true,[string]$Mode='Auto'){
 if(Test-Path $work){[IO.Directory]::Delete($work,$true)}
 foreach($dir in $root,$state,$PackageRoot,(Join-Path $state 'backup-qualification')){[void][IO.Directory]::CreateDirectory($dir)}
 [IO.File]::WriteAllText((Join-Path $PackageRoot 'VERSION'),'1.0.21')
 $script:inputFile=Join-Path $state ('backup-qualification/'+[guid]::NewGuid().ToString('N')+'.json');[IO.File]::WriteAllText($inputFile,'{}')
 $script:description='owned';$script:current=@{Executable=(Join-Path $root 'updater/slots/1.0.21/OpenWebPbx.Updater.exe');StartMode=$Mode;StartName='LocalSystem';Running=$Running;TaskEnabled=$Enabled;TaskXml='';MetadataHash=('A'*64)}
 $script:current.TaskXml=Export-ScheduledTask
 $script:receipt=New-BackupUpdaterQualificationReceipt $inputFile;$script:original=$null
 Suspend-HealthQualificationUpdater ([ref]$script:original)
 $script:taskActions=0;$script:serviceActions=0
}
function WriteJournal([string]$Kind='restored',[switch]$Held){
 $dir=Join-Path $state 'backup-restore';[void][IO.Directory]::CreateDirectory($dir)
 $journal=@{schema=1;state=$Kind;database='fusionpbx';user='fusionpbx';source_host='windowsqa.example.invalid';factory_security_version=1;gates=@{schema=1;services=@{OpenWebPBXUpdater=$script:original.StartMode};running=@('FreeSWITCH','OpenWebPBX')};call_records_hold=@{schema=1;owner='restore';transaction=('a'*32)}}
 [IO.File]::WriteAllText((Join-Path $dir 'journal.json'),($journal|ConvertTo-Json -Depth 7 -Compress))
 if($Held){[IO.File]::WriteAllText((Join-Path $dir 'hold-updates'),'{"schema": 1, "selection": "updates"}');$script:current.StartMode='Disabled'}
}
try{
 foreach($running in $true,$false){foreach($enabled in $true,$false){foreach($mode in 'Auto','Manual','Disabled'){
  if($running-and$mode-ceq'Disabled'){continue}
  Reset $running $enabled $mode;Complete-BackupQualificationUpdater $original $receipt
  Check ($current.Running-eq$running-and$current.TaskEnabled-eq$enabled-and$current.StartMode-ceq$mode)
  Check ((Export-ScheduledTask)-ceq$original.TaskXml)
  Reset $running $enabled $mode;WriteJournal 'recovered';Complete-BackupQualificationUpdater $original $receipt
  Check ($current.Running-eq$running-and$current.TaskEnabled-eq$enabled-and$current.StartMode-ceq$mode)
  foreach($kind in 'prepared','restoring','recovering','recovery_required','restored'){
   Reset $running $enabled $mode;WriteJournal $kind -Held
   $journal=(Get-FileHash (Join-Path $state 'backup-restore/journal.json')).Hash;$hold=(Get-FileHash (Join-Path $state 'backup-restore/hold-updates')).Hash
   Complete-BackupQualificationUpdater $original $receipt
   Check (!$current.Running-and$current.StartMode-ceq'Disabled'-and$current.TaskEnabled-eq$enabled-and$serviceActions-eq0)
   Check ((Export-ScheduledTask)-ceq$original.TaskXml)
   Check ((Get-FileHash (Join-Path $state 'backup-restore/journal.json')).Hash-ceq$journal-and(Get-FileHash (Join-Path $state 'backup-restore/hold-updates')).Hash-ceq$hold)
  }
 }}}
 # Every refusal before a positively owned state must perform zero mutations.
 foreach($bad in 'input_replaced','version_changed','receipt_type','prior_journal','orphan_hold','malformed_hold','wrong_source','wrong_database','stale_journal','unfinished_nohold','foreign_identity','foreign_task','unsafe_running','unsafe_startmode','task_reenabled','wrong_gate_mode','wrong_gate_running'){
  Reset;WriteJournal -Held
  $journalPath=Join-Path $state 'backup-restore/journal.json';$holdPath=Join-Path $state 'backup-restore/hold-updates'
  switch($bad){
   'input_replaced'{$receipt.InputCreatedTicks=[long]($receipt.InputCreatedTicks-1)}
   'version_changed'{[IO.File]::WriteAllText((Join-Path $PackageRoot 'VERSION'),'1.0.22')}
   'receipt_type'{$receipt.Schema=$true}
   'prior_journal'{$receipt.StartedTicks=[long]([DateTime]::UtcNow.Ticks);$receipt.StartedTicks=[long]($receipt.StartedTicks+10000000)}
   'orphan_hold'{[IO.File]::Delete($journalPath)}
   'malformed_hold'{[IO.File]::WriteAllText($holdPath,'{"schema":true,"selection":"updates"}')}
   'wrong_source'{$j=Get-Content $journalPath -Raw|ConvertFrom-Json;$j.source_host='foreign.invalid';$j|ConvertTo-Json -Depth 7 -Compress|Set-Content $journalPath}
   'wrong_database'{$j=Get-Content $journalPath -Raw|ConvertFrom-Json;$j.database='foreign';$j|ConvertTo-Json -Depth 7 -Compress|Set-Content $journalPath}
   'stale_journal'{$receipt.StartedTicks=[long]([DateTime]::UtcNow.Ticks)}
   'unfinished_nohold'{[IO.File]::Delete($holdPath);$current.StartMode='Auto'}
   'foreign_identity'{$current.MetadataHash='B'*64}
   'foreign_task'{$script:description='foreign'}
   'unsafe_running'{$current.Running=$true}
   'unsafe_startmode'{$current.StartMode='Auto'}
   'task_reenabled'{$current.TaskEnabled=$true}
   'wrong_gate_mode'{$j=Get-Content $journalPath -Raw|ConvertFrom-Json;$j.gates.services.OpenWebPBXUpdater='Manual';$j|ConvertTo-Json -Depth 7 -Compress|Set-Content $journalPath}
   'wrong_gate_running'{$j=Get-Content $journalPath -Raw|ConvertFrom-Json;$j.gates.running=@('OpenWebPBXUpdater');$j|ConvertTo-Json -Depth 7 -Compress|Set-Content $journalPath}
  }
  Refuses {Complete-BackupQualificationUpdater $original $receipt};Check ($serviceActions-eq0-and$taskActions-eq0)
 }
 foreach($kind in 'absent','recovered'){
  Reset;if($kind-ceq'recovered'){WriteJournal 'recovered'};$script:description='foreign-otherwise-same-model'
  Refuses {Complete-BackupQualificationUpdater $original $receipt};Check ($serviceActions-eq0-and$taskActions-eq0)
 }
 Reset $false $false;$current.TaskEnabled=$true;Refuses {Complete-BackupQualificationUpdater $original $receipt};Check ($serviceActions-eq0-and$taskActions-eq0)
 Reset $false $true;$current.Running=$true;Refuses {Complete-BackupQualificationUpdater $original $receipt};Check ($serviceActions-eq0-and$taskActions-eq0)
 # A Suspend refusal after capture but before its first mutation can safely restore unchanged choices.
 Reset;$current.Running=$true;$current.TaskEnabled=$true;Complete-BackupQualificationUpdater $original $receipt
 Check ($current.Running-and$current.TaskEnabled-and$serviceActions-eq0)
 Reset;$original=$null;Complete-BackupQualificationUpdater $original $receipt;Check ($serviceActions-eq0-and$taskActions-eq0)
 Reset;WriteJournal 'recovered';$original.Running=$true;$current.MetadataHash='foreign';Refuses {Complete-BackupQualificationUpdater $original $receipt};Check ($serviceActions-eq0-and$taskActions-eq0)
 # Exercise the exact parent wrapper with a stand-in for only its native call.
 $caller=Get-Content (Join-Path $SourceRoot 'tests/windows-backups.ps1') -Raw
 $startMarker=" `$root='C:\OpenWebPBX';`$state=Join-Path `$env:ProgramData 'OpenWebPBX'"
 $start=$caller.IndexOf($startMarker,[StringComparison]::Ordinal);$end=$caller.LastIndexOf('}finally{',[StringComparison]::Ordinal)
 Check ($start-ge0-and$end-gt$start-and$caller.IndexOf($startMarker,$start+1,[StringComparison]::Ordinal)-eq-1)
 $wrapper=$caller.Substring($start,$end-$start)
 $call=@'
 & 'C:\OpenWebPBX\backup-runtime\python.exe' -I (Join-Path $PSScriptRoot 'windows_backups_native.py') $input 1>(Join-Path $private 'child-private.out') 2>(Join-Path $private 'child-private.err')
 if($LASTEXITCODE){throw 'Native backup qualification failed; private report retained. No passing hosted result is implied.'}
'@
 Check ($wrapper.Contains($call));$wrapper=$wrapper.Replace($call,' Invoke-OriginalBackupChild')
 $wrapper=$wrapper.Replace(" `$root='C:\OpenWebPBX';`$state=Join-Path `$env:ProgramData 'OpenWebPBX'",'')
 $wrapper=$wrapper.Replace(" . (Join-Path `$PSScriptRoot 'windows-backup-updater-quiescence.ps1')",'')
 $actual=[scriptblock]::Create($wrapper)
 function New-BackupUpdaterQualificationReceipt{return @{fixture=$true}}
 function Suspend-HealthQualificationUpdater([ref]$Original){$script:suspends++;if($script:failure-ceq'before'){throw [InvalidOperationException]::new('primary-before')};$Original.Value=@{fixture=$true};if($script:failure-ceq'partial'){throw [InvalidOperationException]::new('primary-partial')}}
 function Invoke-OriginalBackupChild {$script:children++;if($script:failure-cin'child','both'){throw [IO.IOException]::new('primary-child')}}
 function Complete-BackupQualificationUpdater {$script:completions++;if($script:failure-cin'cleanup','both'){throw [UnauthorizedAccessException]::new('cleanup-only')}}
 foreach($case in 'none','before','partial','child','cleanup','both'){
  $script:failure=$case;$script:suspends=0;$script:children=0;$script:completions=0;$caught=$null
  try{. $actual}catch{$caught=$_}
  Check ($suspends-eq1-and$children-eq$(if($case-cin'before','partial'){0}else{1})-and$completions-eq1)
  if($case-ceq'none'){Check ($null-eq$caught)}elseif($case-ceq'cleanup'){Check ($caught.Exception-is[UnauthorizedAccessException])}elseif($case-cin'child','both'){Check ($caught.Exception-is[IO.IOException]-and$caught.Exception.Message-ceq'primary-child')}else{Check ($caught.Exception-is[InvalidOperationException])}
  if($case-ceq'both'){Check ($caught.Exception.Data['OpenWebBackupUpdaterCleanupRefused']-eq$true)}
 }
}finally{if(Test-Path $work){[IO.Directory]::Delete($work,$true)}}
[ordered]@{state='passed_actual_hold_aware_QA_source_controls_only';controls=$checks;PowerShell=$PSVersionTable.PSVersion.ToString();service_scheduler_and_child_are_adapters=$true;Windows_native_or_installed_PBX_actions=$false}|ConvertTo-Json
