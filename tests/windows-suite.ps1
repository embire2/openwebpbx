#Requires -RunAsAdministrator
#Requires -Version 7.4
[CmdletBinding()]
param(
 [string]$NativeRunId,[string]$EngineRunId,[string]$PackageRoot,
 [switch]$DisposableHostedRunner
)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
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
$facts=[ordered]@{schema=1;platform='Windows Server 2025 x64';source_commit=$env:GITHUB_SHA;run_id=$env:GITHUB_RUN_ID;state='running';checks=@();gates=[ordered]@{fresh='pending';backups='pending';native_sip_audio='unqualified';direct_113_helper_reapply='unqualified';direct_failure_rollback='unqualified';restore_gate_startup='unqualified';manager_reopen_success='unqualified';manager_reopen_rollback='unqualified';installed_upgrade='unqualified';failure_rollback='unqualified';legacy_106_upgrade='unqualified';outside_acme='unqualified'};cleanup='pending'}
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
function SafeFailureFields($Record){
 $safe=@{}
 foreach($field in 'failed_phase','error_type','source_basename','active_case','command_basename','caller_basename'){
  $value=$Record.$field
  $pattern=if($field -in 'source_basename','command_basename','caller_basename'){'^[A-Za-z0-9_.-]+$'}else{'^[A-Za-z0-9_.+ /()-]+$'}
  if($value -is [string] -and $value.Length -le 160 -and $value -match $pattern){$safe[$field]=$value}
 }
 if(($Record.source_line -is [int] -or $Record.source_line -is [long]) -and $Record.source_line -gt 0 -and $Record.source_line -lt 100000){$safe.source_line=[int]$Record.source_line}
 if(($Record.caller_line -is [int] -or $Record.caller_line -is [long]) -and $Record.caller_line -gt 0 -and $Record.caller_line -lt 100000){$safe.caller_line=[int]$Record.caller_line}
 if(($Record.command_exit -is [int] -or $Record.command_exit -is [long]) -and $Record.command_exit -ge [int]::MinValue -and $Record.command_exit -le [int]::MaxValue){$safe.command_exit=[int]$Record.command_exit}
 if($Record.active_case -is [string] -and $Record.active_case -match '^(native_media_peer_(udp|tcp|tls)_registration_[0-2]|independent_g729_(offer_refused|answer_payload_mismatch))$'){
  if(($Record.sip_response_code -is [int] -or $Record.sip_response_code -is [long]) -and $Record.sip_response_code -ge 200 -and $Record.sip_response_code -le 699){$safe.sip_response_code=[int]$Record.sip_response_code}
  if(($Record.digest_challenge_count -is [int] -or $Record.digest_challenge_count -is [long]) -and $Record.digest_challenge_count -ge 0 -and $Record.digest_challenge_count -le 3){$safe.digest_challenge_count=[int]$Record.digest_challenge_count}
  if($Record.active_case -match '^independent_g729_' -and ($Record.negotiated_payload_type -is [int] -or $Record.negotiated_payload_type -is [long]) -and $Record.negotiated_payload_type -ge 0 -and $Record.negotiated_payload_type -le 127){$safe.negotiated_payload_type=[int]$Record.negotiated_payload_type}
 }
 if($Record.active_case -eq 'normal_admin_owned_extension_audio_preferences'){
  foreach($field in 'owned_domain_matches','authentication_id_matches','sip_password_matches'){if($Record.$field -is [bool]){$safe[$field]=[bool]$Record.$field}}
 }
 $nativeStages=@('native_case','g729_regular_unregister','g729_alternate_register','g729_invite','g729_answer_validation','g729_remote_answer','g729_media','g729_peer_receiver','g729_hangup','g729_alternate_unregister','g729_peer_close','g729_codec_close','g729_regular_reregister','native_peer_unregister','native_peer_close','native_ledger_write','callback_request_created','callback_agent_answer','callback_target_answer','callback_job_completed','voicemail_message_created','voicemail_recording_finalized','voicemail_mail_queued')
 foreach($prefix in 'primary','cleanup'){
  if($Record.($prefix+'_substage') -isnot [string] -or $Record.($prefix+'_substage') -cnotin $nativeStages){continue}
  $safe[$prefix+'_substage']=$Record.($prefix+'_substage')
  $type=$Record.($prefix+'_error_type');if($type -is [string] -and $type -match '^[A-Za-z0-9_]{1,80}$'){$safe[$prefix+'_error_type']=$type}
  foreach($where in 'source','caller'){
   $name=$Record.($prefix+'_'+$where+'_basename');$line=$Record.($prefix+'_'+$where+'_line')
   if($name -in 'windows-native-acceptance.py','pbx_v20_restore_native.py','sip_trunk_live.py','external_component' -and ($line -is [int] -or $line -is [long]) -and $line -gt 0 -and $line -lt 100000){$safe[$prefix+'_'+$where+'_basename']=$name;$safe[$prefix+'_'+$where+'_line']=[int]$line}
  }
 }
 if(($Record.cleanup_failure_count -is [int] -or $Record.cleanup_failure_count -is [long]) -and $Record.cleanup_failure_count -ge 1 -and $Record.cleanup_failure_count -le 32){$safe.cleanup_failure_count=[int]$Record.cleanup_failure_count}
 $mediaCases=@('native_tls_signalling_two_way_decoded_rtp','native_g729_pcmu_independent_codec_two_way_transcoding','native_simultaneous_ring_group','native_hunting_ring_group','native_queue_agent_first','native_ivr_negotiated_wire_rfc2833','native_visible_sip_hold_selected_music_resume_transfer','native_configured_ivr_timeout','native_queue_pause_logout_wire_callback_localservice_agent_first_decoded_rtp','native_hotel_wakeup_localservice_claim_wire_confirmation','native_voicemail_recording_private_owned_wav')
 $completed=@(foreach($name in $mediaCases){foreach($value in @($Record.completed_media_cases)){if($value -is [string] -and $value -ceq $name){$name;break}}})
 if($completed.Count){$safe.completed_media_cases=$completed}
 if($Record.media_peer -is [string] -and $Record.media_peer -cin 'caller','destination' -and $Record.media_direction -is [string] -and $Record.media_direction -cin 'sent','received'){
  $safe.media_peer=$Record.media_peer;$safe.media_direction=$Record.media_direction
  foreach($bound in @(@('media_window_seconds',.5,10),@('media_span_seconds',0,11),@('media_rate_pps',0,100000))){
   $value=$Record.($bound[0]);if(($value -is [double] -or $value -is [single] -or $value -is [int] -or $value -is [long]) -and ![double]::IsNaN([double]$value) -and ![double]::IsInfinity([double]$value) -and $value -ge $bound[1] -and $value -le $bound[2]){$safe[$bound[0]]=$value}
  }
  if(($Record.media_packets -is [int] -or $Record.media_packets -is [long]) -and $Record.media_packets -ge 0 -and $Record.media_packets -le 1000000){$safe.media_packets=$Record.media_packets}
 }
 foreach($entry in (SafeQueueFailureFields $Record).GetEnumerator()){$safe[$entry.Key]=$entry.Value}
 foreach($entry in (SafeVoicemailFailureFields $Record).GetEnumerator()){$safe[$entry.Key]=$entry.Value}
 return $safe
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
function Artifact([string]$RunId,[string]$Kind){
 if($RunId -notmatch '^[0-9]+$'){throw 'Artifact run IDs must be numeric.'}
 $run=Api ('actions/runs/'+$RunId)
 $workflow=if($Kind -eq 'music'){'.github/workflows/windows-suite.yml'}else{'.github/workflows/windows-'+$Kind+'.yml'}
 if($run.repository.full_name -ne 'embire2/openwebpbx' -or $run.head_repository.full_name -ne 'embire2/openwebpbx' -or $run.event -ne 'workflow_dispatch' -or $run.path -ne $workflow -or $run.head_sha -notmatch '^[a-f0-9]{40}$'){throw 'The input run does not belong to the expected repository workflow.'}
 if($Kind -eq 'music'){if($RunId -ne $env:GITHUB_RUN_ID -or $run.head_sha -ne $env:GITHUB_SHA){throw 'Music must come from this exact suite source.'}}
 elseif($run.status -ne 'completed' -or $run.conclusion -ne 'success'){throw 'A source build did not complete successfully.'}
 $prefix=if($Kind -eq 'music'){'openwebpbx-windows-suite-music-'}else{'openwebpbx-windows-'+$Kind+'-'}
 $artifacts=@((Api ('actions/runs/'+$RunId+'/artifacts?per_page=100')).artifacts|Where-Object {$_.name.StartsWith($prefix) -and $_.name.EndsWith('-'+$RunId) -and !$_.expired})
 if($artifacts.Count -ne 1 -or $artifacts[0].digest -notmatch '^sha256:[a-f0-9]{64}$' -or $artifacts[0].size_in_bytes -gt 8GB){throw 'One bounded hash-verified artifact is required.'}
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
 return @{directory=$destination;run=$run;artifact=$artifact}
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
 foreach($file in @('packaging/freeswitch/Build-WindowsNative.ps1','packaging/freeswitch/prepare-windows-native.py','packaging/freeswitch/windows-native-dependencies.py','packaging/freeswitch/windows-native-inputs.json','packaging/freeswitch/core-exports.py','packaging/freeswitch/restore-registration.patch','packaging/codecs/bcg729/buffer-safety.patch','tests/pbx_bcg729_codec.c')){
  $current=(& git -C $source hash-object $file).Trim();$built=(& git -C $source rev-parse ($engine.run.head_sha+':'+$file)).Trim()
  if($LASTEXITCODE -or $current -ne $built){throw 'Rebuild the native engine: current recipe inputs differ from its build.'}
 }
 $backup=Join-Path $work 'backup-runtime';CheckedPython @((Join-Path $source 'packaging/windows/build-backup-runtime.py'),'--cache',(Join-Path $work 'upstream-cache'),'--output',$backup,'--sources',(Join-Path $work 'backup-source'))
 $acmeArchive=Join-Path $work 'simple-acme.zip';Invoke-WebRequest 'https://github.com/simple-acme/simple-acme/releases/download/v2.4.1/simple-acme.v2.4.1.2444.win-x64.trimmed.zip' -OutFile $acmeArchive
 $acme=Join-Path $work 'acme';CheckedPython @((Join-Path $source 'packaging/windows/build-acme-runtime.py'),'--archive',$acmeArchive,'--output',$acme)
 $output=Join-Path $work 'package'
 $packageArguments=@((Join-Path $source 'packaging/build-release.py'),'--target','windows','--server',(Join-Path $native.directory 'server'),'--updater',(Join-Path $native.directory 'updater'),'--desktop',(Join-Path $native.directory 'desktop'),'--engine',(Join-Path $engine.directory 'engine'),'--backup-runtime',$backup,'--acme',$acme,'--music',$music.directory,'--codec-source',(Join-Path $codec 'source'),'--output',$output)
 if($nativeManifest.msi_pthread_experiment){$packageArguments+=@('--registrar-source',(Join-Path $codec 'registrar-source'))}
 CheckedPython $packageArguments
 $archives=@(Get-ChildItem $output -Filter '*.zip' -File);if($archives.Count -ne 1){throw 'One candidate package is required.'}
 $script:candidateArchive=$archives[0].FullName
 $expanded=Join-Path $work 'expanded';PrivateDirectory $expanded;ExpandSafe $archives[0].FullName $expanded
 $roots=@(Get-ChildItem $expanded -Directory);if($roots.Count -ne 1){throw 'The candidate package has an ambiguous root.'}
 $facts.artifacts=@{native_run=$NativeRunId;native_digest=$native.artifact.digest;engine_run=$EngineRunId;engine_digest=$engine.artifact.digest;music_digest=$music.artifact.digest;candidate_sha256=(Hash $archives[0].FullName)}
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
 & icacls.exe $hostkey /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F'|Out-Null
 if($LASTEXITCODE){throw 'The isolated SSH host key permissions could not be secured.'}
 & icacls.exe $hostkey /setowner '*S-1-5-18'|Out-Null
 if($LASTEXITCODE){throw 'The isolated SSH host key owner could not be secured.'}
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
 if(!$connected){throw 'The separate loopback SFTP server did not start.'}
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
try{
 PrivateDirectory $work;PublishFacts
 if((Test-Path "$configuration\config.conf") -or (Test-Path "$state\installation.json") -or (Get-Service OpenWebPBX -ErrorAction SilentlyContinue)){throw 'The ephemeral machine already contains a PBX; it is not an empty suite target.'}
 if(!$PackageRoot){$PackageRoot=PreparePackage}
 Remove-Item Env:\GH_TOKEN -ErrorAction SilentlyContinue
 $PackageRoot=[IO.Path]::GetFullPath($PackageRoot);$release=Get-Content (Join-Path $PackageRoot 'release-manifest.json') -Raw|ConvertFrom-Json
 if($release.version -ne (Get-Content (Join-Path $source 'VERSION') -Raw).Trim()){throw 'The candidate package release differs from source.'}
 $mapped=VerifyInventory $PackageRoot $release.files;$facts.checks+=('Exact candidate package inventory: '+$mapped+' files')
 $phase='original candidate export';ExportOriginalCandidate $release
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
 $acceptanceFile=Join-Path $work 'acceptance-input.json';$ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($password)
 try{$plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)}
 $acceptance=@{schema=1;run_id=$env:GITHUB_RUN_ID;restore_server=$true;admin_email=$admin;admin_password=$plain;public_url=('https://'+$domain+':8443');package_root=$PackageRoot;source_root=$source;private_state_root=$state;python='C:/OpenWebPBX/backup-runtime/python.exe';evidence_directory=(Join-Path $work 'native-private-evidence')}
 [IO.File]::WriteAllText($acceptanceFile,($acceptance|ConvertTo-Json),[Text.UTF8Encoding]::new($false));$plain=$null;$acceptance=$null
 $phase='native acceptance hook';$nativeStartTime=[DateTime]::UtcNow;$native=NativeAcceptanceHook (Join-Path $work 'native-acceptance.json') $nativeStartTime
 if($native){$facts.gates.native_sip_audio='passed'}
 $phase='independent trusted recovery fixture';$recoveryPki=Start-SuiteRecoveryPki -PackageRoot $PackageRoot -SourceRoot $source -Work $work
 $phase='upgrade acceptance hook';$upgrade=AcceptanceHook 'windows-upgrade-acceptance.ps1' (Join-Path $work 'upgrade-acceptance.json')
 if($upgrade){foreach($gate in 'direct_113_helper_reapply','direct_failure_rollback','restore_gate_startup','manager_reopen_success','manager_reopen_rollback','installed_upgrade','failure_rollback','legacy_106_upgrade'){if($upgrade.gates.$gate -eq 'passed'){$facts.gates[$gate]='passed'}}}
 $phase='backup qualification';$sftpConfig=LoopbackSftp
 & (Join-Path $PSScriptRoot 'windows-backups.ps1') -PackageRoot $PackageRoot -AdminEmail $admin -AdminPassword $password -DisposableFactory -SftpConfig $sftpConfig
 if(!$?){throw 'Actual Windows encrypted-backup qualification failed.'}
 $backup=Get-Content "$state\backup-qualification\report.json" -Raw|ConvertFrom-Json
 if($backup.state -ne 'passed' -or !$backup.fully_qualified){throw 'Actual backup/SFTP qualification is incomplete.'}
 $facts.gates.backups='passed';$facts.checks+=@($backup.checks)
 $missing=@($facts.gates.GetEnumerator()|Where-Object {$_.Value -ne 'passed'}|ForEach-Object Key)
 $facts.state=if($facts.state -eq 'failed'){'failed'}elseif($missing.Count){'partial'}else{'passed'};$facts.unqualified=$missing
}catch{
 RememberSuiteFailure $_ $phase
 if($phase -eq 'native acceptance hook' -and $nativeStartTime -and !$facts.native_runtime_failure){
  try{$facts.native_runtime_failure=NativeStartupFailure -StartedAt $nativeStartTime -PrivateDirectory $work}catch{$facts.native_runtime_failure=@{schema=1;observer_failed=$true}}
 }
 Write-Error ('Disposable Windows suite failed in '+$phase+'. No passing result is implied.') -ErrorAction Continue
}finally{
 Remove-Item Env:\GH_TOKEN -ErrorAction SilentlyContinue
 $cleanup=$true
 try{
  if($installed){
   $cleanupLock=$null
   try{$cleanupLock=[IO.File]::Open("$state\upgrade.lock",'OpenOrCreate','ReadWrite','None')}catch{throw 'An owned transaction is still running; cleanup must not interrupt it.'}
   $cleanupLock.Dispose()
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
   & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command '$env:PSModulePath=($PSHOME+"\Modules")+";"+($env:ProgramFiles+"\WindowsPowerShell\Modules");$ErrorActionPreference="Stop";if(Test-Path ($PSHOME+"\Modules\WebAdministration\WebAdministration.psd1")){Import-Module WebAdministration;if(Test-Path IIS:\Sites\OpenWebPBX){Stop-Website OpenWebPBX};if(Test-Path IIS:\AppPools\OpenWebPBX){Stop-WebAppPool OpenWebPBX}}' *> $null
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
 }
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
