# SPDX-License-Identifier: AGPL-3.0-or-later.
# Exact caller functions under offline mocks. Never invokes a Windows service.
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null;$tree=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'windows-restore-qualification.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The actual restore caller no longer parses.'}
foreach($name in 'Derived','AssertBackupTask'){
 $definitions=@($tree.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
 if($definitions.Count -ne 1){throw 'One exact caller function is required.'};. ([ScriptBlock]::Create($definitions[0].Extent.Text))
}
function Check([bool]$Value,[string]$Message){if(!$Value){throw $Message}}
$original=$env:WINDOWS_RESTORE_FIXTURE_PASSPHRASE
try{
 $env:WINDOWS_RESTORE_FIXTURE_PASSPHRASE='Fictional-only-A9!'+('a'*40)
 $actual=[Convert]::ToHexString((Derived 'capsule')).ToLowerInvariant()
 Check ($actual -eq '1bfb48d35329717650f0411afdfd984aa7823eab1eeb9b0c0779b4e99174feeb') 'Independent Python/PowerShell derivation differs.'
 Check ([Convert]::ToHexString((Derived 'administrator/source/x')) -ne [Convert]::ToHexString((Derived 'administrator/target/x'))) 'Source and target administrator passwords must differ.'
 $root='C:\OpenWebPBX';$facts=@{gates=@{}};$script:task=[pscustomobject]@{Principal=[pscustomobject]@{UserId='SYSTEM';RunLevel='Highest'};Actions=@([pscustomobject]@{Execute='C:\OpenWebPBX\backup-runtime\python.exe';Arguments='-I "C:\OpenWebPBX\tools\backups.py" worker'});Triggers=@([pscustomobject]@{CimClass=[pscustomobject]@{CimClassName='MSFT_TaskBootTrigger'}})}
 function Get-ScheduledTask {param([string]$TaskName,$ErrorAction)if($TaskName -ne 'OpenWebPBX-Backups'){throw 'Unexpected task.'};return $script:task}
 function Get-ScheduledTaskInfo {param($InputObject)return [pscustomobject]@{LastTaskResult=0;LastRunTime=[DateTime]::Now}}
 AssertBackupTask;Check ($facts.gates.actual_system_task_principal_action_execution -eq 'passed') 'The positive actual SYSTEM action was not accepted.'
 $script:task.Principal.UserId='Administrator';$refused=$false;try{AssertBackupTask}catch{$refused=$true};Check $refused 'An Administrator task cannot qualify SYSTEM execution.'
 $script:task.Principal.UserId='SYSTEM';$script:task.Actions[0].Arguments='-I unowned.py worker';$refused=$false;try{AssertBackupTask}catch{$refused=$true};Check $refused 'A foreign native task action must be rejected.'
 $script:task.Actions[0].Arguments='-I "C:\OpenWebPBX\tools\backups.py" worker';$script:task.Triggers=@();$refused=$false;try{AssertBackupTask}catch{$refused=$true};Check $refused 'A missing real startup trigger must be rejected.'
 Write-Output 'Six exact restore-caller controls passed; no Windows task/boot qualification claimed.'
}finally{if($null -eq $original){Remove-Item Env:\WINDOWS_RESTORE_FIXTURE_PASSPHRASE -ErrorAction SilentlyContinue}else{$env:WINDOWS_RESTORE_FIXTURE_PASSPHRASE=$original}}
