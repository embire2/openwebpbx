# Actual released-helper boundary: no verifier, files, tasks or services invoked.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$checks=0
$path=Join-Path $SourceRoot 'packaging/windows/Upgrade-LegacyWindows.ps1'
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The legacy helper does not parse.'}
$node=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Assert-OpenWebLegacyTransition'},$true))
if($node.Count -ne 1){throw 'The actual legacy transition guard is required.'}
Invoke-Expression $node[0].Extent.Text
function CheckCase($Installed,$Complete,[string]$Target,[bool]$Allowed){
 $passed=$true;try{Assert-OpenWebLegacyTransition ([pscustomobject]@{Version=$Installed;Completed=$Complete}) $Target}catch{$passed=$false}
 if($passed -ne $Allowed){throw 'Legacy signed-transition boundary failed.'};$script:checks++
}
foreach($old in '1.0.3','1.0.4','1.0.5','1.0.6','1.0.7'){
 foreach($new in '1.0.20','1.0.21','1.0.100','1.1.0','2.0.0'){CheckCase $old $true $new $true}
 foreach($bad in '','1.0.13','1.0.19','0.9.99','1.0.020','1.0.20.0','v1.0.20','1.0.20-preview','1.0.20 ','9999999999.0.0'){CheckCase $old $true $bad $false}
 foreach($complete in $false,$null,'true','false',1){CheckCase $old $complete '1.0.20' $false}
}
foreach($old in '1.0.2','1.0.8','1.0.13','1.0.20','1.0.06','', $null){CheckCase $old $true '1.0.20' $false}
$text=Get-Content -LiteralPath $path -Raw
$verify=$text.IndexOf('--verify-package');$stop=$text.IndexOf('Stop-Service OpenWebPBXUpdater')
if($verify -lt 0 -or $stop -le $verify -or $text.IndexOf('Assert-OpenWebLegacyTransition $installation $TargetVersion') -gt $verify){throw 'The installed signature verifier must succeed before a service stops.'}
$checks++
Write-Output "PASS: $checks actual legacy upgrade boundaries; installed verifier precedes service mutation."
