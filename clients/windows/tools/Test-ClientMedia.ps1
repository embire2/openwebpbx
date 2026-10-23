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
 $proof=[ordered]@{schema=1;producer='Test-ClientMedia.ps1';state='observed_snapshot_counts';exact_snapshot_changed=($Before -cne $After);services=(MediaSnapshotRowCounts $objects[0].services $objects[1].services);root_certificates=(MediaSnapshotRowCounts $objects[0].root_certificates $objects[1].root_certificates);firewall=$firewall}
 foreach($row in @($proof.services,$proof.root_certificates)+@($firewall.Values)){foreach($name in @('before_rows','after_rows','removed_row_values','added_row_values')){if(($row[$name] -isnot [int] -and $row[$name] -isnot [long]) -or $row[$name] -lt 0 -or $row[$name] -gt 100000){throw 'Typed bounded snapshot counts required.'}}}
 return $proof
}
function ReadMediaResult([string]$Path,[switch]$AllowFailure){
 if((Get-Item -LiteralPath $Path).Length -gt 131072){throw 'Bounded media receipt required.'};$raw=Get-Content -LiteralPath $Path -Raw;$document=[System.Text.Json.JsonDocument]::Parse($raw,[System.Text.Json.JsonDocumentOptions]@{MaxDepth=12});try{JsonShape $document.RootElement}finally{$document.Dispose()};$r=$raw|ConvertFrom-Json
 ClosedKeys $r @('schema','producer','state','stage','error_type','cases','exact_owned_cleanup','SourceCommit','SdkSha256','EngineSha256','test_managed_assembly','production_binary_tested','hardware_media_tested','gui_render_tested','carrier_calls_placed','store_accepted','installer_transaction_executed','production_update_channel_tested')
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
try{
 $before=SystemSnapshot;$result.stage='sdk_extract';$sdk=Join-Path $scope 'sdk';ExpandSdk $SdkZip $sdk
 $result.stage='msi_extract';$extraction=Join-Path $scope 'msi';$helper=Join-Path $repo 'packaging/freeswitch/extract-windows-core.py';$adapter=Join-Path $client 'tests/media/extract_media_engine.py'
 if((RunChild $python @($adapter,'--helper',$helper,'--msi',$CoreMsi,'--output',$extraction) $scope 180 -MsiDiagnostic) -ne 0){throw 'Read-only MSI media extraction failed.'}
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
 foreach($item in Get-ChildItem -LiteralPath $sdk -File -Filter '*.dll'){if(Test-Path (Join-Path $app $item.Name)){throw 'SDK runtime collides with managed output.'};Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $app $item.Name)}
 Copy-Item -LiteralPath (Join-Path $sdk 'native') -Destination (Join-Path $app 'native') -Recurse
 Add-Type -AssemblyName System.Drawing
 foreach($n in 1,2){$image=Join-Path $scope ('frame'+$n+'.jpg');$bitmap=[Drawing.Bitmap]::new(640,480);$g=[Drawing.Graphics]::FromImage($bitmap);try{$g.Clear($(if($n -eq 1){[Drawing.Color]::SteelBlue}else{[Drawing.Color]::DarkOrange}));$g.FillRectangle([Drawing.Brushes]::White,40,40,180,120);$g.FillEllipse([Drawing.Brushes]::Black,360,250,120,120);$bitmap.Save($image,[Drawing.Imaging.ImageFormat]::Jpeg)}finally{$g.Dispose();$bitmap.Dispose()}}
 $inputFile=Join-Path $scope 'lab.json';$childReport=Join-Path $scope 'media.json'
 [ordered]@{Schema=1;Root=$scope;EngineRoot=$engine;SourceCommit=$SourceCommit;SdkSha256='9cc84037333daca88af24804e20b9d1f5e41ddd901578484b57dcc6720a8d297';EngineSha256='3d4091bd972c1ea82ff9b6899c091dbeebf66416d6d76475add523ebe10a7542';ImageA=(Join-Path $scope 'frame1.jpg');ImageB=(Join-Path $scope 'frame2.jpg')}|ConvertTo-Json|Set-Content -LiteralPath $inputFile -Encoding utf8NoBOM
 $result.stage='actual_media';$exe=Join-Path $app 'OpenWebPbx.Phone.MediaChecks.exe';$result.child_exit=RunChild $exe @('--run',$inputFile,$childReport) ([Environment]::SystemDirectory) 1200
 if($result.child_exit -ne 0){
  if(Test-Path -LiteralPath $childReport){$failed=ReadMediaResult $childReport -AllowFailure;$result.native_failure=[ordered]@{stage=$failed.stage;error_type=$failed.error_type;completed_cases=[int]$failed.cases.Count;owned_cleanup=[bool]$failed.exact_owned_cleanup}}
  throw 'Actual Windows client media lab failed.'
 };$media=ReadMediaResult $childReport;$result.actual_native_calling=$true
 if(!$script:tcpObserved -or !$script:udpObserved -or $script:socketSamples -lt 3){throw 'Actual owned loopback socket sampling is incomplete.'};$result.loopback_socket_samples=$script:socketSamples;$result.owned_socket_sampling_loopback=$true
 $result.managed_fixture_sha256=Hash (Join-Path $app 'OpenWebPbx.Phone.Windows.dll');$result.native_linphone_sha256=Hash (Join-Path $app 'liblinphone.dll');$result.media=$media
 $result.state='passed_software_media'
}catch{$failure=$_;$result.error_type=$_.Exception.GetType().Name;$result.source_line=[int]$_.InvocationInfo.ScriptLineNumber}
finally{
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
