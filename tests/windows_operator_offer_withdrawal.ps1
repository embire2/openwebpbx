# Actual source functions/loop with only CIM, status reads and time adapters.
# A real owned local Process supplies the retained hashtable shape; no service,
# installed worker, task, product path, host clock or network is changed.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$checks=0
function Verify([bool]$Value){if(!$Value){throw ('Operator withdrawal control '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
function Check([bool]$Value,[string]$Message){if(!$Value){throw $Message}}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-updater-qualification.ps1'),[ref]$tokens,[ref]$errors);Verify (!$errors.Count)
function SourceFunction([string]$Name){$n=@($ast.FindAll({param($x)$x-is [Management.Automation.Language.FunctionDefinitionAst]-and $x.Name-ceq $Name},$true));Verify ($n.Count-eq 1);return $n[0].Extent.Text}
Invoke-Expression (SourceFunction 'TestQualificationOperatorStartupMilestone')
Invoke-Expression (SourceFunction 'RetainQualificationProcess')
$script:retainedProcesses=[Collections.Generic.List[Diagnostics.Process]]::new();$currentProcess=[Diagnostics.Process]::GetCurrentProcess();$ownedPath=$currentProcess.Path;$ownedSession=$currentProcess.SessionId
function Get-CimInstance {param($ClassName,$Filter)Verify ($ClassName-ceq 'Win32_Process'-and $Filter-ceq ('ProcessId='+$currentProcess.Id));return [pscustomobject]@{ExecutablePath=$ownedPath;SessionId=$ownedSession}}
function Invoke-CimMethod {param($InputObject,$MethodName)Verify ($MethodName-ceq 'GetOwnerSid');return @{ReturnValue=0;Sid='S-1-5-18'}}
try{
 $script:held=RetainQualificationProcess $currentProcess $currentProcess.Id $ownedPath 'S-1-5-18' $ownedSession ([DateTime]::MinValue)
 Verify ($held-is [Collections.IDictionary]-and $held.Count-eq 5-and $held.ContainsKey('process')-and $held.ContainsKey('handle')-and $held.ContainsKey('pid')-and $held.ContainsKey('start_ticks')-and $held.identity_verified)
 $created=[DateTime]::new([long]$held.start_ticks,[DateTimeKind]::Utc);Verify ($created-eq $currentProcess.StartTime.ToUniversalTime()-and $created.Kind-eq [DateTimeKind]::Utc)
 $observed=$created.AddSeconds(10)
 $validStatus=@{state='error';installed_version='1.0.21';platform='windows-x64';checked_at=$created.AddSeconds(2).ToString('o')}
 $validRequest=@{mode='operator-rollback';kind='feed';request_path='/embire2/openwebpbx/releases/latest/download/windows-update-manifest.json';http_status=503;at_utc=$created.AddSeconds(1).ToString('o');bytes=0;complete=$true;loopback=$true;original_url=$true;updater_user_agent=$true}
 Verify (TestQualificationOperatorStartupMilestone $validStatus @($validRequest) $created $observed)
 foreach($case in 'old_status','future_status','wrong_version','wrong_platform','not_error','old_request','future_request','wrong_kind','wrong_mode','wrong_path','status_string','bytes_bool','flag_number','mode_array','bad_date'){
  $s=$validStatus|ConvertTo-Json|ConvertFrom-Json -AsHashtable;$r=$validRequest|ConvertTo-Json|ConvertFrom-Json -AsHashtable
  switch($case){old_status{$s.checked_at=$created.AddTicks(-1)}future_status{$s.checked_at=$observed.AddSeconds(1)}wrong_version{$s.installed_version='1.0.22'}wrong_platform{$s.platform='debian-x64'}not_error{$s.state='downloading'}old_request{$r.at_utc=$created.AddTicks(-1)}future_request{$r.at_utc=$observed.AddSeconds(1)}wrong_kind{$r.kind='archive'}wrong_mode{$r.mode='normal'}wrong_path{$r.request_path='/foreign'}status_string{$r.http_status='503'}bytes_bool{$r.bytes=$false}flag_number{$r.complete=1}mode_array{$r.mode=@('operator-rollback')}bad_date{$r.at_utc='PRIVATE_invalid'}}
  Verify (!(TestQualificationOperatorStartupMilestone $s @($r) $created $observed))
 }
 # The first response may precede wrapper-return; process creation is the bound.
 $wrapperReturned=$created.AddSeconds(9);Verify ($created.AddSeconds(1)-lt $wrapperReturned-and (TestQualificationOperatorStartupMilestone $validStatus @($validRequest) $created $observed))
 $operator=SourceFunction 'ActualOperatorRollback';$begin=$operator.IndexOf('$deadline=[DateTime]::UtcNow.AddSeconds(120)');$end=$operator.IndexOf(' AssertOriginalProcessState $heldWorker',$begin);Verify ($begin-ge 0-and $end-gt $begin)
 $loop=$operator.Substring($begin,$end-$begin);Verify (($loop.Split(@('AddSeconds(120)'),[StringSplitOptions]::None)).Count-eq 2)
 Verify ($loop.Contains('[DateTime]::new([long]$restoredWorker.start_ticks,[DateTimeKind]::Utc)')-and !$loop.Contains('$restoredWorker.StartTime'))
 $adapted=$loop.Replace('[DateTime]::UtcNow','(Get-OwnedUtcNow)');Verify ($adapted.Replace('(Get-OwnedUtcNow)','[DateTime]::UtcNow')-ceq $loop);$caller=[ScriptBlock]::Create($adapted)
 Verify ($operator.IndexOf("@{mode='operator-rollback'}")-lt $operator.IndexOf("'operator-rollback-native' -Timeout 1200000"))
 Verify ($operator.IndexOf('foreach($gate in')-lt $operator.IndexOf("@{mode='operator-rollback'}"))
 Verify ($operator.IndexOf('Check $startupObserved')-lt $operator.IndexOf("FileSnapshot -Stage 'after_operator_full'"))
 Verify ($operator-cnotmatch 'Stop-Service|Start-Service|Start-ScheduledTask|Set-Service')
 $BaseVersion='1.0.21';$root='SOURCE_ONLY_ROOT';$state='SOURCE_ONLY_STATE';$qa='SOURCE_ONLY_QA';$CurrentPid=$held.pid+1;$started=$created.AddSeconds(-1)
 function Get-OwnedUtcNow {return $script:clock}
 function InstalledVersions {param($Version)Verify ($Version-ceq '1.0.21');$script:versionReads++;if($script:scenario-ceq 'wrong_generation'-and $script:versionReads-gt 1){return $held.pid+2};return $held.pid}
 function RetainQualificationProcess {param($Process,$ExpectedPid,$ExpectedPath,$ExpectedSid,$ExpectedSession,$NotBefore)
  Verify ($Process.Id-eq $held.pid-and $ExpectedPid-eq $held.pid-and $ExpectedPath-ceq 'SOURCE_ONLY_ROOT\updater\slots\1.0.21\OpenWebPbx.Updater.exe'-and $ExpectedSid-ceq 'S-1-5-18'-and $ExpectedSession-eq 0-and $NotBefore-eq $started);return $script:held
 }
 function AssertOriginalProcessState {param($Held,$ExpectedPid,$Exited,$Message)Verify ([object]::ReferenceEquals($Held,$script:held)-and $ExpectedPid-eq $held.pid-and !$Exited)}
 function Get-Content {param($Path,[switch]$Raw)
  if($Path-ceq 'SOURCE_ONLY_STATE\updates\status.json'){
   $script:statusReads++;$s=@{};foreach($key in $validStatus.Keys){$s[$key]=$validStatus[$key]}
   if($scenario-ceq 'delayed_status'-and $statusReads-lt 3){$s.checked_at=$created.AddSeconds(-1)}
   if($scenario-ceq 'late_status'){$script:clock=$script:fence.AddSeconds(1)}
   return $s|ConvertTo-Json -Compress
  }
  Verify ($Path-ceq (Join-Path $qa 'transport-requests.json'));return @{requests=@($validRequest)}|ConvertTo-Json -Depth 5 -Compress
 }
 function Start-Sleep {param($Milliseconds)Verify ($Milliseconds-eq 500);$script:sleeps++;$script:clock=$script:clock.AddMilliseconds(500)}
 foreach($script:scenario in 'success','delayed_status','wrong_generation','late_status'){
  $script:clock=$created.AddSeconds(10);$script:fence=$clock.AddSeconds(120);$script:versionReads=0;$script:statusReads=0;$script:sleeps=0;$facts=@{};$caught=$null
  try{. $caller}catch{$caught=$_}
  Verify ($deadline-eq $script:fence)
  if($scenario-cin 'success','delayed_status'){
   Verify ($null-eq $caught-and $startupObserved-and $facts.operator_startup_milestone.state-ceq 'passed')
   Verify ($restoredCreated-eq $created-and $restoredCreated.Kind-eq [DateTimeKind]::Utc)
   if($scenario-ceq 'delayed_status'){Verify ($sleeps-eq 2)}
  }else{Verify ($null-ne $caught-and !$startupObserved-and !$facts.ContainsKey('operator_startup_milestone'))}
 }
 @{state='passed';checks=$checks;actual_retained_hashtable=$true;source_restart_loop=$true;clock_cim_and_status_adapters=$true;no_product_service_task_or_network_action=$true}|ConvertTo-Json -Compress
}finally{foreach($p in $script:retainedProcesses){$p.Dispose()}}
