#Requires -RunAsAdministrator
#Requires -Version 7.4
# SPDX-License-Identifier: AGPL-3.0-or-later
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PackageRoot,[switch]$DisposableHostedRunner,[Parameter(Mandatory)][string]$InputPath,[Parameter(Mandatory)][string]$ReportPath)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
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
$facts=[ordered]@{schema=1;state='running';platform='Windows Server 2025 x64';scope='fictional disposable hosted runner';checks=@();gates=[ordered]@{native_sip_audio='pending';smtp='pending';notification_store='pending';cleanup='pending';public_acme='unqualified';physical_devices='unqualified';carrier='unqualified';android_hardware='unqualified'}}
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
 $allowed=@('native_tls_signalling_two_way_decoded_rtp','native_g729_pcmu_independent_codec_two_way_transcoding','native_simultaneous_ring_group','native_hunting_ring_group','native_queue_agent_first','native_ivr_negotiated_wire_rfc2833','native_visible_sip_hold_selected_music_resume_transfer','native_configured_ivr_timeout','native_queue_pause_logout_wire_callback_localservice_agent_first_decoded_rtp','native_hotel_wakeup_localservice_claim_wire_confirmation','native_voicemail_recording_private_owned_wav')
 foreach($name in $allowed){
  foreach($check in @($Checks)){
   if($check.case -is [string] -and $check.case -ceq $name -and $check.passed -is [bool] -and $check.passed -eq $true){$name;break}
  }
 }
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
function MailboxFailureFields($Record){
 $safe=@{}
 if($Record.active_case -isnot [string] -or $Record.active_case -cne 'native_voicemail_wire_forwarding_binary_copy'){return $safe}
 foreach($suffix in 'diagnostics_complete','observer_failed','owned_call_seen','realm_call_id_header_present','owned_domain_header_present','owned_domain_matches','owned_event_name_matches','owned_path_header_present','pin_sent','tutorial_skip_sent','forward_destination_sent','forward_no_intro_sent','dialog_ended','received_rtp','prompt_password_seen','prompt_tutorial_seen','prompt_main_menu_seen','prompt_forward_extension_seen','prompt_forward_intro_seen','prompt_forwarded_seen','prompt_auth_failed_seen','prompt_mailbox_id_seen','prompt_goodbye_seen','prompt_recording_seen','prompt_other_seen'){$field='mailbox_'+$suffix;if($Record.$field -is [bool]){$safe[$field]=$Record.$field}}
 foreach($suffix in 'observed_event_count','owned_event_count','matched_event_count','realm_event_count'){$field='mailbox_'+$suffix;$value=$Record.$field;if(($value -is [int] -or $value -is [long]) -and $value -ge 0 -and $value -le 1000){$safe[$field]=$value}}
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
 if($frames.Count -gt 1){$safe.caller_basename=$frames[1].Groups[1].Value;$safe.caller_line=[int]$frames[1].Groups[2].Value}
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
 $result=Php 'baseline'|ConvertFrom-Json;if(!$result.factory_empty){throw 'Native qualification requires an empty factory.'};$baseline=$true
 foreach($name in $paths){$path=$originalFiles[$name];$present=Test-Path -LiteralPath $path;$originalPresent[$name]=$present;if($present){$originalAcl[$name]=(Get-Acl -LiteralPath $path).Sddl;Copy-Item -LiteralPath $path -Destination (Join-Path $saved $name) -Recurse}}
 $phase='actual Windows RTP socket reset and recovery'
 & $python -I (Join-Path $source 'tests/windows_rtp_socket.py') 1>>"$evidence\private-python.log" 2>>"$evidence\private-python-errors.log"
 if($LASTEXITCODE){throw 'Actual Windows UDP reset/recovery controls did not pass.'}
 $phase='actual Windows voicemail language filesystem defaults'
 & "$root\php\php.exe" -d extension=php_pdo_sqlite.dll (Join-Path $source 'tests/windows_voicemail_defaults.php') $source 1>>"$evidence\private-php.log" 2>>"$evidence\private-php-errors.log"
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
 if($native.state -ne 'passed'){throw 'Actual software native matrix failed.'}
 $facts.checks=@($native.checks);$facts.gates.native_sip_audio='passed';$facts.gates.smtp='passed'
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
 $facts.gates.notification_store='passed';$nativePassed=$true
}catch{
 $errorType=$_.Exception.GetType().Name;$facts.state='failed';$facts.failed_phase=$phase;$facts.error_type=$errorType
 $facts.source_basename='windows-native-acceptance.ps1';$facts.source_line=$_.InvocationInfo.ScriptLineNumber;$facts.active_case=$phase.Replace(' ','_')
 $nativeFailure=$_.Exception.Data['NativeChildFailure']
 if($nativeFailure -and $nativeFailure.source_basename -in 'Enable-PhoneTLS.ps1','Write-PrivateState.ps1','Restore-Gates.ps1','phone-tls.php','phone-tls-chain.php','pbx_phone_auth.php','pbx_sip_domain.php','event_socket.php','config.php','database.php','external_component' -and [int]$nativeFailure.source_line -gt 0 -and [int]$nativeFailure.source_line -le 100000 -and $nativeFailure.active_case -match '^phone_tls_[a-z_]+$' -and $nativeFailure.error_type -match '^[A-Za-z0-9_]{1,80}$'){
  $facts.source_basename=$nativeFailure.source_basename;$facts.source_line=[int]$nativeFailure.source_line;$facts.active_case=$nativeFailure.active_case;$facts.error_type=$nativeFailure.error_type
  if($nativeFailure.caller_basename -in 'Enable-PhoneTLS.ps1','Write-PrivateState.ps1','Restore-Gates.ps1' -and [int]$nativeFailure.caller_line -gt 0){$facts.caller_basename=$nativeFailure.caller_basename;$facts.caller_line=[int]$nativeFailure.caller_line}
 }
 $childReport=Join-Path $evidence 'software-native-report.json'
 if(Test-Path -LiteralPath $childReport){
  try{
   $child=Get-Content -LiteralPath $childReport -Raw|ConvertFrom-Json
   if($child.state -eq 'failed' -and $child.source_basename -in 'windows-native-acceptance.py','pbx_v20_restore_native.py','sip_trunk_live.py','windows-native-fixture.php','permissions.php','database.php','pbx_admin.php','pbx_setup.php','pbx_setup_provisioner.php','pbx_tenants.php','pbx_paths.php','pbx_mapper.php','pbx_schedule.php','pbx_operations.php','pbx_native.php','pbx_phone_auth.php','pbx_sip_domain.php','config.php','event_socket.php','cache.php','external_component' -and [int]$child.source_line -gt 0 -and [int]$child.source_line -le 100000 -and $child.active_case -match '^[a-z0-9_]{1,120}$' -and $child.error_type -match '^[A-Za-z0-9_]{1,80}$'){
    $facts.source_basename=$child.source_basename;$facts.source_line=[int]$child.source_line;$facts.active_case=$child.active_case;$facts.error_type=$child.error_type
    $completed=@(CompletedMediaCases $child.checks);if($completed.Count){$facts.completed_media_cases=$completed}
    foreach($entry in (MediaFailureFields $child).GetEnumerator()){$facts[$entry.Key]=$entry.Value}
    foreach($entry in (QueueFailureFields $child).GetEnumerator()){$facts[$entry.Key]=$entry.Value}
    foreach($entry in (VoicemailFailureFields $child).GetEnumerator()){$facts[$entry.Key]=$entry.Value}
    foreach($entry in (MailboxFailureFields $child).GetEnumerator()){$facts[$entry.Key]=$entry.Value}
    if($child.active_case -match '^(native_media_peer_(udp|tcp|tls)_registration_[0-2]|independent_g729_(offer_refused|answer_payload_mismatch))$'){
     if(($child.sip_response_code -is [int] -or $child.sip_response_code -is [long]) -and $child.sip_response_code -ge 200 -and $child.sip_response_code -le 699){$facts.sip_response_code=[int]$child.sip_response_code}
     if(($child.digest_challenge_count -is [int] -or $child.digest_challenge_count -is [long]) -and $child.digest_challenge_count -ge 0 -and $child.digest_challenge_count -le 3){$facts.digest_challenge_count=[int]$child.digest_challenge_count}
     if($child.active_case -match '^independent_g729_' -and ($child.negotiated_payload_type -is [int] -or $child.negotiated_payload_type -is [long]) -and $child.negotiated_payload_type -ge 0 -and $child.negotiated_payload_type -le 127){$facts.negotiated_payload_type=[int]$child.negotiated_payload_type}
    }
    if($child.active_case -eq 'normal_admin_owned_extension_audio_preferences'){
     foreach($field in 'owned_domain_matches','authentication_id_matches','sip_password_matches'){if($child.$field -is [bool]){$facts[$field]=[bool]$child.$field}}
    }
    $nativeStages=@('native_case','g729_regular_unregister','g729_alternate_register','g729_invite','g729_answer_validation','g729_remote_answer','g729_media','g729_peer_receiver','g729_hangup','g729_alternate_unregister','g729_peer_close','g729_codec_close','g729_regular_reregister','native_peer_unregister','native_peer_close','native_ledger_write','callback_request_created','callback_agent_answer','callback_target_answer','callback_job_completed','voicemail_message_created','voicemail_recording_finalized','voicemail_mail_queued','mailbox_login_prompt','mailbox_main_menu_prompt','mailbox_tutorial_complete','mailbox_recording_playback','mailbox_forward_extension_prompt','mailbox_forward_intro_prompt','mailbox_forwarded_prompt','mailbox_forwarded_message_created','mailbox_forwarded_binary_copy','mailbox_observer_close')
    foreach($prefix in 'primary','cleanup'){
     if($child.($prefix+'_substage') -isnot [string] -or $child.($prefix+'_substage') -cnotin $nativeStages){continue}
     $facts[$prefix+'_substage']=$child.($prefix+'_substage')
     $type=$child.($prefix+'_error_type');if($type -is [string] -and $type -match '^[A-Za-z0-9_]{1,80}$'){$facts[$prefix+'_error_type']=$type}
     foreach($where in 'source','caller'){
      $name=$child.($prefix+'_'+$where+'_basename');$line=$child.($prefix+'_'+$where+'_line')
      if($name -in 'windows-native-acceptance.py','pbx_v20_restore_native.py','sip_trunk_live.py','external_component' -and ($line -is [int] -or $line -is [long]) -and $line -gt 0 -and $line -lt 100000){$facts[$prefix+'_'+$where+'_basename']=$name;$facts[$prefix+'_'+$where+'_line']=[int]$line}
     }
    }
    if(($child.cleanup_failure_count -is [int] -or $child.cleanup_failure_count -is [long]) -and $child.cleanup_failure_count -ge 1 -and $child.cleanup_failure_count -le 32){$facts.cleanup_failure_count=[int]$child.cleanup_failure_count}
   }
  }catch{}
 }
}
finally{
 $phase='exact scoped cleanup'
 try{
  Stop-ScheduledTask -TaskName $notificationTask -ErrorAction SilentlyContinue;Unregister-ScheduledTask -TaskName $notificationTask -Confirm:$false -ErrorAction SilentlyContinue
  if($baseline){$clean=Php 'cleanup'|ConvertFrom-Json;if(!$clean.factory_empty -or $clean.owned_rows -ne 0 -or $clean.owned_contacts -ne 0){throw 'Native fixture cleanup is incomplete.'};if($clean.normal_login_bcrypt_rehash_proved){if(!$clean.original_factory_hash_restored){throw 'Original factory password hash was not restored.'};$facts.checks+='Normal generated-factory login bcrypt12-to-10 rehash proved with unchanged password, then original hash restored during cleanup'}}
  if($binding -and $originalBinding){FixtureBinding -Hash $originalBinding.hash -Store $originalBinding.store}
  foreach($name in $paths){$path=$originalFiles[$name];if($originalPresent.ContainsKey($name)){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force};if($originalPresent[$name]){Copy-Item -LiteralPath (Join-Path $saved $name) -Destination $path -Recurse;$acl=Get-Acl -LiteralPath $path;$acl.SetSecurityDescriptorSddlForm($originalAcl[$name]);Set-Acl -LiteralPath $path -AclObject $acl}}}
  if($baseline){Restart-Service FreeSWITCH;for($i=0;$i -lt 50 -and (Get-Service FreeSWITCH).Status -ne 'Running';$i++){Start-Sleep -Milliseconds 100};if((Get-Service FreeSWITCH).Status -ne 'Running'){throw 'Original factory call engine did not resume.'}}
  if($leaf){Remove-Item -LiteralPath ('Cert:\LocalMachine\My\'+$leaf.Thumbprint) -Force}
  if($rootCertificate){Remove-Item -LiteralPath ('Cert:\LocalMachine\Root\'+$rootCertificate.Thumbprint) -Force}
  if($pkiProcess){
   if(!$pkiProcess.HasExited){Stop-Process -Id $pkiProcess.Id -Force}
   if(!$pkiProcess.WaitForExit(5000)){throw 'Owned certificate-revocation fixture did not stop.'}
   [IO.File]::WriteAllText("$evidence\pki-stdout.log",$pkiOutput.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($false))
   [IO.File]::WriteAllText("$evidence\pki-stderr.log",$pkiErrors.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($false))
   $pkiProcess.Dispose()
  }
  if(Test-Path "$state\unexpected-localservice-$scope"){Remove-Item "$state\unexpected-localservice-$scope" -Force;throw 'LOCAL SERVICE incorrectly wrote containing state.'}
  $cleanupPassed=$true;$facts.gates.cleanup='passed';$facts.cleanup='Original factory rows/contacts/identity/profile/config/certificate binding restored; owned CA/leaf and private probe task removed'
 }catch{$cleanupPassed=$false;$facts.state='failed';$facts.cleanup='failed';$facts.cleanup_error_type=$_.Exception.GetType().Name}
 if($null -eq $envBefore){Remove-Item Env:\OPENWEB_WINDOWS_NATIVE_TEST -ErrorAction SilentlyContinue}else{$env:OPENWEB_WINDOWS_NATIVE_TEST=$envBefore}
 if($null -eq $opensslBefore){Remove-Item Env:\OPENSSL_CONF -ErrorAction SilentlyContinue}else{$env:OPENSSL_CONF=$opensslBefore}
 if($nativePassed -and $cleanupPassed){$facts.state='passed'}
 [IO.File]::WriteAllText($ReportPath,($facts|ConvertTo-Json -Depth 14),[Text.UTF8Encoding]::new($false))
}
if($facts.state -ne 'passed'){throw 'Windows native acceptance did not pass. Review private evidence; factory cleanup must pass before backups.'}
Write-Host 'Actual fictional Windows native calling, SMTP, notification storage and factory cleanup passed.'
