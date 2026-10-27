# QA-only failure evidence; exact database acceptance is unchanged.
function Seal-WindowsUpdaterDatabaseDifference([byte[]]$Raw,[string]$SourceCommit,[string]$RunId,[string]$PublicPem){
 if($PSVersionTable.PSEdition -cne 'Core' -or $Raw.Length -lt 2 -or $Raw.Length -gt 1048576 -or $SourceCommit -cnotmatch '^[a-f0-9]{40}$' -or $RunId -cnotmatch '^[1-9][0-9]{0,19}$' -or !$PublicPem.StartsWith('-----BEGIN PUBLIC KEY-----') -or $PublicPem.Contains('PRIVATE KEY')){throw 'The exact updater ACL diagnostic binding is required.'}
 $sha=[Security.Cryptography.SHA256]::Create();try{$plainHash=([BitConverter]::ToString($sha.ComputeHash($Raw))).Replace('-','').ToLowerInvariant();$publicHash=([BitConverter]::ToString($sha.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($PublicPem)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
 if($publicHash -cne '3ea69ce329731abcdbfc3fc3ab68086ec8ba35e62e4eb82086c6581b05785819'){throw 'Only the Root-owned diagnostic public recipient is permitted.'}
 $binding=[ordered]@{schema=1;purpose='windows-updater-database-difference';source_commit=$SourceCommit;run_id=$RunId;stage='normal_database';plaintext_bytes=$Raw.Length;plaintext_sha256=$plainHash}
 $aad=[Text.UTF8Encoding]::new($false).GetBytes(($binding|ConvertTo-Json -Depth 4 -Compress));$rsa=[Security.Cryptography.RSA]::Create();$key=$null;$aes=$null
 try{
  $rsa.ImportFromPem($PublicPem);if($rsa.KeySize -ne 3072){throw 'The catalogue diagnostic requires RSA3072.'}
  $key=[Security.Cryptography.RandomNumberGenerator]::GetBytes(32);$nonce=[Security.Cryptography.RandomNumberGenerator]::GetBytes(12);$tag=[byte[]]::new(16);$cipher=[byte[]]::new($Raw.Length);$aes=[Security.Cryptography.AesGcm]::new($key,16);$aes.Encrypt($nonce,$Raw,$cipher,$tag,$aad)
  return [ordered]@{schema=1;algorithm='RSA3072-OAEP-SHA256+A256GCM';public_key_sha256=$publicHash;aad=[Convert]::ToBase64String($aad);wrapped_key=[Convert]::ToBase64String($rsa.Encrypt($key,[Security.Cryptography.RSAEncryptionPadding]::OaepSHA256));nonce=[Convert]::ToBase64String($nonce);tag=[Convert]::ToBase64String($tag);ciphertext=[Convert]::ToBase64String($cipher)}
 }finally{if($aes){$aes.Dispose()};if($key){[Array]::Clear($key,0,$key.Length)};$rsa.Dispose()}
}
function Read-WindowsUpdaterDatabaseObservation($Record){
 try{
  if((Test-WindowsUpdaterAclKeys $Record @('schema','state')) -and ($Record.schema -is [int] -or $Record.schema -is [long]) -and $Record.schema -eq 1 -and $Record.state -ceq 'unavailable'){return @{schema=1;state='unavailable'}}
  if(!(Test-WindowsUpdaterAclKeys $Record @('schema','state','changed_table_count','encrypted')) -or ($Record.schema -isnot [int] -and $Record.schema -isnot [long]) -or $Record.schema -ne 1 -or $Record.state -cne 'captured' -or ($Record.changed_table_count -isnot [int] -and $Record.changed_table_count -isnot [long]) -or $Record.changed_table_count -lt 1 -or $Record.changed_table_count -gt 8){return $null}
$e=$Record.encrypted
  if(!(Test-WindowsUpdaterAclKeys $e @('schema','algorithm','public_key_sha256','aad','wrapped_key','nonce','tag','ciphertext')) -or ($e.schema -isnot [int] -and $e.schema -isnot [long]) -or $e.schema -ne 1 -or $e.algorithm -cne 'RSA3072-OAEP-SHA256+A256GCM' -or $e.public_key_sha256 -cne '3ea69ce329731abcdbfc3fc3ab68086ec8ba35e62e4eb82086c6581b05785819'){return $null}
  $decoded=@{}
  foreach($name in 'aad','wrapped_key','nonce','tag','ciphertext'){
   if($e[$name] -isnot [string] -or $e[$name].Length -gt 1398200){return $null}
   $v=[Convert]::FromBase64String($e[$name]);if([Convert]::ToBase64String($v) -cne $e[$name]){return $null};$decoded[$name]=$v
  }
  if($decoded.aad.Length -gt 2048 -or $decoded.wrapped_key.Length -ne 384 -or $decoded.nonce.Length -ne 12 -or $decoded.tag.Length -ne 16 -or $decoded.ciphertext.Length -lt 2 -or $decoded.ciphertext.Length -gt 1048576){return $null}
  $a=[Text.UTF8Encoding]::new($false,$true).GetString($decoded.aad)|ConvertFrom-Json -AsHashtable -NoEnumerate
  if(!(Test-WindowsUpdaterAclKeys $a @('schema','purpose','source_commit','run_id','stage','plaintext_bytes','plaintext_sha256')) -or ($a.schema -isnot [int] -and $a.schema -isnot [long]) -or $a.schema -ne 1 -or $a.purpose -cne 'windows-updater-database-difference' -or $a.source_commit -cne $env:GITHUB_SHA -or $a.source_commit -cnotmatch '^[a-f0-9]{40}$' -or $a.run_id -cne $env:GITHUB_RUN_ID -or $a.run_id -cnotmatch '^[1-9][0-9]{0,19}$' -or $a.stage -cne 'normal_database' -or ($a.plaintext_bytes -isnot [int] -and $a.plaintext_bytes -isnot [long]) -or $a.plaintext_bytes -ne $decoded.ciphertext.Length -or $a.plaintext_sha256 -cnotmatch '^[a-f0-9]{64}$'){return $null}
  return $Record
 }catch{return $null}
}
function Read-WindowsUpdaterDatabaseBytes([string]$Path,[int]$Maximum){
 $item=Get-Item -LiteralPath $Path -Force
 if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt $Maximum){throw 'Bounded diagnostic input required.'}
 $stream=[IO.File]::Open($Path,'Open','Read','Read');$memory=[IO.MemoryStream]::new()
 try{$buffer=[byte[]]::new(65536);while(($n=$stream.Read($buffer,0,[Math]::Min($buffer.Length,$Maximum+1-$memory.Length))) -gt 0){$memory.Write($buffer,0,$n);if($memory.Length -gt $Maximum){throw 'Bounded diagnostic input required.'}};return ,$memory.ToArray()}finally{$stream.Dispose();$memory.Dispose()}
}
function Get-WindowsUpdaterDatabaseObservation($Before,$After,[string]$Directory){
 $raw=$null;$auditKey=$null;$hmac=$null
 try{
  foreach($side in @($Before,$After)){if($side -isnot [Collections.IDictionary] -or $side.values -isnot [Collections.IDictionary] -or $side.values.Count -gt 1000){return $null}}
  $maps=@($Before.values,$After.values);$tables=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach($map in $maps){foreach($table in $map.Keys){if($table -isnot [string] -or $table -cnotmatch '^[a-z_][a-z0-9_]{0,62}$' -or $map[$table] -isnot [string] -or $map[$table] -cnotmatch '^[a-f0-9]{64}$'){return $null};$null=$tables.Add($table)}}
  $changed=@()
  foreach($table in $tables){
   $left=$Before.values.Contains($table);$right=$After.values.Contains($table)
   if($left -and $right -and $Before.values[$table] -ceq $After.values[$table]){continue};if($changed.Count -ge 8){return $null}
   $changed+=,[ordered]@{table=$table;before=if($left){[ordered]@{digest=$Before.values[$table];rows_json=$null;rows_bytes=$null;rows_sha256=$null}}else{$null};after=if($right){[ordered]@{digest=$After.values[$table];rows_json=$null;rows_bytes=$null;rows_sha256=$null}}else{$null}}
  }
  if(!$changed.Count){return $null};$rowsState='unavailable'
  # Exact compared names/digests survive even if optional row capture is unavailable.
  try{
   $auditKey=Read-WindowsUpdaterDatabaseBytes (Join-Path $Directory 'audit.key') 32;if($auditKey.Length -ne 32){throw 'Exact sidecar binding unavailable.'};$hmac=[Security.Cryptography.HMACSHA256]::new($auditKey)
   $captures=@();$labels=@('before-fault','after-normal')
   for($i=0;$i -lt 2;$i++){
    $bytes=Read-WindowsUpdaterDatabaseBytes (Join-Path $Directory ($labels[$i]+'-database-rows.private.json')) 8388608
    $capture=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)|ConvertFrom-Json -AsHashtable -NoEnumerate
    if(!(Test-WindowsUpdaterAclKeys $capture @('schema','state','source_commit','run_id','label','tables')) -or ($capture.schema -isnot [int] -and $capture.schema -isnot [long]) -or $capture.schema -ne 1 -or $capture.state -cne 'captured' -or $capture.source_commit -isnot [string] -or $capture.source_commit -cne $env:GITHUB_SHA -or $capture.run_id -isnot [string] -or $capture.run_id -cne $env:GITHUB_RUN_ID -or $capture.label -isnot [string] -or $capture.label -cne $labels[$i] -or $capture.tables -isnot [Collections.IDictionary] -or $capture.tables.Count -ne $maps[$i].Count){throw 'Exact sidecar binding unavailable.'}
    foreach($table in $maps[$i].Keys){
     if(!$capture.tables.Contains($table)){throw 'Exact sidecar binding unavailable.'};$entry=$capture.tables[$table]
     if(!(Test-WindowsUpdaterAclKeys $entry @('digest','rows_json')) -or $entry.digest -isnot [string] -or $entry.digest -cne $maps[$i][$table] -or $entry.rows_json -isnot [string] -or $entry.rows_json.Length -gt 8388608){throw 'Exact sidecar binding unavailable.'}
     $canonical=[Text.UTF8Encoding]::new($false,$true).GetBytes($entry.rows_json);$digest=([BitConverter]::ToString($hmac.ComputeHash($canonical))).Replace('-','').ToLowerInvariant()
     if($digest -cne $entry.digest){throw 'Exact sidecar binding unavailable.'}
    }
    $captures+=,$capture
   }
   foreach($entry in $changed){
    for($i=0;$i -lt 2;$i++){$name=if($i -eq 0){'before'}else{'after'};if($null -ne $entry[$name]){$text=$captures[$i].tables[$entry.table].rows_json;$canonical=[Text.UTF8Encoding]::new($false,$true).GetBytes($text);$entry[$name].rows_json=$text;$entry[$name].rows_bytes=$canonical.Length;$entry[$name].rows_sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($canonical)).ToLowerInvariant()}}
   }
   $rowsState='exact'
  }catch{}
  $text=ConvertTo-Json -InputObject ([ordered]@{schema=1;source_commit=$env:GITHUB_SHA;run_id=$env:GITHUB_RUN_ID;stage='normal_database';rows_state=$rowsState;changed_tables=@($changed)}) -Depth 8 -Compress
  $raw=[Text.UTF8Encoding]::new($false,$true).GetBytes($text)
  if($raw.Length -gt 1048576){
   foreach($entry in $changed){if($entry.before){$entry.before.rows_json=$null};if($entry.after){$entry.after.rows_json=$null}}
   [Array]::Clear($raw,0,$raw.Length)
   $text=ConvertTo-Json -InputObject ([ordered]@{schema=1;source_commit=$env:GITHUB_SHA;run_id=$env:GITHUB_RUN_ID;stage='normal_database';rows_state='omitted_cap';changed_tables=@($changed)}) -Depth 8 -Compress
   $raw=[Text.UTF8Encoding]::new($false,$true).GetBytes($text);if($raw.Length -gt 1048576){return $null}
  }
  $publicBytes=Read-WindowsUpdaterDatabaseBytes (Join-Path $PSScriptRoot 'windows_updater_file_acl_public.pem') 16384;$public=[Text.UTF8Encoding]::new($false,$true).GetString($publicBytes)
  $encrypted=Seal-WindowsUpdaterDatabaseDifference $raw $env:GITHUB_SHA $env:GITHUB_RUN_ID $public
  return Read-WindowsUpdaterDatabaseObservation ([ordered]@{schema=1;state='captured';changed_table_count=[int]$changed.Count;encrypted=$encrypted})
 }catch{return $null}finally{if($hmac){$hmac.Dispose()};if($auditKey){[Array]::Clear($auditKey,0,$auditKey.Length)};if($raw){[Array]::Clear($raw,0,$raw.Length)}}
}
