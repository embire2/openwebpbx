# SPDX-License-Identifier: AGPL-3.0-or-later
# Pure tests of the actual receipt consumer. Modelled receipts do not qualify media.
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$tool=Join-Path $PSScriptRoot '../../tools/Test-ClientMedia.ps1';$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile([IO.Path]::GetFullPath($tool),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The actual media wrapper does not parse.'}
foreach($name in @('ClosedKeys','JsonShape','ReadNativeWaitObservation','ReadNativeWaveObservation','ReadNativeSecurityObservation','ReadNativeRecorderInterval','ReadNativeRecorderObservation','ReadNativeFailureObservation','ReadEngineObservation','ReadMediaResult')){
 $found=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true))
 if($found.Count -ne 1){throw 'Exactly one actual consumer function is required.'};. ([scriptblock]::Create($found[0].Extent.Text))
}
$SourceCommit='abcdef0123456789abcdef0123456789abcdef0123';$root=Join-Path ([IO.Path]::GetTempPath()) ('phone-media-receipts-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root);$checks=0
function Check([bool]$Value){if(!$Value){throw 'A pure actual-consumer control failed.'};$script:checks++}
function Audio{[ordered]@{Window=[ordered]@{StartSeconds=3.0;Seconds=3.0;MinimumToneRatio=.99;MinimumRms=5000.0;GoodFraction=1.0};FreshSeconds=3.4;ObservedSeconds=3.5}}
function Model{
 $rows=[Collections.Generic.List[object]]::new()
 $maps=[ordered]@{
 tls_chain_hostname=@('wrong_ca_refused','wrong_name_refused');outgoing_audio=@('initial_left','initial_right','active_call_deferred_update','after_update_refusal_left','after_update_refusal_right','idle_allows_update');incoming_audio=@('initial_left','initial_right');hold_music_resume=@('initial_left','initial_right','held_caller_music','resumed_left','resumed_right');dtmf=@('initial_left','initial_right','received_exact_digits');blind_transfer=@('initial_left','initial_right','transferred_left','transferred_right');consult_complete=@('initial_left','initial_right','consultation_left','consultation_right','completed_left','completed_right');consult_cancel=@('initial_left','initial_right','consultation_left','consultation_right','cancelled_left','cancelled_right');call_waiting=@('initial_left','initial_right','waiting_answered_left','waiting_answered_right','original_resumed_left','original_resumed_right');local_conference=@('initial_left','initial_right','host_sdk_recorded_mix','left_received_mix','right_received_mix','sdk_conference_recording');software_vp8=@('initial_left','initial_right','left_decoded_frames','right_decoded_frames','window_seconds','left_width','left_height','right_width','right_height','left_received_fps','right_received_fps');voicemail_local_player=@('native_player_advanced','incoming_call_removed_private_playback','answered_left','answered_right')}
 foreach($entry in $maps.GetEnumerator()){
  $facts=[ordered]@{actual_tls_registration=$true}
  foreach($name in $entry.Value){$facts[$name]=if($name -in @('wrong_ca_refused','wrong_name_refused','received_exact_digits','sdk_conference_recording','native_player_advanced','incoming_call_removed_private_playback','active_call_deferred_update','idle_allows_update')){$true}elseif($name -in @('left_decoded_frames','right_decoded_frames')){30}elseif($name -eq 'window_seconds'){3}elseif($name -match '_width$'){640}elseif($name -match '_height$'){480}elseif($name -match '_received_fps$'){15.0}else{Audio}}
  $rows.Add([ordered]@{name=$entry.Key;state='passed';actual_nativephone=$true;file_media_adapter=$true;growing_wav_snapshot_adapter=$true;facts=$facts})
 }
 [ordered]@{schema=1;producer='OpenWebPbx.Phone.MediaChecks';state='passed_software_media';stage='voicemail_local_player';error_type='none';cases=$rows.ToArray();exact_owned_cleanup=$true;SourceCommit=$SourceCommit;SdkSha256='9cc84037333daca88af24804e20b9d1f5e41ddd901578484b57dcc6720a8d297';EngineSha256='3d4091bd972c1ea82ff9b6899c091dbeebf66416d6d76475add523ebe10a7542';test_managed_assembly=$true;production_binary_tested=$false;hardware_media_tested=$false;gui_render_tested=$false;carrier_calls_placed=$false;store_accepted=$false;installer_transaction_executed=$false;production_update_channel_tested=$false}
}
function Validate($Value,[switch]$AllowFailure){$path=Join-Path $root ([Guid]::NewGuid().ToString('N')+'.json');[IO.File]::WriteAllText($path,($Value|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false));ReadMediaResult $path -AllowFailure:$AllowFailure}
function Refuse([scriptblock]$Change){$model=Model;& $Change $model;$refused=$false;try{$null=Validate $model}catch{$refused=$true};Check $refused}
function RefuseRaw([string]$Text){$path=Join-Path $root ([Guid]::NewGuid().ToString('N')+'.json');[IO.File]::WriteAllText($path,$Text);$refused=$false;try{$null=ReadMediaResult $path}catch{$refused=$true};Check $refused}
try{
 $valid=Validate (Model);Check ($valid.cases.Count -eq 12);Check ($valid.production_binary_tested -eq $false)
 Refuse {param($m)$m['private_identifier']='must_not_escape'}
 Refuse {param($m)$m.SourceCommit='0000000000000000000000000000000000000000'}
 Refuse {param($m)$m.schema='1'}
 Refuse {param($m)$m.production_binary_tested=$true}
 Refuse {param($m)$m.hardware_media_tested=$true}
 Refuse {param($m)$m.gui_render_tested=$true}
 Refuse {param($m)$m.carrier_calls_placed=$true}
 Refuse {param($m)$m.store_accepted=$true}
 Refuse {param($m)$m.exact_owned_cleanup=$false}
 Refuse {param($m)$m.test_managed_assembly=$false}
 Refuse {param($m)$m.cases=$m.cases[0..10]}
 Refuse {param($m)$m.cases[1]=$m.cases[0]}
 Refuse {param($m)$m.cases[1].actual_nativephone=1}
 Refuse {param($m)$m.cases[1].facts.initial_left=$true}
 Refuse {param($m)$m.cases[1].facts.actual_tls_registration=Audio}
 Refuse {param($m)$m.cases[1].facts.initial_left.FreshSeconds=0}
 Refuse {param($m)$m.cases[1].facts.initial_left.ObservedSeconds=0}
 Refuse {param($m)$m.cases[1].facts.initial_left.Window.GoodFraction=.99}
 Refuse {param($m)$m.cases[1].facts.initial_left.Window.MinimumRms=499}
 Refuse {param($m)$m.cases[1].facts.initial_left.Window.MinimumToneRatio=.64}
 Refuse {param($m)$m.cases[1].facts.initial_left.Window.Seconds=2}
 Refuse {param($m)$m.cases[1].facts.initial_left.Window.StartSeconds=-1}
 Refuse {param($m)$m.cases[1].facts.initial_left.Window['unbounded_private_data']='refuse'}
 Refuse {param($m)$m.cases[10].facts.left_decoded_frames=19}
 Refuse {param($m)$m.cases[10].facts.left_width=0}
 Refuse {param($m)$m.cases[10].facts.left_received_fps=4.9}
 Refuse {param($m)$m.cases[10].facts.window_seconds=3.5}
 $raw=Model|ConvertTo-Json -Depth 12 -Compress
 RefuseRaw ($raw.Replace('"schema":1','"schema":1,"schema":1'))
 RefuseRaw ($raw.Replace('"FreshSeconds":3.4','"FreshSeconds":1e309'))
 RefuseRaw ($raw.Replace('"FreshSeconds":3.4','"FreshSeconds":-1e309'))
 RefuseRaw ($raw.Replace('"FreshSeconds":3.4','"FreshSeconds":NaN'))
 RefuseRaw ($raw.Replace('"FreshSeconds":3.4','"FreshSeconds":Infinity'))
 $failed=Model;$failed.state='failed';$failed.stage='hold_music_resume';$failed.error_type='InvalidDataException';$failed.cases=$failed.cases[0..2];$closed=Validate $failed -AllowFailure;Check ($closed.state -ceq 'failed' -and $closed.cases.Count -eq 3)
 $refused=$false;try{$null=Validate $failed}catch{$refused=$true};Check $refused
 $refused=$false;try{$null=Validate (Model) -AllowFailure}catch{$refused=$true};Check $refused
 $failed.failure_observation=[ordered]@{operation='wrong_ca_create';source_basename='LabCoordinator.cs';source_line=37;wait=$null;wave=$null;security=$null;recorder=$null;peer=[ordered]@{progress='native_devices';exited_before_cleanup=$true;exit_code_before_cleanup=2;error_type='InvalidOperationException';stderr_observed=$true}};$failed.engine_lifecycle=[ordered]@{start_completed=$true;shutdown_completed=$false}
 $observed=Validate $failed -AllowFailure;Check ($observed.failure_observation.peer.exit_code_before_cleanup -eq 2)
 foreach($mutation in @('operation','source','line','raw','exit','live_exit','peer_type','peer_progress','stderr','engine_type')){
  $copy=($failed|ConvertTo-Json -Depth 12)|ConvertFrom-Json -AsHashtable
  switch($mutation){operation{$copy.failure_observation.operation='PRIVATE'}source{$copy.failure_observation.source_basename='C:/PRIVATE'}line{$copy.failure_observation.source_line='37'}raw{$copy.failure_observation.raw='PRIVATE'}exit{$copy.failure_observation.peer.exit_code_before_cleanup=2147483648}live_exit{$copy.failure_observation.peer.exited_before_cleanup=$false}peer_type{$copy.failure_observation.peer.error_type='PRIVATE'}peer_progress{$copy.failure_observation.peer.progress='PRIVATE'}stderr{$copy.failure_observation.peer.stderr_observed=$false}engine_type{$copy.engine_lifecycle.start_completed=1}}
  $refused=$false;try{$null=Validate $copy -AllowFailure}catch{$refused=$true};Check $refused
 }
 $wait=[ordered]@{name='incoming_initial';deadline_seconds=20;peers=@([ordered]@{position=0;observed=$true;state=[ordered]@{ready=$true;registration_failed=$false;busy=$false;call_count=0;states=@();signals=@([ordered]@{state=13;reason=4;protocol_code=404;observed=$true})}})}
 $failed.failure_observation.wait=$wait;$closedWait=Validate $failed -AllowFailure;Check ($closedWait.failure_observation.wait.peers[0].state.signals[0].protocol_code -eq 404)
 foreach($mutation in @('name','deadline','peer_position','peer_observed','private','state','count','code','reason','signal_observed','signal_type','too_many')){
  $copy=($failed|ConvertTo-Json -Depth 12)|ConvertFrom-Json -AsHashtable;$w=$copy.failure_observation.wait;$p=$w.peers[0];switch($mutation){name{$w.name='PRIVATE'}deadline{$w.deadline_seconds=21}peer_position{$p.position=1}peer_observed{$p.observed=$false}private{$p.state['number']='PRIVATE'}state{$p.state.call_count=1;$p.state.states=@('PRIVATE')}count{$p.state.call_count=3}code{$p.state.signals[0].protocol_code=700}reason{$p.state.signals[0].reason=26}signal_observed{$p.state.signals[0].observed=$false}signal_type{$p.state.signals[0].protocol_code='404'}too_many{$p.state.signals=@(1..33|ForEach-Object {[ordered]@{state=13;reason=4;protocol_code=404;observed=$true}})}}
  $refused=$false;try{$null=Validate $copy -AllowFailure}catch{$refused=$true};Check $refused
 }
 $failed.error_type='arbitrary private text' ;$refused=$false;try{$null=Validate $failed -AllowFailure}catch{$refused=$true};Check $refused
 $failed.error_type='InvalidDataException'
 $failed.failure_observation.source_basename='AudioProof.cs';$failed.failure_observation.source_line=23
 $failed.failure_observation.wave=[ordered]@{reason='decoded_samples';source='failed_read_buffer';growing=$true;snapshot_atomic=$false;length_check_bytes=44;buffer_bytes=44;riff=$true;wave=$true;riff_declared_bytes=0;chunk='data';chunk_offset=36;chunk_declared_bytes=0;chunk_effective_bytes=0;format_tag=1;channels=1;sample_rate=8000;sample_bits=16;alignment=2;byte_rate=16000;format_seen=$true;data_seen=$true;data_bytes=0}
 $closedWave=Validate $failed -AllowFailure;Check ($closedWave.failure_observation.wave.reason -ceq 'decoded_samples' -and !$closedWave.failure_observation.wave.snapshot_atomic)
 foreach($mutation in @('reason','source','raw','atomic','boolean','marker','negative','count_type','oversize','tag','rate','chunk','declared','length_only')){
  $copy=($failed|ConvertTo-Json -Depth 12)|ConvertFrom-Json -AsHashtable;$w=$copy.failure_observation.wave
  switch($mutation){reason{$w.reason='PRIVATE'}source{$w.source='PRIVATE'}raw{$w['raw']='PRIVATE'}atomic{$w.snapshot_atomic=$true}boolean{$w.growing=1}marker{$w.riff='true'}negative{$w.data_bytes=-1}count_type{$w.buffer_bytes='44'}oversize{$w.buffer_bytes=134217729}tag{$w.format_tag=65536}rate{$w.sample_rate=4294967296}chunk{$w.chunk='PRIVATE'}declared{$w.chunk_declared_bytes=-1}length_only{$w.source='file_length_check'}}
  $bad=$false;try{$null=Validate $copy -AllowFailure}catch{$bad=$true};Check $bad
 }
 $failed.failure_observation.security=[ordered]@{source='already_sampled_secure_argument';tls_ca_and_hostname=$true;mandatory_srtp=$true;call_count=1;calls=@([ordered]@{state='StreamsRunning';encryption='SRTP';srtp_suite='Invalid'})}
 $closedSecurity=Validate $failed -AllowFailure;Check ($closedSecurity.failure_observation.security.calls[0].srtp_suite -ceq 'Invalid')
 $failed.failure_observation.security.source='last_connection_wait_argument';$closedSecurity=Validate $failed -AllowFailure;Check ($closedSecurity.failure_observation.security.source -ceq 'last_connection_wait_argument');$failed.failure_observation.security.source='already_sampled_secure_argument'
 foreach($mutation in @('source','tls_type','mandatory_type','count','state','encryption','suite','identifier')){
  $copy=($failed|ConvertTo-Json -Depth 12)|ConvertFrom-Json -AsHashtable;$o=$copy.failure_observation.security
  switch($mutation){source{$o.source='PRIVATE'}tls_type{$o.tls_ca_and_hostname=1}mandatory_type{$o.mandatory_srtp='true'}count{$o.call_count=3}state{$o.calls[0].state='PRIVATE'}encryption{$o.calls[0].encryption='PRIVATE'}suite{$o.calls[0].srtp_suite='PRIVATE'}identifier{$o.calls[0]['id']='PRIVATE'}}
  $bad=$false;try{$null=Validate $copy -AllowFailure}catch{$bad=$true};Check $bad
 }
 $failed.failure_observation.recorder=[ordered]@{scope='failed_capture_same_owned_recorder';recording='receive_output';payload_phase='after_failed_read_before_cleanup';payload_observed=$true;same_call_identity=$true;call_count=1;calls=@([ordered]@{state='StreamsRunning';codec='PCMU';clock_rate=8000;channels=1});owned_peers_closed=$true;file_observation='observed';initialization_interval=$null;closed_file=[ordered]@{phase='after_owned_peer_shutdown';length_bytes=44;sha256=('a'*64);header_bytes=44;riff=$true;wave=$true;format=$true;data=$true;riff_declared_bytes=32;format_declared_bytes=16;format_tag=1;channels=1;sample_rate=8000;byte_rate=16000;alignment=2;sample_bits=16;data_declared_bytes=0;bytes_after_fixed_header=0}}
 $closedRecorder=Validate $failed -AllowFailure;Check ($closedRecorder.failure_observation.recorder.closed_file.riff_declared_bytes -eq 32)
 foreach($mutation in @('scope','recording','payload_phase','boolean','count','unobserved','codec','call_state','rate','channels','call_identifier','closed_type','closed_false','file_observation','file_missing','file_phase','file_length','hash','header_length','marker_type','marker_absent','format_type','format_absent','format_limit','rate_limit','data_length','data_absent','file_path')){
  $copy=($failed|ConvertTo-Json -Depth 12)|ConvertFrom-Json -AsHashtable;$o=$copy.failure_observation.recorder;$f=$o.closed_file
  switch($mutation){scope{$o.scope='PRIVATE'}recording{$o.recording='PRIVATE'}payload_phase{$o.payload_phase='PRIVATE'}boolean{$o.payload_observed=1}count{$o.call_count=2}unobserved{$o.payload_observed=$false}codec{$o.calls[0].codec='PRIVATE'}call_state{$o.calls[0].state='PRIVATE'}rate{$o.calls[0].clock_rate=192001}channels{$o.calls[0].channels=9}call_identifier{$o.calls[0]['id']='PRIVATE'}closed_type{$o.owned_peers_closed=1}closed_false{$o.owned_peers_closed=$false}file_observation{$o.file_observation='PRIVATE'}file_missing{$o.closed_file=$null}file_phase{$f.phase='PRIVATE'}file_length{$f.length_bytes=134217729}hash{$f.sha256='PRIVATE'}header_length{$f.header_bytes=43}marker_type{$f.riff='true'}marker_absent{$f.riff=$null}format_type{$f.format_tag='1'}format_absent{$f.format_tag=$null}format_limit{$f.format_tag=65536}rate_limit{$f.sample_rate=4294967296}data_length{$f.bytes_after_fixed_header=1}data_absent{$f.data_declared_bytes=$null}file_path{$f['path']='PRIVATE'}}
  $bad=$false;try{$null=Validate $copy -AllowFailure}catch{$bad=$true};Check $bad
 }
 foreach($state in @('read_refused','peers_not_closed')){$copy=($failed|ConvertTo-Json -Depth 12)|ConvertFrom-Json -AsHashtable;$o=$copy.failure_observation.recorder;$o.file_observation=$state;$o.closed_file=$null;$o.owned_peers_closed=$state -ceq 'read_refused';$v=Validate $copy -AllowFailure;Check ($v.failure_observation.recorder.file_observation -ceq $state)}
 $copy=($failed|ConvertTo-Json -Depth 12)|ConvertFrom-Json -AsHashtable;$o=$copy.failure_observation.recorder;$o.payload_observed=$false;$o.same_call_identity=$false;$o.call_count=0;$o.calls=@();$o.closed_file=[ordered]@{phase='after_owned_peer_shutdown';length_bytes=0;sha256=('b'*64);header_bytes=0;riff=$null;wave=$null;format=$null;data=$null;riff_declared_bytes=$null;format_declared_bytes=$null;format_tag=$null;channels=$null;sample_rate=$null;byte_rate=$null;alignment=$null;sample_bits=$null;data_declared_bytes=$null;bytes_after_fixed_header=$null};$v=Validate $copy -AllowFailure;Check ($v.failure_observation.recorder.closed_file.length_bytes -eq 0)
 $failed.failure_observation.wave=[ordered]@{reason='file_length';source='file_length_check';growing=$true;snapshot_atomic=$false;length_check_bytes=0;buffer_bytes=0;riff=$null;wave=$null;riff_declared_bytes=$null;chunk='none';chunk_offset=-1;chunk_declared_bytes=$null;chunk_effective_bytes=$null;format_tag=$null;channels=$null;sample_rate=$null;sample_bits=$null;alignment=$null;byte_rate=$null;format_seen=$false;data_seen=$false;data_bytes=0}
 $failed.failure_observation.recorder.initialization_interval=[ordered]@{phase='before_owned_peer_shutdown';snapshot_atomic=$false;state='observed';failure_capture_ms=0;start_capture_ms=10;end_capture_ms=5010;elapsed_ms=5000;requested_ms=5000;wait_completed=$true;prefix=[ordered]@{length_before_bytes=80000;length_after_bytes=80000;header_bytes=44;riff=$false;wave=$false;format=$false;data=$false;riff_declared_bytes=$null;format_declared_bytes=$null;format_tag=$null;channels=$null;sample_rate=$null;byte_rate=$null;alignment=$null;sample_bits=$null;data_declared_bytes=$null}}
 $v=Validate $failed -AllowFailure;Check ($v.failure_observation.recorder.initialization_interval.elapsed_ms -eq 5000)
 foreach($mutation in @('phase','atomic','state','failure_type','failure_negative','start_negative','backwards','duration','oversize_wait','wrong_budget','wait_type','not_complete','prefix_missing','prefix_raw','prefix_length','prefix_count','prefix_marker','prefix_inferred','wave_not_zero','wave_growing','unconfirmed')){
  $copy=($failed|ConvertTo-Json -Depth 12)|ConvertFrom-Json -AsHashtable;$o=$copy.failure_observation.recorder.initialization_interval;$f=$o.prefix
  switch($mutation){phase{$o.phase='PRIVATE'}atomic{$o.snapshot_atomic=$true}state{$o.state='PRIVATE'}failure_type{$o.failure_capture_ms='0'}failure_negative{$o.failure_capture_ms=-1}start_negative{$o.start_capture_ms=-1}backwards{$o.end_capture_ms=9}duration{$o.elapsed_ms=4999}oversize_wait{$o.requested_ms=5001}wrong_budget{$o.start_capture_ms=11000;$o.end_capture_ms=16000}wait_type{$o.wait_completed=1}not_complete{$o.wait_completed=$false}prefix_missing{$o.prefix=$null}prefix_raw{$f['samples']='PRIVATE'}prefix_length{$f.length_before_bytes=134217729}prefix_count{$f.header_bytes=43}prefix_marker{$f.riff='false'}prefix_inferred{$f.sample_rate=8000}wave_not_zero{$copy.failure_observation.wave.length_check_bytes=1}wave_growing{$copy.failure_observation.wave.growing=$false}unconfirmed{$copy.failure_observation.recorder.same_call_identity=$false}}
  $bad=$false;try{$null=Validate $copy -AllowFailure}catch{$bad=$true};Check $bad
 }
 $copy=($failed|ConvertTo-Json -Depth 12)|ConvertFrom-Json -AsHashtable;$o=$copy.failure_observation.recorder.initialization_interval;$o.state='no_remaining_budget';$o.start_capture_ms=12000;$o.end_capture_ms=12000;$o.elapsed_ms=0;$o.requested_ms=0;$o.wait_completed=$false;$o.prefix=$null;$v=Validate $copy -AllowFailure;Check ($v.failure_observation.recorder.initialization_interval.state -ceq 'no_remaining_budget')
 $copy=($failed|ConvertTo-Json -Depth 12)|ConvertFrom-Json -AsHashtable;$o=$copy.failure_observation.recorder.initialization_interval;$o.state='capture_budget_expired';$o.start_capture_ms=11990;$o.end_capture_ms=12015;$o.elapsed_ms=25;$o.requested_ms=10;$o.prefix=$null;$v=Validate $copy -AllowFailure;Check ($v.failure_observation.recorder.initialization_interval.elapsed_ms -eq 25)
 $copy=($failed|ConvertTo-Json -Depth 12)|ConvertFrom-Json -AsHashtable;$o=$copy.failure_observation.recorder.initialization_interval;$o.state='observation_refused';$o.start_capture_ms=$null;$o.end_capture_ms=$null;$o.elapsed_ms=$null;$o.requested_ms=0;$o.wait_completed=$false;$o.prefix=$null;$v=Validate $copy -AllowFailure;Check ($null -eq $v.failure_observation.recorder.initialization_interval.start_capture_ms)
 [ordered]@{schema=1;state='passed_pure_actual_consumer';checks=$checks;modelled_receipts_only=$true;actual_native_calling=$false;hardware_media_tested=$false}|ConvertTo-Json -Compress
}finally{Remove-Item -LiteralPath $root -Recurse -Force}
