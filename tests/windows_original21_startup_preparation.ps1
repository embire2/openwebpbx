param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$script:checks=0
function Verify([bool]$Value){if(!$Value){throw ('Original startup control '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
function Check([bool]$Value,[string]$Message){if(!$Value){throw $Message}}
$tokens=$null;$errors=$null;$path=Join-Path $SourceRoot 'tests/windows-updater-qualification.ps1';$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors);Verify (!$errors.Count)
foreach($name in 'TestQualificationOriginal21Startup','WaitOriginal21UpdaterStartup','OriginalProcessProofSource','AssertOriginalProcessState'){$node=@($ast.FindAll({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst]-and $n.Name-ceq $name},$true));Verify ($node.Count-eq 1);. ([scriptblock]::Create($node[0].Extent.Text))}
. (OriginalProcessProofSource (Join-Path $SourceRoot 'tests/windows-upgrade-acceptance.ps1'))
Verify ($null-ne (Get-Command GetManagerOriginalExitProof -CommandType Function))
function Refuses([scriptblock]$Body){$caught=$null;try{& $Body}catch{$caught=$_};Verify ($null-ne $caught)}
$born=[DateTime]::UtcNow.AddMinutes(-1);$now=[DateTime]::UtcNow
foreach($value in $now.ToString('o'),$now,([DateTimeOffset]$now)){$s=@{state='up_to_date';installed_version='1.0.21';platform='windows-x64';checked_at=$value};Verify (TestQualificationOriginal21Startup $s $born $now)}
foreach($case in 'wrong_state','wrong_version','wrong_platform','stale','future','missing','naive','array','boolean'){
 $s=@{state='up_to_date';installed_version='1.0.21';platform='windows-x64';checked_at=$now.ToString('o')}
 switch($case){wrong_state{$s.state='checking'}wrong_version{$s.installed_version='1.0.22'}wrong_platform{$s.platform='linux-x64'}stale{$s.checked_at=$born.AddTicks(-1).ToString('o')}future{$s.checked_at=$now.AddTicks(1).ToString('o')}missing{$s.Remove('checked_at')}naive{$s.checked_at='2026-11-03T23:00:00'}array{$s.checked_at=@($now,$now)}boolean{$s.state=$true}}
 Verify (!(TestQualificationOriginal21Startup $s $born $now))
}
$root='C:\OpenWebPBX';$state='C:\ProgramData\OpenWebPBX';$BaseVersion='1.0.21';$script:heldProcesses=[Collections.Generic.List[Diagnostics.Process]]::new()
function Reset([string]$Mode){$script:mode=$Mode;$script:versionCalls=0;$script:sleeps=0;$script:coreRunning=$true;$script:heldBirth=$null;$script:readyAfterSleep=$false;$script:facts=@{}}
function InstalledVersions([string]$Version){Verify ($Version-ceq '1.0.21'-and $script:coreRunning);$script:versionCalls++;if($script:mode-ceq 'changed_generation'-and $script:versionCalls-gt 1){return $PID+1};return $PID}
function RetainQualificationProcess($Process,[int]$ExpectedPid,[string]$ExpectedPath,[string]$ExpectedSid,[int]$ExpectedSession,[DateTime]$NotBefore){
 Verify ($Process.Id-eq $PID-and $ExpectedPid-eq $PID-and $ExpectedPath-ceq 'C:\OpenWebPBX\updater\slots\1.0.21\OpenWebPbx.Updater.exe'-and $ExpectedSid-ceq 'S-1-5-18'-and $ExpectedSession-eq 0-and $NotBefore-eq [DateTime]::MinValue)
 $script:heldBirth=$Process.StartTime.ToUniversalTime();$script:heldProcesses.Add($Process);return @{process=$Process;handle=$Process.Handle;pid=$PID;start_ticks=$heldBirth.Ticks;identity_verified=($script:mode-cne 'unverified_held_tuple')}
}
function Get-Item {[CmdletBinding()]param([string]$LiteralPath,[switch]$Force);Verify ($LiteralPath-ceq 'C:\ProgramData\OpenWebPBX\updates\status.json');return [pscustomobject]@{PSIsContainer=$false;Attributes=[IO.FileAttributes]::Normal;Length=128;FullName='CONTROLLED_STATUS'}}
function Get-Content {[CmdletBinding()]param([string]$LiteralPath,[switch]$Raw)
 Verify ($LiteralPath-ceq 'CONTROLLED_STATUS'-and $Raw)
 if($script:mode-ceq 'late_ready'){[Threading.Thread]::Sleep(80)}
 $s=@{state='up_to_date';installed_version='1.0.21';platform='windows-x64';checked_at=[DateTime]::UtcNow.ToString('o')}
 switch($script:mode){stale{$s.checked_at=$script:heldBirth.AddTicks(-1).ToString('o')}wrong_version{$s.installed_version='1.0.22'}future{$s.checked_at=[DateTime]::UtcNow.AddMinutes(1).ToString('o')}malformed{return '{malformed'}wait_once{if(!$script:readyAfterSleep){$s.state='checking'}}}
 return $s|ConvertTo-Json -Compress
}
function Start-Sleep {param([int]$Milliseconds);Verify ($Milliseconds-eq 250);$script:sleeps++;if($script:mode-ceq 'wait_once'){$script:readyAfterSleep=$true}else{throw 'Controlled bounded observation stop'}}
try{
 foreach($mode in 'ready','wait_once'){
  Reset $mode;$deadline=[DateTime]::UtcNow.AddSeconds(600);WaitOriginal21UpdaterStartup -DeadlineUtc $deadline
  Verify ($facts.original21_startup_preparation.state-ceq 'passed'-and $facts.original21_startup_preparation.manual_worker_or_check-eq $false-and $script:coreRunning-and $deadline.Kind-eq [DateTimeKind]::Utc)
  Verify ($script:sleeps-eq $(if($mode-ceq 'wait_once'){1}else{0}))
 }
 foreach($mode in 'changed_generation','unverified_held_tuple','stale','wrong_version','future','malformed') {Reset $mode;Refuses {WaitOriginal21UpdaterStartup -DeadlineUtc ([DateTime]::UtcNow.AddSeconds(600))};Verify (!$facts.original21_startup_preparation-and $coreRunning)}
 Reset expired;Refuses {WaitOriginal21UpdaterStartup -DeadlineUtc ([DateTime]::UtcNow.AddTicks(-1))};Verify ($versionCalls-eq 0)
 Reset late_ready;Refuses {WaitOriginal21UpdaterStartup -DeadlineUtc ([DateTime]::UtcNow.AddMilliseconds(50))};Verify (!$facts.original21_startup_preparation-and $coreRunning)
 $source=$ast.Extent.Text;$start=$source.IndexOf('$initializationDeadline=[DateTime]::UtcNow.AddSeconds(600)');$tick=$source.IndexOf('WaitOriginal21UpdaterStartup -DeadlineUtc $initializationDeadline',$start);$quiet=$source.IndexOf('Suspend-Original21PrebaselineCore -PackageRoot $package',$tick);$tenant=$source.IndexOf('WaitActualTenantIdle -DeadlineUtc $initializationDeadline',$quiet);$backup=$source.IndexOf('InitializeQualificationBackupWorker -Root $root',$tenant);$resume=$source.IndexOf('Resume-Original21PrebaselineCore -Token $prebaselineCore',$backup);$lab=$source.IndexOf("`$phase='laboratory HTTPS trust import'",$resume)
 Verify ($start-ge 0-and $tick-gt $start-and $quiet-gt $tick-and $tenant-gt $quiet-and $backup-gt $tenant-and $resume-gt $backup-and $lab-gt $resume)
 Verify (([regex]::Matches($source.Substring($start,$backup-$start),'AddSeconds\(600\)')).Count-eq 1)
 $imports=@($ast.FindAll({param($n)$n-is [Management.Automation.Language.CommandAst]-and $n.Extent.Text-ceq '. (OriginalProcessProofSource (Join-Path $PSScriptRoot ''windows-upgrade-acceptance.ps1''))'},$true));Verify ($imports.Count-eq 1-and $imports[0].Extent.StartOffset-lt $tick)
 $self=[Diagnostics.Process]::GetProcessById($PID);try{$held=@{process=$self;handle=$self.Handle;pid=$PID;start_ticks=[long]$self.StartTime.ToUniversalTime().Ticks;identity_verified=$true};AssertOriginalProcessState $held $PID $false 'Real retained current process must remain live';Verify ((GetManagerOriginalExitProof $held $PID).manager_original_identity_verified);$held.start_ticks++;Refuses {AssertOriginalProcessState $held $PID $false 'Wrong generation must refuse'}}finally{$self.Dispose()}
 $startup=@($ast.FindAll({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst]-and $n.Name-ceq 'WaitOriginal21UpdaterStartup'},$true))[0].Extent.Text
 foreach($forbidden in 'Start-ScheduledTask','Start-Service','worker()','--check-once','WriteJson','New-Item'){Verify (!$startup.Contains($forbidden))}
 Verify ($startup.Contains('$held.start_ticks')-and $startup.Contains('AssertOriginalProcessState')-and $startup.Contains('[DateTime]::UtcNow-lt $DeadlineUtc'))
 Write-Output ('PASS '+$checks+' actual startup predicate/caller, held tuple, stale/foreign/deadline and shared600 ordering controls; source adapters only')
}finally{foreach($process in $script:heldProcesses){$process.Dispose()}}
