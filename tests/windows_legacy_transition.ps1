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
$serviceGuard=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Assert-OpenWebLegacyUpdater'},$true))
if($serviceGuard.Count -ne 1){throw 'The actual owned legacy updater guard is required.'}
Invoke-Expression $serviceGuard[0].Extent.Text
$ownedRoot=Join-Path ([IO.Path]::GetTempPath()) 'legacy-owned-pbx'
$installed=[pscustomobject]@{Version='1.0.6';Completed=$true}
$exe=Join-Path $ownedRoot 'updater\slots\1.0.6\OpenWebPbx.Updater.exe'
foreach($account in 'LocalSystem','NT AUTHORITY\SYSTEM'){
 foreach($phase in 'Running','Stopped'){
  Assert-OpenWebLegacyUpdater -Installation $installed -Updater ([pscustomobject]@{Version='1.0.6';Executable=$exe}) -Service ([pscustomobject]@{PathName='"'+$exe+'"';StartName=$account;StartMode='Auto';State=$phase}) -Root $ownedRoot;$checks++
 }
}
foreach($change in @('Version','1.0.7'),@('Executable','foreign.exe'),@('PathName','foreign.exe'),@('StartName','Administrator'),@('StartMode','Manual'),@('StartMode','Disabled'),@('State','Start Pending')){
 $metadata=[pscustomobject]@{Version='1.0.6';Executable=$exe};$service=[pscustomobject]@{PathName='"'+$exe+'"';StartName='LocalSystem';StartMode='Auto';State='Stopped'}
 if($change[0] -cin 'Version','Executable'){$metadata.($change[0])=$change[1]}else{$service.($change[0])=$change[1]}
 $refused=$false;try{Assert-OpenWebLegacyUpdater -Installation $installed -Updater $metadata -Service $service -Root $ownedRoot}catch{$refused=$true}
 if(!$refused){throw 'A missing, foreign or non-automatic legacy updater was accepted.'};$checks++
}
$configNode=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'New-OpenWebLegacyVerifierConfiguration'},$true))
if($configNode.Count -ne 1){throw 'The actual isolated verification configuration is required.'}
Invoke-Expression $configNode[0].Extent.Text
$folder=Join-Path ([IO.Path]::GetTempPath()) ('legacy-verifier-'+[guid]::NewGuid().ToString('N'))
$state=Join-Path $folder 'original';$transition=Join-Path $folder 'transition'
foreach($runtime in @{
 ConnectionStrings=@{Pbx='fixture connection retained'}
 Updater=@{DataDirectory='original-live-updates';InstalledVersionPath='old-override';Helper='original-helper';PublicStatus='original-status';Custom='retained'}
 Other=@{Enabled=$false;Count=7}
},@{ConnectionStrings=@{Pbx='fixture connection retained'}}){
 $before=$runtime|ConvertTo-Json -Depth 20 -Compress
 $isolated=New-OpenWebLegacyVerifierConfiguration -RuntimeJson $before -Transition $transition -StateRoot $state|ConvertFrom-Json
 foreach($pair in @(@('DataDirectory',(Join-Path $transition 'verifier-state')),@('PublicStatus',(Join-Path $transition 'verifier-status.json')),@('InstalledVersionPath',(Join-Path $state 'installation.json')))){
  if($isolated.Updater.($pair[0]) -cne $pair[1]){throw 'Legacy verifier context escaped its private data or actual installed version.'};$checks++
 }
 if($isolated.ConnectionStrings.Pbx -cne 'fixture connection retained'){throw 'Runtime connection metadata must be retained.'};$checks++
 if($before -cne ($runtime|ConvertTo-Json -Depth 20 -Compress)){throw 'The input runtime object was changed.'};$checks++
 if($runtime.ContainsKey('Updater')){
  if($isolated.Updater.Helper -cne 'original-helper' -or $isolated.Updater.Custom -cne 'retained' -or $isolated.Other.Enabled -isnot [bool] -or $isolated.Other.Enabled -or $isolated.Other.Count -ne 7){throw 'Unrelated private runtime settings changed.'};$checks++
 }
}
foreach($bad in '[]','null','false','"runtime"','{"Updater":null}','{"Updater":false}','{"Updater":[]}','{"Updater":"settings"}'){
 $refused=$false;try{$null=New-OpenWebLegacyVerifierConfiguration -RuntimeJson $bad -Transition $transition -StateRoot $state}catch{$refused=$true}
 if(!$refused){throw 'Malformed runtime configuration was accepted.'};$checks++
}
$deep=[pscustomobject]@{Value='leaf'};for($i=0;$i -lt 25;$i++){$deep=[pscustomobject]@{Child=$deep}}
$deepJson=([pscustomobject]@{Other=$deep}|ConvertTo-Json -Depth 40 -Compress)
$refused=$false;try{$null=New-OpenWebLegacyVerifierConfiguration -RuntimeJson $deepJson -Transition $transition -StateRoot $state}catch{$refused=$true}
if(!$refused){throw 'Deep runtime settings must refuse rather than silently truncate.'};$checks++
$isolate=$text.IndexOf('$env:OPENWEBPBX_CONFIG=$verifierConfig');$reset=$text.IndexOf('$env:OPENWEBPBX_CONFIG=$previousConfig')
if($isolate -lt 0 -or $isolate -gt $verify -or $reset -lt $text.IndexOf('}finally{') -or $text.IndexOf('$previousConfig=$env:OPENWEBPBX_CONFIG') -gt $isolate){throw 'The explicit verifier environment must be scoped and restored on every outcome.'};$checks++
Write-Output "PASS: $checks actual legacy upgrade/configuration boundaries; installed verifier precedes service mutation and ordinary feed trust remains separate."
