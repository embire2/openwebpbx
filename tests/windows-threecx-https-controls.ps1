# SPDX-License-Identifier: AGPL-3.0-or-later
# Actual parser/receipt controls. No Windows machine or native service claims.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'windows-threecx-https-fields.ps1')
$script:checks=0
function Check([bool]$Condition){if(!$Condition){throw 'Synthetic report control failed.'};$script:checks++}
function Refuses([scriptblock]$Action){$failed=$false;try{& $Action}catch{$failed=$true};Check $failed}
$json='{"schema":1,"producer":"windows-native-acceptance.py","state":"passed","checks":[{"case":"threecx_https_multipart_csrf_preview","passed":true},{"case":"threecx_https_import_original_credentials_media","passed":true},{"case":"threecx_imported_sip_original_credentials","passed":true},{"case":"threecx_imported_direct_decoded_two_way","passed":true},{"case":"threecx_imported_ring_group_decoded_two_way","passed":true},{"case":"threecx_imported_peer_cleanup","passed":true}],"diagnostic_case":"threecx_import","full_release_eligible":false,"owner_eligible":false,"public_eligible":false,"restore_eligible":false,"signed_upgrade_eligible":false,"physical_devices":"unqualified","ui_render":"unqualified","carrier":"unqualified","public_acme":"unqualified","scope":"fictional-hosted-runner-threecx-import-only"}'
function Fresh {return ($json|ConvertFrom-Json)}
Assert-NativeThreecxImportReport (Fresh);Check $true
Check (!(Test-NativeThreecxImportMode @{}));Check (!(Test-NativeThreecxImportMode @{threecx_import_only=$false}))
Check (Test-NativeThreecxImportMode @{threecx_import_only=$true;native_diagnostics_only=$true})
Check (Test-NativeThreecxImportMode @{threecx_import_only=$true;native_diagnostics_only=$true;hold_diagnostics_only=$false})
foreach($mode in @(@{threecx_import_only='true'},@{threecx_import_only=1},@{threecx_import_only=$true},@{threecx_import_only=$true;native_diagnostics_only=1},@{threecx_import_only=$true;native_diagnostics_only=$true;hold_diagnostics_only=$true},@{threecx_import_only=$true;native_diagnostics_only=$true;hold_diagnostics_only=0})){Refuses {Test-NativeThreecxImportMode $mode|Out-Null}}
foreach($field in (Fresh).PSObject.Properties.Name){$record=Fresh;$record.PSObject.Properties.Remove($field);Refuses {Assert-NativeThreecxImportReport $record}}
foreach($field in 'full_release_eligible','owner_eligible','public_eligible','restore_eligible','signed_upgrade_eligible'){
 foreach($value in @($true,0,'false',$null)){$record=Fresh;$record.$field=$value;Refuses {Assert-NativeThreecxImportReport $record}}
}
foreach($field in 'producer','state','diagnostic_case','scope','physical_devices','ui_render','carrier','public_acme'){
 foreach($value in @('wrong',1,$false,$null)){$record=Fresh;$record.$field=$value;Refuses {Assert-NativeThreecxImportReport $record}}
 $record=Fresh;$record.$field=@($record.$field);Refuses {Assert-NativeThreecxImportReport $record}
}
foreach($value in @('1',$true,0,1.0)){$record=Fresh;$record.schema=$value;Refuses {Assert-NativeThreecxImportReport $record}}
for($i=0;$i -lt 6;$i++){
 foreach($value in @($false,'true',1,$null)){$record=Fresh;$record.checks[$i].passed=$value;Refuses {Assert-NativeThreecxImportReport $record}}
 $record=Fresh;$record.checks[$i].case='native_simultaneous_ring_group';Refuses {Assert-NativeThreecxImportReport $record}
 $record=Fresh;$record.checks[$i]|Add-Member -NotePropertyName password -NotePropertyValue 'fictional';Refuses {Assert-NativeThreecxImportReport $record}
 $record=Fresh;$record.checks=@($record.checks|Where-Object {$_.case -cne $record.checks[$i].case});Refuses {Assert-NativeThreecxImportReport $record}
}
$record=Fresh;$record.checks[0]=$record.checks[1];Refuses {Assert-NativeThreecxImportReport $record}
$record=Fresh;$record|Add-Member -NotePropertyName private_path -NotePropertyValue 'fictional';Refuses {Assert-NativeThreecxImportReport $record}
$errors=$null;$tokens=$null
[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'windows-native-acceptance.ps1'),[ref]$tokens,[ref]$errors)
Check ($errors.Count -eq 0)
@{state='passed';checks=$script:checks;actual_powershell_receipt_controls=$true;native_windows=$false}|ConvertTo-Json -Compress
