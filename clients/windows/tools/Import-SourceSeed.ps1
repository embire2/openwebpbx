# SPDX-License-Identifier: AGPL-3.0-or-later
# Called only by the hosted collector. No network or SDK binary is executed.
function ConvertSourceSeedBytes([byte[]]$Bytes,[string]$Transform){
 if($Transform -ceq 'none'){return ,$Bytes}
 $text=[Text.Encoding]::Latin1.GetString($Bytes)
 if($Transform -ceq 'lf'){$text=$text.Replace("`r`n","`n")}
 elseif($Transform -ceq 'git_ident_unexpand'){$text=[regex]::Replace($text,'\$Id:[^\r\n$]*\$','$Id$')}
 else{throw 'The pinned source checkout transform differs.'}
 return ,([Text.Encoding]::Latin1.GetBytes($text))
}
function GetSourceSeedBlobHash([byte[]]$Bytes){
 $hash=[Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA1)
 try{$header=[Text.Encoding]::ASCII.GetBytes(('blob '+$Bytes.LongLength+[char]0));$hash.AppendData($header);$hash.AppendData($Bytes);return [Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant()}finally{$hash.Dispose()}
}
function ReadSourceSeedManifest([string]$Path,[string]$ExpectedSha){
 $item=Get-Item -LiteralPath $Path -Force
 if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt 8MB -or (SourceHash $item.FullName) -cne $ExpectedSha){throw 'The pinned source seed manifest differs.'}
 $file=[IO.File]::OpenRead($item.FullName);$gzip=[IO.Compression.GZipStream]::new($file,[IO.Compression.CompressionMode]::Decompress);$memory=[IO.MemoryStream]::new()
 try{
  $buffer=[byte[]]::new(131072)
  while(($read=$gzip.Read($buffer,0,$buffer.Length)) -gt 0){if($memory.Length+$read -gt 32MB){throw 'The source seed manifest exceeds its bound.'};$memory.Write($buffer,0,$read)}
  $text=[Text.UTF8Encoding]::new($false,$true).GetString($memory.ToArray());$result=$text|ConvertFrom-Json -Depth 16
 }finally{$memory.Dispose();$gzip.Dispose();$file.Dispose()}
 return $result
}
function ImportSourceSeed([string]$Archive,[string]$ManifestPath,$SeedLock){
 $manifest=ReadSourceSeedManifest $ManifestPath $SeedLock.manifest_sha256
 if($manifest.schema -isnot [long] -and $manifest.schema -isnot [int] -or $manifest.schema -ne 1 -or $manifest.purpose -cne 'exact-sdk-source-seed' -or $manifest.root_commit -cne $lock.source.commit -or $manifest.files.Count -ne 38406 -or $manifest.repositories.Count -ne 33 -or $manifest.binary_source_mapping_verified -ne $false -or $manifest.source_sdk_rebuild_qualified -ne $false){throw 'The pinned source seed identity differs.'}
 if($manifest.archive.url -cne 'https://github.com/embire2/openwebpbx/releases/download/v1.0.11/openwebpbx-1.0.11-android-source.tar.gz' -or $manifest.archive.bytes -ne 364437897 -or $manifest.archive.sha256 -cne '61784eaae91db82d79ada014dae931f01af3e2ad2f5bbcd641b288d92bf89449' -or $manifest.archive.sdk_prefix -cne 'openwebpbx-android/linphone-sdk-5.5.23/'){throw 'The immutable prior source release differs.'}
 $item=Get-Item -LiteralPath $Archive -Force
 if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -ne $manifest.archive.bytes -or (SourceHash $item.FullName) -cne $manifest.archive.sha256){throw 'The complete prior source archive differs.'}
 if(@($manifest.repositories|Where-Object {$_.depth -eq 1}).Count -ne 31){throw 'The direct seed repository count differs.'}
 $file=[IO.File]::OpenRead($item.FullName);$gzip=[IO.Compression.GZipStream]::new($file,[IO.Compression.CompressionMode]::Decompress)
 try{$proof=ImportSourceSeedMaterial $gzip $manifest}finally{$gzip.Dispose();$file.Dispose()}
 if($proof.files -ne 38406 -or $proof.source_bytes -ne 807773336 -or $proof.transforms -ne 26){throw 'The complete canonical SDK seed inventory differs.'}
}
function ImportSourceSeedMaterial([IO.Stream]$Stream,$manifest){
 $expected=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
 $caseNames=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
 foreach($record in $manifest.files){
  $name=AssertSourceRelative $record.path
  foreach($field in 'seed_bytes','source_bytes'){if($record.$field -isnot [int] -and $record.$field -isnot [long]){throw 'A source seed length has an invalid type.'}}
  if(!$caseNames.Add($name) -or $expected.ContainsKey($name) -or $record.mode -cnotin '100644','100755','120000' -or $record.transform -cnotin 'none','lf','git_ident_unexpand' -or $record.seed_bytes -lt 0 -or $record.seed_bytes -gt $lock.bounds.max_single_source_bytes -or $record.source_bytes -lt 0 -or $record.source_bytes -gt $lock.bounds.max_single_source_bytes -or $record.seed_sha256 -cnotmatch '^[a-f0-9]{64}$' -or $record.source_sha256 -cnotmatch '^[a-f0-9]{64}$' -or $record.git_blob_sha1 -cnotmatch '^[a-f0-9]{40}$'){throw 'The source seed inventory differs.'}
  $expected.Add($name,$record)
 }
 $repoNames=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
 foreach($repo in $manifest.repositories){
  $prefix=if($repo.path){$null=AssertSourceRelative $repo.path;'vendor/linphone-sdk/'+$repo.path}else{'vendor/linphone-sdk'}
  if(!$repoNames.Add($prefix) -or $repo.commit -cnotmatch '^[a-f0-9]{40}$' -or $repo.tree_sha1 -cnotmatch '^[a-f0-9]{40}$' -or $repo.depth -lt 0 -or $repo.depth -gt 8){throw 'The source seed repository graph differs.'}
  $null=AssertSourceUrl $repo.url
  if(!$repo.path -and ($repo.commit -cne $lock.source.commit -or $repo.depth -ne 0 -or $repo.url -cne $lock.source.url)){throw 'The source seed root differs.'}
  if($repo.depth -eq 1){$match=@($lock.source.direct_gitlinks|Where-Object {$_.path -ceq $repo.path});if($match.Count -ne 1 -or $match[0].commit -cne $repo.commit -or $match[0].url -cne $repo.url){throw 'A direct seed gitlink differs.'}}
  $allRepos.Add([ordered]@{path=$prefix;url=$repo.url;commit=$repo.commit;depth=$repo.depth;tree_sha1=$repo.tree_sha1;materialization='pinned_prior_source_archive'})
 }
 $loaded=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$entries=0;$scanned=0L;$sourceTotal=0L;$transforms=0
 $tar=[Formats.Tar.TarReader]::new($Stream,$true)
 try{while($entry=$tar.GetNextEntry()){
  $entries++;$scanned+=$entry.Length;if($entries -gt 50000 -or $scanned -gt 2GB){throw 'The prior source archive scan exceeds its bound.'}
  if(!$entry.Name.StartsWith($manifest.archive.sdk_prefix,[StringComparison]::Ordinal)){continue}
  $name=$entry.Name.Substring($manifest.archive.sdk_prefix.Length)
  if($entry.EntryType.ToString() -ceq 'Directory'){$null=AssertSourceRelative $name.TrimEnd('/');continue}
  $null=AssertSourceRelative $name
  if(!$expected.ContainsKey($name) -or !$loaded.Add($name)){throw 'An extra or duplicate SDK seed file was refused.'}
  $record=$expected[$name];$link='';$kind='regular';$mode=if($record.mode -ceq '100755'){493}else{420}
  if($record.mode -ceq '120000'){
   if($entry.EntryType.ToString() -cne 'SymbolicLink' -or ([int]$entry.Mode -band 511) -ne 511){throw 'An SDK seed file changed type or link mode.'}
   $link=$entry.LinkName;if(!$link -or $link -match '[\\:\x00-\x1f]' -or $link.StartsWith('/')){throw 'An SDK seed link is unsafe.'}
   $owner=@($manifest.repositories|Where-Object {!$_.path -or $name.StartsWith(($_.path+'/'),[StringComparison]::Ordinal)}|Sort-Object {$_.path.Length} -Descending)[0]
   $prefix=if($owner.path){'vendor/linphone-sdk/'+$owner.path}else{'vendor/linphone-sdk'}
   $resolved=[IO.Path]::GetFullPath((Join-Path (Split-Path (Join-Path $packet ('vendor/linphone-sdk/'+$name)) -Parent) $link));$boundary=[IO.Path]::GetFullPath((Join-Path $packet $prefix))+[IO.Path]::DirectorySeparatorChar
   if(!$resolved.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase)){throw 'An SDK seed link escapes its repository.'}
   $bytes=[Text.UTF8Encoding]::new($false).GetBytes($link);$kind='symlink_description';$mode=511
  }else{
   if($entry.EntryType.ToString() -cnotin 'RegularFile','V7RegularFile' -or $entry.Length -ne $record.seed_bytes -or ([int]$entry.Mode -band 511) -ne $mode){throw 'An SDK seed file changed mode, length or type.'}
   $memory=[IO.MemoryStream]::new()
   try{if($entry.Length){if(!$entry.DataStream){throw 'An SDK seed body is missing.'};$entry.DataStream.CopyTo($memory)};$bytes=$memory.ToArray()}finally{$memory.Dispose()}
  }
  if($bytes.LongLength -ne $record.seed_bytes -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant() -cne $record.seed_sha256){throw 'An exact SDK seed file differs.'}
  [byte[]]$canonical=ConvertSourceSeedBytes $bytes $record.transform
  if($canonical.LongLength -ne $record.source_bytes -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($canonical)).ToLowerInvariant() -cne $record.source_sha256 -or (GetSourceSeedBlobHash $canonical) -cne $record.git_blob_sha1){throw 'An SDK seed file does not match its pinned Git blob.'}
  $sourceTotal+=$canonical.LongLength;if($record.transform -cne 'none'){$transforms++}
  if($name -ceq 'README.md'){$canonical=ProtectSourceReadme $canonical $lock.policy.readme_redaction}
  AddSourceBytes ('vendor/linphone-sdk/'+$name) $canonical $kind $link $mode
 }}finally{$tar.Dispose()}
 if($loaded.Count -ne $expected.Count){throw 'A required SDK seed file is missing.'}
 return [pscustomobject]@{files=$loaded.Count;source_bytes=$sourceTotal;transforms=$transforms}
}
