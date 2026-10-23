#Requires -Version 7.4
[CmdletBinding()]
param(
 [Parameter(Mandatory)][string]$SdkZip,
 [Parameter(Mandatory)][string]$CoreMsi,
 [Parameter(Mandatory)][string]$EngineZip,
 [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string]$SourceCommit,
 [Parameter(Mandatory)][string]$Report
)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows' -or $env:GITHUB_REPOSITORY -cne 'embire2/openwebpbx' -or !$IsWindows){throw 'Only the disposable hosted Windows client lab is allowed.'}
if((Test-Path 'C:\OpenWebPBX') -or (Test-Path (Join-Path $env:ProgramData 'OpenWebPBX'))){throw 'An installed PBX is outside this lab.'}
$client=Split-Path $PSScriptRoot -Parent;$repo=Split-Path (Split-Path $client -Parent) -Parent
$temp=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\');$prefix=$temp+'\'
function Hash([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Ordinary([string]$Path,[bool]$Exists=$true){
 $full=[IO.Path]::GetFullPath($Path)
 if(!$full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Only this runner temporary tree is allowed.'}
 $parent=[IO.DirectoryInfo]::new([IO.Path]::GetDirectoryName($full))
 while($parent){if(!$parent.Exists -or ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Linked or absent input ancestry.'};$parent=$parent.Parent}
 if(Test-Path -LiteralPath $full){$item=Get-Item -LiteralPath $full -Force;if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'An ordinary file is required.'}}elseif($Exists){throw 'Required input is absent.'}
 $full
}
foreach($inputPath in @($SdkZip,$CoreMsi,$EngineZip)){[void](Ordinary $inputPath)}
$sealedOutput=Ordinary (Join-Path $temp 'client-media-private.sealed.json') $false;if(Test-Path -LiteralPath $sealedOutput){throw 'The encrypted diagnostic output must be new.'}
$Report=Ordinary $Report $false;if(Test-Path -LiteralPath $Report){throw 'The output must be new.'}
if((Get-Item $SdkZip).Length -ne 315960147 -or (Hash $SdkZip) -cne '9cc84037333daca88af24804e20b9d1f5e41ddd901578484b57dcc6720a8d297' -or (Get-Item $CoreMsi).Length -ne 168300544 -or (Hash $CoreMsi) -cne 'f5649e33ad46be2ebdb1d98019bd149c86519f0dca9f47fb881207045203a34d' -or (Get-Item $EngineZip).Length -ne 39161015 -or (Hash $EngineZip) -cne '3d4091bd972c1ea82ff9b6899c091dbeebf66416d6d76475add523ebe10a7542'){throw 'Exact previously accepted component inputs are required.'}
if(([IO.DriveInfo]::new([IO.Path]::GetPathRoot($temp))).AvailableFreeSpace -lt 6GB){throw 'The disposable media lab needs six GiB free capacity.'}
Push-Location $repo
try{$head=(& git rev-parse HEAD).Trim();if($LASTEXITCODE -or $head -cne $SourceCommit -or (& git status --porcelain)){throw 'The exact clean client source is required.'}}finally{Pop-Location}
function ResolveMediaApplication {
 param([ValidateSet('dotnet','python')][string]$Name)
 $command=Get-Command $Name -CommandType Application -ErrorAction Stop|Select-Object -First 1
 if($null -eq $command -or $command -isnot [Management.Automation.ApplicationInfo] -or $command.CommandType -ne [Management.Automation.CommandTypes]::Application){throw 'One native application command is required.'}
 [string]$path=$command.Source
 if(!$path -or ![IO.Path]::IsPathFullyQualified($path) -or [IO.Path]::GetExtension($path) -ine '.exe' -or $path -cne [string]$command.Path -or ![string]::Equals([IO.Path]::GetFullPath($path),$path,[StringComparison]::OrdinalIgnoreCase)){throw 'A concrete fully-qualified executable is required.'}
 $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
 if($item -isnot [IO.FileInfo] -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -le 0){throw 'An existing ordinary executable is required.'}
 return $path
}
$dotnet=ResolveMediaApplication dotnet;$python=ResolveMediaApplication python
Push-Location $client
try{if((& $dotnet --version).Trim() -cne '10.0.401'){throw 'The exact .NET SDK is required.'}}finally{Pop-Location}
function PrivateDirectory([string]$Path){
 if(Test-Path -LiteralPath $Path){throw 'A new owned scope is required.'};[void][IO.Directory]::CreateDirectory($Path)
 $acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetAccessRuleProtection($true,$false)
 $user=[Security.Principal.WindowsIdentity]::GetCurrent().User
 foreach($sid in @($user,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'))){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
 [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($Path),$acl)
}
function NoLinks([string]$Path){
 $pending=[Collections.Generic.Stack[string]]::new();$pending.Push($Path);$count=0
 while($pending.Count){$next=$pending.Pop();$item=Get-Item -LiteralPath $next -Force;if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Owned cleanup refuses a linked entry.'};if(++$count -gt 30000){throw 'Owned tree exceeds its cleanup bound.'};if($item.PSIsContainer){foreach($entry in [IO.Directory]::EnumerateFileSystemEntries($next)){$pending.Push($entry)}}}
}
function ExpandSdk([string]$Archive,[string]$Target){
 PrivateDirectory $Target;$zip=[IO.Compression.ZipFile]::OpenRead($Archive);$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);[long]$total=0;$count=0
 try{
  if($zip.Entries.Count -gt 20000){throw 'The SDK member count is unbounded.'}
  foreach($entry in $zip.Entries){
   $name=$entry.FullName;if($name.Length -gt 240 -or $name -match '(^/|\\|:|\x00|(^|/)\.\.?(/|$))' -or !$seen.Add($name.TrimEnd('/')) -or (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000){throw 'Unsafe or duplicate SDK ZIP member.'}
   $relative=$null
   if($name -cmatch '^linphone-sdk/win64/bin/([^/]+\.dll)$' -and $Matches[1] -notmatch 'tester|bcunit'){$relative=$Matches[1]}
   elseif($name -cmatch '^linphone-sdk/win64/lib/mediastreamer/plugins/(libmswasapi\.dll|libmswebrtc\.dll)$'){$relative='native/plugins/'+$Matches[1]}
   elseif($name -cmatch '^linphone-sdk/win64/share/((?:belr|linphone|sounds|images)/.+[^/])$'){$relative='native/share/'+$Matches[1]}
   elseif($name -ceq 'linphone-sdk/win64/share/linphonecs/LinphoneWrapper.cs'){$relative='LinphoneWrapper.cs'}
   if(!$relative){continue};$total+=$entry.Length;if(++$count -gt 8000 -or $entry.Length -gt 256MB -or $total -gt 1GB){throw 'Selected SDK data exceeds bounds.'}
   $targetFile=Join-Path $Target $relative;[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($targetFile));$input=$entry.Open();$output=[IO.File]::Open($targetFile,'CreateNew','Write','None')
   try{$input.CopyTo($output);$output.Flush($true)}finally{$output.Dispose();$input.Dispose()}
   if((Get-Item $targetFile).Length -ne $entry.Length){throw 'SDK extraction is incomplete.'}
  }
 }finally{$zip.Dispose()}
 if((Hash (Join-Path $Target 'LinphoneWrapper.cs')) -cne 'a99c5197be469d58812afc33a2adb104505134b9a03ac7654d11e4e4341d3a15'){throw 'The exact official C# binding differs.'}
 foreach($name in @('liblinphone.dll','native/plugins/libmswasapi.dll','native/plugins/libmswebrtc.dll')){if(!(Test-Path (Join-Path $Target $name))){throw 'Required SDK runtime dependency is absent.'}}
 $grammars=Get-Content (Join-Path $client 'native/runtime-resources.json') -Raw|ConvertFrom-Json
 if($grammars.files.Count -ne 8){throw 'The source runtime-resource contract differs.'}
 foreach($row in $grammars.files){$file=Join-Path $Target ('native/share/'+$row.path);if((Get-Item $file).Length -ne $row.bytes -or (Hash $file) -cne $row.sha256){throw 'An exact runtime grammar differs.'}}
}
function SystemSnapshot{
 $services=@(Get-CimInstance Win32_Service|Sort-Object Name|ForEach-Object {[ordered]@{name=$_.Name;state=$_.State;mode=$_.StartMode;path=$_.PathName;account=$_.StartName}})
 $certs=@(Get-ChildItem Cert:\LocalMachine\Root,Cert:\CurrentUser\Root|ForEach-Object {$_.Thumbprint}|Sort-Object)
 $rules=[ordered]@{}
 foreach($store in @('ActiveStore','PersistentStore')){foreach($command in @('Get-NetFirewallRule','Get-NetFirewallProfile','Get-NetFirewallAddressFilter','Get-NetFirewallPortFilter','Get-NetFirewallApplicationFilter','Get-NetFirewallServiceFilter','Get-NetFirewallInterfaceFilter','Get-NetFirewallInterfaceTypeFilter','Get-NetFirewallSecurityFilter')){
  $rows=@(& $command -PolicyStore $store|Sort-Object InstanceID,Name|ForEach-Object {$values=[ordered]@{};foreach($field in @($_.CimInstanceProperties|Sort-Object Name)){$values[$field.Name]=$field.Value};$values});$rules[$store+'/'+$command]=$rows
 }}
 [ordered]@{services=$services;root_certificates=$certs;firewall=$rules}|ConvertTo-Json -Depth 8 -Compress
}
function RunChild([string]$Exe,[string[]]$Arguments,[string]$Directory,[int]$Seconds,[switch]$MsiDiagnostic){
 if($MsiDiagnostic){$script:msiChildExit=$null;$script:msiFailure=$null;$script:msiObservationRefused=$false}
 $info=[Diagnostics.ProcessStartInfo]::new($Exe);$info.WorkingDirectory=$Directory;$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
 foreach($arg in $Arguments){[void]$info.ArgumentList.Add($arg)}
 $proc=[Diagnostics.Process]::Start($info);$started=$proc.StartTime.ToUniversalTime();$out=[MediaChildDrain]::Pump($proc.StandardOutput);$err=if($MsiDiagnostic){[MediaChildDrain]::Capture($proc.StandardError,8192)}else{[MediaChildDrain]::Pump($proc.StandardError)}
 try{
  $clock=[Diagnostics.Stopwatch]::StartNew()
  while(!$proc.WaitForExit(500)){
   if($clock.Elapsed.TotalSeconds -ge $Seconds){throw 'Owned child deadline exceeded.'}
   if($Exe.EndsWith('OpenWebPbx.Phone.MediaChecks.exe',[StringComparison]::OrdinalIgnoreCase)){ObserveSockets}
  }
  $errorResult=$err.GetAwaiter().GetResult()
  if($MsiDiagnostic){
   $script:msiChildExit=[int]$proc.ExitCode
   if($proc.ExitCode -ne 0){try{if($errorResult.Truncated){throw 'Bounded MSI diagnostic required.'};$script:msiFailure=ReadMsiFailure $errorResult.Text}catch{$script:msiObservationRefused=$true}}
   $errorLength=$errorResult.Characters
  }else{$errorLength=$errorResult}
  if($out.GetAwaiter().GetResult() -gt 8MB -or $errorLength -gt 8MB){throw 'Owned child output exceeds its private bound.'};[int]$proc.ExitCode
 }
 finally{if(!$proc.HasExited){if($proc.StartTime.ToUniversalTime() -ne $started -or $proc.MainModule.FileName -ine $Exe){throw 'Owned child identity differs.'};$proc.Kill($true);if(!$proc.WaitForExit(10000)){throw 'Owned child cleanup failed.'}};$proc.Dispose()}
}
Add-Type -TypeDefinition @'
using System.IO;using System.Text;using System.Threading.Tasks;
public sealed record MediaCapturedError(string Text,long Characters,bool Truncated);
public static class MediaChildDrain {
 public static async Task<long> Pump(StreamReader reader) { var chars=new char[4096];long total=0;int count;while((count=await reader.ReadAsync(chars))!=0)total=checked(total+count);return total;}
 public static async Task<MediaCapturedError> Capture(StreamReader reader,int limit) { var chars=new char[4096];var text=new StringBuilder(limit);long total=0;int count;while((count=await reader.ReadAsync(chars))!=0){total=checked(total+count);var keep=System.Math.Min(count,limit-text.Length);if(keep>0)text.Append(chars,0,keep);}return new(text.ToString(),total,total>limit);}
}
'@
$script:msiChildExit=$null;$script:msiFailure=$null;$script:msiObservationRefused=$false
$script:socketSamples=0;$script:tcpObserved=$false;$script:udpObserved=$false
function ReadOwnedRows([string]$Path,[switch]$AllowIncomplete){
 if((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Owned process journal is linked.'}
 $stream=[IO.File]::Open($Path,'Open','Read','ReadWrite')
 try{if($stream.Length -gt 32768){throw 'Owned process journal exceeds bounds.'};$bytes=[byte[]]::new($stream.Length);$stream.ReadExactly($bytes)}finally{$stream.Dispose()}
 $text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes)
 if($text.Length -and !$text.EndsWith("`n")){if(!$AllowIncomplete){throw 'Owned journal has an incomplete durable row.'};$at=$text.LastIndexOf("`n");$text=if($at -lt 0){''}else{$text.Substring(0,$at+1)}}
 $lines=@($text.Split("`n",[StringSplitOptions]::RemoveEmptyEntries));if($lines.Count -gt 64){throw 'Owned process journal exceeds bounds.'};$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
 foreach($line in $lines){$document=[System.Text.Json.JsonDocument]::Parse($line,[System.Text.Json.JsonDocumentOptions]@{MaxDepth=3});try{JsonShape $document.RootElement}finally{$document.Dispose()};$r=$line|ConvertFrom-Json;ClosedKeys $r @('role','pid','created_utc_ticks','executable_sha256');if($r.role -isnot [string] -or $r.role -cnotin @('peer','engine') -or $r.pid -isnot [long] -or $r.pid -le 0 -or $r.pid -gt [int]::MaxValue -or $r.created_utc_ticks -isnot [long] -or $r.created_utc_ticks -le 0 -or $r.created_utc_ticks -gt [DateTime]::UtcNow.AddSeconds(5).Ticks -or $r.executable_sha256 -isnot [string] -or $r.executable_sha256 -cnotmatch '^[a-f0-9]{64}$' -or !$seen.Add(($r.pid.ToString()+'/'+$r.created_utc_ticks.ToString()))){throw 'Owned process journal differs.'};$r}
}
function ObserveSockets{
 $journal=Join-Path $scope 'owned-processes.jsonl';if(!(Test-Path -LiteralPath $journal)){return}
 $live=[Collections.Generic.List[int]]::new()
 foreach($r in @(ReadOwnedRows $journal -AllowIncomplete)){
  $p=Get-Process -Id $r.pid -ErrorAction SilentlyContinue;if(!$p){continue}
  try{if($p.HasExited){continue};$expected=if($r.role -ceq 'peer'){Join-Path $scope 'app/OpenWebPbx.Phone.MediaChecks.exe'}else{Join-Path $scope 'engine/FreeSwitchConsole.exe'};if($p.StartTime.ToUniversalTime().Ticks -ne $r.created_utc_ticks -or $p.MainModule.FileName -ine $expected){throw 'Refuse a foreign process at a sampled PID.'};$live.Add([int]$r.pid)}finally{$p.Dispose()}
 }
 if($live.Count){
  foreach($row in @(Get-NetTCPConnection -OwningProcess $live.ToArray() -ErrorAction SilentlyContinue)){
   if($row.LocalAddress -notin @('127.0.0.1','::1') -or $row.RemoteAddress -notin @('127.0.0.1','::1','0.0.0.0','::')){throw 'Owned media TCP escaped loopback.'};$script:tcpObserved=$true
  }
  foreach($row in @(Get-NetUDPEndpoint -OwningProcess $live.ToArray() -ErrorAction SilentlyContinue)){if($row.LocalAddress -notin @('127.0.0.1','::1')){throw 'Owned media UDP escaped loopback.'};$script:udpObserved=$true}
 }
 $script:socketSamples++
}
function ClosedKeys($Value,[string[]]$Expected){$actual=@($Value.PSObject.Properties.Name|Sort-Object);if(($actual -join '|') -cne (($Expected|Sort-Object) -join '|')){throw 'Closed media receipt fields differ.'}}
function JsonShape([System.Text.Json.JsonElement]$Element){
 if($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object){$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);foreach($property in $Element.EnumerateObject()){if(!$seen.Add($property.Name)){throw 'Duplicate JSON member refused.'};JsonShape $property.Value}}
 elseif($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array){foreach($entry in $Element.EnumerateArray()){JsonShape $entry}}
 elseif($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Number){[double]$number=0;if(!$Element.TryGetDouble([ref]$number) -or ![double]::IsFinite($number)){throw 'Nonfinite JSON number refused.'}}
}
function ReadMsiFailure([string]$Text){
 if(!$Text -or $Text.Length -gt 8192){throw 'Bounded closed MSI diagnostic required.'}
 $document=[System.Text.Json.JsonDocument]::Parse($Text,[System.Text.Json.JsonDocumentOptions]@{MaxDepth=3});try{JsonShape $document.RootElement}finally{$document.Dispose()};$r=$Text|ConvertFrom-Json
 ClosedKeys $r @('schema','producer','state','operation','substage','exception_type','missing_module','source_basename','source_line')
 if(($r.schema -isnot [long] -and $r.schema -isnot [int]) -or $r.schema -ne 1 -or $r.producer -cne 'extract_media_engine.py' -or $r.state -cne 'failed' -or $r.operation -cne 'read_only_msi_media_extract'){throw 'The MSI diagnostic identity differs.'}
 foreach($name in @('substage','exception_type','missing_module','source_basename')){if($r.$name -isnot [string]){throw 'Typed closed MSI fields required.'}}
 if($r.substage -cnotin @('bootstrap','validate_host','helper_identity','owned_paths','helper_import','helper_extract','msi_tables','select_media_modules','extract_cabinet','copy_core_files','write_manifest') -or $r.exception_type -cnotin @('ValueError','MediaModuleSelectionError','FileNotFoundError','PermissionError','OSError','CalledProcessError','TimeoutExpired','ImportError','ModuleNotFoundError','KeyError','TypeError','AttributeError','RuntimeError','other') -or $r.missing_module -cnotin @('unknown','mod_dptools.dll','mod_dialplan_xml.dll','mod_sndfile.dll','mod_tone_stream.dll','mod_conference.dll','mod_vpx.dll') -or $r.source_basename -cnotin @('external_component','extract_media_engine.py','extract-windows-core.py') -or ($r.source_line -isnot [long] -and $r.source_line -isnot [int]) -or $r.source_line -lt 0 -or $r.source_line -gt 100000){throw 'The MSI diagnostic value differs.'}
 if(($r.missing_module -cne 'unknown' -and ($r.substage -cne 'select_media_modules' -or $r.exception_type -cne 'MediaModuleSelectionError')) -or ($r.source_basename -ceq 'external_component' -and $r.source_line -ne 0) -or ($r.source_basename -cne 'external_component' -and $r.source_line -eq 0)){throw 'The MSI diagnostic scope differs.'}
 [ordered]@{schema=1;producer='extract_media_engine.py';state='failed';operation='read_only_msi_media_extract';substage=$r.substage;exception_type=$r.exception_type;missing_module=$r.missing_module;source_basename=$r.source_basename;source_line=[int]$r.source_line}
}
function MediaSnapshotRowCounts([object[]]$Before,[object[]]$After){
 if($Before.Count -gt 100000 -or $After.Count -gt 100000){throw 'Snapshot row count exceeds bounds.'}
 $maps=@();foreach($rows in @(@{rows=$Before},@{rows=$After})){
  $map=[Collections.Generic.Dictionary[string,long]]::new([StringComparer]::Ordinal)
  foreach($row in $rows.rows){$text=$row|ConvertTo-Json -Depth 16 -Compress -WarningAction Stop;$key=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text)));if(!$map.ContainsKey($key)){$map[$key]=0};$map[$key]++};$maps+=,$map
 }
 $added=0L;$removed=0L;foreach($key in $maps[0].Keys){$right=if($maps[1].ContainsKey($key)){$maps[1][$key]}else{0};if($maps[0][$key] -gt $right){$removed+=$maps[0][$key]-$right}}
 foreach($key in $maps[1].Keys){$left=if($maps[0].ContainsKey($key)){$maps[0][$key]}else{0};if($maps[1][$key] -gt $left){$added+=$maps[1][$key]-$left}}
 [ordered]@{before_rows=$Before.Count;after_rows=$After.Count;removed_row_values=$removed;added_row_values=$added}
}
function MediaSnapshotDiffCounts([string]$Before,[string]$After){
 if(!$Before -or !$After -or $Before.Length -gt 16MB -or $After.Length -gt 16MB){throw 'Bounded complete snapshots required.'}
 $objects=@();foreach($text in @($Before,$After)){$document=[System.Text.Json.JsonDocument]::Parse($text,[System.Text.Json.JsonDocumentOptions]@{MaxDepth=16});try{JsonShape $document.RootElement}finally{$document.Dispose()};$value=$text|ConvertFrom-Json;ClosedKeys $value @('services','root_certificates','firewall');if($value.services -isnot [array] -or $value.root_certificates -isnot [array]){throw 'Complete snapshot arrays required.'};$objects+=,$value}
 $categories=[ordered]@{rules='Get-NetFirewallRule';profiles='Get-NetFirewallProfile';addresses='Get-NetFirewallAddressFilter';ports='Get-NetFirewallPortFilter';applications='Get-NetFirewallApplicationFilter';services='Get-NetFirewallServiceFilter';interfaces='Get-NetFirewallInterfaceFilter';interface_types='Get-NetFirewallInterfaceTypeFilter';security='Get-NetFirewallSecurityFilter'}
 $keys=@(foreach($store in @('ActiveStore','PersistentStore')){foreach($command in $categories.Values){$store+'/'+$command}})
 foreach($value in $objects){ClosedKeys $value.firewall $keys}
 $firewall=[ordered]@{}
 foreach($category in $categories.Keys){$sets=@();foreach($value in $objects){$rows=@(foreach($store in @('ActiveStore','PersistentStore')){$field=$store+'/'+$categories[$category];if($value.firewall.$field -isnot [array]){throw 'Complete firewall collection arrays required.'};foreach($row in $value.firewall.$field){[ordered]@{store=$store;value=$row}}});$sets+=,@{rows=$rows}};$firewall[$category]=MediaSnapshotRowCounts $sets[0].rows $sets[1].rows}
 $proof=[ordered]@{schema=1;producer='Test-ClientMedia.ps1';state='observed_snapshot_counts';exact_snapshot_changed=($Before -cne $After);before_stage='before_sdk_extract';after_stage='after_owned_process_cleanup';services=(MediaSnapshotRowCounts $objects[0].services $objects[1].services);service_changes=(MediaServiceChanges $objects[0].services $objects[1].services);root_certificates=(MediaSnapshotRowCounts $objects[0].root_certificates $objects[1].root_certificates);firewall=$firewall}
 foreach($row in @($proof.services,$proof.root_certificates)+@($firewall.Values)){foreach($name in @('before_rows','after_rows','removed_row_values','added_row_values')){if(($row[$name] -isnot [int] -and $row[$name] -isnot [long]) -or $row[$name] -lt 0 -or $row[$name] -gt 100000){throw 'Typed bounded snapshot counts required.'}}}
 return $proof
}
function MediaServiceChanges([object[]]$Before,[object[]]$After){
 if($Before.Count -gt 4096 -or $After.Count -gt 4096){throw 'Bounded service inventory required.'}
 $maps=@();foreach($rows in @(@{rows=$Before},@{rows=$After})){
  $map=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
  foreach($row in $rows.rows){ClosedKeys $row @('name','state','mode','path','account');foreach($field in @('name','state','mode')){if($row.$field -isnot [string]){throw 'Typed service fields required.'}};foreach($field in @('path','account')){if($null -ne $row.$field -and $row.$field -isnot [string]){throw 'Typed private service fields required.'}}
   if($row.name -cnotmatch '^[A-Za-z0-9_.-]{1,128}$' -or $row.state -cnotin @('Stopped','Start Pending','Stop Pending','Running','Continue Pending','Pause Pending','Paused','Unknown') -or $row.mode -cnotin @('Auto','Manual','Disabled','Boot','System','Unknown') -or !$map.TryAdd($row.name,$row)){throw 'Unique stock service names and typed states required.'}
  };$maps+=,$map
 }
 $names=@(@($maps[0].Keys)+@($maps[1].Keys)|Sort-Object -Unique);$changes=[Collections.Generic.List[object]]::new();$total=0
 foreach($name in $names){$left=$maps[0].ContainsKey($name);$right=$maps[1].ContainsKey($name);$changed=@(foreach($field in @('state','mode','path','account')){if(!$left -or !$right -or $maps[0][$name].$field -cne $maps[1][$name].$field){$field}})
  if(!$changed.Count){continue};$total++;if($changes.Count -ge 16){continue}
  $changes.Add([ordered]@{name=$name;changed_properties=$changed;before_present=$left;after_present=$right;before_state=$(if($left){$maps[0][$name].state}else{$null});after_state=$(if($right){$maps[1][$name].state}else{$null});before_mode=$(if($left){$maps[0][$name].mode}else{$null});after_mode=$(if($right){$maps[1][$name].mode}else{$null})})
 }
 [ordered]@{changed_services=$total;truncated=($total -gt 16);rows=$changes.ToArray()}
}
function ReadServiceBoundary($Value){
 $stages=@('after_sdk_extract','after_msi_extract','after_managed_build','immediately_before_native_media','after_native_media')
 if($Value.stage -isnot [string] -or $Value.stage -cnotin $stages -or $Value.observed -isnot [bool]){throw 'A fixed service boundary is required.'}
 if(!$Value.observed){ClosedKeys $Value @('stage','observed');return $Value}
 ClosedKeys $Value @('stage','observed','elapsed_ms','changes')
 if(($Value.elapsed_ms -isnot [long] -and $Value.elapsed_ms -isnot [int]) -or $Value.elapsed_ms -lt 0 -or $Value.elapsed_ms -gt 3600000){throw 'A bounded observation time is required.'}
 $changes=$Value.changes;ClosedKeys $changes @('changed_services','truncated','rows')
 if(($changes.changed_services -isnot [long] -and $changes.changed_services -isnot [int]) -or $changes.changed_services -lt 0 -or $changes.changed_services -gt 4096 -or $changes.truncated -isnot [bool] -or $changes.truncated -ne ($changes.changed_services -gt 16) -or $changes.rows -isnot [array] -or $changes.rows.Count -ne [Math]::Min(16,$changes.changed_services)){throw 'Bounded service changes are required.'}
 $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
 foreach($row in $changes.rows){ClosedKeys $row @('name','changed_properties','before_present','after_present','before_state','after_state','before_mode','after_mode')
  if($row.name -isnot [string] -or $row.name -cnotmatch '^[A-Za-z0-9_.-]{1,128}$' -or !$seen.Add($row.name) -or $row.changed_properties -isnot [array] -or $row.changed_properties.Count -lt 1 -or $row.changed_properties.Count -gt 4 -or @($row.changed_properties|Select-Object -Unique).Count -ne $row.changed_properties.Count){throw 'Unique closed service names/properties required.'}
  foreach($property in $row.changed_properties){if($property -isnot [string] -or $property -cnotin @('state','mode','path','account')){throw 'Only property names may be exported.'}}
  foreach($side in @('before','after')){$present=$side+'_present';$state=$side+'_state';$mode=$side+'_mode';if($row.$present -isnot [bool]){throw 'Typed service presence required.'};if($row.$present){if($row.$state -isnot [string] -or $row.$state -cnotin @('Stopped','Start Pending','Stop Pending','Running','Continue Pending','Pause Pending','Paused','Unknown') -or $row.$mode -isnot [string] -or $row.$mode -cnotin @('Auto','Manual','Disabled','Boot','System','Unknown')){throw 'Only typed service status and start modes may be exported.'}}elseif($null -ne $row.$state -or $null -ne $row.$mode){throw 'No state may be inferred for an absent service.'}}
  if(!$row.before_present -and !$row.after_present){throw 'A changed service must have been observed.'}
 }
 $Value
}
function ObserveServiceBoundary([string]$Stage){
 # Observation failure never replaces a product/test failure. Raw private service
 # command paths/accounts stay in memory and never enter the closed projection.
 try{
  $order=@('after_sdk_extract','after_msi_extract','after_managed_build','immediately_before_native_media','after_native_media')
  if($Stage -cnotin $order){return}
  if($script:serviceBoundaries.Count -ge 5 -or $Stage -cne $order[$script:serviceBoundaries.Count] -or $null -eq $script:serviceBoundaryBefore){throw 'Service observation order or baseline unavailable.'}
  $after=@(Get-CimInstance Win32_Service|Sort-Object Name|ForEach-Object {[ordered]@{name=$_.Name;state=$_.State;mode=$_.StartMode;path=$_.PathName;account=$_.StartName}})
  # Reuse the actual snapshot's serialized row type before the strict projection.
  $after=ConvertTo-Json -InputObject $after -Depth 4 -Compress|ConvertFrom-Json -NoEnumerate
  $row=[ordered]@{stage=$Stage;observed=$true;elapsed_ms=$script:serviceBoundaryClock.ElapsedMilliseconds;changes=(MediaServiceChanges $script:serviceBoundaryBefore $after)}
  $safe=ReadServiceBoundary ($row|ConvertTo-Json -Depth 8 -Compress|ConvertFrom-Json)
 }catch{$safe=[pscustomobject]@{stage=$Stage;observed=$false}}
 if($script:serviceBoundaries.Count -lt 5){$script:serviceBoundaries.Add($safe)}
}
function ReadNativeWaitObservation($Value){
 ClosedKeys $Value @('name','deadline_seconds','peers')
 $names=@('wrong_ca_refused','wrong_name_refused','registrations_ready','incoming_initial','streams_initial','incoming_voicemail','streams_voicemail','incoming_blind','streams_blind','incoming_consultation','streams_consultation','incoming_waiting','streams_waiting','voicemail_playing','voicemail_incoming','voicemail_removed','update_idle','held','resumed','dtmf_received','blind_original_ended','consult_completed','consult_cancelled','waiting_original_resumed','conference_merged')
 $states=@('Idle','IncomingReceived','PushIncomingReceived','OutgoingInit','OutgoingProgress','OutgoingRinging','OutgoingEarlyMedia','Connected','StreamsRunning','Pausing','Paused','Resuming','Referred','Error','End','PausedByRemote','UpdatedByRemote','IncomingEarlyMedia','Updating','Released','EarlyUpdatedByRemote','EarlyUpdating')
 if($Value.name -isnot [string] -or $Value.name -cnotin $names -or $Value.deadline_seconds -isnot [long] -or $Value.deadline_seconds -notin @(8,20) -or $Value.peers -isnot [array] -or $Value.peers.Count -lt 1 -or $Value.peers.Count -gt 3){throw 'Exact bounded native wait required.'}
 for($index=0;$index -lt $Value.peers.Count;$index++){$peer=$Value.peers[$index];ClosedKeys $peer @('position','observed','state')
  if($peer.position -isnot [long] -or $peer.position -ne $index -or $peer.observed -isnot [bool] -or $peer.observed -ne ($null -ne $peer.state)){throw 'Exact observed peer scope required.'}
  if(!$peer.observed){continue};$state=$peer.state;ClosedKeys $state @('ready','registration_failed','busy','call_count','states','signals')
  foreach($flag in @('ready','registration_failed','busy')){if($state.$flag -isnot [bool]){throw 'Typed peer status required.'}}
  if($state.call_count -isnot [long] -or $state.call_count -lt 0 -or $state.call_count -gt 2 -or $state.states -isnot [array] -or $state.states.Count -ne $state.call_count -or $state.signals -isnot [array] -or $state.signals.Count -gt 32){throw 'Bounded peer call counts required.'}
  foreach($name in $state.states){if($name -isnot [string] -or $name -cnotin $states){throw 'Closed native call state required.'}}
  foreach($signal in $state.signals){ClosedKeys $signal @('state','reason','protocol_code','observed');if($signal.observed -isnot [bool]){throw 'Typed native observation required.'};foreach($number in @('state','reason','protocol_code')){if($signal.$number -isnot [long]){throw 'Typed native signal required.'}}
   if($signal.observed){if($signal.state -lt 0 -or $signal.state -gt 21 -or $signal.reason -lt 0 -or $signal.reason -gt 25 -or $signal.protocol_code -lt -1 -or $signal.protocol_code -gt 699){throw 'Closed native signal bounds differ.'}}elseif($signal.state -ne -1 -or $signal.reason -ne -1 -or $signal.protocol_code -ne -1){throw 'Unobserved native values cannot be inferred.'}
  }
 }
 $Value
}
function ReadNativeWaveObservation($Value){
 ClosedKeys $Value @('reason','source','growing','snapshot_atomic','length_check_bytes','buffer_bytes','riff','wave','riff_declared_bytes','chunk','chunk_offset','chunk_declared_bytes','chunk_effective_bytes','format_tag','channels','sample_rate','sample_bits','alignment','byte_rate','format_seen','data_seen','data_bytes')
 if($Value.reason -isnot [string] -or $Value.reason -cnotin @('file_length','riff_wave_shape','chunk_header','terminal_data_shape','chunk_length','pcm_format','pcm_layout','duplicate_data','chunk_padding','decoded_samples') -or $Value.source -isnot [string] -or $Value.source -cnotin @('file_length_check','failed_read_buffer') -or $Value.chunk -isnot [string] -or $Value.chunk -cnotin @('none','fmt','data','other')){throw 'Closed failed-WAV reason/source/chunk required.'}
 foreach($field in @('growing','snapshot_atomic','format_seen','data_seen')){if($Value.$field -isnot [bool]){throw 'Typed failed-WAV scope required.'}}
 if($Value.snapshot_atomic){throw 'Concurrent file reads are not atomic snapshots.'}
 foreach($field in @('riff','wave')){if($null -ne $Value.$field -and $Value.$field -isnot [bool]){throw 'Typed observed WAV marker required.'}}
 foreach($field in @('length_check_bytes','buffer_bytes','chunk_offset','data_bytes')){if($Value.$field -isnot [long] -or $Value.$field -lt $(if($field -ceq 'chunk_offset'){-1}else{0}) -or ($field -cne 'length_check_bytes' -and $Value.$field -gt 134217728)){throw 'Bounded failed-WAV counts required.'}}
 foreach($field in @('riff_declared_bytes','chunk_declared_bytes','chunk_effective_bytes','format_tag','channels','sample_rate','sample_bits','alignment','byte_rate')){
  if($null -ne $Value.$field -and ($Value.$field -isnot [long] -or $Value.$field -lt 0 -or $Value.$field -gt $(if($field -in @('format_tag','channels','sample_bits','alignment')){65535}else{4294967295}))){throw 'Typed bounded WAV field required.'}
 }
 if($Value.source -ceq 'file_length_check' -and ($Value.buffer_bytes -ne 0 -or $Value.reason -cne 'file_length' -or $null -ne $Value.riff -or $null -ne $Value.wave -or $Value.format_seen -or $Value.data_seen)){throw 'Length-only failure cannot infer buffer contents.'}
 $Value
}
function ReadNativeSecurityObservation($Value){
 ClosedKeys $Value @('source','tls_ca_and_hostname','mandatory_srtp','call_count','calls')
 if($Value.source -isnot [string] -or $Value.source -cne 'already_sampled_secure_argument' -or $Value.tls_ca_and_hostname -isnot [bool] -or $Value.mandatory_srtp -isnot [bool] -or $Value.call_count -isnot [long] -or $Value.call_count -lt 0 -or $Value.call_count -gt 2 -or $Value.calls -isnot [array] -or $Value.calls.Count -ne $Value.call_count){throw 'Exact already-sampled native security scope required.'}
 foreach($call in $Value.calls){ClosedKeys $call @('state','encryption','srtp_suite')
  if($call.state -isnot [string] -or $call.state -cnotin @('Idle','IncomingReceived','PushIncomingReceived','OutgoingInit','OutgoingProgress','OutgoingRinging','OutgoingEarlyMedia','Connected','StreamsRunning','Pausing','Paused','Resuming','Referred','Error','End','PausedByRemote','UpdatedByRemote','IncomingEarlyMedia','Updating','Released','EarlyUpdatedByRemote','EarlyUpdating','unrecognised') -or $call.encryption -isnot [string] -or $call.encryption -cnotin @('None','SRTP','ZRTP','DTLS','unrecognised') -or $call.srtp_suite -isnot [string] -or $call.srtp_suite -cnotin @('AESCM128HMACSHA180','AESCM128HMACSHA132','AES192CMHMACSHA180','AES192CMHMACSHA132','AES256CMHMACSHA180','AES256CMHMACSHA132','AEADAES128GCM','AEADAES256GCM','Invalid','unrecognised')){throw 'Only closed pinned native security enums may leave the fixture.'}
 }
 $Value
}
function ReadNativeRecorderInterval($Value){
 ClosedKeys $Value @('phase','snapshot_atomic','state','failure_capture_ms','start_capture_ms','end_capture_ms','elapsed_ms','requested_ms','wait_completed','prefix')
 if($Value.phase -isnot [string] -or $Value.phase -cne 'before_owned_peer_shutdown' -or $Value.snapshot_atomic -isnot [bool] -or $Value.snapshot_atomic -or $Value.state -isnot [string] -or $Value.state -cnotin @('observed','observation_refused','call_not_confirmed','no_remaining_budget','capture_budget_expired') -or $Value.wait_completed -isnot [bool]){throw 'Closed diagnostic interval scope required.'}
 foreach($name in @('failure_capture_ms','start_capture_ms','end_capture_ms','elapsed_ms')){if($null -ne $Value.$name -and ($Value.$name -isnot [long] -or $Value.$name -lt 0 -or $Value.$name -gt 300000)){throw 'Bounded capture-relative milliseconds required.'}}
 if($null -eq $Value.failure_capture_ms -or $Value.requested_ms -isnot [long] -or $Value.requested_ms -lt 0 -or $Value.requested_ms -gt 5000){throw 'Original failure time and bounded requested wait required.'}
 if(($null -eq $Value.start_capture_ms) -ne ($null -eq $Value.end_capture_ms) -or ($null -eq $Value.start_capture_ms) -ne ($null -eq $Value.elapsed_ms)){throw 'Partial interval timing is inconsistent.'}
 if($null -ne $Value.start_capture_ms -and ($Value.start_capture_ms -lt $Value.failure_capture_ms -or $Value.end_capture_ms -lt $Value.start_capture_ms -or $Value.elapsed_ms -ne $Value.end_capture_ms-$Value.start_capture_ms)){throw 'Monotonic actual interval required.'}
 if($Value.requested_ms -gt 0 -and ($null -eq $Value.start_capture_ms -or $Value.start_capture_ms -ge 12000 -or $Value.requested_ms -ne [Math]::Min(5000,12000-$Value.start_capture_ms))){throw 'Diagnostic wait exceeds original capture budget.'}
 if($Value.state -ceq 'observed' -and (!$Value.wait_completed -or $Value.requested_ms -eq 0 -or $Value.elapsed_ms -lt $Value.requested_ms -or $null -eq $Value.prefix)){throw 'Observed prefix requires completed diagnostic interval.'}
 if($Value.state -cne 'observed' -and $null -ne $Value.prefix){throw 'Unavailable interval cannot publish prefix.'}
 if($Value.state -ceq 'capture_budget_expired' -and (!$Value.wait_completed -or $Value.requested_ms -eq 0 -or $Value.end_capture_ms -le 12000)){throw 'Overshoot observation differs.'}
 if($Value.state -in @('call_not_confirmed','no_remaining_budget') -and ($Value.requested_ms -ne 0 -or $Value.wait_completed -or $null -eq $Value.start_capture_ms -or $Value.elapsed_ms -ne 0)){throw 'Skipped observation cannot imply a wait.'}
 if($Value.state -ceq 'no_remaining_budget' -and $Value.start_capture_ms -lt 12000){throw 'Remaining original budget was not exhausted.'}
 if($null -ne $Value.prefix){
  $f=$Value.prefix;ClosedKeys $f @('length_before_bytes','length_after_bytes','header_bytes','riff','wave','format','data','riff_declared_bytes','format_declared_bytes','format_tag','channels','sample_rate','byte_rate','alignment','sample_bits','data_declared_bytes')
  foreach($name in @('length_before_bytes','length_after_bytes')){if($f.$name -isnot [long] -or $f.$name -lt 0 -or $f.$name -gt 134217728){throw 'Bounded live file lengths required.'}}
  if($f.header_bytes -isnot [long] -or $f.header_bytes -ne [Math]::Min(44,$f.length_before_bytes)){throw 'Only the bounded actually read prefix is retained.'}
  $offsets=@{riff=0;wave=8;format=12;data=36};foreach($name in $offsets.Keys){if($null -ne $f.$name -and $f.$name -isnot [bool]){throw 'Typed live-header marker required.'};if(($null -ne $f.$name) -ne ($f.header_bytes -ge $offsets[$name]+4)){throw 'Marker cannot precede live prefix bytes.'}}
  foreach($name in @('riff_declared_bytes','format_declared_bytes','sample_rate','byte_rate','data_declared_bytes')){if($null -ne $f.$name -and ($f.$name -isnot [long] -or $f.$name -lt 0 -or $f.$name -gt 4294967295)){throw 'Bounded live header uint32 required.'}}
  foreach($name in @('format_tag','channels','alignment','sample_bits')){if($null -ne $f.$name -and ($f.$name -isnot [long] -or $f.$name -lt 0 -or $f.$name -gt 65535)){throw 'Bounded live header uint16 required.'}}
  if(($null -ne $f.riff_declared_bytes) -ne ($f.riff -eq $true -and $f.header_bytes -ge 8)){throw 'Live RIFF length cannot precede marker.'}
  $hasFormat=$f.riff -eq $true -and $f.wave -eq $true -and $f.format -eq $true -and $f.header_bytes -ge 36
  foreach($name in @('format_declared_bytes','format_tag','channels','sample_rate','byte_rate','alignment','sample_bits')){if(($null -ne $f.$name) -ne $hasFormat){throw 'Live format values require complete fixed prefix.'}}
  if(($null -ne $f.data_declared_bytes) -ne ($f.riff -eq $true -and $f.wave -eq $true -and $f.data -eq $true -and $f.header_bytes -eq 44)){throw 'Live data length requires fixed prefix.'}
 }
 $Value
}
function ReadNativeRecorderObservation($Value){
 ClosedKeys $Value @('scope','recording','payload_phase','payload_observed','same_call_identity','call_count','calls','owned_peers_closed','file_observation','closed_file','initialization_interval')
 if($Value.scope -isnot [string] -or $Value.scope -cne 'failed_capture_same_owned_recorder' -or $Value.recording -isnot [string] -or $Value.recording -cnotin @('receive_output','conference_mix') -or $Value.payload_phase -isnot [string] -or $Value.payload_phase -cne 'after_failed_read_before_cleanup'){throw 'Closed recorder observation scope required.'}
 foreach($flag in @('payload_observed','same_call_identity','owned_peers_closed')){if($Value.$flag -isnot [bool]){throw 'Typed recorder lifecycle required.'}}
 if($Value.call_count -isnot [long] -or $Value.call_count -lt 0 -or $Value.call_count -gt 2 -or $Value.calls -isnot [array] -or $Value.calls.Count -ne $Value.call_count -or (!$Value.payload_observed -and ($Value.same_call_identity -or $Value.call_count -ne 0)) -or ($Value.same_call_identity -and $Value.call_count -eq 0)){throw 'Recorder native snapshot scope differs.'}
 foreach($call in $Value.calls){
  ClosedKeys $call @('state','codec','clock_rate','channels')
  if($call.state -isnot [string] -or $call.state -cnotin @('Idle','IncomingReceived','PushIncomingReceived','OutgoingInit','OutgoingProgress','OutgoingRinging','OutgoingEarlyMedia','Connected','StreamsRunning','Pausing','Paused','Resuming','Referred','Error','End','PausedByRemote','UpdatedByRemote','IncomingEarlyMedia','Updating','Released','EarlyUpdatedByRemote','EarlyUpdating','unrecognised') -or $call.codec -isnot [string] -or $call.codec -cnotin @('PCMU','PCMA','opus','G722','G729','speex','L16','none','unrecognised') -or $call.clock_rate -isnot [long] -or $call.clock_rate -lt 0 -or $call.clock_rate -gt 192000 -or $call.channels -isnot [long] -or $call.channels -lt 0 -or $call.channels -gt 8){throw 'Bounded closed native audio payload required.'}
 }
 if($null -ne $Value.initialization_interval){$null=ReadNativeRecorderInterval $Value.initialization_interval;if($Value.initialization_interval.state -ceq 'call_not_confirmed' -and $Value.payload_observed -and $Value.same_call_identity){throw 'Call identity skip differs.'};if($Value.initialization_interval.requested_ms -gt 0 -and (!$Value.payload_observed -or !$Value.same_call_identity)){throw 'Diagnostic waiting requires this same call.'}}
 if($Value.file_observation -isnot [string] -or $Value.file_observation -cnotin @('observed','read_refused','peers_not_closed') -or (($Value.file_observation -ceq 'peers_not_closed') -ne (!$Value.owned_peers_closed)) -or (($Value.file_observation -ceq 'observed') -ne ($null -ne $Value.closed_file))){throw 'Recorder after-close boundary differs.'}
 if($null -ne $Value.closed_file){
  $f=$Value.closed_file;ClosedKeys $f @('phase','length_bytes','sha256','header_bytes','riff','wave','format','data','riff_declared_bytes','format_declared_bytes','format_tag','channels','sample_rate','byte_rate','alignment','sample_bits','data_declared_bytes','bytes_after_fixed_header')
  if($f.phase -isnot [string] -or $f.phase -cne 'after_owned_peer_shutdown' -or $f.length_bytes -isnot [long] -or $f.length_bytes -lt 0 -or $f.length_bytes -gt 134217728 -or $f.sha256 -isnot [string] -or $f.sha256 -cnotmatch '^[a-f0-9]{64}$' -or $f.header_bytes -isnot [long] -or $f.header_bytes -ne [Math]::Min(44,$f.length_bytes)){throw 'Bounded hashed after-close file required.'}
  $offsets=@{riff=0;wave=8;format=12;data=36};foreach($name in $offsets.Keys){if($null -ne $f.$name -and $f.$name -isnot [bool]){throw 'Typed closed-header marker required.'};if(($null -ne $f.$name) -ne ($f.header_bytes -ge $offsets[$name]+4)){throw 'Marker cannot precede observed header bytes.'}}
  foreach($name in @('riff_declared_bytes','format_declared_bytes','sample_rate','byte_rate','data_declared_bytes')){if($null -ne $f.$name -and ($f.$name -isnot [long] -or $f.$name -lt 0 -or $f.$name -gt 4294967295)){throw 'Bounded header uint32 required.'}}
  foreach($name in @('format_tag','channels','alignment','sample_bits')){if($null -ne $f.$name -and ($f.$name -isnot [long] -or $f.$name -lt 0 -or $f.$name -gt 65535)){throw 'Bounded header uint16 required.'}}
  if(($null -ne $f.riff_declared_bytes) -ne ($f.riff -eq $true -and $f.header_bytes -ge 8)){throw 'RIFF length cannot precede its marker.'}
  $hasFormat=$f.riff -eq $true -and $f.wave -eq $true -and $f.format -eq $true -and $f.header_bytes -ge 36
  foreach($name in @('format_declared_bytes','format_tag','channels','sample_rate','byte_rate','alignment','sample_bits')){if(($null -ne $f.$name) -ne $hasFormat){throw 'Format values require the complete fixed header.'}}
  $hasData=$f.riff -eq $true -and $f.wave -eq $true -and $f.data -eq $true -and $f.header_bytes -eq 44
  if(($null -ne $f.data_declared_bytes) -ne $hasData -or ($null -ne $f.bytes_after_fixed_header) -ne $hasData){throw 'Data values require the fixed header.'}
  if($hasData -and ($f.bytes_after_fixed_header -isnot [long] -or $f.bytes_after_fixed_header -ne $f.length_bytes-44)){throw 'Actual bytes after fixed header differ.'}
 }
 $Value
}
function ReadNativeFailureObservation($Value){
 ClosedKeys $Value @('operation','source_basename','source_line','peer','wait','wave','security','recorder')
 if($Value.operation -isnot [string] -or $Value.operation -cnotin @('engine_construct','engine_start','case_prepare','wrong_ca_create','wrong_ca_wait','wrong_ca_assert','wrong_ca_dispose','wrong_name_create','wrong_name_wait','wrong_name_assert','wrong_name_dispose','peer_0_create','peer_1_create','peer_2_create','registration_wait','security_assert','case_execute','peers_cleanup','engine_idle','engine_shutdown') -or $Value.source_basename -isnot [string] -or $Value.source_basename -cnotin @('LabCoordinator.cs','LabServer.cs','PeerRunner.cs','PeerProtocol.cs','CoreCodecInventory.cs','ProcessImage.cs','WaitObservation.cs','AudioProof.cs','NativePhone.cs','NativeMediaFixture.cs','external_component') -or $Value.source_line -isnot [long] -or $Value.source_line -lt 0 -or $Value.source_line -gt 100000 -or (($Value.source_basename -ceq 'external_component') -ne ($Value.source_line -eq 0))){throw 'Closed actual failure source differs.'}
 if($null -ne $Value.peer){$peer=$Value.peer;ClosedKeys $peer @('progress','exited_before_cleanup','exit_code_before_cleanup','error_type','stderr_observed')
  if($peer.progress -isnot [string] -or $peer.progress -cnotin @('none','native_runtime_resources','native_logging','native_factory','native_configuration','native_create_core','native_database','native_encryption','native_trusted_roots','native_devices','native_listeners','native_start','native_verify_policy','ready','unrecognised') -or $peer.exited_before_cleanup -isnot [bool] -or $peer.stderr_observed -isnot [bool] -or $peer.error_type -isnot [string] -or $peer.error_type -cnotin @('none','InvalidDataException','InvalidOperationException','JsonException','IOException','FileNotFoundException','DirectoryNotFoundException','UnauthorizedAccessException','TimeoutException','DllNotFoundException','EntryPointNotFoundException','BadImageFormatException','TypeInitializationException','ArgumentException','ArgumentNullException','NullReferenceException','NotSupportedException','AccessViolationException','other','unobserved')){throw 'Closed native peer observation differs.'}
  if($peer.exited_before_cleanup){if($peer.exit_code_before_cleanup -isnot [long] -or $peer.exit_code_before_cleanup -lt [int]::MinValue -or $peer.exit_code_before_cleanup -gt [int]::MaxValue){throw 'Observed native peer exit differs.'}}elseif($null -ne $peer.exit_code_before_cleanup){throw 'No exit may be inferred for a live peer.'}
  if($peer.stderr_observed -eq ($peer.error_type -ceq 'unobserved')){throw 'Native peer stderr scope differs.'}
 }
 if($null -ne $Value.wait){$null=ReadNativeWaitObservation $Value.wait}
 if($null -ne $Value.wave){$null=ReadNativeWaveObservation $Value.wave}
 if($null -ne $Value.security){$null=ReadNativeSecurityObservation $Value.security}
 if($null -ne $Value.recorder){$null=ReadNativeRecorderObservation $Value.recorder
  if($null -ne $Value.recorder.initialization_interval){
   $w=$Value.wave;if($null -eq $w -or $w.reason -cne 'file_length' -or $w.source -cne 'file_length_check' -or !$w.growing -or $w.snapshot_atomic -or $w.length_check_bytes -ne 0 -or $w.buffer_bytes -ne 0 -or $w.chunk -cne 'none' -or $w.chunk_offset -ne -1 -or $w.format_seen -or $w.data_seen -or $w.data_bytes -ne 0){throw 'Only the exact original zero-byte refusal permits a diagnostic interval.'}
   foreach($field in @('riff','wave','riff_declared_bytes','chunk_declared_bytes','chunk_effective_bytes','format_tag','channels','sample_rate','sample_bits','alignment','byte_rate')){if($null -ne $w.$field){throw 'Zero-byte refusal cannot have inferred header data.'}}
  }
 }
 $Value
}
function ReadEngineObservation($Value){
 ClosedKeys $Value @('observed','log_bytes','rejection_signals','sdp','sealed_original')
 if($Value.observed -isnot [bool] -or $Value.sealed_original -isnot [bool] -or $Value.log_bytes -isnot [long] -or $Value.log_bytes -lt 0 -or $Value.log_bytes -gt 2097152 -or $Value.rejection_signals -isnot [array] -or $Value.sdp -isnot [array]){throw 'Typed bounded engine observations required.'}
 if(!$Value.observed -and ($Value.rejection_signals.Count -or $Value.sdp.Count)){throw 'Unobserved trace cannot contain inferred signals.'}
 if(($Value.observed -or $Value.sealed_original) -and $Value.log_bytes -eq 0){throw 'Observed trace bytes required.'}
 $signals=@('crypto_in_avp_refused','srtp_administratively_disabled','required_crypto_missing','connection_line_missing','invalid_crypto_suite','codec_error','early_codec_error','reinvite_codec_error','reinvite_negotiation_failed')
 if($Value.rejection_signals.Count -gt $signals.Count -or @($Value.rejection_signals|Select-Object -Unique).Count -ne $Value.rejection_signals.Count -or $Value.sdp.Count -gt 16){throw 'Bounded unique engine observations required.'}
 foreach($signal in $Value.rejection_signals){if($signal -isnot [string] -or $signal -cnotin $signals){throw 'Closed primary engine signals required.'}}
 foreach($sdp in $Value.sdp){
  ClosedKeys $sdp @('direction','kind','protocol','codecs','crypto_suites')
  if($sdp.direction -isnot [string] -or $sdp.direction -cnotin @('remote','local') -or $sdp.kind -isnot [string] -or $sdp.kind -cnotin @('audio','video') -or $sdp.protocol -isnot [string] -or $sdp.protocol -cnotin @('RTP/AVP','RTP/AVPF','RTP/SAVP','RTP/SAVPF','UDP/TLS/RTP/SAVP','UDP/TLS/RTP/SAVPF','other')){throw 'Closed actual SDP media types required.'}
  foreach($field in @('codecs','crypto_suites')){
   $allowed=if($field -ceq 'codecs'){@('PCMU','PCMA','OPUS','G722','G729','VP8','VP9','H264','TELEPHONE-EVENT','CN','other')}else{@('AES_CM_128_HMAC_SHA1_80','AES_CM_128_HMAC_SHA1_32','AEAD_AES_128_GCM','AEAD_AES_256_GCM','other')}
   if($sdp.$field -isnot [array] -or $sdp.$field.Count -gt $allowed.Count -or @($sdp.$field|Select-Object -Unique).Count -ne $sdp.$field.Count){throw 'Bounded unique SDP names required.'}
   foreach($value in $sdp.$field){if($value -isnot [string] -or $value -cnotin $allowed){throw 'Only closed codec and suite names may leave the lab.'}}
  }
 }
 $Value
}
function ReadSealedEngineDiagnostic([byte[]]$Bytes,[string]$Stage){
 if($Bytes.Length -lt 1 -or $Bytes.Length -gt 2810000){throw 'Bounded encrypted diagnostic required.'}
 $raw=[Text.UTF8Encoding]::new($false,$true).GetString($Bytes);$document=[Text.Json.JsonDocument]::Parse($raw,[Text.Json.JsonDocumentOptions]@{MaxDepth=3});try{JsonShape $document.RootElement}finally{$document.Dispose()};$value=$raw|ConvertFrom-Json
 ClosedKeys $value @('schema','algorithm','public_key_sha256','aad','wrapped_key','nonce','tag','ciphertext')
 if($value.schema -isnot [long] -or $value.schema -ne 1 -or $value.algorithm -cne 'RSA3072-OAEP-SHA256+A256GCM' -or $value.public_key_sha256 -cne '1b26bb05b12379982b68d00e92178159049af959ba04cc483a06d1b0a49e7307'){throw 'Dedicated diagnostic encryption identity required.'}
 $decoded=@{}
 foreach($field in @('aad','wrapped_key','nonce','tag','ciphertext')){if($value.$field -isnot [string]){throw 'Typed encrypted fields required.'};$decoded[$field]=[Convert]::FromBase64String($value.$field);if([Convert]::ToBase64String($decoded[$field]) -cne $value.$field){throw 'Canonical encrypted fields required.'}}
 if($decoded.aad.Length -gt 1024 -or $decoded.wrapped_key.Length -ne 384 -or $decoded.nonce.Length -ne 12 -or $decoded.tag.Length -ne 16 -or $decoded.ciphertext.Length -lt 1 -or $decoded.ciphertext.Length -gt 2097152){throw 'Exact encryption field bounds required.'}
 $aad=[Text.UTF8Encoding]::new($false,$true).GetString($decoded.aad);$document=[Text.Json.JsonDocument]::Parse($aad,[Text.Json.JsonDocumentOptions]@{MaxDepth=2});try{JsonShape $document.RootElement}finally{$document.Dispose()};$binding=$aad|ConvertFrom-Json
 ClosedKeys $binding @('schema','source_commit','run_id','stage','plaintext_bytes','plaintext_sha256')
 if($binding.schema -isnot [long] -or $binding.schema -ne 1 -or $binding.source_commit -isnot [string] -or $binding.source_commit -cne $SourceCommit -or $binding.run_id -isnot [string] -or $binding.run_id -cnotmatch '^[1-9][0-9]{0,19}$' -or $binding.run_id -cne $env:GITHUB_RUN_ID -or $binding.stage -isnot [string] -or $binding.stage -cne $Stage -or $binding.stage -cnotin @('engine_start','tls_chain_hostname','outgoing_audio','incoming_audio','hold_music_resume','dtmf','blind_transfer','consult_complete','consult_cancel','call_waiting','local_conference','software_vp8','voicemail_local_player') -or $binding.plaintext_bytes -isnot [long] -or $binding.plaintext_bytes -ne $decoded.ciphertext.Length -or $binding.plaintext_sha256 -isnot [string] -or $binding.plaintext_sha256 -cnotmatch '^[a-f0-9]{64}$'){throw 'Exact source/run/stage authenticated metadata required.'}
 [ordered]@{schema=1;file='client-media-private.sealed.json';bytes=$Bytes.Length;sha256=[Convert]::ToHexStringLower([Security.Cryptography.SHA256]::HashData($Bytes));public_key_sha256=$value.public_key_sha256;source_commit=$binding.source_commit;run_id=$binding.run_id;stage=$binding.stage;plaintext_bytes=$binding.plaintext_bytes}
}
function PreserveSealedEngineDiagnostic([string]$InputPath,[string]$OutputPath,[string]$Stage){
 if(![string]::Equals($InputPath,(Join-Path $scope 'engine-diagnostic.sealed.json'),[StringComparison]::OrdinalIgnoreCase) -or ![string]::Equals($OutputPath,(Join-Path $temp 'client-media-private.sealed.json'),[StringComparison]::OrdinalIgnoreCase)){throw 'Exact owned encrypted diagnostic paths required.'}
 $sealedInput=Ordinary $InputPath;$output=Ordinary $OutputPath $false;if(Test-Path -LiteralPath $output){throw 'Encrypted diagnostic output must be new.'}
 $file=[IO.File]::Open($sealedInput,'Open','Read','None');try{if($file.Length -lt 1 -or $file.Length -gt 2810000){throw 'Bounded encrypted diagnostic required.'};$bytes=[byte[]]::new([int]$file.Length);$file.ReadExactly($bytes)}finally{$file.Dispose()}
 $receipt=ReadSealedEngineDiagnostic $bytes $Stage
 $file=[IO.File]::Open($output,'CreateNew','Write','None');try{$file.Write($bytes);$file.Flush($true)}finally{$file.Dispose()}
 $receipt
}
function ReadMediaResult([string]$Path,[switch]$AllowFailure){
 if((Get-Item -LiteralPath $Path).Length -gt 131072){throw 'Bounded media receipt required.'};$raw=Get-Content -LiteralPath $Path -Raw;$document=[System.Text.Json.JsonDocument]::Parse($raw,[System.Text.Json.JsonDocumentOptions]@{MaxDepth=12});try{JsonShape $document.RootElement}finally{$document.Dispose()};$r=$raw|ConvertFrom-Json
 $keys=@('schema','producer','state','stage','error_type','cases','exact_owned_cleanup','SourceCommit','SdkSha256','EngineSha256','test_managed_assembly','production_binary_tested','hardware_media_tested','gui_render_tested','carrier_calls_placed','store_accepted','installer_transaction_executed','production_update_channel_tested')
 if($AllowFailure -and $r.PSObject.Properties.Name -contains 'failure_observation'){$keys+=@('failure_observation','engine_lifecycle');$null=ReadNativeFailureObservation $r.failure_observation;ClosedKeys $r.engine_lifecycle @('start_completed','shutdown_completed');foreach($flag in @('start_completed','shutdown_completed')){if($r.engine_lifecycle.$flag -isnot [bool]){throw 'Typed actual engine lifecycle required.'}}}
 if($AllowFailure -and $r.PSObject.Properties.Name -contains 'engine_observation'){$keys+='engine_observation';$null=ReadEngineObservation $r.engine_observation}
 ClosedKeys $r $keys
 if($r.schema -isnot [long] -or $r.schema -ne 1 -or $r.producer -cne 'OpenWebPbx.Phone.MediaChecks' -or $r.SourceCommit -cne $SourceCommit -or $r.SdkSha256 -cne '9cc84037333daca88af24804e20b9d1f5e41ddd901578484b57dcc6720a8d297' -or $r.EngineSha256 -cne '3d4091bd972c1ea82ff9b6899c091dbeebf66416d6d76475add523ebe10a7542'){throw 'Media receipt source and component bindings differ.'}
 foreach($flag in @('exact_owned_cleanup','test_managed_assembly','production_binary_tested','hardware_media_tested','gui_render_tested','carrier_calls_placed','store_accepted','installer_transaction_executed','production_update_channel_tested')){if($r.$flag -isnot [bool]){throw 'Typed media scope flags required.'}}
 foreach($flag in @('production_binary_tested','hardware_media_tested','gui_render_tested','carrier_calls_placed','store_accepted','installer_transaction_executed','production_update_channel_tested')){if($r.$flag){throw 'Media receipt exceeds its test scope.'}}
 $names=@('tls_chain_hostname','outgoing_audio','incoming_audio','hold_music_resume','dtmf','blind_transfer','consult_complete','consult_cancel','call_waiting','local_conference','software_vp8','voicemail_local_player')
 if($AllowFailure){
  if($r.state -cne 'failed' -or !$r.test_managed_assembly -or $r.error_type -cnotmatch '^(none|[A-Za-z][A-Za-z0-9]{0,70}Exception)$' -or $r.stage -cnotin (@('engine_start')+$names) -or $r.cases -isnot [array] -or $r.cases.Count -gt 12){throw 'Closed native failure scope differs.'}
  for($i=0;$i -lt $r.cases.Count;$i++){if($r.cases[$i].name -cne $names[$i]){throw 'The actual completed-case prefix differs.'}}
 }elseif($r.state -cne 'passed_software_media' -or !$r.exact_owned_cleanup -or !$r.test_managed_assembly -or $r.error_type -cne 'none' -or $r.stage -cne $names[-1] -or $r.cases -isnot [array] -or $r.cases.Count -ne 12 -or (@($r.cases.name) -join '|') -cne ($names -join '|')){throw 'Actual complete native media qualification remains pending.'}
 $map=@{
 tls_chain_hostname=@('actual_tls_registration','wrong_ca_refused','wrong_name_refused');outgoing_audio=@('actual_tls_registration','initial_left','initial_right','active_call_deferred_update','after_update_refusal_left','after_update_refusal_right','idle_allows_update');incoming_audio=@('actual_tls_registration','initial_left','initial_right');
 hold_music_resume=@('actual_tls_registration','initial_left','initial_right','held_caller_music','resumed_left','resumed_right');dtmf=@('actual_tls_registration','initial_left','initial_right','received_exact_digits');
 blind_transfer=@('actual_tls_registration','initial_left','initial_right','transferred_left','transferred_right');consult_complete=@('actual_tls_registration','initial_left','initial_right','consultation_left','consultation_right','completed_left','completed_right');consult_cancel=@('actual_tls_registration','initial_left','initial_right','consultation_left','consultation_right','cancelled_left','cancelled_right');
 call_waiting=@('actual_tls_registration','initial_left','initial_right','waiting_answered_left','waiting_answered_right','original_resumed_left','original_resumed_right');local_conference=@('actual_tls_registration','initial_left','initial_right','host_sdk_recorded_mix','left_received_mix','right_received_mix','sdk_conference_recording');software_vp8=@('actual_tls_registration','initial_left','initial_right','left_decoded_frames','right_decoded_frames','window_seconds','left_width','left_height','right_width','right_height','left_received_fps','right_received_fps');voicemail_local_player=@('actual_tls_registration','native_player_advanced','incoming_call_removed_private_playback','answered_left','answered_right')}
 foreach($case in $r.cases){
  ClosedKeys $case @('name','state','actual_nativephone','file_media_adapter','growing_wav_snapshot_adapter','facts')
  if($case.state -cne 'passed'){throw 'A required native case failed.'};foreach($flag in @('actual_nativephone','file_media_adapter','growing_wav_snapshot_adapter')){if($case.$flag -isnot [bool] -or !$case.$flag){throw 'A native media adapter scope is incomplete.'}}
  ClosedKeys $case.facts $map[$case.name]
  foreach($fact in $case.facts.PSObject.Properties){
   if($fact.Name -in @('left_decoded_frames','right_decoded_frames','window_seconds')){if($fact.Value -isnot [long] -or ($fact.Name -eq 'window_seconds' -and $fact.Value -ne 3) -or ($fact.Name -ne 'window_seconds' -and ($fact.Value -lt 20 -or $fact.Value -gt 10000))){throw 'Actual decoded-video window differs.'}}
   elseif($fact.Name -in @('left_width','left_height','right_width','right_height')){if($fact.Value -isnot [long] -or $fact.Value -lt 64 -or $fact.Value -gt 4096){throw 'Actual decoded-video dimensions differ.'}}
   elseif($fact.Name -in @('left_received_fps','right_received_fps')){if(($fact.Value -isnot [double] -and $fact.Value -isnot [long]) -or ![double]::IsFinite([double]$fact.Value) -or $fact.Value -lt 5 -or $fact.Value -gt 120){throw 'Actual decoded-video rate differs.'}}
   elseif($fact.Name -in @('actual_tls_registration','wrong_ca_refused','wrong_name_refused','received_exact_digits','sdk_conference_recording','native_player_advanced','incoming_call_removed_private_playback','active_call_deferred_update','idle_allows_update')){if($fact.Value -isnot [bool] -or !$fact.Value){throw 'A required native observation failed.'}}
   else{
    ClosedKeys $fact.Value @('Window','FreshSeconds','ObservedSeconds');foreach($name in @('FreshSeconds','ObservedSeconds')){if(($fact.Value.$name -isnot [double] -and $fact.Value.$name -isnot [long]) -or ![double]::IsFinite([double]$fact.Value.$name) -or $fact.Value.$name -lt 3.3 -or $fact.Value.$name -gt 15){throw 'Fresh current-phase decoded samples required.'}}
    $window=$fact.Value.Window;ClosedKeys $window @('StartSeconds','Seconds','MinimumToneRatio','MinimumRms','GoodFraction');foreach($field in $window.PSObject.Properties){if($field.Value -isnot [double] -and $field.Value -isnot [long] -or ![double]::IsFinite([double]$field.Value)){throw 'Finite typed decoded-audio measurements required.'}};if($window.StartSeconds -lt 0 -or $window.StartSeconds -gt 180 -or $window.Seconds -ne 3 -or $window.MinimumToneRatio -lt .65 -or $window.MinimumToneRatio -gt 2 -or $window.MinimumRms -lt 500 -or $window.MinimumRms -gt 32768 -or $window.GoodFraction -ne 1){throw 'The continuous decoded-audio threshold differs.'}
   }
  }
 }
 $r
}
$scope=Join-Path $temp ('phone-client-media-'+[Guid]::NewGuid().ToString('N'));PrivateDirectory $scope
$result=[ordered]@{schema=1;producer='Test-ClientMedia.ps1';source_commit=$SourceCommit;state='failed';stage='prepare';actual_native_calling=$false;hardware_media_tested=$false;production_binary_tested=$false;store_accepted=$false;exact_owned_cleanup=$false;system_preserved=$false;hold_audio_fixture='generated1553Hz_PCM_WAV';licensed_music_file_tested=$false}
$before=$null;$failure=$null;$media=$null;$ownedClean=$true
$script:serviceBoundaryBefore=$null;$script:serviceBoundaries=[Collections.Generic.List[object]]::new();$script:serviceBoundaryClock=[Diagnostics.Stopwatch]::StartNew()
try{
 $before=SystemSnapshot;try{$script:serviceBoundaryBefore=($before|ConvertFrom-Json).services}catch{}
 $result.stage='sdk_extract';$sdk=Join-Path $scope 'sdk';ExpandSdk $SdkZip $sdk;ObserveServiceBoundary 'after_sdk_extract'
 $result.stage='msi_extract';$extraction=Join-Path $scope 'msi';$helper=Join-Path $repo 'packaging/freeswitch/extract-windows-core.py';$adapter=Join-Path $client 'tests/media/extract_media_engine.py'
 if((RunChild $python @($adapter,'--helper',$helper,'--msi',$CoreMsi,'--output',$extraction) $scope 180 -MsiDiagnostic) -ne 0){throw 'Read-only MSI media extraction failed.'}
 ObserveServiceBoundary 'after_msi_extract'
 $engine=Join-Path $extraction 'core';$zip=[IO.Compression.ZipFile]::OpenRead($EngineZip)
 try{
  foreach($binding in @(@('engine/mod/mod_sofia.dll','fa58601adfab5cd71ac598035c41fafe335f23f0ca038cb0b5c23423ff43d4d5'),@('engine/native-manifest.json',$null),@('source/source-manifest.json','3b230ae320b67bdd88d1d7b6fe3c9e116cf571550b489bba1a7613d7b2cf6bb1'))){
   $matches=@($zip.Entries|Where-Object FullName -CEQ $binding[0]);if($matches.Count -ne 1 -or $matches[0].Length -gt 32MB){throw 'Exact accepted engine member is absent.'}
   $dest=Join-Path $scope ([IO.Path]::GetFileName($binding[0]));$input=$matches[0].Open();$output=[IO.File]::Open($dest,'CreateNew','Write','None');try{$input.CopyTo($output);$output.Flush($true)}finally{$output.Dispose();$input.Dispose()}
   if($binding[1] -and (Hash $dest) -cne $binding[1]){throw 'Accepted engine member binding differs.'}
  }
 }finally{$zip.Dispose()}
 $manifest=Get-Content (Join-Path $scope 'native-manifest.json') -Raw|ConvertFrom-Json
 if($manifest.source_manifest_sha256 -cne '3b230ae320b67bdd88d1d7b6fe3c9e116cf571550b489bba1a7613d7b2cf6bb1' -or $manifest.source_msi_sha256 -cne 'f5649e33ad46be2ebdb1d98019bd149c86519f0dca9f47fb881207045203a34d' -or $manifest.files.'mod/mod_sofia.dll' -cne 'fa58601adfab5cd71ac598035c41fafe335f23f0ca038cb0b5c23423ff43d4d5'){throw 'Accepted patched-engine provenance differs.'}
 Copy-Item -LiteralPath (Join-Path $scope 'mod_sofia.dll') -Destination (Join-Path $engine 'mod/mod_sofia.dll') -Force
 $result.stage='managed_build';$app=Join-Path $scope 'app';$project=Join-Path $client 'tests/OpenWebPbx.Phone.MediaChecks/OpenWebPbx.Phone.MediaChecks.csproj';$binding=Join-Path $sdk 'LinphoneWrapper.cs'
 if((RunChild $dotnet @('publish',$project,'-c','Release','-r','win-x64','--self-contained','true','--disable-build-servers','-p:UseSharedCompilation=false','-m:1',('-p:LinphoneBinding='+$binding),'-o',$app) $client 600) -ne 0){throw 'Actual media fixture build failed.'}
 ObserveServiceBoundary 'after_managed_build'
 foreach($item in Get-ChildItem -LiteralPath $sdk -File -Filter '*.dll'){if(Test-Path (Join-Path $app $item.Name)){throw 'SDK runtime collides with managed output.'};Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $app $item.Name)}
 Copy-Item -LiteralPath (Join-Path $sdk 'native') -Destination (Join-Path $app 'native') -Recurse
 Add-Type -AssemblyName System.Drawing
 foreach($n in 1,2){$image=Join-Path $scope ('frame'+$n+'.jpg');$bitmap=[Drawing.Bitmap]::new(640,480);$g=[Drawing.Graphics]::FromImage($bitmap);try{$g.Clear($(if($n -eq 1){[Drawing.Color]::SteelBlue}else{[Drawing.Color]::DarkOrange}));$g.FillRectangle([Drawing.Brushes]::White,40,40,180,120);$g.FillEllipse([Drawing.Brushes]::Black,360,250,120,120);$bitmap.Save($image,[Drawing.Imaging.ImageFormat]::Jpeg)}finally{$g.Dispose();$bitmap.Dispose()}}
 $inputFile=Join-Path $scope 'lab.json';$childReport=Join-Path $scope 'media.json'
 [ordered]@{Schema=1;Root=$scope;EngineRoot=$engine;SourceCommit=$SourceCommit;SdkSha256='9cc84037333daca88af24804e20b9d1f5e41ddd901578484b57dcc6720a8d297';EngineSha256='3d4091bd972c1ea82ff9b6899c091dbeebf66416d6d76475add523ebe10a7542';ImageA=(Join-Path $scope 'frame1.jpg');ImageB=(Join-Path $scope 'frame2.jpg');RunId=$env:GITHUB_RUN_ID}|ConvertTo-Json|Set-Content -LiteralPath $inputFile -Encoding utf8NoBOM
 $result.stage='actual_media';$exe=Join-Path $app 'OpenWebPbx.Phone.MediaChecks.exe';ObserveServiceBoundary 'immediately_before_native_media';$result.child_exit=RunChild $exe @('--run',$inputFile,$childReport) ([Environment]::SystemDirectory) 1200;ObserveServiceBoundary 'after_native_media'
 if($result.child_exit -ne 0){
  if(Test-Path -LiteralPath $childReport){$failed=ReadMediaResult $childReport -AllowFailure;$result.native_failure=[ordered]@{stage=$failed.stage;error_type=$failed.error_type;completed_cases=[int]$failed.cases.Count;owned_cleanup=[bool]$failed.exact_owned_cleanup};if($failed.PSObject.Properties.Name -contains 'failure_observation'){$result.native_failure.observation=$failed.failure_observation;$result.native_failure.engine_lifecycle=$failed.engine_lifecycle};if($failed.PSObject.Properties.Name -contains 'engine_observation'){$result.native_failure.engine_observation=$failed.engine_observation};if($failed.PSObject.Properties.Name -contains 'engine_observation' -and $failed.engine_observation.sealed_original){try{$result.sealed_engine_diagnostic=PreserveSealedEngineDiagnostic (Join-Path $scope 'engine-diagnostic.sealed.json') $sealedOutput $failed.stage}catch{$result.sealed_engine_diagnostic_preservation_refused=$true}}}
  throw 'Actual Windows client media lab failed.'
 };$media=ReadMediaResult $childReport;$result.actual_native_calling=$true
 if(!$script:tcpObserved -or !$script:udpObserved -or $script:socketSamples -lt 3){throw 'Actual owned loopback socket sampling is incomplete.'};$result.loopback_socket_samples=$script:socketSamples;$result.owned_socket_sampling_loopback=$true
 $result.managed_fixture_sha256=Hash (Join-Path $app 'OpenWebPbx.Phone.Windows.dll');$result.native_linphone_sha256=Hash (Join-Path $app 'liblinphone.dll');$result.media=$media
 $result.state='passed_software_media'
}catch{$failure=$_;$result.error_type=$_.Exception.GetType().Name;$result.source_line=[int]$_.InvocationInfo.ScriptLineNumber}
finally{
 $result.service_boundaries=$script:serviceBoundaries.ToArray()
 if($null -ne $script:msiChildExit){$result.msi_child_exit_code=[int]$script:msiChildExit}
 if($script:msiFailure){$result.msi_failure=$script:msiFailure}
 if($script:msiObservationRefused){$result.msi_failure_observation_refused=$true}
 try{
  $journal=Join-Path $scope 'owned-processes.jsonl'
  if(Test-Path $journal){foreach($r in @(ReadOwnedRows $journal)){$p=Get-Process -Id $r.pid -ErrorAction SilentlyContinue;if($p){try{$expected=if($r.role -ceq 'peer'){Join-Path $scope 'app/OpenWebPbx.Phone.MediaChecks.exe'}else{Join-Path $scope 'engine/FreeSwitchConsole.exe'};if($p.StartTime.ToUniversalTime().Ticks -ne $r.created_utc_ticks -or $p.MainModule.FileName -ine $expected -or (Hash $expected) -cne $r.executable_sha256){throw 'Refuse a foreign process at a recorded PID.'};$p.Kill($true);if(!$p.WaitForExit(10000)){throw 'Owned process did not stop.'};$ownedClean=$false}finally{$p.Dispose()}}}}
  $roots=Join-Path $scope 'owned-roots.txt';if(Test-Path $roots){$rows=@(Get-Content -LiteralPath $roots);if($rows.Count -gt 48 -or @($rows|Select-Object -Unique).Count -ne $rows.Count){throw 'Owned peer-root inventory differs.'};foreach($leaf in $rows){if($leaf -cnotmatch '^phone-media-[a-f0-9]{32}$'){throw 'Owned peer-root leaf differs.'};$path=Join-Path $temp $leaf;if(Test-Path $path){NoLinks $path;Remove-Item -LiteralPath $path -Recurse -Force;$ownedClean=$false}}}
  if($before){$after=SystemSnapshot;$result.system_preserved=$after -ceq $before;if(!$result.system_preserved){try{$result.snapshot_diff=MediaSnapshotDiffCounts $before $after}catch{$result.snapshot_diff_observation_refused=$true}}};if(!$result.system_preserved){$ownedClean=$false}
  NoLinks $scope;Remove-Item -LiteralPath $scope -Recurse -Force
 }catch{$ownedClean=$false;$result.cleanup_error_type=$_.Exception.GetType().Name}
 $result.exact_owned_cleanup=$ownedClean -and !(Test-Path -LiteralPath $scope)
 if(!$result.exact_owned_cleanup -or !$result.system_preserved){$result.state='failed';$result.actual_native_calling=$false}
 try{$output=[IO.File]::Open($Report,'CreateNew','Write','None');try{$bytes=[Text.Encoding]::UTF8.GetBytes(($result|ConvertTo-Json -Depth 12));$output.Write($bytes);$output.Flush($true)}finally{$output.Dispose()}}catch{if($failure){$failure.Exception.Data['closed_media_receipt_write_failed']=$true}else{$failure=$_}}
}
if($failure){throw $failure};if($result.state -cne 'passed_software_media'){throw 'Client media qualification is incomplete.'}
