# SPDX-License-Identifier: AGPL-3.0-or-later
# Actual metadata consumer and ZIP/hash controls; no SDK, network or signing key.
#Requires -Version 7.4
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$path=Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'tools/Collect-Source-Ci.ps1'
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The source CI wrapper does not parse.'}
foreach($name in @('AssertSourceCiResult','AssertSourceCiManifest','ReadSourceCiDiagnostic')){
 $functions=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true))
 if($functions.Count -ne 1){throw 'The exact actual consumer function is required.'}
 . ([scriptblock]::Create($functions[0].Extent.Text))
}
$checks=0
function CheckSourceCi([bool]$Ok){if(!$Ok){throw 'Source CI control failed.'};$script:checks++}
function DenySourceCi([scriptblock]$Action){$denied=$false;try{& $Action}catch{$denied=$true};CheckSourceCi $denied}
$commit='a'*40;$lock='b'*64
$fixture=[ordered]@{schema=1;state='collected_source_candidate_not_binary_correspondence';client_commit=$commit;source_lock_sha256=$lock;archive_filename='openwebpbx-free-phone-1.0.0-source-candidate.zip';archive_bytes=200;archive_sha256=('c'*64);manifest_sha256=('d'*64);repositories=32;files=1;source_bytes=2;licence_files=1;binary_source_mapping_verified=$false;source_sdk_rebuild_qualified=$false;store_accepted=$false}
function FreshSourceCi{return ($fixture|ConvertTo-Json|ConvertFrom-Json)}
AssertSourceCiResult (FreshSourceCi) $commit $lock;CheckSourceCi $true
foreach($field in @('schema','archive_bytes','repositories','files','source_bytes','licence_files')){
 foreach($value in @($true,1.0,'1')){$changed=FreshSourceCi;$changed.$field=$value;DenySourceCi {AssertSourceCiResult $changed $commit $lock}}
}
$changed=FreshSourceCi;$changed|Add-Member extra $true;DenySourceCi {AssertSourceCiResult $changed $commit $lock}
$changed=FreshSourceCi;$changed.PSObject.Properties.Remove('manifest_sha256');DenySourceCi {AssertSourceCiResult $changed $commit $lock}
foreach($field in @('binary_source_mapping_verified','source_sdk_rebuild_qualified','store_accepted')){foreach($value in @($true,0,'false')){$changed=FreshSourceCi;$changed.$field=$value;DenySourceCi {AssertSourceCiResult $changed $commit $lock}}}
foreach($field in @('archive_sha256','manifest_sha256')){$changed=FreshSourceCi;$changed.$field='E'*64;DenySourceCi {AssertSourceCiResult $changed $commit $lock}}
$root=Join-Path ([IO.Path]::GetTempPath()) ('phone-source-ci-checks-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
function MakeSourceCiZip([string]$Name,[string[]]$Entries){
 $file=Join-Path $root $Name;$stream=[IO.File]::Open($file,'CreateNew','ReadWrite','None');$zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
 try{foreach($entryName in $Entries){$entry=$zip.CreateEntry($entryName,[IO.Compression.CompressionLevel]::NoCompression);$entry.ExternalAttributes=0;$output=$entry.Open();try{$bytes=[Text.Encoding]::UTF8.GetBytes('{}');$output.Write($bytes,0,$bytes.Length)}finally{$output.Dispose()}}}finally{$zip.Dispose();$stream.Dispose()};return $file
}
try{
 $digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('{}'))).ToLowerInvariant()
 $valid=MakeSourceCiZip 'valid.zip' @('source-manifest.json','payload.txt');AssertSourceCiManifest $valid $digest 1;CheckSourceCi $true
 DenySourceCi {AssertSourceCiManifest $valid ('0'*64) 1}
 DenySourceCi {AssertSourceCiManifest $valid $digest 2}
 $duplicate=MakeSourceCiZip 'duplicate.zip' @('source-manifest.json','source-manifest.json');DenySourceCi {AssertSourceCiManifest $duplicate $digest 1}
 $missing=MakeSourceCiZip 'missing.zip' @('other.json','payload.txt');DenySourceCi {AssertSourceCiManifest $missing $digest 1}
 $diagnostic=Join-Path $root 'collector.json'
 $diagnosticFixture=[ordered]@{schema=1;producer='Collect-CorrespondingSource.ps1';state='failed';stage='sdk_graph';operation='git_fetch_https';source_kind='sdk_submodule';exception_type='System.Management.Automation.RuntimeException';source_basename='Collect-CorrespondingSource.ps1';source_line=200;sdk_repository_count=1;exported_file_count=74;exported_source_bytes=783298;repository_depth=9;git_exit_code=128;refusal_reason='git_exit_nonzero';binary_source_mapping_verified=$false;store_accepted=$false}
 function SaveSourceCiDiagnostic($Value){[IO.File]::WriteAllText($diagnostic,($Value|ConvertTo-Json),[Text.UTF8Encoding]::new($false))}
 SaveSourceCiDiagnostic $diagnosticFixture;$parsed=ReadSourceCiDiagnostic $diagnostic;CheckSourceCi ($parsed.repository_depth -eq 9 -and $parsed.git_exit_code -eq 128)
 foreach($field in @('schema','source_line','sdk_repository_count','exported_file_count','exported_source_bytes','repository_depth','git_exit_code')){
  foreach($value in @($true,1.0,'1')){$changed=$diagnosticFixture|ConvertTo-Json|ConvertFrom-Json;$changed.$field=$value;SaveSourceCiDiagnostic $changed;DenySourceCi {ReadSourceCiDiagnostic $diagnostic}}
 }
 foreach($field in @('state','stage','operation','source_kind','exception_type','source_basename','refusal_reason')){$changed=$diagnosticFixture|ConvertTo-Json|ConvertFrom-Json;$changed.$field='unlisted private text';SaveSourceCiDiagnostic $changed;DenySourceCi {ReadSourceCiDiagnostic $diagnostic}}
 $changed=$diagnosticFixture|ConvertTo-Json|ConvertFrom-Json;$changed|Add-Member extra 'unlisted';SaveSourceCiDiagnostic $changed;DenySourceCi {ReadSourceCiDiagnostic $diagnostic}
 $changed=$diagnosticFixture|ConvertTo-Json|ConvertFrom-Json;$changed.repository_depth=10;SaveSourceCiDiagnostic $changed;DenySourceCi {ReadSourceCiDiagnostic $diagnostic}
 $changed=$diagnosticFixture|ConvertTo-Json|ConvertFrom-Json;$changed.state='completed';SaveSourceCiDiagnostic $changed;DenySourceCi {ReadSourceCiDiagnostic $diagnostic}
 $changed.stage='complete';$changed.operation='complete';$changed.exception_type='none';$changed.source_basename='none';$changed.source_line=0;$changed.refusal_reason='none';SaveSourceCiDiagnostic $changed;$parsed=ReadSourceCiDiagnostic $diagnostic;CheckSourceCi ($parsed.state -ceq 'completed')
}finally{[IO.Directory]::Delete($root,$true)}
Write-Output ('PASS '+$checks+' actual source CI consumer/ZIP controls; no hosted source collection or binary correspondence claim')
