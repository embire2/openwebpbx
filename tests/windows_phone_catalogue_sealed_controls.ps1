# Real files and ephemeral cryptography; explicit protected-path/read adapters only.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
. (Join-Path $SourceRoot 'tests/windows_phone_catalogue_proof.ps1')
. (Join-Path $SourceRoot 'tests/windows_phone_catalogue_sealed_output.ps1')
$checks=0
function Check([bool]$Ok){if(!$Ok){throw ('Catalogue sealed-output control '+($script:checks+1)+' refused.')};$script:checks++}
function Refuse([scriptblock]$Body){$denied=$false;try{&$Body|Out-Null}catch{$denied=$true};Check $denied}
$work=Join-Path ([IO.Path]::GetTempPath()) ('OpenWebPBX-Catalogue-Qualification-'+[Guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($work)
# ACL/native path APIs are explicit test adapters. Bytes, CreateNew, flush, hashes,
# RSA3072/OAEP/AES-GCM and the source functions themselves remain actual.
function Set-OpenWebRecoveryPrivate {param([string]$Path)if(![IO.File]::Exists($Path)){throw 'Fixture private file absent.'}}
function Assert-OpenWebRecoveryProtected {param([string]$Path,[switch]$Directory,[switch]$Private)
 if($script:denyProtected){throw 'Fixture protected-path refusal.'}
 if($Directory){if(![IO.Directory]::Exists($Path)){throw 'Fixture directory absent.'}}elseif(![IO.File]::Exists($Path)){throw 'Fixture file absent.'}
 if([IO.File]::GetAttributes($Path)-band [IO.FileAttributes]::ReparsePoint){throw 'Fixture ordinary path refused.'}
}
function Read-OpenWebRecoveryBytes {param([string]$Path,[int]$Maximum)
 $bytes=[IO.File]::ReadAllBytes($Path);if($bytes.Length-gt $Maximum){throw 'Fixture bounded read refused.'};return ,$bytes
}
$denyProtected=$false;$rsa=[Security.Cryptography.RSA]::Create(3072);$small=[Security.Cryptography.RSA]::Create(2048)
function SameBytes([byte[]]$Left,[byte[]]$Right){return [Convert]::ToBase64String($Left)-ceq [Convert]::ToBase64String($Right)}
try{
 $ReportPath=Join-Path $work 'native-Desktop.original.json';$stdout="PRIVATE_ORIGINAL`r`n"+[char]0+[char]0xd800+'{}';$stderr='PRIVATE_STDERR'+[char]0xdc00
 $binding=Write-WindowsPhoneCatalogueOriginal $ReportPath $stdout $stderr
 $path=Get-WindowsPhoneCatalogueOriginalPath $ReportPath;$raw=[IO.File]::ReadAllBytes($path)
 Check ($binding.bytes-eq 8+2*($stdout.Length+$stderr.Length) -and $binding.bytes-eq $raw.Length)
 $stream=[IO.MemoryStream]::new($raw);$reader=[IO.BinaryReader]::new($stream)
 try{foreach($text in $stdout,$stderr){Check ($reader.ReadUInt32()-eq $text.Length*2);foreach($c in $text.ToCharArray()){Check ($reader.ReadUInt16()-eq [uint16]$c)}};Check ($stream.Position-eq $stream.Length)}finally{$reader.Dispose();$stream.Dispose()}
 Refuse {Write-WindowsPhoneCatalogueOriginal $ReportPath 'REPLACEMENT' ''};Check (SameBytes $raw ([IO.File]::ReadAllBytes($path)))
 Refuse {Get-WindowsPhoneCatalogueOriginalPath (Join-Path $work 'native-Other.original.json')}
 Refuse {Get-WindowsPhoneCatalogueOriginalPath (Join-Path ([IO.Path]::GetTempPath()) 'native-Core.original.json')}
 $denyProtected=$true;Refuse {Get-WindowsPhoneCatalogueOriginalPath $ReportPath};$denyProtected=$false
 Refuse {Write-WindowsPhoneCatalogueOriginal (Join-Path $work 'native-Core.original.json') ('x'*32769) ''}
 foreach($field in @($binding.Keys)){$bad=[ordered]@{};foreach($n in $binding.Keys){if($n-cne $field){$bad[$n]=$binding[$n]}};Refuse {Read-WindowsPhoneCatalogueOriginalBinding $bad}}
 foreach($change in @(@('schema',2),@('bytes',-1),@('bytes',131081),@('stdout_characters',32769),@('stderr_characters','1'),@('sha256','PRIVATE'))){$bad=[ordered]@{};foreach($n in $binding.Keys){$bad[$n]=$binding[$n]};$bad[$change[0]]=$change[1];Refuse {Read-WindowsPhoneCatalogueOriginalBinding $bad}}
 $source='a'*40;$run='40006107690';$public=$rsa.ExportSubjectPublicKeyInfoPem();$sealed=Seal-WindowsPhoneCatalogueOriginal $raw $source $run 'Desktop' $public
 Check (@($sealed.Keys).Count-eq 8 -and $sealed.algorithm-ceq 'RSA3072-OAEP-SHA256+A256GCM')
 foreach($name in 'aad','wrapped_key','nonce','tag','ciphertext'){Check ([Convert]::ToBase64String([Convert]::FromBase64String($sealed[$name]))-ceq $sealed[$name])}
 $aad=[Convert]::FromBase64String($sealed.aad);$metadata=[Text.Encoding]::UTF8.GetString($aad)|ConvertFrom-Json
 Check (@($metadata.PSObject.Properties).Count-eq 8 -and $metadata.purpose-ceq 'windows-phone-catalogue-output' -and $metadata.source_commit-ceq $source -and $metadata.run_id-ceq $run -and $metadata.edition-ceq 'Desktop' -and $metadata.stage-ceq 'finish_php_json' -and $metadata.plaintext_bytes-eq $raw.Length -and $metadata.plaintext_sha256-ceq $binding.sha256)
 $key=$rsa.Decrypt([Convert]::FromBase64String($sealed.wrapped_key),[Security.Cryptography.RSAEncryptionPadding]::OaepSHA256);$aes=[Security.Cryptography.AesGcm]::new($key,16)
 try{
  $nonce=[Convert]::FromBase64String($sealed.nonce);$tag=[Convert]::FromBase64String($sealed.tag);$cipher=[Convert]::FromBase64String($sealed.ciphertext);$plain=[byte[]]::new($cipher.Length)
  $aes.Decrypt($nonce,$cipher,$tag,$plain,$aad);Check (SameBytes $raw $plain)
  foreach($part in 'nonce','tag','cipher','aad'){$copy=([byte[]](Get-Variable -Name $part -ValueOnly)).Clone();$copy[0]=$copy[0]-bxor 1;switch($part){nonce{Refuse {$aes.Decrypt($copy,$cipher,$tag,$plain,$aad)}}tag{Refuse {$aes.Decrypt($nonce,$cipher,$copy,$plain,$aad)}}cipher{Refuse {$aes.Decrypt($nonce,$copy,$tag,$plain,$aad)}}aad{Refuse {$aes.Decrypt($nonce,$cipher,$tag,$plain,$copy)}}}}
 }finally{$aes.Dispose();[Array]::Clear($key,0,$key.Length)}
 Check (($sealed|ConvertTo-Json -Depth 5)-notmatch 'PRIVATE_ORIGINAL|PRIVATE_STDERR')
 Refuse {Seal-WindowsPhoneCatalogueOriginal $raw $source $run 'Desktop' ($small.ExportSubjectPublicKeyInfoPem())}
 Refuse {Seal-WindowsPhoneCatalogueOriginal $raw $source $run 'Desktop' '-----BEGIN PRIVATE KEY-----'}
 Refuse {Seal-WindowsPhoneCatalogueOriginal $raw 'bad' $run 'Desktop' $public}
 Refuse {Seal-WindowsPhoneCatalogueOriginal $raw $source 'bad' 'Desktop' $public}
 Refuse {Seal-WindowsPhoneCatalogueOriginal $raw $source $run 'Other' $public}
 Refuse {Seal-WindowsPhoneCatalogueOriginal ([byte[]]::new(131081)) $source $run 'Desktop' $public}
 $output=Get-WindowsPhoneCatalogueChildOutput '--refresh' $false $stdout $stderr;$publicPath=Join-Path $SourceRoot 'tests/windows_phone_catalogue_diagnostic_public.pem'
 $actual=Protect-WindowsPhoneCatalogueOriginal $ReportPath $binding $publicPath $source $run Desktop $output
 Check ($actual.public_key_sha256-ceq '1b26bb05b12379982b68d00e92178159049af959ba04cc483a06d1b0a49e7307')
 $foreign=Join-Path $work 'foreign-public.pem';[IO.File]::WriteAllText($foreign,$public)
 Refuse {Protect-WindowsPhoneCatalogueOriginal $ReportPath $binding $foreign $source $run Desktop $output}
 $badOutput=Get-WindowsPhoneCatalogueChildOutput '--refresh' $false ($stdout+'x') $stderr
 Refuse {Protect-WindowsPhoneCatalogueOriginal $ReportPath $binding $publicPath $source $run Desktop $badOutput}
 foreach($kind in 'hash','size','framing'){
  $badRaw=$raw.Clone();$badBinding=[ordered]@{};foreach($n in $binding.Keys){$badBinding[$n]=$binding[$n]}
  if($kind-ceq 'size'){$badRaw=[byte[]]($badRaw+[byte]1)}else{$badRaw[0]=$badRaw[0]-bxor 1}
  if($kind-ceq 'framing'){$hash=[Security.Cryptography.SHA256]::HashData($badRaw);$badBinding.sha256=([BitConverter]::ToString($hash)).Replace('-','').ToLowerInvariant()}
  [IO.File]::WriteAllBytes($path,$badRaw);Refuse {Protect-WindowsPhoneCatalogueOriginal $ReportPath $badBinding $publicPath $source $run Desktop $output}
 }
 [IO.File]::WriteAllBytes($path,$raw)
 $maxReport=Join-Path $work 'native-Core.original.json';$max=Write-WindowsPhoneCatalogueOriginal $maxReport ('a'*32768) ('b'*32768);Check ($max.bytes-eq 131080)
 $maxSealed=Protect-WindowsPhoneCatalogueOriginal $maxReport $max $publicPath $source $run Core (Get-WindowsPhoneCatalogueChildOutput '--refresh' $false ('a'*32768) ('b'*32768));Check (($maxSealed|ConvertTo-Json -Compress).Length-lt 262144)
}finally{$rsa.Dispose();$small.Dispose();[IO.Directory]::Delete($work,$true)}
Write-Output ('PASS '+$checks+' actual binary framing/CreateNew/hash/RSA3072/AES-GCM controls; ACL/native read adapters explicit; no native catalogue pass')
