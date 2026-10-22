# Execute the actual QA-only task ownership/quiescence functions with controlled
# Task Scheduler/CIM bindings and real temporary helper/spool files.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$script:checks=0
function Check([bool]$Value){if(!$Value){throw ('Health quiescence control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
$helper=Join-Path $SourceRoot 'tests/windows-upgrade-health-quiescence.ps1';$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($helper,[ref]$tokens,[ref]$errors);Check ($errors.Count -eq 0)
. $helper
function Hash([string]$Path){return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Get-ScheduledTask {[CmdletBinding()]param([string]$TaskName);Check ($TaskName -ceq 'OpenWebPBX-PhoneHealth');return $script:task}
function Disable-ScheduledTask([string]$TaskName){Check ($TaskName -ceq 'OpenWebPBX-PhoneHealth');$script:actions.Add('disable');$script:task.Settings.Enabled=$false;if($script:task.State -cne 'Running'){$script:task.State='Disabled'}}
function Enable-ScheduledTask([string]$TaskName){Check ($TaskName -ceq 'OpenWebPBX-PhoneHealth');$script:actions.Add('enable');$script:task.Settings.Enabled=$true;if($script:task.State -cne 'Running'){$script:task.State='Ready'}}
function Stop-ScheduledTask {[CmdletBinding()]param([string]$TaskName);Check ($TaskName -ceq 'OpenWebPBX-PhoneHealth');$script:actions.Add('stop');if(!$script:stalled){$script:task.State='Disabled';$script:processes=@()}}
function Start-ScheduledTask([string]$TaskName){Check ($TaskName -ceq 'OpenWebPBX-PhoneHealth' -and $script:task.Settings.Enabled);$script:actions.Add('start');$script:task.State='Running'}
function Get-CimInstance([string]$ClassName,[string]$Filter){Check ($ClassName -ceq 'Win32_Process' -and $Filter -ceq "Name='php.exe' OR Name='powershell.exe'");return $script:processes}
function Invoke-CimMethod($InputObject,[string]$MethodName){Check ($MethodName -ceq 'GetOwnerSid');return [pscustomobject]@{ReturnValue=$InputObject.OwnerResult;Sid=$InputObject.OwnerSid}}
function Start-Sleep([int]$Milliseconds){Check ($Milliseconds -eq 250);$script:sleeps++}
function Reset([bool]$Enabled=$true,[string]$State='Ready') {
 $script:task=[pscustomobject]@{
  TaskName='OpenWebPBX-PhoneHealth';TaskPath='\';Description='OpenWeb PBX owned phone health and Windows security observer'
  Principal=[pscustomobject]@{UserId='SYSTEM';RunLevel='Highest';LogonType='ServiceAccount'}
  Actions=@([pscustomobject]@{Execute=$env:SystemRoot+'\System32\WindowsPowerShell\v1.0\powershell.exe';Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$root+'\tools\Phone-Health.ps1"';WorkingDirectory=$root+'\tools'})
  Settings=[pscustomobject]@{MultipleInstances='IgnoreNew';Enabled=$Enabled};State=$State
 }
 $script:actions=[Collections.Generic.List[string]]::new();$script:processes=@();$script:stalled=$false;$script:sleeps=0
}
function Refuses($Action,[string]$Expected){$caught=$null;try{& $Action}catch{$caught=$_.Exception.Message};Check ($null -ne $caught -and $caught.Contains($Expected))}
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('openweb-health-quiescence-'+[Guid]::NewGuid().ToString('N'));$oldSystemRoot=$env:SystemRoot
try {
 $root=Join-Path $temporary 'root';$state=Join-Path $temporary 'state';$PackageRoot=Join-Path $temporary 'package';$env:SystemRoot='C:\Windows'
 foreach($dir in (Join-Path $root 'tools'),$state,$PackageRoot){$null=[IO.Directory]::CreateDirectory($dir)}
 foreach($name in 'Phone-Health.ps1','PhoneHealth-Security.ps1'){foreach($base in (Join-Path $root 'tools'),$PackageRoot){[IO.File]::WriteAllText((Join-Path $base $name),'OWNED_HELPER_'+$name)}}
 foreach($choice in @(@{enabled=$true;state='Ready';actions='disable,enable'},@{enabled=$false;state='Disabled';actions='disable,disable'},@{enabled=$true;state='Running';actions='disable,stop,enable,start'},@{enabled=$false;state='Running';actions='disable,stop,disable'})){
  Reset $choice.enabled $choice.state;$original=$null
  Suspend-OpenWebQualificationHealth ([ref]$original)
  Check ($original.Exists -and $original.Enabled -ceq $choice.enabled -and $original.Running -ceq ($choice.state -ceq 'Running'))
  Check (!$script:task.Settings.Enabled -and $script:task.State -cne 'Running')
  Resume-OpenWebQualificationHealth $original
  Check ($script:task.Settings.Enabled -ceq $choice.enabled -and ($script:actions -join ',') -ceq $choice.actions)
 }
 Reset;$script:task=$null;$original=$null;Suspend-OpenWebQualificationHealth ([ref]$original);Resume-OpenWebQualificationHealth $original
 Check (!$original.Exists -and $script:actions.Count -eq 0)
 foreach($change in 'taskname','taskpath','description','principal','runlevel','logon','execute','arguments','workingdir','multiple','enabledtype','state','extraaction'){
  Reset
  switch($change){
   'taskname'{$task.TaskName='FOREIGN'} 'taskpath'{$task.TaskPath='\FOREIGN\'} 'description'{$task.Description='FOREIGN'} 'principal'{$task.Principal.UserId='S-1-5-21-123'} 'runlevel'{$task.Principal.RunLevel='Limited'}
   'logon'{$task.Principal.LogonType='Interactive'} 'execute'{$task.Actions[0].Execute='FOREIGN'} 'arguments'{$task.Actions[0].Arguments+=' -Foreign'}
   'workingdir'{$task.Actions[0].WorkingDirectory='FOREIGN'} 'multiple'{$task.Settings.MultipleInstances='Parallel'}
   'enabledtype'{$task.Settings.Enabled='false'} 'state'{$task.State='Queued'} 'extraaction'{$task.Actions+=@($task.Actions[0])}
  }
  $original=$null;Refuses {Suspend-OpenWebQualificationHealth ([ref]$original)} 'foreign or changed'
  Check ($script:actions.Count -eq 0 -and $null -eq $original)
 }
 Reset;$task.Principal.RunLevel=1;$task.Principal.LogonType=5;$task.Principal.UserId='S-1-5-18';$original=$null;Suspend-OpenWebQualificationHealth ([ref]$original);Resume-OpenWebQualificationHealth $original;Check $task.Settings.Enabled
 $installed=Join-Path (Join-Path $root 'tools') 'Phone-Health.ps1';$originalBytes=[IO.File]::ReadAllBytes($installed);[IO.File]::WriteAllText($installed,'CHANGED')
 Reset;$original=$null;Refuses {Suspend-OpenWebQualificationHealth ([ref]$original)} 'differs from';Check ($script:actions.Count -eq 0 -and $null -eq $original);[IO.File]::WriteAllBytes($installed,$originalBytes)
 Reset;$foreign=[pscustomobject]@{ExecutablePath='C:\Other\php.exe';CommandLine='php.exe other.php';OwnerSid='FOREIGN';OwnerResult=0};$processes=@($foreign);Check ((Get-OpenWebQualificationHealthProcesses) -eq 0)
 foreach($kind in 'php','ps'){
  Reset;$nativeRoot=$root.Replace('/','\');$exe=if($kind -ceq 'php'){$nativeRoot+'\php\php.exe'}else{$env:SystemRoot+'\System32\WindowsPowerShell\v1.0\powershell.exe'}
  $cmd=if($kind -ceq 'php'){$nativeRoot+'\tools\phone-health.php'}else{$nativeRoot+'\tools\Phone-Health.ps1'}
  $processes=@([pscustomobject]@{ExecutablePath=$exe;CommandLine=$cmd;OwnerSid='S-1-5-18';OwnerResult=0});Check ((Get-OpenWebQualificationHealthProcesses) -eq 1)
  $processes[0].OwnerSid='FOREIGN';$original=$null;Refuses {Suspend-OpenWebQualificationHealth ([ref]$original)} 'unexpected observer identity';Check ($actions.Count -eq 0 -and $null -eq $original)
  $processes[0].OwnerSid='S-1-5-18';$processes[0].OwnerResult=1;Refuses {Get-OpenWebQualificationHealthProcesses} 'unexpected observer identity'
 }
 Reset $true 'Running';$script:stalled=$true;$original=$null;Refuses {Suspend-OpenWebQualificationHealth ([ref]$original)} 'did not quiesce'
 Check ($script:sleeps -eq 80 -and $original.Exists -and $original.Enabled -and $original.Running -and ($actions -join ',') -ceq 'disable,stop')
 $script:stalled=$false;$task.State='Disabled';Resume-OpenWebQualificationHealth $original;Check (($actions -join ',') -ceq 'disable,stop,enable,start')
 $spool=Join-Path $state 'phone-health-runtime';$null=[IO.Directory]::CreateDirectory($spool);$request=Join-Path $spool 'pending.json';[IO.File]::WriteAllText($request,'PENDING')
 Reset;$original=$null;Refuses {Suspend-OpenWebQualificationHealth ([ref]$original)} 'pending runtime files'
 Check ([IO.File]::ReadAllText($request) -ceq 'PENDING' -and $original.Enabled -and !$task.Settings.Enabled);Resume-OpenWebQualificationHealth $original;Check $task.Settings.Enabled
 [IO.File]::Delete($request);Reset;$original=$null;Suspend-OpenWebQualificationHealth ([ref]$original);Check (!$task.Settings.Enabled);Resume-OpenWebQualificationHealth $original
 Reset;$original=@{Exists=$true;Enabled=$true;Running=$true};$processes=@([pscustomobject]@{ExecutablePath=$root.Replace('/','\')+'\php\php.exe';CommandLine=$root.Replace('/','\')+'\tools\phone-health.php';OwnerSid='S-1-5-18';OwnerResult=0})
 Refuses {Resume-OpenWebQualificationHealth $original} 'unexpected remaining';Check (($actions -join ',') -ceq 'enable')
 # Without the new pre-baseline stop, real heartbeat/request changes would be
 # an inequality. They are not silently normalized or removed by the guard.
 $before=@{checked_at='FIRST';request='FIRST'};$after=@{checked_at='SECOND';request='SECOND'};Check (($before|ConvertTo-Json -Compress) -cne ($after|ConvertTo-Json -Compress))
 $source=[IO.File]::ReadAllText((Join-Path $SourceRoot 'tests/windows-upgrade-acceptance.ps1'));$main=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors);Check ($errors.Count -eq 0)
 $commands=@($main.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst]},$true));$suspend=@($commands|Where-Object {$_.GetCommandName() -ceq 'Suspend-OpenWebQualificationHealth'});$resume=@($commands|Where-Object {$_.GetCommandName() -ceq 'Resume-OpenWebQualificationHealth'})
 Check ($suspend.Count -eq 1 -and $resume.Count -eq 1)
 $signed=@($commands|Where-Object {$_.GetCommandName() -ceq 'SignedChecks'});$baseline=@($commands|Where-Object {$_.GetCommandName() -ceq 'FilesSnapshot' -and $_.Extent.StartOffset -gt $suspend[0].Extent.EndOffset})
 Check ($signed.Count -eq 1 -and $suspend[0].Extent.EndOffset -lt $signed[0].Extent.StartOffset -and $baseline.Count -gt 0)
 $finally=$main.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]}|Select-Object -Last 1
 Check ($null -ne $finally.Finally -and $resume[0].Extent.StartOffset -gt $finally.Finally.Extent.StartOffset)
 Check ($source.Contains('Equal $files (FilesSnapshot)') -and $source.Contains("DatabaseSnapshot 'before-failure'"))
 Write-Output ('PASS '+$checks+' actual owned-health quiescence, foreign/type/hash/spool/identity/timeout refusals, original choice and strict-baseline order controls; native scheduling remains separate')
}finally{$env:SystemRoot=$oldSystemRoot;Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue}
