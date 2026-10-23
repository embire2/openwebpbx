# SPDX-License-Identifier: AGPL-3.0-or-later
# A source candidate collector, never a binary/licence/Store approval.
#Requires -Version 7.4
[CmdletBinding()]
param(
 [ValidateSet('Plan','Collect','InspectNative')][string]$Mode='Plan',
 [string]$Output,[string]$SdkArchive,[string]$NativeRoot,[string]$DiagnosticPath,
 [string]$SourceLock=(Join-Path (Split-Path $PSScriptRoot -Parent) 'native/source-lock.json')
)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
function SourceHash([string]$Path){return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function AssertSourceRelative([string]$Path){
 if(!$Path -or $Path.Length -gt 512 -or $Path -match '[\\:<>"|?*\x00-\x1f\x7f]' -or $Path.StartsWith('/')){throw 'Unsafe source path.'}
 foreach($part in $Path.Split('/')){if(!$part -or $part -in '.','..','.git' -or $part -match '[. ]$' -or $part -match '^(?i:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)'){throw 'Unsafe source path component.'}}
 return $Path
}
function AssertSourceUrl([string]$Url){
 $uri=$null
 if(![Uri]::TryCreate($Url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Host -cnotin 'github.com','gitlab.linphone.org' -or !$uri.IsDefaultPort -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -notmatch '^/[A-Za-z0-9._/-]+$' -or $uri.AbsolutePath.Contains('/../')){throw 'A canonical public HTTPS source URL is required.'}
 return $uri.AbsoluteUri
}
function ResolveSourceUrl([string]$Parent,[string]$Child){
 if($Child.StartsWith('../') -or $Child.StartsWith('./')){$Child=([Uri]::new([Uri]::new(($Parent.TrimEnd('/')+'/')),$Child)).AbsoluteUri}
 return AssertSourceUrl $Child
}
function ReadSourceModuleMap([string]$Text){
 $map=[ordered]@{};$section=$null
 foreach($line in $Text.Split("`n")){
  $line=$line.Trim();if(!$line -or $line.StartsWith('#') -or $line.StartsWith(';')){continue}
  if($line -match '^\[submodule "([^"\r\n]+)"\]$'){$section=$Matches[1];if($map.Contains($section)){throw 'Duplicate submodule declaration.'};$map[$section]=@{};continue}
  if(!$section -or $line -notmatch '^(path|url|branch|update|ignore|shallow)\s*=\s*(.+)$'){throw 'Unsupported submodule configuration.'}
  $key=$Matches[1];$value=$Matches[2].Trim();if($map[$section].ContainsKey($key)){throw 'Duplicate submodule field.'};$map[$section][$key]=$value
 }
 $paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
 foreach($entry in $map.Values){if(!$entry.ContainsKey('path') -or !$entry.ContainsKey('url') -or !$paths.Add((AssertSourceRelative $entry.path))){throw 'Missing or duplicate submodule path/URL.'}}
 return @($map.Values)
}
function ReadSourceGitlinks([string]$Text){
 $rows=@()
 foreach($line in $Text.Split("`n")){
  if(!$line){continue}
  if($line -notmatch '^160000 commit ([a-f0-9]{40})\t(.+)$'){throw 'Unexpected literal gitlink row.'}
  $rows+=@{path=(AssertSourceRelative $Matches[2]);commit=$Matches[1]}
 }
 return $rows
}
function ProtectSourceReadme([byte[]]$Bytes,$Rule){
 $before=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
 if($before -cne $Rule.before_sha256){throw 'The upstream documentation redaction input differs.'}
 $text=[Text.UTF8Encoding]::new($false,$true).GetString($Bytes);$lines=$text.Split("`n")
 if($lines.Count -ne $Rule.line_count -or $lines[$Rule.user_line-1] -notmatch '^user : gitlab\+deploy-token-[0-9]+\r?$' -or $lines[$Rule.password_line-1] -notmatch '^pass : [^\s]+\r?$'){throw 'The pinned documentation credential example has changed shape.'}
 $lines[$Rule.user_line-1]='user : <your registry username>';$lines[$Rule.password_line-1]='pass : <your registry token>'
 $result=[Text.UTF8Encoding]::new($false).GetBytes(($lines -join "`n"))
 $after=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($result)).ToLowerInvariant()
 if($after -cne $Rule.after_sha256){throw 'The documentation-only redaction output differs.'}
 return ,$result
}
function ReadSourcePeImports([string]$Path){
 $file=Get-Item -LiteralPath $Path
 if($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $file.Length -lt 64 -or $file.Length -gt 256MB){throw 'An ordinary bounded PE file is required.'}
 $stream=[IO.File]::OpenRead($file.FullName);$pe=$null
 try{
  $pe=[Reflection.PortableExecutable.PEReader]::new($stream);$headers=$pe.PEHeaders
  if(!$headers.PEHeader){throw 'A PE image is required.'}
  $machine=if($headers.CoffHeader.Machine -eq [Reflection.PortableExecutable.Machine]::Amd64 -and $headers.PEHeader.Magic -eq [Reflection.PortableExecutable.PEMagic]::PE32Plus){'x64'}elseif($headers.CoffHeader.Machine -eq [Reflection.PortableExecutable.Machine]::I386 -and $headers.PEHeader.Magic -eq [Reflection.PortableExecutable.PEMagic]::PE32 -and $headers.CorHeader -and ($headers.CorHeader.Flags -band [Reflection.PortableExecutable.CorFlags]::ILOnly) -and !($headers.CorHeader.Flags -band [Reflection.PortableExecutable.CorFlags]::Requires32Bit)){'managed_anycpu'}else{throw 'Only x64 native or IL-only AnyCPU PE images belong in this payload.'}
  $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  $readName={param([int]$Rva)
   if($Rva -le 0){throw 'Invalid PE import name RVA.'}
   $block=$pe.GetSectionData($Rva);[byte[]]$bytes=$block.GetContent(0,[Math]::Min(260,$block.Length))
   $end=[Array]::IndexOf($bytes,[byte]0)
   if($end -lt 1){throw 'Unterminated PE import name.'}
   $value=[Text.Encoding]::ASCII.GetString($bytes,0,$end)
   if($value -notmatch '^[A-Za-z0-9_.-]+\.dll$'){throw 'Unsafe PE import name.'}
   return $value.ToLowerInvariant()
  }
  foreach($spec in @(@($headers.PEHeader.ImportTableDirectory,20,12,0),@($headers.PEHeader.DelayImportTableDirectory,32,4,1))){
   $directory=$spec[0];if(!$directory.RelativeVirtualAddress -and !$directory.Size){continue}
   if($directory.RelativeVirtualAddress -le 0 -or $directory.Size -lt $spec[1] -or $directory.Size -gt 65536){throw 'Invalid bounded PE import table.'}
   $block=$pe.GetSectionData($directory.RelativeVirtualAddress)
   if($directory.Size -gt $block.Length){throw 'PE import table exceeds its section.'}
   [byte[]]$data=$block.GetContent(0,$directory.Size);$terminated=$false
   for($offset=0;$offset+$spec[1] -le $data.Length;$offset+=$spec[1]){
    $zero=$true;for($i=0;$i -lt $spec[1];$i++){if($data[$offset+$i]){$zero=$false;break}}
    if($zero){$terminated=$true;break}
    if($spec[3] -and [BitConverter]::ToUInt32($data,$offset) -ne 1){throw 'Unsupported VA-based delay import table.'}
    $rva=[BitConverter]::ToUInt32($data,$offset+$spec[2]);if($rva -gt [int]::MaxValue){throw 'Invalid PE name RVA.'}
    $null=$names.Add((& $readName ([int]$rva)))
   }
   if(!$terminated){throw 'Unterminated bounded PE import table.'}
  }
  return [ordered]@{schema=1;machine=$machine;managed=[bool]$headers.CorHeader;sha256=(SourceHash $file.FullName);bytes=$file.Length;imports=@($names|Sort-Object -CaseSensitive);image_loaded=$false;runtime_resolution_tested=$false;static_linkage_proven=$false}
 }finally{if($pe){$pe.Dispose()};$stream.Dispose()}
}
function InspectSourceNative([string]$Root){
 $base=Get-Item -LiteralPath $Root
 if(!$base.PSIsContainer -or ($base.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'An ordinary native payload directory is required.'}
 $items=@(Get-ChildItem -LiteralPath $base.FullName -Force -Recurse)
 if($items.Count -gt 20000 -or @($items|Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'Native inventory scope differs.'}
 $dlls=@($items|Where-Object {!$_.PSIsContainer -and $_.Extension -ieq '.dll'});if($dlls.Count -lt 1 -or $dlls.Count -gt 1024){throw 'A bounded DLL inventory is required.'}
 $known=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);foreach($file in $dlls){$null=$known.Add($file.Name)}
 $rows=@();foreach($file in $dlls){$row=ReadSourcePeImports $file.FullName;$row.path=[IO.Path]::GetRelativePath($base.FullName,$file.FullName).Replace('\','/');$row.imports_present_in_payload=@($row.imports|Where-Object {$known.Contains($_)});$row.imports_not_present_in_payload=@($row.imports|Where-Object {!$known.Contains($_)});$rows+=$row}
 return [ordered]@{schema=1;state='read_only_import_inventory_not_loader_or_source_closure';files=$rows;calls_placed=$false;binary_source_mapping_verified=$false}
}
function AssertSourceHostedOutput([string]$Path,[string]$Temp){
 $base=[IO.Path]::GetFullPath($Temp).TrimEnd([IO.Path]::DirectorySeparatorChar);$target=[IO.Path]::GetFullPath($Path)
 $comparison=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
 if(!$target.StartsWith(($base+[IO.Path]::DirectorySeparatorChar),$comparison) -or (Test-Path -LiteralPath $target)){throw 'Use a new output strictly below RUNNER_TEMP.'}
 $parent=Split-Path $target -Parent
 while($parent){
  if(Test-Path -LiteralPath $parent){$item=Get-Item -LiteralPath $parent -Force;if(!$item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Output ancestry must be ordinary directories.'}}
  if([string]::Equals($parent,$base,$comparison)){return $target}
  $parent=Split-Path $parent -Parent
 }
 throw 'Output ancestry did not reach RUNNER_TEMP.'
}
function WriteSourceJson([string]$Path,$Value){
 $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
 try{$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 30)+"`n");$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
}
function NewSourceZip([string]$Root,[string]$Path){
 $files=@(Get-ChildItem -LiteralPath $Root -File -Recurse -Force|ForEach-Object {[IO.Path]::GetRelativePath($Root,$_.FullName).Replace('\','/')})
 [Array]::Sort($files,[StringComparer]::Ordinal)
 $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$zip=$null
 try{
  $zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
  foreach($relative in $files){$null=AssertSourceRelative $relative;$entry=$zip.CreateEntry($relative,[IO.Compression.CompressionLevel]::NoCompression);$entry.LastWriteTime=[DateTimeOffset]::new(1980,1,1,0,0,0,[TimeSpan]::Zero);$entry.ExternalAttributes=0;$input=[IO.File]::OpenRead((Join-Path $Root $relative));$output=$entry.Open();try{$input.CopyTo($output)}finally{$input.Dispose();$output.Dispose()}}
 }finally{if($zip){$zip.Dispose()};$stream.Dispose()}
}
function NewSourceDiagnosticContext([string]$Path,[string]$Temp){
 $leaf=AssertSourceHostedOutput $Path $Temp;$directory=Split-Path $leaf -Parent
 if([IO.Path]::GetFileName($leaf) -cne 'collector.json' -or [IO.Path]::GetFileName($directory) -cnotmatch '^phone-source-diagnostics-[a-f0-9]{32}$' -or [IO.Path]::GetFullPath((Split-Path $directory -Parent)) -cne [IO.Path]::GetFullPath($Temp).TrimEnd([IO.Path]::DirectorySeparatorChar)){throw 'The dedicated source diagnostic scope differs.'}
 $item=Get-Item -LiteralPath $directory -Force
 if(!$item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or @(Get-ChildItem -LiteralPath $directory -Force).Count){throw 'Use an empty ordinary caller-owned source diagnostic directory.'}
 return @{path=$leaf;stage='bootstrap';operation='read_lock';source_kind='bootstrap';repository_depth=0;git_exit_code=$null}
}
function SourceDiagnosticReason([Management.Automation.ErrorRecord]$Failure){
 if(!$Failure){return 'none'}
 # Exact static guard strings only. The original message is never exported.
 $codes=@{
  'Unsafe source path.'='source_path';'Unsafe source path component.'='source_path';'A canonical public HTTPS source URL is required.'='source_url';
  'Duplicate submodule declaration.'='module_shape';'Unsupported submodule configuration.'='module_shape';'Duplicate submodule field.'='module_shape';'Missing or duplicate submodule path/URL.'='module_shape';'Unexpected literal gitlink row.'='gitlink_shape';
  'The upstream documentation redaction input differs.'='readme_input_hash';'The pinned documentation credential example has changed shape.'='readme_shape';'The documentation-only redaction output differs.'='readme_output_hash';
  'The source candidate lock differs.'='source_lock';'The exact existing SDK ZIP and a new output directory are required.'='missing_input';'The exact complete official SDK input is required.'='sdk_identity';'Insufficient capacity before source collection.'='capacity_before_collection';
  'The bounded owned source operation exceeded time/capacity.'='git_time_or_capacity';'Git metadata output exceeds its bound.'='git_output_bound';'A pinned source Git operation failed; no archive is qualified.'='git_exit_nonzero';
  'Source inventory collision or capacity bound exceeded.'='source_inventory_bound';'Unresolved required LFS content cannot be supplied as a pointer.'='unresolved_lfs';'Private signing/identity key material cannot enter first-party source.'='private_key_refused';'The pinned public-only source resource differs.'='public_key_identity';'The pinned public SubjectPublicKeyInfo differs.'='public_key_identity';'First-party credential/key material needs an exact public-only source allowance.'='unlisted_key_material';
  'Source export requires an owned repository copy.'='export_scope';'Source attributes escaped the owned copy.'='export_scope';'Unexpected source export attributes.'='export_attributes';'Unsafe source symbolic link.'='source_symlink';'A source link escapes its repository.'='source_symlink';'Unsupported or oversized source TAR entry.'='tar_shape';'A regular source file is missing its body.'='tar_shape';
  'Source graph identity or recursion bound exceeded.'='source_graph_bound';'A fetched source commit differs.'='source_commit';'Every literal gitlink requires one exact module path/URL.'='module_graph';'The locked direct SDK source graph differs.'='module_graph';'A direct SDK gitlink differs.'='module_pin';'A source module mapping is ambiguous.'='module_graph';'A locked source URL differs.'='module_url';
  'Commit the exact complete client source before collecting its source asset.'='client_not_clean';'An exact client source commit is required.'='client_commit';'A pinned public build resource is missing from the exact client source.'='missing_public_resource';
  'The exact generated C# binding is missing.'='sdk_binding';'The exact generated C# binding differs.'='sdk_binding';'The observed SDK build metadata differs.'='sdk_metadata';'SDK build metadata bytes differ.'='sdk_metadata';'A source component has no collected licence/copyright material; manual source review is required.'='missing_licence';
  'Insufficient capacity before deterministic source archive creation.'='capacity_before_archive';'The source candidate exceeds the bounded upload size.'='archive_size'
 }
 if($codes.ContainsKey($Failure.Exception.Message)){return $codes[$Failure.Exception.Message]};return 'unknown'
}
function WriteSourceDiagnostic($Context,[Management.Automation.ErrorRecord]$Failure){
 $stages=@('bootstrap','sdk_input','workspace','first_party','sdk_graph','sdk_materials','licences','packet','complete')
 $operations=@('read_lock','validate_input','prepare_work','git_init','git_status','git_rev_parse','git_fetch_local','git_fetch_https','git_ls_tree','git_show','git_archive','git_other','export_files','read_binding','read_sdk_licences','read_sdk_metadata','validate_licences','build_materials','write_manifest','create_archive','write_qualification','complete')
 $kinds=@('bootstrap','first_party','sdk_root','sdk_submodule','sdk_materials','candidate_packet')
 if($Context.stage -cnotin $stages -or $Context.operation -cnotin $operations -or $Context.source_kind -cnotin $kinds -or $Context.repository_depth -isnot [int] -or $Context.repository_depth -lt 0 -or $Context.repository_depth -gt 9){throw 'The closed source diagnostic state differs.'}
 $repositories=Get-Variable -Name allRepos -Scope Script -ErrorAction SilentlyContinue;$files=Get-Variable -Name allFiles -Scope Script -ErrorAction SilentlyContinue;$bytes=Get-Variable -Name totalBytes -Scope Script -ErrorAction SilentlyContinue
 $repoCount=if($null -eq $repositories){0}else{$repositories.Value.Count};$fileCount=if($null -eq $files){0}else{$files.Value.Count};$sourceBytes=if($null -eq $bytes){0L}else{$bytes.Value}
 foreach($count in @($repoCount,$fileCount,$sourceBytes)){if($count -isnot [int] -and $count -isnot [long]){throw 'The source diagnostic counters must be integers.'}}
 if($repoCount -lt 0 -or $repoCount -gt 128 -or $fileCount -lt 0 -or $fileCount -gt 250000 -or $sourceBytes -lt 0 -or $sourceBytes -gt 1610612736){throw 'The source diagnostic counter bounds differ.'}
 $type='none';$name='none';$line=0
 if($Failure){
  $types=@('System.Management.Automation.RuntimeException','System.Management.Automation.MethodInvocationException','System.Management.Automation.ActionPreferenceStopException','System.Management.Automation.ItemNotFoundException','System.Management.Automation.ParameterBindingException','System.Management.Automation.PropertyNotFoundException','System.Management.Automation.ParentContainsErrorRecordException','System.Management.Automation.CmdletInvocationException','System.IO.IOException','System.IO.InvalidDataException','System.IO.FileNotFoundException','System.IO.DirectoryNotFoundException','System.UnauthorizedAccessException','System.ArgumentException','System.InvalidOperationException','System.NotSupportedException','System.ComponentModel.Win32Exception','System.NullReferenceException','System.IndexOutOfRangeException')
  $observed=$Failure.Exception.GetType().FullName;$type=if($observed -cin $types){$observed}else{'other'}
  $name=if([IO.Path]::GetFileName($Failure.InvocationInfo.ScriptName) -ceq 'Collect-CorrespondingSource.ps1'){'Collect-CorrespondingSource.ps1'}else{'external_component'}
  $actualLine=$Failure.InvocationInfo.ScriptLineNumber;if($actualLine -is [int] -and $actualLine -ge 1 -and $actualLine -le 100000){$line=$actualLine}
 }
 $exit=$Context.git_exit_code;if($null -ne $exit -and ($exit -isnot [int] -and $exit -isnot [long] -or $exit -lt -2147483648L -or $exit -gt 2147483647L)){throw 'The source diagnostic Git exit differs.'}
 $record=[ordered]@{schema=1;producer='Collect-CorrespondingSource.ps1';state=$(if($Failure){'failed'}else{'completed'});stage=$Context.stage;operation=$Context.operation;source_kind=$Context.source_kind;exception_type=$type;source_basename=$name;source_line=$line;sdk_repository_count=[int]$repoCount;exported_file_count=[int]$fileCount;exported_source_bytes=[long]$sourceBytes;repository_depth=$Context.repository_depth;git_exit_code=$exit;refusal_reason=(SourceDiagnosticReason $Failure);binary_source_mapping_verified=$false;store_accepted=$false}
 if([Text.Encoding]::UTF8.GetByteCount(($record|ConvertTo-Json -Compress)) -gt 4096){throw 'The closed source diagnostic exceeds its bound.'}
 WriteSourceJson $Context.path $record
}
$sourceDiagnostic=$null;$sourcePrimaryFailure=$null
if($DiagnosticPath){
 if($Mode -cne 'Collect' -or $env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:GITHUB_REPOSITORY -cne 'embire2/openwebpbx' -or !$env:RUNNER_TEMP){throw 'An explicit hosted collection is required for a source diagnostic sidecar.'}
 $sourceDiagnostic=NewSourceDiagnosticContext $DiagnosticPath $env:RUNNER_TEMP
}
try {
# No network or owner action occurs in Plan mode.
$lock=Get-Content -LiteralPath $SourceLock -Raw|ConvertFrom-Json
if($lock.schema -ne 1 -or $lock.source.commit -cnotmatch '^[a-f0-9]{40}$' -or $lock.source.direct_gitlinks.Count -ne 31 -or $lock.qualification.official_sdk_binary_source_mapping_verified -ne $false){throw 'The source candidate lock differs.'}
if($Mode -ceq 'Plan'){
 [ordered]@{schema=1;state='HOLD_hosted_collection_not_run';source_lock_sha256=(SourceHash $SourceLock);direct_gitlinks=31;recursive_materialization='pending';source_asset_validated=$false;binary_source_mapping_verified=$false;store_accepted=$false}|ConvertTo-Json -Compress
 return
}
if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:GITHUB_REPOSITORY -cne 'embire2/openwebpbx' -or !$env:RUNNER_TEMP){throw 'Collection and native inspection require the disposable hosted repository runner.'}
if($Mode -ceq 'InspectNative'){
 $result=InspectSourceNative $NativeRoot
 if(!$Output){throw 'A native inspection output file is required.'}
 $safeOutput=AssertSourceHostedOutput $Output $env:RUNNER_TEMP;WriteSourceJson $safeOutput $result;return
}
if($sourceDiagnostic){$sourceDiagnostic.stage='sdk_input';$sourceDiagnostic.operation='validate_input'}
if(!$SdkArchive -or !$Output){throw 'The exact existing SDK ZIP and a new output directory are required.'}
$sdkFile=Get-Item -LiteralPath $SdkArchive
if($sdkFile.PSIsContainer -or ($sdkFile.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $sdkFile.Length -ne $lock.sdk.bytes -or (SourceHash $sdkFile.FullName) -cne $lock.sdk.sha256){throw 'The exact complete official SDK input is required.'}
$temp=[IO.Path]::GetFullPath($env:RUNNER_TEMP);$destination=AssertSourceHostedOutput $Output $temp
$drive=[IO.DriveInfo]::new([IO.Path]::GetPathRoot($temp));if($drive.AvailableFreeSpace -lt $lock.bounds.minimum_free_bytes){throw 'Insufficient capacity before source collection.'}
if($sourceDiagnostic){$sourceDiagnostic.stage='workspace';$sourceDiagnostic.operation='prepare_work'}
$work=Join-Path $temp ('phone-source-'+[Guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Path $work
$packet=Join-Path $work 'packet';$null=New-Item -ItemType Directory -Path $packet
$emptyConfig=Join-Path $work 'empty.gitconfig';[IO.File]::WriteAllText($emptyConfig,'')
$sterileTree=Join-Path $work 'empty-worktree';$null=New-Item -ItemType Directory -Path $sterileTree
$git=(Get-Command git -CommandType Application -ErrorAction Stop|Select-Object -First 1).Source
$allFiles=[Collections.Generic.List[object]]::new();$allRepos=[Collections.Generic.List[object]]::new();$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);$totalBytes=0L
function InvokeSourceGit([string[]]$Arguments,[switch]$MayBeAbsent){
 $diagnostic=Get-Variable -Name sourceDiagnostic -Scope Script -ValueOnly -ErrorAction SilentlyContinue
 if($diagnostic){
  $verbs=@($Arguments|Where-Object {$_ -cin 'init','status','rev-parse','fetch','ls-tree','show','archive'})
  $verb=if($verbs.Count){$verbs[0]}else{'other'}
  $diagnostic.operation=switch -CaseSensitive($verb){'init'{'git_init'}'status'{'git_status'}'rev-parse'{'git_rev_parse'}'fetch'{if($diagnostic.source_kind -ceq 'first_party'){'git_fetch_local'}else{'git_fetch_https'}}'ls-tree'{'git_ls_tree'}'show'{'git_show'}'archive'{'git_archive'}default{'git_other'}}
  $diagnostic.git_exit_code=$null
 }

 $info=[Diagnostics.ProcessStartInfo]::new($git);$info.UseShellExecute=$false;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
 foreach($arg in @('-c','credential.helper=','-c',('core.attributesFile='+$emptyConfig),'-c',('core.hooksPath='+$work+'/no-hooks'),'-c','protocol.allow=never','-c','protocol.https.allow=always','-c','http.followRedirects=false')+$Arguments){$info.ArgumentList.Add($arg)}
 $info.Environment['GIT_CONFIG_NOSYSTEM']='1';$info.Environment['GIT_CONFIG_GLOBAL']=$emptyConfig;$info.Environment['GIT_CONFIG_COUNT']='0';$info.Environment['GIT_TERMINAL_PROMPT']='0';$info.Environment['GIT_LFS_SKIP_SMUDGE']='1'
 $process=[Diagnostics.Process]::Start($info);$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync();$deadline=[DateTime]::UtcNow.AddSeconds($lock.bounds.max_git_seconds)
 try{
  while(!$process.WaitForExit(1000)){
   $used=(Get-ChildItem -LiteralPath $work -File -Recurse -Force|Measure-Object Length -Sum).Sum
   if([DateTime]::UtcNow -gt $deadline -or $used -gt $lock.bounds.max_owned_work_bytes -or $drive.AvailableFreeSpace -lt 2GB){$process.Kill($true);$process.WaitForExit();throw 'The bounded owned source operation exceeded time/capacity.'}
  }
  $text=$stdout.GetAwaiter().GetResult();$errors=$stderr.GetAwaiter().GetResult()
  if($diagnostic){$diagnostic.git_exit_code=[int]$process.ExitCode}
  if($text.Length -gt 8MB -or $errors.Length -gt 1MB){throw 'Git metadata output exceeds its bound.'}
  if($process.ExitCode -and !($MayBeAbsent -and $process.ExitCode -eq 1)){throw 'A pinned source Git operation failed; no archive is qualified.'}
  return $text
 }finally{$process.Dispose()}
}
function AssertFirstPartySourceMaterial([string]$Path,[byte[]]$Bytes){
 if(!$Path.StartsWith('client/')){return}
 $text=if($Bytes.Length -le 16MB){[Text.Encoding]::UTF8.GetString($Bytes)}else{''}
 if($text -match '(?m)^-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----\r?$'){throw 'Private signing/identity key material cannot enter first-party source.'}
 $allowed=@($lock.policy.public_material|Where-Object {('client/'+$_.path) -ceq $Path})
 if($allowed.Count){
  if($allowed.Count -ne 1 -or $text -cnotmatch '\A-----BEGIN PUBLIC KEY-----\r?\n(?:[A-Za-z0-9+/=]+\r?\n)+-----END PUBLIC KEY-----\r?\n?\z' -or ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()) -cne $allowed[0].sha256){throw 'The pinned public-only source resource differs.'}
  $der=[Convert]::FromBase64String(($text -replace '-----BEGIN PUBLIC KEY-----|-----END PUBLIC KEY-----|\s',''));if(([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($der)).ToLowerInvariant()) -cne $allowed[0].spki_der_sha256){throw 'The pinned public SubjectPublicKeyInfo differs.'}
  return
 }
 if($text -match '(?m)^-----BEGIN PUBLIC KEY-----\r?$' -or $Path -match '(^|/)(\.env(?:\..*)?|credentials|id_rsa|id_ed25519)$' -or $Path -match '\.(pfx|p12|snk|key|pem)$'){throw 'First-party credential/key material needs an exact public-only source allowance.'}
}
function AddSourceBytes([string]$Path,[byte[]]$Bytes,[string]$Kind='regular',[string]$LinkTarget='',[int]$GitMode=420){
 $null=AssertSourceRelative $Path
 if(!$seen.Add($Path) -or $Bytes.LongLength -gt $lock.bounds.max_single_source_bytes -or $allFiles.Count -ge $lock.bounds.max_source_files -or $script:totalBytes+$Bytes.LongLength -gt $lock.bounds.max_source_bytes){throw 'Source inventory collision or capacity bound exceeded.'}
 if($Bytes.Length -le 2048 -and [Text.Encoding]::ASCII.GetString($Bytes).StartsWith('version https://git-lfs.github.com/spec/v1')){throw 'Unresolved required LFS content cannot be supplied as a pointer.'}
 AssertFirstPartySourceMaterial $Path $Bytes
 $target=Join-Path $packet $Path;$null=[IO.Directory]::CreateDirectory((Split-Path $target -Parent));[IO.File]::WriteAllBytes($target,$Bytes)
 $allFiles.Add([ordered]@{path=$Path;bytes=$Bytes.LongLength;sha256=([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant());kind=$Kind;link_target=$LinkTarget;git_mode=$GitMode})
 $script:totalBytes+=$Bytes.LongLength
}
function ExportSourceRepo([string]$Repository,[string]$Commit,[string]$Prefix,[string[]]$PathFilter=@()){
 $tar=Join-Path $work ('export-'+[Guid]::NewGuid().ToString('N')+'.tar');$arguments=@('-C',$Repository,('--work-tree='+$sterileTree),'archive','--worktree-attributes','--format=tar',('--output='+$tar),$Commit);if($PathFilter.Count){$arguments+=@('--')+$PathFilter}
 # Highest-priority overrides are allowed only in our nonce-owned repository copies.
 $ownedBoundary=[IO.Path]::GetFullPath($work)+[IO.Path]::DirectorySeparatorChar
 if(![IO.Path]::GetFullPath($Repository).StartsWith($ownedBoundary,[StringComparison]::OrdinalIgnoreCase)){throw 'Source export requires an owned repository copy.'}
 $attributes=(InvokeSourceGit @('-C',$Repository,'rev-parse','--git-path','info/attributes')).Trim();if(![IO.Path]::IsPathRooted($attributes)){$attributes=Join-Path $Repository $attributes}
 if(![IO.Path]::GetFullPath($attributes).StartsWith($ownedBoundary,[StringComparison]::OrdinalIgnoreCase)){throw 'Source attributes escaped the owned copy.'}
 $override="* -export-ignore -export-subst`n"
 if((Test-Path -LiteralPath $attributes) -and [IO.File]::ReadAllText($attributes) -cne $override){throw 'Unexpected source export attributes.'}
 [IO.File]::WriteAllText($attributes,$override,[Text.UTF8Encoding]::new($false))
 $null=InvokeSourceGit $arguments
 $diagnostic=Get-Variable -Name sourceDiagnostic -Scope Script -ValueOnly -ErrorAction SilentlyContinue;if($diagnostic){$diagnostic.operation='export_files';$diagnostic.git_exit_code=$null}
 $stream=[IO.File]::OpenRead($tar);$reader=[Formats.Tar.TarReader]::new($stream)
 try{while($entry=$reader.GetNextEntry()){
  if($entry.EntryType.ToString() -in 'Directory','GlobalExtendedAttributes','ExtendedAttributes'){continue}
  $name=AssertSourceRelative $entry.Name;$path=AssertSourceRelative ($Prefix+'/'+$name)
  if($entry.EntryType.ToString() -ceq 'SymbolicLink'){
   $link=$entry.LinkName;if(!$link -or $link -match '[\\:\x00-\x1f]' -or $link.StartsWith('/')){throw 'Unsafe source symbolic link.'}
   $resolved=[IO.Path]::GetFullPath((Join-Path (Split-Path (Join-Path $packet $path) -Parent) $link));$boundary=[IO.Path]::GetFullPath((Join-Path $packet $Prefix))+[IO.Path]::DirectorySeparatorChar
   if(!$resolved.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase)){throw 'A source link escapes its repository.'}
   AddSourceBytes $path ([Text.UTF8Encoding]::new($false).GetBytes($link)) 'symlink_description' $link 511;continue
  }
  if($entry.EntryType.ToString() -cnotin 'RegularFile','V7RegularFile' -or $entry.Length -gt $lock.bounds.max_single_source_bytes){throw 'Unsupported or oversized source TAR entry.'}
  if(!$entry.Length){$bytes=[byte[]]@()}else{
   if(!$entry.DataStream){throw 'A regular source file is missing its body.'}
   $memory=[IO.MemoryStream]::new();try{$entry.DataStream.CopyTo($memory);$bytes=$memory.ToArray()}finally{$memory.Dispose()}
  }
  if($Prefix -ceq 'vendor/linphone-sdk' -and $name -ceq 'README.md'){$bytes=ProtectSourceReadme $bytes $lock.policy.readme_redaction}
  $gitMode=if(([int]$entry.Mode -band 73) -ne 0){493}else{420}
  AddSourceBytes $path $bytes 'regular' '' $gitMode
 }}finally{$reader.Dispose();$stream.Dispose();Remove-Item -LiteralPath $tar}
}
function CollectSourceRepo([string]$Url,[string]$Commit,[string]$Prefix,[int]$Depth,[bool]$RootSdk=$false){
 $diagnostic=Get-Variable -Name sourceDiagnostic -Scope Script -ValueOnly -ErrorAction SilentlyContinue;if($diagnostic){$diagnostic.stage='sdk_graph';$diagnostic.operation='validate_input';$diagnostic.git_exit_code=$null;$diagnostic.source_kind=if($RootSdk){'sdk_root'}else{'sdk_submodule'};$diagnostic.repository_depth=$Depth}
 $Url=AssertSourceUrl $Url;$null=AssertSourceRelative $Prefix
 if($Commit -cnotmatch '^[a-f0-9]{40}$' -or $Depth -gt $lock.bounds.max_recursion_depth -or $allRepos.Count -ge $lock.bounds.max_repositories){throw 'Source graph identity or recursion bound exceeded.'}
 $repo=Join-Path $work ('repository-'+$allRepos.Count);$null=InvokeSourceGit @('init','--bare',$repo);$null=InvokeSourceGit @('-C',$repo,'fetch','--no-tags','--no-recurse-submodules','--depth=1',$Url,$Commit)
 if((InvokeSourceGit @('-C',$repo,'rev-parse','FETCH_HEAD')).Trim() -cne $Commit){throw 'A fetched source commit differs.'}
 $allRepos.Add([ordered]@{path=$Prefix;url=$Url;commit=$Commit;depth=$Depth})
 $listing=InvokeSourceGit @('-C',$repo,'ls-tree','-r',$Commit)
 $linkText=(@($listing.Split("`n")|Where-Object {$_.StartsWith('160000 ')}) -join "`n");$links=@(ReadSourceGitlinks $linkText)
 $modulesText=if(@($listing.Split("`n")|Where-Object {$_ -match '\t\.gitmodules$'}).Count){InvokeSourceGit @('-C',$repo,'show',($Commit+':.gitmodules'))}else{''}
 $modules=if($modulesText){@(ReadSourceModuleMap $modulesText)}else{@()}
 if($links.Count -ne $modules.Count){throw 'Every literal gitlink requires one exact module path/URL.'}
 if($RootSdk){
  if($links.Count -ne $lock.source.direct_gitlinks.Count){throw 'The locked direct SDK source graph differs.'}
  foreach($link in $links){$expected=@($lock.source.direct_gitlinks|Where-Object {$_.path -ceq $link.path});if($expected.Count -ne 1 -or $expected[0].commit -cne $link.commit){throw 'A direct SDK gitlink differs.'}}
 }
 ExportSourceRepo $repo $Commit $Prefix
 Remove-Item -LiteralPath $repo -Recurse -Force
 foreach($link in $links){
  $module=@($modules|Where-Object {$_.path -ceq $link.path});if($module.Count -ne 1){throw 'A source module mapping is ambiguous.'}
  $origin=if($RootSdk){$lock.source.canonical_upstream_url}else{$Url};$next=ResolveSourceUrl $origin $module[0].url
  if($RootSdk){$expected=@($lock.source.direct_gitlinks|Where-Object {$_.path -ceq $link.path});if($next -cne $expected[0].url){throw 'A locked source URL differs.'}}
  CollectSourceRepo $next $link.commit ($Prefix+'/'+$link.path) ($Depth+1)
 }
}
if($sourceDiagnostic){$sourceDiagnostic.stage='first_party';$sourceDiagnostic.operation='git_status';$sourceDiagnostic.source_kind='first_party'}
$client=Split-Path $PSScriptRoot -Parent;$repository=Split-Path (Split-Path $client -Parent) -Parent
if((InvokeSourceGit @('-C',$repository,'status','--porcelain','--untracked-files=all','--','clients/windows','resources/windows-phone/release-public.pem')).Trim()){throw 'Commit the exact complete client source before collecting its source asset.'}
$clientCommit=(InvokeSourceGit @('-C',$repository,'rev-parse','HEAD')).Trim();if($clientCommit -cnotmatch '^[a-f0-9]{40}$'){throw 'An exact client source commit is required.'}
$clientCopy=Join-Path $work 'client-repository';$null=InvokeSourceGit @('init','--bare',$clientCopy)
# This single local transport exception reads only the authenticated hosted checkout.
$null=InvokeSourceGit @('-c','protocol.file.allow=always','-C',$clientCopy,'fetch','--no-tags','--no-recurse-submodules','--depth=1',$repository,$clientCommit)
ExportSourceRepo $clientCopy $clientCommit 'client' @('clients/windows','resources/windows-phone/release-public.pem')
foreach($public in $lock.policy.public_material){if(!@($allFiles|Where-Object {$_.path -ceq ('client/'+$public.path) -and $_.sha256 -ceq $public.sha256}).Count){throw 'A pinned public build resource is missing from the exact client source.'}}
Remove-Item -LiteralPath $clientCopy -Recurse -Force
CollectSourceRepo $lock.source.url $lock.source.commit 'vendor/linphone-sdk' 0 $true
if($sourceDiagnostic){$sourceDiagnostic.stage='sdk_materials';$sourceDiagnostic.operation='read_binding';$sourceDiagnostic.source_kind='sdk_materials';$sourceDiagnostic.repository_depth=0;$sourceDiagnostic.git_exit_code=$null}
$archive=[IO.Compression.ZipFile]::OpenRead($sdkFile.FullName)
try{
 $binding=@($archive.Entries|Where-Object {$_.FullName -ceq $lock.sdk.binding_path});if($binding.Count -ne 1 -or $binding[0].Length -ne $lock.sdk.binding_bytes){throw 'The exact generated C# binding is missing.'}
 $stream=$binding[0].Open();$memory=[IO.MemoryStream]::new();try{$stream.CopyTo($memory);$bytes=$memory.ToArray()}finally{$stream.Dispose();$memory.Dispose()}
 if(([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()) -cne $lock.sdk.binding_sha256){throw 'The exact generated C# binding differs.'}
 AddSourceBytes 'vendor-generated/LinphoneWrapper.cs' $bytes
 if($sourceDiagnostic){$sourceDiagnostic.operation='read_sdk_licences'}
 foreach($entry in $archive.Entries){
  if(!$entry.Name -or $entry.Length -gt 1MB -or $entry.FullName -notmatch '/(LICENSE[^/]*|LICENCE[^/]*|COPYING[^/]*|NOTICE[^/]*|COPYRIGHT[^/]*|README\.ijg|version\.txt)$'){continue}
  $stream=$entry.Open();$memory=[IO.MemoryStream]::new();try{$stream.CopyTo($memory);$bytes=$memory.ToArray()}finally{$stream.Dispose();$memory.Dispose()};AddSourceBytes ('sdk-materials/'+$entry.FullName) $bytes
 }
 if($sourceDiagnostic){$sourceDiagnostic.operation='read_sdk_metadata'}
 foreach($metadata in $lock.sdk.metadata){
  $entry=@($archive.Entries|Where-Object {$_.FullName -ceq $metadata.path});if($entry.Count -ne 1 -or $entry[0].Length -ne $metadata.bytes){throw 'The observed SDK build metadata differs.'}
  $stream=$entry[0].Open();$memory=[IO.MemoryStream]::new();try{$stream.CopyTo($memory);$bytes=$memory.ToArray()}finally{$stream.Dispose();$memory.Dispose()}
  if(([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()) -cne $metadata.sha256){throw 'SDK build metadata bytes differ.'}
  if(!$seen.Contains('sdk-materials/'+$metadata.path)){AddSourceBytes ('sdk-materials/'+$metadata.path) $bytes}
 }
}finally{$archive.Dispose()}
if($sourceDiagnostic){$sourceDiagnostic.stage='licences';$sourceDiagnostic.operation='validate_licences';$sourceDiagnostic.git_exit_code=$null}
$licenses=@($allFiles|Where-Object {$_.path -match '(?i)(^|/)(license[^/]*|licence[^/]*|copying[^/]*|notice[^/]*|copyright[^/]*|readme\.ijg)$'})
foreach($component in $allRepos){if(!@($licenses|Where-Object {$_.path.StartsWith(($component.path+'/'),[StringComparison]::Ordinal)}).Count){throw 'A source component has no collected licence/copyright material; manual source review is required.'}}
if($sourceDiagnostic){$sourceDiagnostic.stage='packet';$sourceDiagnostic.operation='build_materials';$sourceDiagnostic.source_kind='candidate_packet';$sourceDiagnostic.git_exit_code=$null}
$notes=@'
# Source candidate: not an accepted matching-binary release

All repository commits, files, licence materials and symbolic-link descriptions are in source-manifest.json.
The SDK ZIP and generated binding were hash-checked. Vendor binary-to-source/build correspondence remains unproven.
Tracked Git LFS pointers refuse collection; .git, environment, credentials and untracked client data are not exported.
The upstream README registry example is redacted using the hash-pinned documentation-only rule in source-lock.json.

Candidate source-SDK build (not a claim to reproduce the official binary):
Install the upstream README prerequisites and Visual Studio C++/Windows SDK/MSYS2 tooling on a clean Windows runner.
Restore symlink_description entries to their validated relative targets before building; executable file modes need review.
Run from vendor/linphone-sdk:
  cmake --preset=windows-sdk -B build-windows -DLINPHONESDK_WINDOWS_ARCHS=64bits -DLINPHONESDK_VERSION=5.5.23 -DLINPHONESDK_STATE=releases -DLINPHONESDK_BRANCH=source-candidate-348e8de
  cmake --build build-windows --config RelWithDebInfo
For a Store-specific candidate replace windows-sdk with windows-store-sdk.
Record the complete resolved compiler/tool versions, CMakeCache files, flags, generated headers and all linked input objects.
The source export excludes Git history. The top-level SDK version/state/branch overrides above are explicitly supported by the pinned CMakeLists.txt; all inner generated versions still require actual build qualification.
Until the source-SDK build passes, these instructions are candidates, not verified rebuild scripts.

The exact first-party client projects and build/packaging scripts are in client/clients/windows.
The hash-pinned official generated C# binding is vendor-generated/LinphoneWrapper.cs.
Use the committed global.json and project package versions; qualify resolved NuGet/runtime notices separately.
Do not substitute this source candidate for complete native call/device, MSIX/WACK, source/build or Store acceptance.
'@
AddSourceBytes 'REBUILD-NOTES.md' ([Text.UTF8Encoding]::new($false).GetBytes($notes))
$rebuild=@'
# Candidate only: no claim to reproduce the official vendor SDK.
#Requires -Version 7.4
param([Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedManifestSha256,[ValidateSet('desktop','store')][string]$Target='desktop')
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
if(!$IsWindows){throw 'The candidate SDK build requires Windows and the upstream documented C++/MSYS2 prerequisites.'}
$manifestPath=Join-Path $PSScriptRoot 'source-manifest.json'
if((Get-FileHash $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ExpectedManifestSha256){throw 'The independently published source manifest differs.'}
$manifest=Get-Content $manifestPath -Raw|ConvertFrom-Json
if($manifest.state -cne 'source_candidate_binary_correspondence_unproven' -or $manifest.files.Count -gt 250000){throw 'The bounded source candidate manifest differs.'}
foreach($file in $manifest.files){
 if($file.path -match '[\\:\x00-\x1f]' -or $file.path.StartsWith('/') -or @($file.path.Split('/')|Where-Object {$_ -in '.','..','.git'}).Count){throw 'Unsafe source manifest path.'}
 $path=Join-Path $PSScriptRoot $file.path;$item=Get-Item -LiteralPath $path
 if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -ne $file.bytes -or (Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $file.sha256){throw 'An exact source file differs.'}
}
# Descriptions are exported as ordinary files so extraction never follows a link.
# Rehydrate only after every ordinary source byte has matched the pinned manifest.
foreach($file in $manifest.files|Where-Object {$_.kind -ceq 'symlink_description'}){
 $path=Join-Path $PSScriptRoot $file.path;$target=$file.link_target
 if(!$target -or $target -match '[\\:\x00-\x1f]' -or $target.StartsWith('/')){throw 'Unsafe source link.'}
 $resolved=[IO.Path]::GetFullPath((Join-Path (Split-Path $path -Parent) $target))
 if(!$resolved.StartsWith(($PSScriptRoot+[IO.Path]::DirectorySeparatorChar),[StringComparison]::OrdinalIgnoreCase)){throw 'The source link escapes the packet.'}
 Remove-Item -LiteralPath $path;New-Item -ItemType SymbolicLink -Path $path -Target $target|Out-Null
}
$preset=if($Target -ceq 'store'){'windows-store-sdk'}else{'windows-sdk'}
$source=Join-Path $PSScriptRoot 'vendor/linphone-sdk';$build=Join-Path $PSScriptRoot ('candidate-build-'+$Target)
if(Test-Path $build){throw 'Use a clean candidate build directory.'}
Push-Location $source
try{
 & cmake ("--preset="+$preset) -B $build '-DLINPHONESDK_WINDOWS_ARCHS=64bits' '-DLINPHONESDK_VERSION=5.5.23' '-DLINPHONESDK_STATE=releases' '-DLINPHONESDK_BRANCH=source-candidate-348e8de'
 if($LASTEXITCODE){throw 'Candidate configure failed; vendor reproduction remains unqualified.'}
 & cmake --build $build --config RelWithDebInfo
 if($LASTEXITCODE){throw 'Candidate source SDK build failed.'}
}finally{Pop-Location}
Write-Host 'Candidate source SDK built. Record toolchains/cache/link inputs and qualify this new SDK and calling separately; the vendor binary was not reproduced.'
'@
AddSourceBytes 'Rebuild-CandidateSdk.ps1' ([Text.UTF8Encoding]::new($false).GetBytes($rebuild))

AddSourceBytes 'source-lock.json' ([IO.File]::ReadAllBytes($SourceLock))
$manifest=[ordered]@{schema=1;state='source_candidate_binary_correspondence_unproven';client_commit=$clientCommit;source_lock_sha256=(SourceHash $SourceLock);sdk_sha256=$lock.sdk.sha256;repositories=@($allRepos);files=@($allFiles);licences=@($licenses);documentation_redaction=$lock.policy.readme_redaction;unresolved_lfs_pointers=0;binary_source_mapping_verified=$false;store_accepted=$false}
if($sourceDiagnostic){$sourceDiagnostic.operation='write_manifest'}
WriteSourceJson (Join-Path $packet 'source-manifest.json') $manifest
$null=New-Item -ItemType Directory -Path $destination
if($drive.AvailableFreeSpace -lt $totalBytes+2GB){throw 'Insufficient capacity before deterministic source archive creation.'}
if($sourceDiagnostic){$sourceDiagnostic.operation='create_archive'}
$zipPath=Join-Path $destination ('openwebpbx-free-phone-'+$lock.client_version+'-source-candidate.zip');NewSourceZip $packet $zipPath
if((Get-Item -LiteralPath $zipPath).Length -gt $lock.bounds.max_archive_bytes){throw 'The source candidate exceeds the bounded upload size.'}
$result=[ordered]@{schema=1;state='collected_source_candidate_not_binary_correspondence';client_commit=$clientCommit;source_lock_sha256=(SourceHash $SourceLock);archive_filename=[IO.Path]::GetFileName($zipPath);archive_bytes=(Get-Item $zipPath).Length;archive_sha256=(SourceHash $zipPath);manifest_sha256=(SourceHash (Join-Path $packet 'source-manifest.json'));repositories=$allRepos.Count;files=$allFiles.Count;source_bytes=$totalBytes;licence_files=$licenses.Count;binary_source_mapping_verified=$false;source_sdk_rebuild_qualified=$false;store_accepted=$false}
if($sourceDiagnostic){$sourceDiagnostic.operation='write_qualification'}
WriteSourceJson (Join-Path $destination 'source-qualification.json') $result
[IO.File]::WriteAllText((Join-Path $destination 'SHA256SUMS'),($result.archive_sha256+'  '+$result.archive_filename+"`n"),[Text.UTF8Encoding]::new($false))
$result|ConvertTo-Json -Compress
# Preserve owned work on refusal for bounded CI diagnostics. Hosted job cleanup owns removal.

if($sourceDiagnostic){$sourceDiagnostic.stage='complete';$sourceDiagnostic.operation='complete'}
} catch {
 $sourcePrimaryFailure=$_
 throw
} finally {
 if($sourceDiagnostic){
  try{WriteSourceDiagnostic $sourceDiagnostic $sourcePrimaryFailure}catch{if(!$sourcePrimaryFailure){throw}}
 }
}
