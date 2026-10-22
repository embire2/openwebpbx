param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$checks=0
function Check([bool]$Value){if(!$Value){throw ('Updater quiescence control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
function Refuses([scriptblock]$Action){$failed=$false;try{& $Action}catch{$failed=$true};Check $failed}
. (Join-Path $SourceRoot 'tests/windows-health-updater-quiescence.ps1')
$work=Join-Path ([IO.Path]::GetTempPath()) ('openweb-health-updater-'+[Guid]::NewGuid().ToString('N'))
function Get-CimInstance($ClassName,$Filter){if($ClassName -ceq 'Win32_Service'){return $script:service};if($ClassName -ceq 'Win32_Process'){if($script:service.State -ceq 'Running' -or $script:orphan){return @{ExecutablePath=$script:expected;ProcessId=([uint32]7123)}};return};throw 'Unexpected native observer'}
function Invoke-CimMethod {return @{ReturnValue=0;Sid=$script:owner}}
function Get-ScheduledTask {return $script:task}
function Export-ScheduledTask {return ('owned-definition;enabled='+$script:task.Settings.Enabled)}
function Disable-ScheduledTask {$script:mutations++;$script:task.Settings.Enabled=$false;$script:task.State='Disabled'}
function Enable-ScheduledTask {$script:mutations++;$script:task.Settings.Enabled=$true;$script:task.State='Ready'}
function Stop-Service {$script:mutations++;$script:service.State='Stopped';$script:service.ProcessId=0}
function Start-Service {$script:mutations++;$script:service.State='Running';$script:service.ProcessId=[uint32]7123}
function Reset {
 $script:mutations=0;$script:owner='S-1-5-18';$script:orphan=$false
 $script:service=@{Name='OpenWebPBXUpdater';PathName=('"'+$expected+'"');StartName='LocalSystem';StartMode='Auto';State='Running';ProcessId=[uint32]7123}
 $script:task=@{TaskName='OpenWebPBX-Updater-Restart';TaskPath='\';Actions=@(@{Execute=($env:SystemRoot+'\System32\WindowsPowerShell\v1.0\powershell.exe');Arguments=('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$root+'\tools\Restart-Updater.ps1"')});Principal=@{UserId='SYSTEM';RunLevel='Highest';LogonType='ServiceAccount'};Settings=@{Enabled=$true};State='Ready';Triggers=@()}
}
try{
 New-Item -ItemType Directory -Path $work|Out-Null;$root=Join-Path $work 'installed';$state=Join-Path $work 'private';$PackageRoot=Join-Path $work 'candidate'
 $package=Join-Path $PackageRoot 'updater';$slot=Join-Path $root 'updater\slots\1.0.20';$script:expected=Join-Path $slot 'OpenWebPbx.Updater.exe'
 New-Item -ItemType Directory -Path $package,$slot,$state|Out-Null
 '1.0.20'|Set-Content -LiteralPath (Join-Path $PackageRoot 'VERSION')
 foreach($name in 'OpenWebPbx.Updater.exe','OpenWebPbx.Updater.dll','OpenWebPbx.Updater.deps.json','OpenWebPbx.Updater.runtimeconfig.json'){'candidate '+$name|Set-Content -LiteralPath (Join-Path $package $name);Copy-Item -LiteralPath (Join-Path $package $name) -Destination (Join-Path $slot $name)}
 @{Version='1.0.20';Executable=$expected}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $state 'updater-install.json')
 foreach($running in $true,$false){foreach($enabled in $true,$false){
  Reset;if(!$running){$service.State='Stopped';$service.ProcessId=0};if(!$enabled){$task.Settings.Enabled=$false;$task.State='Disabled'}
  $before=Get-HealthUpdaterQualificationState;$original=$null;Suspend-HealthQualificationUpdater ([ref]$original);Check (!$service.ProcessId -and $service.State -ceq 'Stopped' -and !$task.Settings.Enabled);Check ($original.Running -eq $running -and $original.TaskEnabled -eq $enabled)
  Resume-HealthQualificationUpdater $original;$after=Get-HealthUpdaterQualificationState;Check ($after.Running -eq $running -and $after.TaskEnabled -eq $enabled -and $after.TaskXml -ceq $before.TaskXml);Check ($after.StartMode -ceq $before.StartMode -and $after.MetadataHash -ceq $before.MetadataHash)
 }}
 foreach($field in 'Name','PathName','StartName','StartMode','State'){
  Reset;$service[$field]='foreign';$original=$null;Refuses {Suspend-HealthQualificationUpdater ([ref]$original)};Check ($mutations -eq 0)
 }
 Reset;$service.ProcessId=[uint32]9999;$original=$null;Refuses {Suspend-HealthQualificationUpdater ([ref]$original)};Check ($mutations -eq 0)
 Reset;$service.StartMode='Disabled';$original=$null;Refuses {Suspend-HealthQualificationUpdater ([ref]$original)};Check ($mutations -eq 0)
 Reset;$owner='S-1-5-21-9999';$original=$null;Refuses {Suspend-HealthQualificationUpdater ([ref]$original)};Check ($mutations -eq 0)
 Reset;$service.State='Stopped';$service.ProcessId=0;$orphan=$true;$original=$null;Refuses {Suspend-HealthQualificationUpdater ([ref]$original)};Check ($mutations -eq 0)
 foreach($field in 'TaskName','TaskPath','State'){
  Reset;$task[$field]='foreign';$original=$null;Refuses {Suspend-HealthQualificationUpdater ([ref]$original)};Check ($mutations -eq 0)
 }
 foreach($field in 'UserId','RunLevel','LogonType'){
  Reset;$task.Principal[$field]='foreign';$original=$null;Refuses {Suspend-HealthQualificationUpdater ([ref]$original)};Check ($mutations -eq 0)
 }
 foreach($field in 'Execute','Arguments'){
  Reset;$task.Actions[0][$field]='foreign';$original=$null;Refuses {Suspend-HealthQualificationUpdater ([ref]$original)};Check ($mutations -eq 0)
 }
 Reset;$task.Triggers=@(@{foreign=$true});$original=$null;Refuses {Suspend-HealthQualificationUpdater ([ref]$original)};Check ($mutations -eq 0)
 Reset;$task.Triggers=$null;$original=$null;Suspend-HealthQualificationUpdater ([ref]$original);Check (!$service.ProcessId -and !$task.Settings.Enabled);Resume-HealthQualificationUpdater $original;Check ($service.State -ceq 'Running' -and $task.Settings.Enabled)
 Reset;$task.State='Running';$original=$null;Refuses {Suspend-HealthQualificationUpdater ([ref]$original)};Check ($mutations -eq 0)
 Reset;$task.Settings.Enabled='true';$original=$null;Refuses {Suspend-HealthQualificationUpdater ([ref]$original)};Check ($mutations -eq 0)
 Reset;$added=Join-Path $slot 'foreign.ini';'foreign'|Set-Content $added;$original=$null;Refuses {Suspend-HealthQualificationUpdater ([ref]$original)};Check ($mutations -eq 0);Remove-Item $added
 Reset;$changed=Join-Path $slot 'OpenWebPbx.Updater.dll';'foreign'|Set-Content $changed;$original=$null;Refuses {Suspend-HealthQualificationUpdater ([ref]$original)};Check ($mutations -eq 0);Copy-Item (Join-Path $package 'OpenWebPbx.Updater.dll') $changed -Force
 Reset;$original=$null;Suspend-HealthQualificationUpdater ([ref]$original);$mutations=0;$service.StartMode='Disabled';Refuses {Resume-HealthQualificationUpdater $original};Check ($mutations -eq 0)
 Reset;$original=$null;Suspend-HealthQualificationUpdater ([ref]$original);$mutations=0;$task.Actions[0].Arguments='foreign';Refuses {Resume-HealthQualificationUpdater $original};Check ($mutations -eq 0)
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows_phone_health_acceptance.ps1'),[ref]$tokens,[ref]$errors);Check ($errors.Count -eq 0)
 $text=$ast.Extent.Text;$suspend=$text.IndexOf('Suspend-HealthQualificationUpdater ([ref]$updaterOriginal)');$baseline=$text.IndexOf("`$publicBefore=Php");$compare=$text.IndexOf('if($publicAfter.state');$resume=$text.IndexOf('Resume-HealthQualificationUpdater $updaterOriginal')
 Check ($suspend -ge 0 -and $baseline -gt $suspend -and $compare -gt $baseline -and $resume -gt $compare)
 Check ($text.Contains("`$publicAfter.public_preservation_sha256 -cne `$publicBefore.public_preservation_sha256"))
 $repository=Get-Content -LiteralPath (Join-Path $SourceRoot 'platform/OpenWebPbx.Updater/UpdateRepository.cs') -Raw
 Check ($repository.Contains('update v_pbx_update_status set updated_at=now() where singleton=1'))
}finally{Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue}
Write-Output ('PASS '+$checks+' actual updater quiescence/file/identity/state controls; service and Scheduler are doubles, no installed PBX invoked')
