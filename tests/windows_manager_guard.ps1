#Requires -Version 5.1
[CmdletBinding()]
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent),[string]$SourceText='',[switch]$ExistingSid500Task)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if(!$SourceText){$SourceText=[IO.File]::ReadAllText((Join-Path $SourceRoot 'packaging/windows/Upgrade-OpenWebPBX.ps1'))}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($SourceText,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The actual upgrade source must parse.'}
$definitions=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'PrepareManagers'},$true))
if($definitions.Count -ne 1){throw 'The actual manager guard must be unique.'}
$definition=$definitions[0].Extent.Text
$commands=@($definitions[0].FindAll({param($node)$node -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object {$_.GetCommandName()}|Sort-Object -Unique)
foreach($command in $commands){if($command -cnotin 'InstalledManagers','Invoke-CimMethod','Get-ScheduledTask','New-ScheduledTaskPrincipal','New-ScheduledTaskAction','New-ScheduledTaskSettingsSet','Register-ScheduledTask','Out-Null','New-Object'){throw 'The isolated manager guard contains an unreviewed command.'}}
$fixed='$actions=@()'+"`n"+'   if($task){$actions=@($task.Actions)}'
if(!$definition.Contains($fixed)){throw 'The explicit native-CIM action array must be preserved.'}
$legacy=$definition.Replace($fixed,'$actions=if($task){@($task.Actions)}else{@()}').Replace('function PrepareManagers {','function PrepareManagersLegacy {')
$script:count=0
function AssertControl([bool]$Value){if(!$Value){throw ('Manager guard control failed at '+(@(Get-PSCallStack)[1].ScriptLineNumber))};$script:count++}
$root='C:\OpenWebPBX'
$script:ownerSid='S-1-5-21-1-2-3-500'
$script:realCim=$false
if($ExistingSid500Task){
 if($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5){throw 'The native-CIM control requires Windows PowerShell5.1.'}
 $script:ownerSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
 if($script:ownerSid -notmatch '-500$'){throw 'Only the existing administrator manager task may be read.'}
 # The only real scheduler operation in this control. Capture it before every
 # product-facing scheduler/CIM/process function is shadowed below.
 $script:originalTask=Get-ScheduledTask -TaskName ('OpenWebPBX-Manager-'+$script:ownerSid) -ErrorAction Stop
 $script:realCim=$true
}else{
 $action=[pscustomobject]@{Execute="$root\desktop\OpenWebPbx.Desktop.exe";WorkingDirectory="$root\desktop";Arguments=''}
 $script:originalTask=[pscustomobject]@{Actions=@($action);Principal=[pscustomobject]@{UserId=$script:ownerSid;LogonType='Interactive'}}
}
$script:taskValue=$script:originalTask;$script:mutationAttempts=0;$script:taskReads=0;$script:ownerReads=0
$script:ownedProcess=[pscustomobject]@{ProcessId=123;ExecutablePath="$root\desktop\OpenWebPbx.Desktop.exe"}
function InstalledManagers{return $script:ownedProcess}
function Invoke-CimMethod($InputObject,[string]$MethodName){
 if(![object]::ReferenceEquals($InputObject,$script:ownedProcess) -or $MethodName -cne 'GetOwnerSid'){throw 'An unexpected CIM operation was requested.'}
 $script:ownerReads++;return [pscustomobject]@{ReturnValue=0;Sid=$script:ownerSid}
}
function Get-ScheduledTask([string]$TaskName){
 if($TaskName -cne ('OpenWebPBX-Manager-'+$script:ownerSid)){throw 'A foreign task lookup was requested.'}
 $script:taskReads++;return $script:taskValue
}
function RefuseMutation {$script:mutationAttempts++;throw 'A real scheduler/process mutation is forbidden by this source control.'}
function New-ScheduledTaskPrincipal {RefuseMutation}
function New-ScheduledTaskAction {RefuseMutation}
function New-ScheduledTaskSettingsSet {RefuseMutation}
function Register-ScheduledTask {RefuseMutation}
function Set-ScheduledTask {RefuseMutation}
function Unregister-ScheduledTask {RefuseMutation}
function Start-ScheduledTask {RefuseMutation}
function Stop-ScheduledTask {RefuseMutation}
function Start-Process {RefuseMutation}
function Stop-Process {RefuseMutation}
Invoke-Expression $definition
Invoke-Expression $legacy
$script:managerTasks=@()
PrepareManagers
AssertControl ($script:managerTasks.Count -eq 1 -and $script:managerTasks[0] -ceq ('OpenWebPBX-Manager-'+$script:ownerSid))
AssertControl ($script:mutationAttempts -eq 0 -and $script:taskReads -eq 1 -and $script:ownerReads -eq 1)
if($script:realCim){
 $script:managerTasks=@();$legacyRefused=$false
 try{PrepareManagersLegacy}catch{$legacyRefused=$_.Exception.Message -ceq 'The manager could not be prepared to reopen. Close it before requesting installation again.'}
 AssertControl $legacyRefused
 AssertControl ($script:managerTasks.Count -eq 0 -and $script:mutationAttempts -eq 0)
 $scalar=if($script:originalTask){@($script:originalTask.Actions)}else{@()}
 AssertControl ($scalar -is [Microsoft.Management.Infrastructure.CimInstance] -and $null -eq $scalar.Count)
 AssertControl (@($script:originalTask.Actions).Count -eq 1)
}
foreach($case in 'wrong_sid','wrong_logon','wrong_command','wrong_working_directory','arguments','zero_actions','multiple_actions'){
 $action=[pscustomobject]@{Execute="$root\desktop\OpenWebPbx.Desktop.exe";WorkingDirectory="$root\desktop";Arguments=''}
 $principal=[pscustomobject]@{UserId=$script:ownerSid;LogonType='Interactive'}
 $actions=@($action)
 switch($case){
  'wrong_sid'{$principal.UserId='S-1-5-21-1-2-3-501'}
  'wrong_logon'{$principal.LogonType='ServiceAccount'}
  'wrong_command'{$action.Execute='C:\Unrelated\desktop.exe'}
  'wrong_working_directory'{$action.WorkingDirectory='C:\Unrelated'}
  'arguments'{$action.Arguments='--unrelated'}
  'zero_actions'{$actions=@()}
  'multiple_actions'{$actions=@($action,$action)}
 }
 $script:taskValue=[pscustomobject]@{Actions=$actions;Principal=$principal}
 $script:managerTasks=@();$before=$script:taskReads;$refused=$false
 try{PrepareManagers}catch{$refused=$_.Exception.Message -ceq 'The manager could not be prepared to reopen. Close it before requesting installation again.'}
 AssertControl $refused
 AssertControl ($script:managerTasks.Count -eq 0 -and $script:mutationAttempts -eq 0 -and $script:taskReads -eq $before+1)
}
# Repeat using the original real CIM task/actions after all rejected cases.
$script:taskValue=$script:originalTask;$script:managerTasks=@();PrepareManagers
AssertControl ($script:managerTasks.Count -eq 1 -and $script:mutationAttempts -eq 0)
[ordered]@{schema=1;state='passed';checks=$script:count;actual_native_cim=$script:realCim;existing_task_reads=$(if($script:realCim){1}else{0});all_product_calls_stubbed=$true;mutation_attempts=$script:mutationAttempts;legacy_cim_rejected=$(if($script:realCim){$true}else{$null});fixed_guard_passed=$true;invalid_contracts_rejected=7}|ConvertTo-Json -Compress
