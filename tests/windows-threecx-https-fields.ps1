# SPDX-License-Identifier: AGPL-3.0-or-later
function Test-NativeThreecxImportMode($InputData){
 if(!$InputData.ContainsKey('threecx_import_only')){return $false}
 if($InputData.threecx_import_only -isnot [bool]){throw 'Synthetic import mode must be explicit.'}
 if(!$InputData.threecx_import_only){return $false}
 if($InputData.native_diagnostics_only -isnot [bool] -or !$InputData.native_diagnostics_only -or ($InputData.ContainsKey('hold_diagnostics_only') -and ($InputData.hold_diagnostics_only -isnot [bool] -or $InputData.hold_diagnostics_only))){throw 'Synthetic import requires its own explicitly nonrelease diagnostic mode.'}
 return $true
}
function Assert-NativeThreecxImportReport($Report){
 $keys=@($Report.PSObject.Properties.Name)
 $expected=@('schema','producer','state','checks','diagnostic_case','full_release_eligible','owner_eligible','public_eligible','restore_eligible','signed_upgrade_eligible','physical_devices','ui_render','carrier','public_acme','scope')
 if($keys.Count -ne $expected.Count -or @($keys|Where-Object {$_ -cnotin $expected}).Count){throw 'Synthetic import report fields differ.'}
 foreach($field in 'producer','state','diagnostic_case','scope'){if($Report.$field -isnot [string]){throw 'Synthetic import report identity types differ.'}}
 if(($Report.schema -isnot [int] -and $Report.schema -isnot [long]) -or $Report.schema -ne 1 -or $Report.producer -cne 'windows-native-acceptance.py' -or $Report.state -cne 'passed' -or $Report.diagnostic_case -cne 'threecx_import' -or $Report.scope -cne 'fictional-hosted-runner-threecx-import-only'){throw 'Synthetic import report identity differs.'}
 foreach($flag in 'full_release_eligible','owner_eligible','public_eligible','restore_eligible','signed_upgrade_eligible'){if($Report.$flag -isnot [bool] -or $Report.$flag){throw 'Synthetic import cannot qualify any release/owner/restore/upgrade.'}}
 foreach($field in 'physical_devices','ui_render','carrier','public_acme'){if($Report.$field -isnot [string] -or $Report.$field -cne 'unqualified'){throw 'Synthetic import claims an untested capability.'}}
 $names=@('threecx_https_multipart_csrf_preview','threecx_https_import_original_credentials_media','threecx_imported_sip_original_credentials','threecx_imported_direct_decoded_two_way','threecx_imported_ring_group_decoded_two_way','threecx_imported_peer_cleanup')
 if($Report.checks -isnot [array] -or $Report.checks.Count -ne $names.Count){throw 'All exact synthetic import cases must complete.'}
 for($i=0;$i -lt $names.Count;$i++){
  $row=$Report.checks[$i];$fields=@($row.PSObject.Properties.Name)
  if($fields.Count -ne 2 -or @($fields|Where-Object {$_ -cnotin 'case','passed'}).Count -or $row.case -isnot [string] -or $row.case -cne $names[$i] -or $row.passed -isnot [bool] -or !$row.passed){throw 'Synthetic import cases must be closed, ordered and successful.'}
 }
}
