#Requires -RunAsAdministrator
#Requires -Version 7.4
# SPDX-License-Identifier: AGPL-3.0-or-later
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PackageRoot,[switch]$DisposableHostedRunner,[Parameter(Mandatory)][string]$InputPath,[Parameter(Mandatory)][string]$ReportPath)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
. (Join-Path $PSScriptRoot 'windows-native-restart-observer.ps1')
if(!$DisposableHostedRunner -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:RUNNER_OS -ne 'Windows' -or $env:GITHUB_REPOSITORY -ne 'embire2/openwebpbx') { throw 'Explicit disposable Windows hosted runner required.' }
if([Environment]::OSVersion.Version.Build -lt 26100){throw 'Windows Server 2025 is required.'}
$inputData=Get-Content -LiteralPath $InputPath -Raw|ConvertFrom-Json -AsHashtable
$root='C:\OpenWebPBX';$state=Join-Path $env:ProgramData 'OpenWebPBX';$source=Split-Path $PSScriptRoot -Parent
if($inputData.schema -ne 1 -or !$inputData.restore_server -or [IO.Path]::GetFullPath($inputData.private_state_root) -ne [IO.Path]::GetFullPath($state) -or [IO.Path]::GetFullPath($inputData.source_root) -ne [IO.Path]::GetFullPath($source) -or $inputData.public_url -ne 'https://windowsqa.example.invalid:8443' -or $inputData.run_id -ne $env:GITHUB_RUN_ID){throw 'The private disposable factory contract is invalid.'}
$installation=Get-Content -LiteralPath "$state\installation.json" -Raw|ConvertFrom-Json
if(!$installation.Completed -or !$installation.RestoreServer -or $installation.AdminEmail -ne $inputData.admin_email){throw 'A completed empty restore-server installation is required.'}
$python=[IO.Path]::GetFullPath($inputData.python)
if($python -ne "$root\backup-runtime\python.exe" -or !(Test-Path -LiteralPath $python)){throw 'Use the isolated bundled Python runtime.'}
$nativeEngine=Get-Content -LiteralPath "$state\native-engine.json" -Raw|ConvertFrom-Json
if($nativeEngine.schema -ne 1){throw 'The verified guarded registrar is required.'}
$scope=[Guid]::NewGuid().ToString('N').Substring(0,24)
$work=Join-Path $state "native-qualification\$scope";$evidence=Join-Path $work 'evidence';$privateInput=Join-Path $work 'input.json';$saved=Join-Path $work 'original'
function PrivateDirectory([string]$Path){New-Item -ItemType Directory -Force -Path $Path|Out-Null;& icacls.exe $Path /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F'|Out-Null;if($LASTEXITCODE){throw 'Private native evidence permissions failed.'}}
PrivateDirectory $work;PrivateDirectory $evidence;PrivateDirectory $saved
$inputData.scope=$scope;$inputData.company_name='Fictional Windows '+$scope;$inputData.service_name='Fictional Native '+$scope;$inputData.evidence_directory=$evidence
[IO.File]::WriteAllText($privateInput,($inputData|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
$envBefore=$env:OPENWEB_WINDOWS_NATIVE_TEST;$opensslBefore=$env:OPENSSL_CONF;$env:OPENWEB_WINDOWS_NATIVE_TEST='1';$env:OPENSSL_CONF="$root\php\extras\ssl\openssl.cnf"
$script="$source\tests\windows-native-acceptance.py";$fixture="$source\tests\windows-native-fixture.php";$pkiProcess=$null;$pkiOutput=$null;$pkiErrors=$null;$leaf=$null;$rootCertificate=$null;$binding=$null;$originalBinding=$null;$baseline=$false;$nativePassed=$false;$cleanupPassed=$false;$phase='factory inventory';$errorType=$null
$facts=[ordered]@{schema=1;state='running';platform='Windows Server 2025 x64';scope='fictional disposable hosted runner';checks=@();gates=[ordered]@{native_sip_audio='pending';meeting_browser='pending';native_clock='pending';native_providers='pending';native_call_me_back='pending';smtp='pending';notification_store='pending';cleanup='pending';public_acme='unqualified';physical_devices='unqualified';carrier='unqualified';android_hardware='unqualified'}}
function Php([string]$Action){$output=& "$root\php\php.exe" $fixture $Action $privateInput 2>>"$evidence\private-php-errors.log";if($LASTEXITCODE){throw 'Private native fixture operation failed.'};return ($output -join "`n")}
function Python([string]$Phase){
 $beforeModules=$env:PSModulePath
 $env:PSModulePath=(Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules')+';'+(Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules')
 try{& $python -I $script --input $privateInput --phase $Phase 1>>"$evidence\private-python.log" 2>>"$evidence\private-python-errors.log";if($LASTEXITCODE){throw 'Actual native qualification did not pass.'}}
 finally{if($null -eq $beforeModules){Remove-Item Env:\PSModulePath -ErrorAction SilentlyContinue}else{$env:PSModulePath=$beforeModules}}
}
function CompletedMediaCases($Checks){
 # Publish only fixed completed case names; peer metrics and raw child data
 # remain in the administrator-private report.
 $allowed=@('native_windows_meeting_browser_video_audio','native_tls_signalling_two_way_decoded_rtp','native_g729_pcmu_independent_codec_two_way_transcoding','native_simultaneous_ring_group','native_hunting_ring_group','native_queue_agent_first','native_ivr_negotiated_wire_rfc2833','native_visible_sip_hold_selected_music_resume_transfer','native_configured_ivr_timeout','native_queue_pause_logout_wire_callback_localservice_agent_first_decoded_rtp','native_hotel_wakeup_localservice_claim_wire_confirmation','native_voicemail_recording_private_owned_wav','native_tls_mailbox_wire_forwarding_exact_binary_wav','native_global_smtp_unconfigured_queue_preserves_attempts','native_queued_voicemail_global_smtp_ip_auth_actual_loopback_attachment','native_global_smtp_password_auth_actual_loopback','native_global_smtp_trusted_tls_hostname_auth_actual_loopback','native_welcome_inline_qr_config_actual_loopback','native_clock1026_gmt2_three_decoded_announcements','native_provider_outbound_decoded_rtp','native_provider_503_failover_once_decoded_rtp','native_provider_busy_no_failover','native_provider_603_failover_once_decoded_rtp','native_provider_incoming_owned_did_decoded_rtp','native_cmb_sa_id_first_auth_decoded_bridge','native_cmb_saved_caller_decoded_bridge','native_cmb_short_quota_native_cutoff_exact_usage','native_cmb_exhausted_quota_no_destination')
 foreach($name in $allowed){
  foreach($check in @($Checks)){
   if($check.case -is [string] -and $check.case -ceq $name -and $check.passed -is [bool] -and $check.passed -eq $true){$name;break}
  }
 }
}
function AssertWelcomeNativeCase($Checks){
 $rows=@($Checks|Where-Object {$_.case -is [string] -and $_.case -ceq 'native_welcome_inline_qr_config_actual_loopback'})
 if($rows.Count -ne 1 -or $rows[0].passed -isnot [bool] -or !$rows[0].passed -or $rows[0].state -isnot [string] -or $rows[0].state -cne 'passed'){throw 'The actual Windows welcome MIME case must complete exactly once.'}
 $row=$rows[0]
 foreach($flag in 'actual_php_postgresql_dispatcher','two_concurrent_dispatchers','one_actual_loopback_delivery','inline_qr_cid_exact','independent_qr_decoded','qr_and_attached_config_exact','password_free_one_use_setup','used_invitation_suppressed','same_framework_backend','no_php_ini_or_gd_renderer','alias_custody_modelled','tls_readiness_modelled','no_external_mail','actual_windows_native','public_rows_exact','global_mail_config_exact','owned_schema_and_locks_removed','private_credentials_removed'){if($row.$flag -isnot [bool] -or !$row.$flag){throw 'The Windows welcome MIME scope/preservation proof is incomplete.'}}
 if(($row.checks -isnot [int] -and $row.checks -isnot [long]) -or $row.checks -lt 29 -or $row.checks -gt 100000 -or $row.gd_required -isnot [bool] -or $row.gd_required -or $row.decoder_sha256 -isnot [string] -or $row.decoder_sha256 -cne '29f98a91148171460b47a942d137ecc90c4b8097636f23cca65263a56bb025d3'){throw 'The actual independent Windows QR decoder proof is invalid.'}
}
function AssertExtendedNativeCases($Checks){
 $names=@('native_clock1026_gmt2_three_decoded_announcements','native_provider_outbound_decoded_rtp','native_provider_503_failover_once_decoded_rtp','native_provider_busy_no_failover','native_provider_603_failover_once_decoded_rtp','native_provider_incoming_owned_did_decoded_rtp','native_cmb_sa_id_first_auth_decoded_bridge','native_cmb_saved_caller_decoded_bridge','native_cmb_short_quota_native_cutoff_exact_usage','native_cmb_exhausted_quota_no_destination')
 foreach($name in $names){
  $rows=@($Checks|Where-Object {$_.case -is [string] -and $_.case -ceq $name})
  if($rows.Count -ne 1 -or $rows[0].passed -isnot [bool] -or !$rows[0].passed){throw 'Every extended native clock/provider/Call Me Back case must complete exactly once.'}
  $row=$rows[0]
  $integerFields=@()
  if($name -ceq 'native_clock1026_gmt2_three_decoded_announcements'){$integerFields=@('frozen_Nathaniel_assets','complete_announcements')}
  elseif($name -like 'native_provider_*' -and $name -cne 'native_provider_incoming_owned_did_decoded_rtp'){$integerFields=@('primary_distinct_calls','backup_distinct_calls')}
  elseif($name -like 'native_cmb_*' -and $name -cne 'native_cmb_exhausted_quota_no_destination'){$integerFields=@('charged_seconds','native_reserved_limit_seconds')}
  foreach($field in $integerFields){
   $value=$row.$field;if(($value -isnot [int] -and $value -isnot [long]) -or $value -lt 0 -or $value -gt 100000){throw 'Extended native integer evidence is invalid.'}
  }
  foreach($field in 'minimum_component_correlation','maximum_native_signal_lateness_ms','maximum_decoded_beep_target_error_ms','caller_decoded_ratio','provider_decoded_ratio','extension_decoded_ratio','destination_decoded_ratio','observed_short_cutoff_seconds'){
   if($null -eq $row.$field){continue};$value=$row.$field
   if(($value -isnot [double] -and $value -isnot [single] -and $value -isnot [int] -and $value -isnot [long]) -or [double]::IsNaN($value) -or [double]::IsInfinity($value) -or $value -lt 0 -or $value -gt 100000){throw 'Extended native measured evidence is invalid.'}
  }
  if($name -ceq 'native_clock1026_gmt2_three_decoded_announcements'){
   foreach($flag in 'sourcebindings_verified','GMT_plus_2_full_time_verified','original_phone_media_restored','owned_clock_call_ended','scoped_observer_stopped','software_phone_only','no_carrier_calls_or_database_configuration_writes'){if($row.$flag -isnot [bool] -or !$row.$flag){throw 'The decoded native clock proof is incomplete.'}}
   foreach($field in 'minimum_component_correlation','maximum_native_signal_lateness_ms','maximum_decoded_beep_target_error_ms'){if($null -eq $row.$field){throw 'The decoded native clock timing is missing.'}}
   if($row.frozen_Nathaniel_assets -ne 34 -or $row.complete_announcements -lt 3 -or $row.minimum_component_correlation -lt .62 -or $row.maximum_native_signal_lateness_ms -ge 250 -or $row.maximum_decoded_beep_target_error_ms -ge 250){throw 'The unchanged native clock speech/signal thresholds did not pass.'}
  }
  if($name -like 'native_provider_*'){
   if($row.no_carrier_traffic -isnot [bool] -or !$row.no_carrier_traffic){throw 'Only fictional local provider proof is allowed.'}
   if($name -cin 'native_provider_outbound_decoded_rtp','native_provider_503_failover_once_decoded_rtp','native_provider_603_failover_once_decoded_rtp','native_provider_incoming_owned_did_decoded_rtp'){
    if($row.caller_decoded_ratio -lt .8){throw 'The fictional provider caller audio did not decode.'}
    if($name -ceq 'native_provider_incoming_owned_did_decoded_rtp'){if($row.extension_decoded_ratio -lt .8){throw 'The fictional incoming extension audio did not decode.'}}
    elseif($row.provider_decoded_ratio -lt .8){throw 'The fictional outgoing provider audio did not decode.'}
   }
   if($name -cne 'native_provider_incoming_owned_did_decoded_rtp' -and ($row.primary_distinct_calls -ne 1 -or $row.backup_distinct_calls -ne $(if($name -cin 'native_provider_503_failover_once_decoded_rtp','native_provider_603_failover_once_decoded_rtp'){1}else{0}))){throw 'Provider failover or refusal duplicated a call.'}
  }
  if($name -like 'native_cmb_*'){
   foreach($flag in 'identity_hmac_unchanged','reservation_released','no_carrier_traffic'){if($row.$flag -isnot [bool] -or !$row.$flag){throw 'Native Call Me Back ownership/settlement proof is incomplete.'}}
   if($name -ceq 'native_cmb_short_quota_native_cutoff_exact_usage'){
    if($null -eq $row.observed_short_cutoff_seconds -or $row.native_reserved_limit_seconds -ne 4 -or $row.observed_short_cutoff_seconds -lt 2 -or $row.observed_short_cutoff_seconds -gt 8){throw 'The configured short user quota needs an actual bounded native cutoff measurement.'}
   }
   if($name -ceq 'native_cmb_exhausted_quota_no_destination' -and ($row.no_destination_bridge -isnot [bool] -or !$row.no_destination_bridge)){throw 'An exhausted allowance produced a destination call.'}
   if($name -cne 'native_cmb_exhausted_quota_no_destination'){
    foreach($flag in 'persistent_binding_verified','no_plaintext_identity_in_facts','total_allowance_unchanged','ten_minute_policy_ceiling_verified'){if($row.$flag -isnot [bool] -or !$row.$flag){throw 'Native Call Me Back allowance/HMAC proof is incomplete.'}}
    if($row.actual_600_second_call -isnot [bool] -or $row.actual_600_second_call -or $row.charged_seconds -le 0 -or $row.charged_seconds -gt $row.native_reserved_limit_seconds -or $row.native_reserved_limit_seconds -gt 600 -or $row.caller_decoded_ratio -lt .8 -or $row.destination_decoded_ratio -lt .8){throw 'Native Call Me Back decoded bridge/limit proof is invalid.'}
   }
  }
 }
}
function CollectNativeProgress($Facts,[string]$Evidence){
 $checks=@()
 foreach($name in 'software-native-report.json','native-progress.json'){
  try{
   $file=Get-Item -LiteralPath (Join-Path $Evidence $name) -ErrorAction Stop
   if($file.PSIsContainer -or $file.Length -gt 1MB -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)){continue}
   $child=Get-Content -LiteralPath $file.FullName -Raw|ConvertFrom-Json
   if(($child.schema -isnot [int] -and $child.schema -isnot [long]) -or $child.schema -ne 1 -or $child.producer -isnot [string] -or $child.producer -cne 'windows-native-acceptance.py' -or $child.state -isnot [string] -or $child.state -cnotin 'running','passed','failed' -or $child.checks -isnot [array] -or $child.checks.Count -gt 256){continue}
   if($name -ceq 'software-native-report.json'){
    if($child.state -cnotin 'passed','failed'){continue}
    $Facts.native_child_state=$child.state
   }elseif($child.state -cne 'running'){continue}
   $checks+=@($child.checks)
  }catch{}
 }
 $completed=@(CompletedMediaCases $checks)
 # Only the PS probe, after all its assertions, owns this completion name.
 foreach($value in @($Facts.completed_media_cases)){if($value -is [string] -and $value -ceq 'native_localservice_notification_store_reader'){$completed+='native_localservice_notification_store_reader';break}}
 if($completed.Count){$Facts.completed_media_cases=$completed}
}
function RecordNativeCleanupFailure($Facts,[string]$Stage,$Failure){
 $allowed=@('stop_notification_task','remove_notification_task','restore_factory','restore_binding','restore_files','restart_engine','remove_leaf','remove_root','stop_pki','collect_pki_logs','parent_write_guard')
 if($Stage -cnotin $allowed){$Stage='cleanup_unknown'}
 $Facts.state='failed';$Facts.cleanup='failed';$Facts.native_cleanup_stage=$Stage
 $type=$Failure.Exception.GetType().Name
 if($type -match '^[A-Za-z0-9_]{1,80}$'){$Facts.cleanup_error_type=$type;$Facts.native_cleanup_error_type=$type}
 $name=if($Failure.InvocationInfo.ScriptName){Split-Path -Leaf $Failure.InvocationInfo.ScriptName}else{'external_component'}
 if($name -cne 'windows-native-acceptance.ps1'){$name='external_component'}
 $Facts.native_cleanup_source_basename=$name
 $line=$Failure.InvocationInfo.ScriptLineNumber
 if(($line -is [int] -or $line -is [long]) -and $line -gt 0 -and $line -lt 100000){$Facts.native_cleanup_source_line=$line}
 if(!$Facts.failed_phase){
  $Facts.failed_phase='exact scoped cleanup';$Facts.active_case='exact_scoped_cleanup'
  $Facts.error_type=$type;$Facts.source_basename=$name
  if($Facts.native_cleanup_source_line){$Facts.source_line=$Facts.native_cleanup_source_line}
 }
}
function NativeCleanupFixtureFields([string]$InputFile){
 $safe=@{}
 try{
  $file=Get-Item -LiteralPath ($InputFile+'.cleanup.failure.json') -ErrorAction Stop
  if($file.PSIsContainer -or $file.Length -gt 2048 -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)){return $safe}
  $row=Get-Content -LiteralPath $file.FullName -Raw|ConvertFrom-Json
  $sources=@('windows-native-fixture.php','permissions.php','database.php','pbx_admin.php','pbx_setup.php','pbx_setup_provisioner.php','pbx_tenants.php','pbx_paths.php','pbx_mapper.php','pbx_schedule.php','pbx_operations.php','pbx_native.php','pbx_phone_auth.php','pbx_sip_domain.php','config.php','event_socket.php','cache.php','external_component')
  if(($row.schema -isnot [int] -and $row.schema -isnot [long]) -or $row.schema -ne 1 -or $row.action -isnot [string] -or $row.action -cne 'cleanup' -or $row.stage -isnot [string] -or $row.stage -cnotin 'initialization','owned_service_lookup','realm_validation','admin_permissions','config_read','users_discovery','extension_update','policy_save','cache_refresh' -or $row.source_basename -isnot [string] -or $row.source_basename -cnotin $sources -or ($row.source_line -isnot [int] -and $row.source_line -isnot [long]) -or $row.source_line -le 0 -or $row.source_line -gt 100000 -or $row.error_type -isnot [string] -or $row.error_type -cnotmatch '^[A-Za-z0-9_]{1,80}$'){return $safe}
  foreach($key in 'action','stage','source_basename','source_line','error_type'){$safe['native_cleanup_fixture_'+$key]=$row.$key}
 }catch{}
 return $safe
}
function MeetingOwnerPageFields($Record){
 $safe=@{}
 if($Record.active_case -isnot [string] -or $Record.active_case -cne 'native_windows_meeting_owner_page'){return $safe}
 $status=$Record.meeting_owner_http_status;$route=$Record.meeting_owner_route
 if(($status -isnot [int] -and $status -isnot [long]) -or $status -lt 0 -or $status -gt 599 -or $route -isnot [string] -or $route -cnotin 'meet','login','logout','desktop','other'){return $safe}
 foreach($field in 'meeting_owner_login_form','meeting_owner_heading','meeting_owner_same_origin','meeting_owner_user_agent_matches'){if($Record.$field -isnot [bool]){return @{}}}
 $safe.meeting_owner_http_status=[int]$status;$safe.meeting_owner_route=$route
 foreach($field in 'meeting_owner_login_form','meeting_owner_heading','meeting_owner_same_origin','meeting_owner_user_agent_matches'){$safe[$field]=$Record.$field}
 return $safe
}
function MeetingMediaFields($Record){
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
 return @{meeting_media=$peers}
}
function MeetingSignalingFields($Record){
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
function MeetingPathFields($Record){
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
function SmtpFailureFields($Record){
 $safe=@{}
 if($Record.active_case -is [string] -and $Record.active_case -ceq 'native_welcome_inline_qr_config_actual_loopback'){
  if($Record.welcome_cleanup_failed -is [bool]){$safe.welcome_cleanup_failed=$Record.welcome_cleanup_failed}
  if($Record.welcome_phase -is [string] -and $Record.welcome_phase -cin 'input','database','bootstrap','queue','dispatch','inspect','suppress','cleanup' -and $Record.welcome_error_type -is [string] -and $Record.welcome_error_type -cin 'RuntimeException','PDOException','Error','TypeError','ValueError','JsonException','Exception' -and $Record.welcome_source_basename -is [string] -and $Record.welcome_source_basename -cin 'windows_welcome_native.php','pbx_mobile.php','pbx_mobile_welcome.php','email.php','outgoing_mail.php','email_send.php','database.php','config.php','settings.php','external_component' -and ($Record.welcome_source_line -is [int] -or $Record.welcome_source_line -is [long]) -and $Record.welcome_source_line -ge 1 -and $Record.welcome_source_line -le 100000 -and $Record.welcome_sqlstate -is [string] -and ($Record.welcome_sqlstate -ceq 'none' -or $Record.welcome_sqlstate -cmatch '^[A-Z0-9]{5}$')){foreach($field in 'welcome_phase','welcome_error_type','welcome_source_basename','welcome_source_line','welcome_sqlstate'){$safe[$field]=$Record.$field}}
  return $safe
 }
 if($Record.active_case -isnot [string] -or $Record.active_case -cne 'global_smtp_trusted_tls_hostname_auth'){return $safe}
 foreach($field in 'smtp_connection_check_passed','smtp_queue_observed'){if($Record.$field -is [bool]){$safe[$field]=$Record.$field}}
 foreach($field in 'smtp_delivery_count','smtp_envelope_count','smtp_session_count','smtp_authenticated_session_count','smtp_tls_accepted_count','smtp_tls_handshake_completed_count','smtp_tls_handshake_failed_count','smtp_seed_row_count','smtp_tick_maintenance_deferrals','smtp_tick_retry_count'){$value=$Record.$field;if(($value -is [int] -or $value -is [long]) -and $value -ge 0 -and $value -le 64){$safe[$field]=$value}}
 foreach($field in 'smtp_tick_selected','smtp_tick_processed'){$value=$Record.$field;if(($value -is [int] -or $value -is [long]) -and $value -ge 0 -and $value -le 10){$safe[$field]=$value}}
 $value=$Record.smtp_seed_retry_count;if(($value -is [int] -or $value -is [long]) -and $value -ge 0 -and $value -le 100){$safe.smtp_seed_retry_count=$value}
 $value=$Record.smtp_tick_exit;if(($value -is [int] -or $value -is [long]) -and $value -ge [int]::MinValue -and $value -le [int]::MaxValue){$safe.smtp_tick_exit=$value}
 foreach($pair in @(@('smtp_stage',@('save','connection_check','seed','dispatch','delivery')),@('smtp_tick_outcome',@('unrecognized','command_failed','command_timeout','deferred_maintenance','deferred_restore','unconfigured','processed')),@('smtp_tls_error_type',@('SSLError','TimeoutError','OSError','external_error')),@('smtp_seed_status',@('waiting','trying','sent','failed')),@('smtp_seed_response_class',@('none','configuration','certificate','authentication','connection','other')))){
  $value=$Record.($pair[0]);if($value -is [string] -and $value -cin $pair[1]){$safe[$pair[0]]=$value}
 }
 return $safe
}

function MediaFailureFields($Record){
 $safe=@{}
 if($Record.media_peer -isnot [string] -or $Record.media_peer -cnotin 'caller','destination' -or $Record.media_direction -isnot [string] -or $Record.media_direction -cnotin 'sent','received'){return $safe}
 $safe.media_peer=$Record.media_peer;$safe.media_direction=$Record.media_direction
 foreach($bound in @(@('media_window_seconds',.5,10),@('media_span_seconds',0,11),@('media_rate_pps',0,100000))){
  $value=$Record.($bound[0]);if(($value -is [double] -or $value -is [single] -or $value -is [int] -or $value -is [long]) -and ![double]::IsNaN([double]$value) -and ![double]::IsInfinity([double]$value) -and $value -ge $bound[1] -and $value -le $bound[2]){$safe[$bound[0]]=$value}
 }
 if(($Record.media_packets -is [int] -or $Record.media_packets -is [long]) -and $Record.media_packets -ge 0 -and $Record.media_packets -le 1000000){$safe.media_packets=$Record.media_packets}
 return $safe
}
function ProviderFailureFields($Record){
 $safe=@{}
 if($Record.active_case -isnot [string] -or $Record.active_case -cnotmatch '^native_provider_10[0-3]$'){return $safe}
 $value=$Record.provider_caller_response_code;if(($value -is [int] -or $value -is [long]) -and $value -ge 100 -and $value -le 699){$safe.provider_caller_response_code=$value}
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
 return $safe
}
function QueueFailureFields($Record){
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
function VoicemailFailureFields($Record){
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
function HotelFailureFields($Record){
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
function MailboxFailureFields($Record){
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
function FixtureBinding([byte[]]$Hash,[string]$Store,[switch]$Read){
 Add-Type -Path "$env:windir\System32\inetsrv\Microsoft.Web.Administration.dll"
 $manager=[Microsoft.Web.Administration.ServerManager]::new()
 try{
  $site=$manager.Sites['OpenWebPBX'];if(!$site){throw 'The installed fixture website is missing.'}
  $bindings=@($site.Bindings|Where-Object {$_.Protocol -eq 'https' -and $_.BindingInformation -eq '*:8443:windowsqa.example.invalid'})
  if($bindings.Count -ne 1){throw 'The exact owned local HTTPS binding is unavailable.'}
  $binding=$bindings[0]
  if($Read){return @{hash=[byte[]]$binding.CertificateHash;store=$binding.CertificateStoreName}}
  $binding.CertificateHash=$Hash;$binding.CertificateStoreName=$Store;$manager.CommitChanges()
 }finally{$manager.Dispose()}
}
function ConfigureFixturePhoneTls([string]$Thumbprint,[string]$Chain){
 # Server management runs in the same real Windows PowerShell 5.1 host used
 # by the installed manager/updater/tasks, never a PS7 compatibility proxy.
 $launcher=Join-Path $work 'configure-phone-tls.ps1';$request=Join-Path $work 'configure-phone-tls.json';$failure=Join-Path $evidence 'phone-tls-failure.json'
 [IO.File]::WriteAllText($request,(@{helper=(Join-Path $PackageRoot 'Enable-PhoneTLS.ps1');thumbprint=$Thumbprint;chain=$Chain;failure=$failure}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
 $launcherCode=@'
param([Parameter(Mandatory)][string]$InputPath)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$record=Get-Content -LiteralPath $InputPath -Raw|ConvertFrom-Json
try{& $record.helper -CertificateThumbprint $record.thumbprint -FullChainPath $record.chain}
catch{
 $basename=Split-Path -Leaf $_.InvocationInfo.ScriptName
 if($basename -notin 'Enable-PhoneTLS.ps1','Write-PrivateState.ps1','Restore-Gates.ps1'){$basename='external_component'}
 $safe=@{error_type=$_.Exception.GetType().Name;source_basename=$basename;source_line=[int]$_.InvocationInfo.ScriptLineNumber;active_case='phone_tls_helper'}
 # InvocationInfo can point at this generated launcher when a nested .NET
 # call fails. Keep only fixed exception types, numeric HRESULT and owned
 # source frames; exception messages/paths/certificate data remain private.
 $inner=$_.Exception;$depth=0
 while($inner.InnerException -and $depth -lt 8){$inner=$inner.InnerException;$depth++}
 $types=@('IOException','UnauthorizedAccessException','CryptographicException','Win32Exception','ArgumentException','InvalidOperationException','AuthenticationException','SocketException','TimeoutException','ObjectDisposedException','FileNotFoundException','DirectoryNotFoundException','SecurityException','NotSupportedException','Exception')
 $safe.phone_tls_inner_error_type=if($inner.GetType().Name -cin $types){$inner.GetType().Name}else{'other'}
 $safe.phone_tls_inner_hresult=([long]$inner.HResult -band 4294967295L)
 $safe.phone_tls_inner_depth=$depth
 $labels=@{
  'Windows could not verify the phone certificate chain.'='phone_tls_chain_validation'
  'Choose a current, exportable certificate issued by a trusted certificate authority.'='phone_tls_certificate_properties'
  'Set a public PBX hostname and trusted HTTPS certificate before enabling Android phones.'='phone_tls_configuration_hostname'
  'Secure phone setup failed.'='phone_tls_native_php_stage'
  'The phone certificate or TLS listener could not be verified for the public PBX hostname.'='phone_tls_listener_validation'
 }
 foreach($label in $labels.Keys){if($_.Exception.Message.Contains($label)){$safe.active_case=$labels[$label];break}}
 if($_.Exception.Data.Contains('OpenWebPhoneTLSBusy')){$safe.active_case='phone_tls_busy'}
 $phpFailure=$_.Exception.Data['OpenWebPhoneTLSPhpFailure']
 if($phpFailure -and $phpFailure.schema -eq 1 -and $phpFailure.source_basename -in 'phone-tls.php','phone-tls-chain.php','pbx_phone_auth.php','pbx_sip_domain.php','event_socket.php','config.php','database.php','external_component' -and [int]$phpFailure.source_line -gt 0 -and [int]$phpFailure.source_line -le 100000 -and $phpFailure.error_type -match '^[A-Za-z0-9_]{1,80}$' -and $phpFailure.stage -in 'idle','bind','resume','ready','apply','rollback','initialization'){
  $safe.source_basename=$phpFailure.source_basename;$safe.source_line=[int]$phpFailure.source_line;$safe.error_type=$phpFailure.error_type;$safe.active_case='phone_tls_php_'+$phpFailure.stage
 }
 # Fixed helper locations are useful; arguments and exception text stay private.
 $frames=[regex]::Matches($_.ScriptStackTrace,'([^\\/\r\n]+\.ps1): line ([0-9]+)')
 $owned=@($frames|Where-Object {$_.Groups[1].Value -cin 'Enable-PhoneTLS.ps1','Write-PrivateState.ps1','Restore-Gates.ps1'})
 if($owned.Count -and $safe.source_basename -ceq 'external_component'){$safe.source_basename=$owned[0].Groups[1].Value;$safe.source_line=[int]$owned[0].Groups[2].Value}
 if($owned.Count -gt 1){$safe.caller_basename=$owned[1].Groups[1].Value;$safe.caller_line=[int]$owned[1].Groups[2].Value}
 [IO.File]::WriteAllText($record.failure,($safe|ConvertTo-Json),[Text.UTF8Encoding]::new($false));exit 1
}
'@
 [IO.File]::WriteAllText($launcher,$launcherCode,[Text.UTF8Encoding]::new($false))
 $start=[Diagnostics.ProcessStartInfo]::new("$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe")
 $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $start.Environment['PSModulePath']=(Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules')+';'+(Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules')
 foreach($arg in @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$launcher,'-InputPath',$request)){$start.ArgumentList.Add($arg)}
 $process=[Diagnostics.Process]::Start($start)
 try{
  $output=$process.StandardOutput.ReadToEndAsync();$errors=$process.StandardError.ReadToEndAsync()
  if(!$process.WaitForExit(180000)){$process.Kill($true);throw 'The native phone TLS helper exceeded its bounded fixture time.'}
  [IO.File]::WriteAllText("$evidence\phone-tls-private.log",$output.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText("$evidence\phone-tls-private-errors.log",$errors.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($false))
  if($process.ExitCode -ne 0){
   $error=[InvalidOperationException]::new('Actual trusted fictional phone TLS setup did not pass.')
   if(Test-Path -LiteralPath $failure){$error.Data['NativeChildFailure']=Get-Content -LiteralPath $failure -Raw|ConvertFrom-Json}
   throw $error
  }
 }finally{$process.Dispose()}
}
function StartFixturePkiServer {
 $start=[Diagnostics.ProcessStartInfo]::new($python)
 $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 foreach($arg in @('-I',$script,'--input',$privateInput,'--phase','pki-server')){$start.ArgumentList.Add($arg)}
 $process=[Diagnostics.Process]::Start($start)
 $script:pkiOutput=$process.StandardOutput.ReadToEndAsync();$script:pkiErrors=$process.StandardError.ReadToEndAsync()
 return $process
}
$paths=@('fusion-config.conf','phone-tls.json','phone-tls','mobile-notifications-config','mobile-notifications-lock','php-cacert')
$originalFiles=@{ 'fusion-config.conf'=(Join-Path $env:ProgramData 'fusionpbx\config.conf');'phone-tls.json'="$state\phone-tls.json";'phone-tls'="$state\phone-tls";'mobile-notifications-config'="$state\mobile-notifications\config.json";'mobile-notifications-lock'="$state\mobile-notifications\config.json.lock";'php-cacert'="$root\php\extras\ssl\cacert.pem" }
$originalPresent=@{};$originalAcl=@{};$parentAcl=(Get-Acl -LiteralPath $state).Sddl
$notificationTask='OpenWebPBX Native Notification Read '+$scope
try{
 $result=Php 'baseline'|ConvertFrom-Json;if($result.factory_empty -isnot [bool] -or !$result.factory_empty){throw 'Native qualification requires an empty factory.'};$baseline=$true;$facts.native_factory_empty_before_fixture=$true
 foreach($name in $paths){$path=$originalFiles[$name];$present=Test-Path -LiteralPath $path;$originalPresent[$name]=$present;if($present){$originalAcl[$name]=(Get-Acl -LiteralPath $path).Sddl;Copy-Item -LiteralPath $path -Destination (Join-Path $saved $name) -Recurse}}
 $phase='actual Windows RTP socket reset and recovery'
 & $python -I (Join-Path $source 'tests/windows_rtp_socket.py') 1>>"$evidence\private-python.log" 2>>"$evidence\private-python-errors.log"
 if($LASTEXITCODE){throw 'Actual Windows UDP reset/recovery controls did not pass.'}
 $phase='actual Windows voicemail language filesystem defaults'
 & "$root\php\php.exe" (Join-Path $source 'tests/windows_voicemail_defaults.php') $source 1>>"$evidence\private-php.log" 2>>"$evidence\private-php-errors.log"
 if($LASTEXITCODE){throw 'Actual Windows voicemail defaults did not pass.'}
 $phase='generated fictional local PKI';Python 'prepare-pki'
 $pkiProcess=StartFixturePkiServer
 for($i=0;$i -lt 50 -and !(Test-Path "$evidence\pki-ready.json") -and !$pkiProcess.HasExited;$i++){Start-Sleep -Milliseconds 100}
 if($pkiProcess.HasExited){$facts.command_basename='python.exe';$facts.command_exit=$pkiProcess.ExitCode;throw 'Owned loopback certificate-revocation fixture exited before becoming ready.'}
 if(!(Test-Path "$evidence\pki-ready.json")){throw 'Owned loopback certificate-revocation fixture did not start.'}
 [IO.File]::AppendAllText("$root\php\extras\ssl\cacert.pem","`r`n"+[IO.File]::ReadAllText("$evidence\fixture-root.pem"),[Text.UTF8Encoding]::new($false))
 $privatePki=Get-Content "$evidence\pki-private.json" -Raw|ConvertFrom-Json
 $rootCertificate=Import-Certificate -FilePath "$evidence\fixture-root.cer" -CertStoreLocation Cert:\LocalMachine\Root
 $leaf=Import-PfxCertificate -FilePath "$evidence\fixture.pfx" -CertStoreLocation Cert:\LocalMachine\My -Password (ConvertTo-SecureString $privatePki.password -AsPlainText -Force) -Exportable
 $originalBinding=FixtureBinding -Read;$binding=$true
 FixtureBinding -Hash ([Convert]::FromHexString($leaf.Thumbprint)) -Store 'My'
 ConfigureFixturePhoneTls -Thumbprint $leaf.Thumbprint -Chain "$evidence\fixture-chain.pem"
 $facts.checks+='Generated local-PKI chain, Windows trust and real HTTPS/SIP TLS listeners; no public ACME claim'
 $phase='normal HTTPS and native calling';Python 'acceptance'
 $native=Get-Content "$evidence\software-native-report.json" -Raw|ConvertFrom-Json
 if(($native.schema -isnot [int] -and $native.schema -isnot [long]) -or $native.schema -ne 1 -or $native.producer -isnot [string] -or $native.producer -cne 'windows-native-acceptance.py' -or $native.state -isnot [string] -or $native.state -cne 'passed' -or $native.checks -isnot [array] -or $native.checks.Count -gt 256){throw 'Actual software native matrix failed.'}
 AssertExtendedNativeCases $native.checks
 AssertWelcomeNativeCase $native.checks
 $facts.gates.native_clock='passed';$facts.gates.native_providers='passed';$facts.gates.native_call_me_back='passed'
 $facts.checks=@($native.checks);$facts.gates.native_sip_audio='passed';$facts.gates.smtp='passed'
 $meeting=@($native.checks|Where-Object {$_.case -ceq 'native_windows_meeting_browser_video_audio'})
 if($meeting.Count -ne 1 -or $meeting[0].passed -isnot [bool] -or !$meeting[0].passed -or $meeting[0].checks -ne 9 -or $meeting[0].wss_roundtrips -ne 16 -or $meeting[0].host_frames -lt 10 -or $meeting[0].guest_frames -lt 10 -or $meeting[0].host_tone_ratio -le .65 -or $meeting[0].guest_tone_ratio -le .65 -or $meeting[0].physical_camera -cne 'unqualified'){throw 'Actual fragmented SIP round trips, browser meeting video and independent two-way audio must pass.'}
 $facts.gates.meeting_browser='passed'
 # Execute the exact production reader's sharing/access pattern under LOCAL SERVICE.
 # No endpoint/device is enrolled, so this probe sends no notification.
 $config="$state\mobile-notifications\config.json";$probe="$work\read-notification.ps1";$probeResult="$work\read-notification-result.json"
 [IO.File]::WriteAllText($probe,@"
`$ErrorActionPreference='Stop'
try {
 `$stream=[IO.File]::Open('$config','Open','Read',[IO.FileShare]'ReadWrite,Delete')
 try {`$reader=[IO.StreamReader]::new(`$stream);`$value=`$reader.ReadToEnd()|ConvertFrom-Json;if(!`$value.enabled -or !`$value.vapid_private_key){throw 'Native keys unavailable'}} finally {`$stream.Dispose()}
 `$parentWriteDenied=`$false
 try{[IO.File]::WriteAllText('$state\unexpected-localservice-$scope','invalid')}catch [UnauthorizedAccessException]{`$parentWriteDenied=`$true}
 if(!`$parentWriteDenied){throw 'Containing state directory became writable'}
 [IO.File]::WriteAllText('$probeResult','{"passed":true,"actual_identity":"LOCAL SERVICE","parent_write_denied":true}')
}catch{exit 1}
"@,[Text.UTF8Encoding]::new($false))
 & icacls.exe $work /grant '*S-1-5-19:(RX)'|Out-Null;& icacls.exe $probe /grant '*S-1-5-19:(R)'|Out-Null
 # Result lives in a dedicated writable child, never the containing state directory.
 $readChild=Join-Path $work 'reader';New-Item -ItemType Directory -Path $readChild|Out-Null;& icacls.exe $readChild /grant '*S-1-5-19:(OI)(CI)M'|Out-Null
 $probeResult=Join-Path $readChild 'result.json';$text=[IO.File]::ReadAllText($probe).Replace("$work\read-notification-result.json",$probeResult);[IO.File]::WriteAllText($probe,$text,[Text.UTF8Encoding]::new($false))
 $taskAction=New-ScheduledTaskAction -Execute "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument ('-NoProfile -NonInteractive -File "'+$probe+'"')
 $principal=New-ScheduledTaskPrincipal -UserId 'S-1-5-19' -LogonType ServiceAccount
 Register-ScheduledTask -TaskName $notificationTask -Action $taskAction -Principal $principal|Out-Null;Start-ScheduledTask -TaskName $notificationTask
 for($i=0;$i -lt 100 -and !(Test-Path $probeResult);$i++){Start-Sleep -Milliseconds 100}
 if(!(Test-Path $probeResult) -or !(Get-Content $probeResult -Raw|ConvertFrom-Json).passed){throw 'Actual LOCAL SERVICE cannot read normal IIS-generated notification identity.'}
 if((Get-Acl -LiteralPath $state).Sddl -ne $parentAcl){throw 'Containing private-state ACL changed.'}
 $service=Get-CimInstance Win32_Service -Filter "Name='OpenWebPBX'";if($service.StartName -notin 'NT AUTHORITY\LocalService','NT AUTHORITY\LOCAL SERVICE'){throw 'Native background service uses an unexpected identity.'}
 $facts.checks+='Actual LOCAL SERVICE reads IIS-generated stable keys with parent write denied; production C# reader source tested separately; no delivery sent'
 $facts.completed_media_cases=@('native_localservice_notification_store_reader')
 $facts.gates.notification_store='passed';$nativePassed=$true
}catch{
 $errorType=$_.Exception.GetType().Name;$facts.state='failed';$facts.failed_phase=$phase;$facts.error_type=$errorType
 $facts.source_basename='windows-native-acceptance.ps1';$facts.source_line=$_.InvocationInfo.ScriptLineNumber;$facts.active_case=$phase.Replace(' ','_')
 $nativeFailure=$_.Exception.Data['NativeChildFailure']
 if($nativeFailure -and $nativeFailure.source_basename -in 'Enable-PhoneTLS.ps1','Write-PrivateState.ps1','Restore-Gates.ps1','phone-tls.php','phone-tls-chain.php','pbx_phone_auth.php','pbx_sip_domain.php','event_socket.php','config.php','database.php','external_component' -and [int]$nativeFailure.source_line -gt 0 -and [int]$nativeFailure.source_line -le 100000 -and $nativeFailure.active_case -match '^phone_tls_[a-z_]+$' -and $nativeFailure.error_type -match '^[A-Za-z0-9_]{1,80}$'){
  $facts.source_basename=$nativeFailure.source_basename;$facts.source_line=[int]$nativeFailure.source_line;$facts.active_case=$nativeFailure.active_case;$facts.error_type=$nativeFailure.error_type
  if($nativeFailure.phone_tls_inner_error_type -is [string] -and $nativeFailure.phone_tls_inner_error_type -cin 'IOException','UnauthorizedAccessException','CryptographicException','Win32Exception','ArgumentException','InvalidOperationException','AuthenticationException','SocketException','TimeoutException','ObjectDisposedException','FileNotFoundException','DirectoryNotFoundException','SecurityException','NotSupportedException','Exception','other'){$facts.phone_tls_inner_error_type=$nativeFailure.phone_tls_inner_error_type}
  foreach($field in 'phone_tls_inner_hresult','phone_tls_inner_depth'){$value=$nativeFailure.$field;$maximum=if($field -ceq 'phone_tls_inner_depth'){8}else{4294967295L};if(($value -is [int] -or $value -is [long]) -and $value -ge 0 -and $value -le $maximum){$facts[$field]=$value}}
  if($nativeFailure.caller_basename -in 'Enable-PhoneTLS.ps1','Write-PrivateState.ps1','Restore-Gates.ps1' -and [int]$nativeFailure.caller_line -gt 0){$facts.caller_basename=$nativeFailure.caller_basename;$facts.caller_line=[int]$nativeFailure.caller_line}
 }
 $childReport=Join-Path $evidence 'software-native-report.json'
 if(Test-Path -LiteralPath $childReport){
  try{
   $child=Get-Content -LiteralPath $childReport -Raw|ConvertFrom-Json
   if($child.state -eq 'failed' -and $child.source_basename -in 'windows-native-acceptance.py','pbx_v20_restore_native.py','sip_trunk_live.py','windows_native_services.py','windows_clock_native.py','pbx_talking_clock_native.py','windows-native-fixture.php','permissions.php','database.php','pbx_admin.php','pbx_setup.php','pbx_setup_provisioner.php','pbx_tenants.php','pbx_paths.php','pbx_mapper.php','pbx_schedule.php','pbx_operations.php','pbx_native.php','pbx_phone_auth.php','pbx_sip_domain.php','config.php','event_socket.php','cache.php','external_component' -and [int]$child.source_line -gt 0 -and [int]$child.source_line -le 100000 -and $child.active_case -match '^[a-z0-9_]{1,120}$' -and $child.error_type -match '^[A-Za-z0-9_]{1,80}$'){
    $facts.source_basename=$child.source_basename;$facts.source_line=[int]$child.source_line;$facts.active_case=$child.active_case;$facts.error_type=$child.error_type
    $completed=@(CompletedMediaCases $child.checks);if($completed.Count){$facts.completed_media_cases=$completed}
    foreach($entry in (MediaFailureFields $child).GetEnumerator()){$facts[$entry.Key]=$entry.Value}
    foreach($entry in (ProviderFailureFields $child).GetEnumerator()){$facts[$entry.Key]=$entry.Value}
    foreach($entry in (QueueFailureFields $child).GetEnumerator()){$facts[$entry.Key]=$entry.Value}
    foreach($entry in (VoicemailFailureFields $child).GetEnumerator()){$facts[$entry.Key]=$entry.Value}
    foreach($entry in (MailboxFailureFields $child).GetEnumerator()){$facts[$entry.Key]=$entry.Value}
    foreach($entry in (HotelFailureFields $child).GetEnumerator()){$facts[$entry.Key]=$entry.Value}
    foreach($entry in (SmtpFailureFields $child).GetEnumerator()){$facts[$entry.Key]=$entry.Value}
    foreach($entry in (MeetingOwnerPageFields $child).GetEnumerator()){$facts[$entry.Key]=$entry.Value}
    foreach($entry in (MeetingMediaFields $child).GetEnumerator()){$facts[$entry.Key]=$entry.Value}
    foreach($entry in (MeetingSignalingFields $child).GetEnumerator()){$facts[$entry.Key]=$entry.Value}
 foreach($entry in (MeetingPathFields $child).GetEnumerator()){$facts[$entry.Key]=$entry.Value}
    if($child.active_case -match '^(native_media_peer_(udp|tcp|tls)_registration_[0-2]|independent_g729_(offer_refused|answer_payload_mismatch))$'){
     if(($child.sip_response_code -is [int] -or $child.sip_response_code -is [long]) -and $child.sip_response_code -ge 200 -and $child.sip_response_code -le 699){$facts.sip_response_code=[int]$child.sip_response_code}
     if(($child.digest_challenge_count -is [int] -or $child.digest_challenge_count -is [long]) -and $child.digest_challenge_count -ge 0 -and $child.digest_challenge_count -le 3){$facts.digest_challenge_count=[int]$child.digest_challenge_count}
     if($child.active_case -match '^independent_g729_' -and ($child.negotiated_payload_type -is [int] -or $child.negotiated_payload_type -is [long]) -and $child.negotiated_payload_type -ge 0 -and $child.negotiated_payload_type -le 127){$facts.negotiated_payload_type=[int]$child.negotiated_payload_type}
    }
    if($child.active_case -eq 'normal_admin_owned_extension_audio_preferences'){
     foreach($field in 'owned_domain_matches','authentication_id_matches','sip_password_matches'){if($child.$field -is [bool]){$facts[$field]=[bool]$child.$field}}
    }
    $nativeStages=@('native_case','g729_regular_unregister','g729_alternate_register','g729_invite','g729_answer_validation','g729_remote_answer','g729_media','g729_peer_receiver','g729_hangup','g729_alternate_unregister','g729_peer_close','g729_codec_close','g729_regular_reregister','native_peer_unregister','native_peer_close','native_ledger_write','callback_request_created','callback_agent_answer','callback_target_answer','callback_job_completed','hotel_phone_answer','hotel_wire_confirmation','hotel_job_completed','voicemail_message_created','voicemail_recording_finalized','voicemail_mail_queued','mailbox_register','mailbox_invite','mailbox_login_prompt','mailbox_main_menu_prompt','mailbox_tutorial_complete','mailbox_recording_playback','mailbox_forward_extension_prompt','mailbox_forward_intro_prompt','mailbox_forwarded_prompt','mailbox_forwarded_message_created','mailbox_forwarded_binary_copy','mailbox_observer_close')
    foreach($prefix in 'primary','cleanup'){
     if($child.($prefix+'_substage') -isnot [string] -or $child.($prefix+'_substage') -cnotin $nativeStages){continue}
     $facts[$prefix+'_substage']=$child.($prefix+'_substage')
     $type=$child.($prefix+'_error_type');if($type -is [string] -and $type -match '^[A-Za-z0-9_]{1,80}$'){$facts[$prefix+'_error_type']=$type}
     foreach($where in 'source','caller'){
      $name=$child.($prefix+'_'+$where+'_basename');$line=$child.($prefix+'_'+$where+'_line')
      if($name -in 'windows-native-acceptance.py','pbx_v20_restore_native.py','sip_trunk_live.py','windows_native_services.py','windows_clock_native.py','pbx_talking_clock_native.py','external_component' -and ($line -is [int] -or $line -is [long]) -and $line -gt 0 -and $line -lt 100000){$facts[$prefix+'_'+$where+'_basename']=$name;$facts[$prefix+'_'+$where+'_line']=[int]$line}
     }
    }
    if(($child.cleanup_failure_count -is [int] -or $child.cleanup_failure_count -is [long]) -and $child.cleanup_failure_count -ge 1 -and $child.cleanup_failure_count -le 32){$facts.cleanup_failure_count=[int]$child.cleanup_failure_count}
   }
  }catch{}
 }
}
finally{
 $phase='exact scoped cleanup'
 $cleanupStage='stop_notification_task'
 try{
  Stop-ScheduledTask -TaskName $notificationTask -ErrorAction SilentlyContinue
  $cleanupStage='remove_notification_task';Unregister-ScheduledTask -TaskName $notificationTask -Confirm:$false -ErrorAction SilentlyContinue
  $cleanupStage='restore_factory'
  if($baseline){$clean=Php 'cleanup'|ConvertFrom-Json;if($clean.cleanup_reloadxml -is [string] -and $clean.cleanup_reloadxml -cin 'success','error','empty','other'){$facts.native_cleanup_reloadxml=$clean.cleanup_reloadxml};if(!$clean.factory_empty -or $clean.owned_rows -ne 0 -or $clean.owned_contacts -ne 0){throw 'Native fixture cleanup is incomplete.'};if($clean.normal_login_bcrypt_rehash_proved){if(!$clean.original_factory_hash_restored){throw 'Original factory password hash was not restored.'};$facts.checks+='Normal generated-factory login bcrypt12-to-10 rehash proved with unchanged password, then original hash restored during cleanup'}}
  $cleanupStage='restore_binding';if($binding -and $originalBinding){FixtureBinding -Hash $originalBinding.hash -Store $originalBinding.store}
  $cleanupStage='restore_files'
  foreach($name in $paths){$path=$originalFiles[$name];if($originalPresent.ContainsKey($name)){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force};if($originalPresent[$name]){Copy-Item -LiteralPath (Join-Path $saved $name) -Destination $path -Recurse;$acl=Get-Acl -LiteralPath $path;$acl.SetSecurityDescriptorSddlForm($originalAcl[$name]);Set-Acl -LiteralPath $path -AclObject $acl}}}
  $cleanupStage='restart_engine';if($baseline){$restartWindow=New-NativeRestartWindow 'C:/Program Files/FreeSWITCH/log/freeswitch.log';Restart-Service FreeSWITCH;for($i=0;$i -lt 50 -and (Get-Service FreeSWITCH).Status -ne 'Running';$i++){Start-Sleep -Milliseconds 100};if((Get-Service FreeSWITCH).Status -ne 'Running'){throw 'Original factory call engine did not resume.'}}
  $cleanupStage='remove_leaf';if($leaf){Remove-Item -LiteralPath ('Cert:\LocalMachine\My\'+$leaf.Thumbprint) -Force}
  $cleanupStage='remove_root';if($rootCertificate){Remove-Item -LiteralPath ('Cert:\LocalMachine\Root\'+$rootCertificate.Thumbprint) -Force}
  $cleanupStage='stop_pki'
  if($pkiProcess){
   if(!$pkiProcess.HasExited){Stop-Process -Id $pkiProcess.Id -Force}
   if(!$pkiProcess.WaitForExit(5000)){throw 'Owned certificate-revocation fixture did not stop.'}
   $cleanupStage='collect_pki_logs'
   [IO.File]::WriteAllText("$evidence\pki-stdout.log",$pkiOutput.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($false))
   [IO.File]::WriteAllText("$evidence\pki-stderr.log",$pkiErrors.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($false))
   $pkiProcess.Dispose()
  }
  $cleanupStage='parent_write_guard';if(Test-Path "$state\unexpected-localservice-$scope"){Remove-Item "$state\unexpected-localservice-$scope" -Force;throw 'LOCAL SERVICE incorrectly wrote containing state.'}
  $cleanupPassed=$true;$facts.gates.cleanup='passed';$facts.cleanup='Original factory rows/contacts/identity/profile/config/certificate binding restored; owned CA/leaf and private probe task removed'
 }catch{
  $cleanupPassed=$false;RecordNativeCleanupFailure $facts $cleanupStage $_
  if($cleanupStage -ceq 'restart_engine'){try{foreach($entry in (Get-NativeRestartObservation $restartWindow 'C:/Program Files/FreeSWITCH/log/freeswitch.log' $evidence $_ $originalFiles $originalPresent $saved).GetEnumerator()){$facts[$entry.Key]=$entry.Value}}catch{}}
  if($cleanupStage -ceq 'restore_factory'){foreach($entry in (NativeCleanupFixtureFields $privateInput).GetEnumerator()){$facts[$entry.Key]=$entry.Value}}
 }
 CollectNativeProgress $facts $evidence
 if($null -eq $envBefore){Remove-Item Env:\OPENWEB_WINDOWS_NATIVE_TEST -ErrorAction SilentlyContinue}else{$env:OPENWEB_WINDOWS_NATIVE_TEST=$envBefore}
 if($null -eq $opensslBefore){Remove-Item Env:\OPENSSL_CONF -ErrorAction SilentlyContinue}else{$env:OPENSSL_CONF=$opensslBefore}
 if($nativePassed -and $cleanupPassed){$facts.state='passed'}
 [IO.File]::WriteAllText($ReportPath,($facts|ConvertTo-Json -Depth 14),[Text.UTF8Encoding]::new($false))
}
if($facts.state -ne 'passed'){throw 'Windows native acceptance did not pass. Review private evidence; factory cleanup must pass before backups.'}
Write-Host 'Actual fictional Windows native calling, SMTP, notification storage and factory cleanup passed.'
