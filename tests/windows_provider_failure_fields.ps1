# Actual native-child and outer-suite projection functions; no service access.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$checks=0
function Check([bool]$Value){if(!$Value){throw ('Provider projection control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-suite.ps1'),[ref]$tokens,[ref]$errors)
Check ($errors.Count -eq 0)
# Function definitions are parsed, then invoked only as closed projections.
foreach($node in $ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){Invoke-Expression $node.Extent.Text}
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-native-acceptance.ps1'),[ref]$tokens,[ref]$errors)
Check ($errors.Count -eq 0)
$node=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'ProviderFailureFields'},$true));Check ($node.Count -eq 1);Invoke-Expression $node[0].Extent.Text
$record=[pscustomobject]@{active_case='native_provider_100';provider_caller_response_code=488;password='PRIVATE_NEVER_PUBLISH';raw_sip='PRIVATE_NEVER_PUBLISH'}
foreach($phase in 'before','after'){foreach($peer in 'primary','backup'){
 $prefix='provider_'+$phase+'_'+$peer+'_'
 foreach($suffix in 'gateway_observed','counts_capped','offer_parsed','offer_pcmu','offer_pcma','receiver_failed','receiver_alive'){$record|Add-Member ($prefix+$suffix) $true}
 foreach($suffix in 'invites','distinct_calls'){$record|Add-Member ($prefix+$suffix) 1}
 $record|Add-Member ($prefix+'last_response_code') 488
 $record|Add-Member ($prefix+'gateway_status') 'UP';$record|Add-Member ($prefix+'gateway_state') 'NOREG'
}}
foreach($filter in 'ProviderFailureFields','SafeFailureFields'){
 $result=& $filter $record
 Check (($result|ConvertTo-Json -Depth 5) -notmatch 'PRIVATE|password|raw_sip')
 foreach($field in $record.PSObject.Properties.Name|Where-Object {$_ -like 'provider_*'}){Check ($result[$field] -ceq $record.$field)}
 foreach($field in $record.PSObject.Properties.Name|Where-Object {$_ -like 'provider_*'}){
  $badValues=if($field -match 'response_code$'){@('488',$true,-1,99,700)}elseif($field -match 'gateway_status$'){@('up','PRIVATE',1,$true)}elseif($field -match 'gateway_state$'){@('noreg','PRIVATE',1,$true)}elseif($field -match 'invites$|distinct_calls$'){@('1',$true,-1,65)}else{@('true',1,$null)}
  foreach($bad in $badValues){$copy=$record.PSObject.Copy();$copy.$field=$bad;Check (!(& $filter $copy).ContainsKey($field))}
 }
 foreach($bad in 'native_provider_104','native_provider_100 ','NATIVE_PROVIDER_100','private_unknown',$null){$copy=$record.PSObject.Copy();$copy.active_case=$bad;$result=& $filter $copy;Check (@($result.Keys|Where-Object {$_ -like 'provider_*'}).Count -eq 0)}
}
"PASS $checks actual native-provider closed status/count/codec/privacy/type projection controls; no PBX invoked"
