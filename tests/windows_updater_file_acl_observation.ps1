# QA-only failure observation. All acceptance comparisons stay exact.
function Seal-WindowsUpdaterAclDifference([byte[]]$Raw,[string]$SourceCommit,[string]$RunId,[string]$PublicPem){
 if($PSVersionTable.PSEdition -cne 'Core' -or $Raw.Length -lt 2 -or $Raw.Length -gt 1048576 -or $SourceCommit -cnotmatch '^[a-f0-9]{40}$' -or $RunId -cnotmatch '^[1-9][0-9]{0,19}$' -or !$PublicPem.StartsWith('-----BEGIN PUBLIC KEY-----') -or $PublicPem.Contains('PRIVATE KEY')){throw 'The exact updater ACL diagnostic binding is required.'}
 $sha=[Security.Cryptography.SHA256]::Create();try{$plainHash=([BitConverter]::ToString($sha.ComputeHash($Raw))).Replace('-','').ToLowerInvariant();$publicHash=([BitConverter]::ToString($sha.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($PublicPem)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
 if($publicHash -cne '3ea69ce329731abcdbfc3fc3ab68086ec8ba35e62e4eb82086c6581b05785819'){throw 'Only the Root-owned diagnostic public recipient is permitted.'}
 $binding=[ordered]@{schema=1;purpose='windows-updater-file-acl-difference';source_commit=$SourceCommit;run_id=$RunId;stage='normal_protected_files';plaintext_bytes=$Raw.Length;plaintext_sha256=$plainHash}
 $aad=[Text.UTF8Encoding]::new($false).GetBytes(($binding|ConvertTo-Json -Depth 4 -Compress));$rsa=[Security.Cryptography.RSA]::Create();$key=$null;$aes=$null
 try{
  $rsa.ImportFromPem($PublicPem);if($rsa.KeySize -ne 3072){throw 'The catalogue diagnostic requires RSA3072.'}
  $key=[Security.Cryptography.RandomNumberGenerator]::GetBytes(32);$nonce=[Security.Cryptography.RandomNumberGenerator]::GetBytes(12);$tag=[byte[]]::new(16);$cipher=[byte[]]::new($Raw.Length);$aes=[Security.Cryptography.AesGcm]::new($key,16);$aes.Encrypt($nonce,$Raw,$cipher,$tag,$aad)
  return [ordered]@{schema=1;algorithm='RSA3072-OAEP-SHA256+A256GCM';public_key_sha256=$publicHash;aad=[Convert]::ToBase64String($aad);wrapped_key=[Convert]::ToBase64String($rsa.Encrypt($key,[Security.Cryptography.RSAEncryptionPadding]::OaepSHA256));nonce=[Convert]::ToBase64String($nonce);tag=[Convert]::ToBase64String($tag);ciphertext=[Convert]::ToBase64String($cipher)}
 }finally{if($aes){$aes.Dispose()};if($key){[Array]::Clear($key,0,$key.Length)};$rsa.Dispose()}
}
function Get-WindowsUpdaterAclAceBytes($Acl){
 if($null -eq $Acl){return ,@()};$rows=@();foreach($ace in $Acl){$b=New-Object byte[] $ace.BinaryLength;$ace.GetBinaryForm($b,0);$rows+=,[Convert]::ToBase64String($b)};return ,$rows
}
function Get-WindowsUpdaterAclBytes($Acl){if($null -eq $Acl){return $null};$b=New-Object byte[] $Acl.BinaryLength;$Acl.GetBinaryForm($b,0);return [Convert]::ToBase64String($b)}
function Get-WindowsUpdaterAclDescriptorDelta([string]$Before,[string]$After){
 if([string]::IsNullOrWhiteSpace($Before) -or [string]::IsNullOrWhiteSpace($After) -or $Before.Length -gt 131072 -or $After.Length -gt 131072 -or $Before.IndexOf([char]0) -ge 0 -or $After.IndexOf([char]0) -ge 0){throw 'Bounded stored descriptors are required.'}
 $a=[Security.AccessControl.RawSecurityDescriptor]::new($Before);$b=[Security.AccessControl.RawSecurityDescriptor]::new($After)
 $left=Get-WindowsUpdaterAclAceBytes $a.DiscretionaryAcl;$right=Get-WindowsUpdaterAclAceBytes $b.DiscretionaryAcl
 return [ordered]@{text_equal=($Before -ceq $After);owner_equal=([object]::Equals($a.Owner,$b.Owner));group_equal=([object]::Equals($a.Group,$b.Group));control_flags_xor=([int]$a.ControlFlags -bxor [int]$b.ControlFlags);dacl_binary_equal=((Get-WindowsUpdaterAclBytes $a.DiscretionaryAcl) -ceq (Get-WindowsUpdaterAclBytes $b.DiscretionaryAcl));sacl_binary_equal=((Get-WindowsUpdaterAclBytes $a.SystemAcl) -ceq (Get-WindowsUpdaterAclBytes $b.SystemAcl));dacl_ace_count_before=$left.Count;dacl_ace_count_after=$right.Count;dacl_ace_multiset_equal=([string]::Join('|',@($left|Sort-Object -CaseSensitive)) -ceq [string]::Join('|',@($right|Sort-Object -CaseSensitive)))}
}
function Test-WindowsUpdaterAclKeys($Value,[string[]]$Keys){
 if($Value -isnot [Collections.IDictionary] -or $Value.Count -ne $Keys.Count){return $false}
 foreach($key in $Value.Keys){if($key -isnot [string] -or $key -cnotin $Keys){return $false}};return $true
}
function Read-WindowsUpdaterAclObservation($Record){
 # Closed public metadata only. No arbitrary supplied path/SDL/hash may escape.
 try{
  if((Test-WindowsUpdaterAclKeys $Record @('schema','state')) -and ($Record.schema -is [int] -or $Record.schema -is [long]) -and $Record.schema -eq 1 -and $Record.state -ceq 'unavailable'){return @{schema=1;state='unavailable'}}
  if(!(Test-WindowsUpdaterAclKeys $Record @('schema','state','changed_count','entries','encrypted')) -or ($Record.schema -isnot [int] -and $Record.schema -isnot [long]) -or $Record.schema -ne 1 -or $Record.state -cne 'captured' -or ($Record.changed_count -isnot [int] -and $Record.changed_count -isnot [long]) -or $Record.changed_count -lt 1 -or $Record.changed_count -gt 8 -or $Record.entries -isnot [Array] -or $Record.entries.Count -ne $Record.changed_count){return $null}
  $labels=@('unknown')+@((QualificationSnapshotPaths).Values)
  foreach($entry in $Record.entries){
   if(!(Test-WindowsUpdaterAclKeys $entry @('file_label','entry_kind','descriptor_state','descriptor')) -or $entry.file_label -isnot [string] -or $entry.file_label -cnotin $labels -or $entry.entry_kind -cnotin 'file','directory','shape' -or $entry.descriptor_state -cnotin 'observed','unavailable'){return $null}
   if($entry.descriptor_state -ceq 'unavailable'){if($null -ne $entry.descriptor){return $null};continue}
   $d=$entry.descriptor
   if(!(Test-WindowsUpdaterAclKeys $d @('text_equal','owner_equal','group_equal','control_flags_xor','dacl_binary_equal','sacl_binary_equal','dacl_ace_count_before','dacl_ace_count_after','dacl_ace_multiset_equal'))){return $null}
   foreach($name in 'text_equal','owner_equal','group_equal','dacl_binary_equal','sacl_binary_equal','dacl_ace_multiset_equal'){if($d[$name] -isnot [bool]){return $null}}
   foreach($name in 'control_flags_xor','dacl_ace_count_before','dacl_ace_count_after'){if(($d[$name] -isnot [int] -and $d[$name] -isnot [long]) -or $d[$name] -lt 0 -or $d[$name] -gt 65535){return $null}}
  }
  $e=$Record.encrypted
  if(!(Test-WindowsUpdaterAclKeys $e @('schema','algorithm','public_key_sha256','aad','wrapped_key','nonce','tag','ciphertext')) -or ($e.schema -isnot [int] -and $e.schema -isnot [long]) -or $e.schema -ne 1 -or $e.algorithm -cne 'RSA3072-OAEP-SHA256+A256GCM' -or $e.public_key_sha256 -cne '3ea69ce329731abcdbfc3fc3ab68086ec8ba35e62e4eb82086c6581b05785819'){return $null}
  $decoded=@{}
  foreach($name in 'aad','wrapped_key','nonce','tag','ciphertext'){
   if($e[$name] -isnot [string] -or $e[$name].Length -gt 1398200){return $null}
   $v=[Convert]::FromBase64String($e[$name]);if([Convert]::ToBase64String($v) -cne $e[$name]){return $null};$decoded[$name]=$v
  }
  if($decoded.aad.Length -gt 2048 -or $decoded.wrapped_key.Length -ne 384 -or $decoded.nonce.Length -ne 12 -or $decoded.tag.Length -ne 16 -or $decoded.ciphertext.Length -lt 2 -or $decoded.ciphertext.Length -gt 1048576){return $null}
  $a=[Text.UTF8Encoding]::new($false,$true).GetString($decoded.aad)|ConvertFrom-Json -AsHashtable -NoEnumerate
  if(!(Test-WindowsUpdaterAclKeys $a @('schema','purpose','source_commit','run_id','stage','plaintext_bytes','plaintext_sha256')) -or ($a.schema -isnot [int] -and $a.schema -isnot [long]) -or $a.schema -ne 1 -or $a.purpose -cne 'windows-updater-file-acl-difference' -or $a.source_commit -cne $env:GITHUB_SHA -or $a.source_commit -cnotmatch '^[a-f0-9]{40}$' -or $a.run_id -cne $env:GITHUB_RUN_ID -or $a.run_id -cnotmatch '^[1-9][0-9]{0,19}$' -or $a.stage -cne 'normal_protected_files' -or ($a.plaintext_bytes -isnot [int] -and $a.plaintext_bytes -isnot [long]) -or $a.plaintext_bytes -ne $decoded.ciphertext.Length -or $a.plaintext_sha256 -cnotmatch '^[a-f0-9]{64}$'){return $null}
  return $Record
 }catch{return $null}
}
function Get-WindowsUpdaterAclObservation($Before,$After){
 # Read only the already-compared maps, never the filesystem/current permissions.
 $raw=$null
 try{
  if($Before -isnot [Collections.IDictionary] -or $After -isnot [Collections.IDictionary] -or $Before.Count -gt 100000 -or $After.Count -gt 100000){return $null}
  $keys=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach($map in $Before,$After){foreach($key in $map.Keys){if($key -isnot [string] -or $key.Length -gt 4096 -or $key.IndexOf([char]0) -ge 0){return $null};$null=$keys.Add($key)}}
  $changed=@();$entries=@();$labels=QualificationSnapshotPaths
  foreach($key in $keys){
   $left=if($Before.Contains($key)){$Before[$key]}else{$null};$right=if($After.Contains($key)){$After[$key]}else{$null}
   $same=$null -ne $left -and $null -ne $right -and $left -is [Collections.IDictionary] -and $right -is [Collections.IDictionary] -and $left.Count -eq $right.Count
   if($same){foreach($field in $left.Keys){if(!$right.Contains($field) -or ![object]::Equals($left[$field],$right[$field])){$same=$false;break}}}
   if($same){continue};if($changed.Count -ge 8){return $null}
   $changed+=,[ordered]@{path=$key;before=$left;after=$right}
   $folded=$key.Replace('\','/').ToLowerInvariant();$label=if($labels.ContainsKey($folded)){$labels[$folded]}else{'unknown'}
   $kind=if($left -is [Collections.IDictionary] -and $right -is [Collections.IDictionary] -and $left.directory -is [bool] -and $right.directory -is [bool] -and $left.directory -eq $right.directory){if($left.directory){'directory'}else{'file'}}else{'shape'}
   $delta=$null;try{if($left.acl -is [string] -and $right.acl -is [string]){$delta=Get-WindowsUpdaterAclDescriptorDelta $left.acl $right.acl}}catch{}
   $entries+=,[ordered]@{file_label=$label;entry_kind=$kind;descriptor_state=if($delta){'observed'}else{'unavailable'};descriptor=$delta}
  }
  if(!$changed.Count){return $null}
  $text=ConvertTo-Json -InputObject ([ordered]@{schema=1;source_commit=$env:GITHUB_SHA;run_id=$env:GITHUB_RUN_ID;stage='normal_protected_files';changed_records=@($changed)}) -Depth 12 -Compress
  $raw=[Text.UTF8Encoding]::new($false,$true).GetBytes($text);if($raw.Length -gt 1048576){return $null}
  $publicPath=Join-Path $PSScriptRoot 'windows_updater_file_acl_public.pem';$item=Get-Item -LiteralPath $publicPath -Force
  if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt 16384){return $null}
  $public=[Text.UTF8Encoding]::new($false,$true).GetString([IO.File]::ReadAllBytes($publicPath))
  $sealed=Seal-WindowsUpdaterAclDifference $raw $env:GITHUB_SHA $env:GITHUB_RUN_ID $public
  return Read-WindowsUpdaterAclObservation ([ordered]@{schema=1;state='captured';changed_count=[int]$changed.Count;entries=@($entries);encrypted=$sealed})
 }catch{return $null}finally{if($raw){[Array]::Clear($raw,0,$raw.Length)}}
}
