#Requires -RunAsAdministrator
[CmdletBinding()]
param(
 [Parameter(Mandatory)][ValidateSet('secure','plan','hold','hold-selection','start-web','recover-startup','resume-factory','activate','acl-read','acl-restore')][string]$Operation,
 [Parameter(Mandatory)][string]$Request
)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$root='C:\OpenWebPBX';$private=Join-Path $env:ProgramData 'OpenWebPBX';$config=Join-Path $env:ProgramData 'fusionpbx';$backupEngineRoot='C:\Program Files\FreeSWITCH'
$control=Join-Path $private 'backup-control';$restore=Join-Path $private 'backup-restore'
$services=@{calls='FreeSWITCH';jobs='OpenWebPBX';updates='OpenWebPBXUpdater'}
$certificateTasks=@('OpenWebPBX Certificate Renewal','OpenWebPBX Pending Phone Certificate')
$additionalTasks=@('OpenWebPBX Outgoing Mail','OpenWebPBX-TenantDomains','OpenWebPBX-PhoneHealth','OpenWebPBX-Onboarding')
. (Join-Path $PSScriptRoot 'CallRecords.Common.ps1')
function RestoreCallRecordHold([string[]]$States){
 $journalPath=OrdinaryPath (Join-Path $restore 'journal.json')
 $item=Get-Item -LiteralPath $journalPath -Force -ErrorAction Stop
 if($item.PSIsContainer -or $item.Length -gt 67108864){throw 'The restore call-record hold journal is invalid.'}
 $journal=Get-Content -LiteralPath $journalPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
 if($journal.state -isnot [string] -or $journal.state -cnotin $States){throw 'The durable restore state does not permit this call-record hold operation.'}
 if(!$journal.PSObject.Properties['call_records_hold']){return $null} # Immutable historical journals.
 Assert-OpenWebCallRecordHold $journal.call_records_hold
 if($journal.call_records_hold.owner -cne 'restore'){throw 'The call-record hold is not owned by this restore.'}
 return $journal.call_records_hold
}
function OrdinaryPath([string]$Path,[switch]$ControlOnly){
 $full=[IO.Path]::GetFullPath($Path)
 $allowed=if($ControlOnly){@($control)}else{@($private,$config,(Join-Path $backupEngineRoot 'conf'),(Join-Path $backupEngineRoot 'sounds\openwebpbx'))}
 $valid=$false
 foreach($base in $allowed){$prefix=[IO.Path]::GetFullPath($base).TrimEnd('\');if($full.Equals($prefix,[StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($prefix+'\',[StringComparison]::OrdinalIgnoreCase)){$valid=$true;break}}
 if(!$valid){throw 'A backup path is outside the owned private locations.'}
 $check=$full
 while($check){
  if(Test-Path -LiteralPath $check){$item=Get-Item -LiteralPath $check -Force;if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Backup paths must not contain links or junctions.'}}
  $check=Split-Path -Parent $check
 }
 return $full
}
function PrivateAcl([string]$Path,[string]$Kind){
 $path=OrdinaryPath $Path
 if($Kind -notin 'private','download','config','media','notifications'){throw 'An unknown backup permission class was requested.'}
 $item=Get-Item -LiteralPath $path -Force
 $acl=if($item.PSIsContainer){New-Object Security.AccessControl.DirectorySecurity}else{New-Object Security.AccessControl.FileSecurity}
 $acl.SetAccessRuleProtection($true,$false)
 $registration=Join-Path $private 'tenant-domains\private';$instanceKey=Join-Path $config 'tenant-domains-instance-key.pem'
 if($Kind -eq 'private' -and ($path.Equals($registration,[StringComparison]::OrdinalIgnoreCase) -or $path.StartsWith($registration+'\',[StringComparison]::OrdinalIgnoreCase) -or $path.Equals($instanceKey,[StringComparison]::OrdinalIgnoreCase))){$acl.SetOwner([Security.Principal.SecurityIdentifier]'S-1-5-32-544')}
 $inherit=if($item.PSIsContainer){[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'}else{[Security.AccessControl.InheritanceFlags]::None}
 $propagation=[Security.AccessControl.PropagationFlags]::None
 $allow=[Security.AccessControl.AccessControlType]::Allow
 foreach($sid in 'S-1-5-32-544','S-1-5-18'){$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)),[Security.AccessControl.FileSystemRights]::FullControl,$inherit,$propagation,$allow)))}
 if($Kind -ne 'private'){
  $web=(New-Object Security.Principal.NTAccount('IIS AppPool\OpenWebPBX')).Translate([Security.Principal.SecurityIdentifier])
  $rights=if($Kind -in 'media','notifications'){[Security.AccessControl.FileSystemRights]::Modify}else{[Security.AccessControl.FileSystemRights]::ReadAndExecute}
  $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($web,$rights,$inherit,$propagation,$allow)))
  if($Kind -in 'config','media','notifications'){
   $serviceRights=if($Kind -eq 'media'){[Security.AccessControl.FileSystemRights]::Modify}else{[Security.AccessControl.FileSystemRights]::ReadAndExecute}
   $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier('S-1-5-19')),$serviceRights,$inherit,$propagation,$allow)))
  }
 }
 Set-Acl -LiteralPath $path -AclObject $acl
}
function Plan {
 Import-Module WebAdministration
 $modes=@{};$running=@()
 foreach($name in $services.Values){$service=Get-Service -Name $name -ErrorAction Stop;$record=Get-CimInstance Win32_Service -Filter "Name='$name'";$modes[$name]=[string]$record.StartMode;if($service.Status -eq 'Running'){$running+=$name}}
 $task=Get-ScheduledTask -TaskName 'OpenWebPBX-Backups' -ErrorAction Stop
 $cleanup=Get-ScheduledTask -TaskName 'OpenWebPBX-Cleanup' -ErrorAction Stop
 $certificates=@{};foreach($name in $certificateTasks){$certTask=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue;if($certTask){$certificates[$name]=[bool]$certTask.Settings.Enabled}}
 $additional=@{};foreach($name in $additionalTasks){$extra=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue;if($extra){$additional[$name]=[bool]$extra.Settings.Enabled}}
 return @{schema=1;services=$modes;running=@($running);backup_enabled=[bool]$task.Settings.Enabled;cleanup_enabled=[bool]$cleanup.Settings.Enabled;certificate_tasks=$certificates;additional_tasks=$additional;site_running=(Get-Website -Name OpenWebPBX).State -eq 'Started';pool_running=(Get-WebAppPoolState OpenWebPBX).Value -eq 'Started';site_auto=[bool](Get-ItemProperty IIS:\Sites\OpenWebPBX serverAutoStart).serverAutoStart;pool_auto=[bool](Get-ItemProperty IIS:\AppPools\OpenWebPBX autoStart).autoStart}
}
function ValidPlan($Value){
 if($Value.schema -ne 1 -or !$Value.services){throw 'The factory startup snapshot is invalid.'}
 foreach($name in $services.Values){$mode=$Value.services.PSObject.Properties[$name];if(!$mode -or $mode.Value -notin 'Auto','Manual','Disabled'){throw 'The factory service startup snapshot is invalid.'}}
 foreach($name in @($Value.running)){if($name -notin $services.Values){throw 'The factory running-service snapshot is invalid.'}}
 foreach($field in 'backup_enabled','cleanup_enabled','site_running','pool_running','site_auto','pool_auto'){if($Value.$field -isnot [bool]){throw 'The factory web/task snapshot is invalid.'}}
 foreach($entry in $Value.certificate_tasks.PSObject.Properties){if($entry.Name -notin $certificateTasks -or $entry.Value -isnot [bool]){throw 'The certificate-task snapshot is invalid.'}}
 foreach($entry in $Value.additional_tasks.PSObject.Properties){if($entry.Name -notin $additionalTasks -or $entry.Value -isnot [bool]){throw 'The additional-task snapshot is invalid.'}}
}
function StopWeb {
 Import-Module WebAdministration
 if((Get-Website -Name OpenWebPBX).State -ne 'Stopped'){Stop-Website OpenWebPBX}
 if((Get-WebAppPoolState OpenWebPBX).Value -ne 'Stopped'){Stop-WebAppPool OpenWebPBX}
 for($i=0;$i -lt 160;$i++){if((Get-WebAppPoolState OpenWebPBX).Value -eq 'Stopped'){return};Start-Sleep -Milliseconds 250}
 throw 'The PBX application pool did not stop.'
}
function HoldSelection([string]$Selection){
 if($Selection -eq 'backups'){Disable-ScheduledTask -TaskName 'OpenWebPBX-Backups'|Out-Null;return}
 if(!$services.ContainsKey($Selection)){throw 'An unknown activation selection was requested.'}
 if($Selection -eq 'jobs'){Disable-ScheduledTask -TaskName 'OpenWebPBX-Cleanup'|Out-Null;foreach($name in $additionalTasks){if(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue){Disable-ScheduledTask -TaskName $name|Out-Null}}}
 if($Selection -eq 'updates'){foreach($name in $certificateTasks){if(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue){Disable-ScheduledTask -TaskName $name|Out-Null}}}
 $name=$services[$Selection];Set-Service -Name $name -StartupType Disabled
 if((Get-Service -Name $name).Status -ne 'Stopped'){Stop-Service -Name $name -Force;(Get-Service -Name $name).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(60))}
}
function Startup($Value){
 ValidPlan $Value;Import-Module WebAdministration
 foreach($name in $services.Values){$mode=if($Value.services.$name -eq 'Auto'){'Automatic'}else{[string]$Value.services.$name};Set-Service -Name $name -StartupType $mode}
 if($Value.backup_enabled){Enable-ScheduledTask -TaskName 'OpenWebPBX-Backups'|Out-Null}else{Disable-ScheduledTask -TaskName 'OpenWebPBX-Backups'|Out-Null}
 if($Value.cleanup_enabled){Enable-ScheduledTask -TaskName 'OpenWebPBX-Cleanup'|Out-Null}else{Disable-ScheduledTask -TaskName 'OpenWebPBX-Cleanup'|Out-Null}
 foreach($entry in $Value.certificate_tasks.PSObject.Properties){if($entry.Value){Enable-ScheduledTask -TaskName $entry.Name|Out-Null}else{Disable-ScheduledTask -TaskName $entry.Name|Out-Null}}
 foreach($entry in $Value.additional_tasks.PSObject.Properties){if($entry.Value){Enable-ScheduledTask -TaskName $entry.Name|Out-Null}else{Disable-ScheduledTask -TaskName $entry.Name|Out-Null}}
 Set-ItemProperty IIS:\Sites\OpenWebPBX serverAutoStart $Value.site_auto
 Set-ItemProperty IIS:\AppPools\OpenWebPBX autoStart $Value.pool_auto
}
function StartWeb {
 Import-Module WebAdministration
 if((Get-WebAppPoolState OpenWebPBX).Value -ne 'Started'){Start-WebAppPool OpenWebPBX}
 for($i=0;$i -lt 160;$i++){if((Get-WebAppPoolState OpenWebPBX).Value -eq 'Started'){break};if($i -eq 159){throw 'The PBX application pool did not start.'};Start-Sleep -Milliseconds 250}
 if((Get-Website -Name OpenWebPBX).State -ne 'Started'){Start-Website OpenWebPBX}
}
try{
 $request=OrdinaryPath $Request -ControlOnly
 $item=Get-Item -LiteralPath $request -Force
 if($item.PSIsContainer -or $item.Length -gt 67108864){throw 'A backup control request is invalid.'}
 $value=Get-Content -LiteralPath $request -Raw -Encoding UTF8|ConvertFrom-Json
 $result=@{}
 # Keep incidental cmdlet output outside the single JSON machine response.
 $null = . {
 switch($Operation){
  'secure'{PrivateAcl ([string]$value.path) ([string]$value.kind)}
  'plan'{$result=Plan}
  'hold'{ValidPlan $value;$cdrHold=RestoreCallRecordHold @('prepared','restoring','recovery_required','recovering','recovered');if($cdrHold){Set-OpenWebCallRecordHold -StateRoot $private -Hold $cdrHold -ExternalLockHeld};foreach($selection in 'updates','jobs','calls','backups'){HoldSelection $selection};StopWeb}
  'hold-selection'{HoldSelection ([string]$value.selection)}
  'start-web'{StartWeb;Set-ItemProperty IIS:\Sites\OpenWebPBX serverAutoStart $true;Set-ItemProperty IIS:\AppPools\OpenWebPBX autoStart $true}
  'recover-startup'{Startup $value}
  'resume-factory'{
   ValidPlan $value
   foreach($name in @($value.running)){if((Get-Service -Name $name).Status -ne 'Running'){Start-Service -Name $name}}
   if($value.pool_running -or $value.site_running){StartWeb}
   if(!$value.site_running){Stop-Website OpenWebPBX}
   if(!$value.pool_running){Stop-WebAppPool OpenWebPBX}
   $cdrHold=RestoreCallRecordHold @('recovered');if($cdrHold){Remove-OpenWebCallRecordHold -StateRoot $private -Hold $cdrHold -ExternalLockHeld}
  }
  'activate'{
   ValidPlan $value.gates
   $journal=Get-Content -LiteralPath (OrdinaryPath (Join-Path $restore 'journal.json')) -Raw -Encoding UTF8|ConvertFrom-Json
   if($journal.state -ne 'restored'){throw 'The restore is not complete.'}
   foreach($selection in @($value.selections)){
    if($selection -notin 'calls','jobs','updates','backups' -or (Test-Path -LiteralPath (Join-Path $restore ('hold-'+$selection)))){throw 'The selected restore service has not been released.'}
    $tls=$null
    if($selection -eq 'calls' -and (Test-Path "$private\phone-tls.json")){
     $tls=Get-Content "$private\phone-tls.json" -Raw -Encoding UTF8|ConvertFrom-Json
     if($tls.RestorePending){throw 'Confirm the replacement phone certificate before activating calls.'}
    }
    if($selection -eq 'backups'){Enable-ScheduledTask -TaskName 'OpenWebPBX-Backups'|Out-Null;Start-ScheduledTask -TaskName 'OpenWebPBX-Backups'}
    else{
     $name=$services[$selection];Set-Service -Name $name -StartupType Automatic;Start-Service -Name $name
     if($selection -eq 'calls' -and $tls.PreparedRestored){
      if(!(Test-Path "$root\tools\Test-PhoneTLS.ps1")){throw 'The native phone certificate readiness helper is unavailable.'}
      & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$root\tools\Test-PhoneTLS.ps1" -MaintenanceLockHeld *> $null
      if($LASTEXITCODE -ne 0){throw 'The restored native phone certificate did not pass its trusted TLS test.'}
     }
     if($selection -eq 'jobs' -and $value.gates.cleanup_enabled){Enable-ScheduledTask -TaskName 'OpenWebPBX-Cleanup'|Out-Null}
    }
   }
   $remaining=$false;foreach($name in 'calls','jobs','updates','backups'){if(Test-Path (Join-Path $restore ('hold-'+$name))){$remaining=$true}}
   if(!$remaining){foreach($entry in @($value.gates.certificate_tasks.PSObject.Properties)+@($value.gates.additional_tasks.PSObject.Properties)){if($entry.Value){Enable-ScheduledTask -TaskName $entry.Name|Out-Null}};$cdrHold=RestoreCallRecordHold @('restored');if($cdrHold){Remove-OpenWebCallRecordHold -StateRoot $private -Hold $cdrHold -ExternalLockHeld}}
  }
  'acl-read'{foreach($path in @($value.paths)){$path=OrdinaryPath ([string]$path);$result[$path]=(Get-Acl -LiteralPath $path).Sddl}}
  'acl-restore'{
   . (Join-Path $PSScriptRoot 'File-Security.ps1')
   foreach($entry in $value.files.PSObject.Properties){
    $path=OrdinaryPath $entry.Name
    if($entry.Value -isnot [string] -or !$entry.Value -or $entry.Value.Length -gt 32768){throw 'A factory private-data permission snapshot is invalid.'}
    Set-OpenWebFileSddl -LiteralPath $path -Sddl $entry.Value
   }
  }
 }
 } 3>$null 4>$null 5>$null 6>$null
 [Console]::Out.WriteLine(($result|ConvertTo-Json -Depth 12 -Compress))
}catch{
 [Console]::Error.WriteLine('The Windows backup control operation failed. Review its owned services, storage and permissions.')
 exit 1
}
