# Bounded actual caller allowlist controls. No Windows/PBX runtime is invoked.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-suite.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The reviewed caller must parse.'}
$queueNodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'SafeQueueFailureFields'},$true))
if($queueNodes.Count -ne 1){throw 'The actual caller queue filter must be uniquely identified.'}
Invoke-Expression $queueNodes[0].Extent.Text
$nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'SafeFailureFields'},$true))
if($nodes.Count -ne 1){throw 'The actual caller allowlist must be uniquely identified.'}
Invoke-Expression $nodes[0].Extent.Text
$nativeAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-native-acceptance.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The reviewed native hook must parse.'}
$mediaNodes=@($nativeAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'CompletedMediaCases'},$true))
if($mediaNodes.Count -ne 1){throw 'The actual completed-media filter must be uniquely identified.'}
Invoke-Expression $mediaNodes[0].Extent.Text
$failureNodes=@($nativeAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'MediaFailureFields'},$true))
if($failureNodes.Count -ne 1){throw 'The actual native media failure filter must be uniquely identified.'}
Invoke-Expression $failureNodes[0].Extent.Text
$queueNodes=@($nativeAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'QueueFailureFields'},$true))
if($queueNodes.Count -ne 1){throw 'The actual native queue filter must be uniquely identified.'}
Invoke-Expression $queueNodes[0].Extent.Text
foreach($pair in @(@($ast,'SafeVoicemailFailureFields'),@($nativeAst,'VoicemailFailureFields'),@($ast,'SafeMailboxFailureFields'),@($nativeAst,'MailboxFailureFields'))){
 $voicemailNodes=@($pair[0].FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $pair[1]},$true))
 if($voicemailNodes.Count -ne 1){throw 'The actual voicemail/mailbox filter must be uniquely identified.'}
 Invoke-Expression $voicemailNodes[0].Extent.Text
}
$checks=0
function Check([bool]$Value){if(!$Value){throw 'The bounded native failure field check failed.'};$script:checks++}
$record=[pscustomobject]@{
 active_case='independent_g729_pcmu_transcoding';error_type='AssertionError';source_basename='pbx_v20_restore_native.py';source_line=236
 primary_substage='g729_peer_receiver';primary_error_type='AssertionError';primary_source_basename='windows-native-acceptance.py';primary_source_line=384;primary_caller_basename='windows-native-acceptance.py';primary_caller_line=653
 cleanup_substage='g729_alternate_unregister';cleanup_error_type='RuntimeError';cleanup_source_basename='pbx_v20_restore_native.py';cleanup_source_line=236;cleanup_caller_basename='windows-native-acceptance.py';cleanup_caller_line=661;cleanup_failure_count=2
 password='private-never-copy';error='private-never-copy';native_packets='private-never-copy'
}
$safe=SafeFailureFields $record
foreach($field in 'primary_substage','primary_error_type','primary_source_basename','primary_source_line','primary_caller_basename','primary_caller_line','cleanup_substage','cleanup_error_type','cleanup_source_basename','cleanup_source_line','cleanup_caller_basename','cleanup_caller_line','cleanup_failure_count'){Check ($safe[$field] -eq $record.$field)}
Check (!$safe.ContainsKey('password') -and !$safe.ContainsKey('error') -and !$safe.ContainsKey('native_packets'))
foreach($prefix in 'primary','cleanup'){
 $copy=$record.PSObject.Copy();$copy.($prefix+'_substage')='secret-shaped-unknown-stage';$filtered=SafeFailureFields $copy
 Check (!$filtered.ContainsKey($prefix+'_substage') -and !$filtered.ContainsKey($prefix+'_error_type') -and !$filtered.ContainsKey($prefix+'_source_basename'))
 $copy=$record.PSObject.Copy();$copy.($prefix+'_error_type')='secret message with spaces';Check (!(SafeFailureFields $copy).ContainsKey($prefix+'_error_type'))
 foreach($where in 'source','caller'){
  $copy=$record.PSObject.Copy();$copy.($prefix+'_'+$where+'_basename')='secret-file-name';Check (!(SafeFailureFields $copy).ContainsKey($prefix+'_'+$where+'_basename'))
  $copy=$record.PSObject.Copy();$copy.($prefix+'_'+$where+'_line')='384';Check (!(SafeFailureFields $copy).ContainsKey($prefix+'_'+$where+'_line'))
  $copy=$record.PSObject.Copy();$copy.($prefix+'_'+$where+'_line')=100000;Check (!(SafeFailureFields $copy).ContainsKey($prefix+'_'+$where+'_line'))
 }
}
foreach($bad in '2',0,33,$true){$copy=$record.PSObject.Copy();$copy.cleanup_failure_count=$bad;Check (!(SafeFailureFields $copy).ContainsKey('cleanup_failure_count'))}
$allowed=@('native_tls_signalling_two_way_decoded_rtp','native_g729_pcmu_independent_codec_two_way_transcoding','native_simultaneous_ring_group','native_hunting_ring_group','native_queue_agent_first','native_ivr_negotiated_wire_rfc2833','native_visible_sip_hold_selected_music_resume_transfer','native_configured_ivr_timeout','native_queue_pause_logout_wire_callback_localservice_agent_first_decoded_rtp','native_hotel_wakeup_localservice_claim_wire_confirmation','native_voicemail_recording_private_owned_wav')
$childChecks=@(foreach($name in $allowed){[pscustomobject]@{case=$name;passed=$true;password='private-never-copy';decoded_ratio=.99;error='private-never-copy'}})
$completed=@(CompletedMediaCases $childChecks)
Check (($completed -join '|') -ceq ($allowed -join '|'))
foreach($name in $allowed){
 foreach($bad in $false,'true',1,$null){Check (@(CompletedMediaCases @([pscustomobject]@{case=$name;passed=$bad})).Count -eq 0)}
}
foreach($bad in 'private-never-copy',$allowed[0].ToUpperInvariant(),($allowed[0]+' '),($allowed[0]+'_secret'),1,$true,@($allowed[0]),[pscustomobject]@{value=$allowed[0]}){
 Check (@(CompletedMediaCases @([pscustomobject]@{case=$bad;passed=$true})).Count -eq 0)
}
Check (@(CompletedMediaCases @([pscustomobject]@{case=$allowed[0]},$null,'private-never-copy')).Count -eq 0)
Check ((@(CompletedMediaCases @($childChecks[0],$childChecks[0])) -join '|') -ceq $allowed[0])
$partial=[pscustomobject]@{completed_media_cases=$completed;checks=$childChecks;password='private-never-copy';metrics=@{private='private-never-copy'}}
$filtered=SafeFailureFields $partial
Check ($filtered.Count -eq 1 -and ($filtered.completed_media_cases -join '|') -ceq ($allowed -join '|'))
Check (($filtered|ConvertTo-Json -Depth 8) -notmatch 'private-never-copy|decoded_ratio|password|metrics')
foreach($bad in 'private-never-copy',$allowed[0].ToUpperInvariant(),($allowed[0]+' '),($allowed[0]+'_secret'),1,$true,@($allowed[0]),[pscustomobject]@{case=$allowed[0];passed=$true}){
 $invalid=[pscustomobject]@{completed_media_cases=[object[]]::new(1)};$invalid.completed_media_cases[0]=$bad
 Check (!(SafeFailureFields $invalid).ContainsKey('completed_media_cases'))
}
$mixed=SafeFailureFields ([pscustomobject]@{completed_media_cases=@('private-never-copy',$allowed[4],$allowed[4],$allowed[0]);checks=$childChecks})
Check (($mixed.completed_media_cases -join '|') -ceq ($allowed[0]+'|'+$allowed[4]) -and $mixed.Count -eq 1)
Check (!(SafeFailureFields ([pscustomobject]@{checks=$childChecks})).ContainsKey('completed_media_cases'))
$media=[pscustomobject]@{media_peer='caller';media_direction='received';media_window_seconds=5.0;media_span_seconds=4.98;media_rate_pps=49.9;media_packets=250;media_window_private='private-never-copy';password='private-never-copy';decoded_pcm='private-never-copy'}
foreach($filter in 'MediaFailureFields','SafeFailureFields'){
 $safe=& $filter $media
 Check ($safe.Count -eq 6 -and ($safe|ConvertTo-Json) -notmatch 'private-never-copy|password|decoded_pcm|media_window_private')
 foreach($field in 'media_peer','media_direction','media_window_seconds','media_span_seconds','media_rate_pps','media_packets'){Check ($safe[$field] -ceq $media.$field)}
 foreach($field in 'media_peer','media_direction'){
  foreach($bad in 'secret-shaped-value',$media.$field.ToUpperInvariant(),1,$true,$null){$copy=$media.PSObject.Copy();$copy.$field=$bad;Check ((& $filter $copy).Count -eq 0)}
 }
 foreach($field in 'media_window_seconds','media_span_seconds','media_rate_pps'){
  foreach($bad in '5',$true,[double]::NaN,[double]::PositiveInfinity,[double]::NegativeInfinity,-1,1000001){$copy=$media.PSObject.Copy();$copy.$field=$bad;Check (!(& $filter $copy).ContainsKey($field))}
 }
 foreach($bad in '250',$true,1.5,-1,1000001){$copy=$media.PSObject.Copy();$copy.media_packets=$bad;Check (!(& $filter $copy).ContainsKey('media_packets'))}
 foreach($pair in @(@('media_window_seconds',.49),@('media_window_seconds',10.01),@('media_span_seconds',11.01),@('media_rate_pps',100000.01))){$copy=$media.PSObject.Copy();$copy.($pair[0])=$pair[1];Check (!(& $filter $copy).ContainsKey($pair[0]))}
}
$queue=[pscustomobject]@{active_case='queue_agent_delivery';queue_diagnostics_complete=$false;queue_before_config_matches=$true;queue_after_queue_readable=$false;queue_after_waiting_members=0;queue_before_expected_registered=$true;queue_before_expected_busy_channels=1;queue_after_other_invites=1;queue_after_other_acks=0;queue_after_other_ended=1;queue_before_expected_tier_position=2;queue_after_expected_status='Available';queue_after_other_state='Receiving';queue_after_expected_tier_state='Ready';queue_after_cancel_reason='TIMEOUT';queue_after_originate_cause='USER_BUSY';queue_after_contact='private-never-copy';queue_after_expected_auth='private-never-copy';password='private-never-copy'}
$knownQueue=@('queue_diagnostics_complete','queue_before_config_matches','queue_after_queue_readable','queue_after_waiting_members','queue_before_expected_registered','queue_before_expected_busy_channels','queue_after_other_invites','queue_after_other_acks','queue_after_other_ended','queue_before_expected_tier_position','queue_after_expected_status','queue_after_other_state','queue_after_expected_tier_state','queue_after_cancel_reason','queue_after_originate_cause')
foreach($filter in 'QueueFailureFields','SafeQueueFailureFields','SafeFailureFields'){
 $safe=& $filter $queue
 foreach($field in $knownQueue){Check ($safe.ContainsKey($field) -and $safe[$field] -ceq $queue.$field)}
 Check (($safe|ConvertTo-Json) -notmatch 'private-never-copy|password|expected_auth|queue_after_contact')
 foreach($bad in 'queue_agent_delivery ','QUEUE_AGENT_DELIVERY','basic_decoded_audio',$null){
  $copy=$queue.PSObject.Copy();$copy.active_case=$bad;$safe=& $filter $copy
  Check (@($safe.Keys|Where-Object {$_ -like 'queue_*'}).Count -eq 0)
 }
 foreach($field in 'queue_diagnostics_complete','queue_before_config_matches','queue_before_expected_registered'){
  foreach($bad in 'true',1,$null,@{private='private-never-copy'}){$copy=$queue.PSObject.Copy();$copy.$field=$bad;Check (!(& $filter $copy).ContainsKey($field))}
 }
 foreach($field in 'queue_after_waiting_members','queue_before_expected_busy_channels','queue_after_other_invites','queue_after_other_acks','queue_after_other_ended'){
  foreach($bad in '1',$true,1.5,-1,65,[double]::NaN,[double]::PositiveInfinity){$copy=$queue.PSObject.Copy();$copy.$field=$bad;Check (!(& $filter $copy).ContainsKey($field))}
 }
 foreach($bad in '2',$true,1.5,-1,1001){$copy=$queue.PSObject.Copy();$copy.queue_before_expected_tier_position=$bad;Check (!(& $filter $copy).ContainsKey('queue_before_expected_tier_position'))}
 foreach($field in 'queue_after_expected_status','queue_after_other_state','queue_after_expected_tier_state','queue_after_cancel_reason','queue_after_originate_cause'){
  foreach($bad in 'private-never-copy',$queue.$field.ToLowerInvariant(),1,$true,@{private='private-never-copy'}){$copy=$queue.PSObject.Copy();$copy.$field=$bad;Check (!(& $filter $copy).ContainsKey($field))}
 }
 $copy=$queue.PSObject.Copy();$copy.queue_before_expected_tier_position=1000;$copy.queue_after_other_invites=64
 $safe=& $filter $copy;Check ($safe.queue_before_expected_tier_position -eq 1000 -and $safe.queue_after_other_invites -eq 64)
}
$callbackStages=@('callback_request_created','callback_agent_answer','callback_target_answer','callback_job_completed')
$stageNodes=@($nativeAst.FindAll({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [Management.Automation.Language.VariableExpressionAst] -and $n.Left.VariablePath.UserPath -eq 'nativeStages'},$true))
Check ($stageNodes.Count -eq 1)
$nativeStages=Invoke-Expression $stageNodes[0].Right.Extent.Text
foreach($stage in $callbackStages){
 Check ($stage -cin $nativeStages)
 $copy=$record.PSObject.Copy();$copy.primary_substage=$stage;Check ((SafeFailureFields $copy).primary_substage -ceq $stage)
}
$callback=[pscustomobject]@{active_case='queue_pause_logout_wire_callback';queue_diagnostics_complete=$true;queue_before_expected_registered=$true;queue_after_target_invites=1;queue_after_target_acks=0;callback_wire_digit_emitted=$true;callback_wire_sent_rtp=$true;callback_wire_received_rtp=$false;callback_before_job_count=0;callback_after_job_count=1;callback_after_job_state='starting';callback_after_attempts=0;callback_after_max_attempts=1;callback_after_target_matches=$true;callback_after_request_is_call=$true;callback_after_has_call_uuid=$true;callback_after_has_lease=$true;callback_after_call_uuid_alive=$false;callback_after_due=$true;callback_after_expired=$false;callback_after_lease_expired=$false;callback_before_jobs_held=$false;callback_after_worker_state='Running';callback_after_last_success_present=$true;callback_after_last_success_advanced=$true;callback_after_pause_state='active';callback_after_result_class='agent_or_route';callback_job_uuid='private-never-copy';callback_after_last_result='private-never-copy';callback_lastSuccess='private-never-copy'}
foreach($filter in 'QueueFailureFields','SafeQueueFailureFields','SafeFailureFields'){
 $safe=& $filter $callback
 foreach($field in $callback.PSObject.Properties.Name|Where-Object {$_ -ne 'active_case' -and $_ -notin 'callback_job_uuid','callback_after_last_result','callback_lastSuccess'}){Check ($safe.ContainsKey($field) -and $safe[$field] -ceq $callback.$field)}
 Check (($safe|ConvertTo-Json) -notmatch 'private-never-copy|last_result|lastSuccess|job_uuid')
 foreach($field in 'callback_wire_digit_emitted','callback_after_due','callback_after_has_lease','callback_after_call_uuid_alive','callback_after_last_success_advanced'){
  foreach($bad in 'true',1,$null,@{private='private-never-copy'}){$copy=$callback.PSObject.Copy();$copy.$field=$bad;Check (!(& $filter $copy).ContainsKey($field))}
 }
 foreach($field in 'callback_before_job_count','callback_after_attempts','callback_after_max_attempts'){
  foreach($bad in '1',$true,1.5,-1,1001,[double]::NaN,[double]::PositiveInfinity){$copy=$callback.PSObject.Copy();$copy.$field=$bad;Check (!(& $filter $copy).ContainsKey($field))}
 }
 foreach($field in 'callback_after_job_state','callback_after_worker_state','callback_after_result_class','callback_after_pause_state'){
  foreach($bad in 'private-never-copy',$callback.$field.ToUpperInvariant(),1,$true,@{private='private-never-copy'}){$copy=$callback.PSObject.Copy();$copy.$field=$bad;Check (!(& $filter $copy).ContainsKey($field))}
 }
 $copy=$callback.PSObject.Copy();$copy.callback_before_job_count=65;Check (!(& $filter $copy).ContainsKey('callback_before_job_count'))
 $copy=$callback.PSObject.Copy();$copy.active_case='queue_agent_delivery';Check (@((& $filter $copy).Keys|Where-Object {$_ -like 'callback_*'}).Count -eq 0)
}
$voicemailStages=@('voicemail_message_created','voicemail_recording_finalized','voicemail_mail_queued')
foreach($stage in $voicemailStages){
 Check ($stage -cin $nativeStages)
 foreach($prefix in 'primary','cleanup'){
  $copy=$record.PSObject.Copy();$copy.($prefix+'_substage')=$stage
  Check ((SafeFailureFields $copy).($prefix+'_substage') -ceq $stage)
  foreach($bad in $stage.ToUpperInvariant(),($stage+' '),1,$true,@($stage)){
   $copy.($prefix+'_substage')=$bad;Check (!(SafeFailureFields $copy).ContainsKey($prefix+'_substage'))
  }
 }
}
$voicemail=[pscustomobject]@{active_case='native_voicemail_recording_and_email_queue';voicemail_diagnostics_complete=$true;voicemail_before_message_count=0;voicemail_after_message_count=1;voicemail_before_mail_count=0;voicemail_after_mail_count=1;voicemail_before_wav_count=0;voicemail_after_wav_count=1;voicemail_before_wav_any_size_gt4096=$false;voicemail_after_wav_any_size_gt4096=$true;voicemail_before_wav_any_header_finalized=$false;voicemail_after_wav_any_header_finalized=$true;voicemail_before_recording_exists=$false;voicemail_before_recording_size_gt4096=$false;voicemail_before_recording_header_finalized=$false;voicemail_after_recording_exists=$true;voicemail_after_recording_size_gt4096=$true;voicemail_after_recording_header_finalized=$false;voicemail_message_uuid='private-never-copy';voicemail_message_path='private-never-copy';voicemail_recording_bytes=12345;voicemail_recording_audio='private-never-copy';voicemail_mail_message='private-never-copy'}
foreach($filter in 'VoicemailFailureFields','SafeVoicemailFailureFields','SafeFailureFields'){
 $safe=& $filter $voicemail
 foreach($field in @('voicemail_diagnostics_complete','voicemail_before_message_count','voicemail_after_message_count','voicemail_before_mail_count','voicemail_after_mail_count','voicemail_before_recording_exists','voicemail_before_recording_size_gt4096','voicemail_before_recording_header_finalized','voicemail_after_recording_exists','voicemail_after_recording_size_gt4096','voicemail_after_recording_header_finalized','voicemail_before_wav_count','voicemail_after_wav_count','voicemail_before_wav_any_size_gt4096','voicemail_after_wav_any_size_gt4096','voicemail_before_wav_any_header_finalized','voicemail_after_wav_any_header_finalized')){Check ($safe.ContainsKey($field) -and $safe[$field] -ceq $voicemail.$field)}
 Check (($safe|ConvertTo-Json) -notmatch 'private-never-copy|message_uuid|message_path|recording_bytes|recording_audio|mail_message')
 foreach($bad in 'native_voicemail_recording_and_email_queue ','NATIVE_VOICEMAIL_RECORDING_AND_EMAIL_QUEUE','native_voicemail_wire_forwarding_binary_copy',$null){$copy=$voicemail.PSObject.Copy();$copy.active_case=$bad;Check (@((& $filter $copy).Keys|Where-Object {$_ -like 'voicemail_*'}).Count -eq 0)}
 foreach($phase in 'before','after'){
  foreach($suffix in 'message_count','mail_count','wav_count'){
   $field='voicemail_'+$phase+'_'+$suffix
   foreach($bad in '1',$true,1.5,-1,65,[double]::NaN,[double]::PositiveInfinity){$copy=$voicemail.PSObject.Copy();$copy.$field=$bad;Check (!(& $filter $copy).ContainsKey($field))}
   $copy=$voicemail.PSObject.Copy();$copy.$field=64;Check ((& $filter $copy)[$field] -eq 64)
  }
  foreach($suffix in 'recording_exists','recording_size_gt4096','recording_header_finalized','wav_any_size_gt4096','wav_any_header_finalized'){
   $field='voicemail_'+$phase+'_'+$suffix
   foreach($bad in 'true',1,$null,@{private='private-never-copy'}){$copy=$voicemail.PSObject.Copy();$copy.$field=$bad;Check (!(& $filter $copy).ContainsKey($field))}
  }
 }
 foreach($bad in 'true',1,$null,@{private='private-never-copy'}){$copy=$voicemail.PSObject.Copy();$copy.voicemail_diagnostics_complete=$bad;Check (!(& $filter $copy).ContainsKey('voicemail_diagnostics_complete'))}
}
$mailboxStages=@('mailbox_login_prompt','mailbox_main_menu_prompt','mailbox_tutorial_complete','mailbox_recording_playback','mailbox_forward_extension_prompt','mailbox_forward_intro_prompt','mailbox_forwarded_prompt','mailbox_forwarded_message_created','mailbox_forwarded_binary_copy','mailbox_observer_close')
foreach($stage in $mailboxStages){
 Check ($stage -cin $nativeStages)
 foreach($prefix in 'primary','cleanup'){
  $copy=$record.PSObject.Copy();$copy.($prefix+'_substage')=$stage;Check ((SafeFailureFields $copy).($prefix+'_substage') -ceq $stage)
  foreach($bad in $stage.ToUpperInvariant(),($stage+' '),1,$true,@($stage)){$copy.($prefix+'_substage')=$bad;Check (!(SafeFailureFields $copy).ContainsKey($prefix+'_substage'))}
 }
}
$mailboxBool=@('diagnostics_complete','observer_failed','owned_call_seen','realm_call_id_header_present','owned_domain_header_present','owned_domain_matches','owned_event_name_matches','owned_path_header_present','pin_sent','tutorial_skip_sent','forward_destination_sent','forward_no_intro_sent','dialog_ended','received_rtp','prompt_password_seen','prompt_tutorial_seen','prompt_main_menu_seen','prompt_forward_extension_seen','prompt_forward_intro_seen','prompt_forwarded_seen','prompt_auth_failed_seen','prompt_mailbox_id_seen','prompt_goodbye_seen','prompt_recording_seen','prompt_other_seen')
$mailboxCount=@('observed_event_count','owned_event_count','matched_event_count','realm_event_count')
$mailboxData=@{active_case='native_voicemail_wire_forwarding_binary_copy';mailbox_callid='private-never-copy';mailbox_path='private-never-copy';mailbox_pin='private-never-copy';mailbox_prompt_PRIVATE_seen=$true;mailbox_event_body='private-never-copy';mailbox_audio='private-never-copy'}
foreach($suffix in $mailboxBool){$mailboxData['mailbox_'+$suffix]=$suffix -notin 'observer_failed','dialog_ended'}
foreach($suffix in $mailboxCount){$mailboxData['mailbox_'+$suffix]=2}
$mailbox=[pscustomobject]$mailboxData
foreach($filter in 'MailboxFailureFields','SafeMailboxFailureFields','SafeFailureFields'){
 $safe=& $filter $mailbox
 foreach($suffix in @($mailboxBool)+@($mailboxCount)){$field='mailbox_'+$suffix;Check ($safe.ContainsKey($field) -and $safe[$field] -ceq $mailbox.$field)}
 Check (($safe|ConvertTo-Json) -notmatch 'private-never-copy|callid|event_body|mailbox_pin"|mailbox_path|mailbox_audio|PRIVATE')
 foreach($bad in 'NATIVE_VOICEMAIL_WIRE_FORWARDING_BINARY_COPY','native_voicemail_wire_forwarding_binary_copy ','native_voicemail_recording_and_email_queue',$null){$copy=$mailbox.PSObject.Copy();$copy.active_case=$bad;Check (@((& $filter $copy).Keys|Where-Object {$_ -like 'mailbox_*'}).Count -eq 0)}
 foreach($suffix in $mailboxBool){
  $field='mailbox_'+$suffix
  foreach($bad in 'true',1,$null,@{private='private-never-copy'}){$copy=$mailbox.PSObject.Copy();$copy.$field=$bad;Check (!(& $filter $copy).ContainsKey($field))}
 }
 foreach($suffix in $mailboxCount){
  $field='mailbox_'+$suffix
  foreach($bad in '2',$true,1.5,-1,1001,[double]::NaN,[double]::PositiveInfinity){$copy=$mailbox.PSObject.Copy();$copy.$field=$bad;Check (!(& $filter $copy).ContainsKey($field))}
  $copy=$mailbox.PSObject.Copy();$copy.$field=1000;Check ((& $filter $copy)[$field] -eq 1000)
 }
}
Write-Output "PASS $checks actual caller native primary/cleanup/media/queue/voicemail/mailbox privacy allowlist checks; no PBX contacted"
