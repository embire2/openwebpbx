# QA only: make deletion deterministic without excluding any owned table.
function Assert-NativeCleanupOrdinary([string]$Path){
 $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
 if($item.PSIsContainer){throw 'An ordinary cleanup helper is required.'}
 for($node=$item;$node;$node=if($node.PSIsContainer){$node.Parent}else{$node.Directory}){if($node.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Redirected cleanup paths are refused.'}}
 return $item
}
function Get-NativeCleanupWriterState([switch]$Quiescing) {
 $exe=Join-Path $root 'server\OpenWebPbx.Server.exe'
 foreach($name in 'OpenWebPbx.Server.exe','OpenWebPbx.Server.dll'){
  $a=Join-Path $root ('server\'+$name);$b=Join-Path $PackageRoot ('server\'+$name);$null=Assert-NativeCleanupOrdinary $a;$null=Assert-NativeCleanupOrdinary $b
  if((Get-FileHash -LiteralPath $a -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $b -Algorithm SHA256).Hash){throw 'The backend differs from the candidate.'}
 }
 $svc=@(Get-CimInstance Win32_Service -Filter "Name='OpenWebPBX'" -ErrorAction Stop)
 if($svc.Count -ne 1 -or $svc[0].Name -cne 'OpenWebPBX' -or ([string]$svc[0].PathName).Trim('"') -ine $exe -or $svc[0].StartName -cnotin 'NT AUTHORITY\LocalService','LocalService' -or $svc[0].StartMode -cnotin 'Auto','Manual','Disabled' -or $svc[0].State -cnotin 'Running','Stopped'){throw 'An exact owned backend is required.'}
 $svc=$svc[0]
 if($svc.State -ceq 'Running' -and $svc.StartMode -ceq 'Disabled'){throw 'A running disabled backend cannot preserve its original choice.'}
 $processes=@(Get-CimInstance Win32_Process -Filter "Name='OpenWebPbx.Server.exe'" -ErrorAction Stop|Where-Object {$_.ExecutablePath -ieq $exe})
 foreach($p in $processes){$sid=Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction Stop;if($sid.ReturnValue -ne 0 -or $sid.Sid -cne 'S-1-5-19'){throw 'The owned backend identity changed.'}}
 if(($svc.State -ceq 'Running' -and ($processes.Count -ne 1 -or $processes[0].ProcessId -ne $svc.ProcessId)) -or ($svc.State -ceq 'Stopped' -and ($svc.ProcessId -ne 0 -or $processes.Count -ne 0))){throw 'The exact backend process did not match its service state.'}
 $task=Get-ScheduledTask -TaskName 'OpenWebPBX-Cleanup' -TaskPath '\' -ErrorAction Stop
 if(@($task).Count -ne 1 -or $task.TaskPath -cne '\' -or $task.TaskName -cne 'OpenWebPBX-Cleanup' -or $task.Principal.UserId -cnotin 'SYSTEM','S-1-5-18' -or [string]$task.Principal.RunLevel -cnotin 'Highest','1' -or @($task.Actions).Count -ne 1 -or $task.Actions[0].Execute -ine ($root+'\php\php.exe') -or $task.Actions[0].Arguments -cne ('"'+$root+'\web\app\pbx_setup\cleanup.php"') -or $task.Actions[0].WorkingDirectory -ine ($root+'\web') -or $task.Settings.Enabled -isnot [bool] -or [string]$task.State -cnotin 'Running','Ready','Disabled'){throw 'The cleanup task belongs to another configuration.'}
 if(!$Quiescing -and [string]$task.State -ceq 'Running' -and !$task.Settings.Enabled){throw 'A running disabled cleanup task cannot preserve its original choice.'}
 foreach($name in 'call_records.php','cleanup.php'){
  $a=Join-Path $root ('web\app\pbx_setup\'+$name);$b=Join-Path $PackageRoot ('web\app\pbx_setup\'+$name);$null=Assert-NativeCleanupOrdinary $a;$null=Assert-NativeCleanupOrdinary $b
  if((Get-FileHash -LiteralPath $a -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $b -Algorithm SHA256).Hash){throw 'A native writer differs from the candidate.'}
 }
 return @{Running=($svc.State -ceq 'Running');StartMode=$svc.StartMode;TaskEnabled=$task.Settings.Enabled;TaskRunning=([string]$task.State -ceq 'Running');TaskXml=(Export-ScheduledTask -TaskName 'OpenWebPBX-Cleanup' -TaskPath '\')}
}
function Get-NativeCleanupPhpWriters {
 $count=0
 foreach($p in Get-CimInstance Win32_Process -Filter "Name='php.exe'" -ErrorAction Stop){
  if($p.ExecutablePath -ine ($root+'\php\php.exe')){continue}
  foreach($name in 'call_records.php','cleanup.php'){
   if(([string]$p.CommandLine).Replace('/','\').IndexOf(($root+'\web\app\pbx_setup\'+$name),[StringComparison]::OrdinalIgnoreCase) -ge 0){
    $owner=Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction Stop
    if($owner.ReturnValue -ne 0 -or $owner.Sid -cnotin 'S-1-5-18','S-1-5-19'){throw 'An unexpected writer identity prevents cleanup.'};$count++;break
   }
  }
 };return $count
}
function Suspend-NativeCleanupWriters([ref]$Original){
 $originalState=Get-NativeCleanupWriterState;$Original.Value=$originalState
 Disable-ScheduledTask -TaskName 'OpenWebPBX-Cleanup' -TaskPath '\' -ErrorAction Stop|Out-Null
 if($originalState.TaskRunning){Stop-ScheduledTask -TaskName 'OpenWebPBX-Cleanup' -TaskPath '\' -ErrorAction Stop}
 if($originalState.Running){$service=Get-Service -Name OpenWebPBX -ErrorAction Stop;$service.Stop();$service.WaitForStatus('Stopped',[TimeSpan]::FromSeconds(30))}
 $timer=[Diagnostics.Stopwatch]::StartNew()
 do{
  $current=Get-NativeCleanupWriterState -Quiescing
  if($current.StartMode -cne $originalState.StartMode -or $current.TaskEnabled){throw 'Writer configuration changed during cleanup.'}
  if(!$current.Running -and !$current.TaskRunning -and (Get-NativeCleanupPhpWriters) -eq 0){return}
  if($timer.Elapsed.TotalSeconds -ge 30){throw 'Owned writers did not quiesce before cleanup.'};Start-Sleep -Milliseconds 100
 }while($true)
}
function Resume-NativeCleanupWriters($Original){
 if(!$Original){return}
 $current=Get-NativeCleanupWriterState -Quiescing
 if($current.StartMode -cne $Original.StartMode){throw 'The backend startup choice changed.'}
 if($Original.TaskEnabled){Enable-ScheduledTask -TaskName 'OpenWebPBX-Cleanup' -TaskPath '\' -ErrorAction Stop|Out-Null}else{Disable-ScheduledTask -TaskName 'OpenWebPBX-Cleanup' -TaskPath '\' -ErrorAction Stop|Out-Null}
 if((Export-ScheduledTask -TaskName 'OpenWebPBX-Cleanup' -TaskPath '\') -cne $Original.TaskXml){throw 'The cleanup task definition did not recover exactly.'}
 if($Original.Running -and !$current.Running){$service=Get-Service -Name OpenWebPBX -ErrorAction Stop;$service.Start();$service.WaitForStatus('Running',[TimeSpan]::FromSeconds(30))}
 if($Original.TaskEnabled -and $Original.TaskRunning){Start-ScheduledTask -TaskName 'OpenWebPBX-Cleanup' -TaskPath '\' -ErrorAction Stop}
 $current=Get-NativeCleanupWriterState -Quiescing
 if($current.Running -ne $Original.Running -or $current.TaskEnabled -ne $Original.TaskEnabled){throw 'The original native writer choice did not recover.'}
}
function Open-NativeCleanupMaintenance {
 $timer=[Diagnostics.Stopwatch]::StartNew()
 do{
  try{return [IO.File]::Open((Join-Path $state 'upgrade.lock'),'Open','ReadWrite','None')}
  catch{
   $errorObject=$_.Exception.GetBaseException();$code=$errorObject.HResult -band 65535
   if($errorObject -isnot [IO.IOException] -or $code -notin 32,33 -or $timer.Elapsed.TotalSeconds -ge 40){throw}
   Start-Sleep -Milliseconds 100
  }
 }while($true)
}
function Invoke-NativeCleanupPhp([string]$Name){
 if($Name -cnotin 'windows-native-cleanup-rows.php','windows-native-cleanup-drain.php'){throw 'An owned cleanup helper is required.'}
 $null=Assert-NativeCleanupOrdinary $privateInput;$null=Assert-NativeCleanupOrdinary (Join-Path $PSScriptRoot $Name)
 $acl=Get-Acl -LiteralPath $privateInput -ErrorAction Stop
 foreach($ace in $acl.Access){if($ace.AccessControlType -eq 'Allow' -and $ace.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -cnotin 'S-1-5-18','S-1-5-32-544'){throw 'Fixture input permissions are not private.'}}
 $expected=Join-Path $state ('native-qualification\'+$scope+'\input.json')
 if([IO.Path]::GetFullPath($privateInput) -ine [IO.Path]::GetFullPath($expected)){throw 'Only the protected current fixture input is allowed.'}
 $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $root 'php\php.exe'));$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $start.ArgumentList.Add((Join-Path $PSScriptRoot $Name));$start.ArgumentList.Add($privateInput)
 $child=[Diagnostics.Process]::Start($start)
 try{
  $readers=@($child.StandardOutput,$child.StandardError);$buffers=@([char[]]::new(1024),[char[]]::new(1024));$texts=@([Text.StringBuilder]::new(),[Text.StringBuilder]::new());$pending=@($null,$null);$closed=@($false,$false);$timer=[Diagnostics.Stopwatch]::StartNew()
  do{
   for($side=0;$side -lt 2;$side++){
    if($closed[$side]){continue}
    if(!$pending[$side]){$pending[$side]=$readers[$side].ReadAsync($buffers[$side],0,1024)}
    if($pending[$side].IsCompleted){$n=$pending[$side].GetAwaiter().GetResult();$pending[$side]=$null;if(!$n){$closed[$side]=$true}else{if($texts[$side].Length+$n -gt 8192){throw 'Owned cleanup helper output exceeded its bound.'};[void]$texts[$side].Append($buffers[$side],0,$n)}}
   }
   if($child.HasExited -and $closed[0] -and $closed[1]){break}
   if($timer.ElapsedMilliseconds -ge 25000){throw 'Owned cleanup helper exceeded its bound.'};Start-Sleep -Milliseconds 10
  }while($true)
  if($child.ExitCode -ne 0){
   if($Name -ceq 'windows-native-cleanup-drain.php'){
    try{
     $row=$texts[0].ToString()|ConvertFrom-Json
     $row|Add-Member NoteProperty child_exit_code ([int]$child.ExitCode) -Force
     $closedFailure=Get-NativeCleanupDrainFailureFields $row
     if($closedFailure.Count){$facts.native_cleanup_drain_failure=$closedFailure}
    }catch{}
    foreach($side in 0,1){
     try{$file=Join-Path $evidence ('native-cleanup-drain-'+@('stdout','stderr')[$side]+'.private.log');$bytes=[Text.UTF8Encoding]::new($false).GetBytes($texts[$side].ToString());$stream=[IO.File]::Open($file,'CreateNew','Write','None');try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}}catch{}
    }
   }
   throw 'Owned cleanup helper refused.'
  }
  return ($texts[0].ToString()|ConvertFrom-Json)
 }finally{if(!$child.HasExited){$child.Kill($true);if(!$child.WaitForExit(5000)){throw 'Owned cleanup helper did not exit.'}};$child.Dispose()}
}
function Invoke-NativeFactoryCleanup {
 $maintenance=$null;$originalWriters=$null;$result=$null;$primary=$null
 try{
  $maintenance=Open-NativeCleanupMaintenance
  Suspend-NativeCleanupWriters ([ref]$originalWriters)
  $drain=Invoke-NativeCleanupPhp 'windows-native-cleanup-drain.php'
  if(($drain.schema -isnot [int] -and $drain.schema -isnot [long]) -or $drain.schema -ne 1 -or $drain.state -cne 'passed' -or $drain.actual_importer -isnot [bool] -or $drain.pre_owned -isnot [bool] -or $drain.foreign_records_imported -isnot [bool] -or $drain.foreign_records_imported){throw 'The owned call-record drain did not pass.'}
  if(($drain.pre_owned -and ($drain.actual_importer -or $drain.owned_channels_ended -ne 0 -or $drain.imported -ne 0 -or $drain.spool_empty_stable_ms -ne 0)) -or (!$drain.pre_owned -and (!$drain.actual_importer -or $drain.spool_empty_stable_ms -ne 3000))){throw 'The owned or idle pre-owned drain scope is invalid.'}
  $result=Php 'cleanup'
 }catch{
  $primary=$_
  try{$row=Invoke-NativeCleanupPhp 'windows-native-cleanup-rows.php';$closed=Get-NativeCleanupRowFields $row;if($closed.Count){$facts.native_cleanup_rows=$closed}}catch{$facts.native_cleanup_rows=@{schema=1;state='unavailable';error_kind='unavailable'}}
 }finally{
  try{Resume-NativeCleanupWriters $originalWriters;if($originalWriters){$facts.native_cleanup_writers_restored=$true}}
  catch{$facts.native_cleanup_writers_restored=$false;if(!$primary){$primary=$_}}
  finally{if($maintenance){$maintenance.Dispose()}}
 }
 if($primary){throw $primary}
 $facts.native_cleanup_writers_restored=$true
 return $result
}
