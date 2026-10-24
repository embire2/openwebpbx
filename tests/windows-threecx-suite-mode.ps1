# SPDX-License-Identifier: AGPL-3.0-or-later
# Separate explicit replay diagnostic; existing normal/factory guards are unchanged.
. (Join-Path $PSScriptRoot 'windows-threecx-https-fields.ps1')
function AssertThreecxImportSuiteMode([bool]$ImportOnly,[bool]$NativeOnly,[bool]$SkipHealth,[bool]$HoldOnly,[bool]$UpgradeOnly,[bool]$BackupOnly,[bool]$ProducerFallback,[string]$ProvidedPackage,[string]$ReplayRun,[string]$NativeRun,[string]$EngineRun,[string]$ArtifactPin,[string]$ZipPin){
 if(!$ImportOnly){return}
 if(!$NativeOnly -or !$SkipHealth -or $HoldOnly -or $UpgradeOnly -or $BackupOnly -or $ProducerFallback -or $ProvidedPackage -or $ArtifactPin -or $ZipPin -or $ReplayRun -cne '40005106134' -or $NativeRun -cne '39903796050' -or $EngineRun -cne '39823852979'){throw 'The import diagnostic requires its exact accepted replay and native/engine inputs, native-only empty-factory scope and no other diagnostic or package choices.'}
}
function AssertThreecxImportAcceptedReplay($Facts){
 $r=$Facts.replay;$a=$Facts.artifacts
 if($r.original_run -isnot [string] -or $r.original_run -cne '40005106134' -or $a.native_run -isnot [string] -or $a.native_run -cne '39903796050' -or $a.engine_run -isnot [string] -or $a.engine_run -cne '39823852979'){throw 'The authenticated replay producer identities differ.'}
 foreach($value in $r.exact_zip_sha256,$a.candidate_sha256){if($value -isnot [string] -or $value -cne 'd0799878b04a8564c4ae074a34d9a3cf809432eb39230f8edf4011f4bd55042e'){throw 'The accepted original candidate bytes differ.'}}
 if($r.windows_runtime_source_identical -isnot [bool] -or !$r.windows_runtime_source_identical -or $r.runtime_overlays -isnot [bool] -or $r.runtime_overlays -or $r.producer_provenance){throw 'Only exact runtime-source replay without overlays or producer fallback is admitted.'}
}
function InvokeThreecxImportEmptyFactory($Facts,[bool]$ModeValidated,[bool]$NativeOnly,[bool]$SkipHealth,[bool]$HoldOnly,[string]$Work){
 if(!$ModeValidated -or !$NativeOnly -or !$SkipHealth -or $HoldOnly -or $Facts.gates.fresh -cne 'passed' -or $Facts.gates.web_readiness -cne 'passed' -or $Facts.phone_health_failure -or (Test-Path -LiteralPath (Join-Path $Work 'phone-health-native.json'))){throw 'Import diagnostics cannot continue from a prior/failed Health fixture or an unproved fresh web installation.'}
 AssertThreecxImportAcceptedReplay $Facts
 $Facts.gates.phone_health='unqualified';$Facts.native_factory_phone_health_skipped=$true
 $Facts.native_factory_fresh_package=$false;$Facts.threecx_accepted_replay_new_installation=$true
 $Facts.release_eligible=$false;$Facts.owner_transaction_eligible=$false
}
function ReadSuiteThreecxImportDiagnostic($Record){
 if(($Record.schema -isnot [int] -and $Record.schema -isnot [long]) -or $Record.schema -ne 1 -or $Record.state -isnot [string] -or $Record.state -cne 'passed' -or $Record.diagnostic_case -isnot [string] -or $Record.diagnostic_case -cne 'threecx_import'){throw 'The actual import diagnostic wrapper must pass.'}
 foreach($flag in 'native_factory_empty_before_fixture','threecx_upload_cleanup'){if($Record.$flag -isnot [bool] -or !$Record.$flag){throw 'The actual empty factory and exact upload cleanup are required.'}}
 foreach($flag in 'full_release_eligible','owner_eligible','public_eligible','restore_eligible','signed_upgrade_eligible'){if($Record.$flag -isnot [bool] -or $Record.$flag){throw 'Import diagnostics cannot promote release, owner, restore or upgrade.'}}
 $gates=@{native_sip_audio='pending';meeting_browser='pending';native_clock='pending';native_providers='pending';native_call_me_back='pending';smtp='pending';notification_store='pending';cleanup='passed';public_acme='unqualified';physical_devices='unqualified';carrier='unqualified';android_hardware='unqualified';ui_render='unqualified';threecx_import_diagnostic='passed'}
 $keys=@($Record.gates.PSObject.Properties.Name)
 if($keys.Count -ne $gates.Count -or @($keys|Where-Object {$_ -cnotin $gates.Keys}).Count){throw 'Import diagnostic gate scope differs.'}
 foreach($key in $gates.Keys){if($Record.gates.$key -isnot [string] -or $Record.gates.$key -cne $gates[$key]){throw 'Import diagnostics cannot substitute a full native gate.'}}
 if($Record.cleanup -isnot [string] -or $Record.cleanup -cne 'Original factory rows/contacts/identity/profile/config/certificate binding restored; owned CA/leaf and private probe task removed'){throw 'Canonical factory preservation is required.'}
 if($Record.checks -isnot [array] -or $Record.checks.Count -lt 6 -or $Record.checks.Count -gt 7){throw 'The six closed import cases are required.'}
 $rows=@($Record.checks|Where-Object {$_ -isnot [string]});$notes=@($Record.checks|Where-Object {$_ -is [string]})
 if($notes.Count -gt 1 -or ($notes.Count -eq 1 -and $notes[0] -cne 'Normal generated-factory login bcrypt12-to-10 rehash proved with unchanged password, then original hash restored during cleanup')){throw 'Unknown import diagnostic notes refused.'}
 # The child wrapper has already consumed its exact closed producer receipt;
 # repeat the same case/type validation, then export only fixed values.
 $closed=[pscustomobject]@{schema=1;producer='windows-native-acceptance.py';state='passed';checks=$rows;diagnostic_case='threecx_import';full_release_eligible=$false;owner_eligible=$false;public_eligible=$false;restore_eligible=$false;signed_upgrade_eligible=$false;physical_devices='unqualified';ui_render='unqualified';carrier='unqualified';public_acme='unqualified';scope='fictional-hosted-runner-threecx-import-only'}
 Assert-NativeThreecxImportReport $closed
 return [ordered]@{schema=1;state='passed';diagnostic_case='threecx_import';cases=@($rows|ForEach-Object {$_.case});native_factory_empty=$true;uploaded_archive_removed=$true;canonical_cleanup='passed';full_release_eligible=$false;owner_eligible=$false;public_eligible=$false;restore_eligible=$false;signed_upgrade_eligible=$false;ui_render='unqualified';physical_devices='unqualified';carrier='unqualified';public_acme='unqualified'}
}
