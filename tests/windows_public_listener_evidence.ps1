# Execute the actual Suite evidence guards; no installed server or network action.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest;$checks=0
function Check([bool]$Value){if(!$Value){throw ('Public-listener evidence control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
function Refuse([scriptblock]$Action){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Check $failed}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-suite.ps1'),[ref]$tokens,[ref]$errors);Check ($errors.Count -eq 0)
foreach($name in 'Read-PublicListenerQualificationReport','PublicListenerQualificationHook'){
 $nodes=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true));Check ($nodes.Count -eq 1);Invoke-Expression $nodes[0].Extent.Text
}
function Proof([string]$Kind){
 $r=[ordered]@{schema=1;state='passed';checks=21;producer='windows_public_listeners_native.ps1'}
 if($Kind -ceq 'native_defender'){
  foreach($field in 'actual_native_defender','actual_os_listener_ownership','service_identity_adapter_double','global_policy_exact','actual_throw_after_create_and_enable','idempotent','foreign_named_rule_preserved','configured_private_ports_excluded','profiles_all_enabled_at_observation'){$r[$field]=$true}
  foreach($field in 'firewall_enforcement_tested','firewall_profiles_changed','installed_server_changed','calls_placed'){$r[$field]=$false}
 }else{
  $r.producer='windows_public_listener_installed.ps1';$r.checks=14
  foreach($field in 'actual_installed_php_pg_esl_os','exact_installed_helper_manifest','provider_5080_tcp_udp_planned','tls_only_when_actually_bound','configured_default_audio_source','private_service_ports_excluded','read_only_preflight'){$r[$field]=$true}
  foreach($field in 'firewall_or_configuration_mutated','calling_or_audio_acceptance','installed_server_changed'){$r[$field]=$false}
 }
 return [pscustomobject]$r
}
foreach($kind in 'native_defender','installed_collector'){
 $record=Proof $kind;$safe=Read-PublicListenerQualificationReport $record $kind 0
 Check ($safe.state -ceq 'passed' -and $safe.checks -eq $record.checks)
 $record|Add-Member NoteProperty untrusted_secret 'not-for-public-facts'
 $safe=Read-PublicListenerQualificationReport $record $kind ([long]0);Check (!$safe.ContainsKey('untrusted_secret'))
 foreach($field in @($record.PSObject.Properties|Where-Object {$_.Value -is [bool]}|ForEach-Object Name)){
  foreach($bad in $null,(!$record.$field),0,1,([string]$record.$field),@{}){$r=Proof $kind;$r.$field=$bad;Refuse {Read-PublicListenerQualificationReport $r $kind 0}}
  $r=Proof $kind;$r.$field=,@($record.$field);Refuse {Read-PublicListenerQualificationReport $r $kind 0}
  $r=Proof $kind;$r.PSObject.Properties.Remove($field);Refuse {Read-PublicListenerQualificationReport $r $kind 0}
 }
 foreach($bad in $null,$true,$false,-1,1,'0',0.0,([decimal]0),@{}){Refuse {Read-PublicListenerQualificationReport (Proof $kind) $kind $bad}}
 Refuse {Read-PublicListenerQualificationReport (Proof $kind) $kind (,0)}
 foreach($bad in $null,$true,$false,0,2,'1',1.0,([decimal]1),@{}){$r=Proof $kind;$r.schema=$bad;Refuse {Read-PublicListenerQualificationReport $r $kind 0}}
 foreach($bad in $null,$true,1,'Passed','passed ','failed','partial',@{}){$r=Proof $kind;$r.state=$bad;Refuse {Read-PublicListenerQualificationReport $r $kind 0}}
 foreach($bad in $null,$true,1,'foreign.ps1',($record.producer+' '),@{}){$r=Proof $kind;$r.producer=$bad;Refuse {Read-PublicListenerQualificationReport $r $kind 0}}
 $minimum=if($kind -ceq 'native_defender'){21}else{14}
 foreach($bad in $null,$true,$false,0,($minimum-1),100001,1.5,([decimal]$minimum),([string]$minimum),@{}){$r=Proof $kind;$r.checks=$bad;Refuse {Read-PublicListenerQualificationReport $r $kind 0}}
 foreach($value in $minimum,([long]$minimum),100000){$r=Proof $kind;$r.checks=$value;Check ((Read-PublicListenerQualificationReport $r $kind 0).checks -eq $value)}
 foreach($field in 'schema','state','producer','checks'){$r=Proof $kind;$r.PSObject.Properties.Remove($field);Refuse {Read-PublicListenerQualificationReport $r $kind 0}}
 Refuse {Read-PublicListenerQualificationReport (,(Proof $kind)) $kind 0}
 foreach($bad in $null,$true,$false,'passed',@{}){Refuse {Read-PublicListenerQualificationReport $bad $kind 0}}
}
foreach($bad in '', 'Native_Defender','installed_collector ','foreign'){Refuse {Read-PublicListenerQualificationReport (Proof 'native_defender') $bad 0}}
# Historical replay cannot borrow new source acceptance for old installed bytes.
$Public21ToCandidate22=$false
$ReplaySuiteRunId='123';$facts=[ordered]@{};PublicListenerQualificationHook 'native_defender';Check ($facts.public_listener_qualification -ceq 'unqualified_historical_candidate')
PublicListenerQualificationHook 'installed_collector';Check ($facts.public_listener_qualification -ceq 'unqualified_historical_candidate')
$ReplaySuiteRunId='';$facts=[ordered]@{gates=@{fresh='passed';web_readiness='passed'}}
Refuse {PublicListenerQualificationHook 'foreign'}
Refuse {PublicListenerQualificationHook 'installed_collector'}
foreach($gate in 'fresh','web_readiness'){
 $facts=[ordered]@{gates=@{fresh='passed';web_readiness='passed'};public_listener_qualification=@{state='partial';native_defender=@{state='passed'};installed_collector='pending'}};$facts.gates[$gate]='failed'
 Refuse {PublicListenerQualificationHook 'installed_collector'};Check ($facts.public_listener_qualification.state -ceq 'partial')
}
$text=$ast.Extent.Text
$native=$text.IndexOf("`$phase='native public-listener firewall qualification';PublicListenerQualificationHook 'native_defender'")
$installed=$text.IndexOf("`$phase='installed public-listener qualification';PublicListenerQualificationHook 'installed_collector'")
Check ($native -gt $text.IndexOf("`$phase='original candidate export';ExportOriginalCandidate `$release") -and $native -lt $text.IndexOf("`$phase='fresh installation';"))
Check ($installed -gt $text.IndexOf("`$phase='native web readiness qualification';WebReadinessHook") -and $installed -lt $text.IndexOf("`$phase='native DTLS qualification';DtlsQualificationHook"))
$calls=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'PublicListenerQualificationHook'},$true));Check ($calls.Count -eq 2)
"PASS $checks actual-source public-listener scope/type/count/child-result/replay/order controls; no installed action"
