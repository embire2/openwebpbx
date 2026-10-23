# QA-only original child output retention; public key only on the disposable runner.
function Get-WindowsPhoneCatalogueOriginalPath([string]$ReportPath){
 $full=[IO.Path]::GetFullPath($ReportPath);$parent=[IO.Path]::GetDirectoryName($full)
 if([IO.Path]::GetFileName($full) -cnotmatch '^native-(Desktop|Core)\.original\.json$' -or [IO.Path]::GetFileName($parent) -cnotmatch '^OpenWebPBX-Catalogue-Qualification-[a-f0-9]{32}$'){throw 'The exact nonce-owned child report path is required.'}
 $null=Assert-OpenWebRecoveryProtected $parent -Directory -Private
 return $full+'.child-output.private.bin'
}
function Write-WindowsPhoneCatalogueOriginal([string]$ReportPath,[string]$Stdout,[string]$Stderr){
 if($Stdout.Length -gt 32768 -or $Stderr.Length -gt 32768){throw 'The original child output exceeds its unchanged bound.'}
 $path=Get-WindowsPhoneCatalogueOriginalPath $ReportPath
 $memory=[IO.MemoryStream]::new();$writer=[IO.BinaryWriter]::new($memory,[Text.Encoding]::Unicode,$true)
 try{
  # UInt32 byte lengths followed by exact UTF16LE code units, with no BOM.
  foreach($text in $Stdout,$Stderr){$writer.Write([uint32]($text.Length*2));foreach($character in $text.ToCharArray()){$writer.Write([uint16]$character)}};$writer.Flush();$raw=$memory.ToArray()
 }finally{$writer.Dispose();$memory.Dispose()}
 $sha=[Security.Cryptography.SHA256]::Create();try{$hash=([BitConverter]::ToString($sha.ComputeHash($raw))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
 $file=[IO.File]::Open($path,'CreateNew','Write','None');try{$file.Write($raw,0,$raw.Length);$file.Flush($true)}finally{$file.Dispose()}
 Set-OpenWebRecoveryPrivate $path
 $null=Assert-OpenWebRecoveryProtected $path -Private
 return (Read-WindowsPhoneCatalogueOriginalBinding ([pscustomobject]@{schema=1;bytes=$raw.Length;sha256=$hash;stdout_characters=$Stdout.Length;stderr_characters=$Stderr.Length}))
}
function Seal-WindowsPhoneCatalogueOriginal([byte[]]$Raw,[string]$SourceCommit,[string]$RunId,[string]$Edition,[string]$PublicPem,$CommitBinding=$null){
 if($PSVersionTable.PSEdition -cne 'Core' -or $Raw.Length -lt 8 -or $Raw.Length -gt 131080 -or $SourceCommit -cnotmatch '^[a-f0-9]{40}$' -or $RunId -cnotmatch '^[1-9][0-9]{0,19}$' -or $Edition -cnotin 'Desktop','Core' -or !$PublicPem.StartsWith('-----BEGIN PUBLIC KEY-----') -or $PublicPem.Contains('PRIVATE KEY')){throw 'The exact catalogue diagnostic binding is required.'}
 $sha=[Security.Cryptography.SHA256]::Create();try{$plainHash=([BitConverter]::ToString($sha.ComputeHash($Raw))).Replace('-','').ToLowerInvariant();$publicHash=([BitConverter]::ToString($sha.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($PublicPem)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
 $binding=[ordered]@{schema=1;purpose='windows-phone-catalogue-output';source_commit=$SourceCommit;run_id=$RunId;edition=$Edition;stage='finish_php_json';plaintext_bytes=$Raw.Length;plaintext_sha256=$plainHash}
 if($null-ne $CommitBinding){$commit=Read-WindowsPhoneCatalogueCommitBinding $CommitBinding;if($commit.bytes-ne $Raw.Length -or $commit.sha256-cne $plainHash){throw 'The sealed commit stream binding differs.'};$binding.stage='commit_child';$binding.encoding='uint32le-length-prefixed-raw-v1';$binding.php_child_exit=$commit.php_child_exit;$binding.php_action=$commit.php_action}
 $aad=[Text.UTF8Encoding]::new($false).GetBytes(($binding|ConvertTo-Json -Depth 4 -Compress));$rsa=[Security.Cryptography.RSA]::Create();$key=$null;$aes=$null
 try{
  $rsa.ImportFromPem($PublicPem);if($rsa.KeySize -ne 3072){throw 'The catalogue diagnostic requires RSA3072.'}
  $key=[Security.Cryptography.RandomNumberGenerator]::GetBytes(32);$nonce=[Security.Cryptography.RandomNumberGenerator]::GetBytes(12);$tag=[byte[]]::new(16);$cipher=[byte[]]::new($Raw.Length);$aes=[Security.Cryptography.AesGcm]::new($key,16);$aes.Encrypt($nonce,$Raw,$cipher,$tag,$aad)
  return [ordered]@{schema=1;algorithm='RSA3072-OAEP-SHA256+A256GCM';public_key_sha256=$publicHash;aad=[Convert]::ToBase64String($aad);wrapped_key=[Convert]::ToBase64String($rsa.Encrypt($key,[Security.Cryptography.RSAEncryptionPadding]::OaepSHA256));nonce=[Convert]::ToBase64String($nonce);tag=[Convert]::ToBase64String($tag);ciphertext=[Convert]::ToBase64String($cipher)}
 }finally{if($aes){$aes.Dispose()};if($key){[Array]::Clear($key,0,$key.Length)};$rsa.Dispose()}
}
function Protect-WindowsPhoneCatalogueOriginal([string]$ReportPath,$Original,[string]$PublicKeyPath,[string]$SourceCommit,[string]$RunId,[string]$Edition,$Output){
 $binding=Read-WindowsPhoneCatalogueOriginalBinding $Original;$outputBinding=Read-WindowsPhoneCatalogueChildOutput $Output
 if($outputBinding.stdout_characters -ne $binding.stdout_characters -or $outputBinding.stderr_characters -ne $binding.stderr_characters){throw 'The original and projected child sizes differ.'}
 $path=Get-WindowsPhoneCatalogueOriginalPath $ReportPath;$null=Assert-OpenWebRecoveryProtected $path -Private
 $raw=Read-OpenWebRecoveryBytes $path -Maximum 131080
 $sha=[Security.Cryptography.SHA256]::Create();try{$hash=([BitConverter]::ToString($sha.ComputeHash($raw))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
 if($raw.Length -ne $binding.bytes -or $hash -cne $binding.sha256 -or [BitConverter]::ToUInt32($raw,0) -ne 2*$binding.stdout_characters -or [BitConverter]::ToUInt32($raw,4+2*$binding.stdout_characters) -ne 2*$binding.stderr_characters){throw 'The exact retained original child bytes differ.'}
 $public=Read-OpenWebRecoveryBytes $PublicKeyPath -Maximum 16384
 $sha=[Security.Cryptography.SHA256]::Create();try{$hash=([BitConverter]::ToString($sha.ComputeHash($public))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
 if($hash -cne '1b26bb05b12379982b68d00e92178159049af959ba04cc483a06d1b0a49e7307'){throw 'Only the reviewed QA public key may seal catalogue diagnostics.'}
 return (Seal-WindowsPhoneCatalogueOriginal $raw $SourceCommit $RunId $Edition ([Text.UTF8Encoding]::new($false,$true).GetString($public)))
}
