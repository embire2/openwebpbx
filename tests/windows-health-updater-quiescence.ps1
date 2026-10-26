# QA only. The independent updater heartbeat is not covered by upgrade.lock.
# Stop its exact candidate-bound service for the complete public-state baseline;
# retain every table/row comparison and restore the original service/task choice.
function Assert-HealthUpdaterOrdinary([string]$Path,[bool]$Directory) {
 $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
 if([bool]$item.PSIsContainer -ne $Directory){throw 'The updater qualification path has changed type.'}
 for($node=$item;$node;$node=$node.Parent){if($node.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'The updater qualification refuses redirected paths.'};if(!$node.PSIsContainer){$node=$node.Directory;if(!$node){break};if($node.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'The updater qualification refuses redirected paths.'}}}
 return $item
}
function Assert-HealthUpdaterRestartTask($Task) {
 $exe=$env:SystemRoot+'\System32\WindowsPowerShell\v1.0\powershell.exe'
 $args='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$root+'\tools\Restart-Updater.ps1"'
 if(@($Task).Count -ne 1 -or $Task.TaskName -cne 'OpenWebPBX-Updater-Restart' -or $Task.TaskPath -cne '\' -or @($Task.Actions).Count -ne 1 -or $Task.Actions[0].Execute -ine $exe -or $Task.Actions[0].Arguments -cne $args -or $Task.Principal.UserId -cnotin 'SYSTEM','S-1-5-18' -or [string]$Task.Principal.RunLevel -cnotin 'Highest','1' -or [string]$Task.Principal.LogonType -cnotin 'ServiceAccount','5' -or @($Task.Triggers|Where-Object {$null -ne $_}).Count -ne 0 -or $Task.Settings.Enabled -isnot [bool] -or [string]$Task.State -cnotin 'Ready','Disabled'){throw 'The updater qualification refuses a foreign or active restart task.'}
}
function Write-HealthUpdaterServiceRefusal($Services,[string]$Expected) {
 # Closed failure-only projection of the exact original sample; no new query.
 try {
  $rows=@($Services);$one=$rows.Count -eq 1
  $safe=@{schema=1;kind='qualification_service_shape_refusal';count=if(!$rows.Count){'absent'}elseif($one){'single'}else{'multiple'};name_matches=$false;image_matches=$false;account_allowed=$false;startup_allowed=$false;state_allowed=$false;service_state='unavailable'}
  if($one){
   $row=$rows[0]
   $safe.name_matches=$row.Name -ceq 'OpenWebPBXUpdater'
   $safe.image_matches=$row.PathName -ieq ('"'+$Expected+'"')
   $safe.account_allowed=$row.StartName -cin 'LocalSystem','NT AUTHORITY\SYSTEM'
   $safe.startup_allowed=$row.StartMode -cin 'Auto','Manual','Disabled'
   $safe.state_allowed=$row.State -cin 'Running','Stopped'
   $safe.service_state=if($row.State -is [string] -and $row.State -cin 'Running','Stopped','Start Pending','Stop Pending','Continue Pending','Pause Pending','Paused','Unknown'){$row.State}else{'other'}
  }
  $raw=ConvertTo-Json -InputObject $safe -Depth 3 -Compress
  if($raw.Length -le 2048){Write-Host ('OPENWEB_UPDATER_SERVICE_REFUSAL '+$raw)}
 }catch{} # Observation must never replace the original refusal.
}
function Get-HealthUpdaterQualificationState {
 $metadata=Join-Path $state 'updater-install.json';$null=Assert-HealthUpdaterOrdinary $metadata $false
 $value=Get-Content -LiteralPath $metadata -Raw|ConvertFrom-Json
 $version=(Get-Content -LiteralPath (Join-Path $PackageRoot 'VERSION') -Raw).Trim()
 if($version -cnotmatch '^\d+\.\d+\.\d+$' -or $value.Version -cne $version){throw 'The updater qualification requires the exact candidate version.'}
 $slot=Join-Path $root ('updater\slots\'+$version);$expected=Join-Path $slot 'OpenWebPbx.Updater.exe'
 if($value.Executable -isnot [string] -or $value.Executable -ine $expected){throw 'The updater metadata does not select the candidate slot.'}
 $packaged=Join-Path $PackageRoot 'updater';$null=Assert-HealthUpdaterOrdinary $slot $true;$null=Assert-HealthUpdaterOrdinary $packaged $true
 $manifest=@{}
 foreach($base in $packaged,$slot){
  $current=@{}
  foreach($entry in Get-ChildItem -LiteralPath $base -Recurse -Force){
   $null=Assert-HealthUpdaterOrdinary $entry.FullName ([bool]$entry.PSIsContainer)
   $relative=$entry.FullName.Substring($base.Length+1)
   if($current.ContainsKey($relative)){throw 'The updater inventory is ambiguous.'}
   $current[$relative]=if($entry.PSIsContainer){'directory'}else{(Get-FileHash -LiteralPath $entry.FullName -Algorithm SHA256).Hash}
  }
  if($base -ceq $packaged){$manifest=$current;if($manifest.Count -lt 4 -or !$manifest.ContainsKey('OpenWebPbx.Updater.exe') -or !$manifest.ContainsKey('OpenWebPbx.Updater.dll')){throw 'The candidate updater inventory is incomplete.'}}
  else{if($current.Count -ne $manifest.Count){throw 'The installed updater inventory differs.'};foreach($name in $manifest.Keys){if(!$current.ContainsKey($name) -or $current[$name] -cne $manifest[$name]){throw 'The installed updater bytes differ from the candidate.'}}}
 }
 $service=@(Get-CimInstance Win32_Service -Filter "Name='OpenWebPBXUpdater'" -ErrorAction Stop)
 if($service.Count -ne 1 -or $service[0].Name -cne 'OpenWebPBXUpdater' -or $service[0].PathName -ine ('"'+$expected+'"') -or $service[0].StartName -cnotin 'LocalSystem','NT AUTHORITY\SYSTEM' -or $service[0].StartMode -cnotin 'Auto','Manual','Disabled' -or $service[0].State -cnotin 'Running','Stopped'){try{Write-HealthUpdaterServiceRefusal $service $expected}catch{};throw 'The updater qualification refuses an unexpected service.'}
 $service=$service[0]
 if($service.State -ceq 'Running' -and $service.StartMode -ceq 'Disabled'){throw 'A running disabled updater cannot be restored without changing startup configuration.'}
 $processes=@(Get-CimInstance Win32_Process -Filter "Name='OpenWebPbx.Updater.exe'" -ErrorAction Stop|Where-Object {$_.ExecutablePath -ieq $expected})
 foreach($process in $processes){$owner=Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid -ErrorAction Stop;if($owner.ReturnValue -ne 0 -or $owner.Sid -cne 'S-1-5-18'){throw 'The updater qualification refuses an unexpected process identity.'}}
 if(($service.State -ceq 'Running' -and ($processes.Count -ne 1 -or $processes[0].ProcessId -ne $service.ProcessId)) -or ($service.State -ceq 'Stopped' -and ($service.ProcessId -ne 0 -or $processes.Count -ne 0))){throw 'The updater service/process ownership is inconsistent.'}
 $task=Get-ScheduledTask -TaskName 'OpenWebPBX-Updater-Restart' -TaskPath '\' -ErrorAction Stop;Assert-HealthUpdaterRestartTask $task
 return @{Executable=$expected;StartMode=$service.StartMode;StartName=$service.StartName;Running=($service.State -ceq 'Running');TaskEnabled=$task.Settings.Enabled;TaskXml=(Export-ScheduledTask -TaskName 'OpenWebPBX-Updater-Restart' -TaskPath '\');MetadataHash=(Get-FileHash -LiteralPath $metadata -Algorithm SHA256).Hash}
}
function Assert-HealthUpdaterOriginal($Original,$Current) {
 foreach($field in 'Executable','StartMode','StartName','MetadataHash'){if($Current[$field] -cne $Original[$field]){throw 'The original updater identity or configuration changed.'}}
}
function Suspend-HealthQualificationUpdater([ref]$Original) {
 $current=Get-HealthUpdaterQualificationState;$Original.Value=$current
 Disable-ScheduledTask -TaskName 'OpenWebPBX-Updater-Restart' -TaskPath '\' -ErrorAction Stop|Out-Null
 if($current.Running){Stop-Service -Name OpenWebPBXUpdater -ErrorAction Stop}
 $deadline=[DateTime]::UtcNow.AddSeconds(30)
 do{
  $now=Get-HealthUpdaterQualificationState;Assert-HealthUpdaterOriginal $current $now
  if($now.TaskEnabled){throw 'The updater restart task became enabled during quiescence.'}
  if(!$now.Running){return}
  if([DateTime]::UtcNow -ge $deadline){throw 'The exact owned updater did not stop before the public baseline.'};Start-Sleep -Milliseconds 100
 }while($true)
}
function Resume-HealthQualificationUpdater($Original) {
 if(!$Original){return}
 $now=Get-HealthUpdaterQualificationState;Assert-HealthUpdaterOriginal $Original $now
 if($Original.TaskEnabled){Enable-ScheduledTask -TaskName 'OpenWebPBX-Updater-Restart' -TaskPath '\' -ErrorAction Stop|Out-Null}else{Disable-ScheduledTask -TaskName 'OpenWebPBX-Updater-Restart' -TaskPath '\' -ErrorAction Stop|Out-Null}
 if((Export-ScheduledTask -TaskName 'OpenWebPBX-Updater-Restart' -TaskPath '\') -cne $Original.TaskXml){throw 'The updater restart task definition did not recover exactly.'}
 if($Original.Running -and !$now.Running){Start-Service -Name OpenWebPBXUpdater -ErrorAction Stop}
 $deadline=[DateTime]::UtcNow.AddSeconds(30)
 do{$now=Get-HealthUpdaterQualificationState;Assert-HealthUpdaterOriginal $Original $now;if($now.Running -eq $Original.Running -and $now.TaskEnabled -eq $Original.TaskEnabled){return};if([DateTime]::UtcNow -ge $deadline){throw 'The original updater running choice did not recover.'};Start-Sleep -Milliseconds 100}while($true)
}
