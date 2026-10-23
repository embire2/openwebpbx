# QA-only read-only proof of the actual installed background importer identity.
param([Parameter(Mandatory)][string]$PackageRoot)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if($env:OPENWEB_WINDOWS_NATIVE_TEST -cne '1' -or $env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows' -or $env:GITHUB_REPOSITORY -cne 'embire2/openwebpbx'){throw 'A disposable native calling fixture is required.'}
$root='C:\OpenWebPBX'
. (Join-Path $PSScriptRoot 'windows-native-cleanup-writers.ps1')
# Reuse the candidate hash, SCM account, native owner SID and owned task guards.
$writer=Get-NativeCleanupWriterState
if($writer.Running -isnot [bool] -or !$writer.Running){throw 'The normal background importer must be running.'}
$service=@(Get-CimInstance Win32_Service -Filter "Name='OpenWebPBX'" -ErrorAction Stop)
if($service.Count -ne 1 -or $service[0].State -cne 'Running' -or $service[0].ProcessId -lt 1){throw 'The actual importer service changed.'}
$process=@(Get-CimInstance Win32_Process -Filter ("ProcessId="+[uint32]$service[0].ProcessId) -ErrorAction Stop)
if($process.Count -ne 1 -or $process[0].ExecutablePath -ine ($root+'\server\OpenWebPbx.Server.exe')){throw 'The actual importer process changed.'}
$owner=Invoke-CimMethod -InputObject $process[0] -MethodName GetOwnerSid -ErrorAction Stop
if($owner.ReturnValue -ne 0 -or $owner.Sid -cne 'S-1-5-19'){throw 'The actual importer identity changed.'}
foreach($child in @(Get-CimInstance Win32_Process -Filter "Name='php.exe'" -ErrorAction Stop)){
 if($child.ExecutablePath -ine ($root+'\php\php.exe') -or ([string]$child.CommandLine).Replace('/','\').IndexOf(($root+'\web\app\pbx_setup\call_records.php'),[StringComparison]::OrdinalIgnoreCase) -lt 0){continue}
 $sid=Invoke-CimMethod -InputObject $child -MethodName GetOwnerSid -ErrorAction Stop
 if($sid.ReturnValue -ne 0 -or $sid.Sid -cne 'S-1-5-19' -or $child.ParentProcessId -ne $service[0].ProcessId){throw 'A separate importer prevents background-service attribution.'}
}
[ordered]@{schema=1;producer='windows_cdr_service.ps1';state='observed';read_only=$true;actual_localservice_identity=$true;candidate_bound=$true;no_separate_importer=$true;process_id=[uint32]$service[0].ProcessId}|ConvertTo-Json -Compress
