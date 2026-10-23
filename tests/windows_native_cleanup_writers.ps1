# Actual QA lifecycle functions; service/Scheduler/CIM adapters only, no PBX mutated.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$checks=0
. (Join-Path $PSScriptRoot 'windows-native-cleanup-row-fields.ps1')
. (Join-Path $PSScriptRoot 'windows-native-cleanup-writers.ps1')
function Check([bool]$Value){if(!$Value){throw ('Native cleanup writer control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
$owned=Join-Path ([IO.Path]::GetTempPath()) ('openweb-cleanup-controls-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory $owned|Out-Null
if(!(Get-PSDrive C -ErrorAction SilentlyContinue)){New-PSDrive -Name C -PSProvider FileSystem -Root $owned|Out-Null;$removeDrive=$true}
$root='C:\OpenWebPBX';$state='C:\ProgramData\OpenWebPBX';$PackageRoot=$owned
function Get-Item {param($LiteralPath,[switch]$Force,$ErrorAction) return [pscustomobject]@{PSIsContainer=$false;Attributes=0;Directory=$null}}
function Get-FileHash {param($LiteralPath,$Algorithm) return @{Hash=$(if($script:wrongHash -and $LiteralPath -like '*call_records.php' -and $LiteralPath -notlike ($PackageRoot+'*')){'WRONG'}else{'EXACT'})}}
function Get-CimInstance {param($ClassName,$Filter,$ErrorAction)
 if($ClassName -ceq 'Win32_Service'){return [pscustomobject]$script:svc}
 if($Filter -ceq "Name='OpenWebPbx.Server.exe'"){if($script:svc.State -ceq 'Running' -or $script:orphanBackend){return [pscustomobject]@{ExecutablePath=$script:svc.PathName.Trim('"');ProcessId=42}};return @()}
 if($script:foreignWriter){return [pscustomobject]@{ExecutablePath=$root+'\php\php.exe';CommandLine='"'+$root+'\php\php.exe" "'+$root+'\web\app\pbx_setup\call_records.php"'}}
 return @()
}
function Invoke-CimMethod {param($InputObject,$MethodName,$ErrorAction) return @{ReturnValue=0;Sid=$(if($script:foreignWriter){'S-1-5-21-999'}else{'S-1-5-19'})}}
function Get-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction)
 if($script:stopPending){$script:stopReads++;if($script:stopReads -ge 3){$script:task.State='Disabled';$script:stopPending=$false}}
 return [pscustomobject]$script:task
}
function Export-ScheduledTask {param($TaskName,$TaskPath) return ('EXACT-XML-ENABLED-'+$script:task.Settings.Enabled)}
function Disable-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction) $script:events.Add('disable');$script:task.Settings.Enabled=$false;if($script:task.State -cne 'Running'){$script:task.State='Disabled'}}
function Enable-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction) $script:events.Add('enable');$script:task.Settings.Enabled=$true;if($script:task.State -cne 'Running'){$script:task.State='Ready'}}
function Stop-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction) $script:events.Add('stop-task');$script:stopPending=$true;$script:stopReads=0}
function Start-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction) $script:events.Add('start-task');$script:task.State='Running'}
function Get-Service {param($Name,$ErrorAction)
 $s=[pscustomobject]@{};$s|Add-Member ScriptMethod Stop {$script:events.Add('stop-service');$script:svc.State='Stopped';$script:svc.ProcessId=0};$s|Add-Member ScriptMethod Start {$script:events.Add('start-service');$script:svc.State='Running';$script:svc.ProcessId=42};$s|Add-Member ScriptMethod WaitForStatus {param($Status,$Timeout) if($script:svc.State -cne $Status){throw 'Adapter state mismatch'}};return $s
}
function Reset([bool]$Running=$true,[bool]$Enabled=$true,[bool]$TaskRunning=$false){
 $script:events=[Collections.Generic.List[string]]::new();$script:wrongHash=$false;$script:foreignWriter=$false;$script:orphanBackend=$false;$script:stopPending=$false
 $script:svc=@{Name='OpenWebPBX';PathName='"'+(Join-Path $root 'server\OpenWebPbx.Server.exe')+'"';StartName='NT AUTHORITY\LocalService';StartMode='Manual';State=$(if($Running){'Running'}else{'Stopped'});ProcessId=$(if($Running){42}else{0})}
 $script:task=@{TaskName='OpenWebPBX-Cleanup';TaskPath='\';Principal=@{UserId='SYSTEM';RunLevel='Highest'};Actions=@(@{Execute=$root+'\php\php.exe';Arguments='"'+$root+'\web\app\pbx_setup\cleanup.php"';WorkingDirectory=$root+'\web'});Settings=@{Enabled=$Enabled};State=$(if($TaskRunning){'Running'}elseif($Enabled){'Ready'}else{'Disabled'})}
}
function Refuses([scriptblock]$Action){$failed=$false;try{& $Action}catch{$failed=$true};Check $failed}
try{
 foreach($running in $false,$true){foreach($enabled in $false,$true){
  Reset $running $enabled;$initial=Get-NativeCleanupWriterState;$original=$null
  Suspend-NativeCleanupWriters ([ref]$original)
  Check (!$script:task.Settings.Enabled -and $script:svc.State -ceq 'Stopped')
  Check ($original.Running -eq $running -and $original.TaskEnabled -eq $enabled)
  Resume-NativeCleanupWriters $original
  $final=Get-NativeCleanupWriterState
  Check ($final.Running -eq $running -and $final.TaskEnabled -eq $enabled -and $final.StartMode -ceq $initial.StartMode -and $final.TaskXml -ceq $initial.TaskXml)
  Check (($events -contains 'stop-service') -eq $running)
 }}
 Reset $true $true $true;$original=$null;Suspend-NativeCleanupWriters ([ref]$original)
 Check ($script:stopReads -ge 3 -and $events.Contains('stop-task'))
 Resume-NativeCleanupWriters $original;Check ($events.Contains('start-task') -and $task.Settings.Enabled)
 foreach($change in @({$script:svc.PathName='C:\foreign.exe'},{$script:svc.StartName='LocalSystem'},{$script:svc.StartMode='Disabled'},{$script:task.Actions[0].Arguments='FOREIGN'},{$script:task.Principal.UserId='FOREIGN'},{$script:task.TaskPath='\FOREIGN\'},{$script:wrongHash=$true})){
  Reset;& $change;Refuses {Get-NativeCleanupWriterState|Out-Null};Check ($events.Count -eq 0)
 }
 Reset $true $false $true;Refuses {Get-NativeCleanupWriterState|Out-Null};Check ((Get-NativeCleanupWriterState -Quiescing).TaskRunning)
 Reset;$script:foreignWriter=$true;Refuses {Get-NativeCleanupPhpWriters|Out-Null}
 Reset $false;$script:orphanBackend=$true;Refuses {Get-NativeCleanupWriterState|Out-Null};Check ($events.Count -eq 0)
 # Execute the real lifecycle wrapper with action adapters to prove ordering,
 # lock retention, exact zero-gate propagation and finally restoration.
 function Open-NativeCleanupMaintenance {$script:events.Add('lock');$lock=[pscustomobject]@{};$lock|Add-Member ScriptMethod Dispose {$script:events.Add('unlock')};return $lock}
 function Invoke-NativeCleanupPhp {param($Name)
  $script:events.Add($Name)
  if($Name -ceq 'windows-native-cleanup-drain.php'){
   if($script:drainFailure){throw 'Owned drain refusal'}
   return [pscustomobject]@{schema=1;state='passed';pre_owned=[bool]$script:preOwned;actual_importer=(!$script:preOwned);foreign_records_imported=$false;owned_channels_ended=0;imported=0;spool_empty_stable_ms=$(if($script:preOwned){0}else{3000})}
  }
  return [pscustomobject]@{schema=1;state='observed';read_only=$true;all_tables_queried=$true;tables_checked=6;leftover_tables=1;leftover_rows=2;counts_capped=$false;categories=@{cdr=0;history=2;health=0;queue=0;jobs=0;mail=0;callback=0;domain=0;other=0}}
 }
 function Php {param($Action) $script:events.Add('delete-and-strict-zero');if($script:deleteFailure){throw 'Owned strict zero refused'};return '{"factory_empty":true,"owned_rows":0}'}
 foreach($drainFailed in $false,$true){foreach($deleteFailed in $false,$true){
  Reset;$script:drainFailure=$drainFailed;$script:deleteFailure=$deleteFailed;$facts=@{}
  $failed=$false;try{$result=Invoke-NativeFactoryCleanup}catch{$failed=$true}
  Check ($failed -eq ($drainFailed -or $deleteFailed))
  Check ($events[0] -ceq 'lock' -and $events[$events.Count-1] -ceq 'unlock')
  Check ($svc.State -ceq 'Running' -and $task.Settings.Enabled)
  Check (($events -contains 'delete-and-strict-zero') -eq !$drainFailed)
  if($failed){Check ($facts.native_cleanup_rows.categories.history -eq 2)}
 }}
 Reset;$script:drainFailure=$false;$script:deleteFailure=$false;$script:preOwned=$true;$facts=@{};[void](Invoke-NativeFactoryCleanup)
 Check ($events.Contains('delete-and-strict-zero') -and $facts.native_cleanup_writers_restored -and $svc.State -ceq 'Running')
 $script:preOwned=$false
 # Closed report schema/type/privacy failures, no raw source names or IDs.
 $row=Invoke-NativeCleanupPhp 'windows-native-cleanup-rows.php';$row|Add-Member NoteProperty password 'PRIVATE';$safe=Get-NativeCleanupRowFields $row
 Check ($safe.categories.history -eq 2 -and ($safe|ConvertTo-Json -Depth 8) -cnotmatch 'PRIVATE|password')
 foreach($field in 'schema','tables_checked','leftover_tables','leftover_rows','read_only','all_tables_queried','counts_capped'){
  $copy=$row|ConvertTo-Json -Depth 8|ConvertFrom-Json;$copy.$field='1';Check ((Get-NativeCleanupRowFields $copy).Count -eq 0)
 }
 foreach($category in 'cdr','history','health','queue','jobs','mail','callback','domain','other'){
  $copy=$row|ConvertTo-Json -Depth 8|ConvertFrom-Json;$copy.categories.$category='0';Check ((Get-NativeCleanupRowFields $copy).Count -eq 0)
 }
 $copy=$row|ConvertTo-Json -Depth 8|ConvertFrom-Json;$copy.categories|Add-Member NoteProperty PRIVATE 0;Check ((Get-NativeCleanupRowFields $copy).Count -eq 0)
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-suite.ps1'),[ref]$tokens,[ref]$errors)
 Check ($errors.Count -eq 0)
 $node=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'SafeNativeCleanupFields'},$true));Check ($node.Count -eq 1);Invoke-Expression $node[0].Extent.Text
 $record=[pscustomobject]@{native_cleanup_stage='restore_factory';native_cleanup_rows=$row;native_cleanup_writers_restored=$false;password='PRIVATE'}
 $safe=SafeNativeCleanupFields $record;Check ($safe.native_cleanup_rows.categories.history -eq 2 -and !$safe.native_cleanup_writers_restored -and ($safe|ConvertTo-Json -Depth 8) -cnotmatch 'PRIVATE|password')
 $record.native_cleanup_rows.categories.history='2';Check (!(SafeNativeCleanupFields $record).ContainsKey('native_cleanup_rows'))
 Write-Output ('PASS '+$checks+' actual-source cleanup writer lifecycle/async-stop/ownership/strict-zero/report privacy controls; service/Scheduler adapters only')
}finally{if($removeDrive){Remove-PSDrive C};Microsoft.PowerShell.Management\Remove-Item -LiteralPath $owned -Recurse -Force}
