#Requires -RunAsAdministrator
#Requires -Version 7.4
# QA only. Complete public-state comparison stays exact while owned writers pause.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PackageRoot,[Parameter(Mandatory)][string]$ReportPath,[switch]$DisposableHostedRunner)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if(!$DisposableHostedRunner -or $env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows' -or $env:GITHUB_REPOSITORY -cne 'embire2/openwebpbx' -or [Environment]::OSVersion.Version.Build -lt 26100){throw 'The disposable Windows Server 2025 factory is required.'}
$root='C:\OpenWebPBX';$state=Join-Path $env:ProgramData 'OpenWebPBX';$work=Join-Path $state ('native-threecx-import\'+[Guid]::NewGuid().ToString('N').Substring(0,24))
$lock=$null;$writers=$null;$updater=$null;$primary=$null;$environmentBefore=$env:OPENWEB_WINDOWS_NATIVE_TEST;$mainStarted=$false;$childCleanupProven=$false;$childCleanupFailed=$false
$report=[ordered]@{schema=1;producer='windows_threecx_import_native.ps1';state='running';checks=0;actual_native_windows=$true;actual_installed_php_pg_zip_restore=$false;configuration_path_adapter=$true;ui_upload_tested=$false;calling_tested=$false;installed_server_changed=$false;historical_failure_cause_proven=$false;main_import_started=$false;cleanup='pending'}
. (Join-Path $PSScriptRoot 'windows-native-cleanup-row-fields.ps1')
. (Join-Path $PSScriptRoot 'windows-native-cleanup-writers.ps1')
. (Join-Path $PSScriptRoot 'windows-health-updater-quiescence.ps1')
function Assert-ThreecxImportReport($Row){
 if($null -eq $Row -or $Row.GetType() -ne [Management.Automation.PSCustomObject] -or ($Row.schema -isnot [int] -and $Row.schema -isnot [long]) -or $Row.schema -ne 1 -or $Row.producer -isnot [string] -or $Row.producer -cne 'windows_threecx_import_native.php' -or $Row.state -isnot [string] -or $Row.state -cne 'passed' -or $Row.php_version -isnot [string] -or $Row.php_version -cne '8.4.27' -or ($Row.checks -isnot [int] -and $Row.checks -isnot [long]) -or $Row.checks -lt 32 -or $Row.checks -gt 1000){throw 'The actual synthetic import matrix did not pass.'}
 foreach($field in 'actual_windows_native','actual_php_pg_zip_restore','configuration_path_adapter','synthetic_archive_only','original_credentials_preserved','custom_greeting_media_exact','default_greeting_unchanged','groups_and_routes_restored','providers_and_dids_disabled','complete_public_rows_exact','global_config_exact','owned_schema_media_key_removed','late_wav_failure_exact_rollback'){if($Row.$field -isnot [bool] -or !$Row.$field){throw 'The synthetic import coverage or preservation proof is missing.'}}
 foreach($field in 'ui_upload_tested','calling_tested','installed_server_changed','historical_failure_cause_proven'){if($Row.$field -isnot [bool] -or $Row.$field){throw 'The isolated import scope must remain explicit.'}}
}
function Get-ThreecxImportFailure($Row){
 $safe=@{};$phases=@('input','database','synthetic_archive','apply','repeat_refusal','unsafe_zip','bad_wav_rollback')
 if($null -eq $Row -or $Row.GetType() -ne [Management.Automation.PSCustomObject] -or $Row.state -cne 'failed' -or $Row.phase -isnot [string] -or $Row.phase -cnotin $phases){return $safe}
 if($Row.error_type -isnot [string] -or $Row.error_type -cnotin 'RuntimeException','InvalidArgumentException','PDOException','TypeError','ValueError','Error','Exception'){return $safe}
 if($Row.source_basename -isnot [string] -or $Row.source_basename -cnotin 'windows_threecx_import_native.php','windows_threecx_fixture.php','pbx_setup_provisioner.php','pbx_v20_restore.php','threecx_backup.php','threecx_v20.php','pbx_paths.php','pbx_phone_restore.php','external_component' -or ($Row.source_line -isnot [int] -and $Row.source_line -isnot [long]) -or $Row.source_line -lt 1 -or $Row.source_line -gt 100000 -or $Row.cleanup_failed -isnot [bool]){return $safe}
 return @{phase=$Row.phase;error_type=$Row.error_type;source_basename=$Row.source_basename;source_line=$Row.source_line;cleanup_failed=$Row.cleanup_failed}
}
function Get-ThreecxRefusalObservation($Result){
 if(($Result -isnot [Collections.IDictionary] -and $Result.GetType() -ne [Management.Automation.PSCustomObject]) -or $Result.ExitCode -isnot [int] -or $Result.Stdout -isnot [string] -or $Result.Stderr -isnot [string] -or $Result.Stdout.Length -gt 8192 -or $Result.Stderr.Length -gt 8192){throw 'The bounded sentinel child record is invalid.'}
 $stdout=if($Result.Stdout -ceq ''){'empty'}elseif($Result.Stdout -cmatch '^PASS 4 actual import early-refusal/sentinel-preservation controls; no database or PBX used\r?\n$'){'expected_success'}elseif($Result.Stdout -cmatch '\ACould not open input file: [^\r\n]{1,4096}\r?\n\z'){'input_file_unavailable'}else{'other'}
 $stderr=if($Result.Stderr -ceq ''){'empty'}elseif($Result.Stderr -match 'PHP Startup:'){'php_startup_warning'}elseif($Result.Stderr -match '(?:PHP )?Fatal error:|Uncaught '){'php_fatal'}elseif($Result.Stderr -match '(?:PHP )?Warning:'){'php_warning'}else{'other'}
 return @{exit_code=$Result.ExitCode;stdout_shape=$stdout;stderr_shape=$stderr;stdout_chars=$Result.Stdout.Length;stderr_chars=$Result.Stderr.Length}
}
function Get-ThreecxCleanupState([bool]$MainStarted,[bool]$ChildCleanupProven,[bool]$WritersRestored,[bool]$ChildCleanupFailed){
 if(!$WritersRestored -or $ChildCleanupFailed){return 'failed'}
 if(!$MainStarted -or $ChildCleanupProven){return 'passed'}
 return 'unverified'
}
function Invoke-BoundedThreecxPhp([string]$Name,[string[]]$Arguments){
 if($Name -cnotin 'windows_threecx_import_native.php','windows_threecx_import_refusals.php'){throw 'An exact owned import test is required.'}
 $file=Join-Path $PSScriptRoot $Name;$null=Assert-NativeCleanupOrdinary $file
 $start=[Diagnostics.ProcessStartInfo]::new($root+'\php\php.exe');$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 foreach($argument in @('-c',($root+'\php\php.ini'),$file)+$Arguments){$start.ArgumentList.Add($argument)}
 $child=[Diagnostics.Process]::Start($start)
 try{
  $readers=@($child.StandardOutput,$child.StandardError);$buffers=@([char[]]::new(1024),[char[]]::new(1024));$texts=@([Text.StringBuilder]::new(),[Text.StringBuilder]::new());$pending=@($null,$null);$closed=@($false,$false);$timer=[Diagnostics.Stopwatch]::StartNew()
  do{
   for($side=0;$side -lt 2;$side++){
    if($closed[$side]){continue};if(!$pending[$side]){$pending[$side]=$readers[$side].ReadAsync($buffers[$side],0,1024)}
    if($pending[$side].IsCompleted){$n=$pending[$side].GetAwaiter().GetResult();$pending[$side]=$null;if(!$n){$closed[$side]=$true}else{if($texts[$side].Length+$n -gt 8192){throw 'The owned import child output exceeded its bound.'};[void]$texts[$side].Append($buffers[$side],0,$n)}}
   }
   if($child.HasExited -and $closed[0] -and $closed[1]){break};if($timer.ElapsedMilliseconds -ge 120000){throw 'The owned import child exceeded its bound.'};Start-Sleep -Milliseconds 10
  }while($true)
  return @{ExitCode=$child.ExitCode;Stdout=$texts[0].ToString();Stderr=$texts[1].ToString()}
 }finally{try{if(!$child.HasExited){$child.Kill($true);if(!$child.WaitForExit(5000)){throw 'The exact owned import child survived cleanup.'}}}finally{$child.Dispose()}}
}
if(Get-Item -LiteralPath $ReportPath -Force -ErrorAction SilentlyContinue){throw 'Retain the previous import report.'}
try{
 $installation=Get-Content -LiteralPath (Join-Path $state 'installation.json') -Raw|ConvertFrom-Json
 if(!$installation.Completed -or !$installation.RestoreServer){throw 'An empty installed restore factory is required.'}
 foreach($relative in @('resources/functions.php')+@('threecx_backup','threecx_v20','pbx_setup_provisioner','pbx_v20_restore','pbx_paths','pbx_voicemail_policy','pbx_phone_restore','pbx_phone_migration','pbx_ringing'|ForEach-Object {'resources/classes/'+$_+'.php'})){
  $installed=Join-Path ($root+'\web') $relative;$candidate=Join-Path (Join-Path $PackageRoot 'web') $relative
  $null=Assert-NativeCleanupOrdinary $installed;$null=Assert-NativeCleanupOrdinary $candidate
  if((Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash){throw 'An installed import dependency differs from the candidate.'}
 }
 foreach($relative in 'app/voicemails/resources/voicemail_without_pins.sql'){
  $installed=Join-Path ($root+'\web') $relative;$candidate=Join-Path (Join-Path $PackageRoot 'web') $relative;$null=Assert-NativeCleanupOrdinary $installed;$null=Assert-NativeCleanupOrdinary $candidate
  if((Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash){throw 'An installed import SQL dependency differs from the candidate.'}
 }
 $null=Assert-NativeCleanupOrdinary ($root+'\php\php.exe');$null=Assert-NativeCleanupOrdinary ($root+'\php\php.ini')
 $parent=Split-Path $work -Parent
 $null=Assert-HealthUpdaterOrdinary $state $true
 if(Test-Path -LiteralPath $parent){$null=Assert-HealthUpdaterOrdinary $parent $true}else{New-Item -ItemType Directory -Path $parent|Out-Null}
 New-Item -ItemType Directory -Path $work|Out-Null
 $acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetAccessRuleProtection($true,$false);$acl.SetOwner([Security.Principal.SecurityIdentifier]'S-1-5-32-544')
 foreach($sid in 'S-1-5-18','S-1-5-32-544'){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]$sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))};Set-Acl -LiteralPath $work -AclObject $acl
 $lock=Open-NativeCleanupMaintenance
 Suspend-HealthQualificationUpdater ([ref]$updater)
 Suspend-NativeCleanupWriters ([ref]$writers)
 $env:OPENWEB_WINDOWS_NATIVE_TEST='1'
 $refusal=Invoke-BoundedThreecxPhp 'windows_threecx_import_refusals.php' @()
 $report.refusal_child=Get-ThreecxRefusalObservation $refusal
 if($refusal.ExitCode -ne 0 -or $refusal.Stderr -cne '' -or $refusal.Stdout -cnotmatch '^PASS 4 actual import early-refusal/sentinel-preservation controls; no database or PBX used\r?\n$'){
  [IO.File]::WriteAllText((Join-Path $work 'refusals.private.out'),$refusal.Stdout,[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText((Join-Path $work 'refusals.private.err'),$refusal.Stderr,[Text.UTF8Encoding]::new($false));throw 'The actual early-refusal sentinel controls did not pass.'
 }
 $mainStarted=$true;$report.main_import_started=$true
 $result=Invoke-BoundedThreecxPhp 'windows_threecx_import_native.php' @($work);$stdout=$result.Stdout;$stderr=$result.Stderr
 [IO.File]::WriteAllText((Join-Path $work 'php.private.out'),$stdout,[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText((Join-Path $work 'php.private.err'),$stderr,[Text.UTF8Encoding]::new($false))
 [IO.File]::WriteAllText((Join-Path $work 'refusals.private.out'),$refusal.Stdout,[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText((Join-Path $work 'refusals.private.err'),$refusal.Stderr,[Text.UTF8Encoding]::new($false))
 if($result.ExitCode -ne 0){try{$failure=Get-ThreecxImportFailure ($stdout|ConvertFrom-Json);if($failure.Count){$report.php_failure=$failure;$childCleanupFailed=$failure.cleanup_failed;$childCleanupProven=!$failure.cleanup_failed;if($childCleanupFailed){$report.child_cleanup_failed=$true}}}catch{};throw 'The owned installed-PHP import refused; retain private evidence.'}
 $row=$stdout|ConvertFrom-Json;Assert-ThreecxImportReport $row;$childCleanupProven=$true
 foreach($field in 'synthetic_archive_only','original_credentials_preserved','custom_greeting_media_exact','default_greeting_unchanged','groups_and_routes_restored','providers_and_dids_disabled','complete_public_rows_exact','global_config_exact','owned_schema_media_key_removed','late_wav_failure_exact_rollback'){$report[$field]=$true}
 $report.checks=[int]$row.checks;$report.refusal_checks=4;$report.php_version=$row.php_version;$report.actual_installed_php_pg_zip_restore=$true
}catch{$primary=$_;$report.state='failed';$report.error_type=$_.Exception.GetType().Name;$report.source_line=$_.InvocationInfo.ScriptLineNumber}
finally{
 $writersRestored=$true
 try{Resume-NativeCleanupWriters $writers}catch{$writersRestored=$false;if(!$primary){$primary=$_};$report.writer_restoration_failed=$true}
 try{Resume-HealthQualificationUpdater $updater}catch{$writersRestored=$false;if(!$primary){$primary=$_};$report.updater_restoration_failed=$true}
 if($lock){$lock.Dispose()}
 if($null -eq $environmentBefore){Remove-Item Env:\OPENWEB_WINDOWS_NATIVE_TEST -ErrorAction SilentlyContinue}else{$env:OPENWEB_WINDOWS_NATIVE_TEST=$environmentBefore}
 $report.original_writer_choices_restored=$writersRestored
 $report.cleanup=Get-ThreecxCleanupState $mainStarted $childCleanupProven $writersRestored $childCleanupFailed
 if(!$primary){$report.state='passed'}else{$report.state='failed'}
 [IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
}
if($primary){throw 'The actual installed synthetic V20 import did not pass; inspect the closed private report.'}
$report|ConvertTo-Json -Compress
