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
 [switch]$DisposableHostedRunner,
 [switch]$RestoredConferenceSupplement
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
$phase='verified qualified package';$installed=$false;$pki=$null;$inputFile=$null;$hostsBefore=$null;$hostsExpected=$null;$settings=$null;$python=$null;$PackageRoot=$null;$qualificationHealthOriginal=$null;$winps=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$facts=[ordered]@{schema=1;role=$Role.ToLowerInvariant();run_id=$env:GITHUB_RUN_ID;source_commit=$env:GITHUB_SHA;state='running';gates=@{};actual_os_boot='unqualified';carrier='unqualified';owner_upgrade='unqualified';cleanup='pending'}
# Import only the reviewed artifact/process and bounded IIS cleanup functions.
# Do not dot-source the executable updater stage or its environment guards.
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'windows-updater-qualification.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The independently reviewed artifact helper no longer parses.'}
foreach($name in 'Check','Hash','WriteJson','PrivateDirectory','SafeRelative','ExpandSafe','Api','Artifact','CheckedProcess','NativeVersions','StopQualificationIis'){
 $nodes=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true));if($nodes.Count -ne 1){throw 'One exact qualification helper is required.'};Invoke-Expression $nodes[0].Extent.Text
}
. (Join-Path $PSScriptRoot 'windows-suite-pki.ps1')
. (Join-Path $PSScriptRoot 'windows-upgrade-health-quiescence.ps1')
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
function SafeRestorePhpFailure($Record){
 if($null -eq $Record -or $Record -is [array]){return $null}
 $keys=@('schema','action','returncode','error_type','source_basename','source_line')
 if($Record -is [Collections.IDictionary]){$actual=@($Record.Keys)}else{$actual=@($Record.PSObject.Properties.Name)}
 if($actual.Count -ne $keys.Count -or @($actual|Where-Object {$_ -cnotin $keys}).Count){return $null}
 if(($Record.schema -isnot [int] -and $Record.schema -isnot [long]) -or $Record.schema -ne 1 -or $Record.action -isnot [string] -or $Record.action -cnotin @('baseline','discover','status','snapshot','seed-job','seed-health','job-status','cleanup')){return $null}
 if(($Record.returncode -isnot [int] -and $Record.returncode -isnot [long]) -or $Record.returncode -eq 0 -or $Record.returncode -lt -2147483648L -or $Record.returncode -gt 4294967295L -or ($Record.source_line -isnot [int] -and $Record.source_line -isnot [long]) -or $Record.error_type -isnot [string] -or $Record.source_basename -isnot [string]){return $null}
 if($Record.error_type -ceq 'unavailable'){if($Record.source_basename -cne 'unavailable' -or $Record.source_line -ne 0){return $null}}
 elseif($Record.error_type -cnotin @('RuntimeException','PDOException','JsonException','TypeError','ValueError','Error','Exception','external_error') -or $Record.source_basename -cnotin @('windows-restore-qualification.php','database.php','pbx_paths.php','pbx_meet_install.php','cache.php','event_socket.php','config.php','external_component') -or $Record.source_line -le 0 -or $Record.source_line -ge 1000000){return $null}
 return @{schema=1;action=$Record.action;returncode=$Record.returncode;error_type=$Record.error_type;source_basename=$Record.source_basename;source_line=$Record.source_line}
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
function SafeRestoredClockSummary($Record){
 if($null -eq $Record -or ($Record -isnot [pscustomobject] -and $Record -isnot [Collections.IDictionary])){return $null}
 $safe=[ordered]@{}
 foreach($field in 'sourcebindings_verified','GMT_plus_2_full_time_verified','original_phone_media_restored','owned_clock_call_ended','scoped_observer_stopped','software_phone_only','no_carrier_calls_or_database_configuration_writes'){
  if($Record.$field -isnot [bool] -or !$Record.$field){return $null};$safe[$field]=$true
 }
 foreach($pair in @(@('frozen_Nathaniel_assets',34),@('complete_announcements',3))){$value=$Record.($pair[0]);if(($value -isnot [int] -and $value -isnot [long]) -or $value -ne $pair[1]){return $null};$safe[$pair[0]]=$value}
 foreach($pair in @(@('minimum_component_correlation',.62,1.0),@('maximum_native_signal_lateness_ms',0,250.0),@('maximum_decoded_beep_target_error_ms',0,350.0))){
  $name=$pair[0];$value=$Record.$name
  if(($value -isnot [int] -and $value -isnot [long] -and $value -isnot [double]) -or [double]::IsNaN([double]$value) -or [double]::IsInfinity([double]$value) -or $value -lt $pair[1] -or $value -gt $pair[2] -or ($name -cne 'minimum_component_correlation' -and $value -eq $pair[2])){return $null}
  $safe[$name]=$value
 }
 return $safe
}
function SafeRestoreTableFailure($Record,[string]$Action){
 if($Record.error_type -isnot [string] -or $Record.error_type -cne 'ValueError' -or $Record.source_basename -isnot [string] -or $Record.source_basename -cne 'windows-restore-qualification.py'){return $null}
 $value=$Record.table_comparison
 if($null -eq $value -or $value -is [Array]){return $null}
 $fields=@('schema','mode','label','before_tables','after_tables','changed_tables','known_tables','other_tables','row_count_changed','digest_changed','missing_before','missing_after')
 $keys=if($value -is [Collections.IDictionary]){@($value.Keys)}else{@($value.PSObject.Properties.Name)}
 if($keys.Count -ne $fields.Count -or @($keys|Where-Object {$_ -cnotin $fields}).Count){return $null}
 if(($value.schema -isnot [int] -and $value.schema -isnot [long]) -or $value.schema -ne 1 -or $value.mode -isnot [string] -or $value.label -isnot [string]){return $null}
 if($Action -ceq 'restore'){if($value.mode -cne 'source-restored' -or $value.label -cne 'target-restored'){return $null}}
 elseif($Action -ceq 'late-restore'){if($value.mode -cne 'factory-recovery' -or $value.label -cnotin @('target-wrongpass','target-recovered')){return $null}}
 else{return $null}
 $counts=@('before_tables','after_tables','changed_tables','other_tables','row_count_changed','digest_changed','missing_before','missing_after')
 foreach($name in $counts){$n=$value.$name;if(($n -isnot [int] -and $n -isnot [long]) -or $n -lt 0 -or $n -gt 4096){return $null}}
 $known=@('v_default_settings','v_dialplan_details','v_dialplans','v_domain_settings','v_domains','v_email_queue','v_event_guard','v_event_guard_logs','v_extensions','v_gateways','v_group_permissions','v_groups','v_menu','v_menu_items','v_pbx_android_devices','v_pbx_call_history','v_pbx_jobs','v_pbx_mail_queue','v_pbx_meeting_invitations','v_pbx_meeting_members','v_pbx_meetings','v_pbx_phone_health_alerts','v_pbx_phone_health_contacts','v_pbx_phone_health_issues','v_pbx_phone_health_recoveries','v_pbx_phone_health_settings','v_pbx_phone_health_state','v_pbx_restore','v_pbx_service_assignments','v_pbx_services','v_pbx_setup_templates','v_pbx_sip_domains','v_pbx_templates','v_pbx_tenant_users','v_pbx_tenants','v_pbx_windows_devices','v_permissions','v_sip_profile_settings','v_sip_profiles','v_user_contacts','v_user_emails','v_user_groups','v_user_settings','v_users','v_vars','v_voicemail_messages','v_voicemails','v_xml_cdr')
 if($value.known_tables -isnot [Array] -or $value.known_tables.Count -gt $known.Count){return $null}
 $seen=@();foreach($name in $value.known_tables){if($name -isnot [string] -or $name -cnotin $known -or $name -cin $seen){return $null};$seen+=,$name}
 $ordered=@($seen|Sort-Object -CaseSensitive);if([string]::Join(',', $seen) -cne [string]::Join(',', $ordered)){return $null}
 if($value.changed_tables -lt 1 -or $value.changed_tables -gt ($value.before_tables+$value.after_tables) -or ($seen.Count+$value.other_tables) -ne $value.changed_tables -or $value.missing_before -gt $value.after_tables -or $value.missing_after -gt $value.before_tables -or ($value.missing_before+$value.missing_after) -gt $value.changed_tables){return $null}
 foreach($name in 'row_count_changed','digest_changed'){if($value.$name -gt ($value.changed_tables-$value.missing_before-$value.missing_after)){return $null}}
 $safe=@{schema=1;mode=$value.mode;label=$value.label;known_tables=@($seen)};foreach($name in $counts){$safe[$name]=[int]$value.$name};return $safe
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
 if($Record.error_type -isnot [string] -or $Record.error_type -cnotin @('BackupError','BackupBusy','PermissionError','FileNotFoundError','OSError','ValueError','TypeError','RuntimeError','JSONDecodeError','other','unavailable') -or $Record.category -isnot [string] -or $Record.category -cnotin @('operation_busy','operation_lock_review','activation_server_guard','activation_selection_guard','activation_service_missing','required_tool_failed','required_tool_unavailable','private_control_unavailable','unclassified') -or $Record.source_frames -isnot [Array] -or $Record.source_frames.Count -gt 4){return $null}
 $frames=@();foreach($frame in $Record.source_frames){
  if($null -eq $frame -or $frame -is [Array]){return $null};$fields=@();if($frame -is [Collections.IDictionary]){$fields=@($frame.Keys)}else{$fields=@($frame.PSObject.Properties.Name)}
  if($fields.Count -ne 3 -or @($fields|Where-Object {$_ -cnotin @('source_basename','source_line','function')}).Count -or $frame.source_basename -isnot [string] -or $frame.source_basename -cne 'backups.py' -or $frame.function -isnot [string] -or $frame.function -cnotin @('main','activate','exclusive_guard','windows_exclusive_guard','control','run','read_settings','ordinary','reparse','atomic_json','held','lock_file','unlock_file') -or ($frame.source_line -isnot [int] -and $frame.source_line -isnot [long]) -or $frame.source_line -le 0 -or $frame.source_line -ge 1000000){return $null}
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
function SafeRestoredConferenceWssChildFields($Record){
 if($Record -isnot [Array] -or $Record.Count -lt 1 -or $Record.Count -gt 2){return $null}
 $safe=@();$labels=@();$psTypes=@('RuntimeException','PSInvalidOperationException','InvalidOperationException','CmdletInvocationException','CommandNotFoundException','FileNotFoundException','IOException','UnauthorizedAccessException','TypeLoadException','CryptographicException','WebSocketException','AuthenticationException','TimeoutException','ManagementException','Exception','external_error')
 foreach($value in $Record){
  if($null -eq $value -or ($value -isnot [Collections.IDictionary] -and $value -isnot [pscustomobject])){return $null}
  $keys=if($value -is [Collections.IDictionary]){@($value.Keys)}else{@($value.PSObject.Properties.Name)}
  if($keys.Count -ne 4 -or @($keys|Where-Object {$_ -cnotin @('schema','label','reason','outcome')}).Count -or ($value.schema -isnot [int] -and $value.schema -isnot [long]) -or $value.schema -ne 1 -or $value.label -isnot [string] -or $value.label -cnotin @('before','after') -or $value.label -cin $labels -or $value.reason -isnot [string] -or $value.reason -cnotin @('report_missing','report_invalid')){return $null}
  $child=$value.outcome
  if($null -eq $child -or ($child -isnot [Collections.IDictionary] -and $child -isnot [pscustomobject])){return $null}
  $keys=if($child -is [Collections.IDictionary]){@($child.Keys)}else{@($child.PSObject.Properties.Name)}
  if($keys.Count -ne 9 -or @($keys|Where-Object {$_ -cnotin @('exit_code','error_type','code_kind','errno','killed','signal','elapsed_ms','powershell_state','powershell')}).Count){return $null}
  foreach($item in @(@('exit_code',-2147483648,4294967295),@('errno',-2147483648,2147483647))){$n=$item[0];if($null -ne $child.$n -and (($child.$n -isnot [int] -and $child.$n -isnot [long]) -or $child.$n -lt $item[1] -or $child.$n -gt $item[2])){return $null}}
  if(($null -ne $child.killed -and $child.killed -isnot [bool]) -or ($child.elapsed_ms -isnot [int] -and $child.elapsed_ms -isnot [long]) -or $child.elapsed_ms -lt 0 -or $child.elapsed_ms -gt 32000 -or $child.error_type -isnot [string] -or $child.error_type -cnotin @('none','Error','TypeError','RangeError','TimeoutError','AbortError','other') -or $child.code_kind -isnot [string] -or $child.code_kind -cnotin @('none','exit','ENOENT','EACCES','EPERM','ETIMEDOUT','ABORT_ERR','ERR_CHILD_PROCESS_STDIO_MAXBUFFER','other') -or $child.signal -isnot [string] -or $child.signal -cnotin @('none','SIGTERM','SIGKILL','other') -or $child.powershell_state -isnot [string] -or $child.powershell_state -cnotin @('absent','invalid','closed')){return $null}
  $ps=$child.powershell;$closed=$null
  if($child.powershell_state -ceq 'closed'){
   if($null -eq $ps -or ($ps -isnot [Collections.IDictionary] -and $ps -isnot [pscustomobject])){return $null}
   $keys=if($ps -is [Collections.IDictionary]){@($ps.Keys)}else{@($ps.PSObject.Properties.Name)}
   if($keys.Count -ne 7 -or @($keys|Where-Object {$_ -cnotin @('schema','state','producer','error_type','source_basename','source_line','hresult')}).Count -or ($ps.schema -isnot [int] -and $ps.schema -isnot [long]) -or $ps.schema -ne 1 -or $ps.state -isnot [string] -or $ps.state -cne 'failed' -or $ps.producer -isnot [string] -or $ps.producer -cne 'windows-meet-wss-path.ps1' -or $ps.error_type -isnot [string] -or $ps.error_type -cnotin $psTypes -or $ps.source_basename -isnot [string] -or $ps.source_basename -cnotin @('windows-meet-wss-path.ps1','unavailable') -or ($ps.source_line -isnot [int] -and $ps.source_line -isnot [long]) -or $ps.source_line -lt 0 -or $ps.source_line -ge 1000000 -or ($ps.hresult -isnot [int] -and $ps.hresult -isnot [long]) -or $ps.hresult -lt -2147483648 -or $ps.hresult -gt 2147483647){return $null}
   if(($ps.source_basename -ceq 'unavailable' -and $ps.source_line -ne 0) -or ($ps.source_basename -cne 'unavailable' -and $ps.source_line -lt 1)){return $null}
   $closed=@{schema=1;state='failed';producer='windows-meet-wss-path.ps1';error_type=$ps.error_type;source_basename=$ps.source_basename;source_line=$ps.source_line;hresult=$ps.hresult}
  }elseif($null -ne $ps){return $null}
  $labels+=@($value.label)
  $safe+=@(@{schema=1;label=$value.label;reason=$value.reason;outcome=@{exit_code=$child.exit_code;error_type=$child.error_type;code_kind=$child.code_kind;errno=$child.errno;killed=$child.killed;signal=$child.signal;elapsed_ms=$child.elapsed_ms;powershell_state=$child.powershell_state;powershell=$closed}})
 }
 return @{meeting_wss_child_failure=$safe}
}

function SafeRestoredConferenceFailure($Record){
 if($null -eq $Record -or ($Record -isnot [Collections.IDictionary] -and $Record -isnot [pscustomobject])){return $null}
 $keys=@('schema','state','producer','error_type','cleanup_verified','source_frames','active_case','owned_process_cleanup_failed','owned_processes_closed')
 $actual=if($Record -is [Collections.IDictionary]){@($Record.Keys)}else{@($Record.PSObject.Properties.Name)}
 if($actual.Count -notin 9,10,11 -or @($actual|Where-Object {$_ -cnotin ($keys+@('meeting_path','meeting_wss_child_failure'))}).Count -or @($keys|Where-Object {$_ -cnotin $actual}).Count){return $null}
 if(($Record.schema -isnot [int] -and $Record.schema -isnot [long]) -or $Record.schema -ne 1 -or $Record.state -isnot [string] -or $Record.state -cne 'failed' -or $Record.producer -isnot [string] -or $Record.producer -cne 'windows_restored_meeting.py' -or $Record.cleanup_verified -isnot [bool]){return $null}
 $types=@('RuntimeError','ValueError','TypeError','KeyError','AttributeError','AssertionError','TimeoutError','TimeoutExpired','OSError','FileNotFoundError','PermissionError','JSONDecodeError','SSLError','HTTPError','URLError','external_error')
 $cases=@('unavailable','native_windows_meeting_browser_media','native_windows_meeting_dependencies','native_windows_meeting_unknown','native_windows_meeting_browser_start','native_windows_meeting_owner_page','native_windows_meeting_create','native_windows_meeting_host_join','native_windows_meeting_guest_join','native_windows_meeting_admission','native_windows_meeting_decoded_media','native_windows_meeting_mute','native_windows_meeting_unmute','native_windows_meeting_end')
 if($Record.error_type -isnot [string] -or $Record.error_type -cnotin $types -or $Record.active_case -isnot [string] -or $Record.active_case -cnotin $cases -or $Record.source_frames -isnot [Array] -or $Record.source_frames.Count -gt 4){return $null}
 $frames=@()
 foreach($frame in $Record.source_frames){
  if($null -eq $frame -or ($frame -isnot [Collections.IDictionary] -and $frame -isnot [pscustomobject])){return $null}
  $names=if($frame -is [Collections.IDictionary]){@($frame.Keys)}else{@($frame.PSObject.Properties.Name)}
  if($names.Count -ne 2 -or @($names|Where-Object {$_ -cnotin @('source_basename','source_line')}).Count -or $frame.source_basename -isnot [string] -or $frame.source_basename -cnotin @('windows_restored_meeting.py','windows-restore-qualification.py','windows-meet-browser.py','windows_meeting_owned_process.py') -or ($frame.source_line -isnot [int] -and $frame.source_line -isnot [long]) -or $frame.source_line -le 0 -or $frame.source_line -ge 1000000){return $null}
  $frames+=@{source_basename=$frame.source_basename;source_line=$frame.source_line}
 }
 foreach($name in 'owned_process_cleanup_failed','owned_processes_closed'){if($null -ne $Record.$name -and $Record.$name -isnot [bool]){return $null}}
 $safe=@{schema=1;state='failed';producer='windows_restored_meeting.py';error_type=$Record.error_type;cleanup_verified=$Record.cleanup_verified;source_frames=$frames;active_case=$Record.active_case;owned_process_cleanup_failed=$Record.owned_process_cleanup_failed;owned_processes_closed=$Record.owned_processes_closed}
 if('meeting_path' -cin $actual){
  if($Record.active_case -cne 'native_windows_meeting_browser_start'){return $null}
  $paths=SafeRestoredConferencePathFields $Record
  if($paths -isnot [Collections.IDictionary] -or $paths.Count -ne 1 -or !$paths.Contains('meeting_path')){return $null}
  $safe.meeting_path=$paths.meeting_path
 }
 if('meeting_wss_child_failure' -cin $actual){
  if($Record.active_case -cne 'native_windows_meeting_browser_start'){return $null}
  $child=SafeRestoredConferenceWssChildFields $Record.meeting_wss_child_failure
  if($child -isnot [Collections.IDictionary] -or $child.Count -ne 1 -or !$child.Contains('meeting_wss_child_failure')){return $null}
  $safe.meeting_wss_child_failure=$child.meeting_wss_child_failure
 }
 return $safe
}
function SafeRestoredConferencePathFields($Record){
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
function ReadRestoredConferenceFailure {
 $child=$script:qualificationFailedChild
 if($null -eq $child -or $child -isnot [Collections.IDictionary]){return $null}
 $keys=@($child.Keys)
 if($keys.Count -ne 4 -or @($keys|Where-Object {$_ -cnotin @('caller','label','completion','exit_code')}).Count -or $child.caller -isnot [string] -or $child.caller -cne 'CheckedProcess' -or $child.label -isnot [string] -or $child.label -cne 'restored-conference-supplement' -or $child.completion -isnot [string] -or $child.completion -cne 'exit' -or ($child.exit_code -isnot [int] -and $child.exit_code -isnot [long]) -or $child.exit_code -eq 0 -or $child.exit_code -lt -2147483648L -or $child.exit_code -gt 4294967295L){return $null}
 $path=Join-Path $work 'restored-conference-supplement.out'
 if(!(Test-Path -LiteralPath $path -PathType Leaf)){return $null}
 $item=Get-Item -LiteralPath $path -Force
 if($item.Length -le 0 -or $item.Length -gt 8192 -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){return $null}
 $parent=$item.Directory;$depth=0
 while($null -ne $parent){if(++$depth -gt 32 -or ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){return $null};$parent=$parent.Parent}
 $stream=$null;$document=$null
 try{
  $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
  if($stream.Length -le 0 -or $stream.Length -gt 8192){return $null}
  $expected=$stream.Length;$buffer=[byte[]]::new(8193);$length=0
  do{$read=$stream.Read($buffer,$length,$buffer.Length-$length);$length+=$read}while($read -gt 0 -and $length -lt $buffer.Length)
  if($length -ne $expected -or $stream.Length -ne $expected){return $null}
  $json=[Text.UTF8Encoding]::new($false,$true).GetString($buffer,0,$length)
  $options=[Text.Json.JsonDocumentOptions]::new();$options.MaxDepth=8
  $document=[Text.Json.JsonDocument]::Parse($json,$options)
  if($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object){return $null}
  $frames=[Text.Json.JsonElement]::new()
  if(!$document.RootElement.TryGetProperty('source_frames',[ref]$frames) -or $frames.ValueKind -ne [Text.Json.JsonValueKind]::Array -or $frames.GetArrayLength() -gt 4){return $null}
  $pending=[Collections.Generic.Stack[Text.Json.JsonElement]]::new();$pending.Push($document.RootElement);$containers=0
  while($pending.Count){
   if(++$containers -gt 64){return $null};$node=$pending.Pop()
   if($node.ValueKind -eq [Text.Json.JsonValueKind]::Object){
    $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($property in $node.EnumerateObject()){
     if(!$names.Add($property.Name)){return $null}
     if($property.Value.ValueKind -in [Text.Json.JsonValueKind]::Object,[Text.Json.JsonValueKind]::Array){$pending.Push($property.Value)}
    }
   }elseif($node.ValueKind -eq [Text.Json.JsonValueKind]::Array){
    foreach($value in $node.EnumerateArray()){if($value.ValueKind -in [Text.Json.JsonValueKind]::Object,[Text.Json.JsonValueKind]::Array){$pending.Push($value)}}
   }
  }
  return SafeRestoredConferenceFailure (ConvertFrom-Json -InputObject $json -AsHashtable)
 }catch{return $null}finally{if($document){$document.Dispose()};if($stream){$stream.Dispose()}}
}
function RestoredMeetingSupplement {
 Check ($Role -ceq 'Target' -and [version]$BaseVersion -ge [version]'1.0.20') 'The conference supplement requires the restored current target.'
 $script:phase='restored browser conference supplement'
 $bindingBefore=Set-SuiteFixtureBinding -Read
 $adapter=Join-Path $state ('native-qualification/'+[Guid]::NewGuid().ToString('N').Substring(0,24))
 Check (!(Test-Path -LiteralPath $adapter)) 'A fresh private native adapter is required.'
 PrivateDirectory $adapter
 try{CheckedProcess $python @('-I','-B',(Join-Path $PSScriptRoot 'windows_restored_meeting.py'),'--input',$inputFile,'--adapter',$adapter) 'restored-conference-supplement' $source 600000}
 catch{
  try{$failure=ReadRestoredConferenceFailure;if($null -ne $failure){$facts.restored_conference_failure=$failure}}catch{}
  throw
 }
 Check (!(Test-Path -LiteralPath $adapter)) 'The owned native adapter scope survived cleanup.'
 $meeting=Get-Content -LiteralPath (Join-Path (Split-Path $inputFile -Parent) 'restored-conference.safe.json') -Raw|ConvertFrom-Json
 $keys=@('schema','state','producer','run_id','source_commit','base_suite_run_id','base_archive_sha256','media','original_meetings_and_members_preserved','original_bindings_and_holds_preserved','owned_processes_closed','owned_native_scope_removed','remaining_calls','existing_invitation_continuity','physical_camera','external_nat')
 Check (@($meeting.PSObject.Properties).Count -eq $keys.Count -and @($meeting.PSObject.Properties.Name|Where-Object {$_ -cnotin $keys}).Count -eq 0) 'One exact closed restored-conference receipt is required.'
 Check (($meeting.schema -is [long] -or $meeting.schema -is [int]) -and $meeting.schema -eq 1 -and $meeting.state -ceq 'passed' -and $meeting.producer -ceq 'windows_restored_meeting.py') 'The restored media producer did not pass.'
 Check ($meeting.run_id -ceq $env:GITHUB_RUN_ID -and $meeting.source_commit -ceq $env:GITHUB_SHA -and $meeting.base_suite_run_id -ceq $BaseSuiteRunId -and $meeting.base_archive_sha256 -ceq $facts.base_archive_sha256) 'The restored media receipt changed its run or archive binding.'
 foreach($name in 'original_meetings_and_members_preserved','original_bindings_and_holds_preserved','owned_processes_closed','owned_native_scope_removed'){Check ($meeting.$name -is [bool] -and $meeting.$name) 'Exact restored conference preservation and cleanup are required.'}
 Check (($meeting.remaining_calls -is [long] -or $meeting.remaining_calls -is [int]) -and $meeting.remaining_calls -eq 0) 'Restored conference calls survived.'
 foreach($name in 'existing_invitation_continuity','physical_camera','external_nat'){Check ($meeting.$name -ceq 'unqualified') 'Unobserved conference capabilities cannot be promoted.'}
 $media=$meeting.media;$mediaKeys=@('checks','wss_roundtrips','host_frames','guest_frames','host_tone_ratio','guest_tone_ratio','physical_camera')
 Check (@($media.PSObject.Properties).Count -eq $mediaKeys.Count -and @($media.PSObject.Properties.Name|Where-Object {$_ -cnotin $mediaKeys}).Count -eq 0) 'Closed original browser media proof required.'
 foreach($pair in @(@('checks',9),@('wss_roundtrips',16))){$n=$media.($pair[0]);Check (($n -is [long] -or $n -is [int]) -and $n -eq $pair[1]) 'All original browser and WSS checks are required.'}
 foreach($name in 'host_frames','guest_frames'){$n=$media.$name;Check (($n -is [long] -or $n -is [int]) -and $n -ge 10 -and $n -le 2147483647) 'Decoded VP8 frames are required.'}
 foreach($name in 'host_tone_ratio','guest_tone_ratio'){$n=$media.$name;Check (($n -is [double] -or $n -is [long] -or $n -is [int]) -and $n -gt .65 -and $n -le 1) 'Independent decoded audio tones are required.'}
 Check ($media.physical_camera -ceq 'unqualified') 'Synthetic browser media does not qualify physical cameras.'
 $bindingAfter=Set-SuiteFixtureBinding -Read
 Check ([Convert]::ToBase64String($bindingBefore.hash) -ceq [Convert]::ToBase64String($bindingAfter.hash) -and $bindingBefore.store -ceq $bindingAfter.store) 'Restored meeting execution changed the exact target IIS certificate binding.'
 $facts.qualification_mode='restored_conference_supplement'
 $facts.restored_conference=$meeting
 $facts.gates.restored_browser_conference_two_way_decoded_audio_video='passed'
}
function SafeRestoreWaitFailure($Record){
 if($null -eq $Record -or $Record -is [Array]){return $null}
 $keys=@('schema','wait_kind','timeout_seconds','source_basename','caller_function','caller_line')
 $actual=@();if($Record -is [Collections.IDictionary]){$actual=@($Record.Keys)}else{$actual=@($Record.PSObject.Properties.Name)}
 if($actual.Count -notin 6,7 -or @($actual|Where-Object {$_ -cnotin ($keys+@('backup_task'))}).Count -or @($keys|Where-Object {$_ -cnotin $actual}).Count){return $null}
 $sites=@{native_invite_ack=@('native',120);native_recording_row=@('native',120);native_media_files=@('media',120);manual_backup_request=@('backup_request',120);manual_backup_complete=@('backup_request',600);restored_daily_task_result=@('backup_request',180);daily_backup_request=@('backup_request',180);daily_backup_complete=@('backup_request',600);restored_job_invite_ack=@('job',120);restored_job_completion=@('job',120)}
 if(($Record.schema -isnot [int] -and $Record.schema -isnot [long]) -or $Record.schema -ne 1 -or $Record.wait_kind -isnot [string] -or $Record.wait_kind -cnotin @($sites.Keys)){return $null}
 $site=$sites[$Record.wait_kind]
 if(($Record.timeout_seconds -isnot [int] -and $Record.timeout_seconds -isnot [long]) -or $Record.timeout_seconds -ne $site[1] -or $Record.caller_function -isnot [string] -or $Record.caller_function -cne $site[0] -or $Record.source_basename -isnot [string] -or $Record.source_basename -cne 'windows-restore-qualification.py' -or ($Record.caller_line -isnot [int] -and $Record.caller_line -isnot [long]) -or $Record.caller_line -le 0 -or $Record.caller_line -ge 1000000){return $null}
 $safe=@{schema=1;wait_kind=$Record.wait_kind;timeout_seconds=$Record.timeout_seconds;source_basename=$Record.source_basename;caller_function=$Record.caller_function;caller_line=$Record.caller_line}
 if('backup_task' -cin $actual){
  $task=$Record.backup_task;if($null -eq $task -or $task -is [Array]){return $null}
  $taskKeys=@();if($task -is [Collections.IDictionary]){$taskKeys=@($task.Keys)}else{$taskKeys=@($task.PSObject.Properties.Name)}
  if($taskKeys.Count -ne 4 -or @($taskKeys|Where-Object {$_ -cnotin @('state','last_result','expected_system_action','last_run_available')}).Count -or $task.state -isnot [string] -or $task.state -cnotin @('Unknown','Disabled','Queued','Ready','Running') -or ($task.last_result -isnot [int] -and $task.last_result -isnot [long]) -or $task.last_result -lt 0 -or $task.last_result -gt 4294967295 -or $task.expected_system_action -isnot [bool] -or $task.last_run_available -isnot [bool]){return $null}
  $safe.backup_task=@{state=$task.state;last_result=$task.last_result;expected_system_action=$task.expected_system_action;last_run_available=$task.last_run_available}
 }
 return $safe
}

function NativeFixture([string]$Action){
 $script:phase=$Action
 # The extracted interpreter remains independent of private installed state.
 try{CheckedProcess $python @('-I','-B',(Join-Path $PSScriptRoot 'windows-restore-qualification.py'),'--input',$inputFile,'--action',$Action) ('restore-'+$Action) $source 1200000}
 catch{
  $safe=$null
  $privateOutput=Join-Path $work ('restore-'+$Action+'.out')
  if(Test-Path $privateOutput){try{$safe=Get-Content $privateOutput -Raw|ConvertFrom-Json;if($safe.state -eq 'failed' -and $safe.error_type -match '^[A-Za-z0-9_.]{1,120}$' -and $safe.source_basename -match '^[A-Za-z0-9_.-]{1,120}$' -and ($safe.source_line -is [long] -or $safe.source_line -is [int]) -and $safe.source_line -ge 0 -and $safe.source_line -lt 1000000){$facts.native_failure=@{error_type=$safe.error_type;source_basename=$safe.source_basename;source_line=$safe.source_line;active_case=$Action};$tableFailure=SafeRestoreTableFailure $safe $Action;if($tableFailure){$facts.native_failure.table_comparison=$tableFailure};$schemaFailure=SafeRestoreSchemaFailure $safe $Action;if($schemaFailure){$facts.native_failure.comparison_label=$schemaFailure.comparison_label;$facts.native_failure.schema_groups_differ=$schemaFailure.schema_groups_differ};if($Action -ceq 'cleanup'){$observation=SafeRestoreFixtureFailure $safe.fixture_failure;if($observation){$facts.native_failure.fixture_failure=$observation}};if($Action -ceq 'late-restore' -and $safe.error_type -ceq 'ValueError' -and $safe.source_basename -ceq 'windows-restore-qualification.py' -and $safe.failure_kind -is [string] -and $safe.failure_kind -ceq 'non_distinct_installation_identity' -and $safe.identity_field -is [string] -and $safe.identity_field -cin @('hardware_uuid_hmac','hostname_hmac','certificate_sha256','template_key_sha256')){$facts.native_failure.failure_kind=$safe.failure_kind;$facts.native_failure.identity_field=$safe.identity_field};if($Action -cin @('native-source','native-target')){$peerFailures=SafeRestorePeerFailures $safe.peer_cleanup_failure;if($peerFailures){$facts.native_failure.peer_cleanup_failure=$peerFailures};$receivers=SafeRestorePeerFailures $safe.peer_receiver_failure -Receiver;if($receivers){$facts.native_failure.peer_receiver_failure=$receivers};if($safe.native_substage -is [string] -and $safe.native_substage -cin @('registration','internal_invite','internal_ack','internal_media','internal_hangup','answered_recording','voicemail_isolation','voicemail_deposit','mailbox_invite','mailbox_login_prompt','mailbox_main_prompt','mailbox_recording_playback','mailbox_media','mailbox_hangup','peer_cleanup','peer_receiver')){$facts.native_failure.native_substage=$safe.native_substage};$allowed=if($Action -ceq 'native-source'){@('source_real_two_way_recorded_call','source_real_native_voicemail_deposit')}else{@('restored_original_credentials_two_way_decoded_native_audio','restored_original_native_voicemail_121_pin_free_retrieval')};if($safe.completed_native_cases -is [array] -and $safe.completed_native_cases.Count -le 2 -and @($safe.completed_native_cases|Select-Object -Unique).Count -eq $safe.completed_native_cases.Count -and @($safe.completed_native_cases|Where-Object {$_ -isnot [string] -or $_ -cnotin $allowed}).Count -eq 0){$cases=@($allowed|Where-Object {$_ -cin $safe.completed_native_cases});$facts.native_failure.completed_native_cases=$cases;foreach($name in $cases){$facts.gates[$name]='passed'}}}}}catch{}}
  if($Action -ceq 'clock-target' -and $facts.native_failure){try{
   if($safe.clock_phase -is [string] -and $safe.clock_phase -cin @('preflight','bindings','observer','invite','signals','analyze','cleanup')){$facts.native_failure.clock_phase=$safe.clock_phase}
   $peerFailures=SafeRestorePeerFailures $safe.peer_cleanup_failure;if($peerFailures){$facts.native_failure.peer_cleanup_failure=$peerFailures}
  }catch{}}
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
  try{
   if($facts.native_failure -and $safe.state -ceq 'failed' -and $safe.error_type -is [string] -and $safe.error_type -ceq 'RuntimeError' -and $safe.source_basename -is [string] -and $safe.source_basename -ceq 'windows-restore-qualification.py' -and (Test-Path -LiteralPath $privateOutput -PathType Leaf)){
    $phpOutput=Get-Item -LiteralPath $privateOutput -Force
    if($phpOutput.Length -gt 0 -and $phpOutput.Length -le 1048576 -and ($phpOutput.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0){$phpFailure=SafeRestorePhpFailure $safe.php_failure;if($phpFailure){$facts.native_failure.php_failure=$phpFailure}}
   }
  }catch{}
  try{
   if($Action -cin @('export-source','target-backup','native-source','native-target','job') -and $facts.native_failure -and $safe.state -ceq 'failed' -and $safe.error_type -is [string] -and $safe.error_type -ceq 'TimeoutError' -and $safe.source_basename -is [string] -and $safe.source_basename -ceq 'windows-restore-qualification.py' -and (Test-Path -LiteralPath $privateOutput -PathType Leaf)){
    $waitOutput=Get-Item -LiteralPath $privateOutput -Force
    if($waitOutput.Length -gt 0 -and $waitOutput.Length -le 1048576 -and ($waitOutput.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0){$waitFailure=SafeRestoreWaitFailure $safe.wait_failure;if($waitFailure){$facts.native_failure.wait_failure=$waitFailure}}
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
 & (Join-Path $PSScriptRoot 'windows_restore_health_quiescence.ps1') -SourceRoot $source
 Check $? 'The strict source/target Health quiescence controls must pass before installation.'
 Check (!(Test-Path $root) -and !(Test-Path "$state\installation.json") -and !(Test-Path "$configuration\config.conf") -and !(Get-Service FreeSWITCH -ErrorAction SilentlyContinue)) 'Each job must be genuinely empty and refuses an existing owner installation.'
 $candidate=Artifact $BaseSuiteRunId ('openwebpbx-windows-suite-candidate-'+$BaseSuiteRunId) '.github/workflows/windows-suite.yml'
 $report=Artifact $BaseSuiteRunId ('openwebpbx-windows-suite-facts-'+$BaseSuiteRunId) '.github/workflows/windows-suite.yml'
 $baseFacts=Get-Content (Join-Path $report.directory 'qualification.json') -Raw|ConvertFrom-Json
 Check ($baseFacts.schema -eq 1 -and $baseFacts.run_id -eq $BaseSuiteRunId -and $baseFacts.source_commit -eq $candidate.run.head_sha -and $baseFacts.state -in 'partial','passed') 'Exact qualified baseline facts are required.'
 foreach($gate in 'fresh','native_sip_audio','backups','direct_113_helper_reapply','direct_failure_rollback','restore_gate_startup'){Check ($baseFacts.gates.$gate -eq 'passed') 'Every essential real baseline gate must pass.'}
 if([version]$BaseVersion -ge [version]'1.0.20'){
  foreach($gate in 'web_readiness','tenant_domains','meeting_transport','meeting_browser','phone_health','stun','native_clock','native_providers','native_call_me_back'){Check ($baseFacts.gates.$gate -is [string] -and $baseFacts.gates.$gate -ceq 'passed') 'The current Windows web, tenant, meeting, phone health, STUN, clock, provider and callback gates must all be qualified.'}
  $listenerProof=$baseFacts.public_listener_qualification
  Check ($null -ne $listenerProof -and ($listenerProof -is [pscustomobject] -or $listenerProof -is [Collections.IDictionary]) -and $listenerProof -isnot [Array]) 'The current public-listener qualification record is required.'
  Check ($listenerProof.state -is [string] -and $listenerProof.state -ceq 'passed') 'Both actual native public-listener stages must pass.'
  Check ($listenerProof.outside_acme -is [string] -and $listenerProof.outside_acme -ceq 'unqualified') 'Public ACME acceptance remains a separate explicit qualification.'
  foreach($kind in 'native_defender','installed_collector'){
   $listenerRecord=$listenerProof.$kind
   Check ($null -ne $listenerRecord -and ($listenerRecord -is [pscustomobject] -or $listenerRecord -is [Collections.IDictionary]) -and $listenerRecord -isnot [Array]) 'Both current public-listener stage records are required.'
   if($kind -ceq 'native_defender'){
    $producer='windows_public_listeners_native.ps1';$minimum=21
    $positive=@('actual_native_defender','actual_os_listener_ownership','service_identity_adapter_double','global_policy_exact','actual_throw_after_create_and_enable','idempotent','foreign_named_rule_preserved','configured_private_ports_excluded','profiles_all_enabled_at_observation')
    $negative=@('firewall_enforcement_tested','firewall_profiles_changed','installed_server_changed','calls_placed')
   }else{
    $producer='windows_public_listener_installed.ps1';$minimum=14
    $positive=@('actual_installed_php_pg_esl_os','exact_installed_helper_manifest','provider_5080_tcp_udp_planned','tls_only_when_actually_bound','configured_default_audio_source','private_service_ports_excluded','read_only_preflight')
    $negative=@('firewall_or_configuration_mutated','calling_or_audio_acceptance','installed_server_changed')
   }
   Check (($listenerRecord.schema -is [int] -or $listenerRecord.schema -is [long]) -and $listenerRecord.schema -eq 1 -and $listenerRecord.state -is [string] -and $listenerRecord.state -ceq 'passed' -and $listenerRecord.producer -is [string] -and $listenerRecord.producer -ceq $producer) 'The exact native public-listener producer and passed schema are required.'
   Check (($listenerRecord.checks -is [int] -or $listenerRecord.checks -is [long]) -and $listenerRecord.checks -ge $minimum -and $listenerRecord.checks -le 100000) 'Both complete bounded public-listener matrices are required.'
   foreach($field in $positive){Check ($listenerRecord.$field -is [bool] -and $listenerRecord.$field -eq $true) 'Actual public-listener coverage and fixture scope must match.'}
   foreach($field in $negative){Check ($listenerRecord.$field -is [bool] -and $listenerRecord.$field -eq $false) 'Public-listener enforcement and calling limitations must remain explicit.'}
  }
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
 Check ($baseFacts.cleanup -eq 'owned services stopped, SFTP receiver/account removed, hostname removed, activation holds preserved') 'The qualified baseline must have completed its exact owned cleanup.'
 $base=Join-Path $candidate.directory ("openwebpbx-$BaseVersion-windows-x64.zip")
 Check ((Hash $base) -eq $baseFacts.candidate_artifact.sha256 -and $baseFacts.artifacts.candidate_sha256 -eq $baseFacts.candidate_artifact.sha256 -and $baseFacts.candidate_artifact.filename -eq ("openwebpbx-$BaseVersion-windows-x64.zip") -and $baseFacts.candidate_artifact.private_exclusions -eq 'passed' -and $baseFacts.candidate_artifact.verified_before_credentials -eq $true) 'The exact independently audited package and BOTH candidate evidence fields must match the qualification.'
 CheckedProcess 'python.exe' @((Join-Path $PSScriptRoot 'windows_candidate_archive.py'),'--archive',$base,'--version',$BaseVersion,'--sha256',$baseFacts.candidate_artifact.sha256) 'verify-qualified-package'
 $expanded=Join-Path $work 'package';PrivateDirectory $expanded;ExpandSafe $base $expanded
 $packages=@(Get-ChildItem $expanded -Directory);Check ($packages.Count -eq 1) 'One exact release package root is required.';$package=$packages[0].FullName;$PackageRoot=$package;$python=Join-Path $package 'backup-runtime/python.exe';NativeVersions $package $BaseVersion|Out-Null
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
 $phase='exact owned Health observer quiescence before both restore baselines'
 Suspend-OpenWebQualificationHealth ([ref]$qualificationHealthOriginal)
 if([version]$BaseVersion -ge [version]'1.0.20'){Check $qualificationHealthOriginal.Exists 'The current package must install its exact owned Health observer before restore qualification.'}
 $facts.health_observer=@{original_exists=[bool]$qualificationHealthOriginal.Exists;original_enabled=[bool]$qualificationHealthOriginal.Enabled;original_running=[bool]$qualificationHealthOriginal.Running;quiescent_before_baseline=$true;original_choice_restored=$false;quiescent_before_shutdown=$false}
 # Keep the complete Health tables and private runtime files in all existing
 # dump/snapshot comparisons. The observer remains disabled through source
 # export, failed/normal target restore and explicit activation assertions.
 $env:OPENWEB_WINDOWS_RESTORE_TEST='1';Fixture 'baseline';NativeFixture 'setup'
 $facts.base_suite_run_id=$BaseSuiteRunId;$facts.base_archive_sha256=Hash $base;$facts.base_source_commit=$baseFacts.source_commit
 if($Role -eq 'Source'){
  EnableTargetTls;NativeFixture 'native-source';NativeFixture 'export-source';AssertBackupTask
 }else{
  $originalTaskStates=@{}
  foreach($name in 'OpenWebPBX-Cleanup','OpenWebPBX Outgoing Mail','OpenWebPBX-TenantDomains','OpenWebPBX-PhoneHealth','OpenWebPBX Certificate Renewal','OpenWebPBX Pending Phone Certificate'){$task=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue;if($task){$originalTaskStates[$name]=[bool]$task.Settings.Enabled}}
  NativeFixture 'late-restore';NativeFixture 'restore'
  $currentBinding=Set-SuiteFixtureBinding -Read
  Check ([Convert]::ToHexString($currentBinding.hash) -eq $pki.leaf.Thumbprint -and $currentBinding.store -eq 'My') 'Restore changed the replacement machine actual IIS certificate binding.'
  HeldServiceRestart
  EnableTargetTls -Prepared;NativeFixture 'activate-calls';NativeFixture 'native-target'
  if([version]$BaseVersion -ge [version]'1.0.20'){NativeFixture 'clock-target'}
  if($RestoredConferenceSupplement){RestoredMeetingSupplement}
  NativeFixture 'job'
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
 if($Role -eq 'Target' -and [version]$BaseVersion -ge [version]'1.0.20'){
  $clock=SafeRestoredClockSummary $nativeFacts.clock_native
  Check ($null -ne $clock -and $facts.gates.restored_original_native_clock_1026_Nathaniel_GMT2_audio -ceq 'passed') 'Actual restored Windows clock speech, GMT+2 signals and exact owned cleanup must pass.'
  $facts.clock_native=$clock
 }
 $facts.state='passed'
}catch{
 $facts.state='failed';$facts.failed_phase=$phase;$facts.error_type=$_.Exception.GetType().Name
 $facts.source_basename=[IO.Path]::GetFileName($_.InvocationInfo.ScriptName);$facts.source_line=[int]$_.InvocationInfo.ScriptLineNumber
 try{$activationFailure=SafeRestoreServiceActivationFailure $_.Exception.Data['restore_service_activation'];if($activationFailure){$facts.service_activation_failure=$activationFailure}}catch{}
 throw
}finally{
 try{
  if($installed){
   $cleanupLock=[IO.File]::Open("$state\upgrade.lock",'OpenOrCreate','ReadWrite','None')
   try{
    # Restore the pre-baseline choice only after every strict comparison.
    # Hold the shared lock while immediately quiescing again for deliberate
    # disposable teardown, so a restarted worker cannot write between them.
    Resume-OpenWebQualificationHealth $qualificationHealthOriginal
    if($qualificationHealthOriginal -and $qualificationHealthOriginal.Exists){Check ([bool](Get-ScheduledTask -TaskName 'OpenWebPBX-PhoneHealth').Settings.Enabled -ceq [bool]$qualificationHealthOriginal.Enabled) 'Disposable cleanup failed to restore the original Health enabled choice.'}
    if($facts.health_observer){$facts.health_observer.original_choice_restored=$true}
    $cleanupHealth=$null;Suspend-OpenWebQualificationHealth ([ref]$cleanupHealth)
    if($facts.health_observer){$facts.health_observer.quiescent_before_shutdown=$true}
   foreach($name in 'OpenWebPBXUpdater','OpenWebPBX','FreeSWITCH'){Stop-Service $name -Force -ErrorAction SilentlyContinue}
   foreach($name in 'OpenWebPBX-Backups','OpenWebPBX Outgoing Mail','OpenWebPBX-TenantDomains','OpenWebPBX-Cleanup','OpenWebPBX Certificate Renewal','OpenWebPBX Pending Phone Certificate','OpenWebPBX-Updater-Restart'){$task=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue;if($task){Disable-ScheduledTask -InputObject $task|Out-Null;Stop-ScheduledTask -InputObject $task -ErrorAction SilentlyContinue}}
   # Stop only the installer-created PostgreSQL service, never another instance.
   $pg=@(Get-CimInstance Win32_Service|Where-Object {$_.Name -like 'OpenWebPBX*' -and $_.PathName -like '*C:\OpenWebPBX\pgsql*'})
   foreach($service in $pg){Stop-Service $service.Name -Force -ErrorAction SilentlyContinue}
   }finally{$cleanupLock.Dispose()}
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
