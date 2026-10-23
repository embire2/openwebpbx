# QA-only direct-child descriptor capture. No product command/argument/exit changes.
function Convert-WindowsPhoneCatalogueCommitCapture([string]$Library){
 foreach($entry in @(@("1=>['file','NUL','w']","1=>['file',(getenv('OPENWEB_CATALOGUE_COMMIT_STDOUT')?:'NUL'),'w']"),@("2=>['file','NUL','w']","2=>['file',(getenv('OPENWEB_CATALOGUE_COMMIT_STDERR')?:'NUL'),'w']"))){
  if(([regex]::Matches($Library,[regex]::Escape($entry[0]))).Count-ne 1){throw 'The exact one commit descriptor differs.'};$Library=$Library.Replace($entry[0],$entry[1])
 };return $Library
}
function Get-WindowsPhoneCatalogueCommitPaths([string]$Directory,[int]$Index){
 $full=[IO.Path]::GetFullPath($Directory)
 if([IO.Path]::GetFileName($full)-cnotmatch '^OpenWebPBX-Catalogue-QA-[a-f0-9]{32}$' -or $Index-lt 0 -or $Index-gt 1000){throw 'The exact owned PHP child namespace is required.'}
 $null=Assert-OpenWebRecoveryProtected $full -Directory -Private
 return [pscustomobject]@{stdout=(Join-Path $full ('commit-child-'+$Index+'.private.stdout.bin'));stderr=(Join-Path $full ('commit-child-'+$Index+'.private.stderr.bin'))}
}
function New-WindowsPhoneCatalogueCommitCapture([string]$Directory,[int]$Index){
 $paths=Get-WindowsPhoneCatalogueCommitPaths $Directory $Index
 foreach($path in $paths.stdout,$paths.stderr){$file=[IO.File]::Open($path,'CreateNew','Write','None');try{$file.Flush($true)}finally{$file.Dispose()};Set-OpenWebRecoveryPrivate $path;$null=Assert-OpenWebRecoveryProtected $path -Private}
 return $paths
}
function Write-WindowsPhoneCatalogueCommitOriginal([string]$ReportPath,[string]$Directory,[int]$Index,[string]$Action,[int]$ChildExit){
 $paths=Get-WindowsPhoneCatalogueCommitPaths $Directory $Index
 foreach($path in $paths.stdout,$paths.stderr){$null=Assert-OpenWebRecoveryProtected $path -Private}
 $stdout=Read-OpenWebRecoveryBytes $paths.stdout -Maximum 65536;$stderr=Read-OpenWebRecoveryBytes $paths.stderr -Maximum 65536
 $path=(Get-WindowsPhoneCatalogueOriginalPath $ReportPath)+'.commit'
 $memory=[IO.MemoryStream]::new();$writer=[IO.BinaryWriter]::new($memory,[Text.Encoding]::UTF8,$true)
 try{foreach($bytes in $stdout,$stderr){$writer.Write([uint32]$bytes.Length);$writer.Write([byte[]]$bytes)};$writer.Flush();$raw=$memory.ToArray()}finally{$writer.Dispose();$memory.Dispose()}
 $sha=[Security.Cryptography.SHA256]::Create();try{$hash=([BitConverter]::ToString($sha.ComputeHash($raw))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
 $actionSafe=(Get-WindowsPhoneCatalogueChildOutput $Action $true '' '').action
 $binding=Read-WindowsPhoneCatalogueCommitBinding ([pscustomobject]@{schema=1;bytes=$raw.Length;sha256=$hash;stdout_bytes=$stdout.Length;stderr_bytes=$stderr.Length;php_action=$actionSafe;php_child_exit=$ChildExit})
 $file=[IO.File]::Open($path,'CreateNew','Write','None');try{$file.Write($raw,0,$raw.Length);$file.Flush($true)}finally{$file.Dispose()};Set-OpenWebRecoveryPrivate $path;$null=Assert-OpenWebRecoveryProtected $path -Private
 return $binding
}
function Protect-WindowsPhoneCatalogueCommitOriginal([string]$ReportPath,$Original,[string]$PublicKeyPath,[string]$SourceCommit,[string]$RunId,[string]$Edition,[int]$ChildExit){
 $binding=Read-WindowsPhoneCatalogueCommitBinding $Original;if($binding.php_child_exit-ne $ChildExit){throw 'The original PHP child exit differs.'}
 $path=(Get-WindowsPhoneCatalogueOriginalPath $ReportPath)+'.commit';$null=Assert-OpenWebRecoveryProtected $path -Private
 $raw=Read-OpenWebRecoveryBytes $path -Maximum 131080
 $sha=[Security.Cryptography.SHA256]::Create();try{$hash=([BitConverter]::ToString($sha.ComputeHash($raw))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
 if($raw.Length-ne $binding.bytes -or $hash-cne $binding.sha256 -or [BitConverter]::ToUInt32($raw,0)-ne $binding.stdout_bytes -or [BitConverter]::ToUInt32($raw,4+$binding.stdout_bytes)-ne $binding.stderr_bytes){throw 'The exact retained commit stream bytes differ.'}
 $public=Read-OpenWebRecoveryBytes $PublicKeyPath -Maximum 16384
 $sha=[Security.Cryptography.SHA256]::Create();try{$hash=([BitConverter]::ToString($sha.ComputeHash($public))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
 if($hash-cne '1b26bb05b12379982b68d00e92178159049af959ba04cc483a06d1b0a49e7307'){throw 'Only the reviewed QA public key may seal commit diagnostics.'}
 return (Seal-WindowsPhoneCatalogueOriginal $raw $SourceCommit $RunId $Edition ([Text.UTF8Encoding]::new($false,$true).GetString($public)) $binding)
}
