# SPDX-License-Identifier: AGPL-3.0-or-later
# Actual observer/projector functions; all CIM service rows are explicit models.
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$tool=Join-Path $PSScriptRoot '../../tools/Test-ClientMedia.ps1';$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile([IO.Path]::GetFullPath($tool),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Actual media wrapper must parse.'}
foreach($name in @('ClosedKeys','MediaServiceChanges','ReadServiceBoundary','ObserveServiceBoundary')){$found=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true));if($found.Count -ne 1){throw 'One actual observer function required.'};. ([scriptblock]::Create($found[0].Extent.Text))}
$checks=0
function Check([bool]$Value){if(!$Value){throw 'A service-boundary control failed.'};$script:checks++}
function RoundTrip($Value){ConvertTo-Json -InputObject $Value -Depth 10 -Compress|ConvertFrom-Json -NoEnumerate}
function Fixture{[ordered]@{stage='after_sdk_extract';observed=$true;elapsed_ms=100;changes=[ordered]@{changed_services=1;truncated=$false;rows=@([ordered]@{name='msiserver';changed_properties=@('state');before_present=$true;after_present=$true;before_state='Stopped';after_state='Running';before_mode='Manual';after_mode='Manual'})}}}
function Refuse([scriptblock]$Action){$failed=$false;try{$null=& $Action}catch{$failed=$true};Check $failed}
$value=ReadServiceBoundary (RoundTrip (Fixture));Check ($value.changes.rows[0].name -ceq 'msiserver')
foreach($mutation in @('stage','observed','time_type','time_bound','private','count','truncated','rows_type','name','property','state','mode','present','absent','duplicate')){
 $value=Fixture;switch($mutation){stage{$value.stage='PRIVATE'}observed{$value.observed=1}time_type{$value.elapsed_ms='100'}time_bound{$value.elapsed_ms=3600001}private{$value.changes.rows[0]['path']='PRIVATE'}count{$value.changes.changed_services=2}truncated{$value.changes.truncated=$true}rows_type{$value.changes.rows=$true}name{$value.changes.rows[0].name='C:/PRIVATE'}property{$value.changes.rows[0].changed_properties=@('PRIVATE')}state{$value.changes.rows[0].after_state='PRIVATE'}mode{$value.changes.rows[0].after_mode='PRIVATE'}present{$value.changes.rows[0].after_present=1}absent{$value.changes.rows[0].after_present=$false}duplicate{$value.changes.changed_services=2;$value.changes.rows+=@($value.changes.rows[0])}};Refuse {ReadServiceBoundary (RoundTrip $value)}
}
Check (!(ReadServiceBoundary (RoundTrip ([ordered]@{stage='after_msi_extract';observed=$false}))).observed)
Refuse {ReadServiceBoundary (RoundTrip ([ordered]@{stage='after_msi_extract';observed=$false;error='PRIVATE'}))}
$script:serviceBoundaryBefore=RoundTrip @([ordered]@{name='msiserver';state='Stopped';mode='Manual';path='PRIVATE_PATH';account='PRIVATE_ACCOUNT'})
$script:serviceBoundaries=[Collections.Generic.List[object]]::new();$script:serviceBoundaryClock=[Diagnostics.Stopwatch]::StartNew();$script:cimCalls=0;$script:failCim=$false
function Get-CimInstance([string]$ClassName){if($ClassName -cne 'Win32_Service'){throw 'Unexpected CIM class.'};$script:cimCalls++;if($script:failCim){throw 'PRIVATE_FAILURE'};[pscustomobject]@{Name='msiserver';State='Running';StartMode='Manual';PathName='PRIVATE_PATH';StartName='PRIVATE_ACCOUNT'}}
ObserveServiceBoundary 'after_sdk_extract';Check ($script:cimCalls -eq 1 -and $script:serviceBoundaries[0].observed -and $script:serviceBoundaries[0].changes.changed_services -eq 1)
$script:failCim=$true;ObserveServiceBoundary 'after_msi_extract';Check ($script:cimCalls -eq 2 -and !$script:serviceBoundaries[1].observed)
$script:failCim=$false;foreach($stage in @('after_managed_build','immediately_before_native_media','after_native_media')){ObserveServiceBoundary $stage}
Check ($script:cimCalls -eq 5 -and $script:serviceBoundaries.Count -eq 5);Check (($script:serviceBoundaries|ConvertTo-Json -Depth 10 -Compress) -notmatch 'PRIVATE')
ObserveServiceBoundary 'PRIVATE';ObserveServiceBoundary 'after_native_media';Check ($script:cimCalls -eq 5 -and $script:serviceBoundaries.Count -eq 5)
$original='private_primary';try{throw $original}catch{$primary=$_;ObserveServiceBoundary 'PRIVATE';Check ($primary.Exception.Message -ceq $original)}
[ordered]@{schema=1;state='passed_actual_service_boundary_observer_controls';checks=$checks;cim_service_api_modelled=$true;actual_native_calling=$false;baseline_or_preservation_predicate_changed=$false}|ConvertTo-Json -Compress
