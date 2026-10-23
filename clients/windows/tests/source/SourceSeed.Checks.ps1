# SPDX-License-Identifier: AGPL-3.0-or-later
# Actual importer/crypto/TAR/filesystem controls; no SDK/archive download.
#Requires -Version 7.4
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$client=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $client 'tools/Collect-CorrespondingSource.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The source collector does not parse.'}
foreach($name in 'SourceHash','AssertSourceRelative','AssertSourceUrl','AssertFirstPartySourceMaterial','AddSourceBytes'){
 $functions=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));if($functions.Count -ne 1){throw 'The actual source helper is ambiguous.'};. ([scriptblock]::Create($functions[0].Extent.Text))
}
. (Join-Path $client 'tools/Import-SourceSeed.ps1')
$lock=Get-Content (Join-Path $client 'native/source-lock.json') -Raw|ConvertFrom-Json
$checks=0
function CheckSeed([bool]$Value){if(!$Value){throw 'A source seed control failed.'};$script:checks++}
function DenySeed([scriptblock]$Action){$denied=$false;try{& $Action|Out-Null}catch{$denied=$true};CheckSeed $denied}
function HashSeed([byte[]]$Bytes){return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()}
CheckSeed ((GetSourceSeedBlobHash ([byte[]]@())) -ceq 'e69de29bb2d1d6434b8b29ae775ad8c2e48c5391')
$line=[Text.Encoding]::UTF8.GetBytes("fixture`r`n")
CheckSeed ([Text.Encoding]::UTF8.GetString((ConvertSourceSeedBytes $line 'lf')) -ceq "fixture`n")
CheckSeed ([Text.Encoding]::ASCII.GetString((ConvertSourceSeedBytes ([Text.Encoding]::ASCII.GetBytes('$Id: immutable-public-object $')) 'git_ident_unexpand')) -ceq '$Id$')
DenySeed {ConvertSourceSeedBytes $line 'unlisted'}
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('phone-source-seed-checks-'+[Guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Path $fixtureRoot
function ResetSeedPacket {
 $script:packet=Join-Path $fixtureRoot ([Guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Path $script:packet
 $script:allFiles=[Collections.Generic.List[object]]::new();$script:allRepos=[Collections.Generic.List[object]]::new();$script:seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);$script:totalBytes=0L
}
function SeedRecord([string]$Name,[byte[]]$Seed,[byte[]]$Source,[string]$Transform='none'){
 return [pscustomobject]@{path=$Name;mode='100644';seed_bytes=$Seed.Length;seed_sha256=(HashSeed $Seed);source_bytes=$Source.Length;source_sha256=(HashSeed $Source);git_blob_sha1=(GetSourceSeedBlobHash $Source);transform=$Transform}
}
function SeedTar([object[]]$Rows){
 $stream=[IO.MemoryStream]::new();$writer=[Formats.Tar.TarWriter]::new($stream,$true)
 try{foreach($row in $Rows){$entry=[Formats.Tar.PaxTarEntry]::new([Formats.Tar.TarEntryType]::RegularFile,('openwebpbx-android/linphone-sdk-5.5.23/'+$row.name));$entry.Mode=[IO.UnixFileMode]420;$entry.DataStream=[IO.MemoryStream]::new([byte[]]$row.bytes,$false);try{$writer.WriteEntry($entry)}finally{$entry.DataStream.Dispose()}}}finally{$writer.Dispose()}
 $stream.Position=0;return ,$stream
}
try{
 $body=[Text.Encoding]::ASCII.GetBytes("fixture license`n");$canonical=[Text.Encoding]::ASCII.GetBytes("fixture`n")
 $first=SeedRecord 'LICENSE' $body $body;$second=SeedRecord 'code.c' $line $canonical 'lf'
 $repo=[pscustomobject]@{path='';commit=$lock.source.commit;url=$lock.source.url;depth=0;tree_sha1=('a'*40)}
 $manifest=[pscustomobject]@{archive=[pscustomobject]@{sdk_prefix='openwebpbx-android/linphone-sdk-5.5.23/'};files=@($first,$second);repositories=@($repo)}
 $rows=@(@{name='LICENSE';bytes=$body},@{name='code.c';bytes=$line})
 ResetSeedPacket;$stream=SeedTar $rows
 try{$result=ImportSourceSeedMaterial $stream $manifest;CheckSeed ($result.files -eq 2 -and $result.transforms -eq 1 -and $allFiles.Count -eq 2);CheckSeed ([IO.File]::ReadAllText((Join-Path $packet 'vendor/linphone-sdk/code.c')) -ceq "fixture`n")}finally{$stream.Dispose()}
 foreach($variant in @('missing','extra','duplicate','changed','escape')){
  ResetSeedPacket;$changed=@($rows)
  switch($variant){'missing'{$changed=@($rows[0])}'extra'{$changed+=@{name='extra.c';bytes=$body}}'duplicate'{$changed+=@{name='LICENSE';bytes=$body}}'changed'{$changed=@(@{name='LICENSE';bytes=$line},$rows[1])}'escape'{$changed=@(@{name='../escape';bytes=$body},$rows[1])}}
  $stream=SeedTar $changed;try{DenySeed {ImportSourceSeedMaterial $stream $manifest}}finally{$stream.Dispose()}
 }
 foreach($field in 'seed_bytes','source_bytes'){
  $bad=$manifest|ConvertTo-Json -Depth 8|ConvertFrom-Json;$bad.files[0].$field=$true;ResetSeedPacket;$stream=SeedTar $rows;try{DenySeed {ImportSourceSeedMaterial $stream $bad}}finally{$stream.Dispose()}
 }
 $full=ReadSourceSeedManifest (Join-Path $client 'native/source-seed-files.json.gz') '1fe86c72ab7bfdbfdd2ecb25b608711a0b90d86168711469817eef82e4ed5e9a'
 CheckSeed ($full.files.Count -eq 38406 -and $full.repositories.Count -eq 33)
 DenySeed {ReadSourceSeedManifest (Join-Path $client 'native/source-seed-files.json.gz') ('0'*64)}
}finally{[IO.Directory]::Delete($fixtureRoot,$true)}
Write-Output ('PASS '+$checks+' actual source-seed helper/TAR/manifest controls; complete hosted materialization and binary correspondence remain unqualified')
