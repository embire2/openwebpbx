# SPDX-License-Identifier: AGPL-3.0-or-later
# A distinct hosted fixture producer contract; never ordinary app/calling proof.
[CmdletBinding()]
param([Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string]$SourceCommit,
      [Parameter(Mandatory)][string]$PythonExecutable)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (!$IsWindows -or $env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:GITHUB_REPOSITORY -cne 'embire2/openwebpbx') { throw 'Only the disposable hosted Windows contract is allowed.' }
if ((Test-Path 'C:\OpenWebPBX') -or (Test-Path (Join-Path $env:ProgramData 'OpenWebPBX'))) { throw 'An installed PBX is outside this contract.' }
$client = Split-Path $PSScriptRoot -Parent
$repo = Split-Path (Split-Path $client -Parent) -Parent
$source = Join-Path $client 'tests/wav-producer'
$temp = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')
$prefix = $temp + '\'
# Reused source-owned primitives are below, byte-pinned by the preparation receipt.
. (Join-Path $PSScriptRoot 'WavProducerPrimitives.ps1')
$script:WavToolchainHelperPath=Join-Path $PSScriptRoot 'WavToolchain.ps1'
if((Hash $script:WavToolchainHelperPath)-cne 'ddbf22359965e0d4affa4e76b9d36f956fbbe672ce533ea8230a5184b47fbe08'){throw 'Exact fixture-only toolchain helper required.'}
. $script:WavToolchainHelperPath
$evidence = Join-Path $temp 'phone-wav-evidence'
PrivateDirectory $evidence
$nonce = [Guid]::NewGuid().ToString('N')
$work = Join-Path $temp ('phone-wav-work-' + $nonce)
$contractRoot = Join-Path $temp ('phone-wav-contract-' + $nonce)
$result = [ordered]@{
    schema = 1; producer = 'OpenWebPBX.FixtureWavProducer'; state = 'failed'; stage = 'source'; error_type = 'none';
    source_commit = $SourceCommit; sdk_version = '5.5.23'; native_contract_exit = $null; managed_contract_exit = $null;
    native_contract_passed = $false; original_parser_controls = 0; sdk_files_unchanged = $false;
    system_preserved = $false; exact_owned_cleanup = $false; original_sdk_writer_qualified = $false;
    decoded_calling_qualified = $false; hardware_qualified = $false; production_app_changed = $false
}
$baseline = $null; $failure = $null; $sdk = $null; $sdkRows = @(); $owned = @(); $zipLease = $null; $pendingNamespace = $null
$script:childKnownStopped = $true
function SaveJson([string]$Leaf, $Value) {
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 16 -Compress))
    if ($bytes.Length -gt 8MB) { throw 'Bounded contract evidence required.' }
    $path = Join-Path $evidence $Leaf
    $stream = [IO.File]::Open($path, 'CreateNew', 'Write', 'None')
    try { $stream.Write($bytes); $stream.Flush($true) } finally { $stream.Dispose() }
}
function Application([string]$Name) {
    $command = Get-Command $Name -CommandType Application -ErrorAction Stop | Select-Object -First 1
    if ($null -eq $command -or $command -isnot [Management.Automation.ApplicationInfo] -or ![IO.Path]::IsPathFullyQualified($command.Path) -or [IO.Path]::GetExtension($command.Path) -ine '.exe') { throw 'A concrete installed executable is required.' }
    $item = Get-Item -LiteralPath $command.Path -Force
    if ($item -isnot [IO.FileInfo] -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -le 0) { throw 'An ordinary installed executable is required.' }
    return [string]$command.Path
}
function ReadContractBounded([string]$Path,[int]$Limit) {
    $item=Get-Item -LiteralPath $Path -Force
    if($item.PSIsContainer -or ($item.Attributes-band [IO.FileAttributes]::ReparsePoint)){throw 'Ordinary private command output required.'}
    $stream=[IO.File]::Open($Path,'Open','Read','Read');$buffer=[byte[]]::new($Limit+1)
    try{$offset=0;while($offset-lt $buffer.Length){$read=$stream.Read($buffer,$offset,$buffer.Length-$offset);if(!$read){break};$offset+=$read};if($offset-gt $Limit){throw 'Contract output exceeds its bound.'};return [Text.Encoding]::UTF8.GetString($buffer,0,$offset)}finally{$stream.Dispose()}
}
function RunContractChild([string]$Label, [string]$Exe, [string[]]$Arguments, [string]$Directory, [int]$Seconds, [string]$DllPath = '', $ToolchainEnvironment=$null) {
    $deadlines=@{cmake_version=30;dotnet_version=30;clang_version=30;lld_version=30;ninja_version=30;configure=120;native_build=180;native_contract=30;managed_contract=120}
    if(!$deadlines.ContainsKey($Label) -or $Seconds-ne $deadlines[$Label]){throw 'Original exact contract child deadline required.'}
    $hash=Hash $Exe;$pythonHash=Hash $PythonExecutable
    $core=Join-Path $PSScriptRoot 'WavProducerOwnedProcess.py';$driver=Join-Path $PSScriptRoot 'WavProducerOwnedChild.py'
    $coreHash=Hash $core;$driverHash=Hash $driver
    $directoryEvidence=Join-Path $evidence ('owned-'+$Label);PrivateDirectory $directoryEvidence
    $childEnvironment=[ordered]@{}
    if($null-ne $ToolchainEnvironment){
        if($Label-cnotin @('configure','native_build')-or@(Compare-Object @($ToolchainEnvironment.Keys|Sort-Object) @('INCLUDE','LIB')).Count){throw 'Closed compiler-only child environment required.'}
        foreach($name in @('INCLUDE','LIB')){$value=$ToolchainEnvironment[$name];if($value-isnot[string]-or!$value.Length-or$value.Length-gt32768-or$value.Contains([char]0)-or$value.Contains("`n")-or$value.Contains("`r")){throw 'Bounded compiler child environment required.'};$childEnvironment[$name]=$value}
    }
    $request=[ordered]@{schema=1;label=$Label;command=@($Exe)+@($Arguments);command_sha256=$hash;working_directory=$Directory;evidence_directory=$directoryEvidence;seconds=$Seconds;python_executable=$PythonExecutable;python_sha256=$pythonHash;job_core_sha256=$coreHash;toolchain_environment=$childEnvironment}
    $requestPath=Join-Path $directoryEvidence 'request.json';$requestBytes=[Text.UTF8Encoding]::new($false).GetBytes(($request|ConvertTo-Json -Depth 8 -Compress))
    if($requestBytes.Length-gt 65536){throw 'Contract request exceeds its bound.'}
    $requestFile=[IO.File]::Open($requestPath,'CreateNew','Write','None');try{$requestFile.Write($requestBytes);$requestFile.Flush($true)}finally{$requestFile.Dispose()};$requestHash=Hash $requestPath
    $info=[Diagnostics.ProcessStartInfo]::new($PythonExecutable)
    $info.WorkingDirectory=$Directory;$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    # No redirected pipes: owned command streams are files monitored by the Job core.
    foreach($arg in @('-I','-B',$driver,$requestPath)){[void]$info.ArgumentList.Add($arg)}
    if($DllPath){$info.Environment['PATH']=$DllPath+';'+$info.Environment['PATH']}
    foreach($name in $childEnvironment.Keys){$info.Environment[$name]=$childEnvironment[$name]}
    $proc=$null;$childFailure=$null;$childResult=$null;$script:childKnownStopped=$false
    try {
        $proc=[Diagnostics.Process]::Start($info);$started=$proc.StartTime.ToUniversalTime()
        # Original command deadline remains inside the Job. Additional20s bounds
        # its existing10s ordinary descendant closure +5s termination/accounting.
        if(!$proc.WaitForExit(($Seconds+20)*1000)){throw 'Owned recorder supervisor cleanup deadline exceeded.'}
        if((Hash $PythonExecutable)-cne $pythonHash -or (Hash $core)-cne $coreHash -or (Hash $driver)-cne $driverHash -or (Hash $Exe)-cne $hash -or (Hash $requestPath)-cne $requestHash){throw 'Pinned recorder supervision input changed.'}
        $proof=ReadContractBounded (Join-Path $directoryEvidence 'driver.safe.json') 8192|ConvertFrom-Json
        $keys=@('schema','producer','state','request_sha256','job_core_sha256','interpreter_sha256','command_image_sha256','command_exit','timed_out','owned_processes_closed','handles_closed','error_type','process_proof_sha256','output_read_completed')
        if(@(Compare-Object @($proof.PSObject.Properties.Name|Sort-Object) @($keys|Sort-Object)).Count -or $proof.schema-isnot [long] -or $proof.schema-ne 1 -or $proof.producer-cne 'WavProducerOwnedChild' -or $proof.request_sha256-cne $requestHash -or $proof.job_core_sha256-cne $coreHash -or $proof.interpreter_sha256-cne $pythonHash -or $proof.command_image_sha256-cne $hash -or $proof.state-cnotin @('failed','observed_complete_owned_child') -or $proof.error_type-cnotin @('none','RuntimeError','OSError','TimeoutExpired','ValueError','other')){throw 'Closed exact supervisor receipt required.'}
        foreach($name in @('timed_out','owned_processes_closed','handles_closed','output_read_completed')){if($proof.$name-isnot [bool]){throw 'Typed supervisor receipt required.'}}
        if($proof.process_proof_sha256-isnot [string] -or $proof.process_proof_sha256-cnotmatch '^[a-f0-9]{64}$' -or (Hash (Join-Path $directoryEvidence 'process.safe.json'))-cne $proof.process_proof_sha256){throw 'Exact owned Job proof required.'}
        $job=ReadContractBounded (Join-Path $directoryEvidence 'process.safe.json') 8192|ConvertFrom-Json
        $jobKeys=@('schema','created_suspended','assigned_before_resume','resumed','owned_job_terminated','exit_code','owned_processes_closed','handles_closed','ordinary_exit')
        if(@(Compare-Object @($job.PSObject.Properties.Name|Sort-Object) @($jobKeys|Sort-Object)).Count -or $job.schema-isnot [long] -or $job.schema-ne 1){throw 'Closed original Job receipt required.'}
        foreach($name in @('created_suspended','assigned_before_resume','resumed','owned_job_terminated','owned_processes_closed','handles_closed','ordinary_exit')){if($job.$name-isnot [bool]){throw 'Typed original Job receipt required.'}}
        if($null-ne $job.exit_code -and ($job.exit_code-isnot [long] -or $job.exit_code-lt 0 -or $job.exit_code-gt [uint32]::MaxValue)){throw 'Typed native exit-code receipt required.'}
        if(!$proof.owned_processes_closed -or !$proof.handles_closed -or !$job.owned_processes_closed -or !$job.handles_closed -or ($job.resumed -and (!$job.created_suspended -or !$job.assigned_before_resume))){throw 'Owned process-tree/handle closure remains unproved.'}
        $script:childKnownStopped=$true
        if($proc.ExitCode-ne 0 -or $proof.state-cne 'observed_complete_owned_child' -or !$proof.output_read_completed -or $proof.error_type-cne 'none' -or $proof.timed_out -or !$job.ordinary_exit -or !$job.created_suspended -or !$job.assigned_before_resume -or !$job.resumed -or $proof.command_exit-isnot [long] -or $proof.command_exit-lt 0 -or $proof.command_exit-gt [uint32]::MaxValue -or $job.exit_code-ne $proof.command_exit){throw 'Owned contract child failed; exact Job/driver evidence retained.'}
        $stdout=ReadContractBounded (Join-Path $directoryEvidence 'stdout.private.log') 8MB;$stderr=ReadContractBounded (Join-Path $directoryEvidence 'stderr.private.log') 8MB
        [IO.File]::WriteAllText((Join-Path $evidence ($Label+'.stdout.txt')),$stdout,[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText((Join-Path $evidence ($Label+'.stderr.txt')),$stderr,[Text.UTF8Encoding]::new($false))
        $exit=[BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]$proof.command_exit),0)
        SaveJson ($Label+'.child.json') ([ordered]@{exit_code=$exit;image_sha256=$hash;supervisor_started_utc=$started.ToString('o');supervisor_pid=$proc.Id;python_sha256=$pythonHash;job_source_sha256=$coreHash;driver_source_sha256=$driverHash;job_proof_sha256=$proof.process_proof_sha256;timed_out=$false;exact_owned_child_cleanup=$true;stdout_truncated=$false;stderr_truncated=$false})
        $childResult=[pscustomobject]@{Exit=$exit;Out=$stdout}
    } catch {$childFailure=$_}
    finally {
        if($null-ne $proc){
            try {
                if(!$proc.HasExited){
                    if($proc.StartTime.ToUniversalTime()-ne $started -or $proc.MainModule.FileName-ine $PythonExecutable -or (Hash $PythonExecutable)-cne $pythonHash){throw 'Exact owned supervisor identity changed.'}
                    $proc.Kill();if(!$proc.WaitForExit(10000)){throw 'Owned supervisor survived bounded termination.'}
                    # Closing its Job handle kills descendants, but without an
                    # original complete accounting receipt tree cleanup stays refused.
                    $script:childKnownStopped=$false
                }
            } catch {if(!$childFailure){$childFailure=$_};$script:childKnownStopped=$false}
            finally {$proc.Dispose()}
        }
    }
    if($childFailure){throw $childFailure};return $childResult
}
function ExpandContractSdk([string]$Archive, [string]$Target) {
    # Same complete-member, traversal, duplicate, symlink, per-file and total guards
    # as Test-ClientMedia. Only selection/layout changes: public headers/import libs.
    PrivateDirectory $Target
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [long]$total = 0; $count = 0
    try {
        if ($zip.Entries.Count -gt 20000) { throw 'The SDK member count is unbounded.' }
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName
            if ($name.Length -gt 240 -or $name -match '(^/|\\|:|\x00|(^|/)\.\.?(/|$))' -or !$seen.Add($name.TrimEnd('/')) -or (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) { throw 'Unsafe or duplicate SDK ZIP member.' }
            $relative = $null
            if ($name -cmatch '^linphone-sdk/win64/(include/.+[^/])$') { $relative = $Matches[1] }
            elseif ($name -cmatch '^linphone-sdk/win64/(lib/(?:mediastreamer2|bctoolbox|ortp)\.lib)$') { $relative = $Matches[1] }
            elseif ($name -cmatch '^linphone-sdk/win64/(bin/[^/]+\.dll)$' -and $Matches[1] -notmatch 'tester|bcunit') { $relative = $Matches[1] }
            if (!$relative) { continue }
            $total += $entry.Length
            if (++$count -gt 8000 -or $entry.Length -gt 256MB -or $total -gt 1GB) { throw 'Selected SDK data exceeds bounds.' }
            $file = Join-Path $Target $relative
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($file))
            $input = $entry.Open(); $output = [IO.File]::Open($file, 'CreateNew', 'Write', 'None')
            try { $input.CopyTo($output); $output.Flush($true) } finally { $output.Dispose(); $input.Dispose() }
            if ((Get-Item $file).Length -ne $entry.Length) { throw 'SDK extraction is incomplete.' }
        }
    } finally { $zip.Dispose() }
    foreach ($file in @('include/mediastreamer2/msfactory.h','include/mediastreamer2/msfilter.h','include/bctoolbox/vfs.h','include/ortp/str_utils.h','lib/mediastreamer2.lib','lib/bctoolbox.lib','lib/ortp.lib','bin/mediastreamer2.dll','bin/bctoolbox.dll','bin/ortp.dll')) {
        if (!(Test-Path -LiteralPath (Join-Path $Target $file) -PathType Leaf)) { throw 'Required original SDK header/import/runtime is absent.' }
    }
}
try {
    Push-Location $repo
    try { if ((& git rev-parse HEAD).Trim() -cne $SourceCommit -or $LASTEXITCODE -or (& git status --porcelain)) { throw 'The exact clean contract source is required.' } } finally { Pop-Location }
    $manifest = Get-Content (Join-Path $source 'source-manifest.json') -Raw | ConvertFrom-Json
    if ($manifest.schema -ne 1 -or $manifest.files.Count -ne 20 -or $manifest.sdk_sha256 -cne '9cc84037333daca88af24804e20b9d1f5e41ddd901578484b57dcc6720a8d297') { throw 'Contract source manifest differs.' }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($row in $manifest.files) {
        if ($row.path -cnotmatch '^[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*$' -or !$seen.Add($row.path) -or $row.path.Split('/') -contains '..') { throw 'Contract source name differs.' }
        $file = Join-Path $source $row.path
        $item = Get-Item -LiteralPath $file -Force
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -ne $row.bytes -or (Hash $file) -cne $row.sha256) { throw 'Pinned contract source differs.' }
    }
    if ((Hash (Join-Path $source 'readiness/AudioProof.original.cs')) -cne '1aeb2622eed0cdefe86b66a1f448a95ecf0da9321bbbb072ea42a0114e07d3e0' -or (Hash (Join-Path $client 'tests/media/AudioProof.cs')) -cne $manifest.original_audio_proof_sha256) { throw 'The original strict parser differs.' }
    SaveJson 'source-inventory.json' $manifest
    # Supplied only from the pinned setup-python action's python-path output;
    # never PATH discovery, WindowsApps aliases, py.exe or an ambient interpreter.
    if(![IO.Path]::IsPathFullyQualified($PythonExecutable) -or [IO.Path]::GetExtension($PythonExecutable)-ine '.exe' -or $PythonExecutable-match '\\WindowsApps\\|\\py\.exe$'){throw 'Explicit pinned setup-python executable required.'}
    $pythonItem=Get-Item -LiteralPath $PythonExecutable -Force
    if($pythonItem.PSIsContainer -or ($pythonItem.Attributes-band [IO.FileAttributes]::ReparsePoint) -or $pythonItem.Length-le 0){throw 'Readable ordinary pinned Python executable required.'}
    $pythonLease=[IO.File]::Open($PythonExecutable,'Open','Read','Read');$pythonLease.Dispose()
    SaveJson 'owned-process-source.json' ([ordered]@{schema=1;proven_job_source_sha256='9c2de4d8b96f1769bf0cb5a9985409bb28587dce7f8add77556941bc4ea55448';launcher_sha256=(Hash $PSCommandPath);job_core_sha256=(Hash (Join-Path $PSScriptRoot 'WavProducerOwnedProcess.py'));supervisor_sha256=(Hash (Join-Path $PSScriptRoot 'WavProducerOwnedChild.py'));python_path=$PythonExecutable;python_sha256=(Hash $PythonExecutable);python_version='3.12.10';original_command_deadlines_seconds=@(30,120,180);ordinary_descendant_wait_seconds=10;job_termination_wait_seconds=5;outer_supervisor_extra_seconds=20;forced_supervisor_wait_seconds=10;redirected_pipes=$false})
    $cmake = Application cmake; $dotnet = Application dotnet
    $cv = RunContractChild cmake_version $cmake @('--version') $source 30
    $dv = RunContractChild dotnet_version $dotnet @('--version') $client 30
    if ($cv.Exit -ne 0 -or $dv.Exit -ne 0 -or $dv.Out.Trim() -cne '10.0.401' -or $cv.Out -cnotmatch '^cmake version 4\.4\.4(?:\r?\n|$)') { throw 'Installed contract tool versions differ.' }
    SaveJson 'tools.json' ([ordered]@{ cmake_path = $cmake; cmake_sha256 = (Hash $cmake); dotnet_path = $dotnet; dotnet_sha256 = (Hash $dotnet); dotnet_version = '10.0.401'; python_path = $PythonExecutable; python_sha256 = (Hash $PythonExecutable); python_version = '3.12.10'; job_source_sha256 = (Hash (Join-Path $PSScriptRoot 'WavProducerOwnedProcess.py')); job_driver_sha256 = (Hash (Join-Path $PSScriptRoot 'WavProducerOwnedChild.py')) })
    $result.stage = 'baseline'
    $baseline = SystemSnapshot
    [IO.File]::WriteAllText((Join-Path $evidence 'baseline.json'), $baseline, [Text.UTF8Encoding]::new($false))
    $pendingNamespace = $work; PrivateDirectory $work; $owned += $work; $pendingNamespace = $null
    $pendingNamespace = $contractRoot; PrivateDirectory $contractRoot; $owned += $contractRoot; $pendingNamespace = $null
    $result.stage = 'toolchain'
    $toolchain=NewWavToolchain
    foreach($entry in @(@('clang_version','clang','^clang version (20\.1\.8)(?:\s|$)'),@('lld_version','lld','^LLD (20\.1\.8)(?:\s|$)'),@('ninja_version','ninja','^(1\.13\.2)(?:\s|$)'))){
        $versionResult=RunContractChild $entry[0] $toolchain.tools[$entry[1]].path @('--version') $source 30
        $match=[regex]::Match($versionResult.Out.Trim(),$entry[2]);if($versionResult.Exit-ne0-or!$match.Success){throw 'Actual recorded tool version differs from the reviewed fixture toolchain.'}
        $toolchain.tools[$entry[1]].version=$match.Groups[1].Value
    }
    $target=[regex]::Match((ReadContractBounded (Join-Path $evidence 'clang_version.stdout.txt') 8MB),'(?m)^Target: (x86_64-pc-windows-msvc)\r?$');if(!$target.Success){throw 'Actual unforced Clang target differs from the original AMD64 SDK ABI.'};$toolchain.target=$target.Groups[1].Value
    AssertWavToolchainUnchanged $toolchain
    SaveJson 'compiler-toolchain.json' $toolchain
    $result.stage = 'sdk_download'
    $archive = Join-Path $work 'sdk.zip'
    MediaGet 'https://download.linphone.org/releases/windows/sdk/linphone-sdk-win64-5.5.23.zip' $archive 315960147
    if ((Get-Item $archive).Length -ne 315960147 -or (Hash $archive) -cne $manifest.sdk_sha256) { throw 'Exact official SDK bytes differ.' }
    $zipLease = [IO.File]::Open($archive, 'Open', 'Read', 'Read')
    $result.stage = 'sdk_extract'
    $sdk = Join-Path $work 'sdk'
    ExpandContractSdk $archive $sdk
    $sdkRows = @(Get-ChildItem -LiteralPath $sdk -Recurse -File | Sort-Object FullName | ForEach-Object { [ordered]@{ path = [IO.Path]::GetRelativePath($sdk,$_.FullName); bytes = $_.Length; sha256 = (Hash $_.FullName) } })
    SaveJson 'sdk-inventory.json' $sdkRows
    SaveJson 'after-sdk-extract.json' (SystemSnapshot | ConvertFrom-Json)
    $build = Join-Path $work 'build'
    $result.stage = 'configure'
    $r = RunContractChild configure $cmake @('-S',$source,'-B',$build,'-G','Ninja Multi-Config',('-DOPENWEB_PINNED_SDK='+$sdk),('-DCMAKE_C_COMPILER:FILEPATH='+$toolchain.tools.clang.path),('-DCMAKE_MAKE_PROGRAM:FILEPATH='+$toolchain.tools.ninja.path),'-DCMAKE_LINKER_TYPE:STRING=LLD',('-DCMAKE_LINKER_LLD:FILEPATH='+$toolchain.tools.lld.path),('-DCMAKE_LINKER:FILEPATH='+$toolchain.tools.lld.path),('-DCMAKE_C_COMPILER_ID_FLAGS_ALWAYS:STRING='+(WavCompilerIdFlags $toolchain))) $source 120 '' $toolchain.environment
    if ($r.Exit -ne 0) { throw 'Native contract configuration refused.' }
    [void](AssertWavConfigured $build $toolchain)
    SaveJson 'compiler.json' ([ordered]@{path=$toolchain.tools.clang.path;sha256=$toolchain.tools.clang.sha256;version=$toolchain.tools.clang.version})
    $result.stage = 'native_build'
    $r = RunContractChild native_build $cmake @('--build',$build,'--config','Release','--parallel','1','--verbose') $source 180 '' $toolchain.environment
    if ($r.Exit -ne 0) { throw 'Native contract build refused.' }
    SaveJson 'build-commands.json' (GetWavBuildCommands $build $r.Out $toolchain)
    SaveJson 'dependency-abi.json' (GetWavDependencies $build $sdk $sdkRows $toolchain)
    SaveJson 'after-native-build.json' (SystemSnapshot | ConvertFrom-Json)
    $exe = Join-Path $build 'Release/wav_contract.exe'
    $plugin = Join-Path $build 'Release/libmsopenwebwav.dll'
    SaveJson 'built-images.json' ([ordered]@{ exe_sha256 = (Hash $exe); plugin_sha256 = (Hash $plugin) })
    $result.stage = 'native_contract'
    $r = RunContractChild native_contract $exe @($contractRoot) $contractRoot 30 (Join-Path $sdk 'bin')
    $result.native_contract_exit = $r.Exit
    if ($r.Exit -ne 0) { throw 'Real SDK producer contract refused.' }
    $native = $r.Out.Trim() | ConvertFrom-Json
    $keys = @('schema','state','checks','actual_sdk','public_factory_selection_proved','invented_PCM_input','decoded_calling_qualified','original_SDK_filewriter_qualified','hardware_qualified')
    if (@(Compare-Object @($native.PSObject.Properties.Name | Sort-Object) @($keys | Sort-Object)).Count -or $native.schema -isnot [long] -or $native.schema -ne 1 -or $native.state -cne 'passed_native_fixture_producer_contract' -or $native.checks -isnot [long] -or $native.checks -lt 1 -or $native.checks -gt 10000 -or $native.actual_sdk -cne '5.5.23' -or $native.public_factory_selection_proved -isnot [bool] -or !$native.public_factory_selection_proved -or $native.invented_PCM_input -isnot [bool] -or !$native.invented_PCM_input -or $native.decoded_calling_qualified -isnot [bool] -or $native.decoded_calling_qualified -or $native.original_SDK_filewriter_qualified -isnot [bool] -or $native.original_SDK_filewriter_qualified -or $native.hardware_qualified -isnot [bool] -or $native.hardware_qualified) { throw 'Closed native contract receipt differs.' }
    SaveJson 'native-receipt.json' $native
    NoLinks $contractRoot
    $produced = @(Get-ChildItem -LiteralPath $contractRoot -Force)
    if ($produced.Count -ne 5 -or @($produced | Where-Object { $_.PSIsContainer }).Count -or @(Compare-Object @($produced.Name | Sort-Object) @('empty.wav','malformed.wav','mono.wav','sixteen.wav','stereo.wav')).Count) { throw 'Actual produced-file inventory differs.' }
    SaveJson 'produced-files.json' @($produced | Sort-Object Name | ForEach-Object { [ordered]@{ name = $_.Name; bytes = $_.Length; sha256 = (Hash $_.FullName) } })
    $result.native_contract_passed = $true
    $result.stage = 'managed_contract'
    $managed = Join-Path $work 'managed'; PrivateDirectory $managed
    foreach ($name in @('ReadinessContract.csproj','ReadinessContract.cs','FirstDataReadiness.cs','AudioProof.original.cs')) { [IO.File]::Copy((Join-Path $source ('readiness/' + $name)), (Join-Path $managed $name), $false) }
    [IO.File]::WriteAllText((Join-Path $managed 'global.json'), '{"sdk":{"version":"10.0.401","rollForward":"disable"}}')
    $feed = Join-Path $work 'empty-feed'; PrivateDirectory $feed
    $r = RunContractChild managed_contract $dotnet @('run','--project',(Join-Path $managed 'ReadinessContract.csproj'),'-c','Release','--no-launch-profile',('-p:RestoreSources=' + $feed),'-p:UseSharedCompilation=false') $managed 120
    $result.managed_contract_exit = $r.Exit
    if ($r.Exit -ne 0) { throw 'Original parser/readiness contract refused.' }
    $managedReceipt = $r.Out.Trim() | ConvertFrom-Json
    $keys = @('schema','state','checks','actual_native_calling','native_plugin_built','original_parser_changed')
    if (@(Compare-Object @($managedReceipt.PSObject.Properties.Name | Sort-Object) @($keys | Sort-Object)).Count -or $managedReceipt.schema -isnot [long] -or $managedReceipt.schema -ne 1 -or $managedReceipt.state -cne 'passed_private_first_data_and_original_parser_contract' -or $managedReceipt.checks -isnot [long] -or $managedReceipt.checks -ne 41 -or $managedReceipt.actual_native_calling -isnot [bool] -or $managedReceipt.actual_native_calling -or $managedReceipt.native_plugin_built -isnot [bool] -or $managedReceipt.native_plugin_built -or $managedReceipt.original_parser_changed -isnot [bool] -or $managedReceipt.original_parser_changed) { throw 'Managed contract receipt differs.' }
    SaveJson 'managed-receipt.json' $managedReceipt
    $result.original_parser_controls = 41
    $result.stage = 'sdk_preservation'
    foreach ($row in $sdkRows) { $file = Join-Path $sdk $row.path; if ((Get-Item $file).Length -ne $row.bytes -or (Hash $file) -cne $row.sha256) { throw 'An original SDK file changed.' } }
    if ((Hash $archive) -cne $manifest.sdk_sha256) { throw 'The original SDK archive changed.' }
    AssertWavToolchainUnchanged $toolchain
    if((Hash $script:WavToolchainHelperPath)-cne 'ddbf22359965e0d4affa4e76b9d36f956fbbe672ce533ea8230a5184b47fbe08'){throw 'Toolchain helper changed during fixture.'}
    $result.sdk_files_unchanged = $true
    $result.stage = 'complete'
} catch {
    $failure = $_; $result.error_type = $_.Exception.GetType().FullName
    if($result.stage-ceq'configure'-and$script:childKnownStopped){try{[void](SaveWavConfigureFailureTrace $build $evidence)}catch{}}
} finally {
    try {
        if ($zipLease) { $zipLease.Dispose(); $zipLease = $null }
        if ($null -ne $pendingNamespace) { throw 'Owned cleanup refuses an incompletely protected namespace creation.' }
        if (!$script:childKnownStopped) { throw 'Owned cleanup refuses a child whose termination is unproved.' }
        foreach ($path in $owned) {
            if (![IO.Path]::GetFullPath($path).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or $path -cnotin @($work,$contractRoot)) { throw 'Owned cleanup scope differs.' }
            NoLinks $path
        }
        foreach ($path in $owned) { [IO.Directory]::Delete($path,$true); if (Test-Path -LiteralPath $path) { throw 'Owned tree cleanup failed.' } }
        $result.exact_owned_cleanup = $true
    } catch { if (!$failure) { $failure = $_; $result.error_type = $_.Exception.GetType().FullName }; $result.exact_owned_cleanup = $false }
    if ($null -ne $baseline) {
        try {
            $after = SystemSnapshot
            [IO.File]::WriteAllText((Join-Path $evidence 'final.json'), $after, [Text.UTF8Encoding]::new($false))
            $result.system_preserved = $after -ceq $baseline
        } catch { if (!$failure) { $failure = $_; $result.error_type = $_.Exception.GetType().FullName }; $result.system_preserved = $false }
    }
    if (!$failure -and $result.stage -ceq 'complete' -and $result.sdk_files_unchanged -and $result.native_contract_passed -and $result.original_parser_controls -eq 41 -and $result.exact_owned_cleanup -and $result.system_preserved) { $result.state = 'passed_distinct_fixture_producer_contract' }
    SaveJson 'report.json' $result
}
if ($failure) { throw $failure }
if ($result.state -cne 'passed_distinct_fixture_producer_contract') { throw 'Complete producer/system preservation contract refused.' }
