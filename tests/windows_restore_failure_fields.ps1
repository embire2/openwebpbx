#Requires -Version 5.1
<# Actual AST projector/caller controls only. No installed application or Windows
restore is executed; all child output and failures below are fictional. #>
[CmdletBinding()]
param([string]$SourceRoot='')
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($SourceRoot)){$SourceRoot=Split-Path $PSScriptRoot -Parent}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-restore-qualification.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Restore qualification source must parse.'}
foreach($name in 'SafeRestoreFixtureFailure','SafeRestorePeerFailures','SafeRestoreSchemaFailure','SafeRestoreMailboxFailure','SafeRestoreToneFailure','SafeRestoreCliFailure','SafeRestoreServiceActivationFailure','AssertRestoredServiceActivation','NativeFixture'){
 $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
 if($nodes.Count -ne 1){throw 'One exact source function is required.'}
 if($name -eq 'NativeFixture'){$nativeDefinition=$nodes[0].Extent.Text}else{Invoke-Expression $nodes[0].Extent.Text}
}
$script:count=0
function Assert([bool]$Condition){$script:count++;if(!$Condition){throw ('A closed restore-observation control failed at source line '+(Get-PSCallStack)[1].ScriptLineNumber+'.')}}
function Clone($Value){return ($Value|ConvertTo-Json -Depth 20 -Compress|ConvertFrom-Json)}
$updaterAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-updater-qualification.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The real qualification Check helper must parse.'}
$checks=@($updaterAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Check'},$true))
if($checks.Count -ne 1){throw 'Exactly one real qualification Check helper is required.'}
Invoke-Expression $checks[0].Extent.Text
$script:actualCheck=${function:Check};$script:actualPrimary=$null
function Check([bool]$Value,[string]$Message){try{& $script:actualCheck $Value $Message}catch{$script:actualPrimary=$_.Exception;throw}}
$script:cimCalls=0;$script:serviceRow=$null;$script:cimFailure=$null
function Get-CimInstance($ClassName,[string]$Filter){
 $script:cimCalls++;Assert ($ClassName -ceq 'Win32_Service' -and $Filter -cin @("Name='FreeSWITCH'","Name='OpenWebPBX'","Name='OpenWebPBXUpdater'"))
 if($script:cimFailure){throw $script:cimFailure};return $script:serviceRow
}
foreach($name in 'FreeSWITCH','OpenWebPBX','OpenWebPBXUpdater'){
 $account=if($name -ceq 'OpenWebPBX'){'NT AUTHORITY\LocalService'}else{'LocalSystem'}
 $script:serviceRow=[pscustomobject]@{Name=$name;State='Running';StartMode='Auto';StartName=$account;ExitCode=[uint32]0;ServiceSpecificExitCode=[uint32]0}
 Assert (@(AssertRestoredServiceActivation $name).Count -eq 0)
 foreach($mode in 'stopped','manual','wrong_identity','wrong_name','unknown','missing','invalid_exit'){
  $script:serviceRow=[pscustomobject]@{Name=$name;State='Stopped';StartMode='Auto';StartName=$account;ExitCode=[uint32]1066;ServiceSpecificExitCode=[uint32]42}
  switch($mode){
   'manual'{$script:serviceRow.State='Running';$script:serviceRow.StartMode='Manual'}
   'wrong_identity'{$script:serviceRow.StartName='PRIVATE principal'}
   'wrong_name'{$script:serviceRow.Name='PRIVATE service'}
   'unknown'{$script:serviceRow.State='PRIVATE';$script:serviceRow.StartMode='PRIVATE'}
   'missing'{$script:serviceRow=$null}
   'invalid_exit'{$script:serviceRow.ExitCode='PRIVATE';$script:serviceRow.ServiceSpecificExitCode=-1}
  }
  $caught=$null;try{AssertRestoredServiceActivation $name}catch{$caught=$_}
  Assert ([object]::ReferenceEquals($caught.Exception,$script:actualPrimary))
  $observation=SafeRestoreServiceActivationFailure $caught.Exception.Data['restore_service_activation']
  Assert ($observation.Count -eq 7 -and $observation.stage -ceq 'service_running_auto' -and $observation.service -ceq $name)
  Assert ($observation.is_expected_identity -eq ($mode -cnotin @('wrong_identity','wrong_name','missing')))
  if($mode -ceq 'unknown'){Assert ($observation.state -ceq 'unknown' -and $observation.start_mode -ceq 'unknown')}
  if($mode -ceq 'missing'){Assert ($observation.state -ceq 'unavailable' -and $observation.start_mode -ceq 'unavailable')}
  if($mode -cin @('missing','invalid_exit')){Assert ($null -eq $observation.exit_code -and $null -eq $observation.service_specific_exit_code)}else{Assert ($observation.exit_code -eq 1066 -and $observation.service_specific_exit_code -eq 42)}
  Assert (($observation|ConvertTo-Json -Compress) -notmatch 'PRIVATE|principal|StartName')
 }
}
$before=$script:cimCalls;$caught=$null;try{AssertRestoredServiceActivation 'PRIVATE'}catch{$caught=$_}
Assert ($null -ne $caught -and $script:cimCalls -eq $before)
$script:cimFailure=[InvalidOperationException]::new('PRIVATE native query failure');$caught=$null
try{AssertRestoredServiceActivation 'OpenWebPBXUpdater'}catch{$caught=$_}
Assert ([object]::ReferenceEquals($caught.Exception,$script:cimFailure))
Assert ((SafeRestoreServiceActivationFailure $caught.Exception.Data['restore_service_activation']).state -ceq 'unavailable')
$script:cimFailure=$null
$script:serviceRow=[pscustomobject]@{Name='OpenWebPBXUpdater';State='Stopped';StartMode='Auto'}
$script:serviceRow|Add-Member ScriptProperty StartName {throw 'PRIVATE metadata getter failure'}
$caught=$null;try{AssertRestoredServiceActivation 'OpenWebPBXUpdater'}catch{$caught=$_}
Assert ([object]::ReferenceEquals($caught.Exception,$script:actualPrimary))
Assert ((SafeRestoreServiceActivationFailure $caught.Exception.Data['restore_service_activation']).is_expected_identity -eq $false)
Assert (($caught.Exception.Data['restore_service_activation']|ConvertTo-Json -Compress) -notmatch 'PRIVATE')
Remove-Item Function:\Get-CimInstance
$serviceGood=@{stage='service_running_auto';service='OpenWebPBXUpdater';state='Stopped';start_mode='Auto';is_expected_identity=$true;exit_code=1066;service_specific_exit_code=42}
Assert ((SafeRestoreServiceActivationFailure (Clone $serviceGood)).Count -eq 7)
foreach($key in $serviceGood.Keys){
 foreach($value in @($null,$true,$false,@(),@{},1.5,'PRIVATE SQL password/path')){
  if($key -cin @('exit_code','service_specific_exit_code') -and $null -eq $value){continue}
  if($key -ceq 'is_expected_identity' -and $value -is [bool]){continue}
  $candidate=Clone $serviceGood;$candidate.$key=$value;Assert ($null -eq (SafeRestoreServiceActivationFailure $candidate))
 }
 $candidate=Clone $serviceGood;$candidate.PSObject.Properties.Remove($key);Assert ($null -eq (SafeRestoreServiceActivationFailure $candidate))
}
foreach($key in 'exit_code','service_specific_exit_code'){
 foreach($value in $null,0,([long]4294967295)){$candidate=Clone $serviceGood;$candidate.$key=$value;Assert ($null -ne (SafeRestoreServiceActivationFailure $candidate))}
 foreach($value in -1,([long]4294967296),'1066'){$candidate=Clone $serviceGood;$candidate.$key=$value;Assert ($null -eq (SafeRestoreServiceActivationFailure $candidate))}
}
$candidate=Clone $serviceGood;$candidate|Add-Member noteproperty message 'PRIVATE';Assert ($null -eq (SafeRestoreServiceActivationFailure $candidate))
foreach($value in $null,@(),@{},@($serviceGood)){Assert ($null -eq (SafeRestoreServiceActivationFailure $value))}
$mainCatch=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.CatchClauseAst] -and $n.Body.Extent.Text.Contains("`$facts.state='failed';`$facts.failed_phase=`$phase")},$true))
Assert ($mainCatch.Count -eq 1)
foreach($mode in 'valid','extra','unknown'){
 $record=Clone $serviceGood;if($mode -ceq 'extra'){$record|Add-Member noteproperty account 'PRIVATE'};if($mode -ceq 'unknown'){$record.service='PRIVATE'}
 $script:activationError=[InvalidOperationException]::new('PRIVATE actual original exception');$script:activationError.Data['restore_service_activation']=$record
 $facts=@{};$phase='postactivation service state'
 $projectionCaught=$null;try{Invoke-Expression ('try{throw $script:activationError}'+$mainCatch[0].Extent.Text)}catch{$projectionCaught=$_}
 Assert ([object]::ReferenceEquals($projectionCaught.Exception,$script:activationError))
 Assert ($facts.state -ceq 'failed' -and $facts.failed_phase -ceq $phase -and $facts.error_type -ceq 'InvalidOperationException')
 Assert (($null -ne $facts.service_activation_failure) -eq ($mode -ceq 'valid'))
 Assert (($facts|ConvertTo-Json -Depth 20 -Compress) -notmatch 'PRIVATE|account|actual original')
}
$good=[ordered]@{schema=1;action='cleanup';step='factory_guard';reason='factory_not_empty';error_type='RuntimeException';source_basename='windows-restore-qualification.php';source_line=123}
$safe=SafeRestoreFixtureFailure (Clone $good)
Assert ($safe.Count -eq 7 -and $safe.step -ceq 'factory_guard' -and $safe.source_line -eq 123)
foreach($definition in @(
 @{key='step';values=@('initialization','owned_lookup','gateway_guard','native_quiescence','native_contacts','backup_inventory','owned_rows_delete','update_commands_delete','backup_commands_delete','drafts_delete','archive_files_delete','cache_cleanup','native_reload','factory_guard','input_commit')},
 @{key='reason';values=@('owned_service_lookup','enabled_gateway','active_calls','phone_identity','live_contact','missing_backup_command','backup_command_guard','backup_metadata_guard','backup_link','backup_integrity','original_command','command_ownership','backup_command_changed','original_draft','draft_ownership','archive_unlink','factory_not_empty','database_error','json_error','type_error','runtime_guard','external_error')},
 @{key='error_type';values=@('RuntimeException','PDOException','JsonException','TypeError','ValueError','Error','Exception','external_error')},
 @{key='source_basename';values=@('windows-restore-qualification.php','database.php','pbx_paths.php','cache.php','event_socket.php','config.php','external_component')}
)){
 foreach($value in $definition.values){$candidate=Clone $good;$candidate.($definition.key)=$value;$projected=SafeRestoreFixtureFailure $candidate;Assert ($null -ne $projected -and $projected.($definition.key) -ceq $value)}
}
foreach($key in $good.Keys){
 foreach($value in @($null,$true,$false,@(),@{},1.5,'PRIVATE SQL password C:/private')){
  $candidate=Clone $good;$candidate.$key=$value;Assert ($null -eq (SafeRestoreFixtureFailure $candidate))
 }
 $candidate=Clone $good;$candidate.PSObject.Properties.Remove($key);Assert ($null -eq (SafeRestoreFixtureFailure $candidate))
}
foreach($value in -1,0,1000000,'123'){$candidate=Clone $good;$candidate.source_line=$value;Assert ($null -eq (SafeRestoreFixtureFailure $candidate))}
foreach($value in 0,2,'1'){$candidate=Clone $good;$candidate.schema=$value;Assert ($null -eq (SafeRestoreFixtureFailure $candidate))}
foreach($value in 1,([long]1)){$candidate=Clone $good;$candidate.schema=$value;Assert ($null -ne (SafeRestoreFixtureFailure $candidate))}
foreach($value in 1,999999){$candidate=Clone $good;$candidate.source_line=$value;Assert ($null -ne (SafeRestoreFixtureFailure $candidate))}
$candidate=Clone $good;$candidate|Add-Member noteproperty message 'PRIVATE SQL password C:/private';Assert ($null -eq (SafeRestoreFixtureFailure $candidate))
Assert ($null -eq (SafeRestoreFixtureFailure $null))
Assert ($null -eq (SafeRestoreFixtureFailure @($good,$good)))
$candidate=Clone $good;$candidate.action=@('cleanup');Assert ($null -eq (SafeRestoreFixtureFailure $candidate))
$candidate=Clone $good;$candidate.step='FACTORY_GUARD';Assert ($null -eq (SafeRestoreFixtureFailure $candidate))
$peerGood=@{peer_index=0;stage='unregister';status_code=503;error_type='check_failed';source_basename='windows-restore-qualification.py';source_line=408}
$peerFields=SafeRestorePeerFailures @((Clone $peerGood));Assert ($peerFields.Count -eq 1 -and $peerFields[0].status_code -eq 503)
foreach($key in $peerGood.Keys){foreach($value in @($null,$true,$false,@(),@{},1.5,'PRIVATE password/path')){$candidate=Clone $peerGood;$candidate.$key=$value;Assert ($null -eq (SafeRestorePeerFailures @($candidate)))}}
foreach($stage in 'unregister','registration_ids','flush_registration','contact_absence','peer_close'){$candidate=Clone $peerGood;$candidate.stage=$stage;Assert ($null -ne (SafeRestorePeerFailures @($candidate)))}
foreach($definition in @(@{key='peer_index';values=@(-1,2)},@{key='status_code';values=@(-1,1,99,700)},@{key='source_line';values=@(-1,1000000)})){foreach($value in $definition.values){$candidate=Clone $peerGood;$candidate.($definition.key)=$value;Assert ($null -eq (SafeRestorePeerFailures @($candidate)))}}
$candidate=Clone $peerGood;$candidate|Add-Member noteproperty message 'PRIVATE';Assert ($null -eq (SafeRestorePeerFailures @($candidate)))
Assert ($null -eq (SafeRestorePeerFailures (@($peerGood)*13)))
$receiver=Clone $peerGood;$receiver.stage='receiver';$receiver|Add-Member noteproperty winerror_kind 'connection_reset_10054'
Assert ($null -ne (SafeRestorePeerFailures @($receiver) -Receiver))
Assert ($null -eq (SafeRestorePeerFailures @($receiver)))
Assert ($null -eq (SafeRestorePeerFailures @($peerGood) -Receiver))
Assert ($null -eq (SafeRestorePeerFailures (@($receiver)*3) -Receiver))
foreach($kind in 'connection_reset_10054','other_winerror','unavailable'){$candidate=Clone $receiver;$candidate.winerror_kind=$kind;Assert ($null -ne (SafeRestorePeerFailures @($candidate) -Receiver))}
foreach($kind in $null,$true,10054,@(),@{},'PRIVATE'){$candidate=Clone $receiver;$candidate.winerror_kind=$kind;Assert ($null -eq (SafeRestorePeerFailures @($candidate) -Receiver))}

$mailboxGood=@{mailbox_pin_sent=$true;mailbox_tutorial_skip_sent=$true;mailbox_prompt_password_seen=$true;mailbox_prompt_tutorial_seen=$true;mailbox_prompt_main_menu_seen=$false;mailbox_prompt_auth_failed_seen=$false;mailbox_prompt_recording_seen=$false;mailbox_observer_failed=$false}
Assert ((SafeRestoreMailboxFailure (Clone $mailboxGood) 'native-target').Count -eq 8)
foreach($key in $mailboxGood.Keys){
 foreach($value in $true,$false){Assert ((SafeRestoreMailboxFailure @{$key=$value} 'native-target').$key -eq $value)}
 foreach($value in $null,0,1,1.5,'PRIVATE password/path',@(),@{}){
  $candidate=Clone $mailboxGood;$candidate.$key=$value;Assert ($null -eq (SafeRestoreMailboxFailure $candidate 'native-target'))
 }
}
foreach($action in 'native-source','cleanup','PRIVATE','NATIVE-TARGET'){Assert ($null -eq (SafeRestoreMailboxFailure $mailboxGood $action))}
foreach($bad in $null,@(),@{},@($mailboxGood),@{PRIVATE=$true}){Assert ($null -eq (SafeRestoreMailboxFailure $bad 'native-target'))}
$candidate=Clone $mailboxGood;$candidate|Add-Member noteproperty message 'PRIVATE';Assert ($null -eq (SafeRestoreMailboxFailure $candidate 'native-target'))
$cliGood=@{exit_code=1;error_type='BackupError';category='operation_busy';source_frames=@(@{source_basename='backups.py';source_line=249;function='exclusive_guard'})}
Assert ((SafeRestoreCliFailure (Clone $cliGood)).Count -eq 4)
foreach($key in $cliGood.Keys){
 foreach($value in @($null,$true,$false,@(),@{},1.5,'PRIVATE')){
  if($key -ceq 'exit_code' -and $null -eq $value){continue}
  if($key -ceq 'source_frames' -and $value -is [Array] -and $value.Count -eq 0){continue}
  $candidate=Clone $cliGood;$candidate.$key=$value;Assert ($null -eq (SafeRestoreCliFailure $candidate))
 }
 $candidate=Clone $cliGood;$candidate.PSObject.Properties.Remove($key);Assert ($null -eq (SafeRestoreCliFailure $candidate))
}
foreach($value in $null,0,255,([long]1)){$candidate=Clone $cliGood;$candidate.exit_code=$value;Assert ($null -ne (SafeRestoreCliFailure $candidate))}
foreach($value in -1,256,'1'){$candidate=Clone $cliGood;$candidate.exit_code=$value;Assert ($null -eq (SafeRestoreCliFailure $candidate))}
foreach($type in 'BackupError','PermissionError','FileNotFoundError','OSError','ValueError','TypeError','RuntimeError','JSONDecodeError','other','unavailable'){$candidate=Clone $cliGood;$candidate.error_type=$type;Assert ($null -ne (SafeRestoreCliFailure $candidate))}
foreach($category in 'operation_busy','operation_lock_review','activation_server_guard','activation_selection_guard','activation_service_missing','required_tool_failed','required_tool_unavailable','private_control_unavailable','unclassified'){$candidate=Clone $cliGood;$candidate.category=$category;Assert ($null -ne (SafeRestoreCliFailure $candidate))}
foreach($function in 'main','activate','exclusive_guard','control','run','read_settings','ordinary','reparse','atomic_json','held','lock_file','unlock_file'){$candidate=Clone $cliGood;$candidate.source_frames[0].function=$function;Assert ($null -ne (SafeRestoreCliFailure $candidate))}
foreach($definition in @(@{key='source_basename';values=@('PRIVATE.py',@('backups.py'))},@{key='function';values=@('PRIVATE',@('main'))},@{key='source_line';values=@(0,-1,1000000,$true,'249')})){
 foreach($value in $definition.values){$candidate=Clone $cliGood;$candidate.source_frames[0].($definition.key)=$value;Assert ($null -eq (SafeRestoreCliFailure $candidate))}
}
$candidate=Clone $cliGood;$candidate.source_frames=@();Assert ((SafeRestoreCliFailure $candidate).source_frames.Count -eq 0)
$candidate=Clone $cliGood;$candidate.source_frames=@($candidate.source_frames*5);Assert ($null -eq (SafeRestoreCliFailure $candidate))
$candidate=Clone $cliGood;$candidate|Add-Member noteproperty message 'PRIVATE';Assert ($null -eq (SafeRestoreCliFailure $candidate))
$candidate=Clone $cliGood;$candidate.source_frames[0]|Add-Member noteproperty path 'PRIVATE';Assert ($null -eq (SafeRestoreCliFailure $candidate))
$toneGood=@{expected_hz=550;sample_count=16000;tone_ratio=0.799;sent_packets=350;received_packets=348;unexpected_audio_packets=0}
foreach($action in 'native-source','native-target'){Assert ((SafeRestoreToneFailure (Clone $toneGood) $action).Count -eq 6)}
foreach($key in $toneGood.Keys){
 foreach($value in @($true,$false,'PRIVATE',@(),@{})){$candidate=Clone $toneGood;$candidate.$key=$value;Assert ($null -eq (SafeRestoreToneFailure $candidate 'native-source'))}
 $candidate=Clone $toneGood;$candidate.PSObject.Properties.Remove($key);Assert ($null -eq (SafeRestoreToneFailure $candidate 'native-source'))
}
foreach($definition in @(@{key='expected_hz';values=@(0,660)},@{key='sample_count';values=@(-1,16001,1.5)},@{key='tone_ratio';values=@(-0.1,2.01,[double]::NaN,[double]::PositiveInfinity)},@{key='received_packets';values=@(-1,10000001,1.5)})){
 foreach($value in $definition.values){$candidate=Clone $toneGood;$candidate.($definition.key)=$value;Assert ($null -eq (SafeRestoreToneFailure $candidate 'native-source'))}
}
foreach($key in 'tone_ratio','sent_packets','received_packets','unexpected_audio_packets'){$candidate=Clone $toneGood;$candidate.$key=$null;Assert ($null -ne (SafeRestoreToneFailure $candidate 'native-source'))}
$candidate=Clone $toneGood;$candidate|Add-Member noteproperty pcm 'PRIVATE';Assert ($null -eq (SafeRestoreToneFailure $candidate 'native-source'))
Assert ($null -eq (SafeRestoreToneFailure (Clone $toneGood) 'restore'))
$work=Join-Path ([IO.Path]::GetTempPath()) ('openweb-restore-projection-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $work
$python='fictional-extracted-python';$source='fictional-source';$inputFile='fictional-private-input'
$script:childFailure=[InvalidOperationException]::new('PRIVATE child failure preserved')
$script:childRecord=$null;$script:seen=$null;$script:childOutputHook=$null
function CheckedProcess($Executable,$Arguments,$Label,$WorkingDirectory,$Timeout){
 $script:seen=@($Executable,$Arguments,$Label,$WorkingDirectory,$Timeout)
 $privateOutput=Join-Path $work ($Label+'.out')
 if($script:childRecord){[IO.File]::WriteAllText($privateOutput,($script:childRecord|ConvertTo-Json -Depth 20 -Compress))}
 elseif(Test-Path $privateOutput){Remove-Item -LiteralPath $privateOutput}
 if($script:childOutputHook){& $script:childOutputHook $privateOutput}
 throw $script:childFailure
}
try{
 # A real temporary source file preserves PSScriptRoot for the unmodified
 # extracted function; only CheckedProcess is replaced by the private delegate.
 $definitions=Join-Path $work 'actual-functions.ps1';[IO.File]::WriteAllText($definitions,$nativeDefinition)
 . $definitions
 foreach($mode in 'valid','extra','wrong_action','missing','private_message'){
  $facts=@{};$observation=Clone $good
  $script:childRecord=[ordered]@{state='failed';error_type='RuntimeError';source_basename='windows-restore-qualification.py';source_line=237}
  if($mode -eq 'extra'){$observation|Add-Member noteproperty message 'PRIVATE SQL password C:/private'}
  if($mode -eq 'wrong_action'){$observation.action='snapshot'}
  if($mode -eq 'private_message'){$observation.reason='PRIVATE SQL password C:/private'}
  if($mode -ne 'missing'){$script:childRecord.fixture_failure=$observation}
  $caught=$null;try{NativeFixture 'cleanup'}catch{$caught=$_}
  Assert ($null -ne $caught -and [object]::ReferenceEquals($caught.Exception,$script:childFailure))
  Assert ($facts.native_failure.error_type -ceq 'RuntimeError' -and $facts.native_failure.source_basename -ceq 'windows-restore-qualification.py' -and $facts.native_failure.source_line -eq 237 -and $facts.native_failure.active_case -ceq 'cleanup')
  Assert ($script:seen[0] -ceq $python -and $script:seen[2] -ceq 'restore-cleanup' -and $script:seen[3] -ceq $source -and $script:seen[4] -eq 1200000)
  Assert (($script:seen[1] -join '|') -ceq ('-I|-B|'+(Join-Path $work 'windows-restore-qualification.py')+'|--input|'+$inputFile+'|--action|cleanup'))
  Assert (($null -ne $facts.native_failure.fixture_failure) -eq ($mode -eq 'valid'))
  Assert (($facts|ConvertTo-Json -Depth 20 -Compress) -notmatch 'PRIVATE|password|C:/private')
 }
 $facts=@{};$script:childRecord.fixture_failure=Clone $good
 try{NativeFixture 'restore'}catch{}
 Assert ($facts.native_failure.active_case -ceq 'restore' -and $null -eq $facts.native_failure.fixture_failure)
 foreach($action in 'export-source','target-backup'){
  foreach($mode in 'int','long','low','high','zero','negative','too_high','string','boolean','array','object','missing','wrong_action','wrong_type','wrong_source','array_type','array_source'){
   $facts=@{};$invoke=$action
   $script:childRecord=@{state='failed';error_type='BackupError';source_basename='backups.py';source_line=292;query_caller_line=726;message='PRIVATE SQL password C:/secret';sql='PRIVATE'}
   switch($mode){
    'long'{$script:childRecord.query_caller_line=[long]726}
    'low'{$script:childRecord.query_caller_line=1}
    'high'{$script:childRecord.query_caller_line=999999}
    'zero'{$script:childRecord.query_caller_line=0}
    'negative'{$script:childRecord.query_caller_line=-1}
    'too_high'{$script:childRecord.query_caller_line=1000000}
    'string'{$script:childRecord.query_caller_line='726'}
    'boolean'{$script:childRecord.query_caller_line=$true}
    'array'{$script:childRecord.query_caller_line=@(726)}
    'object'{$script:childRecord.query_caller_line=@{message='PRIVATE'}}
    'missing'{$script:childRecord.Remove('query_caller_line')}
    'wrong_action'{$invoke='cleanup'}
    'wrong_type'{$script:childRecord.error_type='RuntimeError'}
    'wrong_source'{$script:childRecord.source_basename='foreign.py'}
    'array_type'{$script:childRecord.error_type=@('BackupError')}
    'array_source'{$script:childRecord.source_basename=@('backups.py')}
   }
   $caught=$null;try{NativeFixture $invoke}catch{$caught=$_}
   Assert ([object]::ReferenceEquals($caught.Exception,$script:childFailure))
   $expected=$mode -cin @('int','long','low','high')
   Assert (($null -ne $facts.native_failure.query_caller_line) -eq $expected)
   if($expected){Assert ($facts.native_failure.query_caller_line -eq $script:childRecord.query_caller_line)}
   Assert (($facts|ConvertTo-Json -Depth 20 -Compress) -notmatch 'PRIVATE|SQL|password|C:/secret')
  }
 }
 foreach($mode in 'missing','malformed','oversized','directory','metadata_failure'){
  $facts=@{native_failure=@{error_type='BackupError';source_basename='backups.py';source_line=292}}
  $script:childRecord=@{state='failed';error_type='BackupError';source_basename='backups.py';source_line=292;query_caller_line=726}
  # A stale caller-scope value must not be consumed if fresh output is absent/bad.
  $safe=$script:childRecord
  $script:childOutputHook={param($Output)
   switch($mode){
    'missing'{Remove-Item -LiteralPath $Output}
    'malformed'{[IO.File]::WriteAllText($Output,'PRIVATE invalid JSON')}
    'oversized'{[IO.File]::AppendAllText($Output,(' '*1048577))}
    'directory'{Remove-Item -LiteralPath $Output;$null=New-Item -ItemType Directory -Path $Output}
    'metadata_failure'{function script:Get-Item {throw [IO.IOException]::new('PRIVATE metadata failure')}}
   }
  }
  $caught=$null;try{NativeFixture 'target-backup'}catch{$caught=$_}
  Assert ([object]::ReferenceEquals($caught.Exception,$script:childFailure))
  Assert ($null -eq $facts.native_failure.query_caller_line)
  Assert (($facts|ConvertTo-Json -Depth 20 -Compress) -notmatch 'PRIVATE|SQL|password')
  $script:childOutputHook=$null
  if($mode -eq 'metadata_failure'){Remove-Item Function:\Get-Item}
  $privateOutput=Join-Path $work 'restore-target-backup.out'
  if(Test-Path -LiteralPath $privateOutput){Remove-Item -LiteralPath $privateOutput -Recurse -Force}
 }
 foreach($action in 'export-source','late-restore','restore','activate-calls','job','activate-updates','activate-backups','activate-updates-backups','target-backup'){
  foreach($mode in 'valid','empty_frames','extra','unknown_frame','wrong_type','wrong_source','wrong_action','passed_state','missing'){
   $facts=@{native_failure=@{error_type='RuntimeError';source_basename='windows-restore-qualification.py';source_line=414}};$invoke=$action;$observation=Clone $cliGood
   $script:childRecord=@{state='failed';error_type='RuntimeError';source_basename='windows-restore-qualification.py';source_line=414;cli_failure=$observation;message='PRIVATE SQL password/path'}
   switch($mode){
    'empty_frames'{$observation.source_frames=@()}
    'extra'{$observation|Add-Member noteproperty message 'PRIVATE'}
    'unknown_frame'{$observation.source_frames[0].function='PRIVATE'}
    'wrong_type'{$script:childRecord.error_type='BackupError'}
    'wrong_source'{$script:childRecord.source_basename='backups.py'}
    'wrong_action'{$invoke='native-target'}
    'passed_state'{$script:childRecord.state='passed'}
    'missing'{$script:childRecord.Remove('cli_failure')}
   }
   $caught=$null;try{NativeFixture $invoke}catch{$caught=$_}
   Assert ([object]::ReferenceEquals($caught.Exception,$script:childFailure))
   Assert (($null -ne $facts.native_failure.cli_failure) -eq ($mode -cin @('valid','empty_frames')))
   if($mode -ceq 'valid'){Assert ($facts.native_failure.cli_failure.exit_code -eq 1 -and $facts.native_failure.cli_failure.source_frames[0].function -ceq 'exclusive_guard')}
   Assert (($facts|ConvertTo-Json -Depth 20 -Compress) -notmatch 'PRIVATE|SQL|password|path')
  }
 }
 foreach($field in 'hardware_uuid_hmac','hostname_hmac','certificate_sha256','template_key_sha256'){
  foreach($mode in 'valid','unknown_kind','private_field','array_field','wrong_action','wrong_type','wrong_source','missing_kind','missing_field'){
   $facts=@{};$action='late-restore'
   $script:childRecord=[ordered]@{state='failed';error_type='ValueError';source_basename='windows-restore-qualification.py';source_line=149;failure_kind='non_distinct_installation_identity';identity_field=$field;message='PRIVATE SQL/password C:/secret'}
   switch($mode){
    'unknown_kind'{$script:childRecord.failure_kind='PRIVATE'}
    'private_field'{$script:childRecord.identity_field='PRIVATE'}
    'array_field'{$script:childRecord.identity_field=@($field)}
    'wrong_action'{$action='restore'}
    'wrong_type'{$script:childRecord.error_type='RuntimeError'}
    'wrong_source'{$script:childRecord.source_basename='fictional.php'}
    'missing_kind'{$script:childRecord.Remove('failure_kind')}
    'missing_field'{$script:childRecord.Remove('identity_field')}
   }
   $caught=$null;try{NativeFixture $action}catch{$caught=$_}
   Assert ($null -ne $caught -and [object]::ReferenceEquals($caught.Exception,$script:childFailure))
   Assert ($facts.native_failure.error_type -ceq $script:childRecord.error_type -and $facts.native_failure.source_basename -ceq $script:childRecord.source_basename -and $facts.native_failure.source_line -eq 149 -and $facts.native_failure.active_case -ceq $action)
   Assert (($null -ne $facts.native_failure.failure_kind) -eq ($mode -eq 'valid'))
   Assert (($null -ne $facts.native_failure.identity_field) -eq ($mode -eq 'valid'))
   if($mode -eq 'valid'){Assert ($facts.native_failure.failure_kind -ceq 'non_distinct_installation_identity' -and $facts.native_failure.identity_field -ceq $field)}
   Assert (($facts|ConvertTo-Json -Depth 20 -Compress) -notmatch 'PRIVATE|password|C:/secret')
  }
 }
 foreach($label in 'target-wrongpass','target-recovered','target-restored'){
  foreach($mode in 'valid','wrong_action','wrong_type','wrong_source','wrong_label','extra','missing','all_false','integer','string'){
   $action=if($label -ceq 'target-restored'){'restore'}else{'late-restore'}
   $facts=@{};$groups=@{schema=$true;tables=$false;columns=$true}
   $script:childRecord=@{state='failed';error_type='ValueError';source_basename='windows-restore-qualification.py';source_line=243;comparison_label=$label;schema_groups_differ=$groups;message='PRIVATE SQL/password/path'}
   switch($mode){
    'wrong_action'{$action='cleanup'}
    'wrong_type'{$script:childRecord.error_type='RuntimeError'}
    'wrong_source'{$script:childRecord.source_basename='unknown.py'}
    'wrong_label'{$script:childRecord.comparison_label='PRIVATE'}
    'extra'{$groups.message='PRIVATE'}
    'missing'{$groups.Remove('columns')}
    'all_false'{$groups.schema=$false;$groups.columns=$false}
    'integer'{$groups.schema=1}
    'string'{$groups.schema='true'}
   }
   $caught=$null;try{NativeFixture $action}catch{$caught=$_}
   Assert ([object]::ReferenceEquals($caught.Exception,$script:childFailure))
   Assert (($null -ne $facts.native_failure.comparison_label) -eq ($mode -eq 'valid'))
   Assert (($null -ne $facts.native_failure.schema_groups_differ) -eq ($mode -eq 'valid'))
   if($mode -eq 'valid'){Assert ($facts.native_failure.comparison_label -ceq $label -and $facts.native_failure.schema_groups_differ.Count -eq 3 -and $facts.native_failure.schema_groups_differ.schema -eq $true -and $facts.native_failure.schema_groups_differ.tables -eq $false)}
   Assert (($facts|ConvertTo-Json -Depth 20 -Compress) -notmatch 'PRIVATE|SQL|password|path')
  }
 }
 foreach($action in 'native-source','native-target'){
  $names=if($action -ceq 'native-source'){@('source_real_two_way_recorded_call','source_real_native_voicemail_deposit')}else{@('restored_original_credentials_two_way_decoded_native_audio','restored_original_native_voicemail_pin_rfc2833_retrieval')}
  foreach($mode in 'valid','duplicate','oversize','wrong_action','private_case','private_peer'){
   $facts=@{gates=@{}};$script:childRecord=@{state='failed';error_type='AssertionError';source_basename='sip_trunk_live.py';source_line=249;peer_cleanup_failure=@((Clone $peerGood));peer_receiver_failure=@((Clone $receiver));native_substage='internal_ack';completed_native_cases=$names;message='PRIVATE'}
   switch($mode){
    'duplicate'{$script:childRecord.completed_native_cases=@($names[0],$names[0])}
    'oversize'{$script:childRecord.completed_native_cases=@($names[0],$names[0],$names[0])}
    'wrong_action'{$script:childRecord.completed_native_cases=@('source_real_two_way_recorded_call');if($action -ceq 'native-source'){$script:childRecord.completed_native_cases=@('restored_original_credentials_two_way_decoded_native_audio')}}
    'private_case'{$script:childRecord.completed_native_cases=@('PRIVATE')}
    'private_peer'{$script:childRecord.peer_cleanup_failure[0]|Add-Member noteproperty message 'PRIVATE';$script:childRecord.peer_receiver_failure[0].winerror_kind='PRIVATE';$script:childRecord.native_substage='PRIVATE'}
   }
   $caught=$null;try{NativeFixture $action}catch{$caught=$_}
   Assert ([object]::ReferenceEquals($caught.Exception,$script:childFailure))
   Assert ($facts.native_failure.error_type -ceq 'AssertionError' -and $facts.native_failure.source_line -eq 249)
   $validCases=$mode -in 'valid','private_peer';Assert (($facts.gates.Count -eq 2) -eq $validCases)
   Assert (($null -ne $facts.native_failure.peer_cleanup_failure) -eq ($mode -ne 'private_peer'))
   Assert (($null -ne $facts.native_failure.peer_receiver_failure) -eq ($mode -ne 'private_peer'))
   Assert (($null -ne $facts.native_failure.native_substage) -eq ($mode -ne 'private_peer'))
   Assert (($facts|ConvertTo-Json -Depth 20 -Compress) -notmatch 'PRIVATE|password|path')
  }
 }
 foreach($mode in 'valid','private','wrong_action','integer','empty'){
  $action=if($mode -ceq 'wrong_action'){'native-source'}else{'native-target'}
  $observation=Clone $mailboxGood
  if($mode -ceq 'private'){$observation|Add-Member noteproperty message 'PRIVATE'}
  if($mode -ceq 'integer'){$observation.mailbox_pin_sent=1}
  if($mode -ceq 'empty'){$observation=@{}}
  $facts=@{gates=@{}};$script:childRecord=@{state='failed';error_type='AssertionError';source_basename='windows-native-acceptance.py';source_line=246;native_substage='mailbox_tutorial_complete';mailbox_observation=$observation;completed_native_cases=@('restored_original_credentials_two_way_decoded_native_audio');message='PRIVATE'}
  $caught=$null;try{NativeFixture $action}catch{$caught=$_}
  Assert ([object]::ReferenceEquals($caught.Exception,$script:childFailure))
  Assert (($null -ne $facts.native_failure.mailbox_observation) -eq ($mode -ceq 'valid'))
  Assert (($facts.native_failure.native_substage -ceq 'mailbox_tutorial_complete') -eq ($action -ceq 'native-target'))
  if($mode -ceq 'valid'){Assert ($facts.native_failure.mailbox_observation.Count -eq 8 -and $facts.native_failure.mailbox_observation.mailbox_tutorial_skip_sent -eq $true -and $facts.gates.Count -eq 1)}
  Assert (($facts|ConvertTo-Json -Depth 20 -Compress) -notmatch 'PRIVATE|C:/private|SQL|"message"')
 }
 foreach($action in 'native-source','native-target'){
  foreach($mode in 'valid','short','extra','wrong_action','wrong_type','wrong_source','wrong_stage','passed','oversize'){
   $facts=@{gates=@{};native_failure=@{}};$observation=Clone $toneGood;$invoke=$action
   $script:childRecord=@{state='failed';error_type='AssertionError';source_basename='pbx_v20_restore_native.py';source_line=404;native_substage='internal_media';tone_observation=$observation;message='PRIVATE'}
   switch($mode){
    'short'{$observation.sample_count=3999;$observation.tone_ratio=$null}
    'extra'{$observation|Add-Member noteproperty pcm 'PRIVATE'}
    'wrong_action'{$invoke='restore'}
    'wrong_type'{$script:childRecord.error_type='RuntimeError'}
    'wrong_source'{$script:childRecord.source_basename='windows-restore-qualification.py'}
    'wrong_stage'{$script:childRecord.native_substage='internal_ack'}
    'passed'{$script:childRecord.state='passed';$facts.native_failure=@{error_type='AssertionError'}}
    'oversize'{$script:childOutputHook={param($Path)[IO.File]::WriteAllText($Path,('x'*1048577))}}
   }
   $caught=$null;try{NativeFixture $invoke}catch{$caught=$_};$script:childOutputHook=$null
   Assert ([object]::ReferenceEquals($caught.Exception,$script:childFailure))
   Assert (($null -ne $facts.native_failure.tone_observation) -eq ($mode -cin @('valid','short')))
   Assert (($facts|ConvertTo-Json -Depth 20 -Compress) -notmatch 'PRIVATE|decoded_pcm|address|"message"')
  }
 }
}finally{Remove-Item -LiteralPath $work -Recurse -Force}
Write-Output ("Restore cleanup/identity source/projection controls passed: {0}" -f $script:count)
