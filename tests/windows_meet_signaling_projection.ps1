#Requires -Version 5.1
<# Portable controls execute only the actual AST signaling-report projectors.
All inputs are fictional; no service, browser, network, or database is used. #>
[CmdletBinding()]
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
$script:checks=0
function Check([bool]$Value){
 if(!$Value){throw ('A meeting-signaling projection control failed at test line '+(Get-PSCallStack)[1].ScriptLineNumber+'.')}
 $script:checks++
}
$definitions=@{}
foreach($source in @(
 @{Path='tests/windows-native-acceptance.ps1';Name='MeetingSignalingFields'},
 @{Path='tests/windows-suite.ps1';Name='SafeMeetingSignalingFields'}
)){
 $tokens=$null;$errors=$null
 $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot $source.Path),[ref]$tokens,[ref]$errors)
 Check ($errors.Count -eq 0)
 $nodes=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $source.Name},$true))
 Check ($nodes.Count -eq 1)
 $definitions[$source.Name]=$nodes[0].Extent.Text
}
$nativePrefix='function MeetingSignalingFields'
$suitePrefix='function SafeMeetingSignalingFields'
Check ($definitions.MeetingSignalingFields.StartsWith($nativePrefix,[StringComparison]::Ordinal))
Check ($definitions.SafeMeetingSignalingFields.StartsWith($suitePrefix,[StringComparison]::Ordinal))
$nativeBytes=[Text.Encoding]::UTF8.GetBytes($definitions.MeetingSignalingFields.Substring($nativePrefix.Length))
$suiteBytes=[Text.Encoding]::UTF8.GetBytes($definitions.SafeMeetingSignalingFields.Substring($suitePrefix.Length))
Check ([Convert]::ToBase64String($nativeBytes) -ceq [Convert]::ToBase64String($suiteBytes))
foreach($name in 'MeetingSignalingFields','SafeMeetingSignalingFields'){Invoke-Expression $definitions[$name]}

$booleanFields=@('observed','endpoint_match','counts_capped','local_description','remote_description','admit_ok','offer_observed','offer_audio_secure','offer_video_secure','offer_pcmu','offer_pcma','offer_opus','offer_vp8','offer_sha256_fingerprint','offer_ice_ufrag','offer_ice_pwd','offer_rtcp_mux','offer_bundle','offer_connection')
$integerLimits=[ordered]@{
 ws_observed=512;ws_closed=512;ws_errors=512;sent_register=512;sent_invite=512;admit_requests=512
 admit_responses=512;status_requests=512;status_responses=512;http_failures=512;api_json_failures=512
 admit_http_status=599;status_http_status=599
}
$enumFields=[ordered]@{
 signaling_state=@('stable','have-local-offer','have-remote-offer','have-local-pranswer','have-remote-pranswer','closed','unavailable')
 ice_gathering_state=@('new','gathering','complete','unavailable')
 member_state=@('waiting','admitted','left','removed','unavailable','other')
}
$arrayFields=@('register_codes','invite_codes')
$peerFields=$booleanFields+@($integerLimits.Keys)+@($enumFields.Keys)+$arrayFields
$expectedPeerKeys=($peerFields|Sort-Object)-join '|'
Check ($peerFields.Count -eq 37)
function New-Map([string]$Kind,[Collections.IDictionary]$Values){
 $copy=if($Kind -ceq 'ordered'){[ordered]@{}}else{@{}}
 foreach($key in $Values.Keys){$copy[$key]=$Values[$key]}
 if($Kind -ceq 'object'){return [pscustomobject]$copy}
 return $copy
}
function New-Peer([string]$Kind,[bool]$Guest){
 $values=@{
  observed=!$Guest;endpoint_match=!$Guest;counts_capped=!$Guest
  local_description=!$Guest;remote_description=!$Guest;admit_ok=!$Guest
  signaling_state='stable';ice_gathering_state='complete';member_state='admitted'
  register_codes=@(100,200);invite_codes=@(180,200)
 }
 foreach($key in $booleanFields){if(!$values.ContainsKey($key)){$values[$key]=!$Guest}}
 $index=1
 foreach($key in $integerLimits.Keys){$values[$key]=$index;$index++}
 if($Guest){
  $values.signaling_state='closed';$values.ice_gathering_state='new';$values.member_state='waiting'
  foreach($key in $integerLimits.Keys){$values[$key]+=20}
  $values.register_codes=@(401,200);$values.invite_codes=@(183,486)
 }
 return (New-Map $Kind $values)
}
function New-Record([string]$Kind,[string]$ReportKind='',[string]$HostKind='',[string]$GuestKind=''){
 if(!$ReportKind){$ReportKind=$Kind};if(!$HostKind){$HostKind=$Kind};if(!$GuestKind){$GuestKind=$Kind}
 $report=New-Map $ReportKind @{host=(New-Peer $HostKind $false);guest=(New-Peer $GuestKind $true)}
 return (New-Map $Kind @{active_case='native_windows_meeting_decoded_media';meeting_signaling=$report})
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
 Check ($safe.Count -eq 1 -and $safe.Contains('meeting_signaling'))
 Check ($safe.meeting_signaling -is [Collections.IDictionary] -and $safe.meeting_signaling.Count -eq 2 -and (($safe.meeting_signaling.Keys|Sort-Object)-join '|') -ceq 'guest|host')
 foreach($peer in 'host','guest'){
  $actual=$safe.meeting_signaling.$peer;$expected=$Record.meeting_signaling.$peer
  Check ($actual -is [Collections.IDictionary] -and $actual.Count -eq 37 -and (($actual.Keys|Sort-Object)-join '|') -ceq $expectedPeerKeys)
  foreach($field in $booleanFields){Check ($actual[$field] -is [bool] -and $actual[$field] -eq $expected.$field)}
  foreach($field in $integerLimits.Keys){Check (($actual[$field] -is [int] -or $actual[$field] -is [long]) -and $actual[$field] -eq $expected.$field)}
  foreach($field in $enumFields.Keys){Check ($actual[$field] -is [string] -and $actual[$field] -ceq $expected.$field)}
  foreach($field in $arrayFields){
   $codes=$actual[$field];$expectedCodes=$expected.$field
   Check ($codes -is [Array] -and $codes.Count -eq $expectedCodes.Count)
   for($index=0;$index -lt $codes.Count;$index++){Check (($codes[$index] -is [int] -or $codes[$index] -is [long]) -and $codes[$index] -eq $expectedCodes[$index])}
  }
 }
 Check (($safe|ConvertTo-Json -Depth 8 -Compress) -notmatch 'PRIVATE_FIXTURE')
}
function Check-Refused([string]$Name,$Record){
 $safe=Invoke-Projection $Name $Record
 Check ($safe.Count -eq 0)
}

foreach($name in 'MeetingSignalingFields','SafeMeetingSignalingFields'){
 foreach($shape in @(
  @('dictionary','dictionary','dictionary','dictionary'),@('ordered','ordered','ordered','ordered'),@('object','object','object','object'),
  @('object','dictionary','object','ordered'),@('dictionary','object','ordered','object')
 )){
  Check-Valid $name (New-Record $shape[0] $shape[1] $shape[2] $shape[3])
 }
 foreach($kind in 'dictionary','object'){
  foreach($phase in 'host_join','guest_join','admission','decoded_media','mute','unmute','end'){
   $record=New-Record $kind;Set-Field $record 'active_case' ('native_windows_meeting_'+$phase);Check-Valid $name $record
  }
  $record=New-Record $kind
  foreach($field in 'url','user_agent','cookie','sdp','ice_candidates','private_error'){Set-Field $record $field 'PRIVATE_FIXTURE_RAW_VALUE'}
  Check-Valid $name $record
  foreach($field in 'active_case','meeting_signaling'){
   $record=New-Record $kind;Remove-Field $record $field;Check-Refused $name $record
  }
  foreach($value in @($null,$true,$false,0,'','unrelated_case','native_windows_meeting_owner_page','native_windows_meeting_admission ','NATIVE_WINDOWS_MEETING_ADMISSION',@('native_windows_meeting_admission'),@{})){
   $record=New-Record $kind;Set-Field $record 'active_case' $value;Check-Refused $name $record
  }
  $emptyValues=@(@{},[ordered]@{},[pscustomobject]@{})
  foreach($value in @($null,$true,$false,0,'PRIVATE_FIXTURE',@(),@(@{host=@{};guest=@{}}))+$emptyValues){
   $record=New-Record $kind;Set-Field $record 'meeting_signaling' $value;Check-Refused $name $record
  }
  foreach($peer in 'host','guest'){
   $record=New-Record $kind;Remove-Field $record.meeting_signaling $peer;Check-Refused $name $record
   $record=New-Record $kind;$value=$record.meeting_signaling.$peer;Remove-Field $record.meeting_signaling $peer
   Set-Field $record.meeting_signaling $peer.ToUpperInvariant() $value;Check-Refused $name $record
   foreach($value in @($null,$true,$false,0,'PRIVATE_FIXTURE',@(),@(@{observed=$true}))+$emptyValues){
    $record=New-Record $kind;Set-Field $record.meeting_signaling $peer $value;Check-Refused $name $record
   }
   foreach($field in $peerFields){
    $record=New-Record $kind;Remove-Field $record.meeting_signaling.$peer $field;Check-Refused $name $record
    $record=New-Record $kind;$value=$record.meeting_signaling.$peer.$field;Remove-Field $record.meeting_signaling.$peer $field
    Set-Field $record.meeting_signaling.$peer $field.ToUpperInvariant() $value;Check-Refused $name $record
   }
   foreach($field in 'url','user_agent','cookie','sdp','ice_candidates','private_error','message'){
    $record=New-Record $kind;Set-Field $record.meeting_signaling.$peer $field 'PRIVATE_FIXTURE_RAW_VALUE';Check-Refused $name $record
    $record=New-Record $kind;Set-Field $record.meeting_signaling $field 'PRIVATE_FIXTURE_RAW_VALUE';Check-Refused $name $record
   }
   foreach($field in $booleanFields){
    foreach($value in $false,$true){$record=New-Record $kind;Set-Field $record.meeting_signaling.$peer $field $value;Check-Valid $name $record}
    foreach($value in @($null,0,1,-1,'true','false',[double]1,@($true),@{},[pscustomobject]@{})){
     $record=New-Record $kind;Set-Field $record.meeting_signaling.$peer $field $value;Check-Refused $name $record
    }
   }
   foreach($field in $integerLimits.Keys){
    $limit=$integerLimits[$field]
    foreach($value in @([int]0,[long]0,[int]1,[long]1,[int]$limit,[long]$limit)){
     $record=New-Record $kind;Set-Field $record.meeting_signaling.$peer $field $value;Check-Valid $name $record
    }
    foreach($value in @($null,$true,$false,'0','200',-1,([long]$limit+1),[long]::MinValue,[long]::MaxValue,[double]0,[single]0,[decimal]0,[byte]0,[short]0,[uint32]0,[uint64]0,@(0),@{},[pscustomobject]@{})){
     $record=New-Record $kind;Set-Field $record.meeting_signaling.$peer $field $value;Check-Refused $name $record
    }
   }
   foreach($field in $enumFields.Keys){
    foreach($value in $enumFields[$field]){$record=New-Record $kind;Set-Field $record.meeting_signaling.$peer $field $value;Check-Valid $name $record}
    $first=$enumFields[$field][0]
    foreach($value in @($null,$true,$false,0,'','PRIVATE_FIXTURE',$first.ToUpperInvariant(),($first+' '),(' '+$first),($first+"`n"),@($first),@{},[pscustomobject]@{})){
     $record=New-Record $kind;Set-Field $record.meeting_signaling.$peer $field $value;Check-Refused $name $record
    }
   }
   foreach($field in $arrayFields){
    $sixteen=@(0..15|ForEach-Object {if($_ % 2){[long]699}else{[int]100}})
    foreach($value in @(@(),@(100),@([long]699),@(100,699),$sixteen,[int[]]@(100,200),[long[]]@(100,699))){
     $record=New-Record $kind;Set-Field $record.meeting_signaling.$peer $field $value;Check-Valid $name $record
    }
    $list=[Collections.Generic.List[int]]::new();$list.Add(100)
    foreach($value in @($null,$true,$false,100,'100','PRIVATE_FIXTURE',@{},[pscustomobject]@{},$list,@(100..116))){
     $record=New-Record $kind;Set-Field $record.meeting_signaling.$peer $field $value;Check-Refused $name $record
    }
    # Invalid elements at the start, middle, and end must reject the whole map.
    foreach($position in 0,7,15){
     foreach($bad in @($null,$true,$false,'100','PRIVATE_FIXTURE',99,700,[long]::MinValue,[long]::MaxValue,[double]100,[single]100,[decimal]100,[byte]100,[short]100,[uint32]100,[uint64]100,@(100),@{},[pscustomobject]@{})){
      $codes=[object[]]$sixteen.Clone();$codes[$position]=$bad
      $record=New-Record $kind;Set-Field $record.meeting_signaling.$peer $field $codes;Check-Refused $name $record
     }
    }
   }
  }
  Check-Refused $name (New-Map $kind @{})
 }
 Check-Refused $name $null
}
Write-Output "PASS $script:checks actual AST meeting-signaling projection controls; no installed service, network, or database invoked"
