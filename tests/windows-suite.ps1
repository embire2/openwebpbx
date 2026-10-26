#Requires -RunAsAdministrator
#Requires -Version 7.4
[CmdletBinding()]
param(
 [string]$NativeRunId,[string]$EngineRunId,[string]$PackageRoot,[string]$ReplaySuiteRunId,
 [string]$ReplayCandidateArtifactId,[string]$ReplayCandidateSha256,
 [switch]$DisposableHostedRunner,[switch]$UpgradeDiagnosticsOnly,[switch]$BackupsDiagnosticsOnly,[switch]$ReplayTerminalProducers,[switch]$NativeDiagnosticsOnly,[switch]$SkipPhoneHealthForNativeDiagnostics,[switch]$HoldDiagnosticsOnly,[switch]$ThreecxImportOnly
)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
. (Join-Path $PSScriptRoot 'windows-threecx-suite-mode.ps1')
function SuiteMusicWorkflow([bool]$DiagnosticOnly,[bool]$BackupDiagnosticOnly=$false){
 if($DiagnosticOnly -and $BackupDiagnosticOnly){throw 'Diagnostic modes are mutually exclusive.'}
 if($BackupDiagnosticOnly){return '.github/workflows/windows-backups-diagnostics.yml'}
 if($DiagnosticOnly){return '.github/workflows/windows-upgrade-diagnostics.yml'}
 return '.github/workflows/windows-suite.yml'
}
function AssertSuiteMode([bool]$DiagnosticOnly,[string]$WorkflowRef,[string]$WorkflowSha,[string]$SourceSha,[string]$ProvidedPackage,[bool]$BackupDiagnosticOnly=$false){
 if($DiagnosticOnly -and $BackupDiagnosticOnly){throw 'Diagnostic modes are mutually exclusive.'}
 $upgradeDiagnosticRef=$WorkflowRef -cmatch '^embire2/openwebpbx/\.github/workflows/windows-upgrade-diagnostics\.yml@refs/(heads|tags)/[A-Za-z0-9._/-]+$'
 $backupDiagnosticRef=$WorkflowRef -cmatch '^embire2/openwebpbx/\.github/workflows/windows-backups-diagnostics\.yml@refs/(heads|tags)/[A-Za-z0-9._/-]+$'
 if(!$DiagnosticOnly -and !$BackupDiagnosticOnly){if($upgradeDiagnosticRef -or $backupDiagnosticRef){throw 'The diagnostic workflow requires its explicit diagnostic-only switch.'};return}
 $diagnosticRef=if($BackupDiagnosticOnly){$backupDiagnosticRef}else{$upgradeDiagnosticRef}
 if(!$diagnosticRef -or $WorkflowSha -cnotmatch '^[a-f0-9]{40}$' -or $WorkflowSha -cne $SourceSha -or $ProvidedPackage){throw 'Diagnostic mode requires the exact diagnostic workflow/source and pinned build inputs.'}
}
AssertSuiteMode $UpgradeDiagnosticsOnly $env:GITHUB_WORKFLOW_REF $env:GITHUB_WORKFLOW_SHA $env:GITHUB_SHA $PackageRoot $BackupsDiagnosticsOnly
function AssertNativeDiagnosticsMode([bool]$NativeOnly,[bool]$UpgradeOnly,[bool]$BackupOnly,[bool]$ProducerFallback,[string]$ProvidedPackage,[string]$WorkflowRef,[string]$WorkflowSha,[string]$SourceSha){
 if(!$NativeOnly){return}
 if($UpgradeOnly -or $BackupOnly -or $ProducerFallback -or $ProvidedPackage -or $WorkflowRef -cnotmatch '^embire2/openwebpbx/\.github/workflows/windows-suite\.yml@refs/(heads|tags)/[A-Za-z0-9._/-]+$' -or $WorkflowSha -cnotmatch '^[a-f0-9]{40}$' -or $WorkflowSha -cne $SourceSha){throw 'Native diagnostics require the exact main workflow/source and exclude other modes, custom packages and producer fallback.'}
}
AssertNativeDiagnosticsMode $NativeDiagnosticsOnly $UpgradeDiagnosticsOnly $BackupsDiagnosticsOnly $ReplayTerminalProducers $PackageRoot $env:GITHUB_WORKFLOW_REF $env:GITHUB_WORKFLOW_SHA $env:GITHUB_SHA
function AssertHoldDiagnosticsMode([bool]$HoldOnly,[bool]$NativeOnly,[bool]$UpgradeOnly,[bool]$BackupsOnly,[string]$ProvidedPackage){
 if($HoldOnly -and (!$NativeOnly -or $UpgradeOnly -or $BackupsOnly -or $ProvidedPackage)){throw 'Hold-only diagnostics require explicit native diagnostics and a newly installed empty candidate factory.'}
}
AssertHoldDiagnosticsMode $HoldDiagnosticsOnly $NativeDiagnosticsOnly $UpgradeDiagnosticsOnly $BackupsDiagnosticsOnly $PackageRoot
function AssertFactoryNativeDiagnosticsMode([bool]$SkipHealth,[bool]$NativeOnly,[string]$OriginalRun,[string]$ProvidedPackage){
 if($SkipHealth -and (!$NativeOnly -or $OriginalRun -or $ProvidedPackage)){throw 'Skipping phone health is restricted to explicit native diagnostics of a freshly built, newly installed package.'}
}
AssertThreecxImportSuiteMode $ThreecxImportOnly $NativeDiagnosticsOnly $SkipPhoneHealthForNativeDiagnostics $HoldDiagnosticsOnly $UpgradeDiagnosticsOnly $BackupsDiagnosticsOnly $ReplayTerminalProducers $PackageRoot $ReplaySuiteRunId $NativeRunId $EngineRunId $ReplayCandidateArtifactId $ReplayCandidateSha256
$threecxImportModeValidated=[bool]$ThreecxImportOnly
if(!$ThreecxImportOnly){AssertFactoryNativeDiagnosticsMode $SkipPhoneHealthForNativeDiagnostics $NativeDiagnosticsOnly $ReplaySuiteRunId $PackageRoot}
$factoryDiagnosticsSourceValidated=[bool]$SkipPhoneHealthForNativeDiagnostics
function AssertSuiteReplayMode([string]$OriginalRunId,[string]$ProvidedPackage,[bool]$DiagnosticOnly,[bool]$BackupDiagnosticOnly,[bool]$TerminalProducers,[string]$ExpectedArtifactId,[string]$ExpectedZipSha256){
 if($DiagnosticOnly -and $BackupDiagnosticOnly){throw 'Diagnostic modes are mutually exclusive.'}
 if(!$OriginalRunId){if($TerminalProducers -or $ExpectedArtifactId -or $ExpectedZipSha256){throw 'Replay provenance requires an explicit original full-suite run.'};return}
 if($OriginalRunId -cnotmatch '^[1-9][0-9]{0,19}$' -or $ProvidedPackage){throw 'Exact candidate replay requires a numeric original full-suite run and no other package.'}
 if($DiagnosticOnly -or $BackupDiagnosticOnly){
  if($TerminalProducers -or $ExpectedArtifactId -cnotmatch '^[1-9][0-9]{0,19}$' -or $ExpectedZipSha256 -cnotmatch '^[a-f0-9]{64}$'){throw 'Diagnostic replay requires exact artifact and ZIP pins without producer fallback.'}
 }elseif($ExpectedArtifactId -or $ExpectedZipSha256){throw 'Explicit diagnostic artifact pins cannot change normal qualification replay.'}
}
AssertSuiteReplayMode $ReplaySuiteRunId $PackageRoot $UpgradeDiagnosticsOnly $BackupsDiagnosticsOnly $ReplayTerminalProducers $ReplayCandidateArtifactId $ReplayCandidateSha256
if(!$DisposableHostedRunner -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:RUNNER_OS -ne 'Windows' -or $env:GITHUB_REPOSITORY -ne 'embire2/openwebpbx'){
 throw 'Run only on the explicitly disposable Windows hosted runner of this repository.'
}
if([Environment]::OSVersion.Version.Major -ne 10 -or [Environment]::OSVersion.Version.Build -lt 26100){throw 'The suite requires Windows Server 2025.'}
$source=Split-Path $PSScriptRoot -Parent
$work=Join-Path $env:RUNNER_TEMP ('openwebpbx-suite-'+[Guid]::NewGuid().ToString('N'))
$public=Join-Path $env:RUNNER_TEMP 'openwebpbx-suite-public'
$candidatePublic=Join-Path $env:RUNNER_TEMP 'openwebpbx-suite-candidate';$candidateArchive=$null
$state=Join-Path $env:ProgramData 'OpenWebPBX';$configuration=Join-Path $env:ProgramData 'fusionpbx'
$domain='windowsqa.example.invalid';$installed=$false;$hostAdded=$false;$sftp=$null;$acceptanceFile=$null;$phase='source inputs'
$recoveryPki=$null
. (Join-Path $PSScriptRoot 'windows-suite-pki.ps1')
. (Join-Path $PSScriptRoot 'windows-upgrade-lock-observer.ps1')
. (Join-Path $PSScriptRoot 'windows-native-cleanup-row-fields.ps1')
. (Join-Path $PSScriptRoot 'windows-hold-failure-fields.ps1')
. (Join-Path $PSScriptRoot 'windows-backup-control-observation-fields.ps1')
. (Join-Path $PSScriptRoot 'windows-suite-independent.ps1')
$facts=[ordered]@{schema=1;platform='Windows Server 2025 x64';source_commit=$env:GITHUB_SHA;run_id=$env:GITHUB_RUN_ID;state='running';checks=@();gates=[ordered]@{fresh='pending';web_readiness='unqualified';backups='pending';native_sip_audio='unqualified';native_clock='unqualified';native_providers='unqualified';native_call_me_back='unqualified';tenant_domains='unqualified';stun='unqualified';phone_health='unqualified';meeting_transport='unqualified';meeting_browser='unqualified';direct_113_helper_reapply='unqualified';direct_failure_rollback='unqualified';restore_gate_startup='unqualified';manager_reopen_success='unqualified';manager_reopen_rollback='unqualified';installed_upgrade='unqualified';failure_rollback='unqualified';legacy_106_upgrade='unqualified';outside_acme='unqualified'};cleanup='pending'}
if($UpgradeDiagnosticsOnly){$facts.mode='upgrade_diagnostics_only';$facts.qualification_scope='Diagnostic only; not release qualification. Post-native state is not reproduced.';$facts.release_eligible=$false;$facts.owner_transaction_eligible=$false}
elseif($BackupsDiagnosticsOnly){$facts.mode='backup_diagnostics_only';$facts.qualification_scope='Diagnostic only; not release qualification. Native, upgrade and post-native state are not reproduced.';$facts.release_eligible=$false;$facts.owner_transaction_eligible=$false}
elseif($NativeDiagnosticsOnly){$facts.mode='native_diagnostics_only';$facts.qualification_scope='Diagnostic only; not release qualification. Backups, upgrades and recovery are unqualified.';$facts.release_eligible=$false;$facts.owner_transaction_eligible=$false;$facts.gates.backups='unqualified'}
if($SkipPhoneHealthForNativeDiagnostics){$facts.mode='native_factory_diagnostics_only';$facts.qualification_scope='Fresh isolated native calling diagnostics only. Phone Health qualification is skipped from the outset. Backups, upgrades, recovery, owner transactions and public release are unqualified.';$facts.native_factory_phone_health_skipped=$false;$facts.native_factory_fresh_package=$false}
if($HoldDiagnosticsOnly){$facts.native_diagnostic_case='hold';$facts.qualification_scope='Hold/transfer and natural registration expiry diagnostics only. Full native suite, backups, upgrades, restore, owner and public release are unqualified.';$facts.full_release_eligible=$false;$facts.public_eligible=$false;$facts.restore_eligible=$false;$facts.signed_upgrade_eligible=$false}
if($ThreecxImportOnly){$facts.mode='threecx_import_diagnostics_only';$facts.native_diagnostic_case='threecx_import';$facts.qualification_scope='Synthetic trusted-IIS upload/import and original-credential calling diagnostic only, using the accepted unchanged archive in a new empty installation. Full native suite, Phone Health, backups, upgrades, restore, owner and public release remain unqualified.';$facts.release_eligible=$false;$facts.owner_transaction_eligible=$false;$facts.full_release_eligible=$false;$facts.public_eligible=$false;$facts.restore_eligible=$false;$facts.signed_upgrade_eligible=$false;$facts.gates.threecx_import_diagnostic='unqualified';$facts.candidate_upload='excluded'}
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
function SafeQueueFailureFields($Record){
 $safe=@{}
 if($Record.active_case -isnot [string] -or $Record.active_case -cnotin 'queue_agent_delivery','queue_pause_logout_wire_callback'){return $safe}
 if($Record.queue_diagnostics_complete -is [bool]){$safe.queue_diagnostics_complete=$Record.queue_diagnostics_complete}
 $enums=@{status=@('Unknown','Logged Out','Available','Available (On Demand)','On Break');state=@('Unknown','Waiting','Receiving','In a queue call','Idle','Reserved');tier_state=@('Unknown','No Answer','Ready','Offering','Active Inbound','Standby');cancel_reason=@('UNKNOWN','NONE','TIMEOUT','NO_AGENT_TIMEOUT','BREAK_OUT','EXIT_WITH_KEY');originate_cause=@('UNKNOWN','SUCCESS','NO_ANSWER','USER_BUSY','CALL_REJECTED','NORMAL_CLEARING','NORMAL_TEMPORARY_FAILURE','SUBSCRIBER_ABSENT','UNALLOCATED_NUMBER','NO_ROUTE_DESTINATION','NORMAL_UNSPECIFIED','RECOVERY_ON_TIMER_EXPIRE','LOSE_RACE','DESTINATION_OUT_OF_ORDER','ORIGINATOR_CANCEL','SERVICE_UNAVAILABLE','MEDIA_TIMEOUT','INCOMPATIBLE_DESTINATION','INVALID_NUMBER_FORMAT','NORMAL_CIRCUIT_CONGESTION')}
 foreach($phase in 'before','after'){
  $prefix='queue_'+$phase+'_'
  foreach($suffix in 'config_matches','queue_readable','caller_found','agent_bridged','queue_waiting'){if($Record.($prefix+$suffix) -is [bool]){$safe[$prefix+$suffix]=$Record.($prefix+$suffix)}}
  foreach($suffix in 'waiting_members','trying_members','answered_members'){$value=$Record.($prefix+$suffix);if(($value -is [int] -or $value -is [long]) -and $value -ge 0 -and $value -le 64){$safe[$prefix+$suffix]=$value}}
  foreach($suffix in 'cancel_reason','originate_cause'){$value=$Record.($prefix+$suffix);if($value -is [string] -and $value -cin $enums[$suffix]){$safe[$prefix+$suffix]=$value}}
  foreach($peer in 'expected','other','target'){
   $name=$prefix+$peer+'_'
   foreach($suffix in 'registered','agent_present','contact_matches','ready_due','wrap_due','policy_ready','receiver_failed'){if($Record.($name+$suffix) -is [bool]){$safe[$name+$suffix]=$Record.($name+$suffix)}}
   foreach($suffix in 'busy_channels','open_dialogs','invites','acks','ended','tier_position'){
    $value=$Record.($name+$suffix);$max=if($suffix -eq 'tier_position'){1000}else{64}
    if(($value -is [int] -or $value -is [long]) -and $value -ge 0 -and $value -le $max){$safe[$name+$suffix]=$value}
   }
   foreach($suffix in 'status','state','tier_state'){$value=$Record.($name+$suffix);if($value -is [string] -and $value -cin $enums[$suffix]){$safe[$name+$suffix]=$value}}
  }
 }
 if($Record.active_case -ceq 'queue_pause_logout_wire_callback'){
  foreach($field in 'callback_wire_digit_emitted','callback_wire_sent_rtp','callback_wire_received_rtp'){if($Record.$field -is [bool]){$safe[$field]=$Record.$field}}
  foreach($phase in 'before','after'){
   $prefix='callback_'+$phase+'_'
   foreach($suffix in 'target_matches','request_is_call','has_call_uuid','has_lease','call_uuid_alive','due','expired','lease_expired','jobs_held','last_success_present','last_success_advanced'){if($Record.($prefix+$suffix) -is [bool]){$safe[$prefix+$suffix]=$Record.($prefix+$suffix)}}
   foreach($suffix in 'job_count','attempts','max_attempts'){$value=$Record.($prefix+$suffix);$max=if($suffix -eq 'job_count'){64}else{1000};if(($value -is [int] -or $value -is [long]) -and $value -ge 0 -and $value -le $max){$safe[$prefix+$suffix]=$value}}
   $known=@{job_state=@('absent','unknown','waiting','starting','calling','completed','failed','cancelled');result_class=@('unset','hours','queue','earlier_caller','agent','agent_or_route','agent_no_answer','reconnected','caller_or_route','interrupted','expired','disabled','domain','native_error','connected','unknown');worker_state=@('Starting','Running','Connection unavailable','Setup required');pause_state=@('active','paused','unknown')}
   foreach($suffix in 'job_state','result_class','worker_state','pause_state'){$value=$Record.($prefix+$suffix);if($value -is [string] -and $value -cin $known[$suffix]){$safe[$prefix+$suffix]=$value}}
  }
 }

 return $safe
}
function SafeVoicemailFailureFields($Record){
 $safe=@{}
 if($Record.active_case -isnot [string] -or $Record.active_case -cne 'native_voicemail_recording_and_email_queue'){return $safe}
 if($Record.voicemail_diagnostics_complete -is [bool]){$safe.voicemail_diagnostics_complete=$Record.voicemail_diagnostics_complete}
 foreach($phase in 'before','after'){
  $prefix='voicemail_'+$phase+'_'
  foreach($suffix in 'message_count','mail_count','wav_count'){$value=$Record.($prefix+$suffix);if(($value -is [int] -or $value -is [long]) -and $value -ge 0 -and $value -le 64){$safe[$prefix+$suffix]=$value}}
  foreach($suffix in 'recording_exists','recording_size_gt4096','recording_header_finalized','wav_any_size_gt4096','wav_any_header_finalized'){if($Record.($prefix+$suffix) -is [bool]){$safe[$prefix+$suffix]=$Record.($prefix+$suffix)}}
 }
 return $safe
}
function SafeHotelFailureFields($Record){
 $safe=@{}
 if($Record.active_case -isnot [string] -or $Record.active_case -cne 'hotel_wakeup_worker_wire_confirmation'){return $safe}
 if($Record.hotel_diagnostics_complete -is [bool]){$safe.hotel_diagnostics_complete=$Record.hotel_diagnostics_complete}
 if(($Record.hotel_due_update_count -is [int] -or $Record.hotel_due_update_count -is [long]) -and $Record.hotel_due_update_count -ge 0 -and $Record.hotel_due_update_count -le 64){$safe.hotel_due_update_count=$Record.hotel_due_update_count}
 foreach($phase in 'before','after'){
  $prefix='hotel_'+$phase+'_'
  foreach($suffix in 'job_count','attempts','max_attempts','peer_invites','peer_acks','peer_ended','peer_open_dialogs'){
   $value=$Record.($prefix+$suffix);$maximum=if($suffix -in 'attempts','max_attempts'){1000}else{64}
   if(($value -is [int] -or $value -is [long]) -and $value -ge 0 -and $value -le $maximum){$safe[$prefix+$suffix]=$value}
  }
  foreach($suffix in 'target_matches','due','expired','lease_expired','has_lease','has_call_uuid','peer_received_rtp','peer_sent_rtp','peer_receiver_failed','dtmf_attempted','dtmf_completed','dtmf_clock_started'){if($Record.($prefix+$suffix) -is [bool]){$safe[$prefix+$suffix]=$Record.($prefix+$suffix)}}
  $known=@{job_state=@('absent','unknown','waiting','starting','calling','completed','failed','cancelled');result_class=@('unset','room_checked_out','room_unavailable','agent','room_no_answer','reconnected','unconfirmed','confirmed','interrupted','expired','domain','native_error','unknown')}
  foreach($suffix in 'job_state','result_class'){$value=$Record.($prefix+$suffix);if($value -is [string] -and $value -cin $known[$suffix]){$safe[$prefix+$suffix]=$value}}
 }
 return $safe
}
function SafeMailboxFailureFields($Record){
 $safe=@{}
 if($Record.active_case -isnot [string] -or $Record.active_case -cne 'native_voicemail_wire_forwarding_binary_copy'){return $safe}
 foreach($suffix in 'diagnostics_complete','observer_failed','owned_call_seen','realm_call_id_header_present','owned_domain_header_present','owned_domain_matches','owned_event_name_matches','owned_path_header_present','pin_free','tutorial_skip_sent','forward_destination_sent','forward_no_intro_sent','dialog_ended','received_rtp','prompt_password_seen','prompt_tutorial_seen','prompt_main_menu_seen','prompt_forward_extension_seen','prompt_forward_intro_seen','prompt_forwarded_seen','prompt_auth_failed_seen','prompt_mailbox_id_seen','prompt_goodbye_seen','prompt_recording_seen','prompt_other_seen','register_started','register_completed','invite_started','invite_completed','receiver_failed','receiver_thread_alive','transport_socket_open','transport_eof_seen'){$field='mailbox_'+$suffix;if($Record.$field -is [bool]){$safe[$field]=$Record.$field}}
 foreach($suffix in 'observed_event_count','owned_event_count','matched_event_count','realm_event_count'){$field='mailbox_'+$suffix;$value=$Record.$field;if(($value -is [int] -or $value -is [long]) -and $value -ge 0 -and $value -le 1000){$safe[$field]=$value}}

 foreach($name in 'register','invite'){
  $field='mailbox_'+$name+'_response_code';$value=$Record.$field;if(($value -is [int] -or $value -is [long]) -and $value -ge 200 -and $value -le 699){$safe[$field]=$value}
  $field='mailbox_'+$name+'_challenge_count';$value=$Record.$field;if(($value -is [int] -or $value -is [long]) -and $value -ge 0 -and $value -le 3){$safe[$field]=$value}
 }
 foreach($pair in @(@('mailbox_sip_method',@('REGISTER','INVITE')),@('mailbox_transport',@('udp','tcp','tls')),@('mailbox_receiver_error_type',@('OSError','SSLError','SSLEOFError','SSLZeroReturnError','SSLWantReadError','SSLWantWriteError','ConnectionResetError','ConnectionAbortedError','BrokenPipeError','TimeoutError','RuntimeError','AssertionError','ValueError','KeyError','external_error')))){
  $value=$Record.($pair[0]);if($value -is [string] -and $value -cin $pair[1]){$safe[$pair[0]]=$value}
 }
 return $safe
}
function SafeNativeCleanupFields($Record){
 $safe=@{}
 if($Record.native_cleanup_writers_restored -is [bool]){$safe.native_cleanup_writers_restored=$Record.native_cleanup_writers_restored}
 if($Record.native_cleanup_stage -ceq 'restore_factory' -and $null -ne $Record.native_cleanup_drain_failure){$drain=Get-NativeCleanupDrainFailureFields $Record.native_cleanup_drain_failure;if($drain.Count){$safe.native_cleanup_drain_failure=$drain}}
 if($Record.native_cleanup_stage -ceq 'restore_factory' -and $null -ne $Record.native_cleanup_rows){$row=Get-NativeCleanupRowFields $Record.native_cleanup_rows;if($row.Count){$safe.native_cleanup_rows=$row}}
 if($Record.native_child_state -is [string] -and $Record.native_child_state -cin 'passed','failed'){$safe.native_child_state=$Record.native_child_state}
 if($Record.native_cleanup_stage -isnot [string] -or $Record.native_cleanup_stage -cnotin 'stop_notification_task','remove_notification_task','restore_factory','restore_binding','restore_files','restart_engine','remove_leaf','remove_root','stop_pki','collect_pki_logs','parent_write_guard','cleanup_unknown'){return $safe}
 $safe.native_cleanup_stage=$Record.native_cleanup_stage
 $type=$Record.native_cleanup_error_type;if($type -is [string] -and $type -cmatch '^[A-Za-z0-9_]{1,80}$'){$safe.native_cleanup_error_type=$type}
 $name=$Record.native_cleanup_source_basename;$line=$Record.native_cleanup_source_line
 if($name -is [string] -and $name -cin 'windows-native-acceptance.ps1','windows-native-cleanup-writers.ps1','external_component' -and ($line -is [int] -or $line -is [long]) -and $line -gt 0 -and $line -lt 100000){$safe.native_cleanup_source_basename=$name;$safe.native_cleanup_source_line=$line}
 if($Record.native_cleanup_reloadxml -is [string] -and $Record.native_cleanup_reloadxml -cin 'success','error','empty','other'){$safe.native_cleanup_reloadxml=$Record.native_cleanup_reloadxml}
 if($Record.native_cleanup_stage -ceq 'restart_engine' -and $Record.native_restart_observer -is [bool] -and $Record.native_restart_observer){
  $safe.native_restart_observer=$true
  foreach($field in @('native_restart_window_observed','native_restart_log_truncated')+@(foreach($label in 'fusion_config','phone_tls_metadata','phone_tls_directory','notification_config','notification_lock','php_cacert'){'native_restart_original_'+$label+'_bytes_equal'})){if($Record.$field -is [bool]){$safe[$field]=$Record.$field}}
  foreach($bound in @(@('native_restart_log_offset',0,1099511627776),@('native_restart_log_bytes',0,1048576),@('native_restart_xml_line',1,1000000))){$value=$Record.($bound[0]);if(($value -is [int] -or $value -is [long]) -and $value -ge $bound[1] -and $value -le $bound[2]){$safe[$bound[0]]=$value}}
  $enums=@{native_restart_exception_types=@('ServiceCommandException','InvalidOperationException','Win32Exception','IOException','Exception','RuntimeException','ActionPreferenceStopException');native_restart_log_categories=@('xml_root_unavailable','xml_file_parse_error','xml_parse_error','module_load_error','tls_error')}
  foreach($field in $enums.Keys){$values=$Record.$field;$maximum=if($field -ceq 'native_restart_exception_types'){4}else{5};if($values -is [Array] -and $values.Count -le $maximum){$valid=$true;foreach($value in $values){if($value -isnot [string] -or $value -cnotin $enums[$field]){$valid=$false;break}};if($valid){$safe[$field]=@($values)}}}
  foreach($field in 'native_restart_hresults','native_restart_win32_codes'){$values=$Record.$field;if($values -is [Array] -and $values.Count -le 4){$valid=$true;foreach($value in $values){if(($value -isnot [int] -and $value -isnot [long]) -or $value -lt $(if($field -ceq 'native_restart_hresults'){[int]::MinValue}else{0}) -or $value -gt $(if($field -ceq 'native_restart_hresults'){[int]::MaxValue}else{65535})){$valid=$false;break}};if($valid){$safe[$field]=@($values)}}}
  if($Record.native_restart_xml_basename -is [string] -and $Record.native_restart_xml_basename -cin 'freeswitch.xml','vars.xml','freeswitch.xml.fsxml','sofia.conf.xml','event_socket.conf.xml','modules.conf.xml','lua.conf.xml','internal.xml','external.xml','external_component'){$safe.native_restart_xml_basename=$Record.native_restart_xml_basename}
  $locations=$Record.native_restart_log_locations;if($locations -is [Array] -and $locations.Count -le 8){$clean=@();foreach($location in $locations){$n=$location.source_basename;$l=$location.source_line;if($n -is [string] -and $n -cin 'switch_xml.c','switch_core.c','switch_core_config.c','switch_loadable_module.c','mod_sofia.c','sofia.c','tport.c','tport_tls.c' -and ($l -is [int] -or $l -is [long]) -and $l -ge 1 -and $l -le 1000000){$clean+=,@{source_basename=$n;source_line=$l}}};$safe.native_restart_log_locations=@($clean)}
 }
 if($Record.native_cleanup_stage -ceq 'restore_factory' -and $Record.native_cleanup_fixture_action -is [string] -and $Record.native_cleanup_fixture_action -ceq 'cleanup'){
  $stage=$Record.native_cleanup_fixture_stage;$source=$Record.native_cleanup_fixture_source_basename;$row=$Record.native_cleanup_fixture_source_line;$errorType=$Record.native_cleanup_fixture_error_type
  if($stage -is [string] -and $stage -cin 'initialization','owned_service_lookup','realm_validation','admin_permissions','config_read','users_discovery','extension_update','policy_save','cache_refresh' -and $source -is [string] -and $source -cin 'windows-native-fixture.php','windows_cdr_observation.php','windows_provider_peer.php','permissions.php','database.php','pbx_admin.php','pbx_setup.php','pbx_setup_provisioner.php','pbx_tenants.php','pbx_paths.php','pbx_mapper.php','pbx_schedule.php','pbx_operations.php','pbx_native.php','pbx_phone_auth.php','pbx_sip_domain.php','config.php','event_socket.php','cache.php','external_component' -and ($row -is [int] -or $row -is [long]) -and $row -gt 0 -and $row -le 100000 -and $errorType -is [string] -and $errorType -cmatch '^[A-Za-z0-9_]{1,80}$'){
   foreach($field in 'action','stage','source_basename','source_line','error_type'){$safe['native_cleanup_fixture_'+$field]=$Record.('native_cleanup_fixture_'+$field)}
  }
 }
 return $safe
}
function SafeComparisonFields($Record){
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
function SafeMeetingOwnerPageFields($Record){
 $safe=@{}
 if($Record.active_case -isnot [string] -or $Record.active_case -cne 'native_windows_meeting_owner_page'){return $safe}
 $status=$Record.meeting_owner_http_status;$route=$Record.meeting_owner_route
 if(($status -isnot [int] -and $status -isnot [long]) -or $status -lt 0 -or $status -gt 599 -or $route -isnot [string] -or $route -cnotin 'meet','login','logout','desktop','other'){return $safe}
 foreach($field in 'meeting_owner_login_form','meeting_owner_heading','meeting_owner_same_origin','meeting_owner_user_agent_matches'){if($Record.$field -isnot [bool]){return @{}}}
 $safe.meeting_owner_http_status=[int]$status;$safe.meeting_owner_route=$route
 foreach($field in 'meeting_owner_login_form','meeting_owner_heading','meeting_owner_same_origin','meeting_owner_user_agent_matches'){$safe[$field]=$Record.$field}
 return $safe
}
function SafeMeetingMediaFields($Record){
 $safe=@{}
 if($Record.active_case -isnot [string] -or $Record.active_case -cnotin 'native_windows_meeting_decoded_media','native_windows_meeting_mute','native_windows_meeting_unmute','native_windows_meeting_end'){return $safe}
 $media=$Record.meeting_media
 $keys=if($media -is [Collections.IDictionary]){@($media.Keys)}elseif($media -is [pscustomobject]){@($media.PSObject.Properties|ForEach-Object Name)}else{return $safe}
 if($keys.Count -ne 2 -or @($keys|Where-Object {$_ -cnotin 'host','guest'}).Count){return $safe}
 $booleans=@('observed','connected','remote_audio_live','remote_video_live','local_audio_live','local_video_live','vp8_decoding','probe_error')
 $integers=@('decoded_frames','encoded_frames','inbound_audio_packets','outbound_audio_packets','inbound_video_packets','outbound_video_packets','video_colors')
 $enums=@{connection_state=@('new','connecting','connected','disconnected','failed','closed','unavailable');ice_state=@('new','checking','connected','completed','disconnected','failed','closed','unavailable');visibility=@('visible','hidden','prerender','unavailable');audio_context=@('running','suspended','closed','interrupted','unavailable');ui_state=@('connected','connecting','waiting','ended','rejected','connect_error','permission_error','device_error','unavailable','other')}
 $fields=$booleans+$integers+@($enums.Keys)+@('tone_ratio','power');$peers=@{}
 foreach($side in 'host','guest'){
  $peer=$media.$side;$names=if($peer -is [Collections.IDictionary]){@($peer.Keys)}elseif($peer -is [pscustomobject]){@($peer.PSObject.Properties|ForEach-Object Name)}else{return @{}}
  if($names.Count -ne $fields.Count -or @($names|Where-Object {$_ -cnotin $fields}).Count){return @{}}
  $closed=@{}
  foreach($field in $booleans){if($peer.$field -isnot [bool]){return @{}};$closed[$field]=$peer.$field}
  foreach($field in $integers){$value=$peer.$field;$maximum=if($field -ceq 'video_colors'){14400}else{2147483647};if(($value -isnot [int] -and $value -isnot [long]) -or $value -lt 0 -or $value -gt $maximum){return @{}};$closed[$field]=[int]$value}
  foreach($field in $enums.Keys){$value=$peer.$field;if($value -isnot [string] -or $value -cnotin $enums[$field]){return @{}};$closed[$field]=$value}
  foreach($field in 'tone_ratio','power'){$value=$peer.$field;if(($value -isnot [int] -and $value -isnot [long] -and $value -isnot [single] -and $value -isnot [double]) -or [double]::IsNaN([double]$value) -or [double]::IsInfinity([double]$value) -or $value -lt 0 -or $value -gt 1){return @{}};$closed[$field]=[double]$value}
  $peers[$side]=$closed
 }
 $safe=@{meeting_media=$peers}
 $failure=$Record.meeting_browser_failure
 $failureKeys=if($failure -is [Collections.IDictionary]){@($failure.Keys)}elseif($failure -is [pscustomobject]){@($failure.PSObject.Properties|ForEach-Object Name)}else{@()}
 if($failureKeys.Count -eq 2 -and @($failureKeys|Where-Object {$_ -cnotin 'kind','operation'}).Count -eq 0 -and $failure.kind -is [string] -and $failure.kind -cin 'timeout','type','reference','range','security','invalid_state','not_supported','target_closed','other' -and $failure.operation -is [string] -and $failure.operation -cin 'none','peer_lookup','stats','analyser_create','analyser_source','analyser_connect','analyser_output','spectrum','canvas_create','canvas_draw','canvas_read','complete'){$safe.meeting_browser_failure=@{kind=$failure.kind;operation=$failure.operation}}
 return $safe
}
function SafeMeetingSignalingFields($Record){
 $safe=@{}
 if($Record.active_case -isnot [string] -or $Record.active_case -cnotin 'native_windows_meeting_host_join','native_windows_meeting_guest_join','native_windows_meeting_admission','native_windows_meeting_decoded_media','native_windows_meeting_mute','native_windows_meeting_unmute','native_windows_meeting_end'){return $safe}
 $media=$Record.meeting_signaling
 $keys=if($media -is [Collections.IDictionary]){@($media.Keys)}elseif($media -is [pscustomobject]){@($media.PSObject.Properties|ForEach-Object Name)}else{return $safe}
 if($keys.Count -ne 2 -or @($keys|Where-Object {$_ -cnotin 'host','guest'}).Count){return $safe}
 $booleans=@('observed','endpoint_match','counts_capped','local_description','remote_description','admit_ok','offer_observed','offer_audio_secure','offer_video_secure','offer_pcmu','offer_pcma','offer_opus','offer_vp8','offer_sha256_fingerprint','offer_ice_ufrag','offer_ice_pwd','offer_rtcp_mux','offer_bundle','offer_connection')
 $counts=@('ws_observed','ws_closed','ws_errors','sent_register','sent_invite','admit_requests','admit_responses','status_requests','status_responses','http_failures','api_json_failures')
 $http=@('admit_http_status','status_http_status')
 $enums=@{signaling_state=@('stable','have-local-offer','have-remote-offer','have-local-pranswer','have-remote-pranswer','closed','unavailable');ice_gathering_state=@('new','gathering','complete','unavailable');member_state=@('waiting','admitted','left','removed','unavailable','other')}
 $arrays=@('register_codes','invite_codes');$fields=$booleans+$counts+$http+@($enums.Keys)+$arrays;$peers=@{}
 foreach($side in 'host','guest'){
  $peer=$media.$side;$names=if($peer -is [Collections.IDictionary]){@($peer.Keys)}elseif($peer -is [pscustomobject]){@($peer.PSObject.Properties|ForEach-Object Name)}else{return @{}}
  if($names.Count -ne $fields.Count -or @($names|Where-Object {$_ -cnotin $fields}).Count){return @{}}
  $closed=@{}
  foreach($field in $booleans){if($peer.$field -isnot [bool]){return @{}};$closed[$field]=$peer.$field}
  foreach($field in ($counts+$http)){$value=$peer.$field;$maximum=if($field -cin $http){599}else{512};if(($value -isnot [int] -and $value -isnot [long]) -or $value -lt 0 -or $value -gt $maximum){return @{}};$closed[$field]=[int]$value}
  foreach($field in $enums.Keys){$value=$peer.$field;if($value -isnot [string] -or $value -cnotin $enums[$field]){return @{}};$closed[$field]=$value}
  foreach($field in $arrays){$values=$peer.$field;if($values -isnot [Array] -or $values.Count -gt 16){return @{}};foreach($value in $values){if(($value -isnot [int] -and $value -isnot [long]) -or $value -lt 100 -or $value -gt 699){return @{}}};$closed[$field]=@($values|ForEach-Object {[int]$_})}
  $peers[$side]=$closed
 }
 return @{meeting_signaling=$peers}
}
function SafeMeetingPathFields($Record){
 $safe=@{}
 if($Record.active_case -isnot [string] -or $Record.active_case -cnotin 'native_windows_meeting_browser_start','native_windows_meeting_owner_page','native_windows_meeting_create','native_windows_meeting_host_join','native_windows_meeting_guest_join','native_windows_meeting_admission','native_windows_meeting_decoded_media','native_windows_meeting_mute','native_windows_meeting_unmute','native_windows_meeting_end'){return $safe}
 $paths=$Record.meeting_path
 $keys=if($paths -is [Collections.IDictionary]){@($paths.Keys)}elseif($paths -is [pscustomobject]){@($paths.PSObject.Properties|ForEach-Object Name)}else{return $safe}
 if($keys.Count -ne 2 -or @($keys|Where-Object {$_ -cnotin 'before','after'}).Count){return $safe}
 $ws=@{booleans=@('observed','connected','sent','response_received','closed_exact','large_sent','large_response_received');integers=@{status_code=699;large_status_code=699;elapsed_ms=6000};enums=@{phase=@('connect','send','receive','complete','unavailable');error_kind=@('none','timeout','tls','websocket','other','unavailable')}}
 $pg=@{booleans=@('observed','read_only','query_visible','counts_capped');integers=@{total=512;active=512;idle=512;idle_in_transaction=512;wait_lock=512;meeting_select=512;meeting_update=512;meeting_insert=512;meeting_other=512;meeting_wait_lock=512};enums=@{error_kind=@('none','timeout','database','unavailable')}}
 $http=@{booleans=@('observed','completed','ok');integers=@{http_status=599;elapsed_ms=5000};enums=@{member_state=@('waiting','admitted','left','removed','unavailable','other');error_kind=@('none','timeout','tls','http','invalid_json','other','unavailable')}}
 $specs=@{backend=$ws;frontend=$ws;fragmented_backend=$ws;fragmented_frontend=$ws;database=$pg;host_http=$http;guest_http=$http};$stages=@{}
 foreach($stage in 'before','after'){
  $row=$paths.$stage;$names=if($row -is [Collections.IDictionary]){@($row.Keys)}elseif($row -is [pscustomobject]){@($row.PSObject.Properties|ForEach-Object Name)}else{return @{}}
  if($names.Count -ne 7 -or @($names|Where-Object {$_ -cnotin @($specs.Keys)}).Count){return @{}};$closedStage=@{}
  foreach($kind in $specs.Keys){
   $peer=$row.$kind;$spec=$specs[$kind];$fields=@($spec.booleans)+@($spec.integers.Keys)+@($spec.enums.Keys)
   $names=if($peer -is [Collections.IDictionary]){@($peer.Keys)}elseif($peer -is [pscustomobject]){@($peer.PSObject.Properties|ForEach-Object Name)}else{return @{}}
   if($names.Count -ne $fields.Count -or @($names|Where-Object {$_ -cnotin $fields}).Count){return @{}};$closed=@{}
   foreach($field in $spec.booleans){if($peer.$field -isnot [bool]){return @{}};$closed[$field]=$peer.$field}
   foreach($field in $spec.integers.Keys){$value=$peer.$field;if(($value -isnot [int] -and $value -isnot [long]) -or $value -lt 0 -or $value -gt $spec.integers[$field]){return @{}};$closed[$field]=[int]$value}
   foreach($field in $spec.enums.Keys){$value=$peer.$field;if($value -isnot [string] -or $value -cnotin $spec.enums[$field]){return @{}};$closed[$field]=$value}
   $closedStage[$kind]=$closed
  }
  $stages[$stage]=$closedStage
 }
 return @{meeting_path=$stages}
}
function SafeWelcomeInventory($Record){
 if($null -eq $Record -or $Record -is [array]){return $null}
 $keys=@('schema','public_equal','config_equal','config_check','baseline_state','sample_state','before_tables','after_tables','changed_tables','added_tables','removed_tables','unlisted_tables','tables')
 $actual=if($Record -is [Collections.IDictionary]){@($Record.Keys)}else{@($Record.PSObject.Properties.Name)}
 $hasRefusal=$actual -ccontains 'sampler_refusal';if($hasRefusal){$keys+=,'sampler_refusal'}
 if($actual.Count -ne $keys.Count -or @($actual|Where-Object {$_ -cnotin $keys}).Count){return $null}
 if(($Record.schema -isnot [int] -and $Record.schema -isnot [long]) -or $Record.schema -ne 1 -or $Record.public_equal -isnot [bool] -or $Record.config_equal -isnot [bool] -or $Record.config_check -isnot [string] -or $Record.config_check -cnotin @('original','after_refusal','unavailable')){return $null}
 if($Record.config_check -ceq 'unavailable' -and $Record.config_equal){return $null}
 foreach($key in 'baseline_state','sample_state'){if($Record.$key -isnot [string] -or $Record.$key -cnotin @('matched','unstable','unavailable')){return $null}}
 if($hasRefusal){
  $reason=$Record.sampler_refusal;$reasonKeys=if($reason -is [Collections.IDictionary]){@($reason.Keys)}elseif($reason -is [pscustomobject]){@($reason.PSObject.Properties.Name)}else{return $null}
  if($reasonKeys.Count -ne 2 -or @($reasonKeys|Where-Object {$_ -cnotin @('baseline','sample')}).Count -or ($Record.baseline_state -cne 'unavailable' -and $Record.sample_state -cne 'unavailable')){return $null}
  foreach($key in 'baseline','sample'){if($reason.$key -isnot [string] -or $reason.$key -cnotin @('none','not_observed','outer_transaction','table_count','table_name','time_budget','row_shape','row_bytes','total_bytes','row_count','statement_timeout','lock_timeout','database','observer_error') -or (($Record.($key+'_state') -ceq 'unavailable') -eq ($reason.$key -ceq 'none'))){return $null}}
 }
 foreach($key in 'before_tables','after_tables','changed_tables','added_tables','removed_tables','unlisted_tables'){
  $limit=if($key -cin @('changed_tables','unlisted_tables')){1024}else{512};$value=$Record.$key
  if(($value -isnot [int] -and $value -isnot [long]) -or $value -lt 0 -or $value -gt $limit){return $null}
 }
 if($Record.tables -isnot [array] -or $Record.tables.Count -gt 8){return $null}
 $known=@('v_default_settings','v_domain_settings','v_domains','v_email_queue','v_email_queue_attachments','v_event_guard_logs','v_extensions','v_gateways','v_logs','v_pbx_backup_commands','v_pbx_backup_settings','v_pbx_backup_status','v_pbx_backups','v_pbx_greeting_status','v_pbx_greeting_uses','v_pbx_greetings','v_pbx_jobs','v_pbx_mobile_devices','v_pbx_phone_health_contacts','v_pbx_phone_health_issues','v_pbx_phone_health_recoveries','v_pbx_phone_health_settings','v_pbx_phone_health_state','v_pbx_restore','v_pbx_services','v_pbx_tenant_domains','v_pbx_tenants','v_pbx_update_commands','v_pbx_update_policies','v_pbx_update_status','v_user_logs','v_user_settings','v_users','v_xml_cdr');$rows=@();$names=@()
 foreach($row in $Record.tables){
  if($null -eq $row -or $row -is [array]){return $null};$fields=if($row -is [Collections.IDictionary]){@($row.Keys)}else{@($row.PSObject.Properties.Name)}
  if($fields.Count -ne 4 -or @($fields|Where-Object {$_ -cnotin @('name','before','after','kind')}).Count -or $row.name -isnot [string] -or $row.name -cnotin $known -or $row.kind -isnot [string] -or $row.kind -cnotin @('added','removed','changed')){return $null}
  foreach($key in 'before','after'){$value=$row.$key;if(($value -isnot [int] -and $value -isnot [long]) -or $value -lt 0 -or $value -gt 1000000){return $null}}
  if(($row.kind -ceq 'added' -and $row.before -ne 0) -or ($row.kind -ceq 'removed' -and $row.after -ne 0)){return $null}
  if($names -ccontains $row.name -or ($names.Count -and [string]::CompareOrdinal($names[-1],$row.name) -ge 0)){return $null}
  $names+=,$row.name;$rows+=,@{name=$row.name;before=$row.before;after=$row.after;kind=$row.kind}
 }
 if($rows.Count+$Record.unlisted_tables -ne $Record.changed_tables -or $Record.added_tables+$Record.removed_tables -gt $Record.changed_tables){return $null}
 $matched=$Record.baseline_state -ceq 'matched' -and $Record.sample_state -ceq 'matched'
 if(!$matched){foreach($key in 'changed_tables','added_tables','removed_tables','unlisted_tables'){if($Record.$key -ne 0){return $null}}}
 if(($Record.baseline_state -cne 'matched' -and $Record.before_tables -ne 0) -or ($Record.sample_state -cne 'matched' -and $Record.after_tables -ne 0)){return $null}
 if($matched -and ($Record.after_tables-$Record.before_tables -ne $Record.added_tables-$Record.removed_tables -or $Record.added_tables -gt $Record.after_tables -or $Record.removed_tables -gt $Record.before_tables -or @($rows|Where-Object {$_.kind -ceq 'added'}).Count -gt $Record.added_tables -or @($rows|Where-Object {$_.kind -ceq 'removed'}).Count -gt $Record.removed_tables)){return $null}
 if($matched -and $Record.public_equal -ne ($Record.changed_tables -eq 0)){return $null}
 $safe=@{};foreach($key in $keys){$safe[$key]=$Record.$key};$safe.tables=$rows;if($hasRefusal){$safe.sampler_refusal=@{baseline=$reason.baseline;sample=$reason.sample}};return $safe
}
function SafeWelcomePrimary($Record){
 if($null -eq $Record -or $Record -is [array]){return $null}
 $keys=@('schema','error_type','source_basename','source_line');$actual=if($Record -is [Collections.IDictionary]){@($Record.Keys)}else{@($Record.PSObject.Properties.Name)}
 if($actual.Count -ne 4 -or @($actual|Where-Object {$_ -cnotin $keys}).Count){return $null}
 if(($Record.schema -isnot [int] -and $Record.schema -isnot [long]) -or $Record.schema -ne 1 -or $Record.error_type -isnot [string] -or $Record.error_type -cnotin @('RuntimeError','AssertionError','TimeoutExpired','CalledProcessError','ValueError','JSONDecodeError','UnicodeDecodeError','OSError','TypeError','external_error') -or $Record.source_basename -isnot [string] -or $Record.source_basename -cnotin @('windows_welcome_native.py','windows_welcome_qr.py','smtp_transport_integration.py','external_component') -or ($Record.source_line -isnot [int] -and $Record.source_line -isnot [long]) -or $Record.source_line -lt 1 -or $Record.source_line -gt 100000){return $null}
 return @{schema=1;error_type=$Record.error_type;source_basename=$Record.source_basename;source_line=$Record.source_line}
}
function SafeSmtpFailureFields($Record){
 $safe=@{}
 if($Record.active_case -is [string] -and $Record.active_case -ceq 'native_welcome_inline_qr_config_actual_loopback'){
  if($Record.welcome_cleanup_failed -is [bool]){$safe.welcome_cleanup_failed=$Record.welcome_cleanup_failed}
  if($Record.welcome_phase -is [string] -and $Record.welcome_phase -cin 'input','database','bootstrap','queue','dispatch','inspect','suppress','cleanup' -and $Record.welcome_error_type -is [string] -and $Record.welcome_error_type -cin 'RuntimeException','PDOException','Error','TypeError','ValueError','JsonException','Exception' -and $Record.welcome_source_basename -is [string] -and $Record.welcome_source_basename -cin 'windows_welcome_native.php','pbx_mobile.php','pbx_mobile_welcome.php','email.php','outgoing_mail.php','email_send.php','database.php','config.php','settings.php','external_component' -and ($Record.welcome_source_line -is [int] -or $Record.welcome_source_line -is [long]) -and $Record.welcome_source_line -ge 1 -and $Record.welcome_source_line -le 100000 -and $Record.welcome_sqlstate -is [string] -and ($Record.welcome_sqlstate -ceq 'none' -or $Record.welcome_sqlstate -cmatch '^[A-Z0-9]{5}$')){foreach($field in 'welcome_phase','welcome_error_type','welcome_source_basename','welcome_source_line','welcome_sqlstate'){$safe[$field]=$Record.$field}}
  if($Record.welcome_cleanup_failed -is [bool] -and $Record.welcome_cleanup_failed){
   try{$observed=SafeWelcomeInventory $Record.welcome_cleanup_inventory;if($observed){$safe.welcome_cleanup_inventory=$observed}}catch{}
   try{$observed=SafeWelcomePrimary $Record.welcome_primary;if($observed){$safe.welcome_primary=$observed}}catch{}
  }
  return $safe
 }
 if($Record.active_case -isnot [string] -or $Record.active_case -cnotin 'global_smtp_trusted_tls_hostname_auth','native_voicemail_global_smtp_ip_attachment'){return $safe}
 foreach($field in 'smtp_connection_check_passed','smtp_queue_observed'){if($Record.$field -is [bool]){$safe[$field]=$Record.$field}}
 foreach($field in 'smtp_delivery_count','smtp_envelope_count','smtp_session_count','smtp_authenticated_session_count','smtp_tls_accepted_count','smtp_tls_handshake_completed_count','smtp_tls_handshake_failed_count','smtp_seed_row_count','smtp_tick_maintenance_deferrals','smtp_tick_retry_count','smtp_owned_mail_rows','smtp_owned_waiting_count','smtp_owned_trying_count','smtp_owned_sent_count','smtp_owned_failed_count','smtp_owned_none_count','smtp_owned_configuration_count','smtp_owned_certificate_count','smtp_owned_authentication_count','smtp_owned_connection_count','smtp_owned_other_count'){$value=$Record.$field;if(($value -is [int] -or $value -is [long]) -and $value -ge 0 -and $value -le 64){$safe[$field]=$value}}
 foreach($field in 'smtp_tick_selected','smtp_tick_processed'){$value=$Record.$field;if(($value -is [int] -or $value -is [long]) -and $value -ge 0 -and $value -le 10){$safe[$field]=$value}}
 $value=$Record.smtp_seed_retry_count;if(($value -is [int] -or $value -is [long]) -and $value -ge 0 -and $value -le 100){$safe.smtp_seed_retry_count=$value}
 $value=$Record.smtp_tick_exit;if(($value -is [int] -or $value -is [long]) -and $value -ge [int]::MinValue -and $value -le [int]::MaxValue){$safe.smtp_tick_exit=$value}
 foreach($pair in @(@('smtp_stage',@('save','connection_check','seed','dispatch','delivery')),@('smtp_tick_outcome',@('unrecognized','command_failed','command_timeout','deferred_maintenance','deferred_restore','unconfigured','processed')),@('smtp_tls_error_type',@('SSLError','TimeoutError','OSError','external_error')),@('smtp_seed_status',@('waiting','trying','sent','failed')),@('smtp_seed_response_class',@('none','configuration','certificate','authentication','connection','other')))){
  $value=$Record.($pair[0]);if($value -is [string] -and $value -cin $pair[1]){$safe[$pair[0]]=$value}
 }
 return $safe
}

. (Join-Path $PSScriptRoot 'windows-upgrade-hash-observer.ps1')
function SafeFailureFields($Record){
 $safe=@{}
 if($Record.source_basename -ceq 'windows-upgrade-acceptance.ps1' -and $Record.error_type -is [string]){try{$observed=UpgradeHashFailureFields $Record.hash_failure;if($observed -and $Record.error_type.Split('.')[-1] -ceq $observed.error_type){$safe.hash_failure=$observed}}catch{}}
 if($Record.backup_control_failure){$control=BackupControlObservationFields $Record.backup_control_failure;if($control){$safe.backup_control_failure=$control}}
 foreach($entry in (HoldFailureFields $Record).GetEnumerator()){$safe[$entry.Key]=$entry.Value}
 if($Record.native_factory_empty_before_fixture -is [bool]){$safe.native_factory_empty_before_fixture=$Record.native_factory_empty_before_fixture}
 foreach($field in 'meeting_failure','meeting_recovery_failure'){
  $detail=$Record.$field
  if(!$detail){continue}
  $phases=@('websockets','rewrite_download','rewrite_signature','rewrite_identity','rewrite_install','arr_download','arr_signature','arr_identity','arr_install','trust','hosts','strict_flags','proxy','web_config','complete_ledger','helper_copy','previous_trust','recovery_web_config','recovery_hosts','recovery_flags','recovery_proxy','recovery_trust','recovery_previous_trust','recovery_packages','recovery_websockets','recovery_registry','recovery_ledger','unknown')
  $types=@('RuntimeException','MethodInvocationException','ActionPreferenceStopException','ParameterBindingException','ParameterBindingValidationException','ItemNotFoundException','ProviderInvocationException','InvalidOperationException','IOException','FileNotFoundException','DirectoryNotFoundException','UnauthorizedAccessException','ArgumentException','FormatException','Win32Exception','COMException','WebException','Exception','external_error')
  if($detail.phase -isnot [string] -or $detail.phase -cnotin $phases -or $detail.source_basename -isnot [string] -or $detail.source_basename -cnotin 'Install-Meet.ps1','Meet-Proxy.ps1','Write-PrivateState.ps1','external_component' -or ($detail.source_line -isnot [int] -and $detail.source_line -isnot [long]) -or $detail.source_line -lt 1 -or $detail.source_line -gt 99999){continue}
  if($detail.exception_types -isnot [Array] -or $detail.hresults -isnot [Array] -or $detail.exception_types.Count -lt 1 -or $detail.exception_types.Count -gt 4 -or $detail.hresults.Count -ne $detail.exception_types.Count){continue}
  $valid=$true
  foreach($value in $detail.exception_types){if($value -isnot [string] -or $value -cnotin $types){$valid=$false}}
  foreach($value in $detail.hresults){if(($value -isnot [int] -and $value -isnot [long]) -or $value -lt [int]::MinValue -or $value -gt [int]::MaxValue){$valid=$false}}
  if(!$valid){continue}
  $copy=@{phase=$detail.phase;source_basename=$detail.source_basename;source_line=[int]$detail.source_line;exception_types=@($detail.exception_types);hresults=@($detail.hresults)}
  if(($detail.command_exit -is [int] -or $detail.command_exit -is [long]) -and $detail.command_exit -ge [int]::MinValue -and $detail.command_exit -le [int]::MaxValue){$copy.command_exit=[int]$detail.command_exit}
  $safe[$field]=$copy
 }
 if($Record.active_case -is [string] -and $Record.active_case -cmatch '^native_provider_10[0-3]$'){
 $value=$Record.provider_caller_response_code;if(($value -is [int] -or $value -is [long]) -and $value -ge 100 -and $value -le 699){$safe.provider_caller_response_code=$value}
 $value=$Record.provider_caller_digest_challenge_count;if(($value -is [int] -or $value -is [long]) -and $value -ge 0 -and $value -le 3){$safe.provider_caller_digest_challenge_count=$value}
 foreach($phase in 'before','after'){
  $prefix='provider_'+$phase+'_plan_'
  foreach($key in 'observed','registered','rule_matches','primary_available','backup_available'){if($Record.($prefix+$key) -is [bool]){$safe[$prefix+$key]=$Record.($prefix+$key)}}
  foreach($bound in @(@('routes_count',0,16),@('selected_index',-1,1))){$value=$Record.($prefix+$bound[0]);if(($value -is [int] -or $value -is [long]) -and $value -ge $bound[1] -and $value -le $bound[2]){$safe[$prefix+$bound[0]]=$value}}
  $value=$Record.($prefix+'error');if($value -is [string] -and $value -cin 'none','other','no_rule','providers_unavailable','phone_unavailable'){$safe[$prefix+'error']=$value}
  foreach($peer in 'primary','backup'){
   $prefix='provider_'+$phase+'_'+$peer+'_attempt_'
   foreach($key in 'observed','counts_capped','will_retry'){if($Record.($prefix+$key) -is [bool]){$safe[$prefix+$key]=$Record.($prefix+$key)}}
   $value=$Record.($prefix+'count');if(($value -is [int] -or $value -is [long]) -and $value -ge 0 -and $value -le 16){$safe[$prefix+'count']=$value}
   $value=$Record.($prefix+'sip_status');if(($value -is [int] -or $value -is [long]) -and ($value -eq 0 -or ($value -ge 100 -and $value -le 699))){$safe[$prefix+'sip_status']=$value}
   $value=$Record.($prefix+'state');if($value -is [string] -and $value -cin 'absent','calling','skipped','answered','failed','cancelled','unknown'){$safe[$prefix+'state']=$value}
   $value=$Record.($prefix+'cause');if($value -is [string] -and $value -cin 'none','other','PROVIDER_UNAVAILABLE','SUCCESS','NORMAL_CLEARING','NORMAL_TEMPORARY_FAILURE','INCOMPATIBLE_DESTINATION','SERVICE_UNAVAILABLE','DESTINATION_OUT_OF_ORDER','INVALID_GATEWAY','GATEWAY_DOWN','CHAN_NOT_IMPLEMENTED','MANDATORY_IE_MISSING','INVALID_IE_CONTENTS','NO_ROUTE_DESTINATION','CALL_REJECTED','ORIGINATOR_CANCEL','NO_USER_RESPONSE','NO_ANSWER','NORMAL_CIRCUIT_CONGESTION','USER_BUSY','LOSE_RACE','ALLOTTED_TIMEOUT','RECOVERY_ON_TIMER_EXPIRE','WRONG_CALL_STATE','UNALLOCATED_NUMBER','NETWORK_OUT_OF_ORDER','SWITCH_CONGESTION','RESOURCE_UNAVAILABLE','CRASH','UNKNOWN'){$safe[$prefix+'cause']=$value}
   $prefix='provider_'+$phase+'_'+$peer+'_policy_'
   foreach($key in 'available','rewrite_valid','leg_valid','options_present','options_schema_one','policy_source_forwardslash','options_module_readable'){if($Record.($prefix+$key) -is [bool]){$safe[$prefix+$key]=$Record.($prefix+$key)}}
   foreach($key in 'enabled_kind','register_kind','options_kind'){$value=$Record.($prefix+$key);if($value -is [string] -and $value -cin 'nil','boolean','string','number','table','function','userdata','thread'){$safe[$prefix+$key]=$value}}
   foreach($key in 'enabled_value','register_value'){$value=$Record.($prefix+$key);if($value -is [string] -and $value -cin 'true','false','t','f','1','0','other'){$safe[$prefix+$key]=$value}}
  }
 }
 foreach($phase in 'before','after'){foreach($peer in 'primary','backup'){
  $prefix='provider_'+$phase+'_'+$peer+'_'
  foreach($suffix in 'gateway_observed','counts_capped','offer_parsed','offer_pcmu','offer_pcma','receiver_failed','receiver_alive'){if($Record.($prefix+$suffix) -is [bool]){$safe[$prefix+$suffix]=$Record.($prefix+$suffix)}}
  foreach($suffix in 'invites','distinct_calls'){$value=$Record.($prefix+$suffix);if(($value -is [int] -or $value -is [long]) -and $value -ge 0 -and $value -le 64){$safe[$prefix+$suffix]=$value}}
  $value=$Record.($prefix+'last_response_code');if(($value -is [int] -or $value -is [long]) -and ($value -eq 0 -or ($value -ge 100 -and $value -le 699))){$safe[$prefix+'last_response_code']=$value}
  $value=$Record.($prefix+'gateway_status');if($value -is [string] -and $value -cin 'unknown','UP','DOWN'){$safe[$prefix+'gateway_status']=$value}
  $value=$Record.($prefix+'gateway_state');if($value -is [string] -and $value -cin 'unknown','NOREG','REGED','UNREGED','TRYING','REGISTER','UNREGISTER','FAIL_WAIT','FAILED','EXPIRED'){$safe[$prefix+'gateway_state']=$value}
 }}
 }
 if($Record.active_case -is [string] -and $Record.active_case -ceq 'manager_original_closed'){
  foreach($key in 'manager_original_handle_pinned','manager_original_identity_verified','manager_original_exit_observed','manager_original_has_exited'){if($Record.$key -is [bool]){$safe[$key]=$Record.$key}}
  if($Record.manager_original_process_class -is [string] -and $Record.manager_original_process_class -cin 'live_original','exited_original','unavailable'){$safe.manager_original_process_class=$Record.manager_original_process_class}
 }
 if(($Record.lock_observer_schema -is [int] -or $Record.lock_observer_schema -is [long]) -and $Record.lock_observer_schema -eq 1){$lockFields=SafeOpenWebUpgradeLockFields $Record;foreach($entry in $lockFields.GetEnumerator()){$safe[$entry.Key]=$entry.Value}}
 $cleanupPhases=@(foreach($phase in @($Record.cleanup_failure_phases)){if($phase -is [string] -and $phase -cin 'owned manager cleanup','restore hold cleanup','owned fixture cleanup','owned health observer cleanup'){$phase}})
 if($cleanupPhases.Count){$safe.cleanup_failure_phases=@($cleanupPhases|Select-Object -Unique)}
 foreach($field in 'failed_phase','error_type','source_basename','active_case','command_basename','caller_basename'){
  $value=$Record.$field
  $pattern=if($field -in 'source_basename','command_basename','caller_basename'){'^[A-Za-z0-9_.-]+$'}else{'^[A-Za-z0-9_.+ /()-]+$'}
  if($value -is [string] -and $value.Length -le 160 -and $value -match $pattern){$safe[$field]=$value}
 }
 if(($Record.source_line -is [int] -or $Record.source_line -is [long]) -and $Record.source_line -gt 0 -and $Record.source_line -lt 100000){$safe.source_line=[int]$Record.source_line}
 if(($Record.caller_line -is [int] -or $Record.caller_line -is [long]) -and $Record.caller_line -gt 0 -and $Record.caller_line -lt 100000){$safe.caller_line=[int]$Record.caller_line}
 if($Record.active_case -is [string] -and $Record.active_case -cmatch '^phone_tls_[a-z_]+$'){
  if($Record.phone_tls_inner_error_type -is [string] -and $Record.phone_tls_inner_error_type -cin 'IOException','UnauthorizedAccessException','CryptographicException','Win32Exception','ArgumentException','InvalidOperationException','AuthenticationException','SocketException','TimeoutException','ObjectDisposedException','FileNotFoundException','DirectoryNotFoundException','SecurityException','NotSupportedException','Exception','other'){$safe.phone_tls_inner_error_type=$Record.phone_tls_inner_error_type}
  foreach($field in 'phone_tls_inner_hresult','phone_tls_inner_depth'){$value=$Record.$field;$maximum=if($field -ceq 'phone_tls_inner_depth'){8}else{4294967295L};if(($value -is [int] -or $value -is [long]) -and $value -ge 0 -and $value -le $maximum){$safe[$field]=$value}}
 }
 if(($Record.command_exit -is [int] -or $Record.command_exit -is [long]) -and $Record.command_exit -ge [int]::MinValue -and $Record.command_exit -le [int]::MaxValue){$safe.command_exit=[int]$Record.command_exit}
 $recoveryCommands=@('php.exe','icacls.exe','pg_dump.exe','pg_restore.exe','psql.exe','robocopy.exe','powershell.exe','python.exe','OpenWebPbx.Updater.exe','OpenWebPbx.Server.exe')
 if(($Record.recovery_observations_schema -is [int] -or $Record.recovery_observations_schema -is [long]) -and $Record.recovery_observations_schema -eq 1 -and $Record.recovery_observations_only -is [bool] -and $Record.recovery_observations_only){
  $safe.recovery_observations_schema=1;$safe.recovery_observations_only=$true
  if(($Record.recovery_preexisting_error_count -is [int] -or $Record.recovery_preexisting_error_count -is [long]) -and $Record.recovery_preexisting_error_count -ge 0 -and $Record.recovery_preexisting_error_count -le 256){$safe.recovery_preexisting_error_count=[int]$Record.recovery_preexisting_error_count}
  if($Record.recovery_journal_state -is [string] -and $Record.recovery_journal_state -cin 'prepared','quiescing','deploying','migrating','validating','rolling_back','recovery_required','rolled_back','completed'){$safe.recovery_journal_state=$Record.recovery_journal_state}
  $recoveryTypes=@('System.InvalidOperationException','System.IO.IOException','System.IO.FileNotFoundException','System.IO.DirectoryNotFoundException','System.UnauthorizedAccessException','System.ArgumentException','System.FormatException','System.ComponentModel.Win32Exception','System.Runtime.InteropServices.COMException','System.Net.WebException','System.Management.Automation.RuntimeException','System.Management.Automation.MethodInvocationException','System.Management.Automation.ActionPreferenceStopException','System.Management.Automation.ParameterBindingException','System.Management.Automation.ParameterBindingValidationException','System.Management.Automation.ItemNotFoundException','System.Management.Automation.ProviderInvocationException','Microsoft.PowerShell.Commands.ServiceCommandException')
  $frames=@($Record.recovery_error_observations);$observations=@()
  if($frames.Count -le 8){
   foreach($frame in $frames){
    if($null -eq $frame -or $frame.source_basename -isnot [string] -or $frame.source_basename -cnotin 'Upgrade-OpenWebPBX.ps1','Support-Recovery.ps1','Restore-Gates.ps1' -or ($frame.source_line -isnot [int] -and $frame.source_line -isnot [long]) -or $frame.source_line -lt 1 -or $frame.source_line -ge 100000 -or $frame.error_type -isnot [string] -or $frame.error_type -cnotin $recoveryTypes){continue}
    $entry=@{source_basename=$frame.source_basename;source_line=[int]$frame.source_line;error_type=$frame.error_type}
    if($frame.caller_basename -is [string] -and $frame.caller_basename -cin 'Upgrade-OpenWebPBX.ps1','Support-Recovery.ps1','Restore-Gates.ps1' -and ($frame.caller_line -is [int] -or $frame.caller_line -is [long]) -and $frame.caller_line -gt 0 -and $frame.caller_line -lt 100000){$entry.caller_basename=$frame.caller_basename;$entry.caller_line=[int]$frame.caller_line}
    if($frame.command_basename -is [string] -and $frame.command_basename -cin $recoveryCommands -and ($frame.command_exit -is [int] -or $frame.command_exit -is [long]) -and $frame.command_exit -ge [int]::MinValue -and $frame.command_exit -le [int]::MaxValue){$entry.command_basename=$frame.command_basename;$entry.command_exit=[int]$frame.command_exit}
    $observations+=,$entry
   }
  }
  $safe.recovery_error_observations=$observations
 }
 if($Record.command_basename -ceq 'windows-compare-json.py'){
  $comparison=SafeComparisonFields $Record
  if($comparison){foreach($entry in $comparison.GetEnumerator()){$safe[$entry.Key]=$entry.Value}}
 }
 if($Record.active_case -is [string] -and $Record.active_case -ceq 'direct_reapply_complete' -and $Record.command_basename -ceq 'php.exe' -and ($Record.command_exit -is [int] -or $Record.command_exit -is [long]) -and $Record.command_exit -eq 255 -and $Record.music_stage -is [string] -and $Record.music_stage -cin 'initialization','bootstrap','music_install','native_default','completion'){$safe.music_stage=$Record.music_stage}
 if($Record.active_case -is [string] -and $Record.active_case -ceq 'direct_reapply_preflight'){
  if($Record.payload_inventory_observed -is [bool]){$safe.payload_inventory_observed=$Record.payload_inventory_observed}
  foreach($field in 'payload_extra_count','payload_reparse_count'){$value=$Record.$field;if(($value -is [int] -or $value -is [long]) -and $value -ge 0 -and $value -le 100000){$safe[$field]=$value}}
  $allowed=@{payload_extra_categories=@('codec_helper_cache','runtime_cache','other_bytecode','codec_other','runtime_other','web_other','root_other','other');payload_extra_extensions=@('.pyc','.pyo','.log','.json','.txt','.tmp','.ps1','.py','.dll','none','other');payload_extra_known_basenames=@('core-exports.cpython-313.pyc','build-windows-local.cpython-313.pyc')}
  foreach($field in $allowed.Keys){$values=@(foreach($name in $allowed[$field]){foreach($value in @($Record.$field)){if($value -is [string] -and $value -ceq $name){$name;break}}});if($values.Count){$safe[$field]=$values}}
 }
 if($Record.active_case -is [string] -and $Record.active_case -match '^(native_media_peer_(udp|tcp|tls)_registration_[0-2]|independent_g729_(offer_refused|answer_payload_mismatch))$'){
  if(($Record.sip_response_code -is [int] -or $Record.sip_response_code -is [long]) -and $Record.sip_response_code -ge 200 -and $Record.sip_response_code -le 699){$safe.sip_response_code=[int]$Record.sip_response_code}
  if(($Record.digest_challenge_count -is [int] -or $Record.digest_challenge_count -is [long]) -and $Record.digest_challenge_count -ge 0 -and $Record.digest_challenge_count -le 3){$safe.digest_challenge_count=[int]$Record.digest_challenge_count}
  if($Record.active_case -match '^independent_g729_' -and ($Record.negotiated_payload_type -is [int] -or $Record.negotiated_payload_type -is [long]) -and $Record.negotiated_payload_type -ge 0 -and $Record.negotiated_payload_type -le 127){$safe.negotiated_payload_type=[int]$Record.negotiated_payload_type}
 }
 if($Record.active_case -eq 'normal_admin_owned_extension_audio_preferences'){
  foreach($field in 'owned_domain_matches','authentication_id_matches','sip_password_matches'){if($Record.$field -is [bool]){$safe[$field]=[bool]$Record.$field}}
 }
 $nativeStages=@('native_case','cdr_background_import','g729_regular_unregister','g729_alternate_register','g729_invite','g729_answer_validation','g729_remote_answer','g729_media','g729_peer_receiver','g729_hangup','g729_alternate_unregister','g729_peer_close','g729_codec_close','g729_regular_reregister','native_peer_unregister','native_peer_close','native_ledger_write','callback_request_created','callback_agent_answer','callback_target_answer','callback_job_completed','hotel_phone_answer','hotel_wire_confirmation','hotel_job_completed','voicemail_message_created','voicemail_recording_finalized','voicemail_mail_queued','mailbox_register','mailbox_invite','mailbox_login_prompt','mailbox_main_menu_prompt','mailbox_tutorial_complete','mailbox_recording_playback','mailbox_forward_extension_prompt','mailbox_forward_intro_prompt','mailbox_forwarded_prompt','mailbox_forwarded_message_created','mailbox_forwarded_binary_copy','mailbox_observer_close')
 foreach($prefix in 'primary','cleanup'){
  if($Record.($prefix+'_substage') -isnot [string] -or $Record.($prefix+'_substage') -cnotin $nativeStages){continue}
  $safe[$prefix+'_substage']=$Record.($prefix+'_substage')
  $type=$Record.($prefix+'_error_type');if($type -is [string] -and $type -match '^[A-Za-z0-9_]{1,80}$'){$safe[$prefix+'_error_type']=$type}
  foreach($where in 'source','caller'){
   $name=$Record.($prefix+'_'+$where+'_basename');$line=$Record.($prefix+'_'+$where+'_line')
   if($name -in 'windows-native-acceptance.py','windows-meet-browser.py','pbx_v20_restore_native.py','sip_trunk_live.py','windows_native_services.py','windows_cdr_background.py','windows_cdr_observation.php','windows_hold_native.py','windows_clock_native.py','pbx_talking_clock_native.py','external_component' -and ($line -is [int] -or $line -is [long]) -and $line -gt 0 -and $line -lt 100000){$safe[$prefix+'_'+$where+'_basename']=$name;$safe[$prefix+'_'+$where+'_line']=[int]$line}
  }
 }
 if(($Record.cleanup_failure_count -is [int] -or $Record.cleanup_failure_count -is [long]) -and $Record.cleanup_failure_count -ge 1 -and $Record.cleanup_failure_count -le 32){$safe.cleanup_failure_count=[int]$Record.cleanup_failure_count}
 $mediaCases=@('native_localservice_cdr_background_import','native_windows_meeting_browser_video_audio','native_tls_signalling_two_way_decoded_rtp','native_g729_pcmu_independent_codec_two_way_transcoding','native_simultaneous_ring_group','native_hunting_ring_group','native_queue_agent_first','native_ivr_negotiated_wire_rfc2833','native_visible_sip_hold_selected_music_resume_transfer','native_configured_ivr_timeout','native_queue_pause_logout_wire_callback_localservice_agent_first_decoded_rtp','native_hotel_wakeup_localservice_claim_wire_confirmation','native_voicemail_recording_private_owned_wav','native_tls_mailbox_wire_forwarding_exact_binary_wav','native_global_smtp_unconfigured_queue_preserves_attempts','native_queued_voicemail_global_smtp_ip_auth_actual_loopback_attachment','native_voicemail_attach_delete_smtp250_durable_purge','native_global_smtp_password_auth_actual_loopback','native_global_smtp_trusted_tls_hostname_auth_actual_loopback','native_welcome_inline_qr_config_actual_loopback','native_clock1026_gmt2_three_decoded_announcements','native_provider_outbound_decoded_rtp','native_provider_503_failover_once_decoded_rtp','native_provider_busy_no_failover','native_provider_603_failover_once_decoded_rtp','native_provider_incoming_owned_did_decoded_rtp','native_cmb_sa_id_first_auth_decoded_bridge','native_cmb_saved_caller_decoded_bridge','native_cmb_short_quota_native_cutoff_exact_usage','native_cmb_exhausted_quota_no_destination','native_localservice_notification_store_reader')
 $completed=@(foreach($name in $mediaCases){foreach($value in @($Record.completed_media_cases)){if($value -is [string] -and $value -ceq $name){$name;break}}})
 if($completed.Count){$safe.completed_media_cases=$completed}
 if($Record.media_peer -is [string] -and $Record.media_peer -cin 'caller','destination' -and $Record.media_direction -is [string] -and $Record.media_direction -cin 'sent','received'){
  $safe.media_peer=$Record.media_peer;$safe.media_direction=$Record.media_direction
  foreach($bound in @(@('media_window_seconds',.5,10),@('media_span_seconds',0,11),@('media_rate_pps',0,100000))){
   $value=$Record.($bound[0]);if(($value -is [double] -or $value -is [single] -or $value -is [int] -or $value -is [long]) -and ![double]::IsNaN([double]$value) -and ![double]::IsInfinity([double]$value) -and $value -ge $bound[1] -and $value -le $bound[2]){$safe[$bound[0]]=$value}
  }
  if(($Record.media_packets -is [int] -or $Record.media_packets -is [long]) -and $Record.media_packets -ge 0 -and $Record.media_packets -le 1000000){$safe.media_packets=$Record.media_packets}
  try{
   $tone=$Record.media_tone
   if($null-ne $tone){
    $bounds=@{schema=@(1,1);sample_count=@(0,16000);frequency_millihz=@(0,4000000);mean_square=@(0,1073741824);coherence_ppm=@(0,2000000);segment_samples=@(800,800);segment_count=@(0,20);segment_min_coherence_ppm=@(0,2000000);segment_max_coherence_ppm=@(0,2000000);segment_coherent_count=@(0,20);segment_phase_pairs=@(0,19);segment_max_phase_jump_mdeg=@(0,180000)}
    $keys=if($tone-is[Collections.IDictionary]){@($tone.Keys)}elseif($tone-is[pscustomobject]){@($tone.PSObject.Properties.Name)}else{@()}
    $allowed=@($bounds.Keys)+@('coherence_available','rtp_history');$valid=$keys.Count-eq$allowed.Count-and@($keys|Where-Object{$_-isnot[string]-or$_-cnotin$allowed}).Count-eq0;$closed=@{}
    if($valid){foreach($field in $bounds.Keys){$value=$tone.$field;if(($value-isnot[int]-and$value-isnot[long])-or$value-lt$bounds[$field][0]-or$value-gt$bounds[$field][1]){$valid=$false;break};$closed[$field]=[int]$value}}
    if($valid){
     $valid=$tone.coherence_available-is[bool]-and$tone.rtp_history-is[string]-and$tone.rtp_history-ceq'unavailable'-and$tone.segment_count-eq[math]::Floor($tone.sample_count/800)-and$tone.segment_coherent_count-le$tone.segment_count-and$tone.segment_phase_pairs-le[math]::Max($tone.segment_coherent_count-1,0)-and$tone.segment_min_coherence_ppm-le$tone.segment_max_coherence_ppm
     if((!$tone.segment_phase_pairs-and$tone.segment_max_phase_jump_mdeg)-or(!$tone.coherence_available-and$tone.coherence_ppm)){$valid=$false}
     if(!$tone.segment_count-and@('segment_min_coherence_ppm','segment_max_coherence_ppm','segment_coherent_count','segment_phase_pairs','segment_max_phase_jump_mdeg'|Where-Object{$tone.$_-ne0}).Count){$valid=$false}
    }
    if($valid){$closed.coherence_available=$tone.coherence_available;$closed.rtp_history='unavailable';$safe.media_tone=$closed}
   }
  }catch{} # Optional closed observation must never replace the original failure.
 }
 foreach($entry in (SafeQueueFailureFields $Record).GetEnumerator()){$safe[$entry.Key]=$entry.Value}
 foreach($entry in (SafeVoicemailFailureFields $Record).GetEnumerator()){$safe[$entry.Key]=$entry.Value}
 foreach($entry in (SafeMailboxFailureFields $Record).GetEnumerator()){$safe[$entry.Key]=$entry.Value}
 foreach($entry in (SafeHotelFailureFields $Record).GetEnumerator()){$safe[$entry.Key]=$entry.Value}
 foreach($entry in (SafeSmtpFailureFields $Record).GetEnumerator()){$safe[$entry.Key]=$entry.Value}
 foreach($entry in (SafeMeetingOwnerPageFields $Record).GetEnumerator()){$safe[$entry.Key]=$entry.Value}
 foreach($entry in (SafeMeetingMediaFields $Record).GetEnumerator()){$safe[$entry.Key]=$entry.Value}
 foreach($entry in (SafeMeetingSignalingFields $Record).GetEnumerator()){$safe[$entry.Key]=$entry.Value}
 foreach($entry in (SafeMeetingPathFields $Record).GetEnumerator()){$safe[$entry.Key]=$entry.Value}
 foreach($entry in (SafeNativeCleanupFields $Record).GetEnumerator()){$safe[$entry.Key]=$entry.Value}
 return $safe
}
function SafeNativeMeetingRuntimeFields($Record){
 if(($Record.schema -isnot [int] -and $Record.schema -isnot [long]) -or $Record.schema -ne 1){return @{}}
 $specs=@{modules=@('sofia','conference','hash','vpx','opus');codecs=@('query_valid','pcmu','pcma','vp8','opus');profile=@('query_valid','loopback_signalling','pcmu','pcma','vp8');dtls_certificate=@('observed','ordinary_file','certificate_parsed','private_key_parsed','key_matches','current_validity','rsa_at_least_4096','sha256_fingerprint')}
 $top=@('schema','read_only','observed','certificate_directory_owned')+@($specs.Keys)
 $keys=if($Record -is [Collections.IDictionary]){@($Record.Keys)}elseif($Record -is [pscustomobject]){@($Record.PSObject.Properties|ForEach-Object Name)}else{return @{}}
 if($keys.Count -ne $top.Count -or @($keys|Where-Object {$_ -cnotin $top}).Count){return @{}}
 $safe=@{schema=1}
 foreach($field in 'read_only','observed','certificate_directory_owned'){if($Record.$field -isnot [bool]){return @{}};$safe[$field]=$Record.$field}
 if(!$safe.read_only){return @{}}
 foreach($section in $specs.Keys){
  $value=$Record.$section;$keys=if($value -is [Collections.IDictionary]){@($value.Keys)}elseif($value -is [pscustomobject]){@($value.PSObject.Properties|ForEach-Object Name)}else{return @{}}
  if($keys.Count -ne $specs[$section].Count -or @($keys|Where-Object {$_ -cnotin $specs[$section]}).Count){return @{}}
  $safe[$section]=@{};foreach($field in $specs[$section]){if($value.$field -isnot [bool]){return @{}};$safe[$section][$field]=$value.$field}
 }
 return $safe
}
function NativeMeetingLogCategories([string]$Text,[DateTime]$StartedAt){
 # Only timestamped lines from this isolated runner's attempt are classified.
 # This is time-window evidence, not caller-specific or decoded-media proof.
 $patterns=@{
  codec_negotiation='CODEC NEGOTIATION ERROR|No audio codec available|NO CODECS|NO_CODEC|NO MATCHING CODEC'
  missing_sdp_connection='Cannot find a c= line in the sdp'
  crypto_required='Crypto not negotiated but required'
  fingerprint_file='FP (BIO|FILE|READ) ERR!'
  dtls_certificate='DTLS cert err|DTLS key err|DTLS check key failed|DTLS check chain cert failed|Certificate generation failed'
  dtls_handshake='DTLS packet (decode|encode|write) err|DTLS packet not written to socket|Fingerprint Verification Failed|No peer certificate presented|DTLS state from [A-Z_]+ to (FAIL|INVALID)'
  incompatible_destination='INCOMPATIBLE_DESTINATION'
  ice_candidate_unusable='no suitable candidates found|Drop (audio|video) Candidate[^\r\n]*\((not an IP address|cannot resolve|no network path)\)'
  rtp_activation='(AUDIO|VIDEO) RTP REPORTS ERROR|Error initializing SRTP|Error allocating SRTP|Error! RE-Activating[^\r\n]*Secure RTP (SEND|RECV)'
 }
 $row=@{scope='isolated_runner_time_window';timestamped_lines=0}
 foreach($name in $patterns.Keys){$row[$name]=$false}
 $begin=$StartedAt.ToLocalTime().AddSeconds(-1);$end=[DateTime]::Now.AddSeconds(1)
 foreach($line in ($Text -split "`n")){
  if($line -notmatch '(?:^|\s)(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})(?:\.[0-9]+)?\s'){continue}
  $when=[DateTime]::MinValue
  if(![DateTime]::TryParseExact($Matches[1],'yyyy-MM-dd HH:mm:ss',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$when) -or $when -lt $begin -or $when -gt $end){continue}
  if($row.timestamped_lines -lt 65536){$row.timestamped_lines++}
  foreach($name in $patterns.Keys){if($line -match $patterns[$name]){$row[$name]=$true}}
 }
 return $row
}
function NativeStartupFailure([DateTime]$StartedAt,[string]$PrivateDirectory){
 # This observer runs only in the caller's disposable fresh/native failure
 # window. It never starts/stops services, pauses calls, or changes profiles.
 if($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:RUNNER_OS -ne 'Windows' -or $env:GITHUB_REPOSITORY -ne 'embire2/openwebpbx'){throw 'Disposable hosted startup diagnostics required.'}
 $result=[ordered]@{schema=1;observed_at=[DateTime]::UtcNow.ToString('o');service_observed=$false;event_query_succeeded=$false;events=@();log_observed=$false;log_categories=[ordered]@{sofia_load_error=$false;lua_error=$false;database_error=$false;xml_error=$false;sip_profile_error=$false;tls_error=$false};native_queries=[ordered]@{attempted=$false;authenticated=$false;sofia_loaded=$false;lua_loaded=$false;pgsql_loaded=$false;pause_state_known=$false;channels_known=$false;internal_profile_available=$false}}
 try{
  $service=Get-CimInstance Win32_Service -Filter "Name='FreeSWITCH'" -ErrorAction Stop
  if($service -and $service.Name -eq 'FreeSWITCH' -and $service.State -in 'Stopped','Start Pending','Stop Pending','Running','Continue Pending','Pause Pending','Paused','Unknown'){
   $result.service_observed=$true;$result.service_state=[string]$service.State
   $result.process_id=[uint32]$service.ProcessId;$result.win32_exit_code=[uint32]$service.ExitCode;$result.service_specific_exit_code=[uint32]$service.ServiceSpecificExitCode
   $result.service_status=if($service.Status -in 'OK','Error','Degraded','Unknown','Pred Fail','Starting','Stopping','Service','Stressed','NonRecover','No Contact','Lost Comm'){[string]$service.Status}else{'Unknown'}
  }
 }catch{}
 $end=[DateTime]::UtcNow.AddMinutes(5);$begin=$StartedAt.ToUniversalTime().AddMinutes(-5)
 $moduleNames=@('FreeSwitchConsole.exe','FreeSwitch.dll','mod_sofia.dll','libapr.dll','pthread.dll','mod_lua.dll','mod_pgsql.dll','mod_bcg729.dll','libbcg729.dll','VCRUNTIME140.dll','VCRUNTIME140_1.dll','ucrtbase.dll','KERNELBASE.dll','ntdll.dll')
 try{
  $events=@(Get-WinEvent -FilterHashtable @{LogName='Application';ProviderName='Application Error';Id=1000;StartTime=$begin;EndTime=$end} -MaxEvents 64 -ErrorAction Stop)
  $result.event_query_succeeded=$true
  foreach($event in $events){
   if($event.TimeCreated.ToUniversalTime() -lt $begin -or $event.TimeCreated.ToUniversalTime() -gt $end){continue}
   [xml]$xml=$event.ToXml();$data=@{}
   foreach($item in $xml.Event.EventData.Data){$data[[string]$item.Name]=[string]$item.'#text'}
   if($data.AppName -ine 'FreeSwitchConsole.exe'){continue}
   $module=[IO.Path]::GetFileName(($data.ModuleName -replace '\\','/'))
   if($module -notin $moduleNames){$module='external_component'}
   $safe=[ordered]@{event_id=1000;application='FreeSwitchConsole.exe';module_basename=$module}
   if($data.ExceptionCode -match '^(?:0x)?([a-fA-F0-9]{8})$'){$safe.exception_code=$Matches[1].ToLowerInvariant()}
   if($data.FaultingOffset -match '^(?:0x)?([a-fA-F0-9]{1,16})$'){$safe.fault_offset=$Matches[1].ToLowerInvariant()}
   $result.events+=,$safe
   # Raw XML is retained only in the administrator-private work directory.
   [IO.File]::WriteAllText((Join-Path $PrivateDirectory ('native-event-'+$result.events.Count+'.xml')),$event.ToXml(),[Text.UTF8Encoding]::new($false))
   if($result.events.Count -ge 8){break}
  }
 }catch{if($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*'){$result.event_query_succeeded=$true}}
 try{
  $path='C:/Program Files/FreeSWITCH/log/freeswitch.log'
  if(Test-Path -LiteralPath $path -PathType Leaf){
   $item=Get-Item -LiteralPath $path
   if(!($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){
    $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try{$count=[int][Math]::Min($stream.Length,1MB);[void]$stream.Seek(-$count,[IO.SeekOrigin]::End);$bytes=New-Object byte[] $count;$read=0;while($read -lt $count){$n=$stream.Read($bytes,$read,$count-$read);if(!$n){break};$read+=$n}}finally{$stream.Dispose()}
    if($read -lt $bytes.Length){$bytes=$bytes[0..($read-1)]};if(!$read){$bytes=[byte[]]@()}
    [IO.File]::WriteAllBytes((Join-Path $PrivateDirectory 'native-log-private.tail'),$bytes)
    $text=[Text.Encoding]::UTF8.GetString($bytes,0,$read);$result.log_observed=$true
    $patterns=@{sofia_load_error='(?im)(error loading|failed to load|module load[^\r\n]*fail)[^\r\n]*mod_sofia';lua_error='(?im)(Lua[^\r\n]*(error|fail)|LuaScriptError)';database_error='(?im)(database|SQL|pgsql)[^\r\n]*(error|fail)';xml_error='(?im)(XML[^\r\n]*(error|fail|invalid)|error[^\r\n]*XML)';sip_profile_error='(?im)(error creating SIP UA|SIP profile[^\r\n]*(fail|error))';tls_error='(?im)((TLS|SSL)[^\r\n]*(fail|error)|error loading[^\r\n]*cert)'}
    foreach($key in $patterns.Keys){$result.log_categories[$key]=[bool]($text -match $patterns[$key])}
    $result.meeting_log_window=NativeMeetingLogCategories -Text $text -StartedAt $StartedAt
   }
  }
 }catch{}
 if($result.service_observed -and $result.service_state -eq 'Running'){
  $result.native_queries.attempted=$true;$client=$null;$stream=$null
  try{
   $installation=Get-Content -LiteralPath (Join-Path $state 'installation.json') -Raw|ConvertFrom-Json
   if($installation.SwitchPassword -isnot [string] -or $installation.SwitchPassword -notmatch '^[a-zA-Z0-9_-]{16,128}$'){throw 'Private native credentials unavailable.'}
   $client=[Net.Sockets.TcpClient]::new();if(!$client.ConnectAsync('127.0.0.1',8021).Wait(5000)){throw 'Native observer connect timeout.'}
   $stream=$client.GetStream();$stream.ReadTimeout=5000;$stream.WriteTimeout=5000
   function ReadNativeStartupFrame {
    $header=@{};$line='';$total=0
    while($true){$byte=$stream.ReadByte();if($byte -lt 0 -or ++$total -gt 16384){throw 'Native observer framing failed.'};if($byte -eq 10){$line=$line.TrimEnd("`r");if(!$line){break};$split=$line.IndexOf(':');if($split -gt 0){$header[$line.Substring(0,$split).ToLowerInvariant()]=$line.Substring($split+1).Trim()};$line=''}else{$line+=[char]$byte}}
    $length=0;if($header.ContainsKey('content-length') -and ![int]::TryParse($header['content-length'],[ref]$length)){throw 'Native observer length failed.'}
    if($length -lt 0 -or $length -gt 65536){throw 'Native observer response too large.'}
    $body=New-Object byte[] $length;$read=0;while($read -lt $length){$n=$stream.Read($body,$read,$length-$read);if(!$n){throw 'Native observer response ended.'};$read+=$n}
    return @{header=$header;body=[Text.Encoding]::UTF8.GetString($body)}
   }
   function SendNativeStartupCommand([string]$Command){$bytes=[Text.Encoding]::ASCII.GetBytes($Command+"`n`n");$stream.Write($bytes,0,$bytes.Length);return ReadNativeStartupFrame}
   $greeting=ReadNativeStartupFrame;if($greeting.header['content-type'] -ne 'auth/request'){throw 'Native observer greeting failed.'}
   $auth=SendNativeStartupCommand ('auth '+$installation.SwitchPassword)
   if($auth.header['reply-text'] -ne '+OK accepted'){throw 'Native observer authentication failed.'}
   $result.native_queries.authenticated=$true
   foreach($module in @{sofia='mod_sofia';lua='mod_lua';pgsql='mod_pgsql'}.GetEnumerator()){$reply=SendNativeStartupCommand ('api module_exists '+$module.Value);$result.native_queries[$module.Key+'_loaded']=$reply.body.Trim() -eq 'true'}
   $reply=SendNativeStartupCommand 'api fsctl pause_check';$result.native_queries.pause_state_known=$reply.body.Trim() -in 'true','false'
   $reply=SendNativeStartupCommand 'api show channels as json';$channels=$reply.body|ConvertFrom-Json
   if($channels.row_count -is [int] -or $channels.row_count -is [long]){$result.native_queries.channels_known=$true;$result.native_queries.channels_count=[long]$channels.row_count}
   $reply=SendNativeStartupCommand 'api sofia status profile internal';$result.native_queries.internal_profile_available=[bool]($reply.body -match '(?m)^SIP-IP\s+[^\s]+\s*$')
   # Separate bounded read-only helper checks actual modules/codecs and the
   # core DTLS certificate. Its raw output/error never leaves private work.
   $result.meeting_media_observer='attempted'
   $start=[Diagnostics.ProcessStartInfo]::new('C:/OpenWebPBX/php/php.exe')
   $start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
   $start.Arguments='-f "'+(Join-Path $PSScriptRoot 'windows_meet_native_diagnostics.php')+'" -- --read-only'
   $process=[Diagnostics.Process]::new();$process.StartInfo=$start
   try{
    [void]$process.Start();$output=$process.StandardOutput.ReadToEndAsync();$errors=$process.StandardError.ReadToEndAsync()
    if(!$process.WaitForExit(15000)){$result.meeting_media_observer='timeout';try{$process.Kill();[void]$process.WaitForExit(2000)}catch{};throw 'Read-only media observer exceeded its deadline.'}
    if(!$output.Wait(2000) -or !$errors.Wait(2000)){throw 'Read-only media observer pipes did not close.'}
    [IO.File]::WriteAllText((Join-Path $PrivateDirectory 'native-meeting-runtime.stdout.private'),$output.Result,[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $PrivateDirectory 'native-meeting-runtime.stderr.private'),$errors.Result,[Text.UTF8Encoding]::new($false))
    $result.meeting_media_observer=if($process.ExitCode -eq 0){'invalid_output'}else{'process_failed'}
    if($process.ExitCode -eq 0 -and $output.Result.Length -le 16384){$closed=SafeNativeMeetingRuntimeFields ($output.Result|ConvertFrom-Json);if($closed.Count){$result.meeting_media_runtime=$closed;$result.meeting_media_observer='observed'}}
   }finally{$process.Dispose()}

  }catch{}finally{if($stream){$stream.Dispose()};if($client){$client.Dispose()}}
 }
 return $result
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
function TerminalReplayProducers($Run,$Jobs,[string]$RunId){
 foreach($field in 'status','event','path','head_sha'){if($Run.$field -isnot [string]){throw 'The original producer run fields must be scalar.'}}
 foreach($repository in @($Run.repository,$Run.head_repository)){if($repository.full_name -isnot [string] -or ($repository.id -isnot [int] -and $repository.id -isnot [long])){throw 'Exact typed repository identities are required.'}}
 if(($Run.run_attempt -isnot [int] -and $Run.run_attempt -isnot [long]) -or $Run.run_attempt -ne 1 -or ($Run.id -isnot [int] -and $Run.id -isnot [long]) -or [string]$Run.id -cne $RunId -or $Run.status -cne 'in_progress' -or $null -ne $Run.conclusion -or $Run.repository.full_name -cne 'embire2/openwebpbx' -or $Run.head_repository.full_name -cne 'embire2/openwebpbx' -or $Run.repository.id -ne 1406074259 -or $Run.head_repository.id -ne 1406074259 -or $Run.event -cne 'workflow_dispatch' -or $Run.path -cne '.github/workflows/windows-suite.yml' -or $Run.head_sha -isnot [string] -or $Run.head_sha -cnotmatch '^[a-f0-9]{40}$'){throw 'Only the exact original attempt with honestly pending run-level metadata may use terminal-producer provenance.'}
 if(($Jobs.total_count -isnot [int] -and $Jobs.total_count -isnot [long]) -or $Jobs.total_count -ne 2 -or $Jobs.jobs -isnot [array] -or $Jobs.jobs.Count -ne 2){throw 'Exactly the two declared original producer jobs must be terminal.'}
 $ids=@();$seen=@{}
 foreach($job in $Jobs.jobs){
  foreach($field in 'status','head_sha','conclusion'){if($job.$field -isnot [string]){throw 'The original producer job fields must be scalar.'}}
  if($job.name -isnot [string] -or $job.name -cnotin 'music','suite' -or $seen.ContainsKey($job.name) -or $job.status -cne 'completed' -or $job.head_sha -cne $Run.head_sha -or ($job.run_attempt -isnot [int] -and $job.run_attempt -isnot [long]) -or $job.run_attempt -ne 1 -or ($job.run_id -isnot [int] -and $job.run_id -isnot [long]) -or [string]$job.run_id -cne $RunId -or ($job.id -isnot [int] -and $job.id -isnot [long]) -or $job.id -lt 1){throw 'The original declared job identity, source, attempt or terminal state is invalid.'}
  $seen[$job.name]=$true;$ids+=[ordered]@{name=$job.name;id=$job.id}
  $label=if($job.name -ceq 'music'){'ubuntu-22.04'}else{'windows-2025'};$conclusion=if($job.name -ceq 'music'){'success'}else{'failure'}
  if($job.conclusion -cne $conclusion -or $job.labels -isnot [array] -or $job.labels.Count -ne 1 -or $job.labels[0] -cne $label -or $job.steps -isnot [array] -or $job.steps.Count -lt 4 -or $job.steps.Count -gt 24){throw 'The exact original hosted producer and its final failed/successful outcome are required.'}
  $required=if($job.name -ceq 'music'){@('Stage the immutable public Keoma system prompts','Store only canonical prepared audio and build provenance')}else{@('Store only credential-free acceptance facts','Preserve only the original verified candidate package and checksum')}
  foreach($name in $required){$steps=@($job.steps|Where-Object {$_.name -ceq $name});if($steps.Count -ne 1 -or $steps[0].status -cne 'completed' -or $steps[0].conclusion -cne 'success'){throw 'Every immutable original producer export must have completed successfully.'}}
  $failed=0
  foreach($step in $job.steps){if($step.name -isnot [string] -or $step.status -isnot [string] -or $step.conclusion -isnot [string] -or $step.status -cne 'completed' -or $step.conclusion -cnotin 'success','failure'){throw 'Pending, cancelled, skipped or incomplete original producer steps refuse.'};if($step.conclusion -ceq 'failure'){if($job.name -cne 'suite' -or $step.name -cne 'Verify build inputs and qualify the isolated server'){throw 'Only the declared original PBX qualification failure is allowed.'};$failed++}}
  if($failed -ne $(if($job.name -ceq 'suite'){1}else{0})){throw 'The original producer job failures do not match its final qualification facts.'}
 }
 if($ids[0].id -eq $ids[1].id){throw 'Distinct immutable producer job identities are required.'}
 return [ordered]@{schema=1;readiness='terminal_producer_jobs';original_run_status='in_progress';original_run_conclusion='unreported';attempt=1;jobs=@($ids|Sort-Object name)}
}
function AssertTerminalReplayArtifact($Artifact,$Run){
 $binding=$Artifact.workflow_run
 foreach($value in @($Artifact.id,$Artifact.size_in_bytes,$binding.id,$binding.repository_id,$binding.head_repository_id)){if(($value -isnot [int] -and $value -isnot [long]) -or $value -lt 1){throw 'Typed immutable V4 artifact and producer identities are required.'}}
 if($Artifact.size_in_bytes -gt 8GB -or $Artifact.expired -isnot [bool] -or $Artifact.expired -or $Artifact.digest -isnot [string] -or $Artifact.digest -cnotmatch '^sha256:[a-f0-9]{64}$' -or $binding.id -ne $Run.id -or $binding.head_sha -isnot [string] -or $binding.head_sha -cne $Run.head_sha -or $binding.repository_id -ne 1406074259 -or $binding.head_repository_id -ne 1406074259){throw 'The immutable original V4 artifact does not belong to the exact declared producer source.'}
}
function Artifact([string]$RunId,[string]$Kind){
 if($RunId -notmatch '^[0-9]+$'){throw 'Artifact run IDs must be numeric.'}
 if($Kind -cnotin 'native','engine','music','replay_candidate','replay_facts'){throw 'An exact reviewed artifact type is required.'}
 $replay=$Kind -cin 'replay_candidate','replay_facts'
 $run=Api ('actions/runs/'+$RunId)
 $workflow=if($replay){'.github/workflows/windows-suite.yml'}elseif($Kind -eq 'music'){SuiteMusicWorkflow $UpgradeDiagnosticsOnly $BackupsDiagnosticsOnly}else{'.github/workflows/windows-'+$Kind+'.yml'}
 if($run.repository.full_name -ne 'embire2/openwebpbx' -or $run.head_repository.full_name -ne 'embire2/openwebpbx' -or $run.event -ne 'workflow_dispatch' -or $run.path -ne $workflow -or $run.head_sha -notmatch '^[a-f0-9]{40}$'){throw 'The input run does not belong to the expected repository workflow.'}
 $producerProof=$null
 if($replay -and $ReplayTerminalProducers -and $run.status -cne 'completed'){
  $producerProof=TerminalReplayProducers $run (Api ('actions/runs/'+$RunId+'/jobs?per_page=100')) $RunId
 }elseif($replay){
  # GitHub may publish both completed jobs/artifacts before its run-level
  # terminal state. Wait boundedly; never infer completion from an artifact.
  $originalHead=$run.head_sha;$deadline=[DateTime]::UtcNow.AddMinutes(10)
  while($run.status -cin 'queued','in_progress','waiting','pending','requested' -and [DateTime]::UtcNow -lt $deadline){
   Start-Sleep -Seconds 10;$run=Api ('actions/runs/'+$RunId)
   if($run.repository.full_name -cne 'embire2/openwebpbx' -or $run.head_repository.full_name -cne 'embire2/openwebpbx' -or $run.event -cne 'workflow_dispatch' -or $run.path -cne $workflow -or $run.head_sha -cne $originalHead){throw 'The original replay run identity changed during metadata wait.'}
  }
 }
 if($Kind -eq 'music'){if($RunId -ne $env:GITHUB_RUN_ID -or $run.head_sha -ne $env:GITHUB_SHA){throw 'Music must come from this exact suite source.'}}
 elseif($replay){if(!$producerProof -and ($run.status -cne 'completed' -or $run.conclusion -cnotin 'success','failure')){throw 'Replay requires the exact completed original full-suite workflow or explicit terminal-producer provenance.'}}
 elseif($run.status -ne 'completed' -or $run.conclusion -ne 'success'){throw 'A source build did not complete successfully.'}
 $prefix=if($replay){'openwebpbx-windows-suite-'+$Kind.Substring(7)+'-'}elseif($Kind -eq 'music'){'openwebpbx-windows-suite-music-'}else{'openwebpbx-windows-'+$Kind+'-'}
 $artifacts=@((Api ('actions/runs/'+$RunId+'/artifacts?per_page=100')).artifacts|Where-Object {$_.name.StartsWith($prefix) -and $_.name.EndsWith('-'+$RunId) -and !$_.expired})
 if($artifacts.Count -ne 1 -or $artifacts[0].digest -notmatch '^sha256:[a-f0-9]{64}$' -or $artifacts[0].size_in_bytes -gt 8GB){throw 'One bounded hash-verified artifact is required.'}
 if($replay -and $artifacts[0].name -cne ($prefix+$RunId)){throw 'Replay requires the exact original artifact name.'}
 if($producerProof){AssertTerminalReplayArtifact $artifacts[0] $run}
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
 return @{directory=$destination;run=$run;artifact=$artifact;producer_proof=$producerProof}
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
 foreach($file in @('packaging/freeswitch/Build-WindowsNative.ps1','packaging/freeswitch/prepare-windows-native.py','packaging/freeswitch/windows-native-dependencies.py','packaging/freeswitch/windows-native-inputs.json','packaging/freeswitch/core-exports.py','packaging/freeswitch/restore-registration.patch','packaging/freeswitch/windows-websocket-fragments.patch','tests/windows_websocket_parser.py','packaging/codecs/bcg729/buffer-safety.patch','tests/pbx_bcg729_codec.c')){
  $current=(& git -C $source hash-object $file).Trim();$built=(& git -C $source rev-parse ($engine.run.head_sha+':'+$file)).Trim()
  if($LASTEXITCODE -or $current -ne $built){throw 'Rebuild the native engine: current recipe inputs differ from its build.'}
 }
 $backup=Join-Path $work 'backup-runtime';CheckedPython @((Join-Path $source 'packaging/windows/build-backup-runtime.py'),'--cache',(Join-Path $work 'upstream-cache'),'--output',$backup,'--sources',(Join-Path $work 'backup-source'))
 $acmeArchive=Join-Path $work 'simple-acme.zip';Invoke-WebRequest 'https://github.com/simple-acme/simple-acme/releases/download/v2.4.1/simple-acme.v2.4.1.2444.win-x64.trimmed.zip' -OutFile $acmeArchive
 $acme=Join-Path $work 'acme';CheckedPython @((Join-Path $source 'packaging/windows/build-acme-runtime.py'),'--archive',$acmeArchive,'--output',$acme)
 $output=Join-Path $work 'package'
 $packageArguments=@((Join-Path $source 'packaging/build-release.py'),'--target','windows','--server',(Join-Path $native.directory 'server'),'--updater',(Join-Path $native.directory 'updater'),'--desktop',(Join-Path $native.directory 'desktop'),'--engine',(Join-Path $engine.directory 'engine'),'--backup-runtime',$backup,'--acme',$acme,'--music',(Join-Path $music.directory 'music'),'--voices',(Join-Path $music.directory 'voices/1.0.2'),'--codec-source',(Join-Path $codec 'source'),'--output',$output)
 if($nativeManifest.msi_pthread_experiment){$packageArguments+=@('--registrar-source',(Join-Path $codec 'registrar-source'))}
 CheckedPython $packageArguments
 $archives=@(Get-ChildItem $output -Filter '*.zip' -File);if($archives.Count -ne 1){throw 'One candidate package is required.'}
 $script:candidateArchive=$archives[0].FullName
 $expanded=Join-Path $work 'expanded';PrivateDirectory $expanded;ExpandSafe $archives[0].FullName $expanded
 $roots=@(Get-ChildItem $expanded -Directory);if($roots.Count -ne 1){throw 'The candidate package has an ambiguous root.'}
 $facts.artifacts=@{native_run=$NativeRunId;native_digest=$native.artifact.digest;engine_run=$EngineRunId;engine_digest=$engine.artifact.digest;music_digest=$music.artifact.digest;candidate_sha256=(Hash $archives[0].FullName)}
 return $roots[0].FullName
}
function AssertReplaySourcePaths([string[]]$Paths){
 foreach($path in $Paths){
  $null=SafeRelative $path
  if($path -cin 'tests/pbx_bcg729_codec.c','tests/pbx_windows_pthread.c'){throw 'Pinned native-engine recipe inputs changed; rebuild the candidate.'}
  $nonWindows=$path.StartsWith('packaging/debian/',[StringComparison]::Ordinal) -and $path -cnotin 'packaging/debian/tenant-domains.py','packaging/debian/tenant-domains.php'
  if($path.StartsWith('tests/',[StringComparison]::Ordinal) -or $path.StartsWith('docs/',[StringComparison]::Ordinal) -or $nonWindows -or $path -cin 'AGENTS.md','README.md','readme.md','3CX.md','packaging/BUILDING.md','.github/workflows/windows-suite.yml','.github/workflows/windows-updater-qualification.yml','.github/workflows/windows-upgrade-diagnostics.yml','.github/workflows/windows-backups-diagnostics.yml','.github/workflows/windows-voicemail-diagnostics.yml','.github/workflows/windows-phone.yml'){continue}
  throw 'Windows runtime, native input or package source changed; rebuild the candidate instead of replaying it.'
 }
}
function ReplayFacts($Record,$Run,[string]$Version,[string]$OriginalRunId){
 if(($Record.schema -isnot [int] -and $Record.schema -isnot [long]) -or $Record.schema -ne 1 -or $Record.run_id -isnot [string] -or $Record.run_id -cne $OriginalRunId -or $Record.source_commit -isnot [string] -or $Record.source_commit -cne $Run.head_sha -or $Record.state -isnot [string] -or $Record.state -cnotin 'failed','partial','passed' -or @($Record.PSObject.Properties.Name|Where-Object {$_ -cin 'replay','product_source_commit'}).Count){throw 'Replay requires exact original build facts without a replay chain.'}
 $export=$Record.candidate_artifact;$artifact=$Record.artifacts
 if($export.filename -isnot [string] -or $export.filename -cne ('openwebpbx-'+$Version+'-windows-x64.zip') -or $export.sha256 -isnot [string] -or $export.sha256 -cnotmatch '^[a-f0-9]{64}$' -or $artifact.candidate_sha256 -isnot [string] -or $export.sha256 -cne $artifact.candidate_sha256 -or $export.verified_before_credentials -isnot [bool] -or !$export.verified_before_credentials -or $export.private_exclusions -isnot [string] -or $export.private_exclusions -cne 'passed'){throw 'Both original candidate hashes and the pre-credential export must agree.'}
 $safe=@{candidate_sha256=$export.sha256}
 foreach($name in 'native_run','engine_run'){if($artifact.$name -isnot [string] -or $artifact.$name -cnotmatch '^[1-9][0-9]{0,19}$'){throw 'The original native build identity is incomplete.'};$safe[$name]=$artifact.$name}
 foreach($name in 'native_digest','engine_digest','music_digest'){if($artifact.$name -isnot [string] -or $artifact.$name -cnotmatch '^sha256:[a-f0-9]{64}$'){throw 'The original build artifact identity is incomplete.'};$safe[$name]=$artifact.$name}
 return $safe
}
function PrepareReplayCandidate {
 $candidate=Artifact $ReplaySuiteRunId 'replay_candidate'
 if($ReplayCandidateArtifactId -and [string]$candidate.artifact.id -cne $ReplayCandidateArtifactId){throw 'The diagnostic candidate artifact ID differs from its explicit immutable pin.'}
 $original=Artifact $ReplaySuiteRunId 'replay_facts'
 if($candidate.run.head_sha -cne $original.run.head_sha){throw 'The original candidate and facts source differ.'}
 $reportPath=Join-Path $original.directory 'qualification.json';$report=Get-Item -LiteralPath $reportPath
 if($report.Length -gt 1MB -or ($report.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Bounded original build facts are required.'}
 $record=Get-Content -LiteralPath $reportPath -Raw|ConvertFrom-Json;$version=(Get-Content (Join-Path $source 'VERSION') -Raw).Trim()
 $provenance=ReplayFacts $record $candidate.run $version $ReplaySuiteRunId
 if($ReplayCandidateSha256 -and $provenance.candidate_sha256 -cne $ReplayCandidateSha256){throw 'The authenticated original candidate facts differ from the explicit diagnostic ZIP hash.'}
 $producerProof=$null
 if($candidate.producer_proof -or $original.producer_proof){
  if(!$candidate.producer_proof -or !$original.producer_proof -or $candidate.artifact.id -eq $original.artifact.id -or ($candidate.producer_proof|ConvertTo-Json -Depth 8 -Compress) -cne ($original.producer_proof|ConvertTo-Json -Depth 8 -Compress) -or $record.state -cne 'failed' -or $record.cleanup -isnot [string] -or $record.cleanup -cnotin 'owned services stopped, SFTP receiver/account removed, hostname removed, activation holds preserved','failed' -or $record.failed_phase -isnot [string] -or $record.failed_phase -cnotin 'fresh installation','native tenant-domain qualification','meeting transport qualification','native acceptance hook','independent trusted recovery fixture','upgrade acceptance hook','backup qualification'){throw 'Terminal-producer replay requires matching immutable jobs and complete final failed qualification facts.'}
  $producerProof=$candidate.producer_proof;$producerProof.original_instance_cleanup=$record.cleanup
 }
 & git -C $source fetch --quiet --no-tags --depth=1 https://github.com/embire2/openwebpbx.git $candidate.run.head_sha
 if($LASTEXITCODE){throw 'The immutable original product source is unavailable.'}
 $changed=@(& git -C $source diff --name-only --no-renames $candidate.run.head_sha $env:GITHUB_SHA --)
 if($LASTEXITCODE){throw 'The original and current source trees could not be compared.'};AssertReplaySourcePaths $changed
 $filename=$record.candidate_artifact.filename;$archive=Join-Path $candidate.directory $filename
 if((Hash $archive) -cne $provenance.candidate_sha256 -or [IO.File]::ReadAllText((Join-Path $candidate.directory 'SHA256SUMS')) -cne ($provenance.candidate_sha256+'  '+$filename+"`n")){throw 'The untouched original candidate ZIP and checksum differ.'}
 CheckedPython @((Join-Path $PSScriptRoot 'windows_candidate_archive.py'),'--archive',$archive,'--version',$version,'--sha256',$provenance.candidate_sha256)
 $expanded=Join-Path $work 'replayed-candidate';PrivateDirectory $expanded;ExpandSafe $archive $expanded
 $roots=@(Get-ChildItem -LiteralPath $expanded -Directory);if($roots.Count -ne 1 -or $roots[0].Name -cne ('openwebpbx-'+$version+'-windows-x64')){throw 'The original candidate package root is ambiguous.'}
 $script:candidateArchive=$archive;$facts.artifacts=$provenance;$facts.product_source_commit=$candidate.run.head_sha
 $facts.replay=@{schema=1;original_run=$ReplaySuiteRunId;original_product_source=$candidate.run.head_sha;qualification_source=$env:GITHUB_SHA;original_facts_sha256=(Hash $reportPath);candidate_artifact_digest=$candidate.artifact.digest;facts_artifact_digest=$original.artifact.digest;exact_zip_sha256=$provenance.candidate_sha256;windows_runtime_source_identical=$true;runtime_overlays=$false}
 if($UpgradeDiagnosticsOnly -or $BackupsDiagnosticsOnly){$facts.replay.expected_candidate_artifact_id=$ReplayCandidateArtifactId;$facts.replay.expected_candidate_sha256=$ReplayCandidateSha256}
 if($producerProof){$facts.replay.producer_provenance=$producerProof;$facts.replay.candidate_artifact_id=$candidate.artifact.id;$facts.replay.facts_artifact_id=$original.artifact.id}
 return $roots[0].FullName
}
function ExportOriginalCandidate($Release){
 if(!$candidateArchive -or !(Test-Path -LiteralPath $candidateArchive -PathType Leaf)){throw 'Candidate export requires the original built release ZIP.'}
 $filename=[IO.Path]::GetFileName($candidateArchive);$expectedName='openwebpbx-'+$Release.version+'-windows-x64.zip'
 if($filename -ne $expectedName){throw 'The original candidate archive filename is unexpected.'}
 $checksum=Hash $candidateArchive
 CheckedPython @((Join-Path $PSScriptRoot 'windows_candidate_archive.py'),'--archive',$candidateArchive,'--version',$Release.version,'--sha256',$checksum)
 if(Test-Path -LiteralPath $candidatePublic){throw 'The public candidate directory must not already contain unrelated material.'}
 $staging=Join-Path $work 'candidate-export';New-Item -ItemType Directory -Path $staging|Out-Null
 Copy-Item -LiteralPath $candidateArchive -Destination (Join-Path $staging $filename)
 if((Hash (Join-Path $staging $filename)) -ne $checksum){throw 'The original candidate archive changed during export.'}
 [IO.File]::WriteAllText((Join-Path $staging 'SHA256SUMS'),($checksum+'  '+$filename+"`n"),[Text.UTF8Encoding]::new($false))
 # Only a complete verified pair becomes visible to the upload allowlist.
 [IO.Directory]::Move($staging,$candidatePublic)
 $facts.candidate_artifact=@{filename=$filename;sha256=$checksum;verified_before_credentials=$true;private_exclusions='passed';qualification='reported separately'}
}
function Acquire-SuiteCleanupLock([string]$StateRoot,[string]$PrivateDirectory){
 $timer=[Diagnostics.Stopwatch]::StartNew();$attempts=0;$contended=$false
 do{
  $attempts++
  try{
   $handle=[IO.File]::Open("$StateRoot\upgrade.lock",'OpenOrCreate','ReadWrite','None')
   $facts.cleanup_lock_acquisition=@{attempts=$attempts;initial_contended=$contended;acquired=$true}
   return $handle
  }catch{
   $failure=$_
   $native=$failure.Exception;while($native.InnerException){$native=$native.InnerException}
   if(!$contended){
    $contended=$true
    try{$facts.cleanup_lock_observation=SafeOpenWebUpgradeLockFields (Get-OpenWebUpgradeLockObservation $StateRoot $PrivateDirectory (Read-OpenWebUpdaterGeneration $PrivateDirectory))}catch{}
   }
   $facts.cleanup_lock_acquisition=@{attempts=$attempts;initial_contended=$contended;acquired=$false}
   if($native -isnot [IO.IOException] -or $timer.Elapsed.TotalSeconds -ge 40){throw 'An owned transaction is still running; cleanup must not interrupt it.'}
   Start-Sleep -Milliseconds 250
  }
 }while($timer.Elapsed.TotalSeconds -lt 40)
 throw 'An owned transaction is still running; cleanup must not interrupt it.'
}
function BackupFailureReport([string]$Path,[datetime]$StartedAt){
 $safe=@{schema=1;observation='failure_only';report_status='unavailable'}
 try{
  if([IO.Path]::GetFileName($Path) -cne 'report.json' -or [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($Path)) -cne 'backup-qualification'){$safe.report_status='refused';return $safe}
  if(!(Test-Path -LiteralPath $Path -PathType Leaf)){$safe.report_status='absent';return $safe}
  $file=Get-Item -LiteralPath $Path -Force;$parent=Get-Item -LiteralPath $file.DirectoryName -Force
  if($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $file.LinkType -or ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $file.Length -gt 65536 -or $file.LastWriteTimeUtc -lt $StartedAt){$safe.report_status='refused';return $safe}
  $record=Get-Content -LiteralPath $Path -Encoding UTF8 -Raw|ConvertFrom-Json
  $failure=$record.failure
  $integer={param($Value,$Minimum,$Maximum) return (($Value -is [int] -or $Value -is [int64]) -and $Value -ge $Minimum -and $Value -le $Maximum)}
  if($record.state -isnot [string] -or $record.state -cne 'failed' -or !(& $integer $failure.schema 1 1)){$safe.report_status='invalid';return $safe}
  $phases=@('factory guard','HTTPS and CSRF','source notification identity','source trusted TLS','owned PBX','actual SYSTEM backup','retention','native SFTP','factory reset','native restore recovery','native successful restore','activation','unknown')
  $types=@('AssertionError','RuntimeError','BackupError','BackupBusy','ModuleNotFoundError','ImportError','NameError','TypeError','AttributeError','FileNotFoundError','PermissionError','OSError','ValueError','KeyError','IndexError','JSONDecodeError','TimeoutExpired','CalledProcessError','SSLError','SSLCertVerificationError','URLError','HTTPError','UnicodeDecodeError','EOFError','unknown')
  $safe.failed_phase=if($failure.failed_phase -is [string] -and $failure.failed_phase -cin $phases){$failure.failed_phase}else{'unknown'}
  $safe.error_type=if($failure.error_type -is [string] -and $failure.error_type -cin $types){$failure.error_type}else{'unknown'}
  $safe.source_frames=@();$frames=@($failure.source_frames)
  if($frames.Count -le 8){foreach($frame in $frames){if($frame.source_basename -is [string] -and $frame.source_basename -cin @('windows_backups_native.py','backups.py','windows-backups-worker-observer.py') -and (& $integer $frame.source_line 1 20000)){$safe.source_frames+=@{source_basename=$frame.source_basename;source_line=[int]$frame.source_line}}}}
  if(& $integer $failure.completed_checks 0 64){$safe.completed_checks=[int]$failure.completed_checks}
  $http=$failure.last_http;$safe.last_http=@{target='unknown';method='unknown';status=$null}
  if($http.target -is [string] -and $http.target -cin @('login','backups','notifications','download','unknown')){$safe.last_http.target=$http.target}
  if($http.method -is [string] -and $http.method -cin @('GET','POST','unknown')){$safe.last_http.method=$http.method}
  if(& $integer $http.status 100 599){$safe.last_http.status=[int]$http.status}
  $probe=$failure.local_service_observation
  if($null -ne $probe -and ($probe -is [pscustomobject] -or $probe -is [Collections.IDictionary]) -and $probe -isnot [Array] -and ($probe.schema -is [int] -or $probe.schema -is [long]) -and $probe.schema -eq 1){
   $safe.local_service_observation=@{schema=1}
   if($probe.phase -is [string] -and $probe.phase -cin @('setup','register','start_wait','result_read','privacy_assertions','cleanup','complete')){$safe.local_service_observation.phase=$probe.phase}
   foreach($key in 'creation_receipt','fresh_completion','primary_preserved'){if($probe.$key -is [bool]){$safe.local_service_observation[$key]=$probe.$key}}
   if($probe.cleanup -is [string] -and $probe.cleanup -cin @('not_attempted','removed','refused')){$safe.local_service_observation.cleanup=$probe.cleanup}
   if($probe.read_error -is [string] -and $probe.read_error -cin @('none','access_denied','sharing_violation','lock_violation','other')){$safe.local_service_observation.read_error=$probe.read_error}
  }
  $tls=$failure.tls_preparation
  if((& $integer $tls.schema 1 1) -and $tls.operation -is [string] -and $tls.operation -cin @('prepare_restored_tls','source_trusted_tls') -and $tls.report_status -is [string] -and $tls.report_status -cin @('read','unavailable')){
   $safe.tls_preparation=@{schema=1;operation=$tls.operation;report_status=$tls.report_status;source_frames=@()}
   if($tls.state -is [string] -and $tls.state -ceq 'failed'){$safe.tls_preparation.state='failed'}
   $tlsTypes=@('RuntimeException','MethodInvocationException','InvalidOperationException','UnauthorizedAccessException','IOException','FileNotFoundException','ItemNotFoundException','CryptographicException','Win32Exception','COMException','ParameterBindingException','CommandNotFoundException','PSArgumentException','ActionPreferenceStopException','unknown')
   $tlsClasses=@('configuration_missing','restore_blocked','calls_not_held_and_stopped','public_hostname','certificate_not_eligible','certificate_chain','certificate_chain_size','backup_access','certificate_access','native_php','unknown')
   if($tls.error_type -is [string] -and $tls.error_type -cin $tlsTypes){$safe.tls_preparation.error_type=$tls.error_type}
   if($tls.failure_class -is [string] -and $tls.failure_class -cin $tlsClasses){$safe.tls_preparation.failure_class=$tls.failure_class}
   foreach($key in 'returncode','hresult'){if(& $integer $tls.$key -2147483648 2147483647){$safe.tls_preparation[$key]=[int64]$tls.$key}}
   if(& $integer $tls.native_code 0 65535){$safe.tls_preparation.native_code=[int]$tls.native_code}
   $frames=@($tls.source_frames)
   if($frames.Count -le 8){foreach($frame in $frames){if($frame.source_basename -is [string] -and $frame.source_basename -cin @('Enable-PhoneTLS.ps1','Restore-Gates.ps1','Write-PrivateState.ps1','windows-backup-tls-observer.ps1') -and (& $integer $frame.source_line 1 20000)){$safe.tls_preparation.source_frames+=@{source_basename=$frame.source_basename;source_line=[int]$frame.source_line}}}}
   $php=$tls.php_failure
   if($php.error_type -is [string] -and $php.error_type -cin @('RuntimeException','InvalidArgumentException','PDOException','TypeError','Error','ValueError','Exception') -and $php.source_basename -is [string] -and $php.source_basename -cin @('phone-tls.php','phone-tls-chain.php','pbx_phone_auth.php','pbx_sip_domain.php','event_socket.php','config.php','database.php','external_component') -and (& $integer $php.source_line 1 100000) -and $php.stage -is [string] -and $php.stage -cin @('idle','bind','resume','ready','apply','rollback','initialization')){$safe.tls_preparation.php_failure=@{error_type=$php.error_type;source_basename=$php.source_basename;source_line=[int]$php.source_line;stage=$php.stage}}
  }
  $lock=$failure.lock_observation
  $isRecord={param($Value) return ($null -ne $Value -and ($Value -is [Collections.IDictionary] -or $Value -is [pscustomobject]) -and $Value -isnot [Array])}
  if((& $isRecord $lock) -and (& $integer $lock.schema 1 1) -and $lock.observation -is [string] -and $lock.observation -ceq 'after_original_busy_error'){
   $projected=@{schema=1;observation='after_original_busy_error'};$valid=$true
   foreach($key in 'upgrade','worker'){
    $entry=$lock.$key
    if((& $isRecord $entry) -and $entry.state -is [string] -and $entry.state -cin @('available','busy','missing','access_denied','not_ordinary','other') -and $entry.stream_closed -is [bool]){$projected[$key]=@{state=$entry.state;stream_closed=$entry.stream_closed}}else{$valid=$false}
   }
   if($valid){
    $native=$lock.native
    if(& $isRecord $native){
     $part=@{};$nativeValid=$true
     foreach($key in 'observed','health_observed','local_running','version_matches','iis_login_ready','known_recover_holder'){if($native.$key -is [bool]){$part[$key]=$native.$key}else{$nativeValid=$false}}
     foreach($key in 'holder_count','verified_holder_count'){if(& $integer $native.$key 0 32){$part[$key]=[int]$native.$key}else{$nativeValid=$false}}
     if($native.updater_state -is [string] -and $native.updater_state -cin @('unknown','Stopped','Running','Start Pending','Stop Pending','Paused','Continue Pending','Pause Pending')){$part.updater_state=$native.updater_state}else{$nativeValid=$false}
     if($nativeValid -and $part.verified_holder_count -le $part.holder_count){$projected.native=$part}
    }
    $safe.lock_observation=$projected
   }
  }
  $command=$failure.failed_command
  if((& $integer $command.schema 1 1) -and $command.report_status -is [string] -and $command.report_status -cin @('read','refused','unavailable')){
   $safe.failed_command=@{schema=1;report_status=$command.report_status}
   $categories=@{action=@('create','verify');status=@('failed');message_category=@('private_file_changed','password_or_key_unreadable','required_tool_timeout_or_unavailable','required_tool_failed','retention_integrity','private_storage_unavailable','generic_non_backup_error','unknown');local_status=@('creating','ready','failed','absent','unknown');remote_status=@('disabled','pending','uploaded','failed','absent','unknown')}
   foreach($key in $categories.Keys){if($command.$key -is [string] -and $command.$key -cin $categories[$key]){$safe.failed_command[$key]=$command.$key}}
   if(& $integer $command.linked_count 0 1){$safe.failed_command.linked_count=[int]$command.linked_count}
  }
  $local=$failure.local_query_observation
  if((& $integer $local.schema 1 1) -and $local.wrappers_restored -is [bool] -and $local.truncated -is [bool]){
   $safe.local_query_observation=@{schema=1;wrappers_restored=$local.wrappers_restored;truncated=$local.truncated;events=@()}
   $events=@($local.events)
   if($events.Count -le 8){foreach($event in $events){
    if($event.event -isnot [string] -or $event.event -cnotin @('tool_failure','run_failure','query_failure')){continue}
    $entry=@{event=$event.event}
    $choices=@{tool=@('psql','pg_dump','pg_restore','ssh-keygen','sftp','powershell','unknown');failure_class=@('database_invalid_encoding','database_client_encoding','database_permission','database_connection','database_syntax','ssh_private_key_permissions','ssh_private_key_format','ssh_private_key_unreadable','ssh_host_key','ssh_authentication','ssh_connection','ssh_remote_path','unknown');error_type=@('BackupError','TimeoutExpired','OSError','FileNotFoundError','PermissionError','UnicodeDecodeError','unknown')}
    foreach($key in $choices.Keys){if($event.$key -is [string] -and $event.$key -cin $choices[$key]){$entry[$key]=$event.$key}}
    if(& $integer $event.returncode -2147483648 2147483647){$entry.returncode=[int64]$event.returncode}
    $safe.local_query_observation.events+=,$entry
   }}
  }
  $worker=$failure.worker_observation
  if((& $integer $worker.schema 1 1) -and $worker.report_status -is [string] -and $worker.report_status -cin @('read','refused','unavailable')){
   $safe.worker_observation=@{schema=1;report_status=$worker.report_status;events=@()}
   foreach($key in 'action_restored','truncated'){if($worker.$key -is [bool]){$safe.worker_observation[$key]=$worker.$key}}
   $events=@($worker.events)
   if($events.Count -le 8){foreach($event in $events){
    if($event.event -isnot [string] -or $event.event -cnotin @('tool_failure','run_failure','upload_failure') -or $event.phase -isnot [string] -or $event.phase -cnotin @('before_upload','upload','after_upload')){continue}
    $entry=@{event=$event.event;phase=$event.phase}
    $choices=@{tool=@('psql','pg_dump','pg_restore','ssh-keygen','sftp','powershell','unknown');failure_class=@('database_invalid_encoding','database_client_encoding','database_permission','database_connection','database_syntax','ssh_private_key_permissions','ssh_private_key_format','ssh_private_key_unreadable','ssh_host_key','ssh_authentication','ssh_connection','ssh_remote_path','unknown');error_type=@('BackupError','TimeoutExpired','OSError','FileNotFoundError','PermissionError','UnicodeDecodeError','unknown')}
    foreach($key in $choices.Keys){if($event.$key -is [string] -and $event.$key -cin $choices[$key]){$entry[$key]=$event.$key}}
    if(& $integer $event.returncode -2147483648 2147483647){$entry.returncode=[int64]$event.returncode}
    $safe.worker_observation.events+=,$entry
   }}
  }
  $recovery=$failure.recovery_observation
  if(& $integer $recovery.schema 1 1){
   $safe.recovery_observation=@{schema=1;events=@()}
   if($recovery.journal_state -is [string] -and $recovery.journal_state -cin @('absent','prepared','restoring','restored','recovery_required','recovered','unknown','unavailable')){$safe.recovery_observation.journal_state=$recovery.journal_state}
   foreach($key in 'injection_reached','recover_called','wrappers_restored','truncated'){if($recovery.$key -is [bool]){$safe.recovery_observation[$key]=$recovery.$key}}
   $errorFields={param($value)
    $entry=@{source_frames=@()}
    if($value.error_type -is [string] -and $value.error_type -cin $types){$entry.error_type=$value.error_type}
    $frames=@($value.source_frames)
    if($frames.Count -le 8){foreach($frame in $frames){if($frame.source_basename -is [string] -and $frame.source_basename -cin @('windows_backups_native.py','backups.py') -and (& $integer $frame.source_line 1 20000)){$entry.source_frames+=@{source_basename=$frame.source_basename;source_line=[int]$frame.source_line}}}}
    return $entry
   }
   foreach($key in 'original_error','recovery_error','reported_error'){if($recovery.$key){$safe.recovery_observation[$key]=& $errorFields $recovery.$key}}
   $acl=$recovery.acl_observation
   if((& $integer $acl.schema 1 1) -and $acl.report_status -is [string] -and $acl.report_status -cin @('read','refused','unavailable')){
    $projected=@{schema=1;report_status=$acl.report_status;mismatches=@()}
    if($acl.control_restored -is [bool]){$projected.control_restored=$acl.control_restored}
    $items=@($acl.mismatches)
    if($items.Count -le 3){foreach($item in $items){
     if($item.file_category -isnot [string] -or $item.file_category -cnotin @('config','template_key','runtime','installation','phone_tls_metadata','phone_tls_material','public_access_source','notifications','legacy_push','freeswitch_config','voicemail','recordings','other_owned')){continue}
     $entry=@{file_category=$item.file_category};$valid=$true
     foreach($key in 'strict_sddl_equal','descriptor_binary_equal','owner_equal','group_equal','owner_before_null','owner_after_null','group_before_null','group_after_null'){if($item.$key -is [bool]){$entry[$key]=$item.$key}else{$valid=$false}}
     foreach($key in 'control_flags_before','control_flags_after','control_flags_xor'){if(& $integer $item.$key 0 65535){$entry[$key]=[int]$item.$key}else{$valid=$false}}
     foreach($key in 'descriptor_revision_before','descriptor_revision_after','resource_manager_control_before','resource_manager_control_after'){if(& $integer $item.$key 0 255){$entry[$key]=[int]$item.$key}else{$valid=$false}}
     foreach($label in 'dacl','sacl'){
      $value=$item.$label;$part=@{}
      foreach($key in 'before_null','after_null','raw_binary_equal','ace_sequence_equal','ace_set_equal','ace_multiset_equal','ace_multiplicity_equal','all_ordinary_allow_before','all_ordinary_allow_after'){if($value.$key -is [bool]){$part[$key]=$value.$key}else{$valid=$false}}
      foreach($side in 'before','after'){
       $key='revision_'+$side
       if($null -eq $value.$key){$part[$key]=$null}elseif(& $integer $value.$key 0 255){$part[$key]=[int]$value.$key}else{$valid=$false}
       foreach($prefix in 'size_','count_','unique_ace_count_','duplicate_ace_count_'){$key=$prefix+$side;if(& $integer $value.$key 0 65535){$part[$key]=[int]$value.$key}else{$valid=$false}}
      }
      $entry[$label]=$part
     }
     if($valid){$projected.mismatches+=,$entry}
    }}
    $safe.recovery_observation.acl_observation=$projected
   }
   $events=@($recovery.events)
   if($events.Count -le 8){foreach($event in $events){
    if($event.event -isnot [string] -or $event.event -cnotin @('tool_failure','run_failure','control_failure','recovery_failure') -or $event.phase -isnot [string] -or $event.phase -cnotin @('restore','recovery')){continue}
    $entry=(& $errorFields $event)+@{event=$event.event;phase=$event.phase}
    $choices=@{operation=@('secure','plan','hold','hold-selection','start-web','recover-startup','resume-factory','activate','acl-read','acl-restore','none','unknown');tool=@('psql','pg_dump','pg_restore','ssh-keygen','sftp','powershell','unknown');failure_class=@('database_invalid_encoding','database_client_encoding','database_permission','database_connection','database_syntax','ssh_private_key_permissions','ssh_private_key_format','ssh_private_key_unreadable','ssh_host_key','ssh_authentication','ssh_connection','ssh_remote_path','shell_command_not_found','shell_permission','shell_parameter_binding','shell_path','shell_invalid_operation','control_path_boundary','control_permission_class','control_startup_snapshot','control_stop_timeout','control_start_timeout','control_request','control_acl_snapshot','meet_restore_journal','meet_restore_holds','meet_restore_services','meet_restore_site','meet_restore_lock','meet_endpoint','meet_transport','meet_target_proxy','meet_ledger','unknown')}
    foreach($key in $choices.Keys){if($event.$key -is [string] -and $event.$key -cin $choices[$key]){$entry[$key]=$event.$key}}
    if(& $integer $event.returncode -2147483648 2147483647){$entry.returncode=[int64]$event.returncode}
    if($event.native_source_basename -is [string] -and $event.native_source_basename -cin @('Backup-Control.ps1','Install-Meet.ps1','Meet-Proxy.ps1','Write-PrivateState.ps1') -and (& $integer $event.native_source_line 1 20000)){$entry.native_source_basename=$event.native_source_basename;$entry.native_source_line=[int]$event.native_source_line}
    $safe.recovery_observation.events+=,$entry
   }}
  }
  $safe.report_status='read'
 }catch{}
 return $safe
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
 . (Join-Path $PSScriptRoot 'windows-sftp-diagnostics.ps1')
 Set-OpenWebSftpHostKeySecurity $hostkey $work
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
 if(!$connected){try{. (Join-Path $PSScriptRoot 'windows-sftp-diagnostics.ps1');$facts.sftp_startup_failure=Get-OpenWebSftpStartupFailure $sftp.task (Join-Path $ssh 'sshd.exe') $config $work $port}catch{};throw 'The separate loopback SFTP server did not start.'}
 $json=Join-Path $work 'sftp.json';$values=@{sftp_host='127.0.0.1';sftp_port=$port;sftp_user=$name;sftp_directory=('/OpenWebBackupQA'+$id);sftp_host_key=(Get-Content ($hostkey+'.pub') -Raw).Trim();identity=(Get-Content $identity -Raw);observed_directory=$directory}
 [IO.File]::WriteAllText($json,($values|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
 return $json
}
function RememberHookFailure($Record){
 $safe=SafeFailureFields $Record
 if(!$facts.hook_failure){$facts.hook_failure=$safe}
 else{
  if(!$facts.secondary_failure){$facts.secondary_failure=@{}}
  if(!$facts.secondary_failure.hook_failure){$facts.secondary_failure.hook_failure=$safe}
 }
}
function RememberSuiteFailure($Failure,[string]$Phase){
 $safe=SafeFailureFields ([pscustomobject]@{failed_phase=$Phase;error_type=$Failure.Exception.GetType().FullName;source_basename=$(if($Failure.InvocationInfo.ScriptName){Split-Path -Leaf $Failure.InvocationInfo.ScriptName}else{'windows-suite.ps1'});source_line=[int]$Failure.InvocationInfo.ScriptLineNumber})
 if($facts.state -ne 'failed'){$facts.state='failed';foreach($entry in $safe.GetEnumerator()){$facts[$entry.Key]=$entry.Value}}
 elseif($facts.failed_phase -cne $Phase){
  if(!$facts.secondary_failure){$facts.secondary_failure=@{}}
  if(!$facts.secondary_failure.runner_failure){$facts.secondary_failure.runner_failure=$safe}
 }
}
function NativeCleanupIsExact($Record){
 return ($Record.schema -is [int] -or $Record.schema -is [long]) -and $Record.schema -eq 1 -and $Record.state -is [string] -and $Record.state -ceq 'failed' -and $Record.gates.cleanup -is [string] -and $Record.gates.cleanup -ceq 'passed' -and $Record.cleanup -is [string] -and $Record.cleanup -ceq 'Original factory rows/contacts/identity/profile/config/certificate binding restored; owned CA/leaf and private probe task removed'
}
function NativeIdleIsHealthy($Observer){
 if(($Observer.schema -isnot [int] -and $Observer.schema -isnot [long]) -or $Observer.schema -ne 1 -or $Observer.service_state -isnot [string] -or $Observer.service_state -cne 'Running' -or $Observer.service_status -isnot [string] -or $Observer.service_status -cne 'OK' -or $Observer.events -isnot [array] -or $Observer.events.Count -ne 0){return $false}
 foreach($value in @($Observer.service_observed,$Observer.event_query_succeeded,$Observer.native_queries.attempted,$Observer.native_queries.authenticated,$Observer.native_queries.sofia_loaded,$Observer.native_queries.lua_loaded,$Observer.native_queries.pgsql_loaded,$Observer.native_queries.pause_state_known,$Observer.native_queries.channels_known,$Observer.native_queries.internal_profile_available)){
  if($value -isnot [bool] -or !$value){return $false}
 }
 foreach($value in @($Observer.win32_exit_code,$Observer.service_specific_exit_code,$Observer.native_queries.channels_count)){
  if(($value -isnot [int] -and $value -isnot [long] -and $value -isnot [uint32] -and $value -isnot [uint64]) -or $value -ne 0){return $false}
 }
 return $true
}
function ReadSuiteCdrBackgroundImport($Checks){
 $rows=@($Checks|Where-Object {$_.case -is [string] -and $_.case -ceq 'native_localservice_cdr_background_import'})
 if($rows.Count -ne 1 -or $rows[0] -isnot [pscustomobject]){throw 'Exactly one typed native background call-record proof is required.'}
 $row=$rows[0]
 $flags=@('actual_background_import','actual_localservice_identity','backend_pid_unchanged','read_only_observer','no_explicit_importer','before_system_drain','exact_call_domain_correlation','history_sources_exact','spool_absent')
 $counts=@{matched_cdr_rows=1;answered_cdr_rows=1;history_rows=2;history_owner_rows=2}
 $fields=@('case','passed','polls','elapsed_seconds')+$flags+@($counts.Keys)
 $names=@($row.PSObject.Properties.Name)
 if($names.Count -ne $fields.Count -or @($names|Where-Object {$_ -cnotin $fields}).Count -or $row.passed -isnot [bool] -or !$row.passed){throw 'The public call-record receipt must contain its exact closed fields.'}
 $safe=[ordered]@{case='native_localservice_cdr_background_import';passed=$true}
 foreach($flag in $flags){if($row.$flag -isnot [bool] -or !$row.$flag){throw 'Every native background call-record scope flag must be true.'};$safe[$flag]=$true}
 foreach($name in $counts.Keys){$value=$row.$name;if(($value -isnot [int] -and $value -isnot [long]) -or $value -ne $counts[$name]){throw 'Exact native call-record and participant-history counts are required.'};$safe[$name]=[int]$value}
 if(($row.polls -isnot [int] -and $row.polls -isnot [long]) -or $row.polls -lt 1 -or $row.polls -gt 26){throw 'The native call-record poll count is invalid.'}
 $elapsed=$row.elapsed_seconds
 if(($elapsed -isnot [int] -and $elapsed -isnot [long] -and $elapsed -isnot [single] -and $elapsed -isnot [double]) -or [double]::IsNaN([double]$elapsed) -or [double]::IsInfinity([double]$elapsed) -or $elapsed -lt 0 -or $elapsed -gt 30){throw 'The native call-record elapsed time must be finite and bounded.'}
 $safe.polls=[int]$row.polls;$safe.elapsed_seconds=[double]$elapsed
 return $safe
}
function NativeAcceptanceHook([string]$Report,[DateTime]$StartedAt){
 try{
  $record=AcceptanceHook 'windows-native-acceptance.ps1' $Report
  if(!$record){throw 'The required native acceptance hook is unavailable.'}
  return $record
 }catch{
  $failure=$_;RememberSuiteFailure $failure 'native acceptance hook'
  try{
   $file=Get-Item -LiteralPath $Report -ErrorAction Stop
   if($file.Length -gt 1MB -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Invalid native report.'}
   $record=Get-Content -LiteralPath $Report -Raw|ConvertFrom-Json
   if(!(NativeCleanupIsExact $record)){throw 'Exact native cleanup is not proved.'}
  }catch{$facts.native_continuation='aborted_cleanup';throw $failure}
  try{$observer=NativeStartupFailure -StartedAt $StartedAt -PrivateDirectory $work}catch{$observer=@{schema=1;observer_failed=$true}}
  $facts.native_runtime_failure=$observer
  if(!(NativeIdleIsHealthy $observer)){$facts.native_continuation='aborted_health';throw $failure}
  # Independent gates can produce evidence, while the original native failure
  # remains the suite's primary failure and its native gate stays unqualified.
  $facts.native_continuation='independent gates only';return $null
 }
}
function SafeMeetingTransportReport($Record){
 $phases=@('portable_controls','installed_arguments','installed_ledger','strict_proxy','websocket_inherited','websocket_locked_override','native_modules','mwa_absent','mwa_absent_enabled','mwa_explicit_false','mwa_explicit_true','snapshot_recovery','backend_tls','backend_wrong_host','frontend_wss','frontend_query_refusal')
 if(($Record.schema -isnot [int] -and $Record.schema -isnot [long]) -or $Record.schema -ne 1 -or $Record.state -isnot [string] -or $Record.state -cne 'failed' -or $Record.installed -isnot [bool] -or !$Record.installed -or $Record.control_phase -isnot [string] -or $Record.control_phase -cnotin $phases){return $null}
 $safe=SafeFailureFields ([pscustomobject]@{active_case=('native_windows_meeting_'+$Record.control_phase);meeting_failure=$Record.failure})
 if(!$safe.ContainsKey('meeting_failure')){return $null}
 return $safe
}
function SafeWebReadinessReport($Record){
 $types=@('none','external_component','InvalidOperationException','RuntimeException','MethodInvocationException','IOException','UnauthorizedAccessException','FileNotFoundException','DirectoryNotFoundException','TimeoutException','AuthenticationException','CryptographicException','ArgumentException')
 if(($Record.schema -isnot [int] -and $Record.schema -isnot [long]) -or $Record.schema -ne 1 -or $Record.case -isnot [string] -or $Record.case -cne 'native_windows_readiness_tls_boolean' -or $Record.state -isnot [string] -or $Record.state -cnotin 'passed','failed' -or ($Record.checks -isnot [int] -and $Record.checks -isnot [long]) -or $Record.checks -lt 0 -or $Record.checks -gt 100 -or $Record.cleanup_exact -isnot [bool] -or $Record.phase -isnot [string] -or $Record.phase -cnotin 'preflight','helper','certificate','fixture','installed_iis','cleanup','complete' -or $Record.error_type -isnot [string] -or $Record.error_type -cnotin $types -or ($Record.source_line -isnot [int] -and $Record.source_line -isnot [long]) -or $Record.source_line -lt 0 -or $Record.source_line -gt 99999){return $null}
 $safe=[ordered]@{};foreach($name in 'schema','case','state','checks','cleanup_exact','phase','error_type','source_line'){$safe[$name]=$Record.$name}
 foreach($name in 'manifest_helper_hash','scalar_boolean','trusted_tls','actual_iis'){if($Record.$name -isnot [bool]){return $null};$safe[$name]=$Record.$name}
 return $safe
}
function Read-PublicListenerQualificationReport($Record,[string]$Kind,$ChildExit) {
 if(($Record -isnot [pscustomobject] -and $Record -isnot [Collections.IDictionary]) -or ($ChildExit -isnot [int] -and $ChildExit -isnot [long]) -or $ChildExit -ne 0 -or ($Record.schema -isnot [int] -and $Record.schema -isnot [long]) -or $Record.schema -ne 1 -or $Record.state -isnot [string] -or $Record.state -cne 'passed'){throw 'The native public-listener proof or child result is invalid.'}
 if($Kind -ceq 'native_defender'){
  $producer='windows_public_listeners_native.ps1';$minimum=21
  $positive=@('actual_native_defender','actual_os_listener_ownership','service_identity_adapter_double','global_policy_exact','actual_throw_after_create_and_enable','idempotent','foreign_named_rule_preserved','configured_private_ports_excluded','profiles_all_enabled_at_observation')
  $negative=@('firewall_enforcement_tested','firewall_profiles_changed','installed_server_changed','calls_placed')
 }elseif($Kind -ceq 'installed_collector'){
  $producer='windows_public_listener_installed.ps1';$minimum=14
  $positive=@('actual_installed_php_pg_esl_os','exact_installed_helper_manifest','provider_5080_tcp_udp_planned','tls_only_when_actually_bound','configured_default_audio_source','private_service_ports_excluded','read_only_preflight')
  $negative=@('firewall_or_configuration_mutated','calling_or_audio_acceptance','installed_server_changed')
 }else{throw 'The public-listener proof scope is unknown.'}
 if($Record.producer -isnot [string] -or $Record.producer -cne $producer -or ($Record.checks -isnot [int] -and $Record.checks -isnot [long]) -or $Record.checks -lt $minimum -or $Record.checks -gt 100000){throw 'The actual public-listener evidence producer or control count is incomplete.'}
 $safe=@{schema=1;producer=$producer;state='passed';checks=$Record.checks}
 foreach($field in $positive){if($Record.$field -isnot [bool] -or !$Record.$field){throw 'The actual public-listener coverage or explicit fixture scope is incomplete.'};$safe[$field]=$true}
 foreach($field in $negative){if($Record.$field -isnot [bool] -or $Record.$field){throw 'The public-listener proof must preserve its read-only and packet-enforcement limits.'};$safe[$field]=$false}
 return $safe
}
function PublicListenerQualificationHook([string]$Kind) {
 if($ReplaySuiteRunId){$facts.public_listener_qualification='unqualified_historical_candidate';return}
 if($Kind -cnotin 'native_defender','installed_collector'){throw 'The public-listener qualification stage is invalid.'}
 if(!$facts.Contains('public_listener_qualification')){$facts.public_listener_qualification=@{state='partial';native_defender='pending';installed_collector='pending';outside_acme='unqualified'}}
 if($Kind -ceq 'installed_collector'){
  if($facts.public_listener_qualification.native_defender -isnot [Collections.IDictionary] -or $facts.public_listener_qualification.native_defender.state -cne 'passed' -or $facts.gates.fresh -cne 'passed' -or $facts.gates.web_readiness -cne 'passed' -or !(Test-Path -LiteralPath (Join-Path $PackageRoot 'public-listeners.php'))){throw 'Actual installed listener proof requires the current package, native Defender proof, fresh installation and trusted web readiness.'}
 }
 $script=if($Kind -ceq 'native_defender'){'windows_public_listeners_native.ps1'}else{'windows_public_listener_installed.ps1'}
 $reportPath=Join-Path $work ('public-listener-'+$Kind+'.json')
 $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'))
 $start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $start.Environment['PSModulePath']=(Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/Modules')+';'+(Join-Path $env:ProgramFiles 'WindowsPowerShell/Modules')
 $arguments=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot $script))
 if($Kind -ceq 'native_defender'){$arguments+=@('-SourceRoot',$source)}else{$arguments+=@('-PackageRoot',$PackageRoot,'-ReportPath',$reportPath)}
 foreach($argument in $arguments){$start.ArgumentList.Add($argument)}
 $process=[Diagnostics.Process]::Start($start);$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
 try{
  if(!$process.WaitForExit(240000)){$process.Kill($true);$null=$process.WaitForExit(10000);throw 'The native public-listener proof exceeded its deadline.'}
  if(!$stdout.Wait(5000) -or !$stderr.Wait(5000)){throw 'The native public-listener proof retained an output pipe.'}
  $text=$stdout.Result
  [IO.File]::WriteAllText((Join-Path $work ('public-listener-'+$Kind+'.private.out')),$text);[IO.File]::WriteAllText((Join-Path $work ('public-listener-'+$Kind+'.private.err')),$stderr.Result)
  if($Kind -ceq 'native_defender'){
   if($text.Length -gt 16384){throw 'The native Defender public-listener report exceeded its bound.'}
   $report=$text|ConvertFrom-Json
  }else{
   $file=Get-Item -LiteralPath $reportPath
   if($file.Length -gt 16384 -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'The installed public-listener report is invalid.'}
   $report=Get-Content -LiteralPath $reportPath -Raw|ConvertFrom-Json
  }
  $safe=Read-PublicListenerQualificationReport $report $Kind $process.ExitCode
  $facts.public_listener_qualification[$Kind]=$safe
  if($Kind -ceq 'installed_collector'){$facts.public_listener_qualification.state='passed'}
  $facts.checks+=('Actual native public-listener '+$Kind+' controls: '+$safe.checks+'; public ACME and packet enforcement are unqualified')
 }finally{$process.Dispose()}
}
function WebReadinessHook {
 $reportPath=Join-Path $work 'web-readiness-native.json'
 $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'))
 $start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $start.Environment['PSModulePath']=(Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/Modules')+';'+(Join-Path $env:ProgramFiles 'WindowsPowerShell/Modules')
 foreach($argument in @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'windows_web_readiness_native.ps1'),'-PackageRoot',$PackageRoot,'-ReportPath',$reportPath,'-DisposableHostedRunner')){$start.ArgumentList.Add($argument)}
 $process=[Diagnostics.Process]::Start($start);$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
 try{
  if(!$process.WaitForExit(240000)){$process.Kill($true);throw 'The isolated native readiness controls exceeded their deadline.'}
  [IO.File]::WriteAllText((Join-Path $work 'web-readiness.private.out'),$stdout.GetAwaiter().GetResult())
  [IO.File]::WriteAllText((Join-Path $work 'web-readiness.private.err'),$stderr.GetAwaiter().GetResult())
  $reportFile=Get-Item -LiteralPath $reportPath
  if($reportFile.Length -gt 16384 -or ($reportFile.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'The native readiness report is invalid.'}
  $safe=SafeWebReadinessReport (Get-Content -LiteralPath $reportPath -Raw|ConvertFrom-Json)
  if(!$safe){throw 'The native readiness report fields are invalid.'}
  $facts.web_readiness_report=$safe
  if($process.ExitCode -or $safe.state -cne 'passed' -or $safe.phase -cne 'complete' -or $safe.checks -lt 29 -or $safe.error_type -cne 'none'){throw 'The native packaged web readiness controls failed.'}
  foreach($field in 'manifest_helper_hash','scalar_boolean','trusted_tls','actual_iis','cleanup_exact'){if(!$safe[$field]){throw 'The packaged native readiness behavior and exact cleanup must pass.'}}
  $facts.gates.web_readiness='passed';$facts.checks+=('Actual native Windows packaged readiness helper, scalar Boolean HTTP500/framing/SAN refusals, trusted TLS and installed IIS login: '+$safe.checks)
 }finally{$process.Dispose()}
}
function SafeTenantDomainsProof($Record){
 $safe=@{}
 $task=$Record.task_observation
 if(($task -is [pscustomobject] -or $task -is [Collections.IDictionary]) -and ($task.last_task_result -is [int] -or $task.last_task_result -is [long]) -and $task.last_task_result -ge 0 -and $task.last_task_result -le 4294967295 -and $task.fresh_run -is [bool] -and $task.completed -is [bool] -and ($task.held_worker_exit -is [int] -or $task.held_worker_exit -is [long]) -and $task.held_worker_exit -ge -2147483648 -and $task.held_worker_exit -le 4294967295 -and $task.held_worker_state -is [string] -and $task.held_worker_state -cin 'unavailable','deferred' -and $task.held_worker_reason -is [string] -and $task.held_worker_reason -cin 'unavailable','maintenance_or_restore_hold' -and $task.held_worker_error_type -is [string] -and $task.held_worker_error_type -cin 'unavailable','none','BackupError','PermissionError','ValueError','ImportError','ModuleNotFoundError','OSError','FileNotFoundError','RuntimeError','JSONDecodeError','TimeoutExpired','Pending'){
  $safe.task_observation=@{};foreach($field in 'last_task_result','fresh_run','completed','held_worker_exit','held_worker_state','held_worker_reason','held_worker_error_type'){$safe.task_observation[$field]=$task.$field}
 }
 if(($Record.legacy_acl_status -is [int] -or $Record.legacy_acl_status -is [long]) -and $Record.legacy_acl_status -ge 100 -and $Record.legacy_acl_status -le 599){$safe.legacy_acl_status=[int]$Record.legacy_acl_status}
 $response=$Record.proof_response
 if($response -is [pscustomobject] -or $response -is [Collections.IDictionary]){
  if(($response.status -is [int] -or $response.status -is [long]) -and $response.status -ge 100 -and $response.status -le 599 -and $response.plain_text -is [bool] -and $response.exact_nonce_body -is [bool]){
   $safe.proof_response=@{status=[int]$response.status;plain_text=$response.plain_text;exact_nonce_body=$response.exact_nonce_body}
  }
 }
 return $safe
}
function SafeTenantDomainsReport($Record){
 $phases=@('initialization','packaged_task','worker_identity','proof_prepare','fixture_certificate','alias_certify','static_proof_https','alias_guard','foreign_binding','cleanup','complete')
 $types=@('RuntimeException','MethodInvocationException','ActionPreferenceStopException','ParameterBindingException','ParameterBindingValidationException','ItemNotFoundException','ProviderInvocationException','InvalidOperationException','IOException','FileNotFoundException','DirectoryNotFoundException','UnauthorizedAccessException','ArgumentException','FormatException','Win32Exception','COMException','WebException','Exception')
 if(($Record.schema -isnot [int] -and $Record.schema -isnot [long]) -or $Record.schema -ne 1 -or $Record.state -isnot [string] -or $Record.state -cne 'failed' -or $Record.case -isnot [string] -or $Record.case -cne 'native_windows_tenant_alias_worker_iis_https' -or $Record.phase -isnot [string] -or $Record.phase -cnotin $phases -or $Record.exception_type -isnot [string] -or $Record.exception_type -cnotin $types -or $Record.source_basename -isnot [string] -or $Record.source_basename -cnotin 'windows-tenant-domains-native.ps1','PublicAccess.Common.ps1','Tenant-Domains.ps1','external_component' -or ($Record.source_line -isnot [int] -and $Record.source_line -isnot [long]) -or $Record.source_line -lt 1 -or $Record.source_line -gt 99999){return $null}
 $safe=SafeFailureFields ([pscustomobject]@{active_case=('native_windows_tenant_'+$Record.phase);error_type=$Record.exception_type;source_basename=$Record.source_basename;source_line=[int]$Record.source_line})
 if($Record.cleanup_exact -is [bool]){$safe.cleanup_exact=$Record.cleanup_exact}
 $proof=SafeTenantDomainsProof $Record;foreach($key in $proof.Keys){$safe[$key]=$proof[$key]}
 return $safe
}
function TenantDomainsHook {
 $reportPath=Join-Path $work 'tenant-domains-native.json'
 $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'))
 $start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $start.Environment['PSModulePath']=(Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/Modules')+';'+(Join-Path $env:ProgramFiles 'WindowsPowerShell/Modules')
 foreach($argument in @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'windows-tenant-domains-native.ps1'),'-PackageRoot',$PackageRoot,'-ReportPath',$reportPath,'-DisposableHostedRunner')){$start.ArgumentList.Add($argument)}
 $process=[Diagnostics.Process]::Start($start);$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
 try{
  if(!$process.WaitForExit(300000)){throw 'The installed native tenant-domain controls did not finish.'}
  [IO.File]::WriteAllText((Join-Path $work 'tenant-domains.private.out'),$stdout.GetAwaiter().GetResult())
  [IO.File]::WriteAllText((Join-Path $work 'tenant-domains.private.err'),$stderr.GetAwaiter().GetResult())
  $reportFile=Get-Item -LiteralPath $reportPath
  if($reportFile.Length -gt 65536 -or ($reportFile.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'The native tenant-domain report is invalid.'}
  $report=Get-Content -LiteralPath $reportPath -Raw|ConvertFrom-Json
  if($process.ExitCode){$facts.tenant_domains_failure=SafeTenantDomainsReport $report;throw 'The actual Windows tenant-domain controls failed.'}
  if(($report.schema -isnot [int] -and $report.schema -isnot [long]) -or $report.schema -ne 1 -or $report.state -cne 'passed' -or $report.case -cne 'native_windows_tenant_alias_worker_iis_https' -or ($report.checks -isnot [int] -and $report.checks -isnot [long]) -or $report.checks -lt 1 -or $report.checks -gt 1000 -or $report.actual_acme -cne 'unqualified'){throw 'The actual native tenant-domain evidence is incomplete.'}
  foreach($field in 'system_task','private_acl','static_proof_https','alias_https','foreign_binding_refused','cleanup_exact'){if($report.$field -isnot [bool] -or !$report.$field){throw 'The actual native tenant-domain behavior and exact cleanup must pass.'}}
  $proof=SafeTenantDomainsProof $report
  if($proof.legacy_acl_status -ne 401 -or $proof.proof_response.status -ne 200 -or !$proof.proof_response.plain_text -or !$proof.proof_response.exact_nonce_body){throw 'Actual legacy ACL refusal and corrected trusted static proof evidence are required.'}
  $facts.tenant_domains_proof=$proof
  $facts.gates.tenant_domains='passed';$facts.checks+=('Actual Windows SYSTEM tenant worker, ACL, IIS alias/proof, strict fixture-CA HTTPS and owned recovery controls: '+$report.checks+'; public ACME unqualified')
 }finally{$process.Dispose()}
}
function DtlsQualificationHook {
 if(!(Test-Path -LiteralPath (Join-Path $PackageRoot 'Install-Dtls.ps1'))){
  if($ReplaySuiteRunId){$facts.dtls_qualification='unqualified_historical_candidate';return}
  throw 'The current complete candidate is missing its private DTLS provisioner.'
 }
 $reportPath=Join-Path $work 'dtls-qualification.json'
 $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'))
 $start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $start.Environment['PSModulePath']=(Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/Modules')+';'+(Join-Path $env:ProgramFiles 'WindowsPowerShell/Modules')
 foreach($argument in @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'windows_dtls_qualification.ps1'),'-SourceRoot',$source,'-PackageRoot',$PackageRoot,'-ReportPath',$reportPath)){$start.ArgumentList.Add($argument)}
 $process=[Diagnostics.Process]::Start($start);$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
 try{
  if(!$process.WaitForExit(180000)){throw 'The native DTLS preparation checks did not finish.'}
  [IO.File]::WriteAllText((Join-Path $work 'dtls-qualification.private.out'),$stdout.GetAwaiter().GetResult());[IO.File]::WriteAllText((Join-Path $work 'dtls-qualification.private.err'),$stderr.GetAwaiter().GetResult())
  $file=Get-Item -LiteralPath $reportPath;if($file.Length -gt 4096 -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Native DTLS evidence is invalid.'};$report=Get-Content -LiteralPath $reportPath -Raw|ConvertFrom-Json
  if($process.ExitCode){
   if($report.schema -eq 1 -and $report.state -ceq 'failed' -and $report.stage -cin 'transactions','installed' -and ($report.source_line -is [int] -or $report.source_line -is [long]) -and $report.source_line -gt 0 -and $report.source_line -lt 99999){$facts.dtls_failure=@{stage=$report.stage;source_basename='windows_dtls_qualification.ps1';source_line=$report.source_line}}
   throw 'The actual private DTLS certificate qualification failed.'
  }
  if($report.schema -ne 1 -or $report.producer -cne 'windows_dtls_qualification.ps1' -or $report.state -cne 'passed'){throw 'Native DTLS evidence is incomplete.'}
  foreach($field in 'actual_native_windows','private_certificate_valid','installed_engine_untouched','native_ntfs_transactions','transaction_service_adapter_double'){if($report.$field -isnot [bool] -or !$report.$field){throw 'The actual native DTLS proof is invalid.'}}
  foreach($limit in @(@('transaction_checks',62),@('crypto_checks',12),@('installed_checks',12))){$value=$report.($limit[0]);if(($value -isnot [int] -and $value -isnot [long]) -or $value -lt $limit[1] -or $value -gt 10000){throw 'The native DTLS proof count is invalid.'}}
  $facts.dtls_qualification=@{state='passed';transaction_checks=$report.transaction_checks;crypto_checks=$report.crypto_checks;installed_checks=$report.installed_checks;transaction_service_adapter_double=$true;actual_native_windows=$true}
 }finally{$process.Dispose()}
}
function ReadThreecxImportQualificationReport($Record){
 if($null -eq $Record -or $Record.GetType() -ne [Management.Automation.PSCustomObject] -or ($Record.schema -isnot [int] -and $Record.schema -isnot [long]) -or $Record.schema -ne 1 -or $Record.producer -isnot [string] -or $Record.producer -cne 'windows_threecx_import_native.ps1' -or $Record.state -isnot [string] -or $Record.state -cne 'passed' -or $Record.cleanup -isnot [string] -or $Record.cleanup -cne 'passed' -or $Record.php_version -isnot [string] -or $Record.php_version -cne '8.4.27' -or ($Record.checks -isnot [int] -and $Record.checks -isnot [long]) -or $Record.checks -lt 32 -or $Record.checks -gt 1000 -or ($Record.refusal_checks -isnot [int] -and $Record.refusal_checks -isnot [long]) -or $Record.refusal_checks -ne 4){throw 'The actual installed V20 import report is invalid.'}
 $safe=[ordered]@{schema=1;producer='windows_threecx_import_native.ps1';state='passed';cleanup='passed';checks=[int]$Record.checks;refusal_checks=4;php_version='8.4.27'}
 foreach($field in 'actual_native_windows','actual_installed_php_pg_zip_restore','configuration_path_adapter','synthetic_archive_only','original_credentials_preserved','custom_greeting_media_exact','default_greeting_unchanged','groups_and_routes_restored','providers_and_dids_disabled','complete_public_rows_exact','global_config_exact','owned_schema_media_key_removed','late_wav_failure_exact_rollback','original_writer_choices_restored'){if($Record.$field -isnot [bool] -or !$Record.$field){throw 'The complete isolated V20 import/preservation evidence is required.'};$safe[$field]=$true}
 foreach($field in 'ui_upload_tested','calling_tested','installed_server_changed','historical_failure_cause_proven'){if($Record.$field -isnot [bool] -or $Record.$field){throw 'The actual import coverage limits must remain explicit.'};$safe[$field]=$false}
 return $safe
}
function SafeThreecxImportFailure($Record){
 if($null -eq $Record -or $Record.GetType() -ne [Management.Automation.PSCustomObject] -or ($Record.schema -isnot [int] -and $Record.schema -isnot [long]) -or $Record.schema -ne 1 -or $Record.producer -isnot [string] -or $Record.producer -cne 'windows_threecx_import_native.ps1' -or $Record.state -isnot [string] -or $Record.state -cne 'failed'){return @{}}
 $safe=@{schema=1;producer='windows_threecx_import_native.ps1';state='failed'}
 if($Record.cleanup -is [string] -and $Record.cleanup -cin 'passed','failed','unverified'){$safe.cleanup=$Record.cleanup}
 if(($Record.checks -is [int] -or $Record.checks -is [long]) -and $Record.checks -ge 0 -and $Record.checks -le 1000){$safe.checks=[int]$Record.checks}
 if($Record.error_type -is [string] -and $Record.error_type -cmatch '^[A-Za-z0-9_]{1,80}$'){$safe.error_type=$Record.error_type}
 if(($Record.source_line -is [int] -or $Record.source_line -is [long]) -and $Record.source_line -gt 0 -and $Record.source_line -le 100000){$safe.source_line=[int]$Record.source_line}
 foreach($field in 'child_cleanup_failed','writer_restoration_failed','updater_restoration_failed','main_import_started','original_writer_choices_restored'){if($Record.$field -is [bool]){$safe[$field]=$Record.$field}}
 $sentinel=$Record.refusal_child
 if($null -ne $sentinel -and $sentinel.GetType() -eq [Management.Automation.PSCustomObject] -and $sentinel.exit_code -is [int] -and $sentinel.stdout_shape -is [string] -and $sentinel.stdout_shape -cin 'empty','expected_success','input_file_unavailable','other' -and $sentinel.stderr_shape -is [string] -and $sentinel.stderr_shape -cin 'empty','php_startup_warning','php_fatal','php_warning','other' -and $sentinel.stdout_chars -is [int] -and $sentinel.stdout_chars -ge 0 -and $sentinel.stdout_chars -le 8192 -and $sentinel.stderr_chars -is [int] -and $sentinel.stderr_chars -ge 0 -and $sentinel.stderr_chars -le 8192 -and (($sentinel.stdout_shape -ceq 'empty') -eq ($sentinel.stdout_chars -eq 0)) -and (($sentinel.stderr_shape -ceq 'empty') -eq ($sentinel.stderr_chars -eq 0))){$safe.refusal_child=@{exit_code=$sentinel.exit_code;stdout_shape=$sentinel.stdout_shape;stderr_shape=$sentinel.stderr_shape;stdout_chars=$sentinel.stdout_chars;stderr_chars=$sentinel.stderr_chars}}
 $child=$Record.php_failure
 if($null -ne $child -and $child.GetType() -eq [Management.Automation.PSCustomObject] -and $child.phase -is [string] -and $child.phase -cin 'input','database','synthetic_archive','apply','repeat_refusal','unsafe_zip','bad_wav_rollback' -and $child.error_type -is [string] -and $child.error_type -cin 'RuntimeException','InvalidArgumentException','PDOException','TypeError','ValueError','Error','Exception' -and $child.source_basename -is [string] -and $child.source_basename -cin 'windows_threecx_import_native.php','windows_threecx_fixture.php','pbx_setup_provisioner.php','pbx_v20_restore.php','threecx_backup.php','threecx_v20.php','pbx_paths.php','pbx_phone_restore.php','external_component' -and ($child.source_line -is [int] -or $child.source_line -is [long]) -and $child.source_line -gt 0 -and $child.source_line -le 100000 -and $child.cleanup_failed -is [bool]){$safe.php_failure=@{phase=$child.phase;error_type=$child.error_type;source_basename=$child.source_basename;source_line=[int]$child.source_line;cleanup_failed=$child.cleanup_failed}}
 return $safe
}
function ThreecxImportQualificationHook {
 if($ReplaySuiteRunId){$facts.threecx_import_qualification='unqualified_historical_candidate';return}
 $path=Join-Path $work 'threecx-import-native.json';$started=[DateTime]::UtcNow
 if(Test-Path -LiteralPath $path){throw 'Retain the prior actual V20 import evidence.'}
 try{
  & (Join-Path $source 'tests/windows_threecx_import_native.ps1') -PackageRoot $PackageRoot -ReportPath $path -DisposableHostedRunner *> (Join-Path $work 'threecx-import-native.private.log')
  if(!$?){throw 'Actual installed V20 import qualification failed.'}
  $file=Get-Item -LiteralPath $path -Force
  if($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $file.Length -lt 2 -or $file.Length -gt 65536 -or $file.LastWriteTimeUtc -lt $started.AddSeconds(-2) -or $file.LastWriteTimeUtc -gt [DateTime]::UtcNow.AddSeconds(2)){throw 'A fresh bounded native import report is required.'}
  $facts.threecx_import_qualification=ReadThreecxImportQualificationReport (Get-Content -LiteralPath $path -Raw|ConvertFrom-Json)
  $facts.checks+='Actual installed PHP8.4.27/PostgreSQL synthetic V20 parser, provisioning, restore, credentials, custom greeting, groups/routes, disabled providers and late-WAV rollback; isolated path adapter, no UI upload or calls'
 }catch{
  $failure=$_
  try{if(Test-Path -LiteralPath $path -PathType Leaf){$file=Get-Item -LiteralPath $path -Force;if(!($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $file.Length -le 65536){$safe=SafeThreecxImportFailure (Get-Content -LiteralPath $path -Raw|ConvertFrom-Json);if($safe.Count){$facts.threecx_import_failure=$safe}}}}catch{}
  throw $failure
 }
}
function PhpRuntimeQualificationHook {
 if($ReplaySuiteRunId){$facts.php_runtime_qualification='unqualified_historical_candidate';return}
 $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'))
 $start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $start.Environment['PSModulePath']=(Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/Modules')+';'+(Join-Path $env:ProgramFiles 'WindowsPowerShell/Modules')
 foreach($argument in @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'windows_php_runtime.ps1'),'-SourceRoot',$source,'-WorkRoot',$work)){$start.ArgumentList.Add($argument)}
 $process=[Diagnostics.Process]::Start($start);$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
 try{
  if(!$process.WaitForExit(300000)){$process.Kill($true);$null=$process.WaitForExit(10000);throw 'The private native PHP runtime controls did not finish.'}
  $text=$stdout.GetAwaiter().GetResult()
  [IO.File]::WriteAllText((Join-Path $work 'php-runtime-qualification.private.out'),$text);[IO.File]::WriteAllText((Join-Path $work 'php-runtime-qualification.private.err'),$stderr.GetAwaiter().GetResult())
  if($process.ExitCode -ne 0 -or $text.Length -gt 4096){throw 'The private native PHP runtime controls failed.'}
  $report=$text|ConvertFrom-Json
  if($report.schema -ne 1 -or $report.state -cne 'passed' -or $report.actual_native -isnot [bool] -or !$report.actual_native -or $report.installed_server_changed -isnot [bool] -or $report.installed_server_changed -or $report.new_version -cne '8.4.27' -or $report.old_version -cne '8.4.27'){throw 'The actual native PHP runtime proof is invalid.'}
  foreach($field in 'checks','vendor_files'){if(($report.$field -isnot [int] -and $report.$field -isnot [long]) -or $report.$field -lt 1 -or $report.$field -gt 100000){throw 'The native PHP runtime count is invalid.'}}
  $facts.php_runtime_qualification=@{state='passed';actual_native=$true;checks=$report.checks;vendor_files=$report.vendor_files;installed_server_changed=$false;version=$report.new_version}
 }finally{$process.Dispose()}
}
function Read-UpgradeRecoveryQualificationReport($Record,[string]$ExpectedVersion) {
 if(($Record -isnot [pscustomobject] -and $Record -isnot [Collections.IDictionary]) -or ($Record.schema -isnot [int] -and $Record.schema -isnot [long]) -or $Record.schema -ne 1 -or $ExpectedVersion -cnotmatch '^\d+\.\d+\.\d+$'){throw 'The native recovery proof schema or candidate version is invalid.'}
 foreach($entry in @(@('producer','windows-upgrade-recovery-qualification.ps1'),@('state','passed'),@('updater_version',$ExpectedVersion),@('updater_scope','candidate_component'))){if($Record.($entry[0]) -isnot [string] -or $Record.($entry[0]) -cne $entry[1]){throw 'The native recovery proof has an invalid scope or version.'}}
 foreach($field in 'actual_native_windows','actual_configured_updater_boot'){if($Record.$field -isnot [bool] -or !$Record.$field){throw 'The actual native recovery proof is incomplete.'}}
 if($Record.installed_server_changed -isnot [bool] -or $Record.installed_server_changed){throw 'The native recovery proof changed the installed server.'}
 foreach($limit in @(@('integration_checks',64),@('native_checks',202))){$value=$Record.($limit[0]);if(($value -isnot [int] -and $value -isnot [long]) -or $value -lt $limit[1] -or $value -gt 100000){throw 'The native recovery proof count is incomplete.'}}
 return @{state='passed';actual_native_windows=$true;actual_configured_updater_boot=$true;updater_scope='candidate_component';updater_version=$Record.updater_version;integration_checks=$Record.integration_checks;native_checks=$Record.native_checks;installed_server_changed=$false}
}
function Read-UpdaterCommitSelectionReport($Record) {
 if(($Record -isnot [pscustomobject] -and $Record -isnot [Collections.IDictionary]) -or ($Record.schema -isnot [int] -and $Record.schema -isnot [long]) -or $Record.schema -ne 1 -or $Record.producer -isnot [string] -or $Record.producer -cne 'windows_updater_commit_selection.ps1' -or $Record.state -isnot [string] -or $Record.state -cne 'passed'){throw 'The current native updater commit-selection proof is invalid.'}
 foreach($field in 'actual_native_windows','service_adapter_double','slot_assembly_fixture','actual_running_image_lock','old_silent_exit3_proven','exact_mirror_refusal_retry','completed_finalizer_idempotent','before_commit_old_scm','after_commit_resume','after_selection_idempotent','absent_creation_deferred','legacy_missing_dependency_recovery'){if($Record.$field -isnot [bool] -or !$Record.$field){throw 'The native commit-selection coverage or explicit fixture scope is incomplete.'}}
 foreach($field in 'actual_installed_scm','installed_server_changed'){if($Record.$field -isnot [bool] -or $Record.$field){throw 'This native commit-selection fixture must not claim installed SCM or server changes.'}}
 foreach($limit in @(@('checks',133),@('guard_checks',52))){$value=$Record.($limit[0]);if(($value -isnot [int] -and $value -isnot [long]) -or $value -lt $limit[1] -or $value -gt 100000){throw 'The native commit-selection matrices are incomplete.'}}
 if(($Record.actual_commit_interruption_positions -isnot [int] -and $Record.actual_commit_interruption_positions -isnot [long]) -or $Record.actual_commit_interruption_positions -ne 3){throw 'Both durable-commit sides and selected-service interruption must be covered.'}
 $safe=@{state='passed';checks=$Record.checks;guard_checks=$Record.guard_checks;actual_commit_interruption_positions=3}
 foreach($field in 'actual_native_windows','service_adapter_double','slot_assembly_fixture','actual_running_image_lock','old_silent_exit3_proven','exact_mirror_refusal_retry','completed_finalizer_idempotent','before_commit_old_scm','after_commit_resume','after_selection_idempotent','absent_creation_deferred','legacy_missing_dependency_recovery'){$safe[$field]=$true}
 $safe.actual_installed_scm=$false;$safe.installed_server_changed=$false;return $safe
}
function SafeUpgradeRecoveryQualificationFailure($Record) {
 if($null -eq $Record -or $Record.GetType() -ne [Management.Automation.PSCustomObject]){return @{}}
 $names=@($Record.PSObject.Properties.Name);foreach($name in 'schema','producer','state','stage','source_basename','source_line','error_type'){if($name -cnotin $names){return @{}}}
 if(($Record.schema -isnot [int] -and $Record.schema -isnot [long]) -or $Record.schema -ne 1 -or $Record.producer -isnot [string] -or $Record.producer -cne 'windows-upgrade-recovery-qualification.ps1' -or $Record.state -isnot [string] -or $Record.state -cne 'failed'){return @{}}
 if($Record.stage -isnot [string] -or $Record.stage -cnotin 'integration','native','commit_selection' -or $Record.source_basename -isnot [string] -or $Record.source_basename -cnotin 'windows-upgrade-recovery-qualification.ps1','windows_upgrade_recovery_qualification.ps1','windows_updater_commit_proof.ps1','windows_upgrade_recovery_integration.ps1','windows_upgrade_recovery.ps1','windows_updater_commit_selection.ps1','windows_updater_commit_selection_controls.ps1','UpgradeRecovery.Common.ps1','Upgrade-OpenWebPBX.ps1','CallRecords.Common.ps1','Write-PrivateState.ps1','external_component' -or ($Record.source_line -isnot [int] -and $Record.source_line -isnot [long]) -or $Record.source_line -lt 0 -or $Record.source_line -gt 100000 -or $Record.error_type -isnot [string] -or $Record.error_type -cnotin 'System.Management.Automation.RuntimeException','System.Management.Automation.MethodInvocationException','System.Management.Automation.ActionPreferenceStopException','System.Management.Automation.PSInvalidCastException','System.Management.Automation.PSArgumentException','System.Management.Automation.CommandNotFoundException','System.Management.Automation.ParameterBindingException','System.Management.Automation.ItemNotFoundException','System.Management.Automation.ParseException','System.Management.Automation.ParentContainsErrorRecordException','System.UnauthorizedAccessException','System.IO.IOException','System.ArgumentException','System.InvalidOperationException','System.TimeoutException','external_error'){return @{}}
 return @{schema=1;producer='windows-upgrade-recovery-qualification.ps1';state='failed';stage=$Record.stage;source_basename=$Record.source_basename;source_line=[int]$Record.source_line;error_type=$Record.error_type}
}
function UpgradeRecoveryQualificationHook {
 if($ReplaySuiteRunId){$facts.upgrade_recovery_qualification='unqualified_historical_candidate';return}
 $reportPath=Join-Path $work 'upgrade-recovery-qualification.json'
 $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'))
 $start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $start.Environment['PSModulePath']=(Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/Modules')+';'+(Join-Path $env:ProgramFiles 'WindowsPowerShell/Modules')
 foreach($argument in @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'windows-upgrade-recovery-qualification.ps1'),'-SourceRoot',$source,'-PackageRoot',$PackageRoot,'-ReportPath',$reportPath)){$start.ArgumentList.Add($argument)}
 $process=[Diagnostics.Process]::Start($start);$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
 try{
  if(!$process.WaitForExit(600000)){$process.Kill($true);$null=$process.WaitForExit(10000);throw 'The private native recovery controls did not finish.'}
  [IO.File]::WriteAllText((Join-Path $work 'upgrade-recovery-qualification.private.out'),$stdout.GetAwaiter().GetResult());[IO.File]::WriteAllText((Join-Path $work 'upgrade-recovery-qualification.private.err'),$stderr.GetAwaiter().GetResult())
  if($process.ExitCode -ne 0 -or !(Test-Path -LiteralPath $reportPath -PathType Leaf)){throw 'The private native recovery controls failed.'}
  $report=Get-Content -LiteralPath $reportPath -Raw|ConvertFrom-Json
  $facts.upgrade_recovery_qualification=Read-UpgradeRecoveryQualificationReport $report (Get-Content -LiteralPath (Join-Path $PackageRoot 'VERSION') -Raw).Trim()
  $facts.native_commit_selection=Read-UpdaterCommitSelectionReport $report.native_commit_selection
 }catch{
  try{if(Test-Path -LiteralPath $reportPath -PathType Leaf){$file=Get-Item -LiteralPath $reportPath -Force;if(!($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $file.Length -le 16384){$safe=SafeUpgradeRecoveryQualificationFailure (Get-Content -LiteralPath $reportPath -Raw|ConvertFrom-Json);if($safe.Count){$facts.upgrade_recovery_failure=$safe}}}}catch{}
  throw
 }finally{$process.Dispose()}
}
function MeetingTransportHook {
 $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'))
 $start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $start.Environment['PSModulePath']=(Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/Modules')+';'+(Join-Path $env:ProgramFiles 'WindowsPowerShell/Modules')
 foreach($argument in @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'windows_meet_proxy.ps1'),'-Installed','-Hostname',$domain,'-Port','8443')){$start.ArgumentList.Add($argument)}
 $process=[Diagnostics.Process]::Start($start);$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
 try{
  if(!$process.WaitForExit(120000)){throw 'The installed meeting transport controls did not finish.'}
  $out=$stdout.GetAwaiter().GetResult();$err=$stderr.GetAwaiter().GetResult()
  [IO.File]::WriteAllText((Join-Path $work 'meeting-transport.private.out'),$out)
  [IO.File]::WriteAllText((Join-Path $work 'meeting-transport.private.err'),$err)
  if($process.ExitCode){
   try{$safe=SafeMeetingTransportReport ($out|ConvertFrom-Json);if($safe){$facts.meeting_transport_failure=$safe}}catch{}
   throw 'The actual Windows meeting transport controls failed.'
  }
  $report=$out|ConvertFrom-Json
  if($report.schema -ne 1 -or !$report.installed -or $report.checks -lt 49){throw 'The installed meeting transport evidence is incomplete.'}
  $facts.gates.meeting_transport='passed';$facts.checks+=('Actual strict Windows backend TLS and IIS SIP WebSocket controls: '+$report.checks)
 }finally{$process.Dispose()}
}
function AcceptanceHook([string]$Name,[string]$Report){
 $script=Join-Path $PSScriptRoot $Name
 if(!(Test-Path -LiteralPath $script -PathType Leaf)){return $null}
 $failure=$null
 try{& $script -PackageRoot $PackageRoot -DisposableHostedRunner -InputPath $acceptanceFile -ReportPath $Report}catch{$failure=$_}
 if(!(Test-Path -LiteralPath $Report)){if($failure){throw $failure};throw 'An optional native acceptance hook did not finish.'}
 $record=Get-Content -LiteralPath $Report -Raw|ConvertFrom-Json
 if($record.state -ne 'passed'){
  RememberHookFailure $record
 }
 if($failure){throw $failure}
 if($record.state -ne 'passed'){throw 'An optional native acceptance hook did not pass.'}
 return $record
}
function SafeStunMaintenanceLockFields($Record){
 $safe=@{}
 foreach($name in 'maintenance_lock_acquired','maintenance_lock_busy'){if($Record.$name -is [bool]){$safe[$name]=$Record.$name}}
 if(($Record.maintenance_lock_elapsed_ms -is [int] -or $Record.maintenance_lock_elapsed_ms -is [long]) -and $Record.maintenance_lock_elapsed_ms -ge 0 -and $Record.maintenance_lock_elapsed_ms -le 60000){$safe.maintenance_lock_elapsed_ms=[long]$Record.maintenance_lock_elapsed_ms}
 if($Record.maintenance_lock_error_type -is [string] -and $Record.maintenance_lock_error_type -cin 'IOException','UnauthorizedAccessException','InvalidOperationException','DirectoryNotFoundException','FileNotFoundException','ArgumentException','SecurityException','NotSupportedException'){$safe.maintenance_lock_error_type=$Record.maintenance_lock_error_type}
 if($Record.maintenance_lock_hresult -is [string] -and $Record.maintenance_lock_hresult -cmatch '^[0-9a-f]{8}$'){$safe.maintenance_lock_hresult=$Record.maintenance_lock_hresult}
 $probe=$Record.maintenance_lock_probe
 if($probe -is [pscustomobject] -or $probe -is [Collections.IDictionary]){
  $part=@{}
  if($probe.lock_probe_result -is [string] -and $probe.lock_probe_result -cin 'available','sharing_violation','lock_violation','missing','access_denied','other_io','other_error','not_ordinary'){$part.lock_probe_result=$probe.lock_probe_result}
  if($probe.lock_probe_hresult -is [string] -and $probe.lock_probe_hresult -cmatch '^[0-9a-f]{8}$'){$part.lock_probe_hresult=$probe.lock_probe_hresult}
  if($part.Count){$safe.maintenance_lock_probe=$part}
 }
 return $safe
}
function StunHook {
 $reportPath=Join-Path $work 'stun-native.json'
 try{
  $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'));$start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
  $start.Environment['PSModulePath']=(Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/Modules')+';'+(Join-Path $env:ProgramFiles 'WindowsPowerShell/Modules')
  foreach($argument in @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'windows-stun-native.ps1'),'-PackageRoot',$PackageRoot,'-ReportPath',$reportPath,'-DisposableHostedRunner')){$start.ArgumentList.Add($argument)}
  $process=[Diagnostics.Process]::Start($start);$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
  try{
   if(!$process.WaitForExit(300000)){throw 'The owned native STUN setup is still running; inspect its durable recovery journal.'}
   [IO.File]::WriteAllText((Join-Path $work 'stun-native.private.out'),$stdout.GetAwaiter().GetResult());[IO.File]::WriteAllText((Join-Path $work 'stun-native.private.err'),$stderr.GetAwaiter().GetResult())
   if(!(Test-Path -LiteralPath $reportPath) -or $process.ExitCode){throw 'The actual native STUN setup controls failed.'}
  }finally{$process.Dispose()}
  $report=Get-Content -LiteralPath $reportPath -Raw|ConvertFrom-Json
  $facts.stun_lock_observation=SafeStunMaintenanceLockFields $report
  if(!$report -or $report.schema -ne 1 -or $report.state -cne 'passed' -or $report.case -cne 'native_windows_stun_setup_udp_recovery' -or ($report.checks -isnot [int] -and $report.checks -isnot [long]) -or $report.checks -lt 20 -or $report.checks -gt 1000 -or $report.external_firewall_reachability -cne 'unqualified'){throw 'The native STUN setup evidence is incomplete.'}
  foreach($name in 'actual_native','modern_binding','legacy_binding','turn_refused','idempotent','late_rule_failure_recovered','cleanup_exact','call_engine_preserved','stun_default_restored','firewall_policy_exact'){if($report.$name -isnot [bool] -or !$report.$name){throw 'Real Windows STUN, UDP, recovery and exact cleanup must pass.'}}
  $facts.gates.stun='passed';$facts.checks+=('Actual Windows STUN native service/firewall, modern/legacy decoded UDP, TURN refusal, idempotence and late-failure recovery: '+$report.checks)
 }catch{
  if(Test-Path -LiteralPath $reportPath){
   try{$r=Get-Content -LiteralPath $reportPath -Raw|ConvertFrom-Json;$safe=@{}
    foreach($name in 'actual_native','modern_binding','legacy_binding','turn_refused','idempotent','late_rule_failure_recovered','cleanup_exact','call_engine_preserved','stun_default_restored','firewall_policy_exact'){if($r.$name -is [bool]){$safe[$name]=$r.$name}}
    foreach($name in 'checks','source_line','cleanup_source_line'){$v=$r.$name;if(($v -is [int] -or $v -is [long]) -and $v -ge 0 -and $v -lt 100000){$safe[$name]=$v}}
    $lockFields=SafeStunMaintenanceLockFields $r;foreach($entry in $lockFields.GetEnumerator()){$safe[$entry.Key]=$entry.Value}
    if($r.phase -is [string] -and $r.phase -cin 'preflight','activation','modern_udp','legacy_udp','turn_refusal','idempotence','rollback','late_rule_failure'){$safe.phase=$r.phase};$facts.stun_failure=$safe
   }catch{}
  }
  throw
 }
}
. (Join-Path $PSScriptRoot 'windows-health-restart-phase.ps1')
function SafePhoneHealthFailure($Record){
 $safe=@{}
 if($Record.schema -ne 1 -or $Record.producer -cne 'windows_phone_health_acceptance.ps1' -or $Record.state -cne 'failed'){return $safe}
 $restart=$Record.restart_observation
 $restartKeys=if($restart -is [pscustomobject]){@($restart.PSObject.Properties.Name)}elseif($restart -is [Collections.IDictionary]){@($restart.Keys)}else{@()}
 $flags=@('task_observed','task_enabled','task_info_observed','fresh_start','processes_observed','system_verified','connections_observed','heartbeat_observed')
 $bounds=@{last_result=4294967295L;owned_wrappers=16;owned_php=16;pg_connections=32;matching_heartbeats=32}
 $fields=@('schema','task_state','error_kind','phase_observation')+$flags+@($bounds.Keys)
 if($restartKeys.Count -eq $fields.Count -and @($restartKeys|Where-Object {$_ -cnotin $fields}).Count -eq 0){
  $valid=($restart.schema -is [int] -or $restart.schema -is [long]) -and $restart.schema -eq 1 -and $restart.task_state -is [string] -and $restart.task_state -cin 'unavailable','Running','Ready','Queued','Disabled','Unknown','other' -and $restart.error_kind -is [string] -and $restart.error_kind -cin 'none','context','task','task_info','processes','connections','heartbeat','phase'
  foreach($field in $flags){if($restart.$field -isnot [bool]){$valid=$false}}
  foreach($field in $bounds.Keys){$value=$restart.$field;if(($value -isnot [int] -and $value -isnot [long]) -or $value -lt 0 -or $value -gt $bounds[$field]){$valid=$false}}
  $phase=$null;if($null -ne $restart.phase_observation){try{$phase=Read-HealthRestartPhase $restart.phase_observation;if(!$restart.processes_observed -or !$restart.system_verified -or $restart.owned_php -ne 1 -or !$restart.connections_observed -or $phase.backends.Count -gt $restart.pg_connections){$valid=$false}}catch{$valid=$false}}
  if($valid){$part=@{};foreach($field in $fields){$part[$field]=$restart.$field};$part.phase_observation=$phase;$safe.restart_observation=$part}
 }
 $safe.gates=@{};foreach($name in 'installed_task','installed_system_observer','installed_continuous_observer','installed_restart','installed_collector','postgresql_policy','runtime','custom_subscription','firewall','native_worker','cleanup'){if($Record.gates.$name -is [string] -and $Record.gates.$name -cin 'passed','pending','failed'){$safe.gates[$name]=$Record.gates.$name}}
 if($Record.diagnostic_recovery_exact -is [bool]){$safe.diagnostic_recovery_exact=$Record.diagnostic_recovery_exact}
 $recovery=$Record.diagnostic_recovery_failure
 if(($recovery -is [pscustomobject] -or $recovery -is [Collections.IDictionary]) -and $recovery.error_type -is [string] -and $recovery.error_type -cin 'RuntimeException','MethodInvocationException','ActionPreferenceStopException','ParameterBindingException','ItemNotFoundException','UnauthorizedAccessException','ArgumentException','FormatException','Win32Exception','Exception' -and ($recovery.source_line -is [int] -or $recovery.source_line -is [long]) -and $recovery.source_line -ge 1 -and $recovery.source_line -le 99999){$safe.diagnostic_recovery_failure=@{error_type=$recovery.error_type;source_line=$recovery.source_line}}
 $preservation=$Record.native_worker_preservation_failure
 if(($preservation -is [pscustomobject] -or $preservation -is [Collections.IDictionary]) -and ($preservation.schema -is [int] -or $preservation.schema -is [long]) -and $preservation.schema -eq 1){
  $valid=$true;$projected=@{schema=1}
  foreach($name in 'snapshot_valid','namespace_changed','inventory_changed','table_count_changed','global_digest_changed'){if($preservation.$name -isnot [bool]){$valid=$false;break};$projected[$name]=$preservation.$name}
  foreach($name in 'shape_changed_count','data_changed_count','object_count_before','object_count_after'){$value=$preservation.$name;if(($value -isnot [int] -and $value -isnot [long]) -or $value -lt 0 -or $value -gt 10000){$valid=$false;break};$projected[$name]=$value}
  if($preservation.changed_objects -isnot [array] -or $preservation.changed_objects.Count -gt 12){$valid=$false}
  $objects=@();if($valid){foreach($object in $preservation.changed_objects){
   if(($object -isnot [pscustomobject] -and $object -isnot [Collections.IDictionary]) -or $object.name -isnot [string] -or $object.name -cnotmatch '^v_[a-z0-9_]{1,90}$' -or $object.shape_changed -isnot [bool] -or $object.data_changed -isnot [bool] -or $object.row_count_changed -isnot [bool]){$valid=$false;break}
   $objects+=@{name=$object.name;shape_changed=$object.shape_changed;data_changed=$object.data_changed;row_count_changed=$object.row_count_changed}
  }}
  if($valid){$projected.changed_objects=@($objects);$safe.native_worker_preservation_failure=$projected}
 }
 $launcher=$Record.native_worker_launcher_failure
 if(($launcher -is [pscustomobject] -or $launcher -is [Collections.IDictionary]) -and $launcher.error_type -is [string] -and $launcher.error_type -cin 'RuntimeException','MethodInvocationException','ActionPreferenceStopException','ParameterBindingException','ItemNotFoundException','UnauthorizedAccessException','ArgumentException','FormatException','Win32Exception','Exception' -and ($launcher.source_line -is [int] -or $launcher.source_line -is [long]) -and $launcher.source_line -ge 1 -and $launcher.source_line -le 99999){$safe.native_worker_launcher_failure=@{error_type=$launcher.error_type;source_line=$launcher.source_line}}
 $preflight=$Record.native_worker_firewall_preflight
 if(($preflight -is [pscustomobject] -or $preflight -is [Collections.IDictionary]) -and $preflight.auth_fail_state -is [string] -and $preflight.auth_fail_state -cin 'absent','present','unknown' -and $preflight.auth_ip_state -is [string] -and $preflight.auth_ip_state -cin 'absent','present','unknown' -and $preflight.child_calls -is [array] -and $preflight.child_calls.Count -le 2){
  $calls=@();$valid=$true
  foreach($call in $preflight.child_calls){if(($call -isnot [pscustomobject] -and $call -isnot [Collections.IDictionary]) -or $call.response -isnot [string] -or $call.response -cnotin 'absent','present','unknown','unavailable','invalid' -or $call.deadline_reached -isnot [bool]){$valid=$false;break};$calls+=@{response=$call.response;deadline_reached=$call.deadline_reached}}
  if($valid){$safe.native_worker_firewall_preflight=@{auth_fail_state=$preflight.auth_fail_state;auth_ip_state=$preflight.auth_ip_state;child_calls=@($calls)}}
 }
 foreach($name in 'native_worker_failure','native_worker_cleanup_failure'){
  $r=$Record.$name
  if(($r -isnot [pscustomobject] -and $r -isnot [Collections.IDictionary]) -or $r.phase -isnot [string] -or $r.phase -cnotin 'preflight','bootstrap','firewall_preflight','factory_preflight','schema','fixture','esl_subscribe','esl_publish','esl_receive','native_add','ledger_intent','ledger_reconcile','role_refusal','authorised_recovery','acknowledgement','duplicate_refusal','cleanup','complete' -or $r.error_type -isnot [string] -or $r.error_type -cnotin 'RuntimeException','PDOException','Error','TypeError','ValueError','ErrorException','JsonException','Exception' -or $r.source_basename -isnot [string] -or $r.source_basename -cnotin 'windows_phone_health_worker.php','pbx_windows_event_guard.php','pbx_windows_health_stream.php','pbx_phone_health.php','pbx_phone_health_recovery.php','event_guard_windows.php','database.php','require.php','external_component' -or ($r.source_line -isnot [int] -and $r.source_line -isnot [long]) -or $r.source_line -lt 1 -or $r.source_line -gt 99999 -or $r.sqlstate -isnot [string] -or ($r.sqlstate -cne 'none' -and $r.sqlstate -cnotmatch '^[A-Z0-9]{5}$')){continue}
  $safe[$name]=@{};foreach($field in 'phase','error_type','source_basename','source_line','sqlstate'){$safe[$name][$field]=$r.$field}
 }
 return $safe
}
function PhoneHealthHook {
 $reportPath=Join-Path $work 'phone-health-native.json'
 try{
 & (Join-Path $PSScriptRoot 'windows_phone_health_acceptance.ps1') -PackageRoot $PackageRoot -ReportPath $reportPath -DisposableHostedRunner
 if(!(Test-Path -LiteralPath $reportPath)){throw 'The installed native phone health evidence is absent.'}
 $report=Get-Content -LiteralPath $reportPath -Raw|ConvertFrom-Json
 if($report.schema -ne 1 -or $report.producer -cne 'windows_phone_health_acceptance.ps1' -or $report.state -cne 'passed' -or $report.actual_native_windows -isnot [bool] -or !$report.actual_native_windows -or $report.policy_signalling_doubles -isnot [bool] -or !$report.policy_signalling_doubles -or $report.physical_phone_audio -isnot [bool] -or $report.physical_phone_audio){throw 'The Windows phone health scope or actual native evidence is invalid.'}
 foreach($name in 'installed_task','installed_system_observer','installed_continuous_observer','installed_restart','installed_collector','postgresql_policy','runtime','custom_subscription','firewall','native_worker','cleanup'){if($report.gates.$name -cne 'passed'){throw 'The installed native phone health gates must all pass.'}}
 foreach($limit in @(@('postgresql_checks',96),@('runtime_checks',49),@('subscription_checks',26),@('firewall_checks',18),@('firewall_empty_query_checks',4),@('native_worker_checks',13))){$v=$report.($limit[0]);if(($v -isnot [int] -and $v -isnot [long]) -or $v -lt $limit[1] -or $v -gt 100000){throw 'The native phone health check counts are invalid.'}}
 if($report.native_worker_firewall_policy_exact -isnot [bool] -or !$report.native_worker_firewall_policy_exact){throw 'The actual SYSTEM recovery worker did not preserve complete native firewall policy.'}
 $facts.gates.phone_health='passed';$facts.checks+=('Actual Windows installed SYSTEM phone health task/continuous observer/restart/collector, PostgreSQL '+$report.postgresql_checks+', runtime '+$report.runtime_checks+', Defender '+$report.firewall_checks+' and scoped cleanup; policy signalling uses doubles, physical audio unqualified')
 }catch{
  if(Test-Path -LiteralPath $reportPath){try{$r=Get-Content -LiteralPath $reportPath -Raw|ConvertFrom-Json;$safe=SafePhoneHealthFailure $r;if($safe.Count){$facts.phone_health_failure=$safe}}catch{}}
  throw
 }
}
function InvokeSuitePhoneHealthQualification([bool]$SkipHealth){
 if(!$SkipHealth){PhoneHealthAcceptanceHook ([DateTime]::UtcNow);return}
 if(!$factoryDiagnosticsSourceValidated -or !$NativeDiagnosticsOnly -or $ReplaySuiteRunId -or $facts.gates.fresh -cne 'passed' -or $facts.gates.web_readiness -cne 'passed' -or $facts.phone_health_failure -or (Test-Path -LiteralPath (Join-Path $work 'phone-health-native.json'))){throw 'Fresh native diagnostics cannot continue from a prior or failed phone health fixture.'}
 $facts.gates.phone_health='unqualified';$facts.native_factory_phone_health_skipped=$true;$facts.native_factory_fresh_package=$true
 $facts.release_eligible=$false;$facts.owner_transaction_eligible=$false
}
try{
 PrivateDirectory $work;PublishFacts
 if((Test-Path "$configuration\config.conf") -or (Test-Path "$state\installation.json") -or (Get-Service OpenWebPBX -ErrorAction SilentlyContinue)){throw 'The ephemeral machine already contains a PBX; it is not an empty suite target.'}
 CheckedPython @((Join-Path $source 'tests/windows_voice_installer.py'))
 & (Join-Path $source 'tests/windows_modern_baseline_gates.ps1') -SourceRoot $source *> (Join-Path $work 'modern-baseline-validator.private.log')
 if(!$?){throw 'Modern native baseline evidence controls failed.'}
 & (Join-Path $source 'tests/windows_public_listener_evidence.ps1') -SourceRoot $source *> (Join-Path $work 'public-listener-evidence.private.log')
 if(!$?){throw 'Actual public-listener qualification evidence controls failed.'}
 & (Join-Path $source 'tests/windows_native_services_controls.ps1') -SourceRoot $source *> (Join-Path $work 'native-services-validator.private.log')
 if(!$?){throw 'Extended native qualification evidence controls failed.'}
 & (Join-Path $source 'tests/windows_native_factory_diagnostics.ps1') -SourceRoot $source *> (Join-Path $work 'native-factory-guards.private.log')
 if(!$?){throw 'Explicit native factory diagnostic controls failed.'}
 CheckedPython @((Join-Path $source 'tests/windows_provider_diagnostics_test.py'))
 & (Join-Path $source 'tests/windows_native_cleanup_writers.ps1') -SourceRoot $source *> (Join-Path $work 'native-cleanup-writer-controls.private.log')
 if(!$?){throw 'The exact native cleanup writer lifecycle controls failed.'}
 & (Join-Path $source 'tests/windows_native_cleanup_drain_fields.ps1') -SourceRoot $source *> (Join-Path $work 'native-cleanup-drain-fields.private.log')
 if(!$?){throw 'The closed native cleanup drain failure controls failed.'}
 & (Join-Path $source 'tests/windows_threecx_import_fields.ps1') -SourceRoot $source *> (Join-Path $work 'threecx-import-report-controls.private.log')
 if(!$?){throw 'Typed synthetic V20 import evidence controls failed.'}
 & (Join-Path $source 'tests/windows_threecx_import_controls.ps1') -SourceRoot $source *> (Join-Path $work 'threecx-import-wrapper-controls.private.log')
 if(!$?){throw 'The actual installed V20 import wrapper refusal controls failed.'}
 CheckedPython @((Join-Path $source 'tests/windows_hold_diagnostics_test.py'))
 & {param([switch]$ThreecxImportOnly); & (Join-Path $source 'tests/windows_hold_diagnostics_controls.ps1') -SourceRoot $source *> (Join-Path $work 'hold-diagnostic-controls.private.log')}
 if(!$?){throw 'The focused hold diagnostic scope and evidence controls failed.'}
 if($ThreecxImportOnly){
  & (Join-Path $source 'tests/windows-threecx-suite-controls.ps1') -SourceRoot $source *> (Join-Path $work 'threecx-suite-controls.private.log')
  if(!$?){throw 'The isolated import diagnostic admission and routing controls failed.'}
  & (Join-Path $source 'tests/windows-threecx-https-controls.ps1') *> (Join-Path $work 'threecx-https-controls.private.log')
  if(!$?){throw 'The exact import diagnostic receipt controls failed.'}
  CheckedPython @((Join-Path $source 'tests/windows_threecx_https_controls.py'))
 }

 CheckedPython @((Join-Path $source 'tests/windows_cmb_media_window.py'))
 CheckedPython @((Join-Path $source 'tests/windows_cdr_background_test.py'))
 CheckedPython @((Join-Path $source 'tests/windows_meet_browser_failure.py'))
 CheckedPython @((Join-Path $source 'tests/windows_smtp_notice.py'),'SMTPNoticeControls.test_actual_dom_success_and_refusals')
 CheckedPython @((Join-Path $source 'tests/windows_smtp_notice_controls.py'))
 & (Join-Path $source 'tests/windows_meet_media_projection.ps1') -SourceRoot $source *> (Join-Path $work 'meeting-media-projection.private.log')
 if(!$?){throw 'The closed meeting media/browser failure controls failed.'}
 & (Join-Path $source 'tests/windows_cdr_native_fields.ps1') *> (Join-Path $work 'cdr-native-fields.private.log')
 if(!$?){throw 'The strict native background CDR evidence controls failed.'}
 & (Join-Path $source 'tests/windows_cdr_success_projection.ps1') -SourceRoot $source *> (Join-Path $work 'cdr-success-projection.private.log')
 if(!$?){throw 'The strict public native background CDR receipt controls failed.'}
 & (Join-Path $source 'tests/windows_recovery_localaccounts.ps1') -SourceRoot $source *> (Join-Path $work 'recovery-localaccounts.private.log')
 if(!$?){throw 'The native PowerShell recovery module provenance controls failed.'}
 CheckedPython @((Join-Path $source 'tests/windows_upgrade_restore_holds.py'))
 CheckedPython @((Join-Path $source 'tests/windows_restore_lock_retry.py'))
 CheckedPython @((Join-Path $source 'tests/windows_backup_control_observer_test.py'))
 & (Join-Path $source 'tests/windows_welcome_quiescence.ps1') -SourceRoot $source *> (Join-Path $work 'welcome-quiescence-controls.private.log')
 if(!$?){throw 'The exact welcome updater quiescence controls failed.'}
 & (Join-Path $source 'tests/windows_welcome_inventory_controls.ps1') *> (Join-Path $work 'welcome-inventory-controls.private.log')
 if(!$?){throw 'The closed welcome inventory observation controls failed.'}
 CheckedPython @((Join-Path $source 'tests/windows_voicemail_delete_test.py'))
 & (Join-Path $source 'tests/windows_voicemail_delete_controls.ps1') *> (Join-Path $work 'voicemail-delete-controls.private.log')
 if(!$?){throw 'The required Windows voicemail delete receipt controls failed.'}
 & (Join-Path $source 'tests/windows_call_records_lifecycle.ps1') -SourceRoot $source *> (Join-Path $work 'call-records-lifecycle.private.log')
 & (Join-Path $source 'tests/windows_recovery_restore_holds.ps1') -SourceRoot $source *> (Join-Path $work 'restore-recovery-holds.private.log')
 if(!$?){throw 'The actual Windows call-record activation and recovery lifecycle controls failed.'}
 & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $source 'tests/windows_cdr_service_test.ps1') *> (Join-Path $work 'cdr-service-identity.private.log')
 if($LASTEXITCODE){throw 'The actual LocalService observer refusal controls failed.'}
 & (Join-Path $source 'tests/windows_provider_failure_fields.ps1') -SourceRoot $source *> (Join-Path $work 'provider-projection.private.log')
 if(!$?){throw 'Native provider failure projection controls failed.'}
 & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $source 'tests/windows_phone_tls_failure_fields.ps1') -SourceRoot $source *> (Join-Path $work 'phone-tls-projection.private.log')
 if($LASTEXITCODE){throw 'The actual phone TLS failure launcher controls failed.'}
 & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $source 'tests/windows_phone_tls_lock.ps1') -SourceRoot $source *> (Join-Path $work 'phone-tls-lock.private.log')
 if($LASTEXITCODE){throw 'The actual native phone TLS maintenance controls failed.'}
 & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $source 'tests/windows_stun_lock_fields.ps1') -SourceRoot $source *> (Join-Path $work 'stun-lock-fields.private.log')
 if($LASTEXITCODE){throw 'The closed STUN maintenance evidence controls failed.'}
 & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $source 'tests/windows_legacy_transition.ps1') *> (Join-Path $work 'legacy-source.private.log')
 if($LASTEXITCODE){throw 'The exact legacy upgrade boundary controls failed.'}
 & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $source 'tests/windows_upgrade_health_quiescence.ps1') *> (Join-Path $work 'health-quiescence.private.log')
 if($LASTEXITCODE){throw 'The exact health upgrade quiescence controls failed.'}
 & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $source 'tests/windows_stun_setup_transaction.ps1') -SourceRoot $source -OutputDirectory (Join-Path $work 'stun-transaction-controls') *> (Join-Path $work 'stun-transactions.private.log')
 if($LASTEXITCODE){throw 'The native Windows STUN transaction boundary controls failed.'}
 if($ReplaySuiteRunId){$PackageRoot=PrepareReplayCandidate}elseif(!$PackageRoot){$PackageRoot=PreparePackage}
 Remove-Item Env:\GH_TOKEN -ErrorAction SilentlyContinue
 $PackageRoot=[IO.Path]::GetFullPath($PackageRoot);$release=Get-Content (Join-Path $PackageRoot 'release-manifest.json') -Raw|ConvertFrom-Json
 if($release.version -ne (Get-Content (Join-Path $source 'VERSION') -Raw).Trim()){throw 'The candidate package release differs from source.'}
 $mapped=VerifyInventory $PackageRoot $release.files;$facts.checks+=('Exact candidate package inventory: '+$mapped+' files')
 if($ThreecxImportOnly){AssertThreecxImportAcceptedReplay $facts}else{$phase='original candidate export';ExportOriginalCandidate $release}
 $phase='native public-listener firewall qualification';PublicListenerQualificationHook 'native_defender'
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
 foreach($field in 'meeting_failure','meeting_recovery_failure'){if($_.Exception.Data.Contains($field)){$safe[$field]=$_.Exception.Data[$field]}}
 [IO.File]::WriteAllText($record.error_path,($safe|ConvertTo-Json),[Text.UTF8Encoding]::new($false));exit 1
}
'@
 [IO.File]::WriteAllText($launcher,$launchCode,[Text.UTF8Encoding]::new($false))
 $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe';$start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $start.Environment['PSModulePath']=(Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/Modules')+';'+(Join-Path $env:ProgramFiles 'WindowsPowerShell/Modules')
 foreach($arg in '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$launcher,'-InputPath',$installInput){$start.ArgumentList.Add($arg)}
 $startupStartTime=[DateTime]::UtcNow
 $process=[Diagnostics.Process]::Start($start);$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
 if(!$process.WaitForExit(2400000)){throw 'The real installation is still running; its private state must not be interrupted.'}
 [IO.File]::WriteAllText((Join-Path $work 'install-private.out'),$stdout.GetAwaiter().GetResult());[IO.File]::WriteAllText((Join-Path $work 'install-private.err'),$stderr.GetAwaiter().GetResult());$exit=$process.ExitCode;$process.Dispose();Remove-Item -LiteralPath $installInput -Force
 if($exit){
  if(Test-Path (Join-Path $work 'install-failure.json')){$facts.helper_failure=SafeFailureFields (Get-Content (Join-Path $work 'install-failure.json') -Raw|ConvertFrom-Json)}
  try{$facts.native_startup_failure=NativeStartupFailure -StartedAt $startupStartTime -PrivateDirectory $work}catch{$facts.native_startup_failure=@{schema=1;observer_failed=$true}}
  throw 'The real candidate installation failed.'
 }
 $completed=Get-Content "$state\installation.json" -Raw|ConvertFrom-Json
 if(!$completed.Completed -or !$completed.RestoreServer -or $completed.AdminEmail -ne $admin){throw 'The candidate factory identity or completed state is invalid.'}
 foreach($service in 'OpenWebPBX-Database','OpenWebPBX','OpenWebPBXUpdater','FreeSWITCH'){if((Get-Service $service).Status -ne 'Running'){throw 'A candidate native service is not running.'}}
 & (Join-Path $PackageRoot 'Install-NativeEngine.ps1') -PackageRoot $PackageRoot -Check
 if(!$?){throw 'The installed native call-engine inventory differs.'}
 $facts.gates.fresh='passed';$facts.checks+=('Real restore-ready fresh installation/services/native engine hash preservation')
 $phase='native PHP runtime qualification';PhpRuntimeQualificationHook
 $phase='installed PHP SMTP notice source controls';CheckedPython @((Join-Path $source 'tests/windows_smtp_notice.py'),'--php-executable','C:\OpenWebPBX\php\php.exe','SMTPNoticeControls.test_actual_php_post_notice_and_refusals')
 $phase='installed PHP welcome path source controls';CheckedPython @((Join-Path $source 'tests/windows_welcome_paths.py'),'--php-executable','C:\OpenWebPBX\php\php.exe')
 $phase='native upgrade recovery qualification';UpgradeRecoveryQualificationHook
 $phase='native web readiness qualification';WebReadinessHook
 $phase='installed public-listener qualification';PublicListenerQualificationHook 'installed_collector'
 $phase='native synthetic V20 import qualification';ThreecxImportQualificationHook
 $phase='native DTLS qualification';DtlsQualificationHook
 if(!$UpgradeDiagnosticsOnly -and !$BackupsDiagnosticsOnly){$phase='native STUN qualification';StunHook;$phase='native phone health qualification';if($ThreecxImportOnly){InvokeThreecxImportEmptyFactory $facts $threecxImportModeValidated $NativeDiagnosticsOnly $SkipPhoneHealthForNativeDiagnostics $HoldDiagnosticsOnly $work}else{InvokeSuitePhoneHealthQualification $SkipPhoneHealthForNativeDiagnostics}}
 $phase='native tenant-domain qualification';TenantDomainsAcceptanceHook ([DateTime]::UtcNow)
 $phase='meeting transport qualification';MeetingTransportHook
 $acceptanceFile=Join-Path $work 'acceptance-input.json';$ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($password)
 try{$plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)}
 $acceptance=@{schema=1;run_id=$env:GITHUB_RUN_ID;restore_server=$true;admin_email=$admin;admin_password=$plain;public_url=('https://'+$domain+':8443');package_root=$PackageRoot;source_root=$source;private_state_root=$state;python='C:/OpenWebPBX/backup-runtime/python.exe';evidence_directory=(Join-Path $work 'native-private-evidence');native_diagnostics_only=[bool]$NativeDiagnosticsOnly;hold_diagnostics_only=[bool]$HoldDiagnosticsOnly}
 if($ThreecxImportOnly){$acceptance.threecx_import_only=[bool]$ThreecxImportOnly}
 [IO.File]::WriteAllText($acceptanceFile,($acceptance|ConvertTo-Json),[Text.UTF8Encoding]::new($false));$plain=$null;$acceptance=$null
 # BEGIN qualification-gate-routing
 if(!$UpgradeDiagnosticsOnly -and !$BackupsDiagnosticsOnly){
  $phase='native acceptance hook';$nativeStartTime=[DateTime]::UtcNow;$native=NativeAcceptanceHook (Join-Path $work 'native-acceptance.json') $nativeStartTime
  if($native){
   if($SkipPhoneHealthForNativeDiagnostics){if($native.native_factory_empty_before_fixture -isnot [bool] -or !$native.native_factory_empty_before_fixture){throw 'The native calling fixture did not prove its empty factory baseline.'};$facts.native_factory_empty_before_fixture=$true}
   if($ThreecxImportOnly){
    $facts.threecx_import_diagnostic=ReadSuiteThreecxImportDiagnostic $native;$facts.gates.threecx_import_diagnostic='passed'
   }elseif($HoldDiagnosticsOnly){
    if($native.native_factory_empty_before_fixture -isnot [bool] -or !$native.native_factory_empty_before_fixture -or $native.diagnostic_case -isnot [string] -or $native.diagnostic_case -cne 'hold' -or $native.gates.hold_diagnostic -cne 'passed'){throw 'Hold diagnostics require their actual empty factory and completed native cases.'}
    foreach($flag in 'full_release_eligible','owner_eligible','public_eligible','restore_eligible','signed_upgrade_eligible'){if($native.$flag -isnot [bool] -or $native.$flag){throw 'A focused diagnostic cannot qualify full release, owner, public, restore or signed upgrade.'}}
    $facts.hold_diagnostic='passed';$facts.native_factory_empty_before_fixture=$true
   }else{
   if($native.gates.meeting_browser -cne 'passed'){throw 'The actual Windows meeting browser media gate is required.'}
   foreach($gate in 'native_clock','native_providers','native_call_me_back'){if($native.gates.$gate -cne 'passed'){throw 'The actual native clock, local providers and Call Me Back gates are required.'};$facts.gates.$gate='passed'}
   if(!$NativeDiagnosticsOnly -and !$UpgradeDiagnosticsOnly -and !$BackupsDiagnosticsOnly -and !$ReplaySuiteRunId -and !$SkipPhoneHealthForNativeDiagnostics -and !$HoldDiagnosticsOnly){
    $facts.native_cdr_background_import=ReadSuiteCdrBackgroundImport $native.checks
   }
   $facts.gates.native_sip_audio='passed';$facts.gates.meeting_browser='passed'
   }
  }
 }
 if(!$NativeDiagnosticsOnly){
 $phase='independent trusted recovery fixture';$recoveryPki=Start-SuiteRecoveryPki -PackageRoot $PackageRoot -SourceRoot $source -Work $work
 if(!$BackupsDiagnosticsOnly){
  $phase='upgrade acceptance hook';$upgrade=AcceptanceHook 'windows-upgrade-acceptance.ps1' (Join-Path $work 'upgrade-acceptance.json')
  if($upgrade){foreach($gate in 'direct_113_helper_reapply','direct_failure_rollback','restore_gate_startup','manager_reopen_success','manager_reopen_rollback','installed_upgrade','failure_rollback','legacy_106_upgrade'){if($upgrade.gates.$gate -eq 'passed'){$facts.gates[$gate]='passed'}}}
 }
 if(!$UpgradeDiagnosticsOnly){
  $phase='backup qualification';$sftpConfig=LoopbackSftp
  $backupStartedAt=[DateTime]::UtcNow
  try{
   & (Join-Path $PSScriptRoot 'windows-backups.ps1') -PackageRoot $PackageRoot -AdminEmail $admin -AdminPassword $password -DisposableFactory -SftpConfig $sftpConfig
   if(!$?){throw 'Actual Windows encrypted-backup qualification failed.'}
  }catch{try{$facts.backup_failure=BackupFailureReport (Join-Path $state 'backup-qualification/report.json') $backupStartedAt}catch{};throw}
  $backup=Get-Content "$state\backup-qualification\report.json" -Raw|ConvertFrom-Json
  if($backup.state -ne 'passed' -or !$backup.fully_qualified){throw 'Actual backup/SFTP qualification is incomplete.'}
  $facts.gates.backups='passed';$facts.checks+=@($backup.checks)
 }
 }
 $missing=@($facts.gates.GetEnumerator()|Where-Object {$_.Value -ne 'passed'}|ForEach-Object Key)
 $facts.state=if($facts.state -eq 'failed'){'failed'}elseif($UpgradeDiagnosticsOnly -or $BackupsDiagnosticsOnly){'partial'}elseif($NativeDiagnosticsOnly){'partial'}elseif($missing.Count){'partial'}else{'passed'};$facts.unqualified=$missing
 # END qualification-gate-routing
}catch{
 RememberSuiteFailure $_ $phase
 if($phase -eq 'native acceptance hook' -and $nativeStartTime -and !$facts.native_runtime_failure){
  try{$facts.native_runtime_failure=NativeStartupFailure -StartedAt $nativeStartTime -PrivateDirectory $work}catch{$facts.native_runtime_failure=@{schema=1;observer_failed=$true}}
 }
 Write-Error ('Disposable Windows suite failed in '+$phase+'. No passing result is implied.') -ErrorAction Continue
}finally{
 Remove-Item Env:\GH_TOKEN -ErrorAction SilentlyContinue
 $cleanup=$true
 $cleanupLock=$null
 try{
  if($installed){
   $cleanupLock=Acquire-SuiteCleanupLock $state $work
   # Retain this exclusive guard through teardown. Releasing after the probe
   # lets an owned background task begin a transaction before shutdown.
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
   & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command '$env:PSModulePath=($PSHOME+"\Modules")+";"+($env:ProgramFiles+"\WindowsPowerShell\Modules");$ErrorActionPreference="Stop";if(Test-Path ($PSHOME+"\Modules\WebAdministration\WebAdministration.psd1")){Import-Module WebAdministration;if(Test-Path IIS:\Sites\OpenWebPBX){Stop-Website OpenWebPBX};if(Test-Path IIS:\AppPools\OpenWebPBX){$poolState=(Get-WebAppPoolState OpenWebPBX).Value;if($poolState -eq "Started"){Stop-WebAppPool OpenWebPBX}elseif($poolState -notin "Stopped","Stopping"){throw "Owned pool cleanup found an unexpected state."};for($poll=0;$poll -lt 160;$poll++){$poolState=(Get-WebAppPoolState OpenWebPBX).Value;if($poolState -eq "Stopped"){break};if($poolState -notin "Started","Stopping"){throw "Owned pool cleanup found an unexpected state."};Start-Sleep -Milliseconds 250};if((Get-WebAppPoolState OpenWebPBX).Value -ne "Stopped"){throw "Owned pool cleanup did not stop."}}}' *> $null
   if($LASTEXITCODE){throw 'Owned IIS cleanup did not finish.'}
   if(Get-Service OpenWebPBX-Database -ErrorAction SilentlyContinue){Stop-Service OpenWebPBX-Database -Force}
  }
  Stop-SuiteRecoveryPki $recoveryPki;$recoveryPki=$null
  if($sftp){
   if(Get-ScheduledTask -TaskName $sftp.task -ErrorAction SilentlyContinue){Stop-ScheduledTask -TaskName $sftp.task;Unregister-ScheduledTask -TaskName $sftp.task -Confirm:$false}
   foreach($process in @(Get-CimInstance Win32_Process -Filter "Name='sshd.exe'")){if($process.CommandLine -and $process.CommandLine.Contains($sftp.config)){Stop-Process -Id $process.ProcessId -Force}}
   Remove-LocalUser -Name $sftp.name -ErrorAction SilentlyContinue;Remove-Item -LiteralPath $sftp.directory -Recurse -Force -ErrorAction SilentlyContinue
  }
  if($hostAdded){$text=[IO.File]::ReadAllText($hosts);$text=[regex]::Replace($text,'(?m)^127\.0\.0\.1 windowsqa\.example\.invalid '+[regex]::Escape($marker)+'\r?\n','');[IO.File]::WriteAllText($hosts,$text,[Text.UTF8Encoding]::new($false))}
 }catch{
  $cleanup=$false
  $facts.cleanup_failure=SafeFailureFields ([pscustomobject]@{error_type=$_.Exception.GetType().FullName;source_basename=(Split-Path -Leaf $_.InvocationInfo.ScriptName);source_line=[int]$_.InvocationInfo.ScriptLineNumber})
 }finally{if($cleanupLock){$cleanupLock.Dispose()}}
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
