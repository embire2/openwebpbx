param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest;$script:checks=0
function Check([bool]$ok){if(!$ok){throw ('Catalogue lifecycle control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
function Refused([scriptblock]$work){$caught=$false;try{& $work}catch{$caught=$true};Check $caught}
$tokens=$null;$errors=$null;$tree=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'packaging/windows/WindowsPhoneCatalogue.Common.ps1'),[ref]$tokens,[ref]$errors);Check ($errors.Count -eq 0)
foreach($name in 'Get-OpenWebWindowsPhoneCatalogueTaskHash','Assert-OpenWebWindowsPhoneCatalogueTask'){
 $nodes=@($tree.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));Check ($nodes.Count -eq 1);Invoke-Expression $nodes[0].Extent.Text
}
$script:WindowsPhoneCatalogueTask='OpenWebPBX-WindowsPhoneCatalogue'
$script:xml='<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Triggers><TimeTrigger><Repetition><Interval>PT6H</Interval></Repetition></TimeTrigger><BootTrigger/></Triggers><Principals><Principal><UserId>S-1-5-18</UserId></Principal></Principals><Settings><Enabled>true</Enabled><ExecutionTimeLimit>PT2M</ExecutionTimeLimit></Settings><Actions><Exec><Command>fixed-protected-program</Command></Exec></Actions></Task>'
$hash=Get-OpenWebWindowsPhoneCatalogueTaskHash $script:xml
Check ($hash -cmatch '^[a-f0-9]{64}$')
Check ((Get-OpenWebWindowsPhoneCatalogueTaskHash $script:xml.Replace('<Enabled>true</Enabled>','<Enabled>false</Enabled>')) -ceq $hash)
foreach($pair in @(@('PT6H','PT1M'),@('PT2M','PT24H'),@('S-1-5-18','S-1-5-19'),@('fixed-protected-program','foreign-program'))){Check ((Get-OpenWebWindowsPhoneCatalogueTaskHash $script:xml.Replace($pair[0],$pair[1])) -cne $hash)}
foreach($bad in '<Task/>',$script:xml.Replace('<Enabled>true</Enabled>','<Enabled>1</Enabled>'),$script:xml.Replace('<Enabled>true</Enabled>','<Enabled>true</Enabled><Enabled>true</Enabled>'),'<!DOCTYPE Task [<!ENTITY x SYSTEM "https://invalid.example/private">]><Task>&x;</Task>'){Refused {Get-OpenWebWindowsPhoneCatalogueTaskHash $bad|Out-Null}}
# Actual task guard, with explicit Task Scheduler/ACL/CIM adapters only.
$paths=[pscustomobject]@{PowerShell='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe';Runner='C:\OpenWebPBX\tools\WindowsPhoneCatalogue.ps1';Directory=$PSScriptRoot}
$expected='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$paths.Runner+'" -Action Refresh'
$original=[pscustomobject]@{TaskPath='\';State='Ready';Actions=@([pscustomobject]@{Execute=$paths.PowerShell;Arguments=$expected});Principal=[pscustomobject]@{UserId='SYSTEM';LogonType='ServiceAccount';RunLevel='Highest'};Settings=[pscustomobject]@{Enabled=$true}}
$script:security='FICTIONAL-EXACT-SCHEDULER-DESCRIPTOR';$script:proof=[pscustomobject]@{schema=1;component='windows-free-phone';definition_sha256=$hash;security=$script:security};$script:proofReads=0
function Assert-OpenWebRecoveryProtected([string]$Path){return $Path}
function Get-Content {param([string]$LiteralPath,[switch]$Raw,[string]$Encoding)$script:proofReads++;return($script:proof|ConvertTo-Json -Compress)}
function Export-ScheduledTask {param([string]$TaskName)return $script:xml}
$native=[pscustomobject]@{};$native|Add-Member ScriptMethod GetSecurityDescriptor {param($n)return $script:security}
$folder=[pscustomobject]@{Native=$native};$folder|Add-Member ScriptMethod GetTask {param($n)return $this.Native}
$scheduler=[pscustomobject]@{Folder=$folder};$scheduler|Add-Member ScriptMethod Connect {};$scheduler|Add-Member ScriptMethod GetFolder {param($n)return $this.Folder}
function New-Object {param([string]$ComObject)if($ComObject -cne 'Schedule.Service'){throw 'Unexpected adapter'};return $scheduler}
Assert-OpenWebWindowsPhoneCatalogueTask $original $paths;Check ($script:proofReads -eq 1)
$disabled=$original|ConvertTo-Json -Depth 8|ConvertFrom-Json;$disabled.Settings.Enabled=$false;$script:xml=$script:xml.Replace('<Enabled>true</Enabled>','<Enabled>false</Enabled>');Assert-OpenWebWindowsPhoneCatalogueTask $disabled $paths;Check $true;$script:xml=$script:xml.Replace('<Enabled>false</Enabled>','<Enabled>true</Enabled>')
foreach($kind in 'principal','runlevel','logon','path','program','arguments','multiple','choice','running_disabled'){
 $task=$original|ConvertTo-Json -Depth 8|ConvertFrom-Json
 switch($kind){principal{$task.Principal.UserId='S-1-5-19'}runlevel{$task.Principal.RunLevel='Limited'}logon{$task.Principal.LogonType='Interactive'}path{$task.TaskPath='\foreign\'}program{$task.Actions[0].Execute='C:\foreign.exe'}arguments{$task.Actions[0].Arguments+=' --foreign'}multiple{$task.Actions+=@($task.Actions[0])}choice{$task.Settings.Enabled='true'}running_disabled{$task.Settings.Enabled=$false;$task.State='Running'}}
 $before=$script:proofReads;Refused {Assert-OpenWebWindowsPhoneCatalogueTask $task $paths};Check ($before -eq $script:proofReads)
}
$script:xml=$script:xml.Replace('PT6H','PT1M');Refused {Assert-OpenWebWindowsPhoneCatalogueTask $original $paths};$script:xml=$script:xml.Replace('PT1M','PT6H')
$script:security='CHANGED-FICTIONAL-DESCRIPTOR';Refused {Assert-OpenWebWindowsPhoneCatalogueTask $original $paths}
$script:security=$script:proof.security;$script:proof.schema=$true;Refused {Assert-OpenWebWindowsPhoneCatalogueTask $original $paths}
Write-Output ('PASS '+$script:checks+' actual catalogue XML/task ownership controls; Scheduler/ACL adapters explicit, no task or installed state changed')
