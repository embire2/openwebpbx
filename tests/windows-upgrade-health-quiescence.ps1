# QA only: retain all health table/file comparisons by stopping the exact owned
# observer before the baseline. Native enabled operation has a separate gate.
function Assert-OpenWebQualificationHealthTask($Task) {
 $execute=$env:SystemRoot+'\System32\WindowsPowerShell\v1.0\powershell.exe'
 $arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$root+'\tools\Phone-Health.ps1"'
 if($Task.Description -cne 'OpenWeb PBX owned phone health and Windows security observer'   -or $Task.Principal.UserId -cnotin 'SYSTEM','S-1-5-18' -or [string]$Task.Principal.RunLevel -cne 'Highest'   -or [string]$Task.Principal.LogonType -cne 'ServiceAccount' -or @($Task.Actions).Count -ne 1   -or $Task.Actions[0].Execute -ine $execute -or $Task.Actions[0].Arguments -cne $arguments   -or $Task.Actions[0].WorkingDirectory -ine ($root+'\tools') -or [string]$Task.Settings.MultipleInstances -cne 'IgnoreNew'   -or $Task.Settings.Enabled -isnot [bool] -or [string]$Task.State -cnotin 'Running','Ready','Disabled') {
  throw 'The health qualification refuses a foreign or changed observer task.'
 }
 foreach($name in 'Phone-Health.ps1','PhoneHealth-Security.ps1') {
  $installed=Join-Path (Join-Path $root 'tools') $name;$packaged=Join-Path $PackageRoot $name
  foreach($path in $installed,$packaged){$item=Get-Item -LiteralPath $path -Force;if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'The owned health helper must remain ordinary.'}}
  if((Hash $installed) -cne (Hash $packaged)){throw 'The owned health helper differs from the verified candidate.'}
 }
}
function Get-OpenWebQualificationHealthProcesses {
 $count=0
 foreach($process in Get-CimInstance Win32_Process -Filter "Name='php.exe' OR Name='powershell.exe'") {
  $exe=([string]$process.ExecutablePath).Replace('/','\');$command=([string]$process.CommandLine).Replace('/','\');$nativeRoot=$root.Replace('/','\')
  $php=$exe.Equals(($nativeRoot+'\php\php.exe'),[StringComparison]::OrdinalIgnoreCase) -and $command.IndexOf(($nativeRoot+'\tools\phone-health.php'),[StringComparison]::OrdinalIgnoreCase) -ge 0
  $ps=$exe.Equals(($env:SystemRoot+'\System32\WindowsPowerShell\v1.0\powershell.exe'),[StringComparison]::OrdinalIgnoreCase) -and $command.IndexOf(($nativeRoot+'\tools\Phone-Health.ps1'),[StringComparison]::OrdinalIgnoreCase) -ge 0
  if(!$php -and !$ps){continue}
  $owner=Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid
  if($owner.ReturnValue -ne 0 -or $owner.Sid -cne 'S-1-5-18'){throw 'The health qualification refuses an unexpected observer identity.'}
  $count++
 };return $count
}
function Suspend-OpenWebQualificationHealth([ref]$Original) {
 $task=Get-ScheduledTask -TaskName 'OpenWebPBX-PhoneHealth' -ErrorAction SilentlyContinue
 if(!$task){$Original.Value=@{Exists=$false;Enabled=$false;Running=$false};return}
 Assert-OpenWebQualificationHealthTask $task
 $null=Get-OpenWebQualificationHealthProcesses
 $Original.Value=@{Exists=$true;Enabled=$task.Settings.Enabled;Running=([string]$task.State -ceq 'Running')}
 Disable-ScheduledTask -TaskName 'OpenWebPBX-PhoneHealth'|Out-Null
 if([string]$task.State -ceq 'Running'){Stop-ScheduledTask -TaskName 'OpenWebPBX-PhoneHealth' -ErrorAction Stop}
 $stopped=$false
 for($attempt=0;$attempt -lt 80;$attempt++) {
  $current=Get-ScheduledTask -TaskName 'OpenWebPBX-PhoneHealth'
  Assert-OpenWebQualificationHealthTask $current
  if($current.Settings.Enabled){throw 'The health observer unexpectedly became enabled.'}
  if([string]$current.State -cne 'Running' -and (Get-OpenWebQualificationHealthProcesses) -eq 0){$stopped=$true;break}
  Start-Sleep -Milliseconds 250
 }
 if(!$stopped){throw 'The owned health observer did not quiesce before the preservation baseline.'}
 $spool=Join-Path $state 'phone-health-runtime'
 if(Test-Path -LiteralPath $spool){
  $item=Get-Item -LiteralPath $spool -Force
  if(!$item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'The private health spool must remain ordinary.'}
  foreach($node in Get-ChildItem -LiteralPath $spool -Recurse -Force){if(!$node.PSIsContainer -or ($node.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'The health preservation baseline refuses pending runtime files.'}}
 }
}
function Resume-OpenWebQualificationHealth($Original) {
 if(!$Original -or !$Original.Exists){return}
 $task=Get-ScheduledTask -TaskName 'OpenWebPBX-PhoneHealth'
 Assert-OpenWebQualificationHealthTask $task
 if($Original.Enabled){Enable-ScheduledTask -TaskName 'OpenWebPBX-PhoneHealth'|Out-Null}else{Disable-ScheduledTask -TaskName 'OpenWebPBX-PhoneHealth'|Out-Null}
 if($Original.Enabled -and $Original.Running -and [string]$task.State -cne 'Running'){
  if((Get-OpenWebQualificationHealthProcesses) -ne 0){throw 'An unexpected remaining health observer prevents original-state restart.'}
  Start-ScheduledTask -TaskName 'OpenWebPBX-PhoneHealth'
 }
}
