#Requires -RunAsAdministrator
#Requires -Version 7.4
<#
SPDX-License-Identifier: AGPL-3.0-or-later.
Two independent, opt-in disposable stages. Prepare builds real newer assemblies
from the qualified immutable baseline plus two recorded version overlays. Qualify uses
only root-signed envelopes supplied privately; no signing key is accepted.
No owner-machine, public-release/feed or carrier qualification is performed.
#>
[CmdletBinding()]
param(
 [Parameter(Mandatory)][ValidateSet('PrepareCanary','QualifySigned')][string]$Mode,
 [Parameter(Mandatory)][ValidatePattern('^[0-9]+$')][string]$BaseSuiteRunId,
 [ValidatePattern('^[0-9]+$')][string]$CanaryRunId,
 [ValidatePattern('^\d+\.\d+\.\d+$')][string]$BaseVersion='1.0.13',
 [ValidatePattern('^\d+\.\d+\.\d+$')][string]$CanaryVersion='1.0.14',
 [switch]$DisposableHostedRunner
)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
. (Join-Path $PSScriptRoot 'windows-upgrade-health-quiescence.ps1')
if([version]$CanaryVersion -le [version]$BaseVersion){throw 'The canary must be a genuinely newer numeric version.'}
if(!$DisposableHostedRunner -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:RUNNER_OS -ne 'Windows' -or $env:GITHUB_REPOSITORY -ne 'embire2/openwebpbx'){throw 'Only the explicitly disposable owned GitHub-hosted Windows runner is authorized.'}
$os=Get-CimInstance Win32_OperatingSystem
if($os.ProductType -eq 1 -or $os.Caption -notmatch 'Windows Server 2025' -or [Environment]::OSVersion.Version.Build -lt 26100){throw 'A disposable Windows Server 2025 x64 runner is required.'}
if($Mode -eq 'PrepareCanary' -and ($CanaryRunId -or $env:WINDOWS_UPDATER_SIGNED_PACKETS_B64)){throw 'Preparation must never receive private signed packets.'}
if($Mode -eq 'QualifySigned' -and (!$CanaryRunId -or !$env:WINDOWS_UPDATER_SIGNED_PACKETS_B64)){throw 'Root-reviewed packets and the exact prepared canary run are required.'}
$source=Split-Path $PSScriptRoot -Parent;$root='C:\OpenWebPBX';$state=Join-Path $env:ProgramData 'OpenWebPBX';$engine='C:\Program Files\FreeSWITCH';$configuration=Join-Path $env:ProgramData 'fusionpbx'
$work=Join-Path $env:RUNNER_TEMP ('openwebpbx-updater-'+[Guid]::NewGuid().ToString('N'))
$public=Join-Path $env:RUNNER_TEMP 'openwebpbx-updater-facts';$output=Join-Path $env:RUNNER_TEMP 'openwebpbx-updater-canary'
$phase='verified baseline artifacts';$installed=$false;$transport=$null;$transportRoot=$null;$ownHosts=$false;$serviceEnvironment=$null;$inputFile=$null;$settings=$null;$scope=$null;$fixtureCreated=$false
$managerOwned=$false;$managerStarted=$null;$managerName=$null;$managerSid=$null;$managerSession=0
$qualificationHealthOriginal=$null;$PackageRoot=$null
$retainedProcesses=[Collections.Generic.List[Diagnostics.Process]]::new()
$script:qualificationFailedChild=$null
$script:qualificationComparisonFailure=$null
$script:qualificationFailedHash=$null
$facts=[ordered]@{schema=1;mode=$Mode;run_id=$env:GITHUB_RUN_ID;source_commit=$env:GITHUB_SHA;state='running';scope='disposable Windows Server 2025, fictional PBX, laboratory trusted HTTPS';checks=@();gates=[ordered]@{canary_build='pending';fault_https_download='unqualified';fault_rollback='unqualified';normal_https_download='unqualified';newer_upgrade='unqualified';natural_updater_restart='unqualified';manager_reopen_rollback='unqualified';manager_reopen_success='unqualified';protected_data='unqualified';public_github_delivery='unqualified';owner_106_upgrade='unqualified';carrier='unqualified'};cleanup='pending'}
function Check([bool]$Value,[string]$Message){if(!$Value){throw $Message}}
function QualificationFailureObservation([string]$Trace,$Child,$Comparison=$null,$HashFailure=$null){
 # Project only known source callsites and fixed child identities. Messages,
 # process arguments, private streams and the paths in the trace stay private.
 $frames=[Collections.Generic.List[object]]::new();$seen=@{}
 $functions=@('Check','Hash','SnapshotHash','WriteJson','PrivateDirectory','SecureCanaryFaultContract','Api','SafeRelative','ExpandSafe','Artifact','CheckedProcess','NativeVersions','StopQualificationIis','PrepareCanary','Fixture','Python','InitializeQualificationBackupWorker','DatabaseSnapshot','FileSnapshot','TaskSnapshot','ManagerTaskValid','OwnedManagers','WaitManager','BeginManager','OriginalProcessProofSource','RetainQualificationProcess','AssertOriginalProcessState','ManagerReopened','EqualTaskSnapshots','Equal','NormalTaskPreservation','InstalledVersions','WaitInstall','DownloadProof','GetManagerOriginalExitProof','<ScriptBlock>')
 if($Trace -and $Trace.Length -le 16384){
  $lines=[regex]::Split($Trace,'\r?\n')
  for($i=0;$i -lt [Math]::Min($lines.Count,64) -and $frames.Count -lt 6;$i++){
   $match=[regex]::Match($lines[$i].Trim(),'^at (?<function>[^,\r\n]{1,80}), (?:[^\r\n]*[\\/])?(?<source>windows-updater-qualification\.ps1|windows-upgrade-acceptance\.ps1): line (?<line>[0-9]{1,5})$')
   if(!$match.Success -or $match.Groups['function'].Value -cnotin $functions){continue}
   $line=[int]$match.Groups['line'].Value;if($line -lt 1){continue}
   $name=$match.Groups['function'].Value;$sourceName=$match.Groups['source'].Value;$key=$sourceName+':'+$name+':'+$line
   if(!$seen.ContainsKey($key)){$seen[$key]=$true;$frames.Add(@{source_basename=$sourceName;source_line=$line;function=$name})}
  }
 }
 $labels=@('fetch-immutable-source','source-worktree','server-14-build','updater-14-build','desktop-14-build','OpenWebPbx.Checks-checks','OpenWebPbx.Updater.Checks-checks','prepare-audited-canary','verify-qualified-base','verify-fault','verify-normal','verify-private-signatures','actual-fresh13','python-setup','python-prepare-pki','python-request','compare-fault-database','compare-fault-files','compare-fault-tasks','compare-normal-tasks','compare-normal-database','compare-normal-protected-files','compare-normal-installation-secrets','fixture-baseline','fixture-discover','fixture-status','fixture-snapshot','fixture-cleanup')
 $childReport=$null
 if($Child -is [Collections.IDictionary] -and $Child.label -is [string] -and $Child.label -cin $labels -and $Child.caller -cin @('CheckedProcess','Fixture') -and $Child.caller -cin $frames.ToArray().function){
  if($Child.completion -ceq 'exit' -and $Child.exit_code -is [int] -and $Child.exit_code -ne 0){$childReport=@{label=$Child.label;completion='exit';exit_code=$Child.exit_code}}
  elseif($Child.completion -ceq 'deadline' -and $null -eq $Child.exit_code){$childReport=@{label=$Child.label;completion='deadline';exit_code=$null}}
 }
 $safe=@{schema=1;callsites=$frames.ToArray();child=$childReport}
 if($childReport -and $frames.ToArray().function -ccontains 'Equal' -and $Comparison -is [Collections.IDictionary] -and $Comparison.label -is [string] -and $Comparison.label -cin @('fault-database','fault-files','fault-tasks','normal-database','normal-protected-files','normal-installation-secrets','normal-tasks') -and $childReport.label -ceq ('compare-'+$Comparison.label)){
  $report=QualificationComparisonDetails $Comparison.report
  if($report -and (($report.comparison_result -ceq 'different' -and $childReport.completion -ceq 'exit' -and $childReport.exit_code -eq 1) -or ($report.comparison_result -ceq 'error' -and $childReport.completion -ceq 'exit' -and $childReport.exit_code -eq 2) -or $report.comparison_result -ceq 'unavailable')){
   $safe.comparison=$report
   if($Comparison.label -ceq 'fault-files' -and $report.comparison_result -ceq 'different'){$capture=QualificationFileCaptureFields $Comparison.capture;if($capture){$safe.file_capture=$capture}}
  }
 }
 if($frames.ToArray().function -ccontains 'Hash' -and $frames.ToArray().function -ccontains 'SnapshotHash' -and $frames.ToArray().function -ccontains 'FileSnapshot'){$hash=QualificationHashFailureFields $HashFailure;if($hash){$safe.hash_failure=$hash}}
 return $safe
}
function Hash([string]$Path){return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function QualificationSnapshotPaths {
 # Mirror the existing comparison classifier's closed public paths only.
 $paths=@{}
 foreach($pair in @(@('installation','installation'),@('runtime','runtime'),@('updater-install','updater_install'),@('native-engine','native_engine'),@('local-codec','local_codec'),@('phone-tls','phone_tls_metadata'))){$paths['c:/programdata/openwebpbx/'+$pair[0]+'.json']=$pair[1]}
 $paths+=@{'c:/openwebpbx'='program_root';'c:/openwebpbx/php/php.ini'='php_ini';'c:/openwebpbx/php/extras/ssl/openssl.cnf'='php_openssl';'c:/openwebpbx/php/extras/ssl/cacert.pem'='php_cacert';'c:/programdata/openwebpbx/mobile-notifications'='notification_store';'c:/programdata/openwebpbx/mobile-notifications/config.json'='notification_config';'c:/programdata/openwebpbx/mobile-notifications/config.json.lock'='notification_lock';'c:/programdata/fusionpbx'='fusionpbx_root';'c:/programdata/fusionpbx/config.conf'='fusionpbx_config';'c:/programdata/fusionpbx/openweb-template.key'='fusionpbx_template_key';'c:/programdata/openwebpbx/automatic-backups/worker.lock'='automatic_backups_worker_lock';'c:/programdata/openwebpbx/storage'='storage_root';'c:/programdata/openwebpbx/storage/openweb-music'='stock_music_root';'c:/programdata/openwebpbx/storage/openweb-music/readme.md'='stock_music_readme';'c:/programdata/openwebpbx/storage/openweb-music/manifest.json'='stock_music_manifest';'c:/program files/freeswitch/sounds'='stock_sounds_root';'c:/program files/freeswitch/sounds/openwebpbx'='stock_sounds_openwebpbx'}
 foreach($name in 'phone-tls','public-access','automatic-backups','backup-restore','backup-control','backup-downloads','codec-compiler-cache','codec-build'){$paths['c:/programdata/openwebpbx/'+$name]=$name.Replace('-','_')+'_root'}
 foreach($rate in 8000,16000,32000,48000){$base='c:/programdata/openwebpbx/storage/openweb-music/'+$rate;$paths[$base]='stock_music_'+$rate+'_dir';$paths[$base+'/lofi-beat-loop-schmoop.wav']='stock_music_'+$rate+'_track'}
 return $paths
}
function QualificationHashFailureFields($Record){
 if($Record -isnot [Collections.IDictionary] -or $Record.Count -ne 7){return $null}
 foreach($key in $Record.Keys){if($key -isnot [string] -or $key -cnotin @('stage','file_label','category','config_scope','exception_type','hresult','win32_code')){return $null}}
 $sets=@{stage=@('unobserved','before_fault_full','before_fault_protected','after_fault_full','after_normal_protected');file_label=@('unknown')+@((QualificationSnapshotPaths).Values);category=@('web','server','desktop','tools','updater','config','notifications','media','native','other');config_scope=@('none','fusionpbx','phone_tls','public_access','automatic_backups','backup_restore','backup_control','backup_downloads','codec_compiler_cache','codec_build');exception_type=@('IOException','UnauthorizedAccessException','FileNotFoundException','DirectoryNotFoundException','PathTooLongException','NotSupportedException','ArgumentException','SecurityException','ItemNotFoundException','ProviderInvocationException','RuntimeException','Win32Exception','OtherError')}
 $safe=@{}
 foreach($name in $sets.Keys){if($Record[$name] -isnot [string] -or $Record[$name] -cnotin $sets[$name]){return $null};$safe[$name]=$Record[$name]}
 if($Record.hresult -isnot [int] -or ($null -ne $Record.win32_code -and ($Record.win32_code -isnot [int] -or $Record.win32_code -lt 0 -or $Record.win32_code -gt 65535))){return $null}
 $safe.hresult=$Record.hresult;$safe.win32_code=$Record.win32_code;return $safe
}
function QualificationSnapshotHashFailure([string]$Path,[string]$Stage,[Exception]$Exception){
 $folded=if($Path -and $Path.Length -le 4096){$Path.Replace('\','/').ToLowerInvariant()}else{''}
 $paths=QualificationSnapshotPaths;$label=if($paths.ContainsKey($folded)){$paths[$folded]}else{'unknown'};$category='other';$scope='none'
 foreach($pair in @(@('c:/openwebpbx/web','web'),@('c:/openwebpbx/server','server'),@('c:/openwebpbx/desktop','desktop'),@('c:/openwebpbx/tools','tools'),@('c:/openwebpbx/updater','updater'),@('c:/programdata/fusionpbx','config'),@('c:/programdata/openwebpbx/mobile-notifications','notifications'),@('c:/programdata/openwebpbx/storage','media'),@('c:/program files/freeswitch/sounds/openwebpbx','media'),@('c:/program files/freeswitch','native'),@('c:/programdata/openwebpbx','config'),@('c:/openwebpbx','other'))){if($folded -ceq $pair[0] -or $folded.StartsWith($pair[0]+'/',[StringComparison]::Ordinal)){$category=$pair[1];break}}
 foreach($pair in @(@('c:/programdata/fusionpbx','fusionpbx'),@('c:/programdata/openwebpbx/phone-tls','phone_tls'),@('c:/programdata/openwebpbx/public-access','public_access'),@('c:/programdata/openwebpbx/automatic-backups','automatic_backups'),@('c:/programdata/openwebpbx/backup-restore','backup_restore'),@('c:/programdata/openwebpbx/backup-control','backup_control'),@('c:/programdata/openwebpbx/backup-downloads','backup_downloads'),@('c:/programdata/openwebpbx/codec-compiler-cache','codec_compiler_cache'),@('c:/programdata/openwebpbx/codec-build','codec_build'))){if($folded -ceq $pair[0] -or $folded.StartsWith($pair[0]+'/',[StringComparison]::Ordinal)){$scope=$pair[1];break}}
 $observedException=$Exception
 for($depth=0;$depth -lt 7 -and $observedException.InnerException;$depth++){$observedException=$observedException.InnerException}
 $type=$observedException.GetType().Name
 if($type -cnotin @('IOException','UnauthorizedAccessException','FileNotFoundException','DirectoryNotFoundException','PathTooLongException','NotSupportedException','ArgumentException','SecurityException','ItemNotFoundException','ProviderInvocationException','RuntimeException','Win32Exception')){$type='OtherError'}
 $hr=[int]$observedException.HResult;$code=$null
 if($observedException -is [ComponentModel.Win32Exception] -and $observedException.NativeErrorCode -ge 0 -and $observedException.NativeErrorCode -le 65535){$code=[int]$observedException.NativeErrorCode}elseif(([int64]$hr -band 4294901760) -eq 2147942400){$code=[int]($hr -band 65535)}
 return QualificationHashFailureFields @{stage=$Stage;file_label=$label;category=$category;config_scope=$scope;exception_type=$type;hresult=$hr;win32_code=$code}
}
function SnapshotHash([string]$Path,[string]$Stage){
 try{return Hash $Path}catch{
  # This call alone supplies context; global Hash uses never inherit snapshot state.
  try{$script:qualificationFailedHash=QualificationSnapshotHashFailure $Path $Stage $_.Exception}catch{$script:qualificationFailedHash=$null}
  throw
 }
}
function WriteJson([string]$Path,$Value){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 32),[Text.UTF8Encoding]::new($false))}
function PrivateDirectory([string]$Path){New-Item -ItemType Directory -Force $Path|Out-Null;& icacls.exe $Path /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F'|Out-Null;Check ($LASTEXITCODE -eq 0) 'Private qualification permissions failed.'}
function SecureCanaryFaultContract([string]$Path,[string]$Directory){
 Check ([IO.Path]::IsPathRooted($Path) -and [IO.Path]::IsPathRooted($Directory)) 'An absolute owned contract path is required.'
 $full=[IO.Path]::GetFullPath($Path);$parent=[IO.Path]::GetFullPath($Directory).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
 Check ([IO.Path]::GetDirectoryName($full).Equals($parent,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($full) -cin @('canary-fault-contract.json','canary-host-sentinel.json')) 'Only the two exact owned canary contracts may be secured.'
 $folder=Get-Item -LiteralPath $parent -Force;$item=Get-Item -LiteralPath $full -Force
 Check ($folder.PSIsContainer -and !($folder.Attributes -band [IO.FileAttributes]::ReparsePoint) -and !$item.PSIsContainer -and !($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $item.Length -le 65536) 'An ordinary bounded owned canary contract is required.'
 $before=Hash $full;$length=$item.Length
 & "$env:SystemRoot\System32\icacls.exe" $full /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F'|Out-Null
 Check ($LASTEXITCODE -eq 0) 'The owned canary contract DACL command failed.'
 & "$env:SystemRoot\System32\icacls.exe" $full /setowner '*S-1-5-32-544'|Out-Null
 Check ($LASTEXITCODE -eq 0) 'The owned canary contract owner command failed.'
 $acl=Get-Acl -LiteralPath $full;$rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
 Check ($acl.AreAccessRulesProtected -and $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ceq 'S-1-5-32-544' -and $rules.Count -eq 2) 'The owned canary contract protection or owner differs.'
 $seen=@{}
 foreach($rule in $rules){
  $sid=$rule.IdentityReference.Value
  Check ($sid -cin @('S-1-5-32-544','S-1-5-18') -and !$seen.ContainsKey($sid) -and !$rule.IsInherited -and $rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and [int64]$rule.FileSystemRights -eq [int64][Security.AccessControl.FileSystemRights]::FullControl -and $rule.InheritanceFlags -eq [Security.AccessControl.InheritanceFlags]::None -and $rule.PropagationFlags -eq [Security.AccessControl.PropagationFlags]::None) 'The owned canary contract grants unexpected access.'
  $seen[$sid]=$true
 }
 Check ((Get-Item -LiteralPath $full -Force).Length -eq $length -and (Hash $full) -ceq $before) 'The owned canary contract content changed.'
}
function RandomSecret {return [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()}
function Api([string]$Endpoint){Check (![string]::IsNullOrEmpty($env:GH_TOKEN)) 'The scoped artifact token is unavailable.';return Invoke-RestMethod ('https://api.github.com/repos/embire2/openwebpbx/'+$Endpoint) -Headers @{Authorization=('Bearer '+$env:GH_TOKEN);Accept='application/vnd.github+json';'X-GitHub-Api-Version'='2022-11-28'}}
function SafeRelative([string]$Path){
 Check ($Path -and !$Path.StartsWith('/') -and $Path -notmatch '[\\<>:"|?*\x00-\x1f\x7f]') 'Unsafe artifact path.'
 foreach($part in $Path.Split('/')){Check ($part -and $part -notin '.','..' -and $part -notmatch '[. ]$' -and $part -notmatch '^(CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)') 'Unsafe artifact component.'};return $Path
}
function ExpandSafe([string]$Archive,[string]$Destination){
 $zip=[IO.Compression.ZipFile]::OpenRead($Archive);$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);$total=0L
 try{
  Check ($zip.Entries.Count -le 100000) 'Artifact inventory exceeds its bound.'
  foreach($entry in $zip.Entries){$relative=SafeRelative $entry.FullName.TrimEnd('/');Check ($seen.Add($relative) -and (($entry.ExternalAttributes -shr 16) -band 61440) -ne 40960 -and $entry.Length -le 4GB) 'Linked, colliding or oversized artifact member.';$total+=$entry.Length;Check ($total -le 24GB) 'Artifact size exceeds its bound.';if($entry.FullName.EndsWith('/')){continue};$target=Join-Path $Destination $relative;New-Item -ItemType Directory -Force (Split-Path $target -Parent)|Out-Null;[IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$target,$false)}
 }finally{$zip.Dispose()}
}
function Artifact([string]$RunId,[string]$Name,[string]$Workflow){
 $run=Api ('actions/runs/'+$RunId)
 Check ($run.repository.full_name -eq 'embire2/openwebpbx' -and $run.head_repository.full_name -eq 'embire2/openwebpbx' -and $run.event -eq 'workflow_dispatch' -and $run.path -eq $Workflow -and $run.head_sha -match '^[a-f0-9]{40}$' -and $run.status -eq 'completed' -and $run.conclusion -eq 'success') 'The exact successful owned workflow is required.'
 $artifacts=@((Api ('actions/runs/'+$RunId+'/artifacts?per_page=100')).artifacts|Where-Object {$_.name -eq $Name -and !$_.expired})
 Check ($artifacts.Count -eq 1 -and $artifacts[0].digest -match '^sha256:[a-f0-9]{64}$' -and $artifacts[0].size_in_bytes -le 8GB) 'One exact bounded artifact is required.'
 $artifact=$artifacts[0];$path=Join-Path $work ($Name+'.zip')
 $handler=[Net.Http.HttpClientHandler]::new();$handler.AllowAutoRedirect=$false;$client=[Net.Http.HttpClient]::new($handler)
 $client.DefaultRequestHeaders.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$env:GH_TOKEN);$client.DefaultRequestHeaders.UserAgent.ParseAdd('OpenWebPBX-Private-Updater-Qualification')
 try{$response=$client.GetAsync('https://api.github.com/repos/embire2/openwebpbx/actions/artifacts/'+$artifact.id+'/zip').GetAwaiter().GetResult();Check ([int]$response.StatusCode -eq 302) 'Artifact storage redirect is unavailable.';$location=$response.Headers.Location}finally{$client.Dispose();$handler.Dispose()}
 Check ($location.IsAbsoluteUri -and $location.Scheme -eq 'https') 'Artifact storage must use trusted HTTPS.'
 Invoke-WebRequest -Uri $location -MaximumRedirection 0 -OutFile $path
 Check ((Get-Item $path).Length -eq $artifact.size_in_bytes -and (Hash $path) -eq $artifact.digest.Substring(7)) 'The complete Actions artifact digest differs.'
 $directory=Join-Path $work $Name;PrivateDirectory $directory;ExpandSafe $path $directory
 return @{directory=$directory;run=$run;artifact=$artifact}
}
function CheckedProcess([string]$Executable,[string[]]$Arguments,[string]$Label,[string]$WorkingDirectory=$source,[int]$Timeout=2400000){
 $script:qualificationFailedChild=$null
 $start=[Diagnostics.ProcessStartInfo]::new($Executable);$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.WorkingDirectory=$WorkingDirectory
 if($Executable -like '*WindowsPowerShell*'){$start.Environment['PSModulePath']=(Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/Modules')+';'+(Join-Path $env:ProgramFiles 'WindowsPowerShell/Modules')}
 foreach($argument in $Arguments){$start.ArgumentList.Add($argument)}
 $process=[Diagnostics.Process]::Start($start);$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
 # Do not kill an in-flight installer transaction. The ephemeral runner timeout
 # and durable product journal own recovery when it cannot complete in bounds.
 $finished=$process.WaitForExit($Timeout);if(!$finished){$script:qualificationFailedChild=@{caller='CheckedProcess';label=$Label;completion='deadline';exit_code=$null}}
 Check $finished 'A private qualification child exceeded its deadline; do not interrupt its transaction.'
 [IO.File]::WriteAllText((Join-Path $work ($Label+'.out')),$stdout.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText((Join-Path $work ($Label+'.err')),$stderr.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($false))
 $exit=$process.ExitCode;$process.Dispose();if($exit -ne 0){$script:qualificationFailedChild=@{caller='CheckedProcess';label=$Label;completion='exit';exit_code=$exit}};Check ($exit -eq 0) 'A private qualification operation failed; its streams remain private.'
}
function NativeVersions([string]$Directory,[string]$Version){
 $paths=@{'server/OpenWebPbx.Server.dll'='server';'desktop/OpenWebPbx.Desktop.dll'='desktop';'updater/OpenWebPbx.Updater.dll'='updater'};$records=@()
 foreach($path in $paths.Keys){$full=Join-Path $Directory $path;Check ([Reflection.AssemblyName]::GetAssemblyName($full).Version -eq [version]($Version+'.0')) 'The genuine service, desktop and updater assembly versions must match.';$records+=@{path=$path;assembly_version=$Version+'.0';sha256=(Hash $full)}};return $records
}
function StopQualificationIis($Site,$Pool){
 foreach($item in @($Site,$Pool)){
  if(!$item){continue}
  $state=[string]$item.State
  if($state -eq 'Started'){$item.Stop()|Out-Null}elseif($state -notin 'Stopped','Stopping'){throw 'Owned IIS cleanup found an unexpected state.'}
  for($poll=0;$poll -lt 160;$poll++){
   $state=[string]$item.State;if($state -eq 'Stopped'){break}
   if($state -notin 'Started','Stopping'){throw 'Owned IIS cleanup found an unexpected state.'}
   Start-Sleep -Milliseconds 250
  }
  Check ([string]$item.State -eq 'Stopped') 'Owned IIS cleanup did not stop.'
 }
}
function PrepareCanary($Base,$BaseFacts){
 if(!(Get-Variable BaseVersion -ErrorAction SilentlyContinue)){$BaseVersion='1.0.13'}
 if(!(Get-Variable CanaryVersion -ErrorAction SilentlyContinue)){$CanaryVersion='1.0.14'}
 $phaseBefore=$script:phase;$script:phase=('isolated real '+$CanaryVersion+' build')
 $overlay=Join-Path $work 'source-overlay';$native=Join-Path $work 'native14';PrivateDirectory $native
 CheckedProcess 'git.exe' @('fetch','--no-tags','origin',$BaseFacts.source_commit) 'fetch-immutable-source'
 CheckedProcess 'git.exe' @('worktree','add','--detach',$overlay,$BaseFacts.source_commit) 'source-worktree'
 $version=(Get-Content (Join-Path $overlay 'VERSION') -Raw).Trim();Check ($version -eq $BaseVersion) ('The canary must derive from the actual qualified '+$BaseVersion+' source.')
 $files=@(& git.exe -C $overlay ls-files -- platform packaging/updates/release-public.pem VERSION);Check ($LASTEXITCODE -eq 0 -and $files.Count -gt 40) 'The complete native source inventory is required.'
 $inputs=@($files|ForEach-Object {@{path=$_;sha256=(Hash (Join-Path $overlay $_))}});$overlays=@()
 foreach($relative in 'VERSION','platform/Directory.Build.props'){
  $path=Join-Path $overlay $relative;$old=Hash $path;$text=[IO.File]::ReadAllText($path)
  if($relative -eq 'VERSION'){Check ([regex]::Matches($text,[regex]::Escape($BaseVersion)).Count -eq 1) 'The original release version label is ambiguous.';$text=$text.Replace($BaseVersion,$CanaryVersion)}else{Check ([regex]::Matches($text,('<Version>'+[regex]::Escape($BaseVersion)+'</Version>')).Count -eq 1) 'The source version overlay is ambiguous.';$text=$text.Replace(('<Version>'+$BaseVersion+'</Version>'),('<Version>'+$CanaryVersion+'</Version>'))}
  [IO.File]::WriteAllText($path,$text,[Text.UTF8Encoding]::new($false));$overlays+=@{path=$relative;original_sha256=$old;sha256=(Hash $path)}
  $record=Join-Path $native ('overlays/'+$relative);New-Item -ItemType Directory -Force (Split-Path $record -Parent)|Out-Null;Copy-Item -LiteralPath $path -Destination $record
 }
 [IO.File]::WriteAllText((Join-Path $overlay 'global.json'),'{"sdk":{"version":"10.0.401","rollForward":"disable"}}',[Text.UTF8Encoding]::new($false))
 Check ((& dotnet.exe --version).Trim() -eq '10.0.401') 'The pinned .NET SDK is required.'
 foreach($component in 'server','updater'){$project=if($component -eq 'server'){'OpenWebPbx.Server'}else{'OpenWebPbx.Updater'};CheckedProcess 'dotnet.exe' @('publish',('platform/'+$project),'-c','Release','-r','win-x64','--self-contained','true','-o',(Join-Path $native $component)) ($component+'-14-build') $overlay}
 CheckedProcess 'dotnet.exe' @('build','platform/OpenWebPbx.Desktop','-c','Release','-p:Platform=x64','-o',(Join-Path $native 'desktop')) 'desktop-14-build' $overlay
 foreach($project in 'OpenWebPbx.Checks','OpenWebPbx.Updater.Checks'){CheckedProcess 'dotnet.exe' @('run','--project',('platform/'+$project),'-c','Release') ($project+'-checks') $overlay}
 $versions=NativeVersions $native $CanaryVersion
 $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $native 'desktop/OpenWebPbx.Desktop.exe'));$start.UseShellExecute=$false;$start.WorkingDirectory=Join-Path $native 'desktop';$manager=[Diagnostics.Process]::Start($start)
 try{$deadline=[DateTime]::UtcNow.AddSeconds(45);do{Start-Sleep -Milliseconds 500;$manager.Refresh();Check (!$manager.HasExited) 'The real canary manager exited before its startup gate.'}while($manager.MainWindowHandle -eq 0 -and [DateTime]::UtcNow -lt $deadline);Check ($manager.MainWindowHandle -ne 0 -and $manager.Responding -and $manager.MainWindowTitle -eq ('OpenWeb PBX '+$CanaryVersion)) ('The responsive real '+$CanaryVersion+' manager window is required.');$launch=@{process_alive=$true;responsive=$true;window_title=$manager.MainWindowTitle;window_verified=$true;session_id=$manager.SessionId}}finally{if(!$manager.HasExited){$manager.CloseMainWindow()|Out-Null;if(!$manager.WaitForExit(10000)){$manager.Kill()}};$manager.Dispose()}
 foreach($input in $inputs){$expected=if($input.path -in 'VERSION','platform/Directory.Build.props'){($overlays|Where-Object path -eq $input.path).sha256}else{$input.sha256};Check ((Hash (Join-Path $overlay $input.path)) -eq $expected) 'The native build modified an unapproved source input.'}
 $modified=@(& git.exe -C $overlay diff --name-only HEAD);Check (@(Compare-Object ($modified|Sort-Object) @('VERSION','platform/Directory.Build.props')).Count -eq 0) 'Only the two recorded version overlays may change tracked source.'
 WriteJson (Join-Path $native 'source-inputs.json') @{version=$CanaryVersion;source_commit=$BaseFacts.source_commit;source_inputs=$inputs;overlays=$overlays;sdk='10.0.401';preparation_source_commit=$env:GITHUB_SHA;preparation_run_id=$env:GITHUB_RUN_ID;runner_image=$env:ImageVersion}
 WriteJson (Join-Path $native 'verification.json') @{version=$CanaryVersion;assemblies=$versions;manager_startup=$launch;protocol_checks='passed';updater_checks='passed'}
 $lines=@(Get-ChildItem -LiteralPath $native -File -Recurse|Sort-Object FullName|ForEach-Object {('{0}  {1}' -f (Hash $_.FullName),[IO.Path]::GetRelativePath($native,$_.FullName).Replace('\','/'))})
 [IO.File]::WriteAllLines((Join-Path $native 'SHA256SUMS'),$lines,[Text.UTF8Encoding]::new($false))
 Check (!(Test-Path -LiteralPath $output)) 'An old canary export must not be reused.'
 CheckedProcess 'python.exe' @((Join-Path $PSScriptRoot 'windows-canary-preparation.py'),'--base-archive',$Base,'--base-facts',(Join-Path $work 'baseline-facts.json'),'--native-root',$native,'--output-dir',$output,'--base-version',$BaseVersion,'--target-version',$CanaryVersion) 'prepare-audited-canary'
 $facts.gates.canary_build='passed';$facts.checks+=('Genuine '+$CanaryVersion+' server/manager/updater builds, responsive manager, exactly two source overlays, complete normal/fault manifest and source/hash evidence');$facts.state='prepared';$script:phase=$phaseBefore
}
function Fixture([string]$Action){
 $script:qualificationFailedChild=$null
 $start=[Diagnostics.ProcessStartInfo]::new("$root\php\php.exe");$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WorkingDirectory="$root\web";$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 foreach($argument in @((Join-Path $PSScriptRoot 'windows-updater-fixture.php'),$Action,$inputFile)){$start.ArgumentList.Add($argument)}
 $process=[Diagnostics.Process]::Start($start);$out=$process.StandardOutput.ReadToEndAsync();$err=$process.StandardError.ReadToEndAsync();$finished=$process.WaitForExit(90000);if(!$finished){$script:qualificationFailedChild=@{caller='Fixture';label=('fixture-'+$Action);completion='deadline';exit_code=$null}};Check $finished 'The private scoped audit exceeded its deadline.';$text=$out.GetAwaiter().GetResult();[IO.File]::WriteAllText((Join-Path $work ($Action+'-private.err')),$err.GetAwaiter().GetResult());$exit=$process.ExitCode;$process.Dispose();if($exit -ne 0){$script:qualificationFailedChild=@{caller='Fixture';label=('fixture-'+$Action);completion='exit';exit_code=$exit}};Check ($exit -eq 0) 'The private scoped audit failed.';return $text|ConvertFrom-Json
}
function Python([string]$Action){CheckedProcess "$root\backup-runtime\python.exe" @('-I','-B',(Join-Path $PSScriptRoot 'windows-updater-fixture.py'),'--input',$inputFile,'--action',$Action) ('python-'+$Action)}
function InitializeQualificationBackupWorker([string]$Root,[string]$StateRoot,[string]$PackageRoot){
 # Let the real normal SYSTEM task initialize its own persistent runtime files
 # before every acceptance baseline. Never synthesize or exclude those files.
 . (Join-Path $PackageRoot 'Restore-Gates.ps1')
 $unheld={
  Assert-OpenWebUpgradeAllowed -StateRoot $StateRoot
  Check (!(Test-Path -LiteralPath (Join-Path $StateRoot 'updates/maintenance'))) 'Backup warm-up refuses an active maintenance marker.'
 }
 & $unheld
 $ancestor=[IO.Path]::GetFullPath($StateRoot)
 while($ancestor){$item=Get-Item -LiteralPath $ancestor -Force;Check ($item.PSIsContainer -and !($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) 'Backup warm-up refuses linked state storage.';$ancestor=[IO.Path]::GetDirectoryName($ancestor)}
 $python=Join-Path $Root 'backup-runtime/python.exe';$scriptPath=Join-Path $Root 'tools/backups.py';$arguments='-I "'+$scriptPath+'" worker'
 foreach($pair in @(@($python,(Join-Path $PackageRoot 'backup-runtime/python.exe')),@($scriptPath,(Join-Path $PackageRoot 'backups.py')))){
  foreach($path in $pair){$item=Get-Item -LiteralPath $path -Force;Check (!$item.PSIsContainer -and !($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) 'Backup warm-up requires the exact ordinary installed runtime.'}
  Check ((Hash $pair[0]) -ceq (Hash $pair[1])) 'Backup warm-up refuses a changed installed runtime.'
 }
 $identity={param($Task)
  Check ($Task.TaskName -eq 'OpenWebPBX-Backups' -and $Task.TaskPath -eq '\' -and $Task.Settings.Enabled -and [string]$Task.Settings.MultipleInstances -eq 'IgnoreNew' -and [string]$Task.Principal.UserId -in 'SYSTEM','S-1-5-18','NT AUTHORITY\SYSTEM' -and [string]$Task.Principal.LogonType -eq 'ServiceAccount' -and [string]$Task.Principal.RunLevel -eq 'Highest' -and @($Task.Actions).Count -eq 1 -and $Task.Actions[0].Execute -eq $python -and $Task.Actions[0].Arguments -eq $arguments -and $Task.Actions[0].WorkingDirectory -eq (Join-Path $Root 'tools') -and [string]$Task.State -in 'Ready','Running','Queued') 'Backup warm-up refuses an unexpected normal SYSTEM task.'
 }
 $task=Get-ScheduledTask -TaskName OpenWebPBX-Backups -ErrorAction Stop;& $identity $task
 $definition=(TaskSnapshot)['OpenWebPBX-Backups']
 Check ($definition.exists -eq $true) 'The normal backup task definition is unavailable.'
 $remaining=120
 while([string]$task.State -in 'Running','Queued'){
  Check ($remaining -gt 0) 'The normal backup task did not become idle before the baseline.'
  Start-Sleep -Milliseconds 500;$remaining--;& $unheld
  $task=Get-ScheduledTask -TaskName OpenWebPBX-Backups -ErrorAction Stop;& $identity $task
 }
 Check ($remaining -gt 0) 'The normal backup task did not become idle before the baseline.'
 $prior=Get-ScheduledTaskInfo -TaskName OpenWebPBX-Backups -ErrorAction Stop
 Check ($prior.LastRunTime -is [DateTime]) 'The normal backup task execution time is unavailable.'
 # Scheduler records may have whole-second precision. Start only after that
 # recorded second, retaining the same bounded budget and strict fresh-run test.
 while((Get-Date) -le $prior.LastRunTime.AddSeconds(1)){
  Check ($remaining -gt 0) 'The normal backup task execution clock did not advance before the baseline.'
  Start-Sleep -Milliseconds 500;$remaining--;& $unheld
 }
 Check ($remaining -gt 0) 'The normal backup task did not become ready before the baseline deadline.'
 Start-ScheduledTask -TaskName OpenWebPBX-Backups -ErrorAction Stop
 $completed=$false
 do{
  & $unheld
  $task=Get-ScheduledTask -TaskName OpenWebPBX-Backups -ErrorAction Stop;& $identity $task
  $info=Get-ScheduledTaskInfo -TaskName OpenWebPBX-Backups -ErrorAction Stop
  Check ($info.LastRunTime -is [DateTime]) 'The normal backup task execution time is unavailable.'
  if($info.LastRunTime -gt $prior.LastRunTime -and [string]$task.State -eq 'Ready'){
   Check ($info.LastTaskResult -eq 0) 'The actual normal backup task did not finish successfully.'
   $completed=$true;break
  }
  $remaining--;if($remaining -gt 0){Start-Sleep -Milliseconds 500}
 }while($remaining -gt 0)
 Check $completed 'The actual normal backup task did not finish before the baseline deadline.'
 & $unheld
 $directory=Get-Item -LiteralPath (Join-Path $StateRoot 'automatic-backups') -Force
 $worker=Get-Item -LiteralPath (Join-Path $StateRoot 'automatic-backups/worker.lock') -Force
 Check ($directory.PSIsContainer -and !($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -and !$worker.PSIsContainer -and !($worker.Attributes -band [IO.FileAttributes]::ReparsePoint)) 'The actual backup worker did not initialize its ordinary runtime lock.'
 $after=(TaskSnapshot)['OpenWebPBX-Backups']
 foreach($field in 'exists','enabled','xml','acl','security'){Check ($after[$field] -ceq $definition[$field]) 'Backup warm-up changed the normal task definition or security.'}
}
function DatabaseSnapshot([string]$Label){$settings.snapshot_label=$Label;WriteJson $inputFile $settings;Fixture 'snapshot'|Out-Null;return Get-Content (Join-Path (Split-Path $inputFile -Parent) ($Label+'-database.json')) -Raw|ConvertFrom-Json -AsHashtable}
function FileSnapshot([switch]$Protected,[ValidateSet('unobserved','before_fault_full','before_fault_protected','after_fault_full','after_normal_protected')][string]$Stage='unobserved'){
 $script:qualificationFailedHash=$null
 # The canary is the exact baseline payload with only native version overlays.
 # Its PHP vendor files therefore remain exact on success as well as rollback.
 $directories=@("$root\php",$configuration,"$state\storage","$state\mobile-notifications","$state\mail","$state\phone-tls","$state\public-access","$state\meet-proxy","$state\tenant-domains","$state\automatic-backups","$state\backup-restore","$state\backup-control","$state\backup-downloads","$state\codec-compiler-cache","$state\codec-build","$state\phone-health-runtime","$state\stun-setup","$state\dtls-setup")
 if(!$Protected){$directories+=@("$root\web","$root\server","$root\desktop","$root\tools","$root\backup-runtime","$root\acme","$root\updater\slots","$engine\conf","$engine\scripts","$engine\mod","$engine\sounds")}
 $entries=@{}
 foreach($parent in $root,"$root\updater",$state,$engine,"$engine\cert"){
  if(!(Test-Path -LiteralPath $parent)){Check ($parent -ceq "$engine\cert") 'A snapshot parent directory is missing.';continue}
  $item=Get-Item -LiteralPath $parent -Force
  Check ($item.PSIsContainer -and !($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) 'A snapshot parent must remain an ordinary directory.'
  $entries[$parent]=@{directory=$true;acl=(Get-Acl -LiteralPath $parent).Sddl}
 }
 foreach($directory in $directories){
  if(!(Test-Path -LiteralPath $directory)){continue}
  $folder=Get-Item -LiteralPath $directory -Force
  Check ($folder.PSIsContainer -and !($folder.Attributes -band [IO.FileAttributes]::ReparsePoint)) 'A snapshot tree must remain an ordinary directory.'
  foreach($item in @($folder)+@(Get-ChildItem -LiteralPath $directory -Recurse -Force)){
   Check (!($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) 'A linked fixture cannot be audited.'
   $record=@{directory=[bool]$item.PSIsContainer;acl=(Get-Acl -LiteralPath $item.FullName).Sddl}
   if(!$item.PSIsContainer){$record.sha256=SnapshotHash $item.FullName $Stage;$record.bytes=$item.Length}
   $entries[$item.FullName]=$record
  }
 }
 $paths=@("$state\runtime.json","$state\phone-tls.json","$state\phone-health-instance.json","$state\stun.json","$state\native-engine.json","$state\local-codec.json","$state\meet-ca.pem","$state\meet-proxy.json","$engine\cert\dtls-srtp.pem","$engine\libbcg729.dll")
 if(!$Protected){$paths+=@("$state\installation.json","$state\updater-install.json")}
 foreach($path in $paths){if(Test-Path -LiteralPath $path){
  $item=Get-Item -LiteralPath $path -Force
  Check (!$item.PSIsContainer -and !($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) 'A private audited file must remain ordinary.'
  $entries[$path]=@{directory=$false;acl=(Get-Acl -LiteralPath $path).Sddl;sha256=(SnapshotHash $path $Stage);bytes=$item.Length}
 }}
 return $entries
}
function TaskSnapshot {
 $result=@{};$scheduler=New-Object -ComObject Schedule.Service;$scheduler.Connect()
 # The owned interactive manager re-registers its task when each new window
 # loads. Its exact user/action/security contract is checked separately; static
 # service tasks must preserve their complete XML/COM/file security inventory.
 $names=@('OpenWebPBX-Backups','OpenWebPBX-Cleanup','OpenWebPBX-Updater-Restart','OpenWebPBX Outgoing Mail','OpenWebPBX-TenantDomains','OpenWebPBX-PhoneHealth','OpenWebPBX Certificate Renewal','OpenWebPBX Pending Phone Certificate')
 foreach($name in $names){
  $task=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue;if(!$task){$result[$name]=@{exists=$false};continue};$xml=[xml](Export-ScheduledTask -TaskName $name);$xml.PreserveWhitespace=$false
  $result[$name]=@{exists=$true;enabled=[bool]$task.Settings.Enabled;xml=$xml.OuterXml;acl=(Get-Acl -LiteralPath (Join-Path $env:SystemRoot ('System32/Tasks/'+$name))).Sddl;security=$scheduler.GetFolder('\').GetTask($name).GetSecurityDescriptor(7)}
 };return $result
}
function ManagerTaskValid {
 $task=Get-ScheduledTask -TaskName $managerName -ErrorAction SilentlyContinue;if(!$task){return $false}
 $sid=if($task.Principal.UserId -like 'S-1-*'){$task.Principal.UserId}else{([Security.Principal.NTAccount]::new($task.Principal.UserId)).Translate([Security.Principal.SecurityIdentifier]).Value}
 return ($task.TaskPath -eq '\' -and $sid -eq $managerSid -and [string]$task.Principal.LogonType -eq 'Interactive' -and [string]$task.Principal.RunLevel -eq 'Limited' -and @($task.Actions).Count -eq 1 -and $task.Actions.Execute -eq "$root\desktop\OpenWebPbx.Desktop.exe" -and !$task.Actions.Arguments -and $task.Actions.WorkingDirectory -eq "$root\desktop" -and $task.Settings.Enabled -and [string]$task.Settings.MultipleInstances -eq 'IgnoreNew' -and $task.Settings.ExecutionTimeLimit -eq 'PT0S' -and $task.Description -eq 'Reopen the OpenWeb PBX manager for this user after a verified update.')
}
function OwnedManagers {
 $result=@()
 foreach($record in @(Get-CimInstance Win32_Process -Filter "Name='OpenWebPbx.Desktop.exe'")){
  $owner=Invoke-CimMethod -InputObject $record -MethodName GetOwnerSid
  if($record.ExecutablePath -eq "$root\desktop\OpenWebPbx.Desktop.exe" -and $record.SessionId -eq $managerSession -and $owner.ReturnValue -eq 0 -and $owner.Sid -eq $managerSid){$process=Get-Process -Id $record.ProcessId -ErrorAction SilentlyContinue;if($process -and $process.StartTime.ToUniversalTime() -ge $managerStarted){$result+=@($process)}}
 };return $result
}
function WaitManager([string]$Version,[int]$PreviousPid=0,[DateTime]$NotBefore=[DateTime]::MinValue){
 $deadline=[DateTime]::UtcNow.AddSeconds(120)
 do{foreach($process in @(OwnedManagers)){$process.Refresh();if($process.Id -ne $PreviousPid -and $process.StartTime.ToUniversalTime() -ge $NotBefore -and $process.MainWindowHandle -ne 0 -and $process.Responding -and $process.MainWindowTitle -eq ('OpenWeb PBX '+$Version) -and (ManagerTaskValid)){return $process}};Start-Sleep -Milliseconds 500}while([DateTime]::UtcNow -lt $deadline)
 throw 'The genuine installed manager did not automatically show its responsive versioned window in the original user/session.'
}
function BeginManager {
 if(!(Get-Variable BaseVersion -ErrorAction SilentlyContinue)){$BaseVersion='1.0.13'}
 $script:managerSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;$script:managerSession=[Diagnostics.Process]::GetCurrentProcess().SessionId;$script:managerName='OpenWebPBX-Manager-'+$managerSid
 Check ($managerSession -gt 0 -and [Environment]::UserInteractive) 'Interactive manager reopen remains unqualified when the disposable runner has no real user session.'
 Check (@(Get-CimInstance Win32_Process -Filter "Name='OpenWebPbx.Desktop.exe'").Count -eq 0 -and !(Get-ScheduledTask -TaskName $managerName -ErrorAction SilentlyContinue)) 'Never reuse or close a foreign/pre-existing manager or task.'
 $script:managerOwned=$true;$script:managerStarted=[DateTime]::UtcNow;$start=[Diagnostics.ProcessStartInfo]::new("$root\desktop\OpenWebPbx.Desktop.exe");$start.UseShellExecute=$false;$start.WorkingDirectory="$root\desktop";$start.Environment['PSModulePath']=(Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/Modules')+';'+(Join-Path $env:ProgramFiles 'WindowsPowerShell/Modules');$process=[Diagnostics.Process]::Start($start);$process.Dispose()
 return WaitManager $BaseVersion
}
function OriginalProcessProofSource([string]$Path){
 # Import only the independently Windows-qualified proof function, never the
 # upgrade hook's entrypoint or any service/fixture operation.
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
 Check (@($errors).Count -eq 0) 'The retained-process proof source did not parse.'
 $nodes=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'GetManagerOriginalExitProof'},$true))
 Check ($nodes.Count -eq 1) 'Exactly one retained-process proof is required.'
 return [ScriptBlock]::Create($nodes[0].Extent.Text)
}
function RetainQualificationProcess([Diagnostics.Process]$Process,[int]$ExpectedPid,[string]$ExpectedPath,[string]$ExpectedSid,[int]$ExpectedSession,[DateTime]$NotBefore){
 $retained=$false
 try{
  $handle=$Process.Handle;$start=$Process.StartTime.ToUniversalTime()
  $records=@(Get-CimInstance Win32_Process -Filter ('ProcessId='+$ExpectedPid));$owner=if($records.Count -eq 1){Invoke-CimMethod -InputObject $records[0] -MethodName GetOwnerSid}else{$null}
  $verified=($handle -ne [IntPtr]::Zero -and !$Process.HasExited -and $Process.Id -eq $ExpectedPid -and $records.Count -eq 1 -and $records[0].ExecutablePath -eq $ExpectedPath -and $Process.Path -eq $ExpectedPath -and $owner.ReturnValue -eq 0 -and $owner.Sid -eq $ExpectedSid -and $records[0].SessionId -eq $ExpectedSession -and $Process.SessionId -eq $ExpectedSession -and $start -ge $NotBefore)
  Check $verified 'The original qualification process identity is unavailable before the request.'
  $held=@{process=$Process;handle=$handle;pid=[int]$Process.Id;start_ticks=[long]$start.Ticks;identity_verified=[bool]$verified}
  $script:retainedProcesses.Add($Process);$retained=$true
  return $held
 }finally{if(!$retained -and $Process){$Process.Dispose()}}
}
function AssertOriginalProcessState($Held,[int]$ExpectedPid,[bool]$Exited,[string]$Message){
 $proof=GetManagerOriginalExitProof $Held $ExpectedPid
 Check ($proof.manager_original_handle_pinned -and $proof.manager_original_identity_verified -and $proof.manager_original_exit_observed -and $proof.manager_original_has_exited -eq $Exited) $Message
}
function ManagerReopened([string]$Version,$Held,[DateTime]$NotBefore){
 $PreviousPid=[int]$Held.pid
 AssertOriginalProcessState $Held $PreviousPid $true 'The updater did not close the original owned installed manager.'
 $journal=Get-Content "$state\updates\install-journal.json" -Raw|ConvertFrom-Json;Check (@($journal.manager_tasks) -contains $managerName) 'The genuine product transaction must record the actual interactive restart task.'
 return WaitManager $Version $PreviousPid $NotBefore
}
function EqualTaskSnapshots($Before,$After,[string]$Message){
 # Preserve the raw metadata and exact file ACLs; only the Scheduler descriptor
 # uses the same narrowly scoped product comparator as actual task recovery.
 Check ($Before -is [Collections.IDictionary] -and $After -is [Collections.IDictionary]) $Message
 $left=@{};$right=@{}
 foreach($pair in @(@{source=$Before;target=$left},@{source=$After;target=$right})){
  foreach($name in $pair.source.Keys){
   Check ($pair.source[$name] -is [Collections.IDictionary]) $Message
   $copy=@{};foreach($key in $pair.source[$name].Keys){$copy[$key]=$pair.source[$name][$key]};$pair.target[$name]=$copy
  }
 }
 foreach($name in $Before.Keys){
  if($Before[$name].Keys -ccontains 'security'){
   Check ($After.Keys -ccontains $name) $Message
   Check ($After[$name].Keys -ccontains 'security' -and $Before[$name].security -is [string] -and $After[$name].security -is [string]) $Message
   Check (Test-OpenWebTaskSecurityEquivalent $Before[$name].security $After[$name].security) $Message
   $left[$name].Remove('security');$right[$name].Remove('security')
  }
 }
 Equal $left $right $Message
}
function QualificationComparisonFields($Record){
 $result=$Record.comparison_result;$stage=$Record.comparison_stage
 if($result -isnot [string] -or $result -cnotin 'equal','different','error','unavailable' -or $stage -isnot [string]){return $null}
 $safe=@{comparison_result=$result;comparison_stage=$stage}
 if($result -ceq 'unavailable'){if($stage -cnotin 'launch','report_validation'){return $null};return $safe}
 if($result -ceq 'error'){
  if($stage -cnotin 'usage','read_before','parse_before','read_after','parse_after','compare' -or $Record.comparison_error_type -isnot [string] -or $Record.comparison_error_type -cnotin 'OSError','FileNotFoundError','PermissionError','UnicodeDecodeError','JSONDecodeError','RecursionError','ValueError','TypeError','ExternalError'){return $null}
  $safe.comparison_error_type=$Record.comparison_error_type;return $safe
 }
 if($stage -cne 'compare'){return $null};if($result -ceq 'equal'){return $safe}
 $tables=@('v_vars','v_default_settings','v_domain_settings','v_domains','v_users','v_extensions','v_gateways','v_dialplans','v_dialplan_details','v_sip_profiles','v_sip_profile_settings','v_permissions','v_groups','v_group_permissions','v_user_groups','v_menu','v_menu_items','v_pbx_tenants','v_pbx_tenant_users','v_pbx_services','v_pbx_templates','v_pbx_service_assignments','v_pbx_setup_templates','v_pbx_restore','v_pbx_sip_domains')
 $columns=@(foreach($table in $tables){foreach($column in 'insert_date','update_date','insert_user','update_user'){$table+'.'+$column};if($table -ceq 'v_vars'){foreach($column in 'var_uuid','var_category','var_name','var_value','var_order','var_enabled','var_description'){$table+'.'+$column}};if($table -ceq 'v_default_settings'){foreach($column in 'default_setting_uuid','default_setting_category','default_setting_subcategory','default_setting_name','default_setting_value','default_setting_order','default_setting_enabled','default_setting_description'){$table+'.'+$column}}})
 $arrays=@{comparison_changed_sections=@('identity','roles','memberships','schema','tables','columns','values','table_count');comparison_critical_tables=$tables;comparison_critical_columns=$columns}
 foreach($field in $arrays.Keys){
  $values=$Record.$field;if($values -isnot [Array] -or $values.Count -gt $arrays[$field].Count){return $null}
  $seen=@();foreach($value in $values){if($value -isnot [string] -or $value -cnotin $arrays[$field] -or $value -cin $seen){return $null};$seen+=,$value}
  $safe[$field]=@($seen)
 }
 foreach($field in 'comparison_unknown_section_count','comparison_changed_values_table_count','comparison_other_table_count','comparison_changed_column_count','comparison_other_column_count'){
  $value=$Record.$field;if(($value -isnot [int] -and $value -isnot [long]) -or $value -lt 0 -or $value -gt 100000){return $null};$safe[$field]=[int]$value
 }
 foreach($field in 'comparison_values_observed','comparison_counts_capped','comparison_columns_observed','comparison_column_counts_capped'){
  if($Record.$field -isnot [bool]){return $null};$safe[$field]=$Record.$field
 }
 $fileFields=@('comparison_files_observed','comparison_changed_file_entry_count','comparison_file_counts_capped','comparison_file_field_counts','comparison_file_category_counts','comparison_file_category_field_counts','comparison_known_file_field_counts','comparison_unknown_file_entry_count','comparison_config_scope_field_counts','comparison_file_category_added_kind_counts','comparison_config_scope_removed_kind_counts')
 $names=if($Record -is [Collections.IDictionary]){@($Record.Keys)}else{@($Record.PSObject.Properties.Name)}
 $present=@($fileFields|Where-Object {$names -ccontains $_})
 if($present.Count){
  if($present.Count -ne $fileFields.Count -or $Record.comparison_files_observed -isnot [bool] -or $Record.comparison_file_counts_capped -isnot [bool]){return $null}
  $count=$Record.comparison_changed_file_entry_count
  if(($count -isnot [int] -and $count -isnot [long]) -or $count -lt 0 -or $count -gt 100000){return $null}
  $safe.comparison_files_observed=$Record.comparison_files_observed;$safe.comparison_changed_file_entry_count=[int]$count;$safe.comparison_file_counts_capped=$Record.comparison_file_counts_capped
  $maps=@{comparison_file_field_counts=@('acl','sha256','bytes','directory','added','removed','shape','other');comparison_file_category_counts=@('web','server','desktop','tools','updater','config','notifications','media','native','backup_runtime','acme_runtime','other')}
  foreach($field in $maps.Keys){
   $map=$Record.$field
   if($map -is [Collections.IDictionary]){$keys=@($map.Keys)}elseif($map -is [pscustomobject]){$keys=@($map.PSObject.Properties|ForEach-Object {$_.Name})}else{return $null}
   if($keys.Count -gt $maps[$field].Count){return $null};$copy=@{}
   foreach($key in $keys){$value=$map.$key;if($key -isnot [string] -or $key -cnotin $maps[$field] -or ($value -isnot [int] -and $value -isnot [long]) -or $value -lt 0 -or $value -gt 100000){return $null};$copy[$key]=[int]$value}
   $safe[$field]=$copy
  }
  # The exact Python producer emits all four nested diagnostics together.
  # Validate every fixed label/count; classification never changes equality.
  $count=$Record.comparison_unknown_file_entry_count
  if(($count -isnot [int] -and $count -isnot [long]) -or $count -lt 0 -or $count -gt 100000){return $null}
  $safe.comparison_unknown_file_entry_count=[int]$count
  $labels=@('installation','runtime','updater_install','native_engine','local_codec','phone_tls_metadata','storage_root','stock_music_root','stock_music_readme','stock_music_manifest','stock_sounds_root','stock_sounds_openwebpbx')
  $labels+=@('fusionpbx_root','fusionpbx_config','fusionpbx_template_key','automatic_backups_worker_lock','phone_tls_root','public_access_root','automatic_backups_root','backup_restore_root','backup_control_root','backup_downloads_root','codec_compiler_cache_root','codec_build_root')
  $labels+=@('program_root','php_ini','php_openssl','php_cacert','notification_store','notification_config','notification_lock')
  foreach($rate in 8000,16000,32000,48000){$labels+=@(('stock_music_'+$rate+'_dir'),('stock_music_'+$rate+'_track'))}
  $nested=@{comparison_file_category_field_counts=@('web','server','desktop','tools','updater','config','notifications','media','native','backup_runtime','acme_runtime','other');comparison_known_file_field_counts=$labels;comparison_config_scope_field_counts=@('fusionpbx','phone_tls','public_access','automatic_backups','backup_restore','backup_control','backup_downloads','codec_compiler_cache','codec_build');comparison_file_category_added_kind_counts=@('web','server','desktop','tools','updater','config','notifications','media','native','backup_runtime','acme_runtime','other');comparison_config_scope_removed_kind_counts=@('fusionpbx','phone_tls','public_access','automatic_backups','backup_restore','backup_control','backup_downloads','codec_compiler_cache','codec_build')}
  foreach($field in $nested.Keys){
   $map=$Record.$field
   if($map -is [Collections.IDictionary]){$keys=@($map.Keys)}elseif($map -is [pscustomobject]){$keys=@($map.PSObject.Properties|ForEach-Object {$_.Name})}else{return $null}
   if($keys.Count -gt $nested[$field].Count){return $null};$copy=@{}
   foreach($key in $keys){
    if($key -isnot [string] -or $key -cnotin $nested[$field]){return $null};$row=$map.$key
    if($row -is [Collections.IDictionary]){$columns=@($row.Keys)}elseif($row -is [pscustomobject]){$columns=@($row.PSObject.Properties|ForEach-Object {$_.Name})}else{return $null}
    $allowedColumns=if($field -ceq 'comparison_file_category_added_kind_counts'){@('python_bytecode','dll','pyd','other_file','python_cache_directory','other_directory','shape')}elseif($field -ceq 'comparison_config_scope_removed_kind_counts'){@('temporary_control_request_json','other_file','directory','shape')}else{@('acl','sha256','bytes','directory','added','removed','shape','other')}
    if($columns.Count -gt $allowedColumns.Count){return $null};$values=@{}
    foreach($column in $columns){
     $value=$row.$column
     if($column -isnot [string] -or $column -cnotin $allowedColumns -or ($value -isnot [int] -and $value -isnot [long]) -or $value -lt 0 -or $value -gt 100000){return $null}
     $values[$column]=[int]$value
    }
    $copy[$key]=$values
   }
   $safe[$field]=$copy
  }
 }
 return $safe
}
function QualificationComparisonDetails($Record){
 return QualificationComparisonFields $Record
}
function QualificationFileCaptureFields($Record){
 if($Record -isnot [Collections.IDictionary] -or $Record.Count -ne 2 -or $Record.state -isnot [string] -or $Record.state -cnotin 'verified','unavailable' -or $Record.paths -isnot [Collections.IDictionary]){return $null}
 $labels=@('installation','runtime','updater_install','native_engine','local_codec','phone_tls_metadata','fusionpbx_root','fusionpbx_config','fusionpbx_template_key','automatic_backups_worker_lock','phone_tls_root','public_access_root','automatic_backups_root','backup_restore_root','backup_control_root','backup_downloads_root','codec_compiler_cache_root','codec_build_root')
 if(($Record.state -ceq 'unavailable' -and $Record.paths.Count) -or ($Record.state -ceq 'verified' -and $Record.paths.Count -ne $labels.Count)){return $null}
 $paths=@{}
 foreach($label in $Record.paths.Keys){
  $row=$Record.paths[$label]
  if($label -isnot [string] -or $label -cnotin $labels -or $row -isnot [Collections.IDictionary] -or $row.Count -ne 3 -or $row.before_present -isnot [bool] -or $row.after_present -isnot [bool] -or $row.support_capture -isnot [string] -or $row.support_capture -cnotin 'present','absent','unobserved'){return $null}
  $paths[$label]=@{before_present=$row.before_present;after_present=$row.after_present;support_capture=$row.support_capture}
 }
 return @{state=$Record.state;paths=$paths}
}
function QualificationFileCapture($Before,$After,[string]$StateRoot,[string]$ConfigurationRoot){
 if(!(Get-Variable BaseVersion -ErrorAction SilentlyContinue)){$BaseVersion='1.0.13'}
 if(!(Get-Variable CanaryVersion -ErrorAction SilentlyContinue)){$CanaryVersion='1.0.14'}
 # Failure-only, read-only observation of a sealed, quiesced support inventory.
 # An online configuration copy is not claimed as a quiesced support capture.
 $unavailable=@{state='unavailable';paths=@{}}
 try{
  function NoCaptureLinks([string]$Path){
   for($current=[IO.Path]::GetFullPath($Path);$current;$current=[IO.Path]::GetDirectoryName($current)){
    $item=Get-Item -LiteralPath $current -Force -ErrorAction Stop
    if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Capture observation unavailable.'}
   }
  }
  function ReadCapture([string]$Path,[int]$Maximum){
   NoCaptureLinks $Path;$item=Get-Item -LiteralPath $Path -Force
   if($item.PSIsContainer -or $item.Length -gt $Maximum){throw 'Capture observation unavailable.'}
   $stream=[IO.File]::Open($Path,'Open','Read',([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete));$memory=[IO.MemoryStream]::new()
   try{$buffer=[byte[]]::new(65536);while(($count=$stream.Read($buffer,0,[Math]::Min($buffer.Length,$Maximum+1-$memory.Length))) -gt 0){$memory.Write($buffer,0,$count);if($memory.Length -gt $Maximum){throw 'Capture observation unavailable.'}};$bytes=$memory.ToArray()}finally{$stream.Dispose();$memory.Dispose()}
   $text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes).TrimStart([char]0xfeff)
   return @{bytes=$bytes;value=($text|ConvertFrom-Json -AsHashtable -NoEnumerate)}
  }
  function CaptureHash([byte[]]$Bytes){return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()}
  function CaptureEntry($Map,[string]$Path){
   if($Map -isnot [Collections.IDictionary]){throw 'Capture observation unavailable.'}
   foreach($key in $Map.Keys){if($key -is [string] -and $key.Replace('\','/').Equals($Path.Replace('\','/'),[StringComparison]::OrdinalIgnoreCase)){return @{found=$true;value=$Map[$key]}}}
   return @{found=$false;value=$null}
  }
  if($Before -isnot [Collections.IDictionary] -or $After -isnot [Collections.IDictionary]){throw 'Capture observation unavailable.'}
  $journalPath=Join-Path $StateRoot 'updates/install-journal.json';$journal=ReadCapture $journalPath 65536;$j=$journal.value
  if(($j.schema -isnot [int] -and $j.schema -isnot [long]) -or $j.schema -ne 1 -or $j.state -cne 'rolled_back' -or $j.version -cne $CanaryVersion -or $j.previous_version -cne $BaseVersion -or $j.operator_rollback -isnot [bool] -or $j.operator_rollback -or $j.backup_path -isnot [string]){throw 'Capture observation unavailable.'}
  $backup=[IO.Path]::GetFullPath($j.backup_path);$name=[IO.Path]::GetFileName($backup)
  if($name -cnotmatch '^[0-9]{8}-[0-9]{6}-[a-f0-9]{8}$' -or !$backup.Equals([IO.Path]::GetFullPath((Join-Path (Join-Path $StateRoot 'backups') $name)),[StringComparison]::OrdinalIgnoreCase)){throw 'Capture observation unavailable.'}
  $complete=ReadCapture (Join-Path $backup 'complete.json') 65536;$manifest=ReadCapture (Join-Path $backup 'backup-manifest.json') 8388608
  if($complete.value.version -cne $BaseVersion -or $complete.value.integrity_sha256 -isnot [string] -or $complete.value.integrity_sha256 -cnotmatch '^[a-f0-9]{64}$' -or (CaptureHash $manifest.bytes) -cne $complete.value.integrity_sha256 -or ($manifest.value.schema -isnot [int] -and $manifest.value.schema -isnot [long]) -or $manifest.value.schema -ne 1 -or $manifest.value.files -isnot [Collections.IDictionary]){throw 'Capture observation unavailable.'}
  $support=ReadCapture (Join-Path $backup 'support-state.json') 16777216
  if($manifest.value.files['support-state.json'] -isnot [string] -or $manifest.value.files['support-state.json'] -cnotmatch '^[a-f0-9]{64}$' -or (CaptureHash $support.bytes) -cne $manifest.value.files['support-state.json'] -or ($support.value.schema -isnot [int] -and $support.value.schema -isnot [long]) -or $support.value.schema -ne 1){throw 'Capture observation unavailable.'}
  $record=$support.value
  foreach($field in 'Acls','Files','Directories'){if($record[$field] -isnot [Collections.IDictionary] -or $record[$field].Count -gt 100000){throw 'Capture observation unavailable.'}}
  $selected=@{}
  foreach($pair in @(@('installation','installation'),@('runtime','runtime'),@('updater-install','updater_install'),@('native-engine','native_engine'),@('local-codec','local_codec'),@('phone-tls','phone_tls_metadata'))){$selected[$pair[1]]=@{path=(Join-Path $StateRoot ($pair[0]+'.json'));directory=$null}}
  foreach($directory in 'phone-tls','public-access','automatic-backups','backup-restore','backup-control','backup-downloads','codec-compiler-cache','codec-build'){$selected[$directory.Replace('-','_')+'_root']=@{path=(Join-Path $StateRoot $directory);directory=$directory}}
  $selected.automatic_backups_worker_lock=@{path=(Join-Path $StateRoot 'automatic-backups/worker.lock');directory='automatic-backups'}
  $selected.fusionpbx_root=@{path=$ConfigurationRoot;directory=$null};$selected.fusionpbx_config=@{path=(Join-Path $ConfigurationRoot 'config.conf');directory=$null};$selected.fusionpbx_template_key=@{path=(Join-Path $ConfigurationRoot 'openweb-template.key');directory=$null}
  $paths=@{}
  foreach($label in $selected.Keys){
   $entry=$selected[$label];$presence='unobserved';$file=CaptureEntry $record.Files $entry.path
   if($file.found){if($file.value.Exists -isnot [bool]){throw 'Capture observation unavailable.'};$presence=if($file.value.Exists){'present'}else{'absent'}}
   elseif($entry.directory -and $record.Directories.Contains($entry.directory)){
    $dir=$record.Directories[$entry.directory]
    if($dir.Exists -isnot [bool] -or $dir.Path -isnot [string] -or !$dir.Path.Replace('\','/').Equals((Join-Path $StateRoot $entry.directory).Replace('\','/'),[StringComparison]::OrdinalIgnoreCase)){throw 'Capture observation unavailable.'}
    $presence=if(!$dir.Exists){'absent'}elseif($entry.path -eq $dir.Path -or (CaptureEntry $record.Acls $entry.path).found){'present'}else{'absent'}
   }
   $paths[$label]=@{before_present=(CaptureEntry $Before $entry.path).found;after_present=(CaptureEntry $After $entry.path).found;support_capture=$presence}
  }
  if((CaptureHash (ReadCapture $journalPath 65536).bytes) -cne (CaptureHash $journal.bytes)){throw 'Capture observation unavailable.'}
  return QualificationFileCaptureFields @{state='verified';paths=$paths}
 }catch{return $unavailable}
}
function Equal($Before,$After,[string]$Label){
 $script:qualificationComparisonFailure=$null
 $a=Join-Path $work ($Label+'-before.json');$b=Join-Path $work ($Label+'-after.json');WriteJson $a $Before;WriteJson $b $After
 try{CheckedProcess "$root\backup-runtime\python.exe" @('-I','-B',(Join-Path $PSScriptRoot 'windows-compare-json.py'),$a,$b) ('compare-'+$Label)}catch{
  # The exact predicate still owns refusal. Read only its bounded machine report;
  # private snapshots, arbitrary keys/values and error streams are never exported.
  $report=@{comparison_result='unavailable';comparison_stage='report_validation'}
  try{
   $path=Join-Path $work ('compare-'+$Label+'.out');$item=Get-Item -LiteralPath $path -Force
   if(!$item.PSIsContainer -and !($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $item.Length -le 65536){
    $record=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json -AsHashtable -NoEnumerate
    if($record -is [Collections.IDictionary] -and ($record.schema -is [int] -or $record.schema -is [long]) -and $record.schema -eq 1 -and $record.producer -is [string] -and $record.producer -ceq 'windows-exact-json-comparison'){$observed=QualificationComparisonDetails $record;if($observed){$report=$observed}}
   }
  }catch{}
  $script:qualificationComparisonFailure=@{label=$Label;report=$report}
  if($Label -ceq 'fault-files' -and $report.comparison_result -ceq 'different' -and $report.comparison_files_observed -eq $true){
   try{$script:qualificationComparisonFailure.capture=QualificationFileCapture $Before $After $state $configuration}catch{$script:qualificationComparisonFailure.capture=@{state='unavailable';paths=@{}}}
  }
  throw
 }
}
function NormalTaskPreservation($Before,$After,[DateTime]$Started){
 WriteJson (Join-Path $work 'normal-tasks-exact-before.json') $Before;WriteJson (Join-Path $work 'normal-tasks-exact-after.json') $After
 $normalizedBefore=@{};$normalizedAfter=@{}
 foreach($name in $Before.Keys){
  Check ($After.ContainsKey($name) -and $Before[$name].exists -eq $After[$name].exists) 'Normal update changed the owned task inventory.'
  foreach($pair in @(@{source=$Before;target=$normalizedBefore},@{source=$After;target=$normalizedAfter})){
   $record=@{};foreach($key in $pair.source[$name].Keys){$record[$key]=$pair.source[$name][$key]}
   if($record.exists){
    [xml]$xml=$record.xml;$namespaces=[Xml.XmlNamespaceManager]::new($xml.NameTable);$namespaces.AddNamespace('t','http://schemas.microsoft.com/windows/2004/02/mit/task')
    # Re-registration records the actual current operator/date. These two
    # descriptive fields may change; executable/principal/settings/security may not.
    foreach($node in @($xml.SelectNodes('/t:Task/t:RegistrationInfo/t:Date|/t:Task/t:RegistrationInfo/t:Author',$namespaces))){$node.ParentNode.RemoveChild($node)|Out-Null}
    if($name -in 'OpenWebPBX-Backups','OpenWebPBX Outgoing Mail','OpenWebPBX-TenantDomains'){
     $nodes=@($xml.SelectNodes('/t:Task/t:Triggers/t:TimeTrigger/t:StartBoundary',$namespaces));Check ($nodes.Count -eq 1) 'The owned repeating task must retain one bounded schedule.'
     if([object]::ReferenceEquals($pair.source,$After)){$time=[DateTime]::Parse($nodes[0].InnerText).ToUniversalTime();Check ($time -ge $Started.ToUniversalTime().AddSeconds(-5) -and $time -le [DateTime]::UtcNow.AddMinutes(2)) 'The renewed owned schedule must be created during this real normal update.'}
     $nodes[0].InnerText='QUALIFIED_ONCE_TRIGGER_TIME'
    }
    $record.xml=$xml.OuterXml
   };$pair.target[$name]=$record
  }
 }
 EqualTaskSnapshots $normalizedBefore $normalizedAfter 'normal-task-contract-security'
}
function InstalledVersions([string]$Version){
 $installation=Get-Content "$state\installation.json" -Raw|ConvertFrom-Json;Check ($installation.Completed -and $installation.RestoreServer -and $installation.Version -eq $Version) 'The real installation version is invalid.'
 foreach($path in "$root\server\OpenWebPbx.Server.dll","$root\desktop\OpenWebPbx.Desktop.dll","$root\updater\slots\$Version\OpenWebPbx.Updater.dll"){Check ([Reflection.AssemblyName]::GetAssemblyName($path).Version -eq [version]($Version+'.0')) 'Real installed assemblies differ from the version.'}
 $health=Invoke-RestMethod 'http://127.0.0.1:8087/health' -TimeoutSec 10;Check ($health.state -eq 'Running' -and $health.version -eq $Version) 'The actual assembly-derived service health differs.'
 foreach($name in 'OpenWebPBX-Database','OpenWebPBX','FreeSWITCH','OpenWebPBXUpdater'){Check ((Get-Service $name).Status -eq 'Running') 'The installed native services are not healthy.'}
 $service=Get-CimInstance Win32_Service -Filter "Name='OpenWebPBXUpdater'";Check ($service.ProcessId -gt 0 -and $service.PathName.Trim('"') -eq "$root\updater\slots\$Version\OpenWebPbx.Updater.exe") 'SCM must run the selected genuine updater slot.'
 $process=Get-CimInstance Win32_Process -Filter ('ProcessId='+$service.ProcessId);$owner=Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid;Check ($owner.ReturnValue -eq 0 -and $owner.Sid -eq 'S-1-5-18' -and $process.ExecutablePath -eq "$root\updater\slots\$Version\OpenWebPbx.Updater.exe" -and $process.CommandLine -notmatch '--run-once|--verify-package|--skip-recovery') 'The running SYSTEM updater must use its ordinary service loop.'
 return [uint32]$service.ProcessId
}
function WaitInstall([string]$ExpectedState,[string]$ExpectedCommand,[DateTime]$Started,[int]$Limit=1800){
 $deadline=[DateTime]::UtcNow.AddSeconds($Limit);$observed=$false
 do{
  if(Test-Path "$state\updates\status.json"){$status=Get-Content "$state\updates\status.json" -Raw|ConvertFrom-Json;if($status.state -eq 'downloading' -and $status.progress_bytes -gt 0){$observed=$true}}
  if(Test-Path "$state\updates\install-journal.json"){$journal=Get-Content "$state\updates\install-journal.json" -Raw|ConvertFrom-Json;if($journal.state -eq 'recovery_required'){throw 'The signed transaction requires recovery; no qualification is implied.'};if($journal.state -eq $ExpectedState -and [DateTime]::Parse($journal.updated_at).ToUniversalTime() -ge $Started){
   try{$commands=(Fixture 'status').commands;$new=@($commands|Where-Object {$_.action -eq 'install' -and $_.command_uuid -notin $script:priorCommands -and $_.status -eq $ExpectedCommand});if($new.Count -eq 1){return @{journal=$journal;command=$new[0].command_uuid;progress_observed=$observed}}}catch{}
  }}
  Start-Sleep -Milliseconds 500
 }while([DateTime]::UtcNow -lt $deadline)
 throw 'The actual installed worker did not complete its bounded signed transaction.'
}
function DownloadProof([string]$Mode,$Packet){
 $path="$state\updates\downloads\$($Packet.sha256).archive";Check ((Test-Path $path) -and (Get-Item $path).Length -eq $Packet.bytes -and (Hash $path) -eq $Packet.sha256 -and !(Test-Path ($path+'.partial'))) 'The actual worker must retain the complete verified HTTP archive.'
 $requests=(Get-Content (Join-Path (Split-Path $inputFile -Parent) 'transport-requests.json') -Raw|ConvertFrom-Json).requests
 $archives=@($requests|Where-Object {$_.mode -eq $Mode -and $_.kind -eq 'archive'});Check ($archives.Count -eq 1 -and $archives[0].complete -and $archives[0].bytes -eq $Packet.bytes -and $archives[0].sha256 -eq $Packet.sha256 -and $archives[0].loopback -and $archives[0].original_url -and $archives[0].updater_user_agent) 'One full non-resumed original-URL HTTPS archive transfer from the actual updater is required.'
 Check (@($requests|Where-Object {$_.mode -eq $Mode -and $_.kind -eq 'feed' -and $_.complete}).Count -gt 0) 'The updater did not fetch the original pinned feed over trusted HTTPS.'
 $trust=Get-Content "$state\updates\trust.json" -Raw|ConvertFrom-Json;Check ($trust.sequence -eq $Packet.sequence -and $trust.payload_sha256 -eq $Packet.payload_sha256) 'The installed verifier did not persist the signed monotonic trust state.'
}
try{
 PrivateDirectory $work
 Check (!(Test-Path $root) -and !(Test-Path "$state\installation.json") -and !(Test-Path "$configuration\config.conf") -and !(Get-Service FreeSWITCH -ErrorAction SilentlyContinue)) 'Both stages require an empty disposable runner and refuse any existing owner installation.'
 $baseCandidate=Artifact $BaseSuiteRunId ('openwebpbx-windows-suite-candidate-'+$BaseSuiteRunId) '.github/workflows/windows-suite.yml'
 $baseReport=Artifact $BaseSuiteRunId ('openwebpbx-windows-suite-facts-'+$BaseSuiteRunId) '.github/workflows/windows-suite.yml'
 $baseFacts=Get-Content (Join-Path $baseReport.directory 'qualification.json') -Raw|ConvertFrom-Json
 Check ($baseFacts.schema -eq 1 -and $baseFacts.source_commit -eq $baseCandidate.run.head_sha -and $baseFacts.run_id -eq $BaseSuiteRunId -and $baseFacts.state -in 'partial','passed') 'The exact qualified baseline facts are required.'
 foreach($gate in 'fresh','native_sip_audio','backups','direct_113_helper_reapply','direct_failure_rollback','restore_gate_startup'){Check ($baseFacts.gates.$gate -eq 'passed') ('All essential real '+$BaseVersion+' baseline gates must pass before preparation or updater qualification.')}
 if([version]$BaseVersion -ge [version]'1.0.20'){
  foreach($gate in 'web_readiness','tenant_domains','meeting_transport','meeting_browser','phone_health','stun','native_clock','native_providers','native_call_me_back'){Check ($baseFacts.gates.$gate -is [string] -and $baseFacts.gates.$gate -ceq 'passed') 'The current Windows web, tenant, meeting, phone health, STUN, clock, provider and callback gates must all be qualified.'}
  $dtlsProof=$baseFacts.dtls_qualification
  Check ($null -ne $dtlsProof -and ($dtlsProof -is [pscustomobject] -or $dtlsProof -is [Collections.IDictionary]) -and $dtlsProof -isnot [Array]) 'The complete current native DTLS qualification record is required.'
  Check ($dtlsProof.state -is [string] -and $dtlsProof.state -ceq 'passed') 'The current native DTLS qualification must pass.'
  foreach($field in 'actual_native_windows','transaction_service_adapter_double'){Check ($dtlsProof.$field -is [bool] -and $dtlsProof.$field -eq $true) 'The native DTLS scope and explicit service-adapter double must match.'}
  foreach($limit in @(@('transaction_checks',62),@('crypto_checks',12),@('installed_checks',12))){$value=$dtlsProof.($limit[0]);Check (($value -is [int] -or $value -is [long]) -and $value -ge $limit[1] -and $value -le 10000) 'Every current native DTLS proof count must be complete and bounded.'}
  $phpProof=$baseFacts.php_runtime_qualification
  Check ($null -ne $phpProof -and ($phpProof -is [pscustomobject] -or $phpProof -is [Collections.IDictionary]) -and $phpProof -isnot [Array]) 'The complete current native PHP runtime proof is required.'
  Check ($phpProof.state -is [string] -and $phpProof.state -ceq 'passed' -and $phpProof.version -is [string] -and $phpProof.version -ceq '8.4.27') 'The current pinned PHP security runtime must be qualified.'
  Check ($phpProof.actual_native -is [bool] -and $phpProof.actual_native -eq $true -and $phpProof.installed_server_changed -is [bool] -and $phpProof.installed_server_changed -eq $false) 'The native PHP fixture scope must match.'
  Check (($phpProof.checks -is [int] -or $phpProof.checks -is [long]) -and $phpProof.checks -ge 3000 -and $phpProof.checks -le 100000 -and ($phpProof.vendor_files -is [int] -or $phpProof.vendor_files -is [long]) -and $phpProof.vendor_files -eq 79) 'The complete native PHP control and vendor inventories are required.'
  $recoveryProof=$baseFacts.upgrade_recovery_qualification
  Check ($null -ne $recoveryProof -and ($recoveryProof -is [pscustomobject] -or $recoveryProof -is [Collections.IDictionary]) -and $recoveryProof -isnot [Array]) 'The complete current native upgrade recovery proof is required.'
  Check ($recoveryProof.state -is [string] -and $recoveryProof.state -ceq 'passed' -and $recoveryProof.updater_scope -is [string] -and $recoveryProof.updater_scope -ceq 'candidate_component' -and $recoveryProof.updater_version -is [string] -and $recoveryProof.updater_version -ceq $BaseVersion) 'The actual recovery entry must use the exact candidate updater.'
  foreach($field in 'actual_native_windows','actual_configured_updater_boot'){Check ($recoveryProof.$field -is [bool] -and $recoveryProof.$field -eq $true) 'Actual native configured-updater recovery entry evidence is required.'}
  Check ($recoveryProof.installed_server_changed -is [bool] -and $recoveryProof.installed_server_changed -eq $false) 'The recovery component fixture must preserve the installed server.'
  foreach($limit in @(@('integration_checks',64),@('native_checks',202))){$value=$recoveryProof.($limit[0]);Check (($value -is [int] -or $value -is [long]) -and $value -ge $limit[1] -and $value -le 100000) 'The complete bounded current recovery entry matrices are required.'}
  $commitProof=$baseFacts.native_commit_selection
  Check ($null -ne $commitProof -and ($commitProof -is [pscustomobject] -or $commitProof -is [Collections.IDictionary]) -and $commitProof -isnot [Array]) 'The current native updater commit-selection proof is required.'
  Check ($commitProof.state -is [string] -and $commitProof.state -ceq 'passed') 'The native updater commit-selection matrix must pass.'
  foreach($field in 'actual_native_windows','service_adapter_double','slot_assembly_fixture','actual_running_image_lock','old_silent_exit3_proven','exact_mirror_refusal_retry','completed_finalizer_idempotent','before_commit_old_scm','after_commit_resume','after_selection_idempotent','absent_creation_deferred','legacy_missing_dependency_recovery'){Check ($commitProof.$field -is [bool] -and $commitProof.$field -eq $true) 'The actual image/commit/recovery coverage and explicit fixture scope must match.'}
  foreach($field in 'actual_installed_scm','installed_server_changed'){Check ($commitProof.$field -is [bool] -and $commitProof.$field -eq $false) 'The native commit fixture must not claim installed SCM qualification.'}
  foreach($limit in @(@('checks',133),@('guard_checks',52))){$value=$commitProof.($limit[0]);Check (($value -is [int] -or $value -is [long]) -and $value -ge $limit[1] -and $value -le 100000) 'Both current bounded commit-selection matrices are required.'}
  Check (($commitProof.actual_commit_interruption_positions -is [int] -or $commitProof.actual_commit_interruption_positions -is [long]) -and $commitProof.actual_commit_interruption_positions -eq 3) 'All three actual interrupted commit positions must pass.'
 }
 $base=Join-Path $baseCandidate.directory ('openwebpbx-'+$BaseVersion+'-windows-x64.zip');Check ((Hash $base) -eq $baseFacts.candidate_artifact.sha256 -and $baseFacts.candidate_artifact.private_exclusions -eq 'passed') 'The unchanged audited candidate checksum must match qualification facts.'
 CheckedProcess 'python.exe' @((Join-Path $PSScriptRoot 'windows_candidate_archive.py'),'--archive',$base,'--version',$BaseVersion,'--sha256',$baseFacts.candidate_artifact.sha256) 'verify-qualified-base'
 WriteJson (Join-Path $work 'baseline-facts.json') $baseFacts
 $facts.base_suite_run_id=$BaseSuiteRunId;$facts.base_source_commit=$baseFacts.source_commit;$facts.base_product_source_commit=if($baseFacts.product_source_commit){$baseFacts.product_source_commit}else{$baseFacts.source_commit};$facts.base_archive_sha256=Hash $base
 if($Mode -eq 'PrepareCanary'){PrepareCanary $base $baseFacts}
 else{
  $phase='root-reviewed signed canary inputs'
  $canary=Artifact $CanaryRunId ('openwebpbx-windows-updater-canary-'+$CanaryRunId) '.github/workflows/windows-updater-qualification.yml'
  $provenance=Join-Path $canary.directory 'provenance.json';$archives=@{fault=(Join-Path $canary.directory ('fault/openwebpbx-'+$CanaryVersion+'-windows-x64.zip'));normal=(Join-Path $canary.directory ('normal/openwebpbx-'+$CanaryVersion+'-windows-x64.zip'))}
  $packetPath=Join-Path $work 'root-reviewed-packets.json';$packetBytes=[Convert]::FromBase64String($env:WINDOWS_UPDATER_SIGNED_PACKETS_B64);Check ($packetBytes.Length -le 65536) 'Root-reviewed private envelope packet exceeds its bound.';[IO.File]::WriteAllBytes($packetPath,$packetBytes);Remove-Item Env:\WINDOWS_UPDATER_SIGNED_PACKETS_B64
  $packet=Get-Content $packetPath -Raw|ConvertFrom-Json;Check ($packet.canary_run_id -eq $CanaryRunId -and $packet.base_suite_run_id -eq $BaseSuiteRunId -and $packet.canary_preparation_source_commit -eq $canary.run.head_sha -and $packet.canary_provenance_sha256 -eq (Hash $provenance)) 'Root-reviewed exact canary build/run/provenance identities differ.'
  foreach($modeName in 'fault','normal'){CheckedProcess 'python.exe' @((Join-Path $PSScriptRoot 'windows_candidate_archive.py'),'--archive',$archives[$modeName],'--version',$CanaryVersion,'--sha256',$packet.$modeName.archive_sha256) ('verify-'+$modeName)}
  Check (!(Test-Path $root) -and !(Test-Path "$state\installation.json") -and !(Test-Path "$configuration\config.conf") -and !(Get-Service FreeSWITCH -ErrorAction SilentlyContinue)) 'A completely separate empty runner is required; never reuse an owner or installed factory.'
  $packageDirectory=Join-Path $work 'baseline-package';PrivateDirectory $packageDirectory;ExpandSafe $base $packageDirectory;$package=Join-Path $packageDirectory ('openwebpbx-'+$BaseVersion+'-windows-x64');NativeVersions $package $BaseVersion|Out-Null
  $PackageRoot=$package
  . (Join-Path $package 'Support-Recovery.ps1')
  $scope=[Guid]::NewGuid().ToString('N').Substring(0,24);$qa=Join-Path $state ('updater-qualification/'+$scope);PrivateDirectory $qa;$inputFile=Join-Path $qa 'input.json';$admin='updater-'+$scope+'@example.invalid';$secret='A9!'+(RandomSecret)
  $settings=@{schema=1;scope=$scope;run_id=$env:GITHUB_RUN_ID;admin_email=$admin;admin_password=$secret;company_name=('Fictional updater '+$scope);service_name=('Fictional updater PBX '+$scope);packet_file=$packetPath;provenance_file=$provenance;base_facts=(Join-Path $work 'baseline-facts.json');archives=$archives;public_key=(Join-Path $package 'release-public.pem');web_ca=(Join-Path $state 'local-test.cer');base_version=$BaseVersion;target_version=$CanaryVersion};WriteJson $inputFile $settings
  $env:OPENWEB_WINDOWS_UPDATER_TEST='1'
  # Verify signatures independently before installation. The later worker still
  # verifies them with its unchanged embedded original signing key.
  CheckedProcess (Join-Path $package 'backup-runtime/python.exe') @('-I','-B',(Join-Path $PSScriptRoot 'windows-updater-fixture.py'),'--input',$inputFile,'--action','validate') 'verify-private-signatures'
  $verified=Get-Content (Join-Path $qa 'verified-packets.json') -Raw|ConvertFrom-Json -AsHashtable;$settings.packets=$verified;WriteJson $inputFile $settings
  $hosts=Join-Path $env:SystemRoot 'System32/drivers/etc/hosts';$hostOriginal=[IO.File]::ReadAllBytes($hosts);$hostAcl=(Get-Acl $hosts).Sddl;$marker='# OpenWebPBX disposable updater '+$scope
  Check ([IO.File]::ReadAllText($hosts) -notmatch '(?im)^\s*[^#\r\n]+\s(?:github\.com|windowsqa\.example\.invalid)(?:\s|$)') 'The fixture refuses existing hostname overrides.'
  [IO.File]::AppendAllText($hosts,"`r`n127.0.0.1 windowsqa.example.invalid $marker`r`n",[Text.UTF8Encoding]::new($false));$ownHosts=$true
  $phase=('actual fresh qualified '+$BaseVersion+' installation')
  $launch=Join-Path $work 'install-baseline.ps1';$installInput=Join-Path $work 'install-input.json';WriteJson $installInput @{package=$package;admin=$admin;password=$secret}
  [IO.File]::WriteAllText($launch,@'
param([string]$InputPath)
$ErrorActionPreference='Stop';$r=Get-Content -LiteralPath $InputPath -Raw|ConvertFrom-Json
& (Join-Path $r.package 'Install-OpenWebPBX.ps1') -RestoreServer -LocalCertificate -DomainName windowsqa.example.invalid -PublicAddress 127.0.0.1 -AdminEmail $r.admin -AdminPassword (ConvertTo-SecureString $r.password -AsPlainText -Force)
if(!$?){exit 1}
'@,[Text.UTF8Encoding]::new($false))
  $installed=$true;CheckedProcess "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$launch,'-InputPath',$installInput) 'actual-fresh13';Remove-Item $installInput -Force
  InstalledVersions $BaseVersion|Out-Null
  # Python/OpenSSL needs the actual installed self-signed public certificate in
  # PEM form; it never bypasses certificate/hostname validation.
  $phase='installed13 HTTPS certificate preparation'
  $cert=[Security.Cryptography.X509Certificates.X509Certificate2]::new([IO.File]::ReadAllBytes("$state\local-test.cer"));$webPem=Join-Path $qa 'web-root.pem';[IO.File]::WriteAllText($webPem,"-----BEGIN CERTIFICATE-----`n"+[Convert]::ToBase64String($cert.RawData,[Base64FormattingOptions]::InsertLineBreaks)+"`n-----END CERTIFICATE-----`n",[Text.UTF8Encoding]::new($false));$cert.Dispose();$settings.web_ca=$webPem;WriteJson $inputFile $settings
  $phase='empty factory baseline capture';Fixture 'baseline'|Out-Null
  $phase='normal HTTPS fictional PBX setup';Python 'setup'
  $phase='owned fictional PBX discovery';Fixture 'discover'|Out-Null;$fixtureCreated=$true;$settings=Get-Content $inputFile -Raw|ConvertFrom-Json -AsHashtable
  # Seed ordinary owned media and inactive private PEM bytes, not certificates
  # falsely marked ready. Active phone TLS was already proved by the base suite.
  $phase='owned fictional PBX media preparation';$media=Join-Path $state ('storage/updater-'+$scope);PrivateDirectory $media
  $stream=[IO.File]::Create((Join-Path $media 'fictional.wav'));$writer=[IO.BinaryWriter]::new($stream)
  try{$writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF'));$writer.Write([uint32]4132);$writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '));$writer.Write([uint32]16);$writer.Write([uint16]1);$writer.Write([uint16]1);$writer.Write([uint32]8000);$writer.Write([uint32]16000);$writer.Write([uint16]2);$writer.Write([uint16]16);$writer.Write([Text.Encoding]::ASCII.GetBytes('data'));$writer.Write([uint32]4096);$writer.Write([Security.Cryptography.RandomNumberGenerator]::GetBytes(4096))}finally{$writer.Dispose();$stream.Dispose()};$settings.owned_media=$media
  $phase='laboratory HTTPS PKI preparation';Python 'prepare-pki';$pki=Get-Content (Join-Path $qa 'pki.json') -Raw|ConvertFrom-Json
  $privatePem=Join-Path $state ('phone-tls/updater-'+$scope);PrivateDirectory $privatePem;Copy-Item (Join-Path $qa 'transport-chain.pem'),(Join-Path $qa 'transport-leaf.key') $privatePem;$settings.owned_private_pem=$privatePem
  [IO.File]::WriteAllBytes((Join-Path $qa 'audit.key'),[Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
  $phase='laboratory HTTPS trust import';$transportRoot=Import-Certificate -FilePath (Join-Path $qa 'transport-root.cer') -CertStoreLocation Cert:\LocalMachine\Root;Check ($transportRoot.Thumbprint.ToLowerInvariant() -eq $pki.root_thumbprint) 'The exact owned laboratory trust root was not installed.'
  [IO.File]::AppendAllText($hosts,"127.0.0.1 github.com $marker`r`n",[Text.UTF8Encoding]::new($false));Clear-DnsClientCache
  $phase='laboratory HTTPS worker environment';$serviceKey='HKLM:\SYSTEM\CurrentControlSet\Services\OpenWebPBXUpdater';$environmentProperty=Get-ItemProperty -LiteralPath $serviceKey -Name Environment -ErrorAction SilentlyContinue;$serviceEnvironment=@{exists=($null -ne $environmentProperty);value=if($environmentProperty){$environmentProperty.Environment}else{@()}}
  Check (@($serviceEnvironment.value|Where-Object {$_ -match '^(?i:no_proxy|https?_proxy|all_proxy)='}).Count -eq 0) 'The disposable worker has an unexpected pre-existing proxy environment.'
  New-ItemProperty -LiteralPath $serviceKey -Name Environment -PropertyType MultiString -Value @($serviceEnvironment.value+@('NO_PROXY=github.com,windowsqa.example.invalid,127.0.0.1','no_proxy=github.com,windowsqa.example.invalid,127.0.0.1')) -Force|Out-Null
  $phase='laboratory HTTPS endpoint startup';WriteJson (Join-Path $qa 'mode.json') @{mode='fault'};WriteJson $inputFile $settings
  # The long-lived laboratory server runs the independent, hash-verified
  # extracted baseline runtime. Keeping the installed Python DLLs mapped would
  # artificially prevent the normal installer replacing its backup runtime.
  $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $package 'backup-runtime/python.exe'));$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;foreach($argument in @('-I','-B',(Join-Path $PSScriptRoot 'windows-updater-fixture.py'),'--input',$inputFile,'--action','serve')){$start.ArgumentList.Add($argument)};$transport=[Diagnostics.Process]::Start($start);$transportOutput=$transport.StandardOutput.ReadToEndAsync();$transportErrors=$transport.StandardError.ReadToEndAsync()
  for($i=0;$i -lt 100 -and !(Test-Path (Join-Path $qa 'transport-ready.json')) -and !$transport.HasExited;$i++){Start-Sleep -Milliseconds 100};Check (!$transport.HasExited -and (Test-Path (Join-Path $qa 'transport-ready.json'))) 'The owned trusted HTTPS endpoint failed to start.'
  # Initial fixture-only service environment setup precedes all acceptance
  # snapshots. No test restarts/kills the updater during either transaction.
  $phase='initial installed13 worker startup';Stop-Service OpenWebPBXUpdater;(Get-Service OpenWebPBXUpdater).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(45));Start-Service OpenWebPBXUpdater
  . (OriginalProcessProofSource (Join-Path $PSScriptRoot 'windows-upgrade-acceptance.ps1'))
  Start-Sleep -Seconds 2;[int]$initialPid=InstalledVersions $BaseVersion
  $phase='initial installed13 worker identity';$originalWorker=RetainQualificationProcess ([Diagnostics.Process]::GetProcessById($initialPid)) $initialPid "$root\updater\slots\${BaseVersion}\OpenWebPbx.Updater.exe" 'S-1-5-18' 0 ([DateTime]::MinValue)
  $phase='owned SYSTEM canary fault contract';$contractDirectory=Join-Path $state 'qualification113';PrivateDirectory $contractDirectory
  $contract=@{schema=1;authorized=$true;disposable=$true;fault_authorized=$true;disposable_hosted_runner=$true;github_actions=$true;runner_environment='github-hosted';nonce=$scope;run_id=$env:GITHUB_RUN_ID;repository='embire2/openwebpbx';expected_computer=$env:COMPUTERNAME;expected_domain='windowsqa.example.invalid';original_version=$BaseVersion;baseline_version=$BaseVersion;target_version=$CanaryVersion}
  WriteJson (Join-Path $contractDirectory 'canary-fault-contract.json') $contract;WriteJson (Join-Path $contractDirectory 'canary-host-sentinel.json') $contract
  foreach($file in 'canary-fault-contract.json','canary-host-sentinel.json'){SecureCanaryFaultContract (Join-Path $contractDirectory $file) $contractDirectory}
  $phase='original13 interactive manager startup';$originalManager=BeginManager
  $heldOriginalManager=RetainQualificationProcess $originalManager ([int]$originalManager.Id) "$root\desktop\OpenWebPbx.Desktop.exe" $managerSid $managerSession $managerStarted
  $phase='fault14 full HTTPS download and rollback'
  foreach($modeName in 'fault','normal'){$cache="$state\updates\downloads\$($verified[$modeName].sha256).archive";Check (!(Test-Path $cache) -and !(Test-Path ($cache+'.partial'))) 'The test refuses preseeded or partial canary archives.'}
  if(Test-Path "$state\updates\trust.json"){$prior=Get-Content "$state\updates\trust.json" -Raw|ConvertFrom-Json;Check ($prior.sequence -le $verified.fault.sequence) 'The private fault sequence must not lower existing trust.'}
  Check ((Fixture 'status').channels -eq 0) 'The actual call engine must be idle.'
  $phase='exact owned Health observer quiescence before all preservation baselines'
  Suspend-OpenWebQualificationHealth ([ref]$qualificationHealthOriginal)
  $facts.checks+='Exact owned Health task/helper identity and zero native children/runtime files before complete DB/file/task preservation baselines; enabled choice retained privately'
  $phase='ordinary SYSTEM backup worker baseline initialization'
  InitializeQualificationBackupWorker -Root $root -StateRoot $state -PackageRoot $package
  $facts.checks+='Actual unchanged installed SYSTEM backup task completed normally and initialized its regular worker lock before every acceptance baseline'
  $phase='fault14 full HTTPS download and rollback'
  $beforeDb=DatabaseSnapshot 'before-fault';$beforeFiles=FileSnapshot -Stage 'before_fault_full';$beforeTasks=TaskSnapshot;$protected=FileSnapshot -Protected -Stage 'before_fault_protected'
  $installationProtected=Get-Content "$state\installation.json" -Raw|ConvertFrom-Json -AsHashtable;$installationProtected.Remove('Version')|Out-Null
  $script:priorCommands=@((Fixture 'status').commands|ForEach-Object command_uuid);$requestStarted=[DateTime]::UtcNow;Python 'request';$failure=WaitInstall 'rolled_back' 'failed' $requestStarted
  DownloadProof 'fault' $verified.fault;Check ((InstalledVersions $BaseVersion) -eq $initialPid) 'The original ordinary installed13 worker must remain running after rollback.'
  AssertOriginalProcessState $originalWorker $initialPid $false 'The original ordinary installed13 worker must remain running after rollback.'
  $rollbackManager=ManagerReopened $BaseVersion $heldOriginalManager $requestStarted;$facts.gates.manager_reopen_rollback='passed'
  $heldRollbackManager=RetainQualificationProcess $rollbackManager ([int]$rollbackManager.Id) "$root\desktop\OpenWebPbx.Desktop.exe" $managerSid $managerSession $requestStarted
  $witness=Join-Path $contractDirectory ('canary-fault-witness-'+$scope+'.json');Check (Test-Path $witness) ('The signed fault must prove genuine post-deployment '+$CanaryVersion+' code and normal migration/task setup before failing.')
  $seen=Get-Content $witness -Raw|ConvertFrom-Json;Check ($seen.nonce -eq $scope -and $seen.run_id -eq $env:GITHUB_RUN_ID -and $seen.state -eq 'post_deploy_fault' -and $seen.baseline_version -eq $BaseVersion -and $seen.target_version -eq $CanaryVersion) 'The late signed fault witness is incomplete.'
  foreach($flag in 'normal_migration_completed','backup_and_mail_deferred','candidate_actual_assemblies','original_worker_parent','services_stopped','new_noncustomer_table','new_noncustomer_file','owned_task_hidden_changed','owned_task_read_acl_changed'){Check ($seen.$flag -is [bool] -and $seen.$flag -eq $true) 'The late signed fault did not prove every required actual mutation.'}
  foreach($flag in 'customer_rows_modified','registration_sent','carrier_calls'){Check ($seen.$flag -is [bool] -and $seen.$flag -eq $false) 'The fault witness exceeded its noncustomer scope.'}
  $settings.owned_update_commands=@($failure.command);WriteJson $inputFile $settings
  Equal $beforeDb (DatabaseSnapshot 'after-fault') 'fault-database';Equal $beforeFiles (FileSnapshot -Stage 'after_fault_full') 'fault-files';EqualTaskSnapshots $beforeTasks (TaskSnapshot) 'fault-tasks'
  $failed=Get-Content "$state\updates\failed-install.json" -Raw|ConvertFrom-Json;Check ($failed.version -eq $CanaryVersion -and $failed.asset_sha256 -eq $verified.fault.sha256) 'The worker did not record the exact failed signed package.'
  $facts.gates.fault_https_download='passed';$facts.gates.fault_rollback='passed';$facts.checks+='Actual installed13 SYSTEM worker full trusted HTTPS fault14 transfer, original key/URLs, late real14 witness and exact DB/roles/credentials/files/ACL/task rollback'
  $phase='higher-sequence normal14 full HTTPS download and natural restart'
  WriteJson (Join-Path $qa 'mode.json') @{mode='normal'};$script:priorCommands=@((Fixture 'status').commands|ForEach-Object command_uuid);$requestStarted=[DateTime]::UtcNow;Python 'request';$success=WaitInstall 'completed' 'completed' $requestStarted
  $restartDeadline=[DateTime]::UtcNow.AddSeconds(120);$newPid=0
  do{try{$newPid=InstalledVersions $CanaryVersion}catch{};if($newPid -and $newPid -ne $initialPid){break};Start-Sleep -Milliseconds 500}while([DateTime]::UtcNow -lt $restartDeadline)
  Check ($newPid -gt 0 -and $newPid -ne $initialPid) 'The installed restart task must naturally select and run genuine updater14 without a manual service restart.'
  AssertOriginalProcessState $originalWorker $initialPid $true 'The previous worker must naturally exit after its installed restart task executes.'
  $upgradedManager=ManagerReopened $CanaryVersion $heldRollbackManager $requestStarted;$facts.gates.manager_reopen_success='passed'
  $settings.owned_update_commands+=@($success.command);WriteJson $inputFile $settings
  DownloadProof 'normal' $verified.normal;Equal $beforeDb (DatabaseSnapshot 'after-normal') 'normal-database';Equal $protected (FileSnapshot -Protected -Stage 'after_normal_protected') 'normal-protected-files'
  $afterProtected=Get-Content "$state\installation.json" -Raw|ConvertFrom-Json -AsHashtable;$afterProtected.Remove('Version')|Out-Null;Equal $installationProtected $afterProtected 'normal-installation-secrets'
  NormalTaskPreservation $beforeTasks (TaskSnapshot) $requestStarted;Check (!(Test-Path "$state\updates\failed-install.json")) 'Success must clear the exact failed-install marker.'
  $status=Get-Content "$state\updates\status.json" -Raw|ConvertFrom-Json;Check ($status.last_success_version -eq $CanaryVersion -and $status.installed_version -eq $CanaryVersion) 'The naturally restarted real14 worker must retain last-success and current-version state.'
  Check ((Fixture 'status').channels -eq 0) 'The standalone updater must not create a native call.'
  $facts.gates.canary_build='passed';$facts.gates.normal_https_download='passed';$facts.gates.newer_upgrade='passed';$facts.gates.natural_updater_restart='passed';$facts.gates.protected_data='passed';$facts.checks+='Same installed13 worker higher-sequence full HTTPS normal14 transfer, genuine14 service/desktop/updater, completed command and natural SCM slot/PID restart; protected fictional data/private configuration/media/task security preserved'
  $facts.private_sequences=@($verified.fault.sequence,$verified.normal.sequence);$facts.canary_run_id=$CanaryRunId;$facts.fault_archive_sha256=$verified.fault.sha256;$facts.normal_archive_sha256=$verified.normal.sha256;$facts.state='passed'
 }
}catch{
 $facts.state='failed';$facts.failed_phase=$phase;$facts.error_type=$_.Exception.GetType().Name;$facts.source_basename=if($_.InvocationInfo.ScriptName){Split-Path -Leaf $_.InvocationInfo.ScriptName}else{'external_component'};$facts.source_line=[int]$_.InvocationInfo.ScriptLineNumber
 $facts.failure_observation=QualificationFailureObservation $_.ScriptStackTrace $script:qualificationFailedChild $script:qualificationComparisonFailure $script:qualificationFailedHash
 Write-Error ('Disposable updater qualification failed in '+$phase+'. Private streams are not published.') -ErrorAction Continue
}finally{
 Remove-Item Env:\GH_TOKEN,Env:\WINDOWS_UPDATER_SIGNED_PACKETS_B64 -ErrorAction SilentlyContinue
 $cleanup=$true
 try{
  if($installed){
   $lock=[IO.File]::Open("$state\upgrade.lock",'OpenOrCreate','ReadWrite','None')
   try{
    # Keep the guard through shutdown; a later scheduled tick may not begin a
    # transaction between the ownership check and removal of this fixture.
    # Restore the pre-baseline choice only after every strict comparison. The
    # held lock prevents a resumed observer changing the preserved fixture.
    # Disposable shutdown then stops that exact worker and refuses any orphan.
    Resume-OpenWebQualificationHealth $qualificationHealthOriginal
    $cleanupHealth=$null;Suspend-OpenWebQualificationHealth ([ref]$cleanupHealth)
    foreach($name in 'OpenWebPBX-Backups','OpenWebPBX-Cleanup','OpenWebPBX-Updater-Restart','OpenWebPBX Outgoing Mail','OpenWebPBX-TenantDomains','OpenWebPBX Certificate Renewal','OpenWebPBX Pending Phone Certificate'){if(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue){Disable-ScheduledTask -TaskName $name|Out-Null}}
    if(Get-Service OpenWebPBXUpdater -ErrorAction SilentlyContinue){Stop-Service OpenWebPBXUpdater -Force}
    if($managerOwned){foreach($process in @(OwnedManagers)){Stop-Process -Id $process.Id -Force};if(Get-ScheduledTask -TaskName $managerName -ErrorAction SilentlyContinue){Check (ManagerTaskValid) 'Cleanup refused a modified task outside the exact owned interactive contract.';Stop-ScheduledTask -TaskName $managerName;Unregister-ScheduledTask -TaskName $managerName -Confirm:$false};$managerOwned=$false}
    if($fixtureCreated){Fixture 'cleanup'|Out-Null}
    foreach($path in @($settings.owned_media,$settings.owned_private_pem)){if($path){Check ($path -match [regex]::Escape($scope)) 'Cleanup refused an unowned media path.';Remove-Item -LiteralPath $path -Recurse -Force}}
    foreach($name in 'OpenWebPBX','FreeSWITCH'){if(Get-Service $name -ErrorAction SilentlyContinue){Stop-Service $name -Force}}
    Add-Type -Path "$env:SystemRoot\System32\inetsrv\Microsoft.Web.Administration.dll"
    $iis=[Microsoft.Web.Administration.ServerManager]::new()
    try{
     $site=$iis.Sites['OpenWebPBX'];$pool=$iis.ApplicationPools['OpenWebPBX']
     Check ($site -and $pool -and $site.Applications['/'].ApplicationPoolName -eq 'OpenWebPBX' -and $site.Applications['/'].VirtualDirectories['/'].PhysicalPath -eq "$root\web") 'Cleanup refused IIS objects outside the exact disposable application.'
     StopQualificationIis $site $pool
    }finally{$iis.Dispose()}
    if($serviceEnvironment){if($serviceEnvironment.exists){New-ItemProperty -LiteralPath $serviceKey -Name Environment -PropertyType MultiString -Value $serviceEnvironment.value -Force|Out-Null}else{Remove-ItemProperty -LiteralPath $serviceKey -Name Environment -ErrorAction Stop}}
    if(Get-Service OpenWebPBX-Database -ErrorAction SilentlyContinue){Stop-Service OpenWebPBX-Database -Force}
   }finally{$lock.Dispose()}
  }
  if($transport){if(!$transport.HasExited){$transport.Kill();$transport.WaitForExit()};[IO.File]::WriteAllText((Join-Path $work 'transport-private.out'),$transportOutput.GetAwaiter().GetResult());[IO.File]::WriteAllText((Join-Path $work 'transport-private.err'),$transportErrors.GetAwaiter().GetResult());$transport.Dispose()}
  if($ownHosts){
   $text=[IO.File]::ReadAllText($hosts);$text=[regex]::Replace($text,'(?m)^127\.0\.0\.1 (?:github\.com|windowsqa\.example\.invalid) '+[regex]::Escape($marker)+'\r?\n','')
   # If unrelated bytes changed, do not overwrite them with the old file. Remove
   # only this run's lines and retain unrelated content, while preserving DACL.
   $originalText=[Text.UTF8Encoding]::new($false).GetString($hostOriginal)
   if($text -eq ($originalText+"`r`n")){[IO.File]::WriteAllBytes($hosts,$hostOriginal)}else{[IO.File]::WriteAllText($hosts,$text,[Text.UTF8Encoding]::new($false))}
   Check ((Get-Acl $hosts).Sddl -eq $hostAcl -and [IO.File]::ReadAllText($hosts) -notmatch [regex]::Escape($marker)) 'Owned host mapping cleanup or original ACL preservation failed.';Clear-DnsClientCache
  }
  if($transportRoot){$path='Cert:\LocalMachine\Root\'+$transportRoot.Thumbprint;Check ((Get-Item $path).Thumbprint -eq $transportRoot.Thumbprint) 'Cleanup refused an unrelated trust certificate.';Remove-Item $path}
  if($inputFile){Remove-Item -LiteralPath $inputFile -Force -ErrorAction SilentlyContinue}
  Remove-Item Env:\OPENWEB_WINDOWS_UPDATER_TEST -ErrorAction SilentlyContinue
 }catch{$cleanup=$false;$facts.cleanup_error_type=$_.Exception.GetType().Name;$facts.cleanup_source_line=[int]$_.InvocationInfo.ScriptLineNumber}
 finally{foreach($process in $retainedProcesses){$process.Dispose()}}
 $facts.cleanup=if($cleanup){'owned fixture rows/media, laboratory transport/trust/hosts/environment removed; disposable owned services stopped'}else{'failed'}
 if(!$cleanup){$facts.state='failed'}
 New-Item -ItemType Directory -Force $public|Out-Null;WriteJson (Join-Path $public 'qualification.json') $facts
 if($env:GITHUB_STEP_SUMMARY){('Standalone updater qualification: '+$facts.state+'. Public GitHub delivery/owner/carriers remain unqualified.')|Add-Content $env:GITHUB_STEP_SUMMARY}
}
if($facts.state -eq 'failed'){exit 1}
Write-Output ('Standalone updater stage '+$facts.state+'.')
