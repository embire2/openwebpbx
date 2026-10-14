#Requires -RunAsAdministrator
#Requires -Version 7.4
[CmdletBinding()]
param(
 [string]$NativeRunId,[string]$EngineRunId,[string]$PackageRoot,
 [switch]$DisposableHostedRunner
)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if(!$DisposableHostedRunner -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:RUNNER_OS -ne 'Windows' -or $env:GITHUB_REPOSITORY -ne 'embire2/openwebpbx'){
 throw 'Run only on the explicitly disposable Windows hosted runner of this repository.'
}
if([Environment]::OSVersion.Version.Major -ne 10 -or [Environment]::OSVersion.Version.Build -lt 26100){throw 'The suite requires Windows Server 2025.'}
$source=Split-Path $PSScriptRoot -Parent
$work=Join-Path $env:RUNNER_TEMP ('openwebpbx-suite-'+[Guid]::NewGuid().ToString('N'))
$public=Join-Path $env:RUNNER_TEMP 'openwebpbx-suite-public'
$state=Join-Path $env:ProgramData 'OpenWebPBX';$configuration=Join-Path $env:ProgramData 'fusionpbx'
$domain='windowsqa.example.invalid';$installed=$false;$hostAdded=$false;$sftp=$null;$acceptanceFile=$null;$phase='source inputs'
$facts=[ordered]@{schema=1;platform='Windows Server 2025 x64';source_commit=$env:GITHUB_SHA;run_id=$env:GITHUB_RUN_ID;state='running';checks=@();gates=[ordered]@{fresh='pending';backups='pending';native_sip_audio='unqualified';direct_113_helper_reapply='unqualified';direct_failure_rollback='unqualified';restore_gate_startup='unqualified';manager_reopen_success='unqualified';manager_reopen_rollback='unqualified';installed_upgrade='unqualified';failure_rollback='unqualified';legacy_106_upgrade='unqualified';outside_acme='unqualified'};cleanup='pending'}
function PrivateDirectory([string]$Path){
 New-Item -ItemType Directory -Force -Path $Path|Out-Null
 & icacls.exe $Path /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F'|Out-Null
 if($LASTEXITCODE){throw 'Private qualification storage could not be prepared.'}
}
function Hash([string]$Path){return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function SafeRelative([string]$Path){
 if(!$Path -or $Path.StartsWith('/') -or $Path -match '[\\<>:"|?*\x00-\x1f\x7f]'){throw 'A build inventory contains a forbidden Windows path.'}
 foreach($part in $Path.Split('/')){
  if(!$part -or $part -in '.','..' -or $part -match '[. ]$' -or $part -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)'){throw 'A build inventory contains an unsafe Windows path component.'}
 }
 return $Path
}
function RandomSecret { $bytes=New-Object byte[] 32;$rng=[Security.Cryptography.RandomNumberGenerator]::Create();try{$rng.GetBytes($bytes)}finally{$rng.Dispose()};return ([BitConverter]::ToString($bytes)).Replace('-','').ToLowerInvariant() }
function CheckedPython([string[]]$Arguments){& python @Arguments|Out-Host;if($LASTEXITCODE){throw 'A pinned package preparation operation failed.'}}
function PublishFacts {
 New-Item -ItemType Directory -Force -Path $public|Out-Null
 [IO.File]::WriteAllText((Join-Path $public 'qualification.json'),($facts|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
}
function SafeFailureFields($Record){
 $safe=@{}
 foreach($field in 'failed_phase','error_type','source_basename','active_case','command_basename','caller_basename'){
  $value=$Record.$field
  $pattern=if($field -in 'source_basename','command_basename','caller_basename'){'^[A-Za-z0-9_.-]+$'}else{'^[A-Za-z0-9_.+ /()-]+$'}
  if($value -is [string] -and $value.Length -le 160 -and $value -match $pattern){$safe[$field]=$value}
 }
 if(($Record.source_line -is [int] -or $Record.source_line -is [long]) -and $Record.source_line -gt 0 -and $Record.source_line -lt 100000){$safe.source_line=[int]$Record.source_line}
 if(($Record.caller_line -is [int] -or $Record.caller_line -is [long]) -and $Record.caller_line -gt 0 -and $Record.caller_line -lt 100000){$safe.caller_line=[int]$Record.caller_line}
 if(($Record.command_exit -is [int] -or $Record.command_exit -is [long]) -and $Record.command_exit -ge [int]::MinValue -and $Record.command_exit -le [int]::MaxValue){$safe.command_exit=[int]$Record.command_exit}
 return $safe
}
function Api([string]$Endpoint){
 if(!$env:GH_TOKEN){throw 'The repository-scoped artifact token is unavailable.'}
 Invoke-RestMethod -Uri ('https://api.github.com/repos/embire2/openwebpbx/'+$Endpoint) -Headers @{Authorization=('Bearer '+$env:GH_TOKEN);Accept='application/vnd.github+json';'X-GitHub-Api-Version'='2022-11-28'}
}
function ExpandSafe([string]$Archive,[string]$Destination){
 Add-Type -AssemblyName System.IO.Compression.FileSystem
 $zip=[IO.Compression.ZipFile]::OpenRead($Archive);$seen=@{};$bytes=0L
 try{
  if($zip.Entries.Count -gt 100000){throw 'An input archive has too many entries.'}
  foreach($entry in $zip.Entries){
   $relative=$entry.FullName
   if($relative -match '(^/|\\|:|(^|/)\.\.?(/|$)|[\x00-\x1f]|(^|/)[^/]*[. ](/|$))' -or $relative -match '(^|/)(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])([./]|$)' -or (($entry.ExternalAttributes -shr 16) -band 61440) -eq 40960 -or $seen.ContainsKey($relative.ToLowerInvariant())){throw 'An input archive contains unsafe or colliding paths.'}
   $seen[$relative.ToLowerInvariant()]=$true;$bytes+=$entry.Length
   if($bytes -gt 24GB){throw 'An input archive exceeds its size limit.'}
   if($relative.EndsWith('/')){continue}
   $target=Join-Path $Destination $relative
   New-Item -ItemType Directory -Force (Split-Path $target -Parent)|Out-Null
   [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$target,$false)
  }
 }finally{$zip.Dispose()}
}
function Artifact([string]$RunId,[string]$Kind){
 if($RunId -notmatch '^[0-9]+$'){throw 'Artifact run IDs must be numeric.'}
 $run=Api ('actions/runs/'+$RunId)
 $workflow=if($Kind -eq 'music'){'.github/workflows/windows-suite.yml'}else{'.github/workflows/windows-'+$Kind+'.yml'}
 if($run.repository.full_name -ne 'embire2/openwebpbx' -or $run.head_repository.full_name -ne 'embire2/openwebpbx' -or $run.event -ne 'workflow_dispatch' -or $run.path -ne $workflow -or $run.head_sha -notmatch '^[a-f0-9]{40}$'){throw 'The input run does not belong to the expected repository workflow.'}
 if($Kind -eq 'music'){if($RunId -ne $env:GITHUB_RUN_ID -or $run.head_sha -ne $env:GITHUB_SHA){throw 'Music must come from this exact suite source.'}}
 elseif($run.status -ne 'completed' -or $run.conclusion -ne 'success'){throw 'A source build did not complete successfully.'}
 $prefix=if($Kind -eq 'music'){'openwebpbx-windows-suite-music-'}else{'openwebpbx-windows-'+$Kind+'-'}
 $artifacts=@((Api ('actions/runs/'+$RunId+'/artifacts?per_page=100')).artifacts|Where-Object {$_.name.StartsWith($prefix) -and $_.name.EndsWith('-'+$RunId) -and !$_.expired})
 if($artifacts.Count -ne 1 -or $artifacts[0].digest -notmatch '^sha256:[a-f0-9]{64}$' -or $artifacts[0].size_in_bytes -gt 8GB){throw 'One bounded hash-verified artifact is required.'}
 $artifact=$artifacts[0];$archive=Join-Path $work ($Kind+'.zip')
 # Authorization is sent only to api.github.com. Follow its one-minute signed
 # HTTPS storage URL with a separate client that has no repository token.
 $handler=[Net.Http.HttpClientHandler]::new();$handler.AllowAutoRedirect=$false;$client=[Net.Http.HttpClient]::new($handler)
 $client.DefaultRequestHeaders.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$env:GH_TOKEN)
 $client.DefaultRequestHeaders.UserAgent.ParseAdd('OpenWebPBX-Windows-Qualification')
 try{$response=$client.GetAsync('https://api.github.com/repos/embire2/openwebpbx/actions/artifacts/'+$artifact.id+'/zip').GetAwaiter().GetResult();if([int]$response.StatusCode -ne 302){throw 'Artifact storage did not supply its signed redirect.'};$location=$response.Headers.Location.AbsoluteUri}finally{$client.Dispose();$handler.Dispose()}
 if(([Uri]$location).Scheme -ne 'https'){throw 'Artifact storage must use HTTPS.'}
 Invoke-WebRequest -Uri $location -MaximumRedirection 0 -OutFile $archive
 if((Get-Item $archive).Length -ne $artifact.size_in_bytes -or (Hash $archive) -ne $artifact.digest.Substring(7)){throw 'The GitHub artifact archive digest differs.'}
 $destination=Join-Path $work $Kind;PrivateDirectory $destination;ExpandSafe $archive $destination
 return @{directory=$destination;run=$run;artifact=$artifact}
}
function VerifyInventory([string]$Directory,$Files){
 $count=0;$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
 foreach($entry in $Files.PSObject.Properties){
  $relative=SafeRelative $entry.Name
  if(!$seen.Add($relative) -or $entry.Value -notmatch '^[a-f0-9]{64}$'){throw 'A build file inventory is invalid or has colliding Windows paths.'}
  $path=Join-Path $Directory $relative
  if(!(Test-Path -LiteralPath $path -PathType Leaf) -or ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint) -or (Hash $path) -ne $entry.Value){throw 'A build file failed exact hash verification.'};$count++
 }
 if($count -lt 1){throw 'A build inventory is empty.'}
 return $count
}
function PreparePackage {
 $native=Artifact $NativeRunId 'native';$engine=Artifact $EngineRunId 'engine';$music=Artifact $env:GITHUB_RUN_ID 'music'
 $inputs=Get-Content (Join-Path $native.directory 'source-inputs.json') -Raw|ConvertFrom-Json
 $version=(Get-Content (Join-Path $source 'VERSION') -Raw).Trim()
 if($inputs.version -ne $version -or $inputs.source_commit -ne $native.run.head_sha){throw 'Native source/version evidence is inconsistent.'}
 $expected=@(git -C $source ls-files -- platform packaging/updates/release-public.pem VERSION)
 $provided=@($inputs.source_inputs|ForEach-Object path)
 if($LASTEXITCODE -or $expected.Count -lt 40 -or @(Compare-Object ($expected|Sort-Object) ($provided|Sort-Object)).Count){throw 'Native source input inventory is incomplete.'}
 foreach($entry in $inputs.source_inputs){if((Hash (Join-Path $source $entry.path)) -ne $entry.sha256){throw 'Rebuild native binaries: current source inputs differ from their artifact.'}}
 foreach($line in Get-Content (Join-Path $native.directory 'SHA256SUMS')){if($line -notmatch '^([a-f0-9]{64})  (.+)$' -or (Hash (Join-Path $native.directory $Matches[2])) -ne $Matches[1]){throw 'A native artifact file failed its inventory hash.'}}
 $nativeManifest=Get-Content (Join-Path $engine.directory 'engine/native-manifest.json') -Raw|ConvertFrom-Json
 if($nativeManifest.schema -ne 1 -or !$nativeManifest.codec_not_in_release -or (Hash (Join-Path $source 'packaging/freeswitch/restore-registration.patch')) -ne $nativeManifest.patch_sha256 -or (Hash (Join-Path $engine.directory 'source/source-manifest.json')) -ne $nativeManifest.source_manifest_sha256 -or (Hash (Join-Path $engine.directory 'source/dependency-lock.json')) -ne $nativeManifest.dependency_lock_sha256){throw 'The native registrar manifest differs from current source pins.'}
 $null=VerifyInventory (Join-Path $engine.directory 'engine') $nativeManifest.files
 $codec=Join-Path $engine.directory 'codec-source';$codecManifest=Get-Content (Join-Path $codec 'codec-source-manifest.json') -Raw|ConvertFrom-Json
 if($codecManifest.schema -ne 1 -or $codecManifest.generated_binary_included -ne $false -or $codecManifest.codec_distribution_status -ne 'local-source-build-only' -or (Hash (Join-Path $codec 'core-exports.py')) -ne (Hash (Join-Path $source 'packaging/freeswitch/core-exports.py')) -or $codecManifest.core_export_helper_sha256 -ne (Hash (Join-Path $codec 'core-exports.py')) -or $codecManifest.source_manifest_sha256 -ne (Hash (Join-Path $codec 'source/source-manifest.json'))){throw 'The public codec-source/helper provenance differs from current verified inputs.'}
 & git -C $source fetch --quiet --depth=1 https://github.com/embire2/openwebpbx.git $engine.run.head_sha
 if($LASTEXITCODE){throw 'The exact engine workflow source could not be checked.'}
 foreach($file in @('packaging/freeswitch/Build-WindowsNative.ps1','packaging/freeswitch/prepare-windows-native.py','packaging/freeswitch/windows-native-dependencies.py','packaging/freeswitch/windows-native-inputs.json','packaging/freeswitch/core-exports.py','packaging/freeswitch/restore-registration.patch','packaging/codecs/bcg729/buffer-safety.patch','tests/pbx_bcg729_codec.c')){
  $current=(& git -C $source hash-object $file).Trim();$built=(& git -C $source rev-parse ($engine.run.head_sha+':'+$file)).Trim()
  if($LASTEXITCODE -or $current -ne $built){throw 'Rebuild the native engine: current recipe inputs differ from its build.'}
 }
 $backup=Join-Path $work 'backup-runtime';CheckedPython @((Join-Path $source 'packaging/windows/build-backup-runtime.py'),'--cache',(Join-Path $work 'upstream-cache'),'--output',$backup,'--sources',(Join-Path $work 'backup-source'))
 $acmeArchive=Join-Path $work 'simple-acme.zip';Invoke-WebRequest 'https://github.com/simple-acme/simple-acme/releases/download/v2.4.1/simple-acme.v2.4.1.2444.win-x64.trimmed.zip' -OutFile $acmeArchive
 $acme=Join-Path $work 'acme';CheckedPython @((Join-Path $source 'packaging/windows/build-acme-runtime.py'),'--archive',$acmeArchive,'--output',$acme)
 $output=Join-Path $work 'package';CheckedPython @((Join-Path $source 'packaging/build-release.py'),'--target','windows','--server',(Join-Path $native.directory 'server'),'--updater',(Join-Path $native.directory 'updater'),'--desktop',(Join-Path $native.directory 'desktop'),'--engine',(Join-Path $engine.directory 'engine'),'--backup-runtime',$backup,'--acme',$acme,'--music',$music.directory,'--codec-source',(Join-Path $codec 'source'),'--output',$output)
 $archives=@(Get-ChildItem $output -Filter '*.zip' -File);if($archives.Count -ne 1){throw 'One candidate package is required.'}
 $expanded=Join-Path $work 'expanded';PrivateDirectory $expanded;ExpandSafe $archives[0].FullName $expanded
 $roots=@(Get-ChildItem $expanded -Directory);if($roots.Count -ne 1){throw 'The candidate package has an ambiguous root.'}
 $facts.artifacts=@{native_run=$NativeRunId;native_digest=$native.artifact.digest;engine_run=$EngineRunId;engine_digest=$engine.artifact.digest;music_digest=$music.artifact.digest;candidate_sha256=(Hash $archives[0].FullName)}
 return $roots[0].FullName
}
function LoopbackSftp {
 $capability=Get-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
 if($capability.State -ne 'Installed'){$result=Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0';if($result.RestartNeeded){throw 'The isolated SFTP server needs a restart.'}}
 $id=[Guid]::NewGuid().ToString('N').Substring(0,10);$name='owbqa'+$id;$directory='C:\OpenWebBackupQA'+$id
 $secret=ConvertTo-SecureString ('A9!'+(RandomSecret)) -AsPlainText -Force
 $user=New-LocalUser -Name $name -Password $secret -Description 'Owned disposable backup SFTP qualification' -AccountNeverExpires -PasswordNeverExpires
 $script:sftp=@{name=$name;directory=$directory;task=('OpenWebPBX-SFTP-QA-'+$id);config=(Join-Path $work 'sshd_config')}
 Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $name
 New-Item -ItemType Directory -Path $directory|Out-Null
 & icacls.exe $directory /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' ($name+':(OI)(CI)M')|Out-Null
 if($LASTEXITCODE){throw 'The isolated SFTP receiver permissions could not be prepared.'}
 $ssh=Join-Path $env:SystemRoot 'System32/OpenSSH';$hostkey=Join-Path $work 'hostkey';$identity=Join-Path $work 'identity'
 foreach($key in $hostkey,$identity){& "$ssh\ssh-keygen.exe" -q -t ed25519 -N '' -f $key;if($LASTEXITCODE){throw 'The isolated SSH identity could not be prepared.'}}
 & icacls.exe $hostkey /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F'|Out-Null
 if($LASTEXITCODE){throw 'The isolated SSH host key permissions could not be secured.'}
 & icacls.exe $hostkey /setowner '*S-1-5-18'|Out-Null
 if($LASTEXITCODE){throw 'The isolated SSH host key owner could not be secured.'}
 $authorized=Join-Path $work 'authorized_keys';Copy-Item ($identity+'.pub') $authorized
 & icacls.exe $authorized /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' ('*'+$user.SID.Value+':R')|Out-Null
 if($LASTEXITCODE){throw 'The isolated SSH public key read permissions could not be secured.'}
 & icacls.exe $authorized /setowner ('*'+$user.SID.Value)|Out-Null
 if($LASTEXITCODE){throw 'The isolated SSH public key owner could not be secured.'}
 $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop()
 $config=Join-Path $work 'sshd_config';$content=@("Port $port",'ListenAddress 127.0.0.1',('HostKey '+$hostkey.Replace('\','/')),('PidFile '+(Join-Path $work 'sshd.pid').Replace('\','/')),('AuthorizedKeysFile '+$authorized.Replace('\','/')),'PasswordAuthentication no','PubkeyAuthentication yes','StrictModes yes',('AllowUsers '+$name),'Subsystem sftp internal-sftp','ForceCommand internal-sftp','AllowTcpForwarding no','AllowAgentForwarding no','PermitTunnel no')
 [IO.File]::WriteAllText($config,($content -join "`n")+"`n",[Text.UTF8Encoding]::new($false))
 # Run this separate receiver as SYSTEM without changing the machine's normal
 # sshd service/configuration. Win32 sshd uses a fixed SCM service name.
 $action=New-ScheduledTaskAction -Execute "$ssh\sshd.exe" -Argument ('-D -f "'+$config+'" -E "'+(Join-Path $work 'sshd-private.log')+'"')
 $principal=New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
 $settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 2) -MultipleInstances IgnoreNew
 Register-ScheduledTask -TaskName $sftp.task -Action $action -Principal $principal -Settings $settings -Force|Out-Null;Start-ScheduledTask -TaskName $sftp.task
 $deadline=[DateTime]::UtcNow.AddSeconds(30);$connected=$false
 do{$socket=[Net.Sockets.TcpClient]::new();try{$socket.Connect('127.0.0.1',$port);$connected=$true}catch{Start-Sleep -Milliseconds 200}finally{$socket.Dispose()}}while(!$connected -and [DateTime]::UtcNow -lt $deadline)
 if(!$connected){throw 'The separate loopback SFTP server did not start.'}
 $json=Join-Path $work 'sftp.json';$values=@{sftp_host='127.0.0.1';sftp_port=$port;sftp_user=$name;sftp_directory=('/OpenWebBackupQA'+$id);sftp_host_key=(Get-Content ($hostkey+'.pub') -Raw).Trim();identity=(Get-Content $identity -Raw);observed_directory=$directory}
 [IO.File]::WriteAllText($json,($values|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
 return $json
}
function AcceptanceHook([string]$Name,[string]$Report){
 $script=Join-Path $PSScriptRoot $Name
 if(!(Test-Path -LiteralPath $script -PathType Leaf)){return $null}
 $failure=$null
 try{& $script -PackageRoot $PackageRoot -DisposableHostedRunner -InputPath $acceptanceFile -ReportPath $Report}catch{$failure=$_}
 if(!(Test-Path -LiteralPath $Report)){if($failure){throw $failure};throw 'An optional native acceptance hook did not finish.'}
 $record=Get-Content -LiteralPath $Report -Raw|ConvertFrom-Json
 if($record.state -ne 'passed'){
  $facts.hook_failure=SafeFailureFields $record
 }
 if($failure){throw $failure}
 if($record.state -ne 'passed'){throw 'An optional native acceptance hook did not pass.'}
 return $record
}
try{
 PrivateDirectory $work;PublishFacts
 if((Test-Path "$configuration\config.conf") -or (Test-Path "$state\installation.json") -or (Get-Service OpenWebPBX -ErrorAction SilentlyContinue)){throw 'The ephemeral machine already contains a PBX; it is not an empty suite target.'}
 if(!$PackageRoot){$PackageRoot=PreparePackage}
 Remove-Item Env:\GH_TOKEN -ErrorAction SilentlyContinue
 $PackageRoot=[IO.Path]::GetFullPath($PackageRoot);$release=Get-Content (Join-Path $PackageRoot 'release-manifest.json') -Raw|ConvertFrom-Json
 if($release.version -ne (Get-Content (Join-Path $source 'VERSION') -Raw).Trim()){throw 'The candidate package release differs from source.'}
 $mapped=VerifyInventory $PackageRoot $release.files;$facts.checks+=('Exact candidate package inventory: '+$mapped+' files')
 $phase='fresh installation';$admin='windowsqa-'+[Guid]::NewGuid().ToString('N').Substring(0,12)+'@example.invalid';$password=ConvertTo-SecureString (RandomSecret) -AsPlainText -Force
 $hosts=Join-Path $env:SystemRoot 'System32/drivers/etc/hosts';$marker='# OpenWebPBX-WindowsSuite-'+$env:GITHUB_RUN_ID
 if([IO.File]::ReadAllText($hosts) -match '(?im)^\s*[^#\r\n]+\s+windowsqa\.example\.invalid(?:\s|$)'){throw 'The suite hostname already has an unrelated hosts entry.'}
 [IO.File]::AppendAllText($hosts,"`r`n127.0.0.1 $domain $marker`r`n",[Text.UTF8Encoding]::new($false));$hostAdded=$true
 $installed=$true
 $installInput=Join-Path $work 'install-input.json';$ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($password)
 try{$plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)}
 [IO.File]::WriteAllText($installInput,(@{package_root=$PackageRoot;admin_email=$admin;admin_password=$plain;domain=$domain;error_path=(Join-Path $work 'install-failure.json')}|ConvertTo-Json),[Text.UTF8Encoding]::new($false));$plain=$null
 $launcher=Join-Path $work 'install.ps1';$launchCode=@'
param([string]$InputPath)
$ErrorActionPreference='Stop';$record=Get-Content -LiteralPath $InputPath -Raw|ConvertFrom-Json
try{
 if($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted'){throw 'Disposable hosted runner required.'}
 $password=ConvertTo-SecureString $record.admin_password -AsPlainText -Force
 & (Join-Path $record.package_root 'Install-OpenWebPBX.ps1') -RestoreServer -LocalCertificate -DomainName $record.domain -PublicAddress '127.0.0.1' -AdminEmail $record.admin_email -AdminPassword $password
 if(!$?){throw 'The installed Windows helper did not finish.'}
 exit 0
}catch{
 $safe=@{error_type=$_.Exception.GetType().FullName;source_basename=(Split-Path -Leaf $_.InvocationInfo.ScriptName);source_line=[int]$_.InvocationInfo.ScriptLineNumber}
 foreach($field in 'command_basename','command_exit','caller_basename','caller_line'){
  if($_.Exception.Data.Contains($field)){$safe[$field]=$_.Exception.Data[$field]}
 }
 [IO.File]::WriteAllText($record.error_path,($safe|ConvertTo-Json),[Text.UTF8Encoding]::new($false));exit 1
}
'@
 [IO.File]::WriteAllText($launcher,$launchCode,[Text.UTF8Encoding]::new($false))
 $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe';$start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $start.Environment['PSModulePath']=(Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/Modules')+';'+(Join-Path $env:ProgramFiles 'WindowsPowerShell/Modules')
 foreach($arg in '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$launcher,'-InputPath',$installInput){$start.ArgumentList.Add($arg)}
 $process=[Diagnostics.Process]::Start($start);$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
 if(!$process.WaitForExit(2400000)){throw 'The real installation is still running; its private state must not be interrupted.'}
 [IO.File]::WriteAllText((Join-Path $work 'install-private.out'),$stdout.GetAwaiter().GetResult());[IO.File]::WriteAllText((Join-Path $work 'install-private.err'),$stderr.GetAwaiter().GetResult());$exit=$process.ExitCode;$process.Dispose();Remove-Item -LiteralPath $installInput -Force
 if($exit){if(Test-Path (Join-Path $work 'install-failure.json')){$facts.helper_failure=SafeFailureFields (Get-Content (Join-Path $work 'install-failure.json') -Raw|ConvertFrom-Json)};throw 'The real candidate installation failed.'}
 $completed=Get-Content "$state\installation.json" -Raw|ConvertFrom-Json
 if(!$completed.Completed -or !$completed.RestoreServer -or $completed.AdminEmail -ne $admin){throw 'The candidate factory identity or completed state is invalid.'}
 foreach($service in 'OpenWebPBX-Database','OpenWebPBX','OpenWebPBXUpdater','FreeSWITCH'){if((Get-Service $service).Status -ne 'Running'){throw 'A candidate native service is not running.'}}
 & (Join-Path $PackageRoot 'Install-NativeEngine.ps1') -PackageRoot $PackageRoot -Check
 if(!$?){throw 'The installed native call-engine inventory differs.'}
 $facts.gates.fresh='passed';$facts.checks+=('Real restore-ready fresh installation/services/native engine hash preservation')
 $acceptanceFile=Join-Path $work 'acceptance-input.json';$ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($password)
 try{$plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)}
 $acceptance=@{schema=1;run_id=$env:GITHUB_RUN_ID;restore_server=$true;admin_email=$admin;admin_password=$plain;public_url=('https://'+$domain+':8443');package_root=$PackageRoot;source_root=$source;private_state_root=$state;python='C:/OpenWebPBX/backup-runtime/python.exe';evidence_directory=(Join-Path $work 'native-private-evidence')}
 [IO.File]::WriteAllText($acceptanceFile,($acceptance|ConvertTo-Json),[Text.UTF8Encoding]::new($false));$plain=$null;$acceptance=$null
 $phase='native acceptance hook';$native=AcceptanceHook 'windows-native-acceptance.ps1' (Join-Path $work 'native-acceptance.json')
 if($native){$facts.gates.native_sip_audio='passed'}
 $phase='upgrade acceptance hook';$upgrade=AcceptanceHook 'windows-upgrade-acceptance.ps1' (Join-Path $work 'upgrade-acceptance.json')
 if($upgrade){foreach($gate in 'direct_113_helper_reapply','direct_failure_rollback','restore_gate_startup','manager_reopen_success','manager_reopen_rollback','installed_upgrade','failure_rollback','legacy_106_upgrade'){if($upgrade.gates.$gate -eq 'passed'){$facts.gates[$gate]='passed'}}}
 $phase='backup qualification';$sftpConfig=LoopbackSftp
 & (Join-Path $PSScriptRoot 'windows-backups.ps1') -PackageRoot $PackageRoot -AdminEmail $admin -AdminPassword $password -DisposableFactory -SftpConfig $sftpConfig
 if(!$?){throw 'Actual Windows encrypted-backup qualification failed.'}
 $backup=Get-Content "$state\backup-qualification\report.json" -Raw|ConvertFrom-Json
 if($backup.state -ne 'passed' -or !$backup.fully_qualified){throw 'Actual backup/SFTP qualification is incomplete.'}
 $facts.gates.backups='passed';$facts.checks+=@($backup.checks)
 $missing=@($facts.gates.GetEnumerator()|Where-Object {$_.Value -ne 'passed'}|ForEach-Object Key)
 $facts.state=if($missing.Count){'partial'}else{'passed'};$facts.unqualified=$missing
}catch{
 $facts.state='failed';$facts.failed_phase=$phase
 $facts.error_type=$_.Exception.GetType().FullName
 $facts.source_basename=if($_.InvocationInfo.ScriptName){Split-Path -Leaf $_.InvocationInfo.ScriptName}else{'windows-suite.ps1'}
 $facts.source_line=[int]$_.InvocationInfo.ScriptLineNumber
 Write-Error ('Disposable Windows suite failed in '+$phase+'. No passing result is implied.') -ErrorAction Continue
}finally{
 Remove-Item Env:\GH_TOKEN -ErrorAction SilentlyContinue
 $cleanup=$true
 try{
  if($installed){
   $cleanupLock=$null
   try{$cleanupLock=[IO.File]::Open("$state\upgrade.lock",'OpenOrCreate','ReadWrite','None')}catch{throw 'An owned transaction is still running; cleanup must not interrupt it.'}
   $cleanupLock.Dispose()
   # Shutdown honors activation holds. This owned ephemeral instance is never
   # restarted by cleanup, and no customer/factory hold marker is removed.
   foreach($name in 'OpenWebPBX-Backups','OpenWebPBX-Cleanup','OpenWebPBX Certificate Renewal','OpenWebPBX Pending Phone Certificate','OpenWebPBX Outgoing Mail'){if(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue){Disable-ScheduledTask -TaskName $name|Out-Null}}
   foreach($name in 'OpenWebPBXUpdater','OpenWebPBX','FreeSWITCH'){if(Get-Service $name -ErrorAction SilentlyContinue){Set-Service $name -StartupType Disabled;Stop-Service $name -Force -ErrorAction Stop}}
   $owned=Join-Path $state 'backup-qualification/owned-fixture.json'
   if(Test-Path -LiteralPath $owned){
    $record=Get-Content -LiteralPath $owned -Raw|ConvertFrom-Json
    if($record.fixture_domain -notmatch '^[a-f0-9-]{36}$' -or $record.fixture_realm -notmatch '^backup-native-[a-f0-9]{12}\.invalid$'){throw 'The owned backup fixture identity is invalid.'}
    $prior=$env:OPENWEB_WINDOWS_BACKUP_TEST;$env:OPENWEB_WINDOWS_BACKUP_TEST='1'
    try{Push-Location 'C:/OpenWebPBX/web';try{& 'C:/OpenWebPBX/php/php.exe' (Join-Path $PSScriptRoot 'windows-backups-fixture.php') clear-held $owned;if($LASTEXITCODE){throw 'The owned restored backup fixture could not be cleared.'}}finally{Pop-Location}}
    finally{if($null -eq $prior){Remove-Item Env:\OPENWEB_WINDOWS_BACKUP_TEST -ErrorAction SilentlyContinue}else{$env:OPENWEB_WINDOWS_BACKUP_TEST=$prior}}
    foreach($path in (Join-Path $state ('storage/openwebpbx/'+$record.fixture_domain)),(Join-Path $state 'storage/recordings/backup-fixture.wav'),'C:/Program Files/FreeSWITCH/sounds/openwebpbx/backup-fixture.wav'){Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue}
   }
   & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command '$env:PSModulePath=($PSHOME+"\Modules")+";"+($env:ProgramFiles+"\WindowsPowerShell\Modules");$ErrorActionPreference="Stop";if(Test-Path ($PSHOME+"\Modules\WebAdministration\WebAdministration.psd1")){Import-Module WebAdministration;if(Test-Path IIS:\Sites\OpenWebPBX){Stop-Website OpenWebPBX};if(Test-Path IIS:\AppPools\OpenWebPBX){Stop-WebAppPool OpenWebPBX}}' *> $null
   if($LASTEXITCODE){throw 'Owned IIS cleanup did not finish.'}
   if(Get-Service OpenWebPBX-Database -ErrorAction SilentlyContinue){Stop-Service OpenWebPBX-Database -Force}
  }
  if($sftp){
   if(Get-ScheduledTask -TaskName $sftp.task -ErrorAction SilentlyContinue){Stop-ScheduledTask -TaskName $sftp.task;Unregister-ScheduledTask -TaskName $sftp.task -Confirm:$false}
   foreach($process in @(Get-CimInstance Win32_Process -Filter "Name='sshd.exe'")){if($process.CommandLine -and $process.CommandLine.Contains($sftp.config)){Stop-Process -Id $process.ProcessId -Force}}
   Remove-LocalUser -Name $sftp.name -ErrorAction SilentlyContinue;Remove-Item -LiteralPath $sftp.directory -Recurse -Force -ErrorAction SilentlyContinue
  }
  if($hostAdded){$text=[IO.File]::ReadAllText($hosts);$text=[regex]::Replace($text,'(?m)^127\.0\.0\.1 windowsqa\.example\.invalid '+[regex]::Escape($marker)+'\r?\n','');[IO.File]::WriteAllText($hosts,$text,[Text.UTF8Encoding]::new($false))}
 }catch{
  $cleanup=$false
  $facts.cleanup_failure=SafeFailureFields ([pscustomobject]@{error_type=$_.Exception.GetType().FullName;source_basename=(Split-Path -Leaf $_.InvocationInfo.ScriptName);source_line=[int]$_.InvocationInfo.ScriptLineNumber})
 }
 if($acceptanceFile){Remove-Item -LiteralPath $acceptanceFile -Force -ErrorAction SilentlyContinue}
 $facts.cleanup=if($cleanup){'owned services stopped, SFTP receiver/account removed, hostname removed, activation holds preserved'}else{'failed'}
 if(!$cleanup){if($facts.state -ne 'failed'){$facts.failed_phase='owned cleanup'};$facts.state='failed'}
 PublishFacts
 # Only the acceptance allowlist above is uploaded. This includes no backup,
 # machine configuration, PostgreSQL data, PEM/PFX, auth ID, password or logs.
 if($env:GITHUB_STEP_SUMMARY){('Windows suite state: '+$facts.state+'. Missing gates: '+(@($facts.unqualified) -join ', ')+'.')|Add-Content $env:GITHUB_STEP_SUMMARY}
}
if($facts.state -eq 'failed'){exit 1}
Write-Output ('Windows suite '+$facts.state+'. Actual checks are recorded separately from unqualified gates.')
