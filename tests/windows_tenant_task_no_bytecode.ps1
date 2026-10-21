[CmdletBinding()]
param([string]$InstallerPath='')
if(!$InstallerPath){$InstallerPath=Join-Path (Split-Path $PSScriptRoot -Parent) 'packaging/windows/Install-TenantDomains.ps1'}
$ErrorActionPreference='Stop';$checks=0
function Check([bool]$Value){if(!$Value){throw 'Tenant worker task ownership control failed.'};$script:checks++}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($InstallerPath,[ref]$tokens,[ref]$errors)
Check ($errors.Count -eq 0)
$guards=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.Contains("throw 'The tenant-domain task belongs to another configuration.'")},$true))
Check ($guards.Count -eq 1)
$guard=[scriptblock]::Create(('param($existing,$root,$description)' + "`n" + $guards[0].Extent.Text + "`n" + 'return $true'))
$actions=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left -is [Management.Automation.Language.VariableExpressionAst] -and $node.Left.VariablePath.UserPath -ceq 'action'},$true))
Check ($actions.Count -eq 1)
$root='C:\OpenWebPBX';$description='OpenWeb PBX owned tenant HTTPS lease worker'
$old='-I "C:\OpenWebPBX\tools\tenant-domains.py"';$new='-I -B "C:\OpenWebPBX\tools\tenant-domains.py"'
function OwnedTask([string]$Arguments){return [pscustomobject]@{Description=$description;Principal=[pscustomobject]@{UserId='SYSTEM'};Actions=@([pscustomobject]@{Execute="$root\backup-runtime\python.exe";Arguments=$Arguments;WorkingDirectory="$root\tools"});Settings=[pscustomobject]@{Enabled=$true}}}
function Accepts($Task){try{return [bool](& $guard $Task $root $description)}catch{return $false}}
Check (Accepts $null)
foreach($argsText in $old,$new){
 $task=OwnedTask $argsText;Check (Accepts $task)
 $task.Principal.UserId='S-1-5-18';Check (Accepts $task)
 $task.Settings.Enabled=$false;Check (Accepts $task)
}
foreach($bad in '-I -B unowned.py','-B -I "C:\OpenWebPBX\tools\tenant-domains.py"',($new+' --extra'),($old+' '),' -I "C:\OpenWebPBX\tools\tenant-domains.py"','-I -B "C:\OpenWebPBX\tools\other.py"'){Check (!(Accepts (OwnedTask $bad)))}
foreach($field in 'description','principal','execute','directory','count'){
 $task=OwnedTask $old
 switch($field){description{$task.Description='Foreign task'}principal{$task.Principal.UserId='S-1-5-32-544'}execute{$task.Actions[0].Execute='C:\Other\python.exe'}directory{$task.Actions[0].WorkingDirectory='C:\Other'}count{$task.Actions+=,$task.Actions[0]}}
 Check (!(Accepts $task))
}
function New-ScheduledTaskAction([string]$Execute,[string]$Argument,[string]$WorkingDirectory){[pscustomobject]@{Execute=$Execute;Argument=$Argument;WorkingDirectory=$WorkingDirectory}}
$created=& ([scriptblock]::Create(('param($root)' + "`n" + $actions[0].Extent.Text + "`n" + 'return $action'))) $root
Check ($created.Execute -ceq "$root\backup-runtime\python.exe" -and $created.Argument -ceq $new -and $created.WorkingDirectory -ceq "$root\tools")
$disabled=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.Contains('Disable-ScheduledTask -TaskName $name')},$true))
Check ($disabled.Count -eq 1)
$disable=[scriptblock]::Create(('param($DeferStart,$existing,$name)' + "`n" + $disabled[0].Extent.Text))
function Disable-ScheduledTask([string]$TaskName){$script:disabledTask=$TaskName}
foreach($enabled in $false,$true){foreach($defer in $false,$true){$script:disabledTask=$null;$task=OwnedTask $old;$task.Settings.Enabled=$enabled;& $disable $defer $task 'OpenWebPBX-TenantDomains';Check (($null -ne $disabledTask) -eq ($defer -or !$enabled));if($disabledTask){Check ($disabledTask -ceq 'OpenWebPBX-TenantDomains')}}}
Write-Host ("Tenant task exact legacy/new ownership and enabled-state controls passed: "+$checks)
