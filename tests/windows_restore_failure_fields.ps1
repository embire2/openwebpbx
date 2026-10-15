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
foreach($name in 'SafeRestoreFixtureFailure','SafeRestorePeerFailures','SafeRestoreSchemaFailure','NativeFixture'){
 $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
 if($nodes.Count -ne 1){throw 'One exact source function is required.'}
 if($name -eq 'NativeFixture'){$nativeDefinition=$nodes[0].Extent.Text}else{Invoke-Expression $nodes[0].Extent.Text}
}
$script:count=0
function Assert([bool]$Condition){$script:count++;if(!$Condition){throw ('A closed restore-observation control failed at source line '+(Get-PSCallStack)[1].ScriptLineNumber+'.')}}
function Clone($Value){return ($Value|ConvertTo-Json -Depth 20 -Compress|ConvertFrom-Json)}
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

$work=Join-Path ([IO.Path]::GetTempPath()) ('openweb-restore-projection-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $work
$python='fictional-extracted-python';$source='fictional-source';$inputFile='fictional-private-input'
$script:childFailure=[InvalidOperationException]::new('PRIVATE child failure preserved')
$script:childRecord=$null;$script:seen=$null
function CheckedProcess($Executable,$Arguments,$Label,$WorkingDirectory,$Timeout){
 $script:seen=@($Executable,$Arguments,$Label,$WorkingDirectory,$Timeout)
 $privateOutput=Join-Path $work ($Label+'.out')
 if($script:childRecord){[IO.File]::WriteAllText($privateOutput,($script:childRecord|ConvertTo-Json -Depth 20 -Compress))}
 elseif(Test-Path $privateOutput){Remove-Item -LiteralPath $privateOutput}
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
}finally{Remove-Item -LiteralPath $work -Recurse -Force}
Write-Output ("Restore cleanup/identity source/projection controls passed: {0}" -f $script:count)
