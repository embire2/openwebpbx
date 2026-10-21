#Requires -Version 5.1
<# Portable controls execute only the actual AST media-report projectors.
All inputs are fictional; no service, browser, network, or database is used. #>
[CmdletBinding()]
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
$script:checks=0
function Check([bool]$Value){
 if(!$Value){throw ('A meeting-media projection control failed at test line '+(Get-PSCallStack)[1].ScriptLineNumber+'.')}
 $script:checks++
}
$definitions=@{}
foreach($source in @(
 @{Path='tests/windows-native-acceptance.ps1';Name='MeetingMediaFields'},
 @{Path='tests/windows-suite.ps1';Name='SafeMeetingMediaFields'}
)){
 $tokens=$null;$errors=$null
 $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot $source.Path),[ref]$tokens,[ref]$errors)
 Check ($errors.Count -eq 0)
 $nodes=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $source.Name},$true))
 Check ($nodes.Count -eq 1)
 $definitions[$source.Name]=$nodes[0].Extent.Text
}
$nativePrefix='function MeetingMediaFields'
$suitePrefix='function SafeMeetingMediaFields'
Check ($definitions.MeetingMediaFields.StartsWith($nativePrefix,[StringComparison]::Ordinal))
Check ($definitions.SafeMeetingMediaFields.StartsWith($suitePrefix,[StringComparison]::Ordinal))
$nativeBytes=[Text.Encoding]::UTF8.GetBytes($definitions.MeetingMediaFields.Substring($nativePrefix.Length))
$suiteBytes=[Text.Encoding]::UTF8.GetBytes($definitions.SafeMeetingMediaFields.Substring($suitePrefix.Length))
Check ([Convert]::ToBase64String($nativeBytes) -ceq [Convert]::ToBase64String($suiteBytes))
foreach($name in 'MeetingMediaFields','SafeMeetingMediaFields'){Invoke-Expression $definitions[$name]}

$booleanFields=@('observed','connected','remote_audio_live','remote_video_live','local_audio_live','local_video_live','vp8_decoding','probe_error')
$enumFields=[ordered]@{
 connection_state=@('new','connecting','connected','disconnected','failed','closed','unavailable')
 ice_state=@('new','checking','connected','completed','disconnected','failed','closed','unavailable')
 visibility=@('visible','hidden','prerender','unavailable')
 audio_context=@('running','suspended','closed','interrupted','unavailable')
 ui_state=@('connected','connecting','waiting','ended','rejected','connect_error','permission_error','device_error','unavailable','other')
}
$integerLimits=[ordered]@{
 decoded_frames=2147483647;encoded_frames=2147483647;inbound_audio_packets=2147483647
 outbound_audio_packets=2147483647;inbound_video_packets=2147483647;outbound_video_packets=2147483647;video_colors=14400
}
$numberFields=@('tone_ratio','power')
$peerFields=$booleanFields+@($enumFields.Keys)+@($integerLimits.Keys)+$numberFields
$expectedPeerKeys=($peerFields|Sort-Object)-join '|'
Check ($peerFields.Count -eq 22)
function New-Map([string]$Kind,[Collections.IDictionary]$Values){
 $copy=if($Kind -ceq 'ordered'){[ordered]@{}}else{@{}}
 foreach($key in $Values.Keys){$copy[$key]=$Values[$key]}
 if($Kind -ceq 'object'){return [pscustomobject]$copy}
 return $copy
}
function New-Peer([string]$Kind,[bool]$Guest){
 $values=@{
  observed=!$Guest;connected=!$Guest;remote_audio_live=!$Guest;remote_video_live=!$Guest
  local_audio_live=!$Guest;local_video_live=!$Guest;vp8_decoding=!$Guest;probe_error=$Guest
  connection_state='connected';ice_state='completed';visibility='visible';audio_context='running';ui_state='connected'
  decoded_frames=7;encoded_frames=9;inbound_audio_packets=11;outbound_audio_packets=13
  inbound_video_packets=17;outbound_video_packets=19;video_colors=23;tone_ratio=.875;power=.25
 }
 if($Guest){
  $values.connection_state='closed';$values.ice_state='disconnected';$values.visibility='hidden';$values.audio_context='suspended';$values.ui_state='ended'
  foreach($key in $integerLimits.Keys){$values[$key]++}
  $values.tone_ratio=.125;$values.power=.5
 }
 return (New-Map $Kind $values)
}
function New-Record([string]$Kind,[string]$MediaKind='',[string]$HostKind='',[string]$GuestKind=''){
 if(!$MediaKind){$MediaKind=$Kind};if(!$HostKind){$HostKind=$Kind};if(!$GuestKind){$GuestKind=$Kind}
 $media=New-Map $MediaKind @{host=(New-Peer $HostKind $false);guest=(New-Peer $GuestKind $true)}
 return (New-Map $Kind @{active_case='native_windows_meeting_decoded_media';meeting_media=$media})
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
 Check ($safe.Count -eq 1 -and $safe.Contains('meeting_media'))
 Check ($safe.meeting_media -is [Collections.IDictionary] -and $safe.meeting_media.Count -eq 2 -and (($safe.meeting_media.Keys|Sort-Object)-join '|') -ceq 'guest|host')
 foreach($peer in 'host','guest'){
  $actual=$safe.meeting_media.$peer;$expected=$Record.meeting_media.$peer
  Check ($actual -is [Collections.IDictionary] -and $actual.Count -eq 22 -and (($actual.Keys|Sort-Object)-join '|') -ceq $expectedPeerKeys)
  foreach($field in $booleanFields){Check ($actual[$field] -is [bool] -and $actual[$field] -eq $expected.$field)}
  foreach($field in $enumFields.Keys){Check ($actual[$field] -is [string] -and $actual[$field] -ceq $expected.$field)}
  foreach($field in $integerLimits.Keys){Check (($actual[$field] -is [int] -or $actual[$field] -is [long]) -and $actual[$field] -eq $expected.$field)}
  foreach($field in $numberFields){
   $value=$actual[$field]
   Check (($value -is [int] -or $value -is [long] -or $value -is [single] -or $value -is [double]) -and [double]$value -eq [double]$expected.$field)
  }
 }
 Check (($safe|ConvertTo-Json -Depth 8 -Compress) -notmatch 'PRIVATE_FIXTURE')
}
function Check-Refused([string]$Name,$Record){
 $safe=Invoke-Projection $Name $Record
 Check ($safe.Count -eq 0)
}

foreach($name in 'MeetingMediaFields','SafeMeetingMediaFields'){
 foreach($shape in @(
  @('dictionary','dictionary','dictionary','dictionary'),@('ordered','ordered','ordered','ordered'),@('object','object','object','object'),
  @('object','dictionary','object','ordered'),@('dictionary','object','ordered','object')
 )){
  Check-Valid $name (New-Record $shape[0] $shape[1] $shape[2] $shape[3])
 }
 foreach($kind in 'dictionary','object'){
  foreach($phase in 'decoded_media','mute','unmute','end'){
   $record=New-Record $kind;Set-Field $record 'active_case' ('native_windows_meeting_'+$phase)
   Check-Valid $name $record
  }
  $record=New-Record $kind
  foreach($field in 'url','user_agent','cookie','sdp','ice_candidates','private_error'){
   Set-Field $record $field 'PRIVATE_FIXTURE_RAW_VALUE'
  }
  Check-Valid $name $record
  foreach($field in 'active_case','meeting_media'){
   $record=New-Record $kind;Remove-Field $record $field;Check-Refused $name $record
  }
  foreach($value in @($null,$true,$false,0,'','unrelated_case','native_windows_meeting_owner_page','native_windows_meeting_decoded_media ','NATIVE_WINDOWS_MEETING_DECODED_MEDIA',@('native_windows_meeting_decoded_media'),@{})){
   $record=New-Record $kind;Set-Field $record 'active_case' $value;Check-Refused $name $record
  }
  $emptyValues=@(@{},[ordered]@{},[pscustomobject]@{})
  foreach($value in @($null,$true,$false,0,'PRIVATE_FIXTURE',@(),@(@{host=@{};guest=@{}}))+$emptyValues){
   $record=New-Record $kind;Set-Field $record 'meeting_media' $value;Check-Refused $name $record
  }
  foreach($peer in 'host','guest'){
   $record=New-Record $kind;Remove-Field $record.meeting_media $peer;Check-Refused $name $record
   $record=New-Record $kind;$value=$record.meeting_media.$peer;Remove-Field $record.meeting_media $peer
   Set-Field $record.meeting_media $peer.ToUpperInvariant() $value;Check-Refused $name $record
   foreach($value in @($null,$true,$false,0,'PRIVATE_FIXTURE',@(),@(@{observed=$true}))+$emptyValues){
    $record=New-Record $kind;Set-Field $record.meeting_media $peer $value;Check-Refused $name $record
   }
   foreach($field in $peerFields){
    $record=New-Record $kind;Remove-Field $record.meeting_media.$peer $field;Check-Refused $name $record
    $record=New-Record $kind;$value=$record.meeting_media.$peer.$field;Remove-Field $record.meeting_media.$peer $field
    Set-Field $record.meeting_media.$peer $field.ToUpperInvariant() $value;Check-Refused $name $record
   }
   foreach($field in 'url','user_agent','cookie','sdp','ice_candidates','private_error','message'){
    $record=New-Record $kind;Set-Field $record.meeting_media.$peer $field 'PRIVATE_FIXTURE_RAW_VALUE';Check-Refused $name $record
    $record=New-Record $kind;Set-Field $record.meeting_media $field 'PRIVATE_FIXTURE_RAW_VALUE';Check-Refused $name $record
   }
   foreach($field in $booleanFields){
    foreach($value in $false,$true){$record=New-Record $kind;Set-Field $record.meeting_media.$peer $field $value;Check-Valid $name $record}
    foreach($value in @($null,0,1,-1,'true','false',[double]1,@($true),@{},[pscustomobject]@{})){
     $record=New-Record $kind;Set-Field $record.meeting_media.$peer $field $value;Check-Refused $name $record
    }
   }
   foreach($field in $enumFields.Keys){
    foreach($value in $enumFields[$field]){$record=New-Record $kind;Set-Field $record.meeting_media.$peer $field $value;Check-Valid $name $record}
    $first=$enumFields[$field][0]
    foreach($value in @($null,$true,$false,0,'','PRIVATE_FIXTURE',$first.ToUpperInvariant(),($first+' '),(' '+$first),($first+"`n"),@($first),@{},[pscustomobject]@{})){
     $record=New-Record $kind;Set-Field $record.meeting_media.$peer $field $value;Check-Refused $name $record
    }
   }
   foreach($field in $integerLimits.Keys){
    $limit=$integerLimits[$field]
    foreach($value in @([int]0,[long]0,[int]1,[long]1,[int]$limit,[long]$limit)){
     $record=New-Record $kind;Set-Field $record.meeting_media.$peer $field $value;Check-Valid $name $record
    }
    foreach($value in @($null,$true,$false,'0','2147483647',-1,([long]$limit+1),[long]::MinValue,[long]::MaxValue,[double]0,[single]0,[decimal]0,[byte]0,[short]0,[uint32]0,[uint64]0,@(0),@{},[pscustomobject]@{})){
     $record=New-Record $kind;Set-Field $record.meeting_media.$peer $field $value;Check-Refused $name $record
    }
   }
   foreach($field in $numberFields){
    foreach($value in @([int]0,[int]1,[long]0,[long]1,[single]0,[single]0.25,[single]1,[double]0,[double]::Epsilon,[double]0.5,[double]1)){
     $record=New-Record $kind;Set-Field $record.meeting_media.$peer $field $value;Check-Valid $name $record
    }
    foreach($value in @($null,$true,$false,'0.5','NaN','Infinity',(-[double]::Epsilon),-.01,1.0000001,[double]::NaN,[double]::PositiveInfinity,[double]::NegativeInfinity,[single]::NaN,[single]::PositiveInfinity,[single]::NegativeInfinity,[decimal]0.5,[byte]0,[short]0,[uint32]0,[uint64]0,@(.5),@{},[pscustomobject]@{})){
     $record=New-Record $kind;Set-Field $record.meeting_media.$peer $field $value;Check-Refused $name $record
    }
   }
  }
  Check-Refused $name (New-Map $kind @{})
 }
 Check-Refused $name $null
}
Write-Output "PASS $script:checks actual AST meeting-media projection controls; no installed service, network, or database invoked"
