#Requires -RunAsAdministrator
#Requires -Version 7.4
<# SPDX-License-Identifier: AGPL-3.0-or-later.
Separate fictional source and genuinely empty replacement hosts. Supported CLI
restore with private input; real HTTPS/CSRF sign-in and SYSTEM scheduled backup.
No owner machine, public release, signer, carrier or actual OS reboot is used.
#>
[CmdletBinding()]
param(
 [Parameter(Mandatory)][ValidateSet('Source','Target')][string]$Role,
 [Parameter(Mandatory)][ValidatePattern('^[1-9][0-9]{0,19}$')][string]$BaseSuiteRunId,
 [ValidatePattern('^\d+\.\d+\.\d+$')][string]$BaseVersion='1.0.13',
 [switch]$DisposableHostedRunner
)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if(!$DisposableHostedRunner -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:RUNNER_OS -ne 'Windows' -or $env:GITHUB_REPOSITORY -ne 'embire2/openwebpbx' -or $env:GITHUB_EVENT_NAME -ne 'workflow_dispatch'){throw 'Only the explicitly disposable owned manually dispatched hosted Windows runner is authorized.'}
$os=Get-CimInstance Win32_OperatingSystem
if($os.ProductType -eq 1 -or $os.Caption -notmatch 'Windows Server 2025' -or [Environment]::OSVersion.Version.Build -lt 26100){throw 'A disposable Windows Server 2025 runner is required.'}
if(!$env:WINDOWS_RESTORE_FIXTURE_PASSPHRASE -or $env:WINDOWS_RESTORE_FIXTURE_PASSPHRASE.Length -lt 32){throw 'Root must temporarily supply the independent fictional-fixture encryption passphrase.'}
$source=Split-Path $PSScriptRoot -Parent;$root='C:\OpenWebPBX';$state=Join-Path $env:ProgramData 'OpenWebPBX';$configuration=Join-Path $env:ProgramData 'fusionpbx'
$work=Join-Path $env:RUNNER_TEMP ('openwebpbx-restore-'+$Role.ToLowerInvariant()+'-'+[Guid]::NewGuid().ToString('N'))
$public=Join-Path $env:RUNNER_TEMP ('openwebpbx-restore-'+$Role.ToLowerInvariant()+'-facts')
$transfer=Join-Path $env:RUNNER_TEMP 'openwebpbx-restore-transfer'
$phase='verified qualified package';$installed=$false;$pki=$null;$inputFile=$null;$hostsBefore=$null;$hostsExpected=$null;$settings=$null;$python=$null;$winps=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$facts=[ordered]@{schema=1;role=$Role.ToLowerInvariant();run_id=$env:GITHUB_RUN_ID;source_commit=$env:GITHUB_SHA;state='running';gates=@{};actual_os_boot='unqualified';carrier='unqualified';owner_upgrade='unqualified';cleanup='pending'}
# Import only the reviewed artifact/process and bounded IIS cleanup functions.
# Do not dot-source the executable updater stage or its environment guards.
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'windows-updater-qualification.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The independently reviewed artifact helper no longer parses.'}
foreach($name in 'Check','Hash','WriteJson','PrivateDirectory','SafeRelative','ExpandSafe','Api','Artifact','CheckedProcess','NativeVersions','StopQualificationIis'){
 $nodes=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true));if($nodes.Count -ne 1){throw 'One exact qualification helper is required.'};Invoke-Expression $nodes[0].Extent.Text
}
. (Join-Path $PSScriptRoot 'windows-suite-pki.ps1')
function Derived([string]$Label){
 $h=[Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes($env:WINDOWS_RESTORE_FIXTURE_PASSPHRASE))
 try{return $h.ComputeHash([Text.Encoding]::UTF8.GetBytes('openweb-restore-qualification/v1/'+$Label))}finally{$h.Dispose()}
}
function Fixture([string]$Action){
 CheckedProcess "$root\php\php.exe" @((Join-Path $PSScriptRoot 'windows-restore-qualification.php'),$Action,$inputFile) ('php-'+$Action) "$root\web" 120000
}
function SafeRestoreFixtureFailure($Record){
 if($null -eq $Record -or $Record -is [array]){return $null}
 $keys=@('schema','action','step','reason','error_type','source_basename','source_line')
 if($Record -is [System.Collections.IDictionary]){$actual=@($Record.Keys)}else{$actual=@($Record.PSObject.Properties.Name)}
 if($actual.Count -ne $keys.Count -or @($actual|Where-Object {$_ -cnotin $keys}).Count){return $null}
 if(($Record.schema -isnot [int] -and $Record.schema -isnot [long]) -or $Record.schema -ne 1 -or $Record.action -isnot [string] -or $Record.action -cne 'cleanup'){return $null}
 $steps=@('initialization','owned_lookup','gateway_guard','native_quiescence','native_contacts','backup_inventory','owned_rows_delete','update_commands_delete','backup_commands_delete','drafts_delete','archive_files_delete','cache_cleanup','native_reload','factory_guard','input_commit')
 $reasons=@('owned_service_lookup','enabled_gateway','active_calls','phone_identity','live_contact','missing_backup_command','backup_command_guard','backup_metadata_guard','backup_link','backup_integrity','original_command','command_ownership','backup_command_changed','original_draft','draft_ownership','archive_unlink','factory_not_empty','database_error','json_error','type_error','runtime_guard','external_error')
 $types=@('RuntimeException','PDOException','JsonException','TypeError','ValueError','Error','Exception','external_error')
 $sources=@('windows-restore-qualification.php','database.php','pbx_paths.php','cache.php','event_socket.php','config.php','external_component')
 if($Record.step -isnot [string] -or $Record.step -cnotin $steps -or $Record.reason -isnot [string] -or $Record.reason -cnotin $reasons -or $Record.error_type -isnot [string] -or $Record.error_type -cnotin $types -or $Record.source_basename -isnot [string] -or $Record.source_basename -cnotin $sources){return $null}
 if(($Record.source_line -isnot [int] -and $Record.source_line -isnot [long]) -or $Record.source_line -le 0 -or $Record.source_line -ge 1000000){return $null}
 return @{schema=1;action='cleanup';step=$Record.step;reason=$Record.reason;error_type=$Record.error_type;source_basename=$Record.source_basename;source_line=$Record.source_line}
}
function SafeRestorePeerFailures($Records,[switch]$Receiver){
 $maximum=if($Receiver){2}else{12}
 if($Records -isnot [array] -or $Records.Count -lt 1 -or $Records.Count -gt $maximum){return $null}
 $out=@();$keys=@('peer_index','stage','status_code','error_type','source_basename','source_line')
 if($Receiver){$keys+='winerror_kind'}
 foreach($row in $Records){
  if($null -eq $row -or $row -is [array]){return $null}
  if($row -is [Collections.IDictionary]){$actual=@($row.Keys)}else{$actual=@($row.PSObject.Properties.Name)}
  if($actual.Count -ne $keys.Count -or @($actual|Where-Object {$_ -cnotin $keys}).Count){return $null}
  if(($row.peer_index -isnot [int] -and $row.peer_index -isnot [long]) -or $row.peer_index -notin 0,1 -or ($row.status_code -isnot [int] -and $row.status_code -isnot [long]) -or !($row.status_code -eq 0 -or ($row.status_code -ge 100 -and $row.status_code -le 699)) -or ($row.source_line -isnot [int] -and $row.source_line -isnot [long]) -or $row.source_line -lt 0 -or $row.source_line -ge 1000000){return $null}
  $stages=if($Receiver){@('receiver')}else{@('unregister','registration_ids','flush_registration','contact_absence','peer_close')}
  if($row.stage -isnot [string] -or $row.stage -cnotin $stages -or $row.error_type -isnot [string] -or $row.error_type -cnotin @('RuntimeError','AssertionError','ValueError','TypeError','KeyError','AttributeError','OSError','TimeoutError','ConnectionError','ConnectionResetError','ConnectionAbortedError','ConnectionRefusedError','BrokenPipeError','SSLError','SSLEOFError','SSLCertVerificationError','JSONDecodeError','UnicodeDecodeError','check_failed','external_error') -or $row.source_basename -isnot [string] -or $row.source_basename -cnotin @('windows-restore-qualification.py','windows-native-acceptance.py','pbx_v20_restore_native.py','sip_trunk_live.py','socket.py','ssl.py','decoder.py','external_component')){return $null}
  $fields=@{peer_index=$row.peer_index;stage=$row.stage;status_code=$row.status_code;error_type=$row.error_type;source_basename=$row.source_basename;source_line=$row.source_line}
  if($Receiver){if($row.winerror_kind -isnot [string] -or $row.winerror_kind -cnotin @('connection_reset_10054','other_winerror','unavailable')){return $null};$fields.winerror_kind=$row.winerror_kind}
  $out+=$fields
 }
 return ,$out
}
function SafeRestoreSchemaFailure($Record,[string]$Action){
 if($Record.error_type -isnot [string] -or $Record.error_type -cne 'ValueError' -or $Record.source_basename -isnot [string] -or $Record.source_basename -cne 'windows-restore-qualification.py'){return $null}
 $labels=if($Action -ceq 'late-restore'){@('target-wrongpass','target-recovered')}elseif($Action -ceq 'restore'){@('target-restored')}else{@()}
 if($Record.comparison_label -isnot [string] -or $Record.comparison_label -cnotin $labels){return $null}
 $groups=$Record.schema_groups_differ
 if($null -eq $groups -or $groups -is [array]){return $null}
 if($groups -is [Collections.IDictionary]){$keys=@($groups.Keys)}else{$keys=@($groups.PSObject.Properties.Name)}
 if($keys.Count -ne 3 -or @($keys|Where-Object {$_ -cnotin @('schema','tables','columns')}).Count){return $null}
 foreach($name in 'schema','tables','columns'){if($groups.$name -isnot [bool]){return $null}}
 if(!$groups.schema -and !$groups.tables -and !$groups.columns){return $null}
 return @{comparison_label=$Record.comparison_label;schema_groups_differ=@{schema=$groups.schema;tables=$groups.tables;columns=$groups.columns}}
}
function SafeRestoreMailboxFailure($Record,[string]$Action){
 if($Action -cne 'native-target' -or $null -eq $Record -or $Record -is [array]){return $null}
 $allowed=@('mailbox_pin_free','mailbox_tutorial_skip_sent','mailbox_prompt_password_seen','mailbox_prompt_tutorial_seen','mailbox_prompt_main_menu_seen','mailbox_prompt_auth_failed_seen','mailbox_prompt_recording_seen','mailbox_observer_failed')
 if($Record -is [Collections.IDictionary]){$keys=@($Record.Keys)}else{$keys=@($Record.PSObject.Properties.Name)}
 if($keys.Count -lt 1 -or $keys.Count -gt 8){return $null}
 $safe=@{}
 foreach($key in $keys){if($key -cnotin $allowed -or $Record.$key -isnot [bool]){return $null};$safe[$key]=$Record.$key}
 return $safe
}
function SafeRestoreToneFailure($Record,[string]$Action){
 if($Action -cnotin @('native-source','native-target') -or $null -eq $Record -or $Record -is [Array]){return $null}
 $keys=@('expected_hz','sample_count','tone_ratio','sent_packets','received_packets','unexpected_audio_packets')
 if($Record -is [Collections.IDictionary]){$actual=@($Record.Keys)}else{$actual=@($Record.PSObject.Properties.Name)}
 if($actual.Count -ne $keys.Count -or @($actual|Where-Object {$_ -cnotin $keys}).Count){return $null}
 if(($Record.expected_hz -isnot [int] -and $Record.expected_hz -isnot [long]) -or $Record.expected_hz -notin 440,550 -or ($Record.sample_count -isnot [int] -and $Record.sample_count -isnot [long]) -or $Record.sample_count -lt 0 -or $Record.sample_count -gt 16000){return $null}
 $ratio=$Record.tone_ratio
 if($null -ne $ratio -and (($ratio -isnot [double] -and $ratio -isnot [int] -and $ratio -isnot [long]) -or [double]::IsNaN($ratio) -or [double]::IsInfinity($ratio) -or $ratio -lt 0 -or $ratio -gt 2)){return $null}
 foreach($key in 'sent_packets','received_packets','unexpected_audio_packets'){$value=$Record.$key;if($null -ne $value -and (($value -isnot [int] -and $value -isnot [long]) -or $value -lt 0 -or $value -gt 10000000)){return $null}}
 return @{expected_hz=$Record.expected_hz;sample_count=$Record.sample_count;tone_ratio=$ratio;sent_packets=$Record.sent_packets;received_packets=$Record.received_packets;unexpected_audio_packets=$Record.unexpected_audio_packets}
}
function SafeRestoreCliFailure($Record){
 if($null -eq $Record -or $Record -is [Array]){return $null}
 $keys=@('exit_code','error_type','category','source_frames');$actual=@();if($Record -is [Collections.IDictionary]){$actual=@($Record.Keys)}else{$actual=@($Record.PSObject.Properties.Name)}
 if($actual.Count -ne $keys.Count -or @($actual|Where-Object {$_ -cnotin $keys}).Count){return $null}
 if($null -ne $Record.exit_code -and (($Record.exit_code -isnot [int] -and $Record.exit_code -isnot [long]) -or $Record.exit_code -lt 0 -or $Record.exit_code -gt 255)){return $null}
 if($Record.error_type -isnot [string] -or $Record.error_type -cnotin @('BackupError','PermissionError','FileNotFoundError','OSError','ValueError','TypeError','RuntimeError','JSONDecodeError','other','unavailable') -or $Record.category -isnot [string] -or $Record.category -cnotin @('operation_busy','operation_lock_review','activation_server_guard','activation_selection_guard','activation_service_missing','required_tool_failed','required_tool_unavailable','private_control_unavailable','unclassified') -or $Record.source_frames -isnot [Array] -or $Record.source_frames.Count -gt 4){return $null}
 $frames=@();foreach($frame in $Record.source_frames){
  if($null -eq $frame -or $frame -is [Array]){return $null};$fields=@();if($frame -is [Collections.IDictionary]){$fields=@($frame.Keys)}else{$fields=@($frame.PSObject.Properties.Name)}
  if($fields.Count -ne 3 -or @($fields|Where-Object {$_ -cnotin @('source_basename','source_line','function')}).Count -or $frame.source_basename -isnot [string] -or $frame.source_basename -cne 'backups.py' -or $frame.function -isnot [string] -or $frame.function -cnotin @('main','activate','exclusive_guard','control','run','read_settings','ordinary','reparse','atomic_json','held','lock_file','unlock_file') -or ($frame.source_line -isnot [int] -and $frame.source_line -isnot [long]) -or $frame.source_line -le 0 -or $frame.source_line -ge 1000000){return $null}
  $frames+=@{source_basename='backups.py';source_line=$frame.source_line;function=$frame.function}
 }
 return @{exit_code=$Record.exit_code;error_type=$Record.error_type;category=$Record.category;source_frames=@($frames)}
}
function SafeRestoreServiceActivationFailure($Record){
 if($null -eq $Record -or $Record -is [Array]){return $null}
 $keys=@('stage','service','state','start_mode','is_expected_identity','exit_code','service_specific_exit_code')
 $actual=@();if($Record -is [Collections.IDictionary]){$actual=@($Record.Keys)}else{$actual=@($Record.PSObject.Properties.Name)}
 if($actual.Count -ne $keys.Count -or @($actual|Where-Object {$_ -cnotin $keys}).Count){return $null}
 if($Record.stage -isnot [string] -or $Record.stage -cne 'service_running_auto' -or $Record.service -isnot [string] -or $Record.service -cnotin @('FreeSWITCH','OpenWebPBX','OpenWebPBXUpdater')){return $null}
 if($Record.state -isnot [string] -or $Record.state -cnotin @('Running','Stopped','Start Pending','Stop Pending','Continue Pending','Pause Pending','Paused','Unknown','unavailable','unknown') -or $Record.start_mode -isnot [string] -or $Record.start_mode -cnotin @('Auto','Manual','Disabled','Boot','System','Unknown','unavailable','unknown') -or $Record.is_expected_identity -isnot [bool]){return $null}
 foreach($key in 'exit_code','service_specific_exit_code'){$v=$Record.$key;if($null -ne $v -and (($v -isnot [int] -and $v -isnot [long]) -or $v -lt 0 -or $v -gt 4294967295)){return $null}}
 return @{stage=$Record.stage;service=$Record.service;state=$Record.state;start_mode=$Record.start_mode;is_expected_identity=$Record.is_expected_identity;exit_code=$Record.exit_code;service_specific_exit_code=$Record.service_specific_exit_code}
}
function AssertRestoredServiceActivation([string]$Name){
 if($Name -cnotin @('FreeSWITCH','OpenWebPBX','OpenWebPBXUpdater')){throw 'Only the three fixed restored fixture services may be observed.'}
 $service=$null
 try{
  $service=Get-CimInstance Win32_Service -Filter ("Name='"+$Name+"'")
  Check ($service.State -eq 'Running' -and $service.StartMode -eq 'Auto') 'Every explicitly activated service must be Running with automatic startup.'
 }catch{
  try{
   $state='unavailable';$mode='unavailable';$identity=$false;$nativeExit=$null;$specificExit=$null
   if($null -ne $service){
    $state=if($service.State -is [string] -and $service.State -cin @('Running','Stopped','Start Pending','Stop Pending','Continue Pending','Pause Pending','Paused','Unknown')){$service.State}else{'unknown'}
    $mode=if($service.StartMode -is [string] -and $service.StartMode -cin @('Auto','Manual','Disabled','Boot','System','Unknown')){$service.StartMode}else{'unknown'}
    $accounts=if($Name -ceq 'OpenWebPBX'){@('NT AUTHORITY\LocalService','NT AUTHORITY\Local Service')}else{@('LocalSystem','NT AUTHORITY\SYSTEM')}
    $identity=[bool]($service.Name -is [string] -and $service.Name -ceq $Name -and $service.StartName -is [string] -and $service.StartName -in $accounts)
    foreach($item in @(@('ExitCode','exit'),@('ServiceSpecificExitCode','specific'))){$v=$service.($item[0]);if(($v -is [int] -or $v -is [long] -or $v -is [uint32]) -and $v -ge 0 -and $v -le 4294967295){if($item[1] -ceq 'exit'){$nativeExit=[long]$v}else{$specificExit=[long]$v}}}
   }
   $_.Exception.Data['restore_service_activation']=@{stage='service_running_auto';service=$Name;state=$state;start_mode=$mode;is_expected_identity=$identity;exit_code=$nativeExit;service_specific_exit_code=$specificExit}
  }catch{}
  throw
 }
}
function NativeFixture([string]$Action){
 $script:phase=$Action
 # The extracted interpreter remains independent of private installed state.
 try{CheckedProcess $python @('-I','-B',(Join-Path $PSScriptRoot 'windows-restore-qualification.py'),'--input',$inputFile,'--action',$Action) ('restore-'+$Action) $source 1200000}
 catch{
  $safe=$null
  $privateOutput=Join-Path $work ('restore-'+$Action+'.out')
  if(Test-Path $privateOutput){try{$safe=Get-Content $privateOutput -Raw|ConvertFrom-Json;if($safe.state -eq 'failed' -and $safe.error_type -match '^[A-Za-z0-9_.]{1,120}$' -and $safe.source_basename -match '^[A-Za-z0-9_.-]{1,120}$' -and ($safe.source_line -is [long] -or $safe.source_line -is [int]) -and $safe.source_line -ge 0 -and $safe.source_line -lt 1000000){$facts.native_failure=@{error_type=$safe.error_type;source_basename=$safe.source_basename;source_line=$safe.source_line;active_case=$Action};$schemaFailure=SafeRestoreSchemaFailure $safe $Action;if($schemaFailure){$facts.native_failure.comparison_label=$schemaFailure.comparison_label;$facts.native_failure.schema_groups_differ=$schemaFailure.schema_groups_differ};if($Action -ceq 'cleanup'){$observation=SafeRestoreFixtureFailure $safe.fixture_failure;if($observation){$facts.native_failure.fixture_failure=$observation}};if($Action -ceq 'late-restore' -and $safe.error_type -ceq 'ValueError' -and $safe.source_basename -ceq 'windows-restore-qualification.py' -and $safe.failure_kind -is [string] -and $safe.failure_kind -ceq 'non_distinct_installation_identity' -and $safe.identity_field -is [string] -and $safe.identity_field -cin @('hardware_uuid_hmac','hostname_hmac','certificate_sha256','template_key_sha256')){$facts.native_failure.failure_kind=$safe.failure_kind;$facts.native_failure.identity_field=$safe.identity_field};if($Action -cin @('native-source','native-target')){$peerFailures=SafeRestorePeerFailures $safe.peer_cleanup_failure;if($peerFailures){$facts.native_failure.peer_cleanup_failure=$peerFailures};$receivers=SafeRestorePeerFailures $safe.peer_receiver_failure -Receiver;if($receivers){$facts.native_failure.peer_receiver_failure=$receivers};if($safe.native_substage -is [string] -and $safe.native_substage -cin @('registration','internal_invite','internal_ack','internal_media','internal_hangup','answered_recording','voicemail_isolation','voicemail_deposit','mailbox_invite','mailbox_login_prompt','mailbox_main_prompt','mailbox_recording_playback','mailbox_media','mailbox_hangup','peer_cleanup','peer_receiver')){$facts.native_failure.native_substage=$safe.native_substage};$allowed=if($Action -ceq 'native-source'){@('source_real_two_way_recorded_call','source_real_native_voicemail_deposit')}else{@('restored_original_credentials_two_way_decoded_native_audio','restored_original_native_voicemail_121_pin_free_retrieval')};if($safe.completed_native_cases -is [array] -and $safe.completed_native_cases.Count -le 2 -and @($safe.completed_native_cases|Select-Object -Unique).Count -eq $safe.completed_native_cases.Count -and @($safe.completed_native_cases|Where-Object {$_ -isnot [string] -or $_ -cnotin $allowed}).Count -eq 0){$cases=@($allowed|Where-Object {$_ -cin $safe.completed_native_cases});$facts.native_failure.completed_native_cases=$cases;foreach($name in $cases){$facts.gates[$name]='passed'}}}}}catch{}}
  if($Action -ceq 'native-target' -and $facts.native_failure){try{
   if($safe.native_substage -is [string] -and $safe.native_substage -ceq 'mailbox_tutorial_complete'){$facts.native_failure.native_substage=$safe.native_substage}
   $mailbox=SafeRestoreMailboxFailure $safe.mailbox_observation $Action
   if($mailbox){$facts.native_failure.mailbox_observation=$mailbox}
  }catch{}}
  try{
   if($Action -cin @('native-source','native-target') -and $facts.native_failure -and $safe.state -ceq 'failed' -and $safe.error_type -ceq 'AssertionError' -and $safe.source_basename -ceq 'pbx_v20_restore_native.py' -and $safe.native_substage -cin @('internal_media','mailbox_media') -and (Test-Path -LiteralPath $privateOutput -PathType Leaf)){
    $toneOutput=Get-Item -LiteralPath $privateOutput -Force
    if($toneOutput.Length -gt 0 -and $toneOutput.Length -le 1048576 -and ($toneOutput.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0){$tone=SafeRestoreToneFailure $safe.tone_observation $Action;if($tone){$facts.native_failure.tone_observation=$tone}}
   }
  }catch{}
  try{
   if($Action -cin @('export-source','target-backup') -and $facts.native_failure -and (Test-Path -LiteralPath $privateOutput -PathType Leaf)){
    $queryOutput=Get-Item -LiteralPath $privateOutput -Force
    if($queryOutput.Length -gt 0 -and $queryOutput.Length -le 1048576 -and ($queryOutput.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and $safe.state -ceq 'failed' -and $safe.error_type -is [string] -and $safe.error_type -ceq 'BackupError' -and $safe.source_basename -is [string] -and $safe.source_basename -ceq 'backups.py' -and ($safe.query_caller_line -is [int] -or $safe.query_caller_line -is [long]) -and $safe.query_caller_line -gt 0 -and $safe.query_caller_line -lt 1000000){$facts.native_failure.query_caller_line=$safe.query_caller_line}
   }
  }catch{}
  try{
   if($Action -cin @('export-source','late-restore','restore','activate-calls','job','activate-updates','activate-backups','activate-updates-backups','target-backup') -and $facts.native_failure -and $safe.state -ceq 'failed' -and $safe.error_type -is [string] -and $safe.error_type -ceq 'RuntimeError' -and $safe.source_basename -is [string] -and $safe.source_basename -ceq 'windows-restore-qualification.py' -and (Test-Path -LiteralPath $privateOutput -PathType Leaf)){
    $cliOutput=Get-Item -LiteralPath $privateOutput -Force
    if($cliOutput.Length -gt 0 -and $cliOutput.Length -le 1048576 -and ($cliOutput.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0){$cli=SafeRestoreCliFailure $safe.cli_failure;if($cli){$facts.native_failure.cli_failure=$cli}}
   }
  }catch{}
  throw
 }
}
function AssertBackupTask {
 $task=Get-ScheduledTask -TaskName 'OpenWebPBX-Backups' -ErrorAction Stop
 Check ($task.Principal.UserId -in 'SYSTEM','S-1-5-18' -and $task.Principal.RunLevel -eq 'Highest' -and @($task.Actions).Count -eq 1 -and $task.Actions[0].Execute -eq "$root\backup-runtime\python.exe" -and $task.Actions[0].Arguments -eq '-I "C:\OpenWebPBX\tools\backups.py" worker') 'The real installed backup worker task must retain its exact SYSTEM action.'
 Check (@($task.Triggers|Where-Object {$_.CimClass.CimClassName -eq 'MSFT_TaskBootTrigger'}).Count -eq 1) 'The real owned task must retain its startup trigger; actual OS boot remains unqualified.'
 $deadline=[DateTime]::UtcNow.AddSeconds(60)
 do{$info=Get-ScheduledTaskInfo -InputObject $task;if($info.LastTaskResult -eq 0 -and $info.LastRunTime -gt [DateTime]::Now.AddMinutes(-15)){break};Start-Sleep -Milliseconds 500}while([DateTime]::UtcNow -lt $deadline)
 Check ($info.LastTaskResult -eq 0 -and $info.LastRunTime -gt [DateTime]::Now.AddMinutes(-15)) 'Actual scheduled SYSTEM backup must finish successfully.'
 $facts.gates.actual_system_task_principal_action_execution='passed'
}
function EnableTargetTls([switch]$Prepared){
 $script:phase=if($Prepared){'offline target TLS preparation'}else{'independent source phone TLS'}
 $arguments=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',"$root\tools\Enable-PhoneTLS.ps1",'-CertificateThumbprint',$pki.leaf.Thumbprint)
 if($Prepared){$arguments+='-PrepareRestored'}
 CheckedProcess $winps $arguments ('tls-'+$Role.ToLowerInvariant()) $source 300000
}
function HeldServiceRestart {
 $script:phase='controlled held updater-service restart'
 # This is service-start recovery proof, never an operating-system boot claim.
 $restore=Join-Path $state 'backup-restore'
 foreach($selection in 'calls','jobs','updates','backups'){Check (Test-Path "$restore\hold-$selection") 'Every restored class must remain held before the controlled service start.'}
 Check ((Get-Service FreeSWITCH).Status -eq 'Stopped' -and (Get-Service OpenWebPBX).Status -eq 'Stopped') 'Calls and jobs must be stopped before this held start.'
 $before=@(Get-Content $inputFile -Raw|ConvertFrom-Json);$before=$before[0]
 try{
  Set-Service OpenWebPBXUpdater -StartupType Manual;Start-Service OpenWebPBXUpdater
  $deadline=[DateTime]::UtcNow.AddSeconds(30)
  do{Start-Sleep -Milliseconds 500;$service=Get-Service OpenWebPBXUpdater;if($service.Status -ne 'Running'){throw 'The held genuine updater exited before its recovery gate.'}}while([DateTime]::UtcNow -lt $deadline)
  foreach($selection in 'calls','jobs','updates','backups'){Check (Test-Path "$restore\hold-$selection") 'Service startup removed a restore hold.'}
  Check ((Get-Service FreeSWITCH).Status -eq 'Stopped' -and (Get-Service OpenWebPBX).Status -eq 'Stopped') 'Held service startup must not start calls or jobs.'
  Fixture 'job-status';$job=Get-Content (Join-Path $work 'php-job-status.out') -Raw|ConvertFrom-Json
  Check ($job.state -eq 'waiting' -and $job.attempts -eq 0) 'Held worker startup claimed the restored future job.'
  $facts.gates.controlled_service_start_preserves_all_holds='passed'
 }finally{Stop-Service OpenWebPBXUpdater -ErrorAction SilentlyContinue;Set-Service OpenWebPBXUpdater -StartupType Disabled}
}
function SourceTransfer {
 # Same current workflow still runs in the target job. Require the exact
 # completed successful SOURCE JOB, not overall run success before target ends.
 $run=Api ('actions/runs/'+$env:GITHUB_RUN_ID)
 Check ($run.repository.full_name -eq 'embire2/openwebpbx' -and $run.head_repository.full_name -eq 'embire2/openwebpbx' -and $run.event -eq 'workflow_dispatch' -and $run.path -eq '.github/workflows/windows-restore-qualification.yml' -and $run.head_sha -eq $env:GITHUB_SHA) 'The exact owned current restore workflow is required.'
 $jobs=@((Api ('actions/runs/'+$env:GITHUB_RUN_ID+'/jobs?per_page=100')).jobs|Where-Object name -eq 'Fictional encrypted backup source')
 Check ($jobs.Count -eq 1 -and $jobs[0].status -eq 'completed' -and $jobs[0].conclusion -eq 'success') 'The independent source job must have passed and cleaned up.'
 $script:sourceHostedJobId=[string]$jobs[0].id
 $name='openwebpbx-windows-restore-transfer-'+$env:GITHUB_RUN_ID
 $items=@((Api ('actions/runs/'+$env:GITHUB_RUN_ID+'/artifacts?per_page=100')).artifacts|Where-Object {$_.name -eq $name -and !$_.expired})
 Check ($items.Count -eq 1 -and $items[0].digest -match '^sha256:[a-f0-9]{64}$' -and $items[0].size_in_bytes -le 8GB) 'One bounded exact fictional transfer artifact is required.'
 $item=$items[0];$handler=[Net.Http.HttpClientHandler]::new();$handler.AllowAutoRedirect=$false;$client=[Net.Http.HttpClient]::new($handler)
 $client.DefaultRequestHeaders.Authorization=[Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer',$env:GH_TOKEN);$client.DefaultRequestHeaders.UserAgent.ParseAdd('OpenWebPBX-Private-Restore-Qualification')
 try{$response=$client.GetAsync('https://api.github.com/repos/embire2/openwebpbx/actions/artifacts/'+$item.id+'/zip').GetAwaiter().GetResult();Check ([int]$response.StatusCode -eq 302) 'The authenticated transfer redirect is unavailable.';$location=$response.Headers.Location}finally{$client.Dispose();$handler.Dispose()}
 Check ($location.IsAbsoluteUri -and $location.Scheme -eq 'https') 'Transfer artifact storage must use trusted HTTPS.'
 $archive=Join-Path $work 'transfer.zip';Invoke-WebRequest $location -MaximumRedirection 0 -OutFile $archive
 Check ((Get-Item $archive).Length -eq $item.size_in_bytes -and (Hash $archive) -eq $item.digest.Substring(7)) 'The complete artifact digest differs.'
 Check (!(Test-Path $transfer)) 'A previous transfer must not be reused.';PrivateDirectory $transfer;ExpandSafe $archive $transfer
 Check (@(Get-ChildItem -LiteralPath $transfer -Recurse -File).Count -eq 2 -and (Test-Path "$transfer\fixture.owpbx") -and (Test-Path "$transfer\capsule.json")) 'Only fictional ciphertext and authenticated redacted evidence may be transferred.'
}
try{
 PrivateDirectory $work
 Check (!(Test-Path $root) -and !(Test-Path "$state\installation.json") -and !(Test-Path "$configuration\config.conf") -and !(Get-Service FreeSWITCH -ErrorAction SilentlyContinue)) 'Each job must be genuinely empty and refuses an existing owner installation.'
 $candidate=Artifact $BaseSuiteRunId ('openwebpbx-windows-suite-candidate-'+$BaseSuiteRunId) '.github/workflows/windows-suite.yml'
 $report=Artifact $BaseSuiteRunId ('openwebpbx-windows-suite-facts-'+$BaseSuiteRunId) '.github/workflows/windows-suite.yml'
 $baseFacts=Get-Content (Join-Path $report.directory 'qualification.json') -Raw|ConvertFrom-Json
 Check ($baseFacts.schema -eq 1 -and $baseFacts.run_id -eq $BaseSuiteRunId -and $baseFacts.source_commit -eq $candidate.run.head_sha -and $baseFacts.state -in 'partial','passed') 'Exact qualified baseline facts are required.'
 foreach($gate in 'fresh','native_sip_audio','backups','direct_113_helper_reapply','direct_failure_rollback','restore_gate_startup'){Check ($baseFacts.gates.$gate -eq 'passed') 'Every essential real baseline gate must pass.'}
 if([version]$BaseVersion -ge [version]'1.0.20'){Check ($baseFacts.gates.meeting_transport -eq 'passed') 'The current Windows meeting transport must also be qualified.'}
 Check ($baseFacts.cleanup -eq 'owned services stopped, SFTP receiver/account removed, hostname removed, activation holds preserved') 'The qualified baseline must have completed its exact owned cleanup.'
 $base=Join-Path $candidate.directory ("openwebpbx-$BaseVersion-windows-x64.zip")
 Check ((Hash $base) -eq $baseFacts.candidate_artifact.sha256 -and $baseFacts.artifacts.candidate_sha256 -eq $baseFacts.candidate_artifact.sha256 -and $baseFacts.candidate_artifact.filename -eq ("openwebpbx-$BaseVersion-windows-x64.zip") -and $baseFacts.candidate_artifact.private_exclusions -eq 'passed' -and $baseFacts.candidate_artifact.verified_before_credentials -eq $true) 'The exact independently audited package and BOTH candidate evidence fields must match the qualification.'
 CheckedProcess 'python.exe' @((Join-Path $PSScriptRoot 'windows_candidate_archive.py'),'--archive',$base,'--version',$BaseVersion,'--sha256',$baseFacts.candidate_artifact.sha256) 'verify-qualified-package'
 $expanded=Join-Path $work 'package';PrivateDirectory $expanded;ExpandSafe $base $expanded
 $packages=@(Get-ChildItem $expanded -Directory);Check ($packages.Count -eq 1) 'One exact release package root is required.';$package=$packages[0].FullName;$python=Join-Path $package 'backup-runtime/python.exe';NativeVersions $package $BaseVersion|Out-Null
 if($Role -eq 'Target'){SourceTransfer}
 $binding=$env:GITHUB_RUN_ID+'/'+$env:GITHUB_SHA
 $scope=[Convert]::ToHexString((Derived ('scope/'+$binding))).ToLowerInvariant().Substring(0,24)
 $qa=Join-Path $state ('restore-qualification/'+$scope);PrivateDirectory $qa;$inputFile=Join-Path $qa 'input.json'
 $sourcePassword='A9!'+[Convert]::ToHexString((Derived ('administrator/source/'+$binding))).ToLowerInvariant()
 $targetPassword='A9!'+[Convert]::ToHexString((Derived ('administrator/target/'+$binding))).ToLowerInvariant()
 $password=if($Role -eq 'Source'){$sourcePassword}else{$targetPassword};$email='restoreqa@example.invalid'
 $settings=@{schema=1;disposable=$true;github_actions=$true;runner_environment='github-hosted';repository='embire2/openwebpbx';scope=$scope;run_id=$env:GITHUB_RUN_ID;source_commit=$env:GITHUB_SHA;role=$Role.ToLowerInvariant();admin_email=$email;admin_password=$password;source_admin_password=$sourcePassword;passphrase=$env:WINDOWS_RESTORE_FIXTURE_PASSPHRASE;service_name=('Fictional restore PBX '+$scope);source_root=$source;base_suite_run_id=$BaseSuiteRunId;candidate_sha256=(Hash $base);transfer_directory=$transfer}
 $jobName=if($Role -eq 'Source'){'Fictional encrypted backup source'}else{'Independent clean replacement restore'}
 $currentJobs=@((Api ('actions/runs/'+$env:GITHUB_RUN_ID+'/jobs?per_page=100')).jobs|Where-Object name -eq $jobName)
 Check ($currentJobs.Count -eq 1 -and $currentJobs[0].status -eq 'in_progress' -and $currentJobs[0].runner_name -eq $env:RUNNER_NAME -and $currentJobs[0].id -gt 0) 'The actual current authenticated hosted job and runner binding are required.'
 $settings.hosted_job_id=[string]$currentJobs[0].id
 if($Role -eq 'Target'){$settings.source_hosted_job_id=$sourceHostedJobId;Check ($settings.hosted_job_id -ne $sourceHostedJobId) 'The replacement cannot reuse the authenticated source job.'}
 WriteJson $inputFile $settings;[IO.File]::WriteAllBytes((Join-Path $qa 'audit.key'),(Derived 'audit'))
 $machineSid=(Get-LocalUser | Where-Object {$_.SID.Value -match '-500$'}).SID.Value -replace '-500$',''
 $h=[Security.Cryptography.HMACSHA256]::new((Derived 'machine-identity'));try{$settings.machine_sid_hmac=[Convert]::ToHexString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($machineSid))).ToLowerInvariant()}finally{$h.Dispose()}
 $hardware=[string](Get-CimInstance Win32_ComputerSystemProduct).UUID;$hardware=$hardware.ToUpperInvariant()
 Check ($hardware -match '^[A-F0-9]{8}(-[A-F0-9]{4}){3}-[A-F0-9]{12}$' -and $hardware.Replace('-','') -notin ('0'*32),('F'*32)) 'A validated nonplaceholder hardware UUID is required.'
 $h=[Security.Cryptography.HMACSHA256]::new((Derived 'machine-identity'))
 try{foreach($entry in @{hardware_uuid_hmac=$hardware;hostname_hmac=[Environment]::MachineName.ToUpperInvariant();runner_name_hmac=$env:RUNNER_NAME}.GetEnumerator()){$settings[$entry.Key]=[Convert]::ToHexString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($entry.Value))).ToLowerInvariant()}}finally{$h.Dispose()}
 Remove-Item Env:\WINDOWS_RESTORE_FIXTURE_PASSPHRASE
 $phase='actual separate fresh installer'
 $request=Join-Path $work 'install-input.json';WriteJson $request @{package=$package;admin=$email;password=$password}
 $wrapper=Join-Path $work 'install-private.ps1'
 [IO.File]::WriteAllText($wrapper,@'
param([string]$InputFile)
$ErrorActionPreference='Stop'
$r=Get-Content -LiteralPath $InputFile -Raw|ConvertFrom-Json
& (Join-Path $r.package 'Install-OpenWebPBX.ps1') -RestoreServer -LocalCertificate -DomainName windowsqa.example.invalid -PublicAddress 127.0.0.1 -AdminEmail $r.admin -AdminPassword (ConvertTo-SecureString $r.password -AsPlainText -Force)
'@,[Text.UTF8Encoding]::new($false))
 $installed=$true;CheckedProcess $winps @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$wrapper,$request) 'fresh-install' $source 2400000
 $password=$null;$sourcePassword=$null;$targetPassword=$null
 $hosts=Join-Path $env:SystemRoot 'System32/drivers/etc/hosts';$hostsBefore=[IO.File]::ReadAllBytes($hosts)
 Check ([Text.Encoding]::UTF8.GetString($hostsBefore) -notmatch 'windowsqa\.example\.invalid') 'Do not reuse an existing hostname fixture.'
 [IO.File]::AppendAllText($hosts,"`r`n127.0.0.1 windowsqa.example.invalid # OpenWeb PBX restore $scope`r`n",[Text.UTF8Encoding]::new($false))
 $hostsExpected=[IO.File]::ReadAllBytes($hosts)
 $phase='independent target-specific trusted PKI';$pki=Start-SuiteRecoveryPki $package $source $work
 $settings.web_ca=Join-Path $pki.directory 'evidence/fixture-root.pem';$settings.certificate_sha256=Hash (Join-Path $pki.directory 'evidence/fixture-leaf.pem')
 # Hash the actual native helper's leaf bytes; refuse absent evidence rather
 # than infer a thumbprint as a certificate-content checksum.
 WriteJson $inputFile $settings;$settings=$null
 $env:OPENWEB_WINDOWS_RESTORE_TEST='1';Fixture 'baseline';NativeFixture 'setup'
 $facts.base_suite_run_id=$BaseSuiteRunId;$facts.base_archive_sha256=Hash $base;$facts.base_source_commit=$baseFacts.source_commit
 if($Role -eq 'Source'){
  EnableTargetTls;NativeFixture 'native-source';NativeFixture 'export-source';AssertBackupTask
 }else{
  $originalTaskStates=@{}
  foreach($name in 'OpenWebPBX-Cleanup','OpenWebPBX Outgoing Mail','OpenWebPBX Certificate Renewal','OpenWebPBX Pending Phone Certificate'){$task=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue;if($task){$originalTaskStates[$name]=[bool]$task.Settings.Enabled}}
  NativeFixture 'late-restore';NativeFixture 'restore'
  $currentBinding=Set-SuiteFixtureBinding -Read
  Check ([Convert]::ToHexString($currentBinding.hash) -eq $pki.leaf.Thumbprint -and $currentBinding.store -eq 'My') 'Restore changed the replacement machine actual IIS certificate binding.'
  HeldServiceRestart
  EnableTargetTls -Prepared;NativeFixture 'activate-calls';NativeFixture 'native-target';NativeFixture 'job'
  NativeFixture 'activate-updates-backups';NativeFixture 'target-backup';AssertBackupTask
  $phase='postactivation original task states'
  foreach($name in $originalTaskStates.Keys){Check ([bool](Get-ScheduledTask -TaskName $name).Settings.Enabled -eq $originalTaskStates[$name]) 'Explicit activation failed to preserve an original cleanup/mail/certificate task enabled state.'}
  $phase='postactivation service state'
  foreach($name in 'FreeSWITCH','OpenWebPBX','OpenWebPBXUpdater'){AssertRestoredServiceActivation $name}
  $phase='postactivation jobs identity'
  Check ((Get-CimInstance Win32_Service -Filter "Name='OpenWebPBX'").StartName -in 'NT AUTHORITY\LocalService','NT AUTHORITY\Local Service') 'Restored automatic jobs must still run under the actual LOCAL SERVICE identity.'
  $facts.gates.explicit_all_class_activation_preserves_owned_task_states_and_service_identities='passed'
 }
 # Finish actual task qualification before disabling only this fresh fixture's
 # timer, so cleanup cannot race another daily command at a UTC boundary.
 Disable-ScheduledTask -TaskName 'OpenWebPBX-Backups'|Out-Null
 Stop-ScheduledTask -TaskName 'OpenWebPBX-Backups' -ErrorAction SilentlyContinue
 NativeFixture 'cleanup'
 $nativeFacts=Get-Content (Join-Path (Split-Path $inputFile -Parent) 'facts.json') -Raw|ConvertFrom-Json
 foreach($property in $nativeFacts.gates.PSObject.Properties){$facts.gates[$property.Name]=$property.Value}
 $facts.state='passed'
}catch{
 $facts.state='failed';$facts.failed_phase=$phase;$facts.error_type=$_.Exception.GetType().Name
 $facts.source_basename=[IO.Path]::GetFileName($_.InvocationInfo.ScriptName);$facts.source_line=[int]$_.InvocationInfo.ScriptLineNumber
 try{$activationFailure=SafeRestoreServiceActivationFailure $_.Exception.Data['restore_service_activation'];if($activationFailure){$facts.service_activation_failure=$activationFailure}}catch{}
 throw
}finally{
 try{
  if($installed){
   foreach($name in 'OpenWebPBXUpdater','OpenWebPBX','FreeSWITCH'){Stop-Service $name -Force -ErrorAction SilentlyContinue}
   foreach($name in 'OpenWebPBX-Backups','OpenWebPBX Outgoing Mail','OpenWebPBX-Cleanup','OpenWebPBX Certificate Renewal','OpenWebPBX Pending Phone Certificate','OpenWebPBX-Updater-Restart'){$task=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue;if($task){Disable-ScheduledTask -InputObject $task|Out-Null;Stop-ScheduledTask -InputObject $task -ErrorAction SilentlyContinue}}
   # Stop only the installer-created PostgreSQL service, never another instance.
   $pg=@(Get-CimInstance Win32_Service|Where-Object {$_.Name -like 'OpenWebPBX*' -and $_.PathName -like '*C:\OpenWebPBX\pgsql*'})
   foreach($service in $pg){Stop-Service $service.Name -Force -ErrorAction SilentlyContinue}
  }
  if($pki){Stop-SuiteRecoveryPki $pki}
  if($installed -and (Test-Path "$env:SystemRoot\System32\inetsrv\Microsoft.Web.Administration.dll")){
   Add-Type -Path "$env:SystemRoot\System32\inetsrv\Microsoft.Web.Administration.dll"
   $manager=[Microsoft.Web.Administration.ServerManager]::new()
   try{StopQualificationIis $manager.Sites['OpenWebPBX'] $manager.ApplicationPools['OpenWebPBX']}finally{$manager.Dispose()}
  }
  if($hostsBefore){$hostsPath=Join-Path $env:SystemRoot 'System32/drivers/etc/hosts';Check ([Convert]::ToBase64String([IO.File]::ReadAllBytes($hostsPath)) -eq [Convert]::ToBase64String($hostsExpected)) 'Hostname cleanup refuses unexpected foreign changes.';[IO.File]::WriteAllBytes($hostsPath,$hostsBefore)}
  Check (@(Get-Service -Name FreeSWITCH,OpenWebPBX,OpenWebPBXUpdater -ErrorAction SilentlyContinue|Where-Object Status -eq 'Running').Count -eq 0) 'Owned fixture services remain active.'
  $facts.cleanup='owned fresh services/tasks stopped, exact original hostname and owned CA/binding restored; durable journals retained privately'
 }catch{
  $facts.state='failed';$facts.cleanup='failed';$facts.cleanup_error_type=$_.Exception.GetType().Name
 }
 Remove-Item Env:\OPENWEB_WINDOWS_RESTORE_TEST -ErrorAction SilentlyContinue;Remove-Item Env:\WINDOWS_RESTORE_FIXTURE_PASSPHRASE -ErrorAction SilentlyContinue
 New-Item -ItemType Directory -Force $public|Out-Null;WriteJson (Join-Path $public 'qualification.json') $facts
}
if($facts.state -ne 'passed' -or $facts.cleanup -eq 'failed'){throw 'The separate-server restore qualification did not pass; no Windows acceptance is implied.'}
