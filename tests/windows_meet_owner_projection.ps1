#Requires -Version 5.1
<# Portable controls execute only the two actual AST report projectors. Inputs
are fictional; no installed service, browser, network, or database is used. #>
[CmdletBinding()]
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
$script:checks=0
function Check([bool]$Value){
 if(!$Value){throw ('A meeting-owner projection control failed at test line '+(Get-PSCallStack)[1].ScriptLineNumber+'.')}
 $script:checks++
}
$definitions=@{}
foreach($source in @(
 @{Path='tests/windows-native-acceptance.ps1';Name='MeetingOwnerPageFields'},
 @{Path='tests/windows-suite.ps1';Name='SafeMeetingOwnerPageFields'}
)){
 $tokens=$null;$errors=$null
 $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot $source.Path),[ref]$tokens,[ref]$errors)
 Check ($errors.Count -eq 0)
 $nodes=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $source.Name},$true))
 Check ($nodes.Count -eq 1)
 $definitions[$source.Name]=$nodes[0].Extent.Text
}
# Preserve every byte after the function name, including whitespace and comments.
$nativePrefix='function MeetingOwnerPageFields'
$suitePrefix='function SafeMeetingOwnerPageFields'
Check ($definitions.MeetingOwnerPageFields.StartsWith($nativePrefix,[StringComparison]::Ordinal))
Check ($definitions.SafeMeetingOwnerPageFields.StartsWith($suitePrefix,[StringComparison]::Ordinal))
$nativeBytes=[Text.Encoding]::UTF8.GetBytes($definitions.MeetingOwnerPageFields.Substring($nativePrefix.Length))
$suiteBytes=[Text.Encoding]::UTF8.GetBytes($definitions.SafeMeetingOwnerPageFields.Substring($suitePrefix.Length))
Check ([Convert]::ToBase64String($nativeBytes) -ceq [Convert]::ToBase64String($suiteBytes))
foreach($name in 'MeetingOwnerPageFields','SafeMeetingOwnerPageFields'){Invoke-Expression $definitions[$name]}

$booleanFields=@('meeting_owner_login_form','meeting_owner_heading','meeting_owner_same_origin','meeting_owner_user_agent_matches')
$safeFields=@('meeting_owner_http_status','meeting_owner_route')+$booleanFields
$expectedKeys=($safeFields|Sort-Object)-join '|'
function New-Record([string]$Kind){
 $record=@{
  active_case='native_windows_meeting_owner_page';meeting_owner_http_status=200;meeting_owner_route='meet'
  meeting_owner_login_form=$false;meeting_owner_heading=$true
  meeting_owner_same_origin=$true;meeting_owner_user_agent_matches=$true
 }
 if($Kind -ceq 'object'){return [pscustomobject]$record}
 if($Kind -ceq 'ordered'){return [ordered]@{}+$record}
 return $record
}
function Set-Field($Record,[string]$Field,$Value){
 if($Record -is [Collections.IDictionary]){$Record[$Field]=$Value}
 elseif($Record.PSObject.Properties[$Field]){$Record.$Field=$Value}
 else{$Record|Add-Member -NotePropertyName $Field -NotePropertyValue $Value}
}
function Remove-Field($Record,[string]$Field){
 if($Record -is [Collections.IDictionary]){$null=$Record.Remove($Field)}
 else{$Record.PSObject.Properties.Remove($Field)}
}
function Invoke-Projection([string]$Name,$Record){
 $before=$Record|ConvertTo-Json -Depth 8 -Compress
 $outputs=@(& $Name $Record)
 Check ($outputs.Count -eq 1 -and $outputs[0] -is [Collections.IDictionary])
 Check (($Record|ConvertTo-Json -Depth 8 -Compress) -ceq $before)
 return $outputs[0]
}
function Check-Valid([string]$Name,$Record){
 $safe=Invoke-Projection $Name $Record
 Check ($safe.Count -eq 6 -and (($safe.Keys|Sort-Object)-join '|') -ceq $expectedKeys)
 Check ($safe.meeting_owner_http_status -is [int] -and $safe.meeting_owner_http_status -eq $Record.meeting_owner_http_status)
 Check ($safe.meeting_owner_route -is [string] -and $safe.meeting_owner_route -ceq $Record.meeting_owner_route)
 foreach($field in $booleanFields){Check ($safe[$field] -is [bool] -and $safe[$field] -eq $Record.$field)}
 Check (($safe|ConvertTo-Json -Depth 8 -Compress) -notmatch 'PRIVATE_FIXTURE')
}
function Check-Refused([string]$Name,$Record){
 $safe=Invoke-Projection $Name $Record
 Check ($safe.Count -eq 0)
}

foreach($name in 'MeetingOwnerPageFields','SafeMeetingOwnerPageFields'){
 foreach($kind in 'dictionary','ordered','object'){
  $record=New-Record $kind
  Check (($kind -ceq 'object' -and $record -is [pscustomobject]) -or ($kind -cne 'object' -and $record -is [Collections.IDictionary]))
  Check-Valid $name $record
  # Every route and every combination of the four Boolean observations survives.
  foreach($route in 'meet','login','logout','desktop','other'){
   foreach($mask in 0..15){
    $record=New-Record $kind;Set-Field $record 'meeting_owner_route' $route
    for($index=0;$index -lt $booleanFields.Count;$index++){Set-Field $record $booleanFields[$index] ([bool]($mask -band (1 -shl $index)))}
    Check-Valid $name $record
   }
  }
  foreach($status in 0,1,199,200,302,401,500,598,599){
   foreach($value in @([int]$status,[long]$status)){
    $record=New-Record $kind;Set-Field $record 'meeting_owner_http_status' $value
    Check-Valid $name $record
   }
  }
  # Private raw extras are ignored, including names related to the safe fields.
  $record=New-Record $kind
  foreach($field in 'cookies','url','user_agent','meeting_owner_cookie','meeting_owner_url','meeting_owner_user_agent','message'){
   Set-Field $record $field 'PRIVATE_FIXTURE_RAW_VALUE'
  }
  Set-Field $record 'private_nested' @{cookie='PRIVATE_FIXTURE_NESTED_VALUE'}
  Check-Valid $name $record
  foreach($field in @('active_case')+$safeFields){
   $record=New-Record $kind;Remove-Field $record $field
   Check-Refused $name $record
  }
  foreach($value in @($null,$true,$false,0,'','native_windows_meeting_owner','NATIVE_WINDOWS_MEETING_OWNER_PAGE','native_windows_meeting_owner_page ','unrelated_case',@('native_windows_meeting_owner_page'),@{private='PRIVATE_FIXTURE'})){
   $record=New-Record $kind;Set-Field $record 'active_case' $value
   Check-Refused $name $record
  }
  foreach($value in @($null,$true,$false,'','200',-1,600,[int]::MinValue,[int]::MaxValue,[long]::MinValue,[long]::MaxValue,[double]200,[single]200,[decimal]200,[byte]200,[short]200,[uint32]200,[uint64]200,@(200),@{},[pscustomobject]@{private='PRIVATE_FIXTURE'})){
   $record=New-Record $kind;Set-Field $record 'meeting_owner_http_status' $value
   Check-Refused $name $record
  }
  foreach($value in @($null,$true,$false,0,'','MEET','Meet',' meet','meet ','/meet/','/login.php','https://private.invalid/PRIVATE_FIXTURE','meet?token=PRIVATE_FIXTURE',"meet`n",@('meet'),@{},[pscustomobject]@{private='PRIVATE_FIXTURE'})){
   $record=New-Record $kind;Set-Field $record 'meeting_owner_route' $value
   Check-Refused $name $record
  }
  foreach($field in $booleanFields){
   foreach($value in @($null,0,1,-1,'true','false','False',[double]1,@($true),@{},[pscustomobject]@{private='PRIVATE_FIXTURE'})){
    $record=New-Record $kind;Set-Field $record $field $value
    Check-Refused $name $record
   }
  }
  $empty=New-Record $kind
  foreach($field in @('active_case')+$safeFields){Remove-Field $empty $field}
  Check-Refused $name $empty
 }
 Check-Refused $name $null
}
Write-Output "PASS $script:checks actual AST meeting-owner projection controls; no installed service, network, or database invoked"
