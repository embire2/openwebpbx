#Requires -RunAsAdministrator
#Requires -Version 5.1
# Real NTFS/ACL/child termination and optional exact original .NET updater boot.
# All runtime, database/engine endpoints and update paths are fictional fixtures.
[CmdletBinding()]
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent),[string]$LegacyUpdaterDirectory,[string]$UpdaterDirectory,[ValidatePattern('^\d+\.\d+\.\d+$')][string]$ExpectedUpdaterVersion)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest;$script:checks=0
if($PSVersionTable.PSEdition -ne 'Desktop'){throw 'Run native recovery controls with Windows PowerShell, matching the installed updater.'}
function Assert([bool]$Value){if(!$Value){throw ('Upgrade recovery control failed at test line '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
function Refuses([scriptblock]$Action){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Assert $failed}
. (Join-Path $SourceRoot 'packaging\windows\UpgradeRecovery.Common.ps1')
. (Join-Path $SourceRoot 'packaging\windows\File-Security.ps1')
$work=Join-Path ([IO.Path]::GetTempPath()) ('openweb-upgrade-recovery-'+[Guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($work);Set-OpenWebRecoveryPrivate $work -Directory
$children=[Collections.Generic.List[Diagnostics.Process]]::new()
if($LegacyUpdaterDirectory -and $UpdaterDirectory){throw 'Choose one explicit updater component proof.'}
if($LegacyUpdaterDirectory){$UpdaterDirectory=$LegacyUpdaterDirectory;$ExpectedUpdaterVersion='1.0.6'}
if($UpdaterDirectory){if(!$ExpectedUpdaterVersion){throw 'An exact updater version is required.'};Assert ([Reflection.AssemblyName]::GetAssemblyName((Join-Path $UpdaterDirectory 'OpenWebPbx.Updater.dll')).Version -eq [version]($ExpectedUpdaterVersion+'.0'))}

function WriteText([string]$Path,[string]$Value){Write-OpenWebRecoveryFile $Path ([Text.UTF8Encoding]::new($false).GetBytes($Value))}
function Json([string]$Path,$Value){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 32),[Text.UTF8Encoding]::new($false))}
function Case([string]$Kind='default'){
 $base=Join-Path $work ([Guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($base);Set-OpenWebRecoveryPrivate $base -Directory
 $root=Join-Path $base 'root';$state=Join-Path $base 'state';$engine=Join-Path $base 'engine';$package=Join-Path $base 'package';$backup=Join-Path $state 'backups\owned-sealed'
 foreach($dir in $root,$state,$engine,$package,(Join-Path $root 'tools'),(Join-Path $state 'updates'),$backup){$null=[IO.Directory]::CreateDirectory($dir);Set-OpenWebRecoveryPrivate $dir -Directory}
 $runtime=[ordered]@{ConnectionStrings=@{Pbx='Host=127.0.0.1;Port=1;Database=fictional;Username=fictional;Password=fictional-only;Timeout=1;Command Timeout=1;Pooling=false'};Unrelated=@{Keep='EXACT';Number=7;Flag=$false}}
 if($Kind -ceq 'date'){$runtime.Unrelated.ISO='2026-10-22T01:02:03.000Z'}
 if($Kind -ceq 'large_integer'){$runtime.Unrelated.Large=9007199254740993L}
 if($Kind -ceq 'fraction'){$runtime.Unrelated.Fraction=0.125}
 if($Kind -ceq 'deep'){$nested=[pscustomobject]@{leaf='KEEP'};for($i=0;$i -lt 27;$i++){$nested=[pscustomobject]@{child=$nested}};$runtime.Unrelated.Deep=$nested}
 if($Kind -cne 'missing_updater'){$runtime.Updater=[ordered]@{DataDirectory=(Join-Path $state 'updates');PublicStatus=(Join-Path $state 'public-status.json');InstalledVersionPath=(Join-Path $state 'installation.json')}}
 if($Kind -cin 'default','foreign','invalid','empty','partial'){$runtime.Updater.Helper=if($Kind -ceq 'foreign'){'C:\foreign\untrusted.ps1'}elseif($Kind -ceq 'invalid'){42}elseif($Kind -ceq 'empty'){''}else{Join-Path $root 'tools\Upgrade-OpenWebPBX.ps1'}}
 WriteText (Join-Path $state 'runtime.json') ($runtime|ConvertTo-Json -Depth 32)
 WriteText (Join-Path $state 'installation.json') '{"Version":"1.0.6","Completed":true}'
 $old='param([switch]$Recover) if(!$Recover){exit 2};[IO.File]::WriteAllText('+("'"+(Join-Path $state 'selected-entry.txt').Replace("'","''")+"'")+",'old');exit 75"
 WriteText (Join-Path $root 'tools\Upgrade-OpenWebPBX.ps1') $old
 foreach($name in 'UpgradeRecovery.Common.ps1','File-Security.ps1'){WriteText (Join-Path $package $name) ([IO.File]::ReadAllText((Join-Path $SourceRoot ('packaging\windows\'+$name))))}
 foreach($name in 'Restore-Gates.ps1','Support-Recovery.ps1','Web-Readiness.ps1','Dtls.Common.ps1','PhoneHealth-Security.ps1','PhpRuntime.Common.ps1','Write-PrivateState.ps1','check-call-engine.php','windows-log.php','CallRecords.Common.ps1'){WriteText (Join-Path $package $name) ('# FICTIONAL dependency '+$name)}
 WriteText (Join-Path $package 'Upgrade-OpenWebPBX.ps1') ($old.Replace("'old'","'new'"))
 WriteText (Join-Path $package 'VERSION') "1.0.20`n"
 if($Kind -ceq 'partial'){WriteText (Join-Path $package 'aaa-copy-window.php') ('#'+('x'*8388608))}
 $manifest=@{version='1.0.20';files=@{}};foreach($file in Get-ChildItem -LiteralPath $package -File){$manifest.files[$file.Name]=Get-OpenWebRecoveryHash (Read-OpenWebRecoveryBytes $file.FullName)}
 WriteText (Join-Path $package 'release-manifest.json') ($manifest|ConvertTo-Json -Depth 8)
 WriteText (Join-Path $backup 'runtime.json') ([IO.File]::ReadAllText((Join-Path $state 'runtime.json')))
 $sealed=@{schema=1;files=@{'runtime.json'=(Get-OpenWebRecoveryHash (Read-OpenWebRecoveryBytes (Join-Path $backup 'runtime.json')))}}
 WriteText (Join-Path $backup 'backup-manifest.json') ($sealed|ConvertTo-Json -Depth 8)
 WriteText (Join-Path $backup 'complete.json') (@{version='1.0.6';integrity_sha256=(Get-OpenWebRecoveryHash (Read-OpenWebRecoveryBytes (Join-Path $backup 'backup-manifest.json')))}|ConvertTo-Json)
 Json (Join-Path $state 'updates\install-journal.json') @{schema=1;state='quiescing';version='1.0.20';previous_version='1.0.6';backup_path=$backup}
 return [pscustomobject]@{Base=$base;Root=$root;State=$state;Engine=$engine;Package=$package;Backup=$backup;Runtime=(Join-Path $state 'runtime.json');Journal=(Join-Path $state 'updates\install-journal.json')}
}
function NewEntry($Case,[IO.FileStream]$Lock){return New-OpenWebUpgradeRecovery -PackageRoot $Case.Package -Root $Case.Root -StateRoot $Case.State -EngineRoot $Case.Engine -Backup $Case.Backup -MaintenanceLock $Lock}
function Pin($Case,$Entry){$j=Get-Content -LiteralPath $Case.Journal -Raw|ConvertFrom-Json;$j.state='deploying';$j|Add-Member NoteProperty recovery_entry $Entry;Json $Case.Journal $j}
function Publish($Case,$Entry,[IO.FileStream]$Lock){Publish-OpenWebUpgradeRecovery -Entry $Entry -Root $Case.Root -StateRoot $Case.State -EngineRoot $Case.Engine -MaintenanceLock $Lock}
function Complete($Case,$Entry,[IO.FileStream]$Lock,[string]$Outcome){Complete-OpenWebUpgradeRecovery -Entry $Entry -Root $Case.Root -StateRoot $Case.State -EngineRoot $Case.Engine -MaintenanceLock $Lock -Outcome $Outcome}
function Child([string]$Executable,[string[]]$Arguments,[string]$Directory,[hashtable]$Environment=@{}){
 $id=[Guid]::NewGuid().ToString('N');$start=New-Object Diagnostics.ProcessStartInfo $Executable;$start.UseShellExecute=$false;$start.WorkingDirectory=$Directory;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 # This fixture uses only owned paths without quote characters. No credentials
 # are passed as arguments or inherited from installed runtime configuration.
 foreach($arg in $Arguments){Assert (!$arg.Contains('"'))};$start.Arguments=($Arguments|ForEach-Object {'"'+$_+'"'}) -join ' '
 foreach($key in $Environment.Keys){$start.EnvironmentVariables[$key]=$Environment[$key]}
 $p=[Diagnostics.Process]::Start($start);$children.Add($p);return [pscustomobject]@{Process=$p;Output=$p.StandardOutput.ReadToEndAsync();Errors=$p.StandardError.ReadToEndAsync();Directory=$Directory;Id=$id}
}
function Finish($Child,[int]$Seconds=20){Assert ($Child.Process.WaitForExit($Seconds*1000));[IO.File]::WriteAllText((Join-Path $Child.Directory ($Child.Id+'.private.out')),$Child.Output.GetAwaiter().GetResult());[IO.File]::WriteAllText((Join-Path $Child.Directory ($Child.Id+'.private.err')),$Child.Errors.GetAwaiter().GetResult());return $Child.Process.ExitCode}
try{
 # Early owned-handle handover controls. No service, job, installed state or
 # live maintenance path is used. A typed Timer needs no PowerShell runspace.
 Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Threading;
public sealed class OpenWebOwnedMaintenanceReader : IDisposable {
 readonly FileStream stream; readonly ManualResetEvent done=new ManualResetEvent(false);
 Timer timer; Exception failure;
 public OpenWebOwnedMaintenanceReader(string path){stream=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read);}
 public void ReleaseAfter(int milliseconds,string statePath,string stateText){
  if(timer!=null)throw new InvalidOperationException("The owned release is already scheduled.");
  timer=new Timer(delegate(object unused){
   try{if(!String.IsNullOrEmpty(statePath))File.WriteAllText(statePath,stateText,new UTF8Encoding(false));}
   catch(Exception error){failure=error;}
   finally{stream.Dispose();done.Set();}
  },null,milliseconds,Timeout.Infinite);
 }
 public bool Wait(){return done.WaitOne(5000);}
 public void Dispose(){
  if(timer!=null){using(var ended=new ManualResetEvent(false)){if(!timer.Dispose(ended)||!ended.WaitOne(5000))throw new TimeoutException("The owned release callback did not finish.");}}
  stream.Dispose();done.Dispose();
  if(failure!=null)throw new InvalidOperationException("The owned release callback failed.",failure);
 }
}
'@
 $handover=Join-Path $work 'owned-maintenance-handover';$null=[IO.Directory]::CreateDirectory($handover)
 $ownedLock=Join-Path $handover 'upgrade.lock';[IO.File]::WriteAllText($ownedLock,'EXACT_OWNED_LOCK')
 $installation=Join-Path $handover 'installation.json';[IO.File]::WriteAllText($installation,'{"Version":"1.0.21","Completed":true}',[Text.UTF8Encoding]::new($false))
 $tokens=$null;$parseErrors=$null;$upgradeAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'packaging/windows/Upgrade-OpenWebPBX.ps1'),[ref]$tokens,[ref]$parseErrors)
 Assert ($parseErrors.Count -eq 0)
 $guardNodes=@($upgradeAst.FindAll({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.StartsWith('if((Get-Content "$private\installation.json" -Raw) -cne $installationText)')},$true));Assert ($guardNodes.Count -eq 1)
 $stateGuard=[scriptblock]::Create($guardNodes[0].Extent.Text)
 $reader=[OpenWebOwnedMaintenanceReader]::new($ownedLock)
 try{
  $blocked=$false;try{$unexpected=[IO.File]::Open($ownedLock,'OpenOrCreate','ReadWrite','None');$unexpected.Dispose()}catch [IO.IOException]{$blocked=$_.Exception.GetBaseException().HResult -eq -2147024864};Assert $blocked
  $reader.ReleaseAfter(250,$null,$null);$clock=[Diagnostics.Stopwatch]::StartNew()
  $lease=Open-OpenWebUpgradeMaintenance -Path $ownedLock -WaitMilliseconds 2000
  try{Assert ($clock.ElapsedMilliseconds -ge 1 -and $clock.ElapsedMilliseconds -lt 5000 -and $reader.Wait());Assert-OpenWebRecoveryLock -MaintenanceLock $lease -StateRoot $handover;Assert ($lease.CanRead -and $lease.CanWrite)}finally{$lease.Dispose()}
 }finally{$reader.Dispose()}
 $reader=[OpenWebOwnedMaintenanceReader]::new($ownedLock)
 try{
  $clock=[Diagnostics.Stopwatch]::StartNew();$failure=$null
  try{$unexpected=Open-OpenWebUpgradeMaintenance -Path $ownedLock -WaitMilliseconds 100;$unexpected.Dispose()}catch [IO.IOException]{$failure=$_}
  Assert ($failure -and $failure.Exception.GetBaseException().HResult -eq -2147024864 -and $clock.ElapsedMilliseconds -ge 100 -and $clock.ElapsedMilliseconds -lt 5000)
 }finally{$reader.Dispose()}
 # The earlier shared reader models a previous operation changing the exact
 # installation text before releasing its handle; JSON-equivalent is changed.
 $private=$handover;$installationText=Get-Content $installation -Raw;$priorPassword=$env:PGPASSWORD
 $reader=[OpenWebOwnedMaintenanceReader]::new($ownedLock)
 try{
  $reader.ReleaseAfter(250,$installation,$installationText+"`n")
  $lease=Open-OpenWebUpgradeMaintenance -Path $ownedLock -WaitMilliseconds 2000
  try{
   $script:deferred=$false;$mutated=$false;$refused=$false
   try{. $stateGuard;$mutated=$true}catch{$refused=$true}
   Assert ($refused -and $script:deferred -and !$mutated -and $reader.Wait())
   Assert ($env:PGPASSWORD -ceq $priorPassword -and !(Test-Path (Join-Path $handover 'updates')))
  }finally{$lease.Dispose()}
 }finally{$reader.Dispose()}
 $lease=Open-OpenWebUpgradeMaintenance -Path $ownedLock -WaitMilliseconds 0
 try{$installationText=Get-Content $installation -Raw;$script:deferred=$false;. $stateGuard;Assert (!$script:deferred)}finally{$lease.Dispose()}
 Assert ([IO.File]::ReadAllText($ownedLock) -ceq 'EXACT_OWNED_LOCK')
 $after=[IO.File]::Open($ownedLock,'Open','ReadWrite','None');$after.Dispose();Assert $true
 foreach($kind in 'missing_updater','missing_helper','default','date'){
  $c=Case $kind;$before=[IO.File]::ReadAllBytes($c.Runtime);$acl=(Get-Acl -LiteralPath $c.Runtime).Sddl;$attributes=[int](Get-Item -LiteralPath $c.Runtime -Force).Attributes
  $lock=[IO.File]::Open((Join-Path $c.State 'upgrade.lock'),'OpenOrCreate','ReadWrite','None')
  try{
   $entry=NewEntry $c $lock;Assert ([IO.File]::ReadAllText($c.Runtime) -ceq [Text.Encoding]::UTF8.GetString($before));Refuses {Publish $c $entry $lock}
   Pin $c $entry;Publish $c $entry $lock
   $after=Get-Content -LiteralPath $c.Runtime -Raw|ConvertFrom-Json;Assert ($after.Updater.Helper -ceq (Join-Path $entry.bundle_path 'recovery-launcher.ps1'))
   if($kind -ceq 'date'){Assert ($after.Unrelated.ISO -is [string] -and $after.Unrelated.ISO -ceq '2026-10-22T01:02:03.000Z')}
   Assert ((Get-Acl -LiteralPath $c.Runtime).Sddl -ceq $acl -and [int](Get-Item -LiteralPath $c.Runtime -Force).Attributes -eq $attributes)
   $entryCall=Child (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$after.Updater.Helper,'-Recover') $c.Base
   Assert ((Finish $entryCall) -eq 75 -and [IO.File]::ReadAllText((Join-Path $c.State 'selected-entry.txt')) -ceq 'new')
   Complete $c $entry $lock Rollback
   Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($c.Runtime)) -ceq [Convert]::ToBase64String($before) -and (Get-Acl -LiteralPath $c.Runtime).Sddl -ceq $acl)
  }finally{$lock.Dispose()}
 }
 foreach($kind in 'foreign','invalid','empty','large_integer','fraction','deep'){
  $c=Case $kind;$before=Get-OpenWebRecoveryHash (Read-OpenWebRecoveryBytes $c.Runtime);$lock=[IO.File]::Open((Join-Path $c.State 'upgrade.lock'),'OpenOrCreate','ReadWrite','None')
  try{Refuses {NewEntry $c $lock};Assert ((Get-OpenWebRecoveryHash (Read-OpenWebRecoveryBytes $c.Runtime)) -ceq $before)}finally{$lock.Dispose()}
 }
 $c=Case;$lockPath=Join-Path $c.State 'upgrade.lock'
 foreach($sharing in [IO.FileShare]::ReadWrite,[IO.FileShare]::Read,[IO.FileShare]::Write){$shared=[IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite',$sharing);try{Refuses {NewEntry $c $shared}}finally{$shared.Dispose()}}
 $hardlink=Join-Path $c.Base 'foreign-lock-alias';$null=New-Item -ItemType HardLink -Path $hardlink -Target $lockPath
 $locked=[IO.File]::Open($lockPath,'Open','ReadWrite','None');try{Refuses {NewEntry $c $locked}}finally{$locked.Dispose();Remove-Item -LiteralPath $hardlink -Force}
 $lock=[IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite','None')
 try{
  $entry=NewEntry $c $lock;Pin $c $entry;Publish $c $entry $lock
  foreach($kind in 'dependency','launcher','metadata','journal','runtime','extra'){
   $path=switch($kind){'dependency'{Join-Path $entry.bundle_path 'Support-Recovery.ps1'} 'launcher'{Join-Path $entry.bundle_path 'recovery-launcher.ps1'} 'metadata'{Join-Path $entry.bundle_path 'entry.json'} 'journal'{$c.Journal} 'runtime'{$c.Runtime} 'extra'{Join-Path $entry.bundle_path 'foreign.ps1'}}
   $exists=Test-Path -LiteralPath $path;$saved=if($exists){[IO.File]::ReadAllBytes($path)}else{$null}
   if($kind -ceq 'journal'){$j=Get-Content $path -Raw|ConvertFrom-Json;$j.recovery_entry.metadata_sha256='0'*64;Json $path $j}else{[IO.File]::AppendAllText($path,"`n#CHANGED")}
   Refuses {Get-OpenWebUpgradeRecoveryMetadata -Entry $entry -Root $c.Root -StateRoot $c.State -EngineRoot $c.Engine -RequirePublished}
   if($kind -ceq 'launcher'){
    $call=Child (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$path,'-Recover') $c.Base
    Assert ((Finish $call) -eq 2 -and !(Test-Path -LiteralPath (Join-Path $c.State 'selected-entry.txt')))
   }
   if($exists){[IO.File]::WriteAllBytes($path,$saved)}else{[IO.File]::Delete($path)}
  }
  Refuses {Complete $c $entry $lock Success}
  foreach($name in 'Upgrade-OpenWebPBX.ps1','UpgradeRecovery.Common.ps1','Restore-Gates.ps1','Support-Recovery.ps1','File-Security.ps1','Web-Readiness.ps1','Dtls.Common.ps1','PhoneHealth-Security.ps1','PhpRuntime.Common.ps1','Write-PrivateState.ps1','check-call-engine.php','windows-log.php','CallRecords.Common.ps1'){[IO.File]::Copy((Join-Path $entry.bundle_path $name),(Join-Path $c.Root ('tools\'+$name)),$true)}
  foreach($name in 'Upgrade-OpenWebPBX.ps1','UpgradeRecovery.Common.ps1','Restore-Gates.ps1','Support-Recovery.ps1','File-Security.ps1','Web-Readiness.ps1','Dtls.Common.ps1','PhoneHealth-Security.ps1','PhpRuntime.Common.ps1','Write-PrivateState.ps1','check-call-engine.php','windows-log.php','CallRecords.Common.ps1'){
   $path=Join-Path $c.Root ('tools\'+$name);$saved=[IO.File]::ReadAllBytes($path);[IO.File]::Delete($path)
   Refuses {Complete $c $entry $lock Success};[IO.File]::WriteAllBytes($path,$saved)
  }
  $before=Read-OpenWebRecoveryBytes (Join-Path $entry.bundle_path 'runtime.before.json');Complete $c $entry $lock Success
  Assert ([Convert]::ToBase64String([IO.File]::ReadAllBytes($c.Runtime)) -ceq [Convert]::ToBase64String($before))
  # A second interruption after the final configuration reset but before the
  # terminal journal must re-publish the safe entry before repeating rollback.
  Ensure-OpenWebUpgradeRecoveryPublished -Entry $entry -Root $c.Root -StateRoot $c.State -EngineRoot $c.Engine -MaintenanceLock $lock
  Assert ((Get-Content -LiteralPath $c.Runtime -Raw|ConvertFrom-Json).Updater.Helper -ceq (Join-Path $entry.bundle_path 'recovery-launcher.ps1'))
 }finally{$lock.Dispose()}
 # Real process interruption: first kill with a complete unpublished bundle,
 # then kill immediately after the atomic configuration handoff. Native PBX
 # services are never involved; the optional unchanged .NET worker loads only
 # this complete fictional configuration and fails against closed TCP port1.
 foreach($position in 'copying','before','after'){
  $c=if($position -ceq 'copying'){Case 'partial'}else{Case};$input=Join-Path $c.Base 'input.json';Json $input $c;$ready=Join-Path $c.Base 'ready.json';$scriptPath=Join-Path $c.Base 'interrupt.ps1'
  $body=@'
param([string]$Source,[string]$InputFile,[string]$Position)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
. (Join-Path $Source 'packaging\windows\UpgradeRecovery.Common.ps1')
. (Join-Path $Source 'packaging\windows\File-Security.ps1')
$c=Get-Content -LiteralPath $InputFile -Raw|ConvertFrom-Json
$lock=[IO.File]::Open((Join-Path $c.State 'upgrade.lock'),'OpenOrCreate','ReadWrite','None')
$entry=New-OpenWebUpgradeRecovery -PackageRoot $c.Package -Root $c.Root -StateRoot $c.State -EngineRoot $c.Engine -Backup $c.Backup -MaintenanceLock $lock
$j=Get-Content -LiteralPath $c.Journal -Raw|ConvertFrom-Json;$j.state='deploying';$j|Add-Member NoteProperty recovery_entry $entry
[IO.File]::WriteAllText($c.Journal,($j|ConvertTo-Json -Depth 12))
if($Position -ceq 'after'){Publish-OpenWebUpgradeRecovery -Entry $entry -Root $c.Root -StateRoot $c.State -EngineRoot $c.Engine -MaintenanceLock $lock}
[IO.File]::WriteAllText((Join-Path $c.Base 'ready.json'),($entry|ConvertTo-Json -Depth 8))
while($true){Start-Sleep -Milliseconds 100}
'@
  WriteText $scriptPath $body;$child=Child (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$scriptPath,'-Source',$SourceRoot,'-InputFile',$input,'-Position',$position) $c.Base
  $deadline=[DateTime]::UtcNow.AddSeconds(45);while($position -cne 'copying' -and !(Test-Path -LiteralPath $ready) -and !$child.Process.HasExited -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 100}
  if($position -ceq 'copying'){
   # The child may not finish copying/pinning the dependency set. Detect a real
   # incomplete private bundle; no runtime-only test pause exists in product.
   $partialObserved=$false;$deadline=[DateTime]::UtcNow.AddSeconds(45)
   while(!$child.Process.HasExited -and [DateTime]::UtcNow -lt $deadline){
    $parent=Join-Path $c.State 'updates\recovery-entry'
    if(Test-Path -LiteralPath $parent){foreach($folder in @(Get-ChildItem -LiteralPath $parent -Directory)){if(@(Get-ChildItem -LiteralPath $folder.FullName -File).Count -gt 0 -and !(Test-Path -LiteralPath (Join-Path $folder.FullName 'entry.json'))){$partialObserved=$true;break}}}
    if($partialObserved){break};Start-Sleep -Milliseconds 5
   }
   Assert ($partialObserved -and !$child.Process.HasExited -and !(Test-Path -LiteralPath $ready))
  }else{Assert ((Test-Path -LiteralPath $ready) -and !$child.Process.HasExited)}
  $child.Process.Kill();Assert ($child.Process.WaitForExit(10000));$null=Finish $child
  $r=Get-Content -LiteralPath $c.Runtime -Raw|ConvertFrom-Json;$expected=if($position -cin 'copying','before'){'old'}else{'new'}
  # Never allow an omitted fixture override to select any installed path.
  Assert ($r.Updater.Helper -is [string] -and $r.Updater.Helper.StartsWith($c.Base+'\',[StringComparison]::OrdinalIgnoreCase))
  Assert ($r.Updater.DataDirectory -ceq (Join-Path $c.State 'updates') -and $r.Updater.PublicStatus -ceq (Join-Path $c.State 'public-status.json') -and $r.Updater.InstalledVersionPath -ceq (Join-Path $c.State 'installation.json'))
  Assert ($r.ConnectionStrings.Pbx -ceq 'Host=127.0.0.1;Port=1;Database=fictional;Username=fictional;Password=fictional-only;Timeout=1;Command Timeout=1;Pooling=false')
  $call=Child (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$r.Updater.Helper,'-Recover') $c.Base;Assert ((Finish $call) -eq 75)
  Assert ([IO.File]::ReadAllText((Join-Path $c.State 'selected-entry.txt')) -ceq $expected)
  if($UpdaterDirectory){
   # Independent complete TCP table proof, no SYN timeout inference.
   Assert (@(Get-NetTCPConnection -State Listen -ErrorAction Stop|Where-Object LocalPort -eq 1).Count -eq 0)
   $exe=Join-Path $UpdaterDirectory 'OpenWebPbx.Updater.exe';Assert (Test-Path -LiteralPath $exe -PathType Leaf)
   [IO.File]::Delete((Join-Path $c.State 'selected-entry.txt'))
   $managed=Child $exe @('--run-once') $c.Base @{OPENWEBPBX_CONFIG=$c.Runtime};$null=Finish $managed 30
   Assert ([IO.File]::ReadAllText((Join-Path $c.State 'selected-entry.txt')) -ceq $expected)
  }
 }
 Write-Output ('PASS '+$checks+' actual native private recovery bundle/config/ACL/lock/tamper, original choice, complete dependency and before/after handoff interruption controls; actual configured .NET boot=' + [bool]$UpdaterDirectory+'; updater version='+$ExpectedUpdaterVersion)
}finally{
 foreach($p in $children){try{if(!$p.HasExited){$p.Kill();$null=$p.WaitForExit(10000)}}finally{$p.Dispose()}}
 Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction Stop
}
