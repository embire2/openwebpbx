# Actual production QA validator extracted through its AST; no PBX/network access.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-native-acceptance.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Native acceptance source does not parse.'}
$node=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'AssertExtendedNativeCases'},$true))
if($node.Count -ne 1){throw 'The exact extended native validator is missing.'};Invoke-Expression $node[0].Extent.Text
$names=@('native_clock1026_gmt2_three_decoded_announcements','native_provider_outbound_decoded_rtp','native_provider_503_failover_once_decoded_rtp','native_provider_busy_no_failover','native_provider_603_failover_once_decoded_rtp','native_provider_incoming_owned_did_decoded_rtp','native_cmb_sa_id_first_auth_decoded_bridge','native_cmb_saved_caller_decoded_bridge','native_cmb_short_quota_native_cutoff_exact_usage','native_cmb_exhausted_quota_no_destination')
$good=@(foreach($name in $names){[pscustomobject]@{case=$name;passed=$true;sourcebindings_verified=$true;GMT_plus_2_full_time_verified=$true;original_phone_media_restored=$true;owned_clock_call_ended=$true;scoped_observer_stopped=$true;software_phone_only=$true;no_carrier_calls_or_database_configuration_writes=$true;frozen_Nathaniel_assets=34;complete_announcements=3;minimum_component_correlation=.9998;maximum_native_signal_lateness_ms=15;maximum_decoded_beep_target_error_ms=42;no_carrier_traffic=$true;caller_decoded_ratio=.9998;provider_decoded_ratio=.9998;extension_decoded_ratio=.9998;primary_distinct_calls=1;backup_distinct_calls=$(if($name -cin 'native_provider_503_failover_once_decoded_rtp','native_provider_603_failover_once_decoded_rtp'){1}else{0});identity_hmac_unchanged=$true;reservation_released=$true;persistent_binding_verified=$true;no_plaintext_identity_in_facts=$true;total_allowance_unchanged=$true;ten_minute_policy_ceiling_verified=$true;actual_600_second_call=$false;charged_seconds=3;native_reserved_limit_seconds=4;destination_decoded_ratio=.9998;no_destination_bridge=$true;observed_short_cutoff_seconds=4.1}})
$script:checks=0
function Accept($Rows){AssertExtendedNativeCases $Rows;$script:checks++}
function Refuse($Rows){$failed=$false;try{AssertExtendedNativeCases $Rows}catch{$failed=$true};if(!$failed){throw 'The validator accepted incomplete or misleading native evidence.'};$script:checks++}
function CopyGood{return ,@(($good|ConvertTo-Json -Depth 5)|ConvertFrom-Json)}
Accept $good
foreach($name in $names){
 Refuse @($good|Where-Object {$_.case -cne $name})
 Refuse @($good+@($good|Where-Object {$_.case -ceq $name}))
 foreach($value in @($false,'true',1,$null)){
  $rows=CopyGood;($rows|Where-Object {$_.case -ceq $name}).passed=$value;Refuse $rows
 }
}
foreach($pair in @(@(0,'complete_announcements',2),@(0,'complete_announcements','3'),@(0,'maximum_native_signal_lateness_ms',250),@(0,'maximum_decoded_beep_target_error_ms',250),@(0,'minimum_component_correlation',.61),@(0,'minimum_component_correlation',[double]::NaN),@(1,'provider_decoded_ratio',.79),@(2,'backup_distinct_calls',2),@(3,'backup_distinct_calls',1),@(5,'extension_decoded_ratio',0),@(6,'identity_hmac_unchanged',$false),@(7,'actual_600_second_call',$true),@(8,'native_reserved_limit_seconds',601),@(8,'charged_seconds',5),@(9,'no_destination_bridge',$false),@(1,'primary_distinct_calls','1'),@(1,'primary_distinct_calls',@(1)),@(2,'backup_distinct_calls','1'),@(2,'backup_distinct_calls',@(1)),@(8,'observed_short_cutoff_seconds',$null),@(8,'observed_short_cutoff_seconds','4'),@(8,'observed_short_cutoff_seconds',1.9),@(8,'observed_short_cutoff_seconds',8.1),@(8,'native_reserved_limit_seconds',600))){
 $rows=CopyGood;$rows[$pair[0]].($pair[1])=$pair[2];Refuse $rows
}
"PASS $script:checks exact extended native completion/type/privacy/threshold/duplicate refusal controls; no PBX or network invoked"
