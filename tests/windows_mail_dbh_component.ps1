# Only the original accepted public20 installer plus a separate owned DBh probe.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$HelperRoot,[Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string]$HelperRef,[Parameter(Mandatory)][string]$PythonExecutable)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
if(!$IsWindows -or $env:GITHUB_ACTIONS-cne 'true' -or $env:RUNNER_ENVIRONMENT-cne 'github-hosted' -or $env:GITHUB_REPOSITORY-cne 'embire2/openwebpbx'){throw 'Disposable hosted Windows only.'}
if((Get-CimInstance Win32_OperatingSystem).Caption-notmatch 'Windows Server 2025'){throw 'Actual Windows Server2025 required.'}
foreach($path in 'C:\OpenWebPBX',(Join-Path $env:ProgramData 'OpenWebPBX'),(Join-Path $env:ProgramData 'fusionpbx'),'C:\Program Files\FreeSWITCH'){if(Test-Path -LiteralPath $path){throw 'A new empty machine is required.'}}
if(@(Get-Service -Name 'OpenWebPBX*','FreeSWITCH' -ErrorAction SilentlyContinue).Count){throw 'Existing PBX services are outside this component.'}
$source=Split-Path $PSScriptRoot -Parent;$helper=[IO.Path]::GetFullPath($HelperRoot)
foreach($pair in @(@($source,$env:GITHUB_SHA),@($helper,$HelperRef))){$actual=(& git -C $pair[0] rev-parse HEAD).Trim();if($LASTEXITCODE-or $actual-cne $pair[1]-or (& git -C $pair[0] status --porcelain)){throw 'An exact clean immutable checkout is required.'}}
if(![IO.Path]::IsPathFullyQualified($PythonExecutable)-or $PythonExecutable-notmatch '\.exe$'-or $PythonExecutable-match '\\WindowsApps\\|\\py\.exe$'){throw 'Use the exact pinned setup-python output.'}
function Hash([string]$Path){return(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Private([string]$Path){if(Test-Path -LiteralPath $Path){throw 'Retain prior private evidence; a fresh directory is required.'};New-Item -ItemType Directory -Path $Path -Force|Out-Null;& icacls.exe $Path /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F'|Out-Null;if($LASTEXITCODE){throw 'Private storage refused.'}}
$scope=[Guid]::NewGuid().ToString('N').Substring(0,24);$work=Join-Path $env:RUNNER_TEMP ('mail-dbh-work-'+$scope);$evidence=Join-Path $env:RUNNER_TEMP 'mail-dbh-evidence';Private $work;Private $evidence
function Save([string]$Name,$Value){$raw=[Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 16));if($raw.Length-gt 65536){throw 'Closed diagnostic exceeds limit.'};[IO.File]::WriteAllBytes((Join-Path $evidence ($Name+'.safe.json')),$raw)}
$report=[ordered]@{schema=1;state='failed';scope='actual Windows native Dbh only; no calls or SMTP';base_version='1.0.20';base_archive_sha256='9a45d51c1ee1d1f985062fc16fb0cdfaea43aee6c1a7a540a7b820852e776522';source_commit=$env:GITHUB_SHA;helper_source_commit=$HelperRef;stage='public20';cleanup='unverified';release_qualified=$false;historical_windows_cause_proven=$false;native_async_lua_closed=$false}
$installed=$false;$knownClosed=$true;$fixture=$null;$services=@{};$primary=$null;$setupAttempted=$false;$engineProcess=$null
function Probe([string]$Action){
 $directory=Join-Path $evidence $Action;Private $directory;$info=[Diagnostics.ProcessStartInfo]::new($PythonExecutable);$info.UseShellExecute=$false;$info.CreateNoWindow=$true
 foreach($arg in @('-I','-B',(Join-Path $PSScriptRoot 'windows_mail_dbh_child.py'),$Action,$directory,$fixture)){[void]$info.ArgumentList.Add($arg)}
 $proc=$null;$script:knownClosed=$false
 try{$proc=[Diagnostics.Process]::Start($info);$started=$proc.StartTime.ToUniversalTime();if(!$proc.WaitForExit(270000)){throw 'The original Job240 plus bounded closure did not finish.'};$path=Join-Path $directory 'result.safe.json';if((Get-Item $path).Length-gt 65536){throw 'Closed child receipt exceeded bound.'};$row=Get-Content $path -Raw|ConvertFrom-Json;if($row.schema-isnot [long]-or $row.schema-ne 1-or $row.action-cne $Action-or $row.job_sha256-cne '9c2de4d8b96f1769bf0cb5a9985409bb28587dce7f8add77556941bc4ea55448'-or $row.owned_processes_closed-isnot [bool]-or !$row.owned_processes_closed-or $row.handles_closed-isnot [bool]-or !$row.handles_closed){throw 'Owned Job/handle closure unproved.'};$script:knownClosed=$true;return$row}
 finally{if($proc){try{if(!$proc.HasExited){if($proc.StartTime.ToUniversalTime()-ne $started-or $proc.MainModule.FileName-ine $PythonExecutable){throw 'Owned supervisor identity changed.'};$proc.Kill();if(!$proc.WaitForExit(10000)){throw 'Owned supervisor termination refused.'};$script:knownClosed=$false}}finally{$proc.Dispose()}}}
}
try{
 & $PythonExecutable -I -B (Join-Path $PSScriptRoot 'windows_mail_dbh_child.py') prepare $work;if($LASTEXITCODE){throw 'Original public20 verification refused.'}
 $package=Join-Path $work 'package/openwebpbx-1.0.20-windows-x64';$public=Get-Content (Join-Path $work 'public20.safe.json') -Raw|ConvertFrom-Json;Save 'public20' $public
 $input=Join-Path $work 'install.private.json';$secret='Aa!'+[Guid]::NewGuid().ToString('N')
 [IO.File]::WriteAllText($input,(@{package=$package;password=$secret;domain=('dbh-'+$scope+'.invalid')}|ConvertTo-Json),[Text.UTF8Encoding]::new($false));$secret=$null
 $launcher=Join-Path $work 'install.ps1';$code=@'
param([string]$InputPath)
$ErrorActionPreference='Stop'
$record=Get-Content $InputPath -Raw|ConvertFrom-Json
$password=ConvertTo-SecureString $record.password -AsPlainText -Force
& (Join-Path $record.package 'Install-OpenWebPBX.ps1') -RestoreServer -LocalCertificate -DomainName $record.domain -PublicAddress '127.0.0.1' -AdminEmail 'fixture@example.invalid' -AdminPassword $password
if(!$?){exit 1}
'@
 [IO.File]::WriteAllText($launcher,$code,[Text.UTF8Encoding]::new($false));$report.stage='original_installer';$installed=$true
 # Preserve the original suite's40-minute installer boundary. Its services are
 # intentional SCM children; the separate probe uses the original owned Job240.
 $native=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
 $installer=Start-Process -FilePath $native -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$launcher,'-InputPath',$input) -PassThru -RedirectStandardOutput (Join-Path $work 'install.stdout.private.log') -RedirectStandardError (Join-Path $work 'install.stderr.private.log')
 try{if(!$installer.WaitForExit(2400000)){throw 'Original installation remains running; no interruption or cleanup is inferred.'};if($installer.ExitCode){throw 'Original accepted20 installer refused.'}}finally{$installer.Dispose();Remove-Item -LiteralPath $input -Force -ErrorAction SilentlyContinue}
 $state=Join-Path $env:ProgramData 'OpenWebPBX';$installation=Get-Content (Join-Path $state 'installation.json') -Raw|ConvertFrom-Json
 if(!$installation.Completed-or !$installation.RestoreServer-or $installation.AdminEmail-cne 'fixture@example.invalid'){throw 'An owned empty restore factory is required.'}
 & (Join-Path $package 'Install-NativeEngine.ps1') -PackageRoot $package -Check;if(!$?){throw 'Original native core inventory refused.'}
 foreach($name in 'OpenWebPBXUpdater','OpenWebPBX','FreeSWITCH','OpenWebPBX-Database'){$row=Get-CimInstance Win32_Service -Filter ("Name='"+$name+"'");if(!$row-or $row.State-cne 'Running'){throw 'Original native service missing.'};$match=[regex]::Match([string]$row.PathName,'^"?(.+?\.exe)"?(?:\s|$)');$exe=$match.Groups[1].Value;if(!$match.Success-or !([IO.Path]::GetFullPath($exe).StartsWith('C:\OpenWebPBX\',[StringComparison]::OrdinalIgnoreCase)-or [IO.Path]::GetFullPath($exe).StartsWith('C:\Program Files\FreeSWITCH\',[StringComparison]::OrdinalIgnoreCase))){throw 'Owned service image refused.'};$services[$name]=@{path=$row.PathName;image=$exe;sha256=(Hash $exe)}}
 $engineService=Get-CimInstance Win32_Service -Filter "Name='FreeSWITCH'";$engineProcess=Get-Process -Id $engineService.ProcessId;$null=$engineProcess.Handle;if($engineProcess.Path-ine $services['FreeSWITCH'].image){throw 'Held owned engine image differs.'}
 $report.stage='probe';$fixture=Join-Path $state ('mail-dbh-diagnostic/'+$scope);if(Test-Path $fixture){throw 'Retain any earlier scope.'};Private $fixture
 $codeRoot=(Join-Path $helper 'app/switch/resources/scripts').Replace('\','/');[IO.File]::WriteAllText((Join-Path $fixture 'plan.private.json'),(@{code=$codeRoot}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
 $pins=[ordered]@{};foreach($name in 'resources/functions/voicemail_mail_queue.lua','resources/functions/database.lua','resources/functions/database/native.lua','resources/functions/api.lua','resources/functions/base64.lua','resources/functions/base64_alex.lua'){$pins[$name]=Hash (Join-Path $codeRoot $name)}
 Save 'source-bindings' @{source_commit=$env:GITHUB_SHA;helper_source_commit=$HelperRef;module_hashes=$pins;original_job_sha256=(Hash (Join-Path $PSScriptRoot 'windows_meeting_owned_process.py'));python_sha256=(Hash $PythonExecutable);per_case_seconds=15;invented_audio_pcm_bytes=@(3200,102400,512000)}
 $setupAttempted=$true;$prepared=Probe setup;Save 'setup' $prepared;if($prepared.state-cne 'observed'){throw 'Owned DB/WAV setup refused.'}
 $observed=Probe run;Save 'run' $observed;$inspected=Probe inspect;Save 'inspection' $inspected
 foreach($name in $pins.Keys){if((Hash (Join-Path $codeRoot $name))-cne $pins[$name]){throw 'Exact helper/common-wrapper source changed.'}}
 if($observed.state-cne 'observed'-or $inspected.state-cne 'observed'-or $inspected.observation.queue_rows-ne 3-or $inspected.observation.attachment_rows-ne 3-or @($inspected.observation.checks|Where-Object {!$_.queued-or !$_.marker_exact-or !$_.audio_exact}).Count){throw 'Native enqueue/row/audio observation refused.'}
 $report.state='passed';$report.stage='complete'
}catch{$primary=$_;$report.error_type=$_.Exception.GetType().Name;$report.source_line=$_.InvocationInfo.ScriptLineNumber}
finally{
 $clean=$knownClosed
 try{if($setupAttempted-and $knownClosed){$cleaned=Probe cleanup;Save 'database-cleanup' $cleaned;if($cleaned.state-cne 'observed'){throw 'Owned DB cleanup refused.'}}}catch{$clean=$false;if(!$primary){$primary=$_}}
 if($installed){
  foreach($name in 'OpenWebPBX-Backups','OpenWebPBX-Cleanup','OpenWebPBX Certificate Renewal','OpenWebPBX Pending Phone Certificate','OpenWebPBX Outgoing Mail'){try{if(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue){Disable-ScheduledTask -TaskName $name|Out-Null}}catch{$clean=$false}}
  foreach($name in 'OpenWebPBXUpdater','OpenWebPBX','FreeSWITCH','OpenWebPBX-Database'){
   try{if(!$services.ContainsKey($name)){throw 'Original exact service ownership was not captured.'};$row=Get-CimInstance Win32_Service -Filter ("Name='"+$name+"'");if($row.PathName-cne $services[$name].path-or (Hash $services[$name].image)-cne $services[$name].sha256){throw 'Owned service changed.'};$service=Get-Service $name;if($service.Status-ne 'Stopped'){$service.Stop();$service.WaitForStatus('Stopped',[TimeSpan]::FromSeconds(30))};if((Get-Service $name).Status-ne 'Stopped'){throw 'Owned service remains running.'}}
   catch{$clean=$false;if(!$primary){$primary=$_}}
  }
 }
 if($engineProcess){try{if(!$engineProcess.WaitForExit(10000)){throw 'Held engine still runs; asynchronous Lua closure unproved.'};$report.native_async_lua_closed=$true} catch{$clean=$false;if(!$primary){$primary=$_}}finally{$engineProcess.Dispose()}}
 if($fixture-and !$report.native_async_lua_closed){$clean=$false}
 if($clean-and $fixture){try{if(Test-Path (Join-Path $fixture 'progress.safe.json')){$progress=Get-Item (Join-Path $fixture 'progress.safe.json');if($progress.Length-gt 65536){throw 'Closed progress exceeds limit.'};Save 'final-native-progress' (Get-Content $progress.FullName -Raw|ConvertFrom-Json)};foreach($leaf in 'plan.private.json','fixture.private.json','owned-database.private.json','small.wav','medium.wav','large.wav'){if(Test-Path (Join-Path $fixture $leaf)){Remove-Item -LiteralPath (Join-Path $fixture $leaf) -Force -ErrorAction Stop};if(Test-Path (Join-Path $fixture $leaf)){throw 'Owned fixture file remains.'}}}catch{$clean=$false}}
 $report.cleanup=if($clean){'owned database/audio/input removed; exact owned services stopped'}else{'failed_or_unverified'}
 if($primary-or !$clean){$report.state='failed'};Save 'report' $report
}
if($report.state-cne 'passed'){throw 'The component did not pass; inspect only retained closed diagnostics.'}
