#Requires -Version 7.4
#Requires -RunAsAdministrator
[CmdletBinding()]param([switch]$DisposableHostedRunner)
# Real Scheduler and cross-process sharing controls. No PBX is installed or
# contacted; the sole task is disabled and nonce-named. No release acceptance.
$ErrorActionPreference='Stop'
if(!$DisposableHostedRunner -or $env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows' -or $env:GITHUB_REPOSITORY -cne 'embire2/openwebpbx'){throw 'An explicitly disposable owned Windows runner is required.'}
$os=Get-CimInstance Win32_OperatingSystem
if($os.ProductType -eq 1 -or $os.Caption -notmatch 'Windows Server 2025'){throw 'Windows Server 2025 is required.'}
$checks=0;$phase='source';$taskOwned=$false;$child=$null;$cleanup=$false
$source=Split-Path $PSScriptRoot -Parent
$work=Join-Path $env:RUNNER_TEMP ('OpenWebUpdaterControls-'+[guid]::NewGuid().ToString('N'))
$taskName='OpenWebPBX-QA-'+[guid]::NewGuid().ToString('N')
$public=Join-Path $env:RUNNER_TEMP 'openwebpbx-updater-runtime-facts'
$facts=[ordered]@{schema=1;run_id=$env:GITHUB_RUN_ID;source_commit=$env:GITHUB_SHA;state='running';scope='isolated Scheduler and file-sharing components';release_eligible=$false;cleanup='pending'}
function Must([bool]$Value){$script:checks++;if(!$Value){$script:failedControlLine=[int](Get-PSCallStack)[1].ScriptLineNumber;throw 'An updater runtime assertion refused.'}}
function Definitions([string]$Path){
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors);Must (@($errors).Count -eq 0)
 $defs=@{};foreach($node in @($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))){Must (!$defs.ContainsKey($node.Name));$defs[$node.Name]=$node.Extent.Text};return $defs
}
function CopyRows($Rows){return $Rows|ConvertTo-Json -Depth 32|ConvertFrom-Json -AsHashtable}
function Snapshot {
 $task=Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
 Must ($task.TaskPath -ceq '\' -and !$task.Settings.Enabled -and @($task.Actions).Count -eq 1 -and $task.Actions[0].Execute -ceq "$env:SystemRoot\System32\cmd.exe" -and $task.Actions[0].Arguments -ceq '/c exit 0')
 [xml]$xml=Export-ScheduledTask -TaskName $taskName;$xml.PreserveWhitespace=$false
 $scheduler=New-Object -ComObject Schedule.Service;$scheduler.Connect()
 return @{'OpenWebPBX-PhoneHealth'=@{exists=$true;enabled=[bool]$task.Settings.Enabled;xml=$xml.OuterXml;acl=(Get-Acl -LiteralPath (Join-Path $env:SystemRoot ('System32/Tasks/'+$taskName))).Sddl;security=$scheduler.GetFolder('\').GetTask($taskName).GetSecurityDescriptor(7)}}
}
function StartReader([int]$HoldMilliseconds){
 $ready=Join-Path $work 'reader.ready';Remove-Item -LiteralPath $ready -ErrorAction SilentlyContinue
 $start=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path);$start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 foreach($arg in @('-NoProfile','-File',(Join-Path $work 'reader.ps1'),'-StateRoot',$work,'-Ready',$ready,'-HoldMilliseconds',[string]$HoldMilliseconds,'-LeaseSource',(Join-Path $source 'platform/OpenWebPbx.Server/WindowsCallRecordLease.cs'))){$start.ArgumentList.Add($arg)}
 $script:child=[Diagnostics.Process]::Start($start);$script:readerOut=$child.StandardOutput.ReadToEndAsync();$script:readerErr=$child.StandardError.ReadToEndAsync()
 $deadline=[DateTime]::UtcNow.AddSeconds(20)
 while(!(Test-Path -LiteralPath $ready) -and !$child.HasExited -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 20}
 Must (!$child.HasExited -and (Test-Path -LiteralPath $ready) -and [IO.File]::ReadAllText($ready) -ceq 'held')
}
function FinishReader {
 Must ($child.WaitForExit(20000));Must ($child.ExitCode -eq 0)
 Must ($readerOut.GetAwaiter().GetResult() -ceq '' -and $readerErr.GetAwaiter().GetResult() -ceq '')
 $child.Dispose();$script:child=$null
}
try{
 $null=New-Item -ItemType Directory -Path $work
 $defs=Definitions (Join-Path $PSScriptRoot 'windows-updater-qualification.ps1')
 $script:testPython=(Get-Command python.exe -CommandType Application -ErrorAction Stop|Select-Object -First 1).Source
 $names=@('Check','WriteJson','CheckedProcess','QualificationComparisonFields','QualificationComparisonDetails','QualificationTaskDifference','QualificationTaskDifferenceFields','EqualTaskSnapshots','NormalTaskPreservation','OpenQualificationCleanupLock')
 foreach($name in $names){
  Must ($defs.ContainsKey($name))
 }
 $equal=$defs.Equal.Replace('"$root\backup-runtime\python.exe"','$script:testPython');Must ($equal -cne $defs.Equal -and $equal.Replace('$script:testPython','"$root\backup-runtime\python.exe"') -ceq $defs.Equal)
 # A file-backed bootstrap preserves the actual comparator's PSScriptRoot.
 # Anonymous scriptblocks otherwise lose its adjacent Python script location.
 $fixture=Join-Path $work 'windows-updater-qualification.ps1'
 [IO.File]::WriteAllText($fixture,((@($names|ForEach-Object {$defs[$_]})+@($equal)) -join "`n"))
 $comparator=Join-Path $PSScriptRoot 'windows-compare-json.py';$copied=Join-Path $work 'windows-compare-json.py';Copy-Item -LiteralPath $comparator -Destination $copied
 Must ((Get-FileHash -LiteralPath $comparator).Hash -ceq (Get-FileHash -LiteralPath $copied).Hash);. $fixture
 $security=Definitions (Join-Path $source 'packaging/windows/Support-Recovery.ps1');. ([scriptblock]::Create($security['Test-OpenWebTaskSecurityEquivalent']))
 $tokens=$null;$errors=$null;$installer=[Management.Automation.Language.Parser]::ParseFile((Join-Path $source 'packaging/windows/Install-PhoneHealth.ps1'),[ref]$tokens,[ref]$errors);Must (@($errors).Count -eq 0)
 $trigger=@($installer.FindAll({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$triggers'},$true));Must ($trigger.Count -eq 1)
 $phase='native_scheduler'
 Must (!(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue))
 $action=New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\cmd.exe" -Argument '/c exit 0'
 $principal=New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
 $settings=New-ScheduledTaskSettingsSet -Disable -MultipleInstances IgnoreNew -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval ([TimeSpan]::FromMinutes(1))
 . ([scriptblock]::Create($trigger[0].Extent.Text))
 $taskOwned=$true;Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Trigger $triggers|Out-Null
 $before=Snapshot;Start-Sleep -Milliseconds 1200;$started=[DateTime]::UtcNow
 . ([scriptblock]::Create($trigger[0].Extent.Text))
 Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Trigger $triggers -Force|Out-Null
 $after=Snapshot;Must ($before['OpenWebPBX-PhoneHealth'].xml -cne $after['OpenWebPBX-PhoneHealth'].xml)
 $old=$defs.NormalTaskPreservation.Replace(",'OpenWebPBX-PhoneHealth')",')');Must ($old -cne $defs.NormalTaskPreservation -and $old.Replace("'OpenWebPBX-TenantDomains')","'OpenWebPBX-TenantDomains','OpenWebPBX-PhoneHealth')") -ceq $defs.NormalTaskPreservation)
 $phase='native_scheduler_old_comparator'
 . ([scriptblock]::Create($old));$caught=$null;try{NormalTaskPreservation $before $after $started}catch{$caught=$_}
 Must ($null -ne $caught -and $script:qualificationComparisonFailure.report.comparison_result -ceq 'different' -and $script:qualificationComparisonFailure.task.known_tasks['OpenWebPBX-PhoneHealth'][0] -ceq 'xml')
 $phase='native_scheduler_corrected_comparator'
 . ([scriptblock]::Create($defs.NormalTaskPreservation));NormalTaskPreservation $before $after $started;Must ($null -eq $script:qualificationComparisonFailure)
 foreach($case in 'action','interval','boot','principal','enabled','file_acl','com_acl','future','duplicate'){
  $changed=CopyRows $after;$row=$changed['OpenWebPBX-PhoneHealth'];[xml]$xml=$row.xml;$ns=[Xml.XmlNamespaceManager]::new($xml.NameTable);$ns.AddNamespace('t','http://schemas.microsoft.com/windows/2004/02/mit/task')
  switch($case){
   'action'{$xml.SelectSingleNode('/t:Task/t:Actions/t:Exec/t:Arguments',$ns).InnerText='/c exit 1'}
   'interval'{$xml.SelectSingleNode('/t:Task/t:Triggers/t:TimeTrigger/t:Repetition/t:Interval',$ns).InnerText='PT1S'}
   'boot'{$node=$xml.SelectSingleNode('/t:Task/t:Triggers/t:BootTrigger',$ns);$null=$node.ParentNode.RemoveChild($node)}
   'principal'{$xml.SelectSingleNode('/t:Task/t:Principals/t:Principal/t:UserId',$ns).InnerText='S-1-5-19'}
   'enabled'{$row.enabled=$true};'file_acl'{$row.acl+='changed'};'com_acl'{$row.security='D:(A;;FA;;;WD)'}
   'future'{$xml.SelectSingleNode('/t:Task/t:Triggers/t:TimeTrigger/t:StartBoundary',$ns).InnerText=[DateTime]::UtcNow.AddDays(1).ToString('o')}
   'duplicate'{$node=$xml.SelectSingleNode('/t:Task/t:Triggers/t:TimeTrigger',$ns);$null=$node.ParentNode.AppendChild($node.CloneNode($true))}
  }
  $row.xml=$xml.OuterXml;$refused=$false;try{NormalTaskPreservation $before $changed $started}catch{$refused=$true};Must $refused
 }
 $facts.scheduler_original_refusal=$true;$facts.scheduler_renewal_only=$true;$facts.scheduler_other_changes_refused=9
 $phase='native_cleanup_lease'
 $mutex=Join-Path $work 'upgrade.lock';[IO.File]::WriteAllText($mutex,'unchanged-fixture-lock');$original=(Get-FileHash -LiteralPath $mutex).Hash
 $reader=@'
param([string]$StateRoot,[string]$Ready,[int]$HoldMilliseconds,[string]$LeaseSource)
$ErrorActionPreference='Stop'
$code=[IO.File]::ReadAllText($LeaseSource)
if(!$code.StartsWith("namespace OpenWebPbx.Server;")){throw 'Unexpected lease source.'}
$code=$code.Replace('namespace OpenWebPbx.Server;',"using System; using System.IO; namespace OpenWebPbx.Server {")+"`n}"
Add-Type -TypeDefinition $code -CompilerOptions '/nullable:enable'
$lease=[OpenWebPbx.Server.WindowsCallRecordLease]::TryAcquire($StateRoot)
if(!$lease){throw 'The actual CDR lease was not acquired.'}
try{[IO.File]::WriteAllText($Ready,'held');Start-Sleep -Milliseconds $HoldMilliseconds}finally{$lease.Dispose()}
'@
 [IO.File]::WriteAllText((Join-Path $work 'reader.ps1'),$reader)
 $free=OpenQualificationCleanupLock $mutex;try{Must ($free.CanRead -and $free.CanWrite)}finally{$free.Dispose()}
 StartReader 1000
 $oldError=$null;try{$unexpected=[IO.File]::Open($mutex,'OpenOrCreate','ReadWrite','None');$unexpected.Dispose()}catch{$oldError=$_}
 Must ($null -ne $oldError -and $oldError.Exception.GetBaseException() -is [IO.IOException] -and ($oldError.Exception.GetBaseException().HResult -band 65535) -eq 32)
 $watch=[Diagnostics.Stopwatch]::StartNew();$acquired=OpenQualificationCleanupLock $mutex 5000
 try{Must ($watch.ElapsedMilliseconds -ge 500 -and $watch.ElapsedMilliseconds -lt 5000 -and $acquired.CanWrite)}finally{$acquired.Dispose()};FinishReader
 StartReader 1500
 $watch=[Diagnostics.Stopwatch]::StartNew();$caught=$null;try{$unexpected=OpenQualificationCleanupLock $mutex 250;$unexpected.Dispose()}catch{$caught=$_}
 Must ($null -ne $caught -and $caught.Exception.GetBaseException() -is [IO.IOException] -and ($caught.Exception.GetBaseException().HResult -band 65535) -eq 32 -and $watch.ElapsedMilliseconds -ge 250 -and $watch.ElapsedMilliseconds -lt 1000);FinishReader
 $watch=[Diagnostics.Stopwatch]::StartNew();$caught=$null;try{$unexpected=OpenQualificationCleanupLock $work 1000;$unexpected.Dispose()}catch{$caught=$_}
 Must ($null -ne $caught -and $caught.Exception.GetBaseException() -is [UnauthorizedAccessException] -and $watch.ElapsedMilliseconds -lt 500)
 Must ((Get-FileHash -LiteralPath $mutex).Hash -ceq $original)
 $facts.actual_cdr_lease_original_refusal=$true;$facts.cleanup_acquisition_waits_and_bounds=$true;$facts.other_errors_not_retried=$true;$facts.lock_bytes_preserved=$true;$facts.state='passed'
}catch{
 $facts.state='failed';$facts.failed_phase=$phase;$facts.error_type=$_.Exception.GetType().Name;$facts.source_line=[int]$_.InvocationInfo.ScriptLineNumber
 if($script:failedControlLine -gt 0 -and $script:failedControlLine -le 1000){$facts.control_line=$script:failedControlLine}
}finally{
 try{
  if($child){if(!$child.HasExited){$child.Kill();Must ($child.WaitForExit(10000))};$child.Dispose()}
  if($taskOwned){$null=Snapshot;Unregister-ScheduledTask -TaskName $taskName -Confirm:$false;Must (!(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue))}
  if(Test-Path -LiteralPath $work){Remove-Item -LiteralPath $work -Recurse -Force;Must (!(Test-Path -LiteralPath $work))};$cleanup=$true
 }catch{$facts.cleanup_error_type=$_.Exception.GetType().Name;$facts.cleanup_source_line=[int]$_.InvocationInfo.ScriptLineNumber;$facts.state='failed'}
 $facts.cleanup=if($cleanup){'owned task, child and files removed'}else{'failed'};$facts.checks=$checks
 $null=New-Item -ItemType Directory -Path $public -Force;[IO.File]::WriteAllText((Join-Path $public 'qualification.json'),($facts|ConvertTo-Json -Depth 8))
}
if($facts.state -cne 'passed'){throw 'Isolated updater runtime controls failed; see bounded facts.'}
Write-Output ('PASS '+$checks+' real Scheduler, original CDR lease and bounded cleanup controls')
