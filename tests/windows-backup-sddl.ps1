param()
# Synthetic/read-only metadata helper. Descriptor, SID and ACE bytes never leave this process.
$ErrorActionPreference='Stop'
[Console]::InputEncoding=New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding=New-Object Text.UTF8Encoding($false)
function EqualBytes([byte[]]$Left,[byte[]]$Right){
 if($Left.Length -ne $Right.Length){return $false}
 for($index=0;$index -lt $Left.Length;$index++){if($Left[$index] -ne $Right[$index]){return $false}}
 return $true
}
function BinaryForm($Value){
 $bytes=New-Object byte[] $Value.BinaryLength;$Value.GetBinaryForm($bytes,0);return ,$bytes
}
function AclMetadata($Left,$Right){
 $result=@{before_null=($null -eq $Left);after_null=($null -eq $Right)}
 $sets=@();$sequences=@();$binaries=@()
 foreach($side in @(@('before',$Left),@('after',$Right))){
  $label=$side[0];$acl=$side[1];$keys=New-Object 'Collections.Generic.Dictionary[string,int]' ([StringComparer]::Ordinal)
  $sequence=New-Object 'Collections.Generic.List[string]';$ordinary=($null -ne $acl -and $acl.Count -gt 0)
  $binary=[byte[]]@()
  if($null -eq $acl){$result['revision_'+$label]=$null;$result['size_'+$label]=0;$result['count_'+$label]=0}
  else{
   if($acl.BinaryLength -gt 65535 -or $acl.Count -gt 65535){throw 'refused'}
   $binary=BinaryForm $acl
   $result['revision_'+$label]=[int]$acl.Revision;$result['size_'+$label]=[int]$acl.BinaryLength;$result['count_'+$label]=[int]$acl.Count
   foreach($ace in $acl){
    $key=[Convert]::ToBase64String((BinaryForm $ace));$sequence.Add($key)
    if($keys.ContainsKey($key)){$keys[$key]++}else{$keys.Add($key,1)}
    if($ace -isnot [Security.AccessControl.CommonAce] -or $ace.IsCallback -or $ace.AceType -ne [Security.AccessControl.AceType]::AccessAllowed -or $ace.AceQualifier -ne [Security.AccessControl.AceQualifier]::AccessAllowed){$ordinary=$false}
   }
  }
  $result['unique_ace_count_'+$label]=[int]$keys.Count
  $result['duplicate_ace_count_'+$label]=[int]($sequence.Count-$keys.Count)
  $result['all_ordinary_allow_'+$label]=[bool]$ordinary
  $sets+=,$keys;$sequences+=,$sequence;$binaries+=,$binary
 }
 $sameNull=($result.before_null -eq $result.after_null)
 $setEqual=$sameNull -and $sets[0].Count -eq $sets[1].Count;$multiplicityEqual=$setEqual
 foreach($key in $sets[0].Keys){
  if(!$sets[1].ContainsKey($key)){$setEqual=$false;$multiplicityEqual=$false}
  elseif($sets[0][$key] -ne $sets[1][$key]){$multiplicityEqual=$false}
 }
 $sequenceEqual=$sameNull -and $sequences[0].Count -eq $sequences[1].Count
 if($sequenceEqual){for($index=0;$index -lt $sequences[0].Count;$index++){if($sequences[0][$index] -cne $sequences[1][$index]){$sequenceEqual=$false;break}}}
 $result.raw_binary_equal=[bool]($sameNull -and (EqualBytes $binaries[0] $binaries[1]))
 $result.ace_sequence_equal=[bool]$sequenceEqual;$result.ace_set_equal=[bool]$setEqual
 $result.ace_multiset_equal=[bool]$multiplicityEqual;$result.ace_multiplicity_equal=[bool]$multiplicityEqual
 return $result
}
function DescriptorObjects($Left,$Right){
 $before=BinaryForm $Left;$after=BinaryForm $Right
 if($before.Length -gt 262144 -or $after.Length -gt 262144){throw 'refused'}
 return @{
  descriptor_binary_equal=(EqualBytes $before $after)
  descriptor_revision_before=[int]$before[0];descriptor_revision_after=[int]$after[0]
  owner_equal=([object]::Equals($left.Owner,$right.Owner));group_equal=([object]::Equals($left.Group,$right.Group))
  owner_before_null=($null -eq $left.Owner);owner_after_null=($null -eq $right.Owner)
  group_before_null=($null -eq $left.Group);group_after_null=($null -eq $right.Group)
  control_flags_before=[int]$left.ControlFlags;control_flags_after=[int]$right.ControlFlags
  control_flags_xor=([int]$left.ControlFlags -bxor [int]$right.ControlFlags)
  resource_manager_control_before=[int]$left.ResourceManagerControl;resource_manager_control_after=[int]$right.ResourceManagerControl
  dacl=(AclMetadata $left.DiscretionaryAcl $right.DiscretionaryAcl)
  sacl=(AclMetadata $left.SystemAcl $right.SystemAcl)
 }
}
function DescriptorMetadata($Value){
 $left=New-Object Security.AccessControl.RawSecurityDescriptor ([string]$Value.before)
 $right=New-Object Security.AccessControl.RawSecurityDescriptor ([string]$Value.after)
 return (DescriptorObjects $left $right)+@{file_category=$Value.file_category;strict_sddl_equal=([string]$Value.before -ceq [string]$Value.after)}
}
try{
 $text=[Console]::In.ReadToEnd()
 if($text.Length -gt 1048576){throw 'refused'}
 $request=$text|ConvertFrom-Json
 $categories=@('config','template_key','runtime','installation','phone_tls_metadata','phone_tls_material','public_access_source','notifications','legacy_push','freeswitch_config','voicemail','recordings','other_owned')
 $items=@($request.items)
 if($request.schema -isnot [int] -or $request.schema -ne 1 -or $items.Count -lt 1 -or $items.Count -gt 3){throw 'refused'}
 foreach($item in $items){
  if($item.file_category -isnot [string] -or $item.file_category -cnotin $categories -or $item.before -isnot [string] -or $item.after -isnot [string] -or $item.before.Length -gt 131072 -or $item.after.Length -gt 131072){throw 'refused'}
 }
 $result=@{schema=1;report_status='read';mismatches=@()}
 foreach($item in $items){$result.mismatches+=,(DescriptorMetadata $item)}
 [Console]::Out.WriteLine(($result|ConvertTo-Json -Depth 8 -Compress))
}catch{[Console]::Out.WriteLine('{"schema":1,"report_status":"unavailable","mismatches":[]}')}
