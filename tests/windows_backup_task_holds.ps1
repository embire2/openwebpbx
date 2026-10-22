# Execute actual plan/hold/recovery functions against fictional task bindings.
# Native worker exclusion and Task Scheduler behavior require Windows acceptance.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$script:checks=0
function Check([bool]$Value){if(!$Value){throw ('Backup task hold control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'packaging/windows/Backup-Control.ps1'),[ref]$tokens,[ref]$errors)
Check ($errors.Count -eq 0)
foreach($name in 'services','certificateTasks','additionalTasks'){
 $nodes=@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -ceq ('$'+$name)})
 Check ($nodes.Count -eq 1);. ([scriptblock]::Create($nodes[0].Extent.Text))
}
foreach($name in 'Plan','ValidPlan','HoldSelection','Startup'){
 $nodes=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true))
 Check ($nodes.Count -eq 1);. ([scriptblock]::Create($nodes[0].Extent.Text))
}
function Import-Module([string]$Name){Check ($Name -ceq 'WebAdministration')}
function Get-Service([string]$Name){Check ($Name -cin $services.Values);return [pscustomobject]@{Status='Stopped'}}
function Get-CimInstance([string]$ClassName,[string]$Filter){Check ($ClassName -ceq 'Win32_Service');return [pscustomobject]@{StartMode='Manual'}}
function Set-Service([string]$Name,[string]$StartupType){Check ($Name -cin $services.Values -and $StartupType -cin 'Manual','Disabled')}
function Get-ScheduledTask {[CmdletBinding()]param([string]$TaskName);if($script:tasks.ContainsKey($TaskName)){return [pscustomobject]@{Settings=[pscustomobject]@{Enabled=$script:tasks[$TaskName]}}}}
function Enable-ScheduledTask([string]$TaskName){Check ($script:tasks.ContainsKey($TaskName));$script:taskActions.Add('enable:'+$TaskName);$script:tasks[$TaskName]=$true}
function Disable-ScheduledTask([string]$TaskName){Check ($script:tasks.ContainsKey($TaskName));$script:taskActions.Add('disable:'+$TaskName);$script:tasks[$TaskName]=$false}
function Get-Website([string]$Name){return [pscustomobject]@{State='Stopped'}}
function Get-WebAppPoolState([string]$Name){return [pscustomobject]@{Value='Stopped'}}
function Get-ItemProperty([string]$Path,[string]$Name){return [pscustomobject]@{serverAutoStart=$false;autoStart=$false}}
function Set-ItemProperty([string]$Path,[string]$Name,$Value){Check ($Value -is [bool] -and !$Value)}
foreach($health in 'enabled','disabled','absent'){
 $script:tasks=@{'OpenWebPBX-Backups'=$true;'OpenWebPBX-Cleanup'=$true;'OpenWebPBX Outgoing Mail'=$true;'OpenWebPBX-TenantDomains'=$false;'Unrelated task'=$true}
 if($health -cne 'absent'){$script:tasks['OpenWebPBX-PhoneHealth']=($health -ceq 'enabled')}
 $script:taskActions=[Collections.Generic.List[string]]::new()
 $original=@{};foreach($key in $tasks.Keys){$original[$key]=$tasks[$key]}
 $plan=Plan|ConvertTo-Json -Depth 8|ConvertFrom-Json
 if($health -ceq 'absent'){Check ($null -eq $plan.additional_tasks.PSObject.Properties['OpenWebPBX-PhoneHealth'])}
 else{Check ($plan.additional_tasks.'OpenWebPBX-PhoneHealth' -is [bool] -and $plan.additional_tasks.'OpenWebPBX-PhoneHealth' -ceq ($health -ceq 'enabled'))}
 Check ($null -eq $plan.additional_tasks.PSObject.Properties['Unrelated task'])
 HoldSelection 'jobs'
 foreach($name in 'OpenWebPBX-Cleanup','OpenWebPBX Outgoing Mail','OpenWebPBX-TenantDomains'){Check (!$tasks[$name])}
 if($health -cne 'absent'){Check (!$tasks['OpenWebPBX-PhoneHealth'])}
 Startup $plan
 foreach($key in $original.Keys){Check ($tasks[$key] -ceq $original[$key])}
 Check (@($taskActions|Where-Object {$_ -match 'Unrelated'}).Count -eq 0)
 if($health -ceq 'absent'){Check (@($taskActions|Where-Object {$_ -match 'PhoneHealth'}).Count -eq 0)}
 foreach($value in 'private',1,@(),$null){
  $bad=$plan|ConvertTo-Json -Depth 8|ConvertFrom-Json
  $bad.additional_tasks|Add-Member -Force -NotePropertyName 'OpenWebPBX-PhoneHealth' -NotePropertyValue $value
  $caught=$false;try{ValidPlan $bad}catch{$caught=$true};Check $caught
 }
 $bad=$plan|ConvertTo-Json -Depth 8|ConvertFrom-Json
 $bad.additional_tasks|Add-Member -NotePropertyName 'Unrelated task' -NotePropertyValue $true
 $caught=$false;try{ValidPlan $bad}catch{$caught=$true};Check $caught
}
Write-Output ('PASS '+$checks+' actual backup plan/hold/recovery task choice and foreign/type refusal controls; native workers not executed')
