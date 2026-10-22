# Actual PowerShell AST/body controls; Task Scheduler itself is native-only.
$ErrorActionPreference='Stop';$script:checks=0
. (Join-Path $PSScriptRoot '..\packaging\windows\PhoneHealth-Security.ps1')
function Check([bool]$Value,[string]$Message){if(!$Value){throw $Message};$script:checks++}
function Refuses([scriptblock]$Action,[string]$Message){try{$null=& $Action}catch{$script:checks++;return};throw $Message}
$beforeProgramData=$env:ProgramData;$beforeWindir=$env:windir;$tmp=Join-Path ([IO.Path]::GetTempPath()) ('openweb-health-task-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $tmp 'OpenWebPBX')|Out-Null;$env:ProgramData=$tmp;$env:windir='C:\Windows';$script:task=$null;$script:stops=0;$script:disables=0;$script:neverStop=$false
function Get-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction);return $script:task}
function Disable-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction);$script:disables++;$script:task.Settings.Enabled=$false}
function Stop-ScheduledTask {param($TaskName,$TaskPath,$ErrorAction);$script:stops++;if(!$script:neverStop){$script:task.State='Ready'}}
function Start-Sleep {param($Milliseconds)}
function OwnedTask {return [pscustomobject]@{TaskName='OpenWebPBX-PhoneHealth';TaskPath='\';Description='OpenWeb PBX owned phone health and Windows security observer';Principal=[pscustomobject]@{UserId='SYSTEM';LogonType='ServiceAccount';RunLevel='Highest'};Actions=@([pscustomobject]@{Execute='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe';Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\OpenWebPBX\tools\Phone-Health.ps1"';WorkingDirectory='C:\OpenWebPBX\tools'});State='Running';Settings=[pscustomobject]@{Enabled=$true}}}
function TestAcl([string]$Owner,[string]$Sid,[string]$Rights,[string]$Propagation='None'){
 $identity=[pscustomobject]@{Value=$Sid};$identity|Add-Member -MemberType ScriptMethod -Name Translate -Value {param($type);return $this}
 return [pscustomobject]@{Owner=$Owner;Access=@([pscustomobject]@{IdentityReference=$identity;FileSystemRights=[Security.AccessControl.FileSystemRights]$Rights;AccessControlType='Allow';PropagationFlags=[Security.AccessControl.PropagationFlags]$Propagation})}
}
$lock=$null
try{
 foreach($path in @('..\packaging\windows\PhoneHealth-Security.ps1','..\packaging\windows\PhoneHealth-Firewall.Common.ps1','..\packaging\windows\PhoneHealth-Firewall.ps1','..\packaging\windows\Phone-Health.ps1','..\packaging\windows\Install-PhoneHealth.ps1')){$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $path),[ref]$tokens,[ref]$errors);Check ($errors.Count -eq 0) 'Health PowerShell parse failed.'}
 $lock=[IO.File]::Open((Join-Path $tmp 'OpenWebPBX\upgrade.lock'),'CreateNew','ReadWrite','None')
 Assert-OpenWebHealthTask $null;Stop-OpenWebHealthTask -MaintenanceLock $lock;Check ($script:stops -eq 0 -and $script:disables -eq 0) 'Missing task mutated another task.'
 $script:task=OwnedTask;Assert-OpenWebHealthTask $script:task;Stop-OpenWebHealthTask -MaintenanceLock $lock;Check ($script:stops -eq 1 -and $script:disables -eq 0 -and $script:task.Settings.Enabled) 'Normal stop changed enabled choice.'
 $script:task=OwnedTask;Stop-OpenWebHealthTask -MaintenanceLock $lock -Disable;Check ($script:stops -eq 2 -and $script:disables -eq 1 -and !$script:task.Settings.Enabled) 'Snapshot stop did not disable exact task.'
 $script:task=OwnedTask;$script:task.State='Disabled';$script:task.Settings.Enabled=$false;Stop-OpenWebHealthTask -MaintenanceLock $lock;Check ($script:stops -eq 2 -and !$script:task.Settings.Enabled) 'Explicit disabled choice changed.'
 foreach($property in @('TaskName','TaskPath','Description')){$script:task=OwnedTask;$script:task.$property='foreign';Refuses {Stop-OpenWebHealthTask -MaintenanceLock $lock -Disable} 'Foreign named task was stopped.'}
 foreach($property in @('UserId','LogonType','RunLevel')){$script:task=OwnedTask;$script:task.Principal.$property='foreign';Refuses {Stop-OpenWebHealthTask -MaintenanceLock $lock -Disable} 'Foreign principal was stopped.'}
 foreach($property in @('Execute','Arguments','WorkingDirectory')){$script:task=OwnedTask;$script:task.Actions[0].$property='foreign';Refuses {Stop-OpenWebHealthTask -MaintenanceLock $lock -Disable} 'Foreign action was stopped.'}
 $script:task=OwnedTask;$script:task.Actions+=@($script:task.Actions[0]);Refuses {Stop-OpenWebHealthTask -MaintenanceLock $lock -Disable} 'Multiple task actions accepted.'
 Check ($script:stops -eq 2 -and $script:disables -eq 1) 'Foreign task changed before refusing.'
 $script:task=OwnedTask;$script:task.Principal.UserId='S-1-5-18';Assert-OpenWebHealthTask $script:task;Check $true 'SYSTEM SID not accepted.'
 $script:task=@((OwnedTask),(OwnedTask));Refuses {Assert-OpenWebHealthTask $script:task} 'Multiple same-name tasks accepted.'
 $script:task=OwnedTask;$script:neverStop=$true;Refuses {Stop-OpenWebHealthTask -MaintenanceLock $lock} 'Running task did not time out.';Check ($script:stops -eq 3) 'Stop retried mutations rather than bounded observation.'
 $lock.Dispose();$lock=$null;$wrong=[IO.File]::Open((Join-Path $tmp 'wrong.lock'),'CreateNew','ReadWrite','None');try{Refuses {Stop-OpenWebHealthTask -MaintenanceLock $wrong} 'Unrelated lock accepted.'}finally{$wrong.Dispose()}
 $admin='S-1-5-32-544';$setup='S-1-5-21-111-222-333-1001';$iis='S-1-5-82-1-2-3-4-5';$plain='S-1-5-21-111-222-333-1002';$allowed=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);foreach($sid in @('S-1-5-18',$admin,$setup)){$null=$allowed.Add($sid)}
 $full='C:\OpenWebPBX\tools\phone-health.php'
 Assert-OpenWebHealthAcl (TestAcl $admin $setup FullControl) $full $full $allowed;Check $true 'Current named setup administrator grant refused.'
 Assert-OpenWebHealthAcl (TestAcl $setup $admin FullControl) $full $full $allowed;Check $true 'Current named setup administrator owner refused.'
 Assert-OpenWebHealthAcl (TestAcl $admin $iis ReadAndExecute) $full $full $allowed;Check $true 'Read-only IIS access refused.'
 foreach($rights in 'Write','Modify','FullControl','Delete','ChangePermissions','TakeOwnership'){Refuses {Assert-OpenWebHealthAcl (TestAcl $admin $iis $rights) $full $full $allowed} 'IIS writable helper accepted.'}
 Refuses {Assert-OpenWebHealthAcl (TestAcl $plain $admin FullControl) $full $full $allowed} 'Unprivileged owner can change helper ACL.'
 Refuses {Assert-OpenWebHealthAcl (TestAcl $admin $plain FullControl) $full $full $allowed} 'Former/non-admin writer accepted.'
 $null=$allowed.Remove($setup);Refuses {Assert-OpenWebHealthAcl (TestAcl $admin $setup FullControl) $full $full $allowed} 'Revoked setup administrator writer accepted.'
 Assert-OpenWebHealthAcl (TestAcl $admin $plain Write) 'C:\' $full $allowed;Check $true 'Unrelated sibling creation on volume root refused.'
 Refuses {Assert-OpenWebHealthAcl (TestAcl $admin $plain DeleteSubdirectoriesAndFiles) 'C:\' $full $allowed} 'Unprivileged volume delete-child accepted.'
 Assert-OpenWebHealthAcl (TestAcl $admin $plain FullControl InheritOnly) 'C:\OpenWebPBX\tools' $full $allowed;Check $true 'Inherit-only ACE applied to current node.'
 @{checks=$script:checks;actual_powershell_ast_and_body=$true;native_task_scheduler=$false;no_host_tasks_changed=$true}|ConvertTo-Json -Compress
}finally{if($lock){$lock.Dispose()};$env:ProgramData=$beforeProgramData;$env:windir=$beforeWindir;Remove-Item -LiteralPath $tmp -Recurse -Force}
