# SPDX-License-Identifier: AGPL-3.0-or-later
# Pure tests of the actual receipt consumer. Modelled receipts do not qualify media.
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$tool=Join-Path $PSScriptRoot '../../tools/Test-ClientMedia.ps1';$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile([IO.Path]::GetFullPath($tool),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The actual media wrapper does not parse.'}
foreach($name in @('ClosedKeys','JsonShape','ReadNativeFailureObservation','ReadMediaResult')){
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
 $failed.failure_observation=[ordered]@{operation='wrong_ca_create';source_basename='LabCoordinator.cs';source_line=37;peer=[ordered]@{progress='native_devices';exited_before_cleanup=$true;exit_code_before_cleanup=2;error_type='InvalidOperationException';stderr_observed=$true}};$failed.engine_lifecycle=[ordered]@{start_completed=$true;shutdown_completed=$false}
 $observed=Validate $failed -AllowFailure;Check ($observed.failure_observation.peer.exit_code_before_cleanup -eq 2)
 foreach($mutation in @('operation','source','line','raw','exit','live_exit','peer_type','peer_progress','stderr','engine_type')){
  $copy=($failed|ConvertTo-Json -Depth 12)|ConvertFrom-Json -AsHashtable
  switch($mutation){operation{$copy.failure_observation.operation='PRIVATE'}source{$copy.failure_observation.source_basename='C:/PRIVATE'}line{$copy.failure_observation.source_line='37'}raw{$copy.failure_observation.raw='PRIVATE'}exit{$copy.failure_observation.peer.exit_code_before_cleanup=2147483648}live_exit{$copy.failure_observation.peer.exited_before_cleanup=$false}peer_type{$copy.failure_observation.peer.error_type='PRIVATE'}peer_progress{$copy.failure_observation.peer.progress='PRIVATE'}stderr{$copy.failure_observation.peer.stderr_observed=$false}engine_type{$copy.engine_lifecycle.start_completed=1}}
  $refused=$false;try{$null=Validate $copy -AllowFailure}catch{$refused=$true};Check $refused
 }
 $failed.error_type='arbitrary private text';$refused=$false;try{$null=Validate $failed -AllowFailure}catch{$refused=$true};Check $refused
 [ordered]@{schema=1;state='passed_pure_actual_consumer';checks=$checks;modelled_receipts_only=$true;actual_native_calling=$false;hardware_media_tested=$false}|ConvertTo-Json -Compress
}finally{Remove-Item -LiteralPath $root -Recurse -Force}
