#Requires -RunAsAdministrator
#Requires -Version 7.4
<#
SPDX-License-Identifier: AGPL-3.0-or-later.
Two independent, opt-in disposable stages. Prepare builds real 1.0.14 assemblies
from an immutable 1.0.13 source plus two recorded version overlays. Qualify uses
only root-signed envelopes supplied privately; no signing key is accepted.
No owner-machine, public-release/feed or carrier qualification is performed.
#>
[CmdletBinding()]
param(
 [Parameter(Mandatory)][ValidateSet('PrepareCanary','QualifySigned')][string]$Mode,
 [Parameter(Mandatory)][ValidatePattern('^[0-9]+$')][string]$BaseSuiteRunId,
 [ValidatePattern('^[0-9]+$')][string]$CanaryRunId,
 [switch]$DisposableHostedRunner
)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
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
$facts=[ordered]@{schema=1;mode=$Mode;run_id=$env:GITHUB_RUN_ID;source_commit=$env:GITHUB_SHA;state='running';scope='disposable Windows Server 2025, fictional PBX, laboratory trusted HTTPS';checks=@();gates=[ordered]@{canary_build='pending';fault_https_download='unqualified';fault_rollback='unqualified';normal_https_download='unqualified';newer_upgrade='unqualified';natural_updater_restart='unqualified';manager_reopen_rollback='unqualified';manager_reopen_success='unqualified';protected_data='unqualified';public_github_delivery='unqualified';owner_106_upgrade='unqualified';carrier='unqualified'};cleanup='pending'}
function Check([bool]$Value,[string]$Message){if(!$Value){throw $Message}}
function Hash([string]$Path){return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function WriteJson([string]$Path,$Value){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 32),[Text.UTF8Encoding]::new($false))}
function PrivateDirectory([string]$Path){New-Item -ItemType Directory -Force $Path|Out-Null;& icacls.exe $Path /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F'|Out-Null;Check ($LASTEXITCODE -eq 0) 'Private qualification permissions failed.'}
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
 $matches=@((Api ('actions/runs/'+$RunId+'/artifacts?per_page=100')).artifacts|Where-Object {$_.name -eq $Name -and !$_.expired})
 Check ($matches.Count -eq 1 -and $matches[0].digest -match '^sha256:[a-f0-9]{64}$' -and $matches[0].size_in_bytes -le 8GB) 'One exact bounded artifact is required.'
 $artifact=$matches[0];$path=Join-Path $work ($Name+'.zip')
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
 $start=[Diagnostics.ProcessStartInfo]::new($Executable);$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.WorkingDirectory=$WorkingDirectory
 if($Executable -like '*WindowsPowerShell*'){$start.Environment['PSModulePath']=(Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/Modules')+';'+(Join-Path $env:ProgramFiles 'WindowsPowerShell/Modules')}
 foreach($argument in $Arguments){$start.ArgumentList.Add($argument)}
 $process=[Diagnostics.Process]::Start($start);$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
 # Do not kill an in-flight installer transaction. The ephemeral runner timeout
 # and durable product journal own recovery when it cannot complete in bounds.
 Check ($process.WaitForExit($Timeout)) 'A private qualification child exceeded its deadline; do not interrupt its transaction.'
 [IO.File]::WriteAllText((Join-Path $work ($Label+'.out')),$stdout.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText((Join-Path $work ($Label+'.err')),$stderr.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($false))
 $exit=$process.ExitCode;$process.Dispose();Check ($exit -eq 0) 'A private qualification operation failed; its streams remain private.'
}
function NativeVersions([string]$Directory,[string]$Version){
 $paths=@{'server/OpenWebPbx.Server.dll'='server';'desktop/OpenWebPbx.Desktop.dll'='desktop';'updater/OpenWebPbx.Updater.dll'='updater'};$records=@()
 foreach($path in $paths.Keys){$full=Join-Path $Directory $path;Check ([Reflection.AssemblyName]::GetAssemblyName($full).Version -eq [version]($Version+'.0')) 'The genuine service, desktop and updater assembly versions must match.';$records+=@{path=$path;assembly_version=$Version+'.0';sha256=(Hash $full)}};return $records
}
function PrepareCanary($Base,$BaseFacts){
 $phaseBefore=$script:phase;$script:phase='isolated real 1.0.14 build'
 $overlay=Join-Path $work 'source-overlay';$native=Join-Path $work 'native14';PrivateDirectory $native
 CheckedProcess 'git.exe' @('fetch','--no-tags','origin',$BaseFacts.source_commit) 'fetch-immutable-source'
 CheckedProcess 'git.exe' @('worktree','add','--detach',$overlay,$BaseFacts.source_commit) 'source-worktree'
 $version=(Get-Content (Join-Path $overlay 'VERSION') -Raw).Trim();Check ($version -eq '1.0.13') 'The canary must derive from the actual qualified 1.0.13 source.'
 $files=@(& git.exe -C $overlay ls-files -- platform packaging/updates/release-public.pem VERSION);Check ($LASTEXITCODE -eq 0 -and $files.Count -gt 40) 'The complete native source inventory is required.'
 $inputs=@($files|ForEach-Object {@{path=$_;sha256=(Hash (Join-Path $overlay $_))}});$overlays=@()
 foreach($relative in 'VERSION','platform/Directory.Build.props'){
  $path=Join-Path $overlay $relative;$old=Hash $path;$text=[IO.File]::ReadAllText($path)
  if($relative -eq 'VERSION'){Check ([regex]::Matches($text,'1\.0\.13').Count -eq 1) 'The original release version label is ambiguous.';$text=$text.Replace('1.0.13','1.0.14')}else{Check ([regex]::Matches($text,'<Version>1\.0\.13</Version>').Count -eq 1) 'The source version overlay is ambiguous.';$text=$text.Replace('<Version>1.0.13</Version>','<Version>1.0.14</Version>')}
  [IO.File]::WriteAllText($path,$text,[Text.UTF8Encoding]::new($false));$overlays+=@{path=$relative;original_sha256=$old;sha256=(Hash $path)}
  $record=Join-Path $native ('overlays/'+$relative);New-Item -ItemType Directory -Force (Split-Path $record -Parent)|Out-Null;Copy-Item -LiteralPath $path -Destination $record
 }
 [IO.File]::WriteAllText((Join-Path $overlay 'global.json'),'{"sdk":{"version":"10.0.401","rollForward":"disable"}}',[Text.UTF8Encoding]::new($false))
 Check ((& dotnet.exe --version).Trim() -eq '10.0.401') 'The pinned .NET SDK is required.'
 foreach($component in 'server','updater'){$project=if($component -eq 'server'){'OpenWebPbx.Server'}else{'OpenWebPbx.Updater'};CheckedProcess 'dotnet.exe' @('publish',('platform/'+$project),'-c','Release','-r','win-x64','--self-contained','true','-o',(Join-Path $native $component)) ($component+'-14-build') $overlay}
 CheckedProcess 'dotnet.exe' @('build','platform/OpenWebPbx.Desktop','-c','Release','-p:Platform=x64','-o',(Join-Path $native 'desktop')) 'desktop-14-build' $overlay
 foreach($project in 'OpenWebPbx.Checks','OpenWebPbx.Updater.Checks'){CheckedProcess 'dotnet.exe' @('run','--project',('platform/'+$project),'-c','Release') ($project+'-checks') $overlay}
 $versions=NativeVersions $native '1.0.14'
 $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $native 'desktop/OpenWebPbx.Desktop.exe'));$start.UseShellExecute=$false;$start.WorkingDirectory=Join-Path $native 'desktop';$manager=[Diagnostics.Process]::Start($start)
 try{$deadline=[DateTime]::UtcNow.AddSeconds(45);do{Start-Sleep -Milliseconds 500;$manager.Refresh();Check (!$manager.HasExited) 'The real canary manager exited before its startup gate.'}while($manager.MainWindowHandle -eq 0 -and [DateTime]::UtcNow -lt $deadline);Check ($manager.MainWindowHandle -ne 0 -and $manager.Responding -and $manager.MainWindowTitle -eq 'OpenWeb PBX 1.0.14') 'The responsive real 1.0.14 manager window is required.';$launch=@{process_alive=$true;responsive=$true;window_title=$manager.MainWindowTitle;window_verified=$true;session_id=$manager.SessionId}}finally{if(!$manager.HasExited){$manager.CloseMainWindow()|Out-Null;if(!$manager.WaitForExit(10000)){$manager.Kill()}};$manager.Dispose()}
 foreach($input in $inputs){$expected=if($input.path -in 'VERSION','platform/Directory.Build.props'){($overlays|Where-Object path -eq $input.path).sha256}else{$input.sha256};Check ((Hash (Join-Path $overlay $input.path)) -eq $expected) 'The native build modified an unapproved source input.'}
 $modified=@(& git.exe -C $overlay diff --name-only HEAD);Check (@(Compare-Object ($modified|Sort-Object) @('VERSION','platform/Directory.Build.props')).Count -eq 0) 'Only the two recorded version overlays may change tracked source.'
 WriteJson (Join-Path $native 'source-inputs.json') @{version='1.0.14';source_commit=$BaseFacts.source_commit;source_inputs=$inputs;overlays=$overlays;sdk='10.0.401';preparation_source_commit=$env:GITHUB_SHA;preparation_run_id=$env:GITHUB_RUN_ID;runner_image=$env:ImageVersion}
 WriteJson (Join-Path $native 'verification.json') @{version='1.0.14';assemblies=$versions;manager_startup=$launch;protocol_checks='passed';updater_checks='passed'}
 $lines=@(Get-ChildItem -LiteralPath $native -File -Recurse|Sort-Object FullName|ForEach-Object {('{0}  {1}' -f (Hash $_.FullName),[IO.Path]::GetRelativePath($native,$_.FullName).Replace('\','/'))})
 [IO.File]::WriteAllLines((Join-Path $native 'SHA256SUMS'),$lines,[Text.UTF8Encoding]::new($false))
 Check (!(Test-Path -LiteralPath $output)) 'An old canary export must not be reused.'
 CheckedProcess 'python.exe' @((Join-Path $PSScriptRoot 'windows-canary-preparation.py'),'--base-archive',$Base,'--base-facts',(Join-Path $work 'baseline-facts.json'),'--native-root',$native,'--output-dir',$output) 'prepare-audited-canary'
 $facts.gates.canary_build='passed';$facts.checks+='Genuine 1.0.14 server/manager/updater builds, responsive manager, exactly two source overlays, complete normal/fault manifest and source/hash evidence';$facts.state='prepared';$script:phase=$phaseBefore
}
function Fixture([string]$Action){
 $start=[Diagnostics.ProcessStartInfo]::new("$root\php\php.exe");$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WorkingDirectory="$root\web";$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 foreach($argument in @((Join-Path $PSScriptRoot 'windows-updater-fixture.php'),$Action,$inputFile)){$start.ArgumentList.Add($argument)}
 $process=[Diagnostics.Process]::Start($start);$out=$process.StandardOutput.ReadToEndAsync();$err=$process.StandardError.ReadToEndAsync();Check ($process.WaitForExit(90000)) 'The private scoped audit exceeded its deadline.';$text=$out.GetAwaiter().GetResult();[IO.File]::WriteAllText((Join-Path $work ($Action+'-private.err')),$err.GetAwaiter().GetResult());$exit=$process.ExitCode;$process.Dispose();Check ($exit -eq 0) 'The private scoped audit failed.';return $text|ConvertFrom-Json
}
function Python([string]$Action){CheckedProcess "$root\backup-runtime\python.exe" @('-I',(Join-Path $PSScriptRoot 'windows-updater-fixture.py'),'--input',$inputFile,'--action',$Action) ('python-'+$Action)}
function DatabaseSnapshot([string]$Label){$settings.snapshot_label=$Label;WriteJson $inputFile $settings;Fixture 'snapshot'|Out-Null;return Get-Content (Join-Path (Split-Path $inputFile -Parent) ($Label+'-database.json')) -Raw|ConvertFrom-Json -AsHashtable}
function FileSnapshot([switch]$Protected){
 $directories=if($Protected){@($configuration,"$state\storage","$state\mobile-notifications","$state\phone-tls","$state\public-access")}else{@("$root\web","$root\server","$root\desktop","$root\tools","$root\backup-runtime","$root\acme","$root\updater\slots",$configuration,"$engine\conf","$engine\scripts","$engine\mod","$engine\sounds","$state\storage","$state\mobile-notifications","$state\phone-tls","$state\public-access")}
 $entries=@{}
 foreach($parent in $root,"$root\updater",$state,$engine){Check (!(Get-Item $parent).Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) 'A linked parent cannot be audited.';$entries[$parent]=@{directory=$true;acl=(Get-Acl $parent).Sddl}}
 foreach($directory in $directories){if(!(Test-Path -LiteralPath $directory)){continue};foreach($item in @(Get-Item -LiteralPath $directory -Force)+@(Get-ChildItem -LiteralPath $directory -Recurse -Force)){Check (!$item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) 'A linked fixture cannot be audited.';$record=@{directory=[bool]$item.PSIsContainer;acl=(Get-Acl -LiteralPath $item.FullName).Sddl};if(!$item.PSIsContainer){$record.sha256=Hash $item.FullName;$record.bytes=$item.Length};$entries[$item.FullName]=$record}}
 $paths=@("$state\runtime.json","$state\phone-tls.json","$state\native-engine.json","$state\local-codec.json","$root\php\php.ini","$root\php\extras\ssl\openssl.cnf","$root\php\extras\ssl\cacert.pem","$engine\libbcg729.dll")
 if(!$Protected){$paths+=@("$state\installation.json","$state\updater-install.json")}
 foreach($path in $paths){if(Test-Path -LiteralPath $path){$item=Get-Item -LiteralPath $path;Check (!$item.Attributes.HasFlag([IO.FileAttributes]::ReparsePoint)) 'A private audited file must be regular.';$entries[$path]=@{directory=$false;acl=(Get-Acl -LiteralPath $path).Sddl;sha256=(Hash $path);bytes=$item.Length}}}
 return $entries
}
function TaskSnapshot {
 $result=@{};$scheduler=New-Object -ComObject Schedule.Service;$scheduler.Connect()
 # The owned interactive manager re-registers its task when each new window
 # loads. Its exact user/action/security contract is checked separately; static
 # service tasks must preserve their complete XML/COM/file security inventory.
 $names=@('OpenWebPBX-Backups','OpenWebPBX-Cleanup','OpenWebPBX-Updater-Restart','OpenWebPBX Outgoing Mail','OpenWebPBX Certificate Renewal','OpenWebPBX Pending Phone Certificate')
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
 $script:managerSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;$script:managerSession=[Diagnostics.Process]::GetCurrentProcess().SessionId;$script:managerName='OpenWebPBX-Manager-'+$managerSid
 Check ($managerSession -gt 0 -and [Environment]::UserInteractive) 'Interactive manager reopen remains unqualified when the disposable runner has no real user session.'
 Check (@(Get-CimInstance Win32_Process -Filter "Name='OpenWebPbx.Desktop.exe'").Count -eq 0 -and !(Get-ScheduledTask -TaskName $managerName -ErrorAction SilentlyContinue)) 'Never reuse or close a foreign/pre-existing manager or task.'
 $script:managerOwned=$true;$script:managerStarted=[DateTime]::UtcNow;$start=[Diagnostics.ProcessStartInfo]::new("$root\desktop\OpenWebPbx.Desktop.exe");$start.UseShellExecute=$false;$start.WorkingDirectory="$root\desktop";$start.Environment['PSModulePath']=(Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/Modules')+';'+(Join-Path $env:ProgramFiles 'WindowsPowerShell/Modules');$process=[Diagnostics.Process]::Start($start);$process.Dispose()
 return WaitManager '1.0.13'
}
function ManagerReopened([string]$Version,[int]$PreviousPid,[DateTime]$NotBefore){
 Check (!(Get-Process -Id $PreviousPid -ErrorAction SilentlyContinue)) 'The updater did not close the original owned installed manager.'
 $journal=Get-Content "$state\updates\install-journal.json" -Raw|ConvertFrom-Json;Check (@($journal.manager_tasks) -contains $managerName) 'The genuine product transaction must record the actual interactive restart task.'
 return WaitManager $Version $PreviousPid $NotBefore
}
function Equal($Before,$After,[string]$Label){$a=Join-Path $work ($Label+'-before.json');$b=Join-Path $work ($Label+'-after.json');WriteJson $a $Before;WriteJson $b $After;CheckedProcess "$root\backup-runtime\python.exe" @('-I','-c','import json,sys;assert json.load(open(sys.argv[1],encoding="utf-8-sig"))==json.load(open(sys.argv[2],encoding="utf-8-sig"))',$a,$b) ('compare-'+$Label)}
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
    if($name -in 'OpenWebPBX-Backups','OpenWebPBX Outgoing Mail'){
     $nodes=@($xml.SelectNodes('/t:Task/t:Triggers/t:TimeTrigger/t:StartBoundary',$namespaces));Check ($nodes.Count -eq 1) 'The owned repeating task must retain one bounded schedule.'
     if([object]::ReferenceEquals($pair.source,$After)){$time=[DateTime]::Parse($nodes[0].InnerText).ToUniversalTime();Check ($time -ge $Started.ToUniversalTime().AddSeconds(-5) -and $time -le [DateTime]::UtcNow.AddMinutes(2)) 'The renewed owned schedule must be created during this real normal update.'}
     $nodes[0].InnerText='QUALIFIED_ONCE_TRIGGER_TIME'
    }
    $record.xml=$xml.OuterXml
   };$pair.target[$name]=$record
  }
 }
 Equal $normalizedBefore $normalizedAfter 'normal-task-contract-security'
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
 foreach($gate in 'fresh','native_sip_audio','backups','direct_113_helper_reapply','direct_failure_rollback','restore_gate_startup'){Check ($baseFacts.gates.$gate -eq 'passed') 'All essential real 1.0.13 baseline gates must pass before preparation or updater qualification.'}
 $base=Join-Path $baseCandidate.directory 'openwebpbx-1.0.13-windows-x64.zip';Check ((Hash $base) -eq $baseFacts.candidate_artifact.sha256 -and $baseFacts.candidate_artifact.private_exclusions -eq 'passed') 'The unchanged audited candidate checksum must match qualification facts.'
 CheckedProcess 'python.exe' @((Join-Path $PSScriptRoot 'windows_candidate_archive.py'),'--archive',$base,'--version','1.0.13','--sha256',$baseFacts.candidate_artifact.sha256) 'verify-qualified-base'
 WriteJson (Join-Path $work 'baseline-facts.json') $baseFacts
 $facts.base_suite_run_id=$BaseSuiteRunId;$facts.base_source_commit=$baseFacts.source_commit;$facts.base_archive_sha256=Hash $base
 if($Mode -eq 'PrepareCanary'){PrepareCanary $base $baseFacts}
 else{
  $phase='root-reviewed signed canary inputs'
  $canary=Artifact $CanaryRunId ('openwebpbx-windows-updater-canary-'+$CanaryRunId) '.github/workflows/windows-updater-qualification.yml'
  $provenance=Join-Path $canary.directory 'provenance.json';$archives=@{fault=(Join-Path $canary.directory 'fault/openwebpbx-1.0.14-windows-x64.zip');normal=(Join-Path $canary.directory 'normal/openwebpbx-1.0.14-windows-x64.zip')}
  $packetPath=Join-Path $work 'root-reviewed-packets.json';$packetBytes=[Convert]::FromBase64String($env:WINDOWS_UPDATER_SIGNED_PACKETS_B64);Check ($packetBytes.Length -le 65536) 'Root-reviewed private envelope packet exceeds its bound.';[IO.File]::WriteAllBytes($packetPath,$packetBytes);Remove-Item Env:\WINDOWS_UPDATER_SIGNED_PACKETS_B64
  $packet=Get-Content $packetPath -Raw|ConvertFrom-Json;Check ($packet.canary_run_id -eq $CanaryRunId -and $packet.base_suite_run_id -eq $BaseSuiteRunId -and $packet.canary_preparation_source_commit -eq $canary.run.head_sha -and $packet.canary_provenance_sha256 -eq (Hash $provenance)) 'Root-reviewed exact canary build/run/provenance identities differ.'
  foreach($modeName in 'fault','normal'){CheckedProcess 'python.exe' @((Join-Path $PSScriptRoot 'windows_candidate_archive.py'),'--archive',$archives[$modeName],'--version','1.0.14','--sha256',$packet.$modeName.archive_sha256) ('verify-'+$modeName)}
  Check (!(Test-Path $root) -and !(Test-Path "$state\installation.json") -and !(Test-Path "$configuration\config.conf") -and !(Get-Service FreeSWITCH -ErrorAction SilentlyContinue)) 'A completely separate empty runner is required; never reuse an owner or installed factory.'
  $packageDirectory=Join-Path $work 'baseline-package';PrivateDirectory $packageDirectory;ExpandSafe $base $packageDirectory;$package=Join-Path $packageDirectory 'openwebpbx-1.0.13-windows-x64';NativeVersions $package '1.0.13'|Out-Null
  $scope=[Guid]::NewGuid().ToString('N').Substring(0,24);$qa=Join-Path $state ('updater-qualification/'+$scope);PrivateDirectory $qa;$inputFile=Join-Path $qa 'input.json';$admin='updater-'+$scope+'@example.invalid';$secret='A9!'+(RandomSecret)
  $settings=@{schema=1;scope=$scope;run_id=$env:GITHUB_RUN_ID;admin_email=$admin;admin_password=$secret;company_name=('Fictional updater '+$scope);service_name=('Fictional updater PBX '+$scope);packet_file=$packetPath;provenance_file=$provenance;base_facts=(Join-Path $work 'baseline-facts.json');archives=$archives;public_key=(Join-Path $package 'release-public.pem');web_ca=(Join-Path $state 'local-test.cer')};WriteJson $inputFile $settings
  $env:OPENWEB_WINDOWS_UPDATER_TEST='1'
  # Verify signatures independently before installation. The later worker still
  # verifies them with its unchanged embedded original signing key.
  CheckedProcess (Join-Path $package 'backup-runtime/python.exe') @('-I',(Join-Path $PSScriptRoot 'windows-updater-fixture.py'),'--input',$inputFile,'--action','validate') 'verify-private-signatures'
  $verified=Get-Content (Join-Path $qa 'verified-packets.json') -Raw|ConvertFrom-Json -AsHashtable;$settings.packets=$verified;WriteJson $inputFile $settings
  $hosts=Join-Path $env:SystemRoot 'System32/drivers/etc/hosts';$hostOriginal=[IO.File]::ReadAllBytes($hosts);$hostAcl=(Get-Acl $hosts).Sddl;$marker='# OpenWebPBX disposable updater '+$scope
  Check ([IO.File]::ReadAllText($hosts) -notmatch '(?im)^\s*[^#\r\n]+\s(?:github\.com|windowsqa\.example\.invalid)(?:\s|$)') 'The fixture refuses existing hostname overrides.'
  [IO.File]::AppendAllText($hosts,"`r`n127.0.0.1 windowsqa.example.invalid $marker`r`n",[Text.UTF8Encoding]::new($false));$ownHosts=$true
  $phase='actual fresh qualified 1.0.13 installation'
  $launch=Join-Path $work 'install-baseline.ps1';$installInput=Join-Path $work 'install-input.json';WriteJson $installInput @{package=$package;admin=$admin;password=$secret}
  [IO.File]::WriteAllText($launch,@'
param([string]$InputPath)
$ErrorActionPreference='Stop';$r=Get-Content -LiteralPath $InputPath -Raw|ConvertFrom-Json
& (Join-Path $r.package 'Install-OpenWebPBX.ps1') -RestoreServer -LocalCertificate -DomainName windowsqa.example.invalid -PublicAddress 127.0.0.1 -AdminEmail $r.admin -AdminPassword (ConvertTo-SecureString $r.password -AsPlainText -Force)
if(!$?){exit 1}
'@,[Text.UTF8Encoding]::new($false))
  $installed=$true;CheckedProcess "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$launch,'-InputPath',$installInput) 'actual-fresh13';Remove-Item $installInput -Force
  InstalledVersions '1.0.13'|Out-Null
  # Python/OpenSSL needs the actual installed self-signed public certificate in
  # PEM form; it never bypasses certificate/hostname validation.
  $cert=[Security.Cryptography.X509Certificates.X509Certificate2]::new([IO.File]::ReadAllBytes("$state\local-test.cer"));$webPem=Join-Path $qa 'web-root.pem';[IO.File]::WriteAllText($webPem,"-----BEGIN CERTIFICATE-----`n"+[Convert]::ToBase64String($cert.RawData,[Base64FormattingOptions]::InsertLineBreaks)+"`n-----END CERTIFICATE-----`n",[Text.UTF8Encoding]::new($false));$cert.Dispose();$settings.web_ca=$webPem;WriteJson $inputFile $settings
  Fixture 'baseline'|Out-Null;$phase='normal HTTPS fictional PBX setup';Python 'setup';Fixture 'discover'|Out-Null;$fixtureCreated=$true;$settings=Get-Content $inputFile -Raw|ConvertFrom-Json -AsHashtable
  # Seed ordinary owned media and inactive private PEM bytes, not certificates
  # falsely marked ready. Active phone TLS was already proved by the base suite.
  $media=Join-Path $state ('storage/updater-'+$scope);PrivateDirectory $media
  $stream=[IO.File]::Create((Join-Path $media 'fictional.wav'));$writer=[IO.BinaryWriter]::new($stream)
  try{$writer.Write([Text.Encoding]::ASCII.GetBytes('RIFF'));$writer.Write([uint32]4132);$writer.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '));$writer.Write([uint32]16);$writer.Write([uint16]1);$writer.Write([uint16]1);$writer.Write([uint32]8000);$writer.Write([uint32]16000);$writer.Write([uint16]2);$writer.Write([uint16]16);$writer.Write([Text.Encoding]::ASCII.GetBytes('data'));$writer.Write([uint32]4096);$writer.Write([Security.Cryptography.RandomNumberGenerator]::GetBytes(4096))}finally{$writer.Dispose();$stream.Dispose()};$settings.owned_media=$media
  Python 'prepare-pki';$pki=Get-Content (Join-Path $qa 'pki.json') -Raw|ConvertFrom-Json
  $privatePem=Join-Path $state ('phone-tls/updater-'+$scope);PrivateDirectory $privatePem;Copy-Item (Join-Path $qa 'transport-chain.pem'),(Join-Path $qa 'transport-leaf.key') $privatePem;$settings.owned_private_pem=$privatePem
  [IO.File]::WriteAllBytes((Join-Path $qa 'audit.key'),[Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
  $transportRoot=Import-Certificate -FilePath (Join-Path $qa 'transport-root.cer') -CertStoreLocation Cert:\LocalMachine\Root;Check ($transportRoot.Thumbprint.ToLowerInvariant() -eq $pki.root_thumbprint) 'The exact owned laboratory trust root was not installed.'
  [IO.File]::AppendAllText($hosts,"127.0.0.1 github.com $marker`r`n",[Text.UTF8Encoding]::new($false));Clear-DnsClientCache
  $serviceKey='HKLM:\SYSTEM\CurrentControlSet\Services\OpenWebPBXUpdater';$environmentProperty=Get-ItemProperty -LiteralPath $serviceKey -Name Environment -ErrorAction SilentlyContinue;$serviceEnvironment=@{exists=($null -ne $environmentProperty);value=if($environmentProperty){$environmentProperty.Environment}else{@()}}
  Check (@($serviceEnvironment.value|Where-Object {$_ -match '^(?i:no_proxy|https?_proxy|all_proxy)='}).Count -eq 0) 'The disposable worker has an unexpected pre-existing proxy environment.'
  New-ItemProperty -LiteralPath $serviceKey -Name Environment -PropertyType MultiString -Value @($serviceEnvironment.value+@('NO_PROXY=github.com,windowsqa.example.invalid,127.0.0.1','no_proxy=github.com,windowsqa.example.invalid,127.0.0.1')) -Force|Out-Null
  WriteJson (Join-Path $qa 'mode.json') @{mode='fault'};WriteJson $inputFile $settings
  # The long-lived laboratory server runs the independent, hash-verified
  # extracted baseline runtime. Keeping the installed Python DLLs mapped would
  # artificially prevent the normal installer replacing its backup runtime.
  $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $package 'backup-runtime/python.exe'));$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;foreach($argument in @('-I',(Join-Path $PSScriptRoot 'windows-updater-fixture.py'),'--input',$inputFile,'--action','serve')){$start.ArgumentList.Add($argument)};$transport=[Diagnostics.Process]::Start($start);$transportOutput=$transport.StandardOutput.ReadToEndAsync();$transportErrors=$transport.StandardError.ReadToEndAsync()
  for($i=0;$i -lt 100 -and !(Test-Path (Join-Path $qa 'transport-ready.json')) -and !$transport.HasExited;$i++){Start-Sleep -Milliseconds 100};Check (!$transport.HasExited -and (Test-Path (Join-Path $qa 'transport-ready.json'))) 'The owned trusted HTTPS endpoint failed to start.'
  # Initial fixture-only service environment setup precedes all acceptance
  # snapshots. No test restarts/kills the updater during either transaction.
  Stop-Service OpenWebPBXUpdater;(Get-Service OpenWebPBXUpdater).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(45));Start-Service OpenWebPBXUpdater
  Start-Sleep -Seconds 2;$initialPid=InstalledVersions '1.0.13'
  $contractDirectory=Join-Path $state 'qualification113';PrivateDirectory $contractDirectory
  $contract=@{schema=1;authorized=$true;disposable=$true;fault_authorized=$true;disposable_hosted_runner=$true;github_actions=$true;runner_environment='github-hosted';nonce=$scope;run_id=$env:GITHUB_RUN_ID;repository='embire2/openwebpbx';expected_computer=$env:COMPUTERNAME;expected_domain='windowsqa.example.invalid';original_version='1.0.13';baseline_version='1.0.13';target_version='1.0.14'}
  WriteJson (Join-Path $contractDirectory 'canary-fault-contract.json') $contract;WriteJson (Join-Path $contractDirectory 'canary-host-sentinel.json') $contract
  foreach($file in 'canary-fault-contract.json','canary-host-sentinel.json'){& icacls.exe (Join-Path $contractDirectory $file) /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F' /setowner '*S-1-5-32-544'|Out-Null;Check ($LASTEXITCODE -eq 0) 'The owned SYSTEM fault contract file could not be secured.'}
  $originalManager=BeginManager
  $phase='fault14 full HTTPS download and rollback'
  foreach($modeName in 'fault','normal'){$cache="$state\updates\downloads\$($verified[$modeName].sha256).archive";Check (!(Test-Path $cache) -and !(Test-Path ($cache+'.partial'))) 'The test refuses preseeded or partial canary archives.'}
  if(Test-Path "$state\updates\trust.json"){$prior=Get-Content "$state\updates\trust.json" -Raw|ConvertFrom-Json;Check ($prior.sequence -le $verified.fault.sequence) 'The private fault sequence must not lower existing trust.'}
  Check ((Fixture 'status').channels -eq 0) 'The actual call engine must be idle.'
  $beforeDb=DatabaseSnapshot 'before-fault';$beforeFiles=FileSnapshot;$beforeTasks=TaskSnapshot;$protected=FileSnapshot -Protected
  $installationProtected=Get-Content "$state\installation.json" -Raw|ConvertFrom-Json -AsHashtable;$installationProtected.Remove('Version')|Out-Null
  $script:priorCommands=@((Fixture 'status').commands|ForEach-Object command_uuid);$requestStarted=[DateTime]::UtcNow;Python 'request';$failure=WaitInstall 'rolled_back' 'failed' $requestStarted
  DownloadProof 'fault' $verified.fault;Check ((InstalledVersions '1.0.13') -eq $initialPid) 'The original ordinary installed13 worker must remain running after rollback.'
  $rollbackManager=ManagerReopened '1.0.13' $originalManager.Id $requestStarted;$facts.gates.manager_reopen_rollback='passed'
  $witness=Join-Path $contractDirectory ('canary-fault-witness-'+$scope+'.json');Check (Test-Path $witness) 'The signed fault must prove genuine post-deployment 1.0.14 code and normal migration/task setup before failing.'
  $seen=Get-Content $witness -Raw|ConvertFrom-Json;Check ($seen.nonce -eq $scope -and $seen.run_id -eq $env:GITHUB_RUN_ID -and $seen.state -eq 'post_deploy_fault' -and $seen.baseline_version -eq '1.0.13' -and $seen.target_version -eq '1.0.14') 'The late signed fault witness is incomplete.'
  foreach($flag in 'normal_migration_completed','backup_and_mail_deferred','candidate_actual_assemblies','original_worker_parent','services_stopped','new_noncustomer_table','new_noncustomer_file','owned_task_hidden_changed','owned_task_read_acl_changed'){Check ($seen.$flag -is [bool] -and $seen.$flag -eq $true) 'The late signed fault did not prove every required actual mutation.'}
  foreach($flag in 'customer_rows_modified','registration_sent','carrier_calls'){Check ($seen.$flag -is [bool] -and $seen.$flag -eq $false) 'The fault witness exceeded its noncustomer scope.'}
  $settings.owned_update_commands=@($failure.command);WriteJson $inputFile $settings
  Equal $beforeDb (DatabaseSnapshot 'after-fault') 'fault-database';Equal $beforeFiles (FileSnapshot) 'fault-files';Equal $beforeTasks (TaskSnapshot) 'fault-tasks'
  $failed=Get-Content "$state\updates\failed-install.json" -Raw|ConvertFrom-Json;Check ($failed.version -eq '1.0.14' -and $failed.asset_sha256 -eq $verified.fault.sha256) 'The worker did not record the exact failed signed package.'
  $facts.gates.fault_https_download='passed';$facts.gates.fault_rollback='passed';$facts.checks+='Actual installed13 SYSTEM worker full trusted HTTPS fault14 transfer, original key/URLs, late real14 witness and exact DB/roles/credentials/files/ACL/task rollback'
  $phase='higher-sequence normal14 full HTTPS download and natural restart'
  WriteJson (Join-Path $qa 'mode.json') @{mode='normal'};$script:priorCommands=@((Fixture 'status').commands|ForEach-Object command_uuid);$requestStarted=[DateTime]::UtcNow;Python 'request';$success=WaitInstall 'completed' 'completed' $requestStarted
  $restartDeadline=[DateTime]::UtcNow.AddSeconds(120);$newPid=0
  do{try{$newPid=InstalledVersions '1.0.14'}catch{};if($newPid -and $newPid -ne $initialPid){break};Start-Sleep -Milliseconds 500}while([DateTime]::UtcNow -lt $restartDeadline)
  Check ($newPid -gt 0 -and $newPid -ne $initialPid) 'The installed restart task must naturally select and run genuine updater14 without a manual service restart.'
  Check (!(Get-Process -Id $initialPid -ErrorAction SilentlyContinue)) 'The previous worker must naturally exit after its installed restart task executes.'
  $upgradedManager=ManagerReopened '1.0.14' $rollbackManager.Id $requestStarted;$facts.gates.manager_reopen_success='passed'
  $settings.owned_update_commands+=@($success.command);WriteJson $inputFile $settings
  DownloadProof 'normal' $verified.normal;Equal $beforeDb (DatabaseSnapshot 'after-normal') 'normal-database';Equal $protected (FileSnapshot -Protected) 'normal-protected-files'
  $afterProtected=Get-Content "$state\installation.json" -Raw|ConvertFrom-Json -AsHashtable;$afterProtected.Remove('Version')|Out-Null;Equal $installationProtected $afterProtected 'normal-installation-secrets'
  NormalTaskPreservation $beforeTasks (TaskSnapshot) $requestStarted;Check (!(Test-Path "$state\updates\failed-install.json")) 'Success must clear the exact failed-install marker.'
  $status=Get-Content "$state\updates\status.json" -Raw|ConvertFrom-Json;Check ($status.last_success_version -eq '1.0.14' -and $status.installed_version -eq '1.0.14') 'The naturally restarted real14 worker must retain last-success and current-version state.'
  Check ((Fixture 'status').channels -eq 0) 'The standalone updater must not create a native call.'
  $facts.gates.canary_build='passed';$facts.gates.normal_https_download='passed';$facts.gates.newer_upgrade='passed';$facts.gates.natural_updater_restart='passed';$facts.gates.protected_data='passed';$facts.checks+='Same installed13 worker higher-sequence full HTTPS normal14 transfer, genuine14 service/desktop/updater, completed command and natural SCM slot/PID restart; protected fictional data/private configuration/media/task security preserved'
  $facts.private_sequences=@($verified.fault.sequence,$verified.normal.sequence);$facts.canary_run_id=$CanaryRunId;$facts.fault_archive_sha256=$verified.fault.sha256;$facts.normal_archive_sha256=$verified.normal.sha256;$facts.state='passed'
 }
}catch{
 $facts.state='failed';$facts.failed_phase=$phase;$facts.error_type=$_.Exception.GetType().Name;$facts.source_basename=if($_.InvocationInfo.ScriptName){Split-Path -Leaf $_.InvocationInfo.ScriptName}else{'external_component'};$facts.source_line=[int]$_.InvocationInfo.ScriptLineNumber
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
    foreach($name in 'OpenWebPBX-Backups','OpenWebPBX-Cleanup','OpenWebPBX Outgoing Mail','OpenWebPBX Certificate Renewal','OpenWebPBX Pending Phone Certificate'){if(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue){Disable-ScheduledTask -TaskName $name|Out-Null}}
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
     if($site.State -ne 'Stopped'){$site.Stop()|Out-Null};if($pool.State -ne 'Stopped'){$pool.Stop()|Out-Null}
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
 $facts.cleanup=if($cleanup){'owned fixture rows/media, laboratory transport/trust/hosts/environment removed; disposable owned services stopped'}else{'failed'}
 if(!$cleanup){$facts.state='failed'}
 New-Item -ItemType Directory -Force $public|Out-Null;WriteJson (Join-Path $public 'qualification.json') $facts
 if($env:GITHUB_STEP_SUMMARY){('Standalone updater qualification: '+$facts.state+'. Public GitHub delivery/owner/carriers remain unqualified.')|Add-Content $env:GITHUB_STEP_SUMMARY}
}
if($facts.state -eq 'failed'){exit 1}
Write-Output ('Standalone updater stage '+$facts.state+'.')
