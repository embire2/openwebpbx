# Execute the actual versioned guards from both restore/updater entry points.
# No Windows installation, task, network request or signed package is simulated.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$script:checks=0
function Assert([bool]$Value){if(!$Value){throw ('Modern baseline control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
function Check([bool]$Value,[string]$Message){$script:guardCalls++;if(!$Value){throw 'EXACT_CURRENT_BASELINE_REFUSAL'}}
function DtlsProof {return [pscustomobject]@{state='passed';transaction_checks=62;crypto_checks=12;installed_checks=12;transaction_service_adapter_double=$true;actual_native_windows=$true}}
function PhpProof {return [pscustomobject]@{state='passed';actual_native=$true;checks=3052;vendor_files=79;installed_server_changed=$false;version='8.4.27'}}
function RecoveryProof {return [pscustomobject]@{state='passed';actual_native_windows=$true;actual_configured_updater_boot=$true;updater_scope='candidate_component';updater_version=$BaseVersion;integration_checks=64;native_checks=202;installed_server_changed=$false}}
function CommitProof {return [pscustomobject]@{state='passed';checks=133;guard_checks=52;actual_commit_interruption_positions=3;actual_native_windows=$true;service_adapter_double=$true;slot_assembly_fixture=$true;actual_running_image_lock=$true;old_silent_exit3_proven=$true;exact_mirror_refusal_retry=$true;completed_finalizer_idempotent=$true;before_commit_old_scm=$true;after_commit_resume=$true;after_selection_idempotent=$true;absent_creation_deferred=$true;legacy_missing_dependency_recovery=$true;actual_installed_scm=$false;installed_server_changed=$false}}
function ListenerProof {
 $native=[ordered]@{schema=1;state='passed';checks=21;producer='windows_public_listeners_native.ps1'}
 foreach($field in 'actual_native_defender','actual_os_listener_ownership','service_identity_adapter_double','global_policy_exact','actual_throw_after_create_and_enable','idempotent','foreign_named_rule_preserved','configured_private_ports_excluded','profiles_all_enabled_at_observation'){$native[$field]=$true}
 foreach($field in 'firewall_enforcement_tested','firewall_profiles_changed','installed_server_changed','calls_placed'){$native[$field]=$false}
 $installed=[ordered]@{schema=1;state='passed';checks=14;producer='windows_public_listener_installed.ps1'}
 foreach($field in 'actual_installed_php_pg_esl_os','exact_installed_helper_manifest','provider_5080_tcp_udp_planned','tls_only_when_actually_bound','configured_default_audio_source','private_service_ports_excluded','read_only_preflight'){$installed[$field]=$true}
 foreach($field in 'firewall_or_configuration_mutated','calling_or_audio_acceptance','installed_server_changed'){$installed[$field]=$false}
 return [pscustomobject]@{state='passed';outside_acme='unqualified';native_defender=[pscustomobject]$native;installed_collector=[pscustomobject]$installed}
}
function Refuses([scriptblock]$Action){$caught=$null;try{& $Action}catch{$caught=$_.Exception.Message};Assert ($caught -ceq 'EXACT_CURRENT_BASELINE_REFUSAL')}
$tokens=$null;$errors=$null;$producer=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-suite.ps1'),[ref]$tokens,[ref]$errors);Assert ($errors.Count -eq 0)
$projection=@($producer.FindAll({param($node)$node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$facts.dtls_qualification' -and $node.Right.Extent.Text.StartsWith("@{state='passed';transaction_checks=")},$true));Assert ($projection.Count -eq 1)
# Execute the actual current producer projection, without its native runner.
$report=[pscustomobject]@{transaction_checks=63;crypto_checks=12;installed_checks=12};$facts=@{};Invoke-Expression $projection[0].Extent.Text
$producedDtls=$facts.dtls_qualification
$phpProjection=@($producer.FindAll({param($node)$node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$facts.php_runtime_qualification' -and $node.Right.Extent.Text.StartsWith("@{state='passed';actual_native=")},$true));Assert ($phpProjection.Count -eq 1)
$report=[pscustomobject]@{checks=3052;vendor_files=79;new_version='8.4.27'};$facts=@{};Invoke-Expression $phpProjection[0].Extent.Text;$producedPhp=$facts.php_runtime_qualification
$recoveryProjection=@($producer.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Read-UpgradeRecoveryQualificationReport'},$true));Assert ($recoveryProjection.Count -eq 1);Invoke-Expression $recoveryProjection[0].Extent.Text
$listenerProducer=@($producer.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Read-PublicListenerQualificationReport'},$true));Assert ($listenerProducer.Count -eq 1);Invoke-Expression $listenerProducer[0].Extent.Text
$oldTokens=$null;$oldErrors=$null;$oldAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/fixtures/windows-modern-baseline-before-runtime.ps1'),[ref]$oldTokens,[ref]$oldErrors);Assert ($oldErrors.Count -eq 0)
$oldNodes=@($oldAst.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.IfStatementAst]});Assert ($oldNodes.Count -eq 1);$oldGuard=[scriptblock]::Create($oldNodes[0].Extent.Text)
$modern=@('web_readiness','tenant_domains','meeting_transport','meeting_browser','phone_health','stun','native_clock','native_providers','native_call_me_back')
foreach($consumer in 'windows-updater-qualification.ps1','windows-restore-qualification.ps1'){
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot ('tests/'+$consumer)),[ref]$tokens,[ref]$errors);Assert ($errors.Count -eq 0)
 $nodes=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith('if([version]$BaseVersion -ge ') -and $node.Extent.Text.Contains("'web_readiness'")},$true));Assert ($nodes.Count -eq 1)
 $guard=[scriptblock]::Create($nodes[0].Extent.Text)
 foreach($version in '1.0.20','1.0.21'){
  $BaseVersion=$version;$values=@{};foreach($gate in $modern){$values[$gate]='passed'};$baseFacts=[pscustomobject]@{gates=[pscustomobject]$values;dtls_qualification=(DtlsProof);php_runtime_qualification=(PhpProof);upgrade_recovery_qualification=(RecoveryProof);native_commit_selection=(CommitProof);public_listener_qualification=(ListenerProof)}
  $script:guardCalls=0;& $guard;Assert ($script:guardCalls -eq 78)
  foreach($gate in $modern){
   $badValues=@($null,$true,$false,0,1,'Passed','passed ','partial','running','unqualified',@('passed'),@('passed','unqualified'),@{},[pscustomobject]@{state='passed'})
   foreach($bad in $badValues){
    $baseFacts.gates.$gate=$bad;$caught=$null;$script:guardCalls=0;try{& $guard}catch{$caught=$_.Exception.Message}
    Assert ($caught -ceq 'EXACT_CURRENT_BASELINE_REFUSAL' -and $script:guardCalls -ge 1 -and $script:guardCalls -le 9)
   }
   $baseFacts.gates.PSObject.Properties.Remove($gate);$caught=$null;try{& $guard}catch{$caught=$_.Exception.Message};Assert ($caught -ceq 'EXACT_CURRENT_BASELINE_REFUSAL')
   $baseFacts.gates|Add-Member -NotePropertyName $gate -NotePropertyValue 'passed'
  }
  $script:guardCalls=0;& $guard;Assert ($script:guardCalls -eq 78)
  foreach($currentRecord in @($producedDtls,(ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $producedDtls -Compress)))){$baseFacts.dtls_qualification=$currentRecord;$script:guardCalls=0;& $guard;Assert ($script:guardCalls -eq 78)}
  foreach($bad in @($null,$true,$false,0,1,'passed','unqualified_historical_candidate',@('passed'),@((DtlsProof)),@{},[pscustomobject]@{state='passed'})){
   $baseFacts.dtls_qualification=$bad;$caught=$null;try{& $guard}catch{$caught=$_.Exception.Message};Assert ($caught -ceq 'EXACT_CURRENT_BASELINE_REFUSAL')
  }
  $baseFacts.dtls_qualification=DtlsProof
  foreach($field in 'state','transaction_checks','crypto_checks','installed_checks','transaction_service_adapter_double','actual_native_windows'){
   $minimum=switch($field){'transaction_checks'{62};'crypto_checks'{12};'installed_checks'{12};default{0}}
   $badValues=switch($field){
    'state'{@($null,$true,1,'Passed','passed ','failed','partial',@('passed'),@{})}
    {$_ -in 'actual_native_windows','transaction_service_adapter_double'}{@($null,$false,0,1,'true',@($true),@{})}
    default{@($null,$true,$false,0,($minimum-1),10001,1.5,([decimal]$minimum),([string]$minimum),@($minimum),@{})}
   }
   foreach($bad in $badValues){$baseFacts.dtls_qualification=DtlsProof;$baseFacts.dtls_qualification.$field=$bad;$caught=$null;try{& $guard}catch{$caught=$_.Exception.Message};Assert ($caught -ceq 'EXACT_CURRENT_BASELINE_REFUSAL')}
   $baseFacts.dtls_qualification=DtlsProof;$baseFacts.dtls_qualification.PSObject.Properties.Remove($field);$caught=$null;try{& $guard}catch{$caught=$_.Exception.Message};Assert ($caught -ceq 'EXACT_CURRENT_BASELINE_REFUSAL')
  }
  $baseFacts.dtls_qualification=DtlsProof;$baseFacts.PSObject.Properties.Remove('dtls_qualification');$caught=$null;try{& $guard}catch{$caught=$_.Exception.Message};Assert ($caught -ceq 'EXACT_CURRENT_BASELINE_REFUSAL')
  $baseFacts|Add-Member NoteProperty dtls_qualification (DtlsProof)
  foreach($value in 62,([long]62),10000){$baseFacts.dtls_qualification=DtlsProof;$baseFacts.dtls_qualification.transaction_checks=$value;$script:guardCalls=0;& $guard;Assert ($script:guardCalls -eq 78)}
  $baseFacts.dtls_qualification=DtlsProof
  # Actual current producer projections must be accepted after JSON transport.
  $nativeRecord=[pscustomobject]@{schema=1;producer='windows-upgrade-recovery-qualification.ps1';state='passed';actual_native_windows=$true;actual_configured_updater_boot=$true;integration_checks=64;native_checks=202;updater_version=$BaseVersion;updater_scope='candidate_component';installed_server_changed=$false}
  $producedRecovery=Read-UpgradeRecoveryQualificationReport $nativeRecord $BaseVersion
  foreach($pair in @(@('php_runtime_qualification',$producedPhp),@('upgrade_recovery_qualification',$producedRecovery))){foreach($record in @($pair[1],(ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $pair[1] -Compress)))){$baseFacts.($pair[0])=$record;$script:guardCalls=0;& $guard;Assert ($script:guardCalls -eq 78)}}
  foreach($kind in 'php_runtime_qualification','upgrade_recovery_qualification'){
   foreach($bad in @($null,$true,$false,0,1,'passed','unqualified_historical_candidate',@('passed'),@((PhpProof)),@{},[pscustomobject]@{state='passed'})){$baseFacts.$kind=$bad;Refuses {& $guard}}
   $baseFacts.$kind=if($kind -ceq 'php_runtime_qualification'){PhpProof}else{RecoveryProof}
   $baseFacts.PSObject.Properties.Remove($kind);Refuses {& $guard}
   $baseFacts|Add-Member NoteProperty $kind $(if($kind -ceq 'php_runtime_qualification'){PhpProof}else{RecoveryProof})
  }
  $rows=@(
   @('php_runtime_qualification','state','state',0),@('php_runtime_qualification','version','php_version',0),@('php_runtime_qualification','actual_native','true',0),@('php_runtime_qualification','installed_server_changed','false',0),@('php_runtime_qualification','checks','number',3000),@('php_runtime_qualification','vendor_files','vendor',79),
   @('upgrade_recovery_qualification','state','state',0),@('upgrade_recovery_qualification','updater_scope','scope',0),@('upgrade_recovery_qualification','updater_version','candidate_version',0),@('upgrade_recovery_qualification','actual_native_windows','true',0),@('upgrade_recovery_qualification','actual_configured_updater_boot','true',0),@('upgrade_recovery_qualification','installed_server_changed','false',0),@('upgrade_recovery_qualification','integration_checks','number',64),@('upgrade_recovery_qualification','native_checks','number',202)
  )
  foreach($row in $rows){
   $kind=$row[0];$field=$row[1];$minimum=$row[3]
   $badValues=switch($row[2]){
    'state'{@($null,$true,1,'Passed','passed ','failed','partial',@('passed'),@{})}
    'php_version'{@($null,$true,1,'8.4.26','8.4.27 ','8.4.27.0',@('8.4.27'),@{})}
    'scope'{@($null,$true,1,'legacy_component','candidate_component ','Candidate_Component',@('candidate_component'),@{})}
    'candidate_version'{@($null,$true,1,'1.0.6',($BaseVersion+'.0'),($BaseVersion+' '),@($BaseVersion),@{})}
    'true'{@($null,$false,0,1,'true',@($true),@{})}
    'false'{@($null,$true,0,1,'false',@($false),@{})}
    'vendor'{@($null,$true,$false,0,78,80,100001,1.5,([decimal]79),'79',@(79),@{})}
    default{@($null,$true,$false,0,($minimum-1),100001,1.5,([decimal]$minimum),([string]$minimum),@($minimum),@{})}
   }
   foreach($bad in $badValues){$baseFacts.$kind=if($kind -ceq 'php_runtime_qualification'){PhpProof}else{RecoveryProof};$baseFacts.$kind.$field=$bad;Refuses {& $guard}}
   $baseFacts.$kind=if($kind -ceq 'php_runtime_qualification'){PhpProof}else{RecoveryProof};$baseFacts.$kind.PSObject.Properties.Remove($field);Refuses {& $guard}
   foreach($value in $minimum,([long]$minimum)){
    if($row[2] -cnotin 'number','vendor'){continue}
    $baseFacts.$kind=if($kind -ceq 'php_runtime_qualification'){PhpProof}else{RecoveryProof};$baseFacts.$kind.$field=$value;$script:guardCalls=0;& $guard;Assert ($script:guardCalls -eq 78)
   }
   if($row[2] -ceq 'number'){$baseFacts.$kind.$field=100000;$script:guardCalls=0;& $guard;Assert ($script:guardCalls -eq 78)}
   $baseFacts.$kind=if($kind -ceq 'php_runtime_qualification'){PhpProof}else{RecoveryProof}
  }
  foreach($bad in @($null,$true,1,'passed','unqualified_historical_candidate',@((CommitProof)),@{},[pscustomobject]@{state='passed'})){$baseFacts.native_commit_selection=$bad;Refuses {& $guard}}
  $baseFacts.native_commit_selection=CommitProof
  foreach($field in @((CommitProof).PSObject.Properties.Name)){
   $minimum=switch($field){'checks'{133};'guard_checks'{52};'actual_commit_interruption_positions'{3};default{0}}
   $badValues=if($field -ceq 'state'){@($null,$true,1,'Passed','passed ','failed',@('passed'),@{})}elseif($minimum){@($null,$true,0,($minimum-1),100001,1.5,([decimal]$minimum),([string]$minimum),@($minimum),@{})}else{@($null,1,'true',@($true),@{},(-not (CommitProof).$field))}
   if($field -ceq 'actual_commit_interruption_positions'){$badValues+=4}
   foreach($bad in $badValues){$baseFacts.native_commit_selection=CommitProof;$baseFacts.native_commit_selection.$field=$bad;Refuses {& $guard}}
   $baseFacts.native_commit_selection=CommitProof;$baseFacts.native_commit_selection.PSObject.Properties.Remove($field);Refuses {& $guard}
   $baseFacts.native_commit_selection=CommitProof
   if($minimum){foreach($value in $minimum,([long]$minimum)){$baseFacts.native_commit_selection.$field=$value;$script:guardCalls=0;& $guard;Assert ($script:guardCalls -eq 78)}}
  }
  $baseFacts.native_commit_selection=CommitProof;$baseFacts.PSObject.Properties.Remove('native_commit_selection');Refuses {& $guard};$baseFacts|Add-Member NoteProperty native_commit_selection (CommitProof)
  # Use both actual producer projections, then independently corrupt each typed field.
  $listener=ListenerProof
  foreach($kind in 'native_defender','installed_collector'){$listener.$kind=Read-PublicListenerQualificationReport $listener.$kind $kind 0}
  foreach($record in @($listener,(ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $listener -Depth 10 -Compress)))){$baseFacts.public_listener_qualification=$record;$script:guardCalls=0;& $guard;Assert ($script:guardCalls -eq 78)}
  foreach($bad in @($null,$true,$false,1,'unqualified_historical_candidate',@((ListenerProof)),@{},[pscustomobject]@{state='passed'})){$baseFacts.public_listener_qualification=$bad;Refuses {& $guard}}
  foreach($row in @(@('state','passed'),@('outside_acme','unqualified'))){
   foreach($bad in @($null,$true,1,($row[1]+' '),$row[1].ToUpperInvariant(),@($row[1]),@{})){$baseFacts.public_listener_qualification=ListenerProof;$baseFacts.public_listener_qualification.($row[0])=$bad;Refuses {& $guard}}
   $baseFacts.public_listener_qualification=ListenerProof;$baseFacts.public_listener_qualification.PSObject.Properties.Remove($row[0]);Refuses {& $guard}
  }
  foreach($kind in 'native_defender','installed_collector'){
   foreach($bad in @($null,$true,$false,1,'passed',@((ListenerProof).$kind),@{},[pscustomobject]@{state='passed'})){$baseFacts.public_listener_qualification=ListenerProof;$baseFacts.public_listener_qualification.$kind=$bad;Refuses {& $guard}}
   $baseline=(ListenerProof).$kind;$minimum=if($kind -ceq 'native_defender'){21}else{14}
   foreach($field in @($baseline.PSObject.Properties.Name)){
    $badValues=switch($field){
     'schema'{@($null,$true,0,2,1.0,([decimal]1),'1',@(1),@{})}
     'state'{@($null,$true,1,'Passed','passed ','partial',@('passed'),@{})}
     'producer'{@($null,$true,1,'foreign.ps1',($baseline.producer+' '),@($baseline.producer),@{})}
     'checks'{@($null,$true,($minimum-1),100001,([decimal]$minimum),([string]$minimum),@($minimum),@{})}
     default{@($null,1,([string]$baseline.$field),@($baseline.$field),@{},(-not $baseline.$field))}
    }
    foreach($bad in $badValues){$baseFacts.public_listener_qualification=ListenerProof;$baseFacts.public_listener_qualification.$kind.$field=$bad;Refuses {& $guard}}
    $baseFacts.public_listener_qualification=ListenerProof;$baseFacts.public_listener_qualification.$kind.PSObject.Properties.Remove($field);Refuses {& $guard}
   }
   foreach($value in $minimum,([long]$minimum),100000){$baseFacts.public_listener_qualification=ListenerProof;$baseFacts.public_listener_qualification.$kind.checks=$value;$script:guardCalls=0;& $guard;Assert ($script:guardCalls -eq 78)}
   $baseFacts.public_listener_qualification=ListenerProof;$baseFacts.public_listener_qualification.$kind.schema=[long]1;$script:guardCalls=0;& $guard;Assert ($script:guardCalls -eq 78)
   $baseFacts.public_listener_qualification=ListenerProof;$baseFacts.public_listener_qualification.PSObject.Properties.Remove($kind);Refuses {& $guard}
  }
  $baseFacts.public_listener_qualification=ListenerProof;$baseFacts.PSObject.Properties.Remove('public_listener_qualification');Refuses {& $guard};$baseFacts|Add-Member NoteProperty public_listener_qualification (ListenerProof)
  # The exact old guard admitted an older20 baseline with neither new proof.
  $baseFacts.PSObject.Properties.Remove('php_runtime_qualification');$baseFacts.PSObject.Properties.Remove('upgrade_recovery_qualification')
  $script:guardCalls=0;& $oldGuard;Assert ($script:guardCalls -eq 16);Refuses {& $guard}
 }
 $BaseVersion='1.0.13';$baseFacts=[pscustomobject]@{gates=[pscustomobject]@{}};$script:guardCalls=0;& $guard;Assert ($script:guardCalls -eq 0)
}
Write-Output ('PASS '+$checks+' actual modern restore/updater baseline guard controls; current nine gates and complete native DTLS/PHP/candidate-recovery/commit-selection/public-listener records required, historical13 branch unchanged')
