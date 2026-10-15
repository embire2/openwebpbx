#Requires -Version 5.1
[CmdletBinding()]
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent),[string]$ChildOutput='')
$ErrorActionPreference='Stop';$t=$null;$e=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-suite.ps1'),[ref]$t,[ref]$e)
if($e.Count){throw 'The exact suite source must parse.'}
$nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.Extent.Text.Contains('Stop-WebAppPool OpenWebPBX') -and $n.Extent.Text.Contains('-Command')},$true))
if($nodes.Count -ne 1 -or $nodes[0].CommandElements[-1] -isnot [Management.Automation.Language.StringConstantExpressionAst]){throw 'The exact native cleanup child must be unique.'}
$command=$nodes[0].CommandElements[-1].Value
if($ChildOutput){[IO.File]::WriteAllText($ChildOutput,$command,[Text.UTF8Encoding]::new($false))}
$script:checks=0
function Check([bool]$Value){if(!$Value){throw ('IIS cleanup control failed at '+(@(Get-PSCallStack)[1].ScriptLineNumber))};$script:checks++}
$script:poolPresent=$true;$script:sitePresent=$true;$script:state='Stopped';$script:stopCalls=0;$script:siteCalls=0;$script:stopFails=$false;$script:stopChanges=$true
function Test-Path([string]$Path){if($Path -like '*WebAdministration.psd1'){return $true};if($Path -ceq 'IIS:\Sites\OpenWebPBX'){return $script:sitePresent};if($Path -ceq 'IIS:\AppPools\OpenWebPBX'){return $script:poolPresent};throw 'A foreign provider path was queried.'}
function Import-Module([string]$Name){if($Name -cne 'WebAdministration'){throw 'A foreign module was requested.'}}
function Stop-Website([string]$Name){if($Name -cne 'OpenWebPBX'){throw 'A foreign site was targeted.'};$script:siteCalls++}
function Get-WebAppPoolState([string]$Name){if($Name -cne 'OpenWebPBX'){throw 'A foreign pool was queried.'};return [pscustomobject]@{Value=$script:state}}
function Stop-WebAppPool([string]$Name){if($Name -cne 'OpenWebPBX'){throw 'A foreign pool was targeted.'};$script:stopCalls++;if($script:stopFails){throw 'The actual stop failure must propagate.'};if($script:stopChanges){$script:state='Stopped'}}
$prior=$env:PSModulePath
try{
 foreach($initial in 'Stopped','Started'){
  $script:state=$initial;$script:stopCalls=0;$script:siteCalls=0
  Invoke-Expression $command
  Check ($script:state -ceq 'Stopped' -and $script:siteCalls -eq 1)
  Check ($script:stopCalls -eq $(if($initial -eq 'Started'){1}else{0}))
  Invoke-Expression $command
  Check ($script:state -ceq 'Stopped' -and $script:siteCalls -eq 2)
  Check ($script:stopCalls -eq $(if($initial -eq 'Started'){1}else{0}))
 }
 foreach($unknown in 'Starting','Stopping','Unknown','',42){
  $script:state=$unknown;$script:stopCalls=0;$refused=$false
  try{Invoke-Expression $command}catch{$refused=$_.Exception.Message -ceq 'Owned pool cleanup found an unexpected state.'}
  Check ($refused -and $script:stopCalls -eq 0)
 }
 $script:state='Started';$script:stopFails=$true;$refused=$false
 try{Invoke-Expression $command}catch{$refused=$_.Exception.Message -ceq 'The actual stop failure must propagate.'}
 Check $refused
 $script:stopFails=$false;$script:stopChanges=$false;$refused=$false
 try{Invoke-Expression $command}catch{$refused=$_.Exception.Message -ceq 'Owned pool cleanup did not stop.'}
 Check $refused
 $script:poolPresent=$false;$script:sitePresent=$false;$script:stopCalls=0;$script:siteCalls=0
 Invoke-Expression $command
 Check ($script:stopCalls -eq 0 -and $script:siteCalls -eq 0)
}finally{$env:PSModulePath=$prior}
Write-Output ('PASS '+$script:checks+' exact native-child pool state/idempotence/refusal/postcondition controls; no IIS contacted')
