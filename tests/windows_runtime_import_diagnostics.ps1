#Requires -RunAsAdministrator
#Requires -Version 7.4
[CmdletBinding()]
param([switch]$DisposableHostedRunner)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if(!$DisposableHostedRunner -or $env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows' -or $env:GITHUB_REPOSITORY -cne 'embire2/openwebpbx'){throw 'Use only the explicitly disposable Windows hosted runner.'}
$source=Split-Path $PSScriptRoot -Parent
$work=Join-Path $env:RUNNER_TEMP ('openweb-runtime-import-'+[Guid]::NewGuid().ToString('N'))
$public=Join-Path $env:RUNNER_TEMP 'openweb-vm-diagnostic-public'
$report=[ordered]@{schema=1;state='running';scope='isolated exact packaged Python imports only; no PBX install or rollback acceptance';source_commit=$env:GITHUB_SHA;run_id=$env:GITHUB_RUN_ID;cleanup_exact=$false}
$phase='artifact';$ReplayTerminalProducers=$false;$UpgradeDiagnosticsOnly=$false;$BackupsDiagnosticsOnly=$false
# Reuse only the reviewed, bounded artifact primitives. The suite entry point
# and any install/qualification functions are never evaluated.
$tokens=$null;$errors=$null;$tree=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'windows-suite.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The artifact primitive source does not parse.'}
foreach($name in 'PrivateDirectory','Hash','SafeRelative','Api','ExpandSafe','Artifact'){
 $nodes=@($tree.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$false))
 if($nodes.Count -ne 1){throw 'One exact reviewed artifact primitive is required.'}
 . ([scriptblock]::Create($nodes[0].Extent.Text))
}
function SaveReport {New-Item -ItemType Directory -Force $public|Out-Null;[IO.File]::WriteAllText((Join-Path $public 'qualification.json'),($report|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))}
function InvokePython([string]$Runtime,[string[]]$Arguments){
 $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=Join-Path $Runtime 'python.exe';$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $start.Environment['PYTHONDONTWRITEBYTECODE']='1'
 foreach($argument in $Arguments){$start.ArgumentList.Add($argument)}
 $process=[Diagnostics.Process]::Start($start);$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
 try{
  if(!$process.WaitForExit(45000)){$process.Kill($true);throw 'The owned Python import exceeded its deadline.'}
  if(!$stdout.Wait(5000) -or !$stderr.Wait(5000)){throw 'The owned Python import output did not close.'}
  if($process.ExitCode -ne 0 -or $stderr.Result.Length -ne 0){throw 'The owned Python import failed.'}
  return $stdout.Result
 }finally{$process.Dispose()}
}
function RuntimeSnapshot([string]$Runtime){
 $files=@{};$directories=@{}
 foreach($item in Get-ChildItem -LiteralPath $Runtime -Recurse -Force){
  if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Runtime links are forbidden.'}
  $relative=$item.FullName.Substring($Runtime.Length+1).Replace('\','/')
  if($item.PSIsContainer){$directories[$relative]=$true}else{$files[$relative]=Hash $item.FullName}
 }
 return @{files=$files;directories=$directories}
}
function AddedKinds($Before,$After){
 foreach($path in $Before.files.Keys){if(!$After.files.ContainsKey($path) -or $After.files[$path] -cne $Before.files[$path]){throw 'An import modified or removed an existing runtime file.'}}
 foreach($path in $Before.directories.Keys){if(!$After.directories.ContainsKey($path)){throw 'An import removed an existing directory.'}}
 $counts=[ordered]@{python_bytecode=0;dll=0;pyd=0;other_file=0;python_cache_directory=0;other_directory=0}
 foreach($path in $After.files.Keys){if(!$Before.files.ContainsKey($path)){$kind=if($path.EndsWith('.pyc',[StringComparison]::OrdinalIgnoreCase) -or $path.EndsWith('.pyo',[StringComparison]::OrdinalIgnoreCase)){'python_bytecode'}elseif($path.EndsWith('.dll',[StringComparison]::OrdinalIgnoreCase)){'dll'}elseif($path.EndsWith('.pyd',[StringComparison]::OrdinalIgnoreCase)){'pyd'}else{'other_file'};$counts[$kind]++}}
 foreach($path in $After.directories.Keys){if(!$Before.directories.ContainsKey($path)){$kind=if($path.EndsWith('/__pycache__',[StringComparison]::OrdinalIgnoreCase) -or $path -ceq '__pycache__'){'python_cache_directory'}else{'other_directory'};$counts[$kind]++}}
 return $counts
}
try{
 PrivateDirectory $work;SaveReport
 $original=Artifact '39634074138' 'replay_candidate'
 if($original.run.head_sha -cne 'd97df9e8e579d6cad0f98fe1f675f8e3074dd540' -or $original.artifact.id -ne 12363212748 -or $original.artifact.size_in_bytes -ne 584781060 -or $original.artifact.digest -cne 'sha256:e0b76f1ad2ffcd39188620195d1e00146b85ba3fa3b6cd1414aeb4ca57d29ea1'){throw 'The original immutable product artifact differs.'}
 $archive=Join-Path $original.directory 'openwebpbx-1.0.20-windows-x64.zip'
 if((Get-Item $archive).Length -ne 584780668 -or (Hash $archive) -cne '78de3f0c159900ce937b0be52aa6378273ab03633352b0b636ecf054e1baf029'){throw 'The original product ZIP differs.'}
 $report.product_source_commit=$original.run.head_sha;$report.candidate_sha256=Hash $archive
 $phase='runtime extract';SaveReport
 $runtime=Join-Path $work 'pristine';PrivateDirectory $runtime
 $zip=[IO.Compression.ZipFile]::OpenRead($archive);$root='openwebpbx-1.0.20-windows-x64/';$count=0
 try{
  $entry=$zip.GetEntry($root+'release-manifest.json');if(!$entry -or $entry.Length -gt 5MB){throw 'The immutable release manifest is unavailable.'}
  $reader=[IO.StreamReader]::new($entry.Open());try{$manifest=$reader.ReadToEnd()|ConvertFrom-Json}finally{$reader.Dispose()}
  if($manifest.version -cne '1.0.20'){throw 'The immutable release version differs.'}
  foreach($entry in $zip.Entries){
   if(!$entry.FullName.StartsWith($root+'backup-runtime/',[StringComparison]::Ordinal)){continue}
   $relative=SafeRelative $entry.FullName.Substring(($root+'backup-runtime/').Length)
   if($entry.Length -gt 100MB -or (($entry.ExternalAttributes -shr 16) -band 61440) -eq 40960){throw 'Unsafe runtime archive member.'}
   $target=Join-Path $runtime $relative;New-Item -ItemType Directory -Force (Split-Path $target -Parent)|Out-Null
   [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$target,$false)
   $expected=$manifest.files.('backup-runtime/'+$relative)
   if($expected -isnot [string] -or $expected -cnotmatch '^[a-f0-9]{64}$' -or (Hash $target) -cne $expected){throw 'A runtime member differs from the exact original manifest.'};$count++
  }
 }finally{$zip.Dispose()}
 if($count -ne 199){throw 'The original runtime member inventory is incomplete.'}
 $report.runtime_files_verified=$count
 & (Join-Path $source 'packaging/windows/Ensure-Runtime.ps1');if(!$?){throw 'The pinned Windows runtime bootstrap failed.'}
 $phase='actual imports';SaveReport
 $warm='import sys; from cryptography.hazmat.primitives.ciphers.aead import AESGCM; assert sys.version_info[:2] == (3,13); print(int(sys.dont_write_bytecode))'
 $full='import sys; from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes; from cryptography.hazmat.primitives.ciphers.aead import AESGCM; print(int(sys.dont_write_bytecode))'
 $report.cases=[ordered]@{}
 foreach($mode in 'isolated','isolated_no_bytecode'){
  $copy=Join-Path $work $mode;Copy-Item -LiteralPath $runtime -Destination $copy -Recurse
  $before=RuntimeSnapshot $copy;$arguments=@('-I');$flag='0';if($mode -ceq 'isolated_no_bytecode'){$arguments+='-B';$flag='1'}
  if((InvokePython $copy ($arguments+@('-c',$warm))).Trim() -cne $flag){throw 'The actual isolated Python bytecode policy differs.'}
  $warmed=RuntimeSnapshot $copy
  if((InvokePython $copy ($arguments+@('-c',$full))).Trim() -cne $flag){throw 'The broad import bytecode policy differs.'}
  $fullSnapshot=RuntimeSnapshot $copy
  $report.cases[$mode]=[ordered]@{aesgcm_import_added=(AddedKinds $before $warmed);broader_backup_import_added=(AddedKinds $warmed $fullSnapshot);all_imports_added=(AddedKinds $before $fullSnapshot);actual_dont_write_bytecode=($flag -ceq '1')}
  if($mode -ceq 'isolated_no_bytecode' -and ($fullSnapshot.files.Count -ne $before.files.Count -or $fullSnapshot.directories.Count -ne $before.directories.Count)){throw 'Explicit no-bytecode imports changed the pristine runtime inventory.'}
 }
 $report.state='passed';$phase='complete'
}catch{
 $report.state='failed';$report.phase=$phase;$report.error_type=$_.Exception.GetType().FullName;$report.source_line=[int]$_.InvocationInfo.ScriptLineNumber
}finally{
 # All processes are joined above and only this random owned tree is removed.
 if(Test-Path -LiteralPath $work){Remove-Item -LiteralPath $work -Recurse -Force}
 $report.cleanup_exact=!(Test-Path -LiteralPath $work);if(!$report.cleanup_exact){$report.state='failed'}
 SaveReport
}
if($report.state -cne 'passed'){throw 'The isolated exact-runtime diagnostic failed; bounded facts are retained.'}
