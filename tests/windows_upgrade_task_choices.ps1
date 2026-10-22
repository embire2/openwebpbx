# Actual upgrade success block with fictional Task Scheduler bindings.
# These controls do not install or change a Windows task.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$script:checks=0
function Check([bool]$Value){if(!$Value){throw ('Background task-choice control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'packaging/windows/Upgrade-OpenWebPBX.ps1'),[ref]$tokens,[ref]$errors)
Check ($errors.Count -eq 0)
$nodes=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.ForEachStatementAst] -and $node.Extent.Text.Contains('$originalSupport.Tasks.PSObject.Properties[$name]')},$true))
Check ($nodes.Count -eq 1)
$actual=[scriptblock]::Create($nodes[0].Extent.Text)
$names=@('OpenWebPBX-Backups','OpenWebPBX Outgoing Mail','OpenWebPBX-TenantDomains','OpenWebPBX-PhoneHealth')
function Enable-ScheduledTask([string]$TaskName){$script:actions.Add('enable:'+$TaskName)}
function Disable-ScheduledTask([string]$TaskName){$script:actions.Add('disable:'+$TaskName)}
function Start-ScheduledTask([string]$TaskName){$script:actions.Add('start:'+$TaskName)}
$choices=@('missing','new','enabled','disabled')
foreach($backup in $choices){foreach($mail in $choices){foreach($domain in $choices){foreach($health in $choices){
 $tasks=@{};$expected=@();$values=@($backup,$mail,$domain,$health)
 for($i=0;$i -lt $names.Count;$i++){
  $value=$values[$i];$name=$names[$i]
  if($value -cne 'missing'){$tasks[$name]=@{Exists=($value -cne 'new');Enabled=($value -ceq 'enabled')}}
  $expected+=($(if($value -ceq 'disabled'){'disable:'}else{'enable:'})+$name)
  if($name -ceq 'OpenWebPBX-PhoneHealth' -and $value -cne 'disabled'){$expected+='start:'+$name}
 }
 $originalSupport=@{Tasks=$tasks}|ConvertTo-Json -Depth 5|ConvertFrom-Json
 $script:actions=[Collections.Generic.List[string]]::new()
 . $actual
 Check (($actions -join '|') -ceq ($expected -join '|'))
 Check ($actions.Count -eq $(if($health -ceq 'disabled'){4}else{5}))
}}}}
foreach($field in 'Exists','Enabled'){
 foreach($value in $null,1,'true',@(),@{private='UNPUBLISHED_PRIVATE_VALUE'}){
  $record=@{Exists=$true;Enabled=$true};$record[$field]=$value
  $originalSupport=@{Tasks=@{'OpenWebPBX-Backups'=$record}}|ConvertTo-Json -Depth 8|ConvertFrom-Json
  $script:actions=[Collections.Generic.List[string]]::new();$caught=$null
  try{. $actual}catch{$caught=$_.Exception.Message}
  Check ($caught -ceq 'The original background-task enabled choice is invalid.')
  Check ($actions.Count -eq 0)
  Check (!$caught.Contains('UNPUBLISHED_PRIVATE_VALUE'))
 }
 $record=@{Exists=$true;Enabled=$true};$record.Remove($field)
 $originalSupport=@{Tasks=@{'OpenWebPBX-Backups'=$record}}|ConvertTo-Json -Depth 5|ConvertFrom-Json
 $script:actions=[Collections.Generic.List[string]]::new();$caught=$null
 try{. $actual}catch{$caught=$_.Exception.Message}
 Check ($caught -ceq 'The original background-task enabled choice is invalid.' -and $actions.Count -eq 0)
}
# A foreign task in the support inventory must never become a command target.
$originalSupport='{"Tasks":{"Unrelated task":{"Exists":true,"Enabled":false}}}'|ConvertFrom-Json
$script:actions=[Collections.Generic.List[string]]::new();. $actual
Check ($actions.Count -eq 5 -and @($actions|Where-Object {$_ -match 'Unrelated'}).Count -eq 0)
Write-Output ('PASS '+$checks+' actual upgrade task-choice combinations, malformed-record refusals and foreign-task isolation; no Windows task changed')
