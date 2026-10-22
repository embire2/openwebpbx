#Requires -Version 5.1
# Actual AST closed path-report controls only; no installed service or network.
[CmdletBinding()]
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$script:checks=0
function Check([bool]$Value){if(!$Value){throw ('A meeting-path projection control failed at test line '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
$definitions=@{}
foreach($source in @(@{Path='tests/windows-native-acceptance.ps1';Name='MeetingPathFields'},@{Path='tests/windows-suite.ps1';Name='SafeMeetingPathFields'})){
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot $source.Path),[ref]$tokens,[ref]$errors);Check ($errors.Count -eq 0)
 $nodes=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $source.Name},$true));Check ($nodes.Count -eq 1);$definitions[$source.Name]=$nodes[0].Extent.Text
}
$nativePrefix='function MeetingPathFields';$suitePrefix='function SafeMeetingPathFields'
Check ($definitions.MeetingPathFields.StartsWith($nativePrefix,[StringComparison]::Ordinal))
Check ($definitions.SafeMeetingPathFields.StartsWith($suitePrefix,[StringComparison]::Ordinal))
Check ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($definitions.MeetingPathFields.Substring($nativePrefix.Length))) -ceq [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($definitions.SafeMeetingPathFields.Substring($suitePrefix.Length))))
foreach($name in 'MeetingPathFields','SafeMeetingPathFields'){Invoke-Expression $definitions[$name]}
$ws=@{Booleans=@('observed','connected','sent','response_received','closed_exact','large_sent','large_response_received');Integers=@{status_code=699;large_status_code=699;elapsed_ms=6000};Enums=@{phase=@('connect','send','receive','complete','unavailable');error_kind=@('none','timeout','tls','websocket','other','unavailable')}}
$pg=@{Booleans=@('observed','read_only','query_visible','counts_capped');Integers=@{total=512;active=512;idle=512;idle_in_transaction=512;wait_lock=512;meeting_select=512;meeting_update=512;meeting_insert=512;meeting_other=512;meeting_wait_lock=512};Enums=@{error_kind=@('none','timeout','database','unavailable')}}
$http=@{Booleans=@('observed','completed','ok');Integers=@{http_status=599;elapsed_ms=5000};Enums=@{member_state=@('waiting','admitted','left','removed','unavailable','other');error_kind=@('none','timeout','tls','http','invalid_json','other','unavailable')}}
$specifications=[ordered]@{backend=$ws;frontend=$ws;fragmented_backend=$ws;fragmented_frontend=$ws;database=$pg;host_http=$http;guest_http=$http}
function New-Map([string]$Shape,[Collections.IDictionary]$Values){$copy=@{};foreach($key in $Values.Keys){$copy[$key]=$Values[$key]};if($Shape -ceq 'object'){return [pscustomobject]$copy};return $copy}
function New-Record([string]$Shape){
 $stages=@{};$index=1
 foreach($stage in 'before','after'){
  $nodes=@{}
  foreach($kind in $specifications.Keys){
   $spec=$specifications[$kind];$fields=@{}
   foreach($field in $spec.Booleans){$fields[$field]=[bool]($index % 2)}
   foreach($field in $spec.Integers.Keys){$fields[$field]=$index}
   foreach($field in $spec.Enums.Keys){$fields[$field]=$spec.Enums[$field][$index % $spec.Enums[$field].Count]}
   $nodes[$kind]=New-Map $Shape $fields;$index++
  }
  $stages[$stage]=New-Map $Shape $nodes
 }
 return (New-Map $Shape @{active_case='native_windows_meeting_decoded_media';meeting_path=(New-Map $Shape $stages)})
}
function Set-Field($Record,[string]$Field,$Value){if($Record -is [Collections.IDictionary]){$Record[$Field]=$Value}elseif($Record.PSObject.Properties[$Field]){$Record.$Field=$Value}else{$Record|Add-Member -NotePropertyName $Field -NotePropertyValue $Value}}
function Remove-Field($Record,[string]$Field){if($Record -is [Collections.IDictionary]){$null=$Record.Remove($Field)}else{$Record.PSObject.Properties.Remove($Field)}}
function Project([string]$Name,$Record){
 $before=$Record|ConvertTo-Json -Depth 9 -Compress;$output=@(& $Name $Record)
 Check ($output.Count -eq 1 -and $output[0] -is [Collections.IDictionary])
 Check (($Record|ConvertTo-Json -Depth 9 -Compress) -ceq $before)
 return $output[0]
}
function Refused([string]$Name,$Record){$safe=Project $Name $Record;Check ($safe.Count -eq 0)}
function Accepted([string]$Name,$Record){$safe=Project $Name $Record;Check ($safe.Count -eq 1 -and $safe.Contains('meeting_path'))}
function Exact([string]$Name,$Record){
 $safe=Project $Name $Record
 Check ($safe.Count -eq 1 -and $safe.Contains('meeting_path'))
 Check ($safe.meeting_path.Count -eq 2 -and (($safe.meeting_path.Keys|Sort-Object)-join '|') -ceq 'after|before')
 foreach($stage in 'before','after'){
  Check ($safe.meeting_path.$stage.Count -eq 7 -and (($safe.meeting_path.$stage.Keys|Sort-Object)-join '|') -ceq 'backend|database|fragmented_backend|fragmented_frontend|frontend|guest_http|host_http')
  foreach($kind in $specifications.Keys){
   $spec=$specifications[$kind];$expected=$Record.meeting_path.$stage.$kind;$actual=$safe.meeting_path.$stage.$kind
   $fields=@($spec.Booleans)+@($spec.Integers.Keys)+@($spec.Enums.Keys)
   Check ($actual -is [Collections.IDictionary] -and $actual.Count -eq $fields.Count -and (($actual.Keys|Sort-Object)-join '|') -ceq (($fields|Sort-Object)-join '|'))
   foreach($field in $spec.Booleans){Check ($actual[$field] -is [bool] -and $actual[$field] -eq $expected.$field)}
   foreach($field in $spec.Integers.Keys){Check ($actual[$field] -is [int] -and $actual[$field] -eq $expected.$field)}
   foreach($field in $spec.Enums.Keys){Check ($actual[$field] -is [string] -and $actual[$field] -ceq $expected.$field)}
  }
 }
 Check (($safe|ConvertTo-Json -Depth 9 -Compress) -notmatch 'PRIVATE_FIXTURE')
}
foreach($name in 'MeetingPathFields','SafeMeetingPathFields'){
 foreach($shape in 'dictionary','object'){
  Exact $name (New-Record $shape)
  # Mixed object/dictionary nesting must retain all fourteen distinct observations.
  $record=New-Record $shape;$replacement=New-Record $(if($shape -ceq 'object'){'dictionary'}else{'object'})
  Set-Field $record.meeting_path 'after' $replacement.meeting_path.after;Exact $name $record
  foreach($phase in 'browser_start','owner_page','create','host_join','guest_join','admission','decoded_media','mute','unmute','end'){
   $record=New-Record $shape;Set-Field $record 'active_case' ('native_windows_meeting_'+$phase);Accepted $name $record
  }
  $record=New-Record $shape;Set-Field $record 'url' 'PRIVATE_FIXTURE';Set-Field $record 'error' 'PRIVATE_FIXTURE';Exact $name $record
  foreach($value in @($null,$true,0,'','other','native_windows_meeting_unknown','NATIVE_WINDOWS_MEETING_DECODED_MEDIA','native_windows_meeting_end ',@('native_windows_meeting_end'),@{})){
   $record=New-Record $shape;Set-Field $record 'active_case' $value;Refused $name $record
  }
  foreach($field in 'active_case','meeting_path'){$record=New-Record $shape;Remove-Field $record $field;Refused $name $record}
  foreach($value in @($null,$true,0,'PRIVATE_FIXTURE',@(),@{},[pscustomobject]@{})){
   $record=New-Record $shape;Set-Field $record 'meeting_path' $value;Refused $name $record
  }
  $record=New-Record $shape;Set-Field $record.meeting_path 'url' 'PRIVATE_FIXTURE';Refused $name $record
  foreach($stage in 'before','after'){
   $record=New-Record $shape;Remove-Field $record.meeting_path $stage;Refused $name $record
   foreach($value in @($null,$true,0,'PRIVATE_FIXTURE',@(),@{},[pscustomobject]@{})){
    $record=New-Record $shape;Set-Field $record.meeting_path $stage $value;Refused $name $record
   }
   $record=New-Record $shape;Set-Field $record.meeting_path.$stage 'url' 'PRIVATE_FIXTURE';Refused $name $record
   foreach($kind in $specifications.Keys){
    $spec=$specifications[$kind];$fields=@($spec.Booleans)+@($spec.Integers.Keys)+@($spec.Enums.Keys)
    $record=New-Record $shape;Remove-Field $record.meeting_path.$stage $kind;Refused $name $record
    foreach($value in @($null,$true,0,'PRIVATE_FIXTURE',@(),@{},[pscustomobject]@{})){
     $record=New-Record $shape;Set-Field $record.meeting_path.$stage $kind $value;Refused $name $record
    }
    foreach($extra in 'url','user_agent','headers','sql','password','error'){
     $record=New-Record $shape;Set-Field $record.meeting_path.$stage.$kind $extra 'PRIVATE_FIXTURE';Refused $name $record
    }
    foreach($field in $fields){
     $record=New-Record $shape;Remove-Field $record.meeting_path.$stage.$kind $field;Refused $name $record
     $record=New-Record $shape;$value=$record.meeting_path.$stage.$kind.$field;Remove-Field $record.meeting_path.$stage.$kind $field
     Set-Field $record.meeting_path.$stage.$kind $field.ToUpperInvariant() $value;Refused $name $record
    }
    # Bound/type coverage runs once per node, keeping the matrix linear.
    if($stage -cne 'after'){continue}
    foreach($field in $spec.Booleans){
     foreach($value in $false,$true){$record=New-Record $shape;Set-Field $record.meeting_path.$stage.$kind $field $value;Accepted $name $record}
     foreach($value in @($null,0,'true',@($true),@{})){$record=New-Record $shape;Set-Field $record.meeting_path.$stage.$kind $field $value;Refused $name $record}
    }
    foreach($field in $spec.Integers.Keys){
     $maximum=$spec.Integers[$field]
     foreach($value in @([int]0,[long]0,[int]$maximum,[long]$maximum)){$record=New-Record $shape;Set-Field $record.meeting_path.$stage.$kind $field $value;Accepted $name $record}
     foreach($value in @($null,$true,'0',-1,($maximum+1),[double]0,[decimal]0,@(0),@{})){$record=New-Record $shape;Set-Field $record.meeting_path.$stage.$kind $field $value;Refused $name $record}
    }
    foreach($field in $spec.Enums.Keys){
     foreach($value in $spec.Enums[$field]){$record=New-Record $shape;Set-Field $record.meeting_path.$stage.$kind $field $value;Accepted $name $record}
     $first=$spec.Enums[$field][0]
     foreach($value in @($null,$true,0,'PRIVATE_FIXTURE',$first.ToUpperInvariant(),($first+' '),@($first),@{})){$record=New-Record $shape;Set-Field $record.meeting_path.$stage.$kind $field $value;Refused $name $record}
    }
   }
  }
  Refused $name (New-Map $shape @{})
 }
 Refused $name $null
}
Write-Output "PASS $script:checks actual AST meeting-path closed-schema/type/bound/enum/privacy controls; no installed service or network invoked"
