# SPDX-License-Identifier: AGPL-3.0-or-later
function GetPackageCertificateFailure([Management.Automation.ErrorRecord]$Record,[string]$Mode,[string]$Stage){
 if($Mode-cnotin @('Create','Remove') -or $Stage-cnotin @('entry','root','acl','stores','create_preflight','create_intent','native_module','create_certificate','verify_created','write_receipt','add_trust','read_intent','read_receipt','verify_bindings','verify_keys','remove_trust','remove_private','remove_orphan','verify_removed')){throw 'Unknown certificate diagnostic context.'}
 $reasons=@{
  'Only the disposable native Windows certificate fixture is allowed.'='host_guard'
  'The owned private root differs.'='root_scope'
  'The fixture root is linked.'='root_link'
  'The certificate fixture root must be protected.'='root_acl_shape'
  'The certificate fixture ACL differs.'='root_acl_rule'
  'The private key scope, provider, ownership or export policy is foreign.'='key_scope'
  'An ordinary bounded certificate receipt is required.'='receipt_file'
  'The certificate receipt identity differs.'='receipt_identity'
  'The development certificate or private container already exists.'='identity_exists'
  'Certificate intent already exists.'='intent_exists'
  'The native PKI module is absent.'='module_absent'
  'The native certificate command provenance differs.'='module_provenance'
  'The generated development certificate differs.'='created_identity'
  'The generated key is not CNG.'='created_key_type'
  'Foreign development identity lacks ownership intent.'='intent_absent'
  'The certificate intent is unavailable.'='intent_file'
  'The development certificate ownership differs.'='intent_identity'
  'The private certificate has no binding receipt; preserve it for review.'='receipt_absent'
  'The private certificate binding differs.'='private_binding'
  'The public trust certificate does not match the owned private certificate.'='public_binding'
  'The private key is foreign.'='private_key_type'
  'Owned certificate cleanup is incomplete.'='cleanup_incomplete'
 }
 $reason='external_exception';if($reasons.ContainsKey($Record.Exception.Message)){$reason=$reasons[$Record.Exception.Message]}
 $source='other';$line=0;if($null-ne $Record.InvocationInfo){$source=[IO.Path]::GetFileName($Record.InvocationInfo.ScriptName);$line=[int]$Record.InvocationInfo.ScriptLineNumber};if($source-cne 'Certificate.ps1'){$source='other'}
 $inner=$Record.Exception.InnerException
 [ordered]@{schema=1;producer='PackageCertificateFailure';mode=$Mode;stage=$Stage;source=$source;line=$line;error_type=$Record.Exception.GetType().Name;hresult=[int]$Record.Exception.HResult;inner_type=$(if($inner){$inner.GetType().Name}else{$null});inner_hresult=$(if($inner){[int]$inner.HResult}else{$null});reason=$reason}
}
function ReadPackageCertificateFailure([string]$Text,[string]$Mode){
 if($Text.Length-gt 8MB -or $Mode-cnotin @('Create','Remove')){throw 'The certificate diagnostic scope differs.'}
 $prefix='OPENWEBPBX_PACKAGE_CERTIFICATE_OBSERVATION ';$lines=@($Text -split "`r?`n"|Where-Object {$_.StartsWith($prefix,[StringComparison]::Ordinal)})
 if($lines.Count-ne 1 -or $lines[0].Length-gt 4096){throw 'A unique bounded certificate diagnostic is required.'}
 $json=$lines[0].Substring($prefix.Length);$document=[Text.Json.JsonDocument]::Parse($json)
 try{if($document.RootElement.ValueKind-ne [Text.Json.JsonValueKind]::Object){throw 'Certificate diagnostic must be an object.'};$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);foreach($entry in $document.RootElement.EnumerateObject()){if(!$seen.Add($entry.Name)){throw 'Certificate diagnostic repeats a field.'}}}finally{$document.Dispose()}
 $value=$json|ConvertFrom-Json
 $names=@($value.PSObject.Properties.Name|Sort-Object);$expected=@('schema','producer','mode','stage','source','line','error_type','hresult','inner_type','inner_hresult','reason'|Sort-Object)
 if(($names -join ',')-cne ($expected -join ',') -or $value.schema-isnot [long] -or $value.schema-ne 1 -or $value.producer-cne 'PackageCertificateFailure' -or $value.mode-cne $Mode -or $value.stage-cnotin @('entry','root','acl','stores','create_preflight','create_intent','native_module','create_certificate','verify_created','write_receipt','add_trust','read_intent','read_receipt','verify_bindings','verify_keys','remove_trust','remove_private','remove_orphan','verify_removed') -or $value.source-cnotin @('Certificate.ps1','other') -or $value.line-isnot [long] -or $value.line-lt 0 -or $value.line-gt 10000 -or $value.error_type-isnot [string] -or $value.error_type-cnotmatch '^(Exception|[A-Za-z][A-Za-z0-9]{0,90}Exception)$' -or $value.hresult-isnot [long] -or $value.hresult-lt [int]::MinValue -or $value.hresult-gt [int]::MaxValue){throw 'The typed certificate diagnostic differs.'}
 if(($null-eq $value.inner_type)-ne ($null-eq $value.inner_hresult) -or ($null-ne $value.inner_type -and ($value.inner_type-isnot [string] -or $value.inner_type-cnotmatch '^(Exception|[A-Za-z][A-Za-z0-9]{0,90}Exception)$' -or $value.inner_hresult-isnot [long] -or $value.inner_hresult-lt [int]::MinValue -or $value.inner_hresult-gt [int]::MaxValue))){throw 'The typed inner certificate diagnostic differs.'}
 if($value.reason-cnotin @('external_exception','host_guard','root_scope','root_link','root_acl_shape','root_acl_rule','key_scope','receipt_file','receipt_identity','identity_exists','intent_exists','module_absent','module_provenance','created_identity','created_key_type','intent_absent','intent_file','intent_identity','receipt_absent','private_binding','public_binding','private_key_type','cleanup_incomplete')){throw 'Unknown certificate guard reason.'}
 $value
}
function GetPackageChildFailure([string]$Operation,[int]$ExitCode){
 if($Operation-cnotin @('publish_app','publish_updater','list_packages','certificate_create','certificate_remove','package_info','ui_update','ui_verify','sign_package','sign_bundle','make_bundle','package_install','seed_data','package_launch','checkpoint','package_remove') -or $ExitCode-eq 0){throw 'The child failure context differs.'}
 [ordered]@{operation=$Operation;exit_code=$ExitCode}
}
function GetPackageCertificateRemoval([int]$PrivateCount,[int]$TrustCount,[bool]$KeyExists){
 if($PrivateCount-ne 0 -or $TrustCount-ne 0 -or $KeyExists){throw 'Owned certificate cleanup is incomplete.'}
 [ordered]@{schema=1;producer='PackageCertificateRemoval';private_certificates=$PrivateCount;public_trust_certificates=$TrustCount;private_key_exists=$KeyExists}
}
function ReadPackageCertificateRemoval([string]$Text){
 if($Text.Length-gt 1024){throw 'The certificate removal observation exceeds its bound.'}
 $document=[Text.Json.JsonDocument]::Parse($Text)
 try{if($document.RootElement.ValueKind-ne [Text.Json.JsonValueKind]::Object){throw 'Certificate removal observation must be an object.'};$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);foreach($entry in $document.RootElement.EnumerateObject()){if(!$seen.Add($entry.Name)){throw 'Certificate removal observation repeats a field.'}}}finally{$document.Dispose()}
 $value=$Text|ConvertFrom-Json;$expected=@('schema','producer','private_certificates','public_trust_certificates','private_key_exists'|Sort-Object)
 if((@($value.PSObject.Properties.Name|Sort-Object)-join ',')-cne ($expected-join ',') -or $value.schema-isnot [long] -or $value.schema-ne 1 -or $value.producer-cne 'PackageCertificateRemoval' -or $value.private_certificates-isnot [long] -or $value.private_certificates-ne 0 -or $value.public_trust_certificates-isnot [long] -or $value.public_trust_certificates-ne 0 -or $value.private_key_exists-isnot [bool] -or $value.private_key_exists){throw 'The actual private certificate, public trust or key absence was not proved.'};$value
}
function GetPackageSnapshotComparison([string]$Before,[string]$After){
 if($Before.Length-gt 8MB -or $After.Length-gt 8MB){throw 'Package preservation vectors exceed their bound.'}
 $first=$Before|ConvertFrom-Json;$last=$After|ConvertFrom-Json;$observed=[ordered]@{}
 foreach($category in @('certificates','packages','registry')){
  $left=@($first.$category);$right=@($last.$category)
  $observed[$category]=[ordered]@{before_count=$left.Count;after_count=$right.Count;matches=(ConvertTo-Json -InputObject $left -Depth 14 -Compress)-ceq (ConvertTo-Json -InputObject $right -Depth 14 -Compress)}
 }
 $stores=[ordered]@{};foreach($store in @('My','TrustedPeople','Root','CA')){
  $left=@($first.certificates|Where-Object store -CEQ $store);$right=@($last.certificates|Where-Object store -CEQ $store)
  $stores[$store]=[ordered]@{before_count=$left.Count;after_count=$right.Count;matches=(ConvertTo-Json -InputObject $left -Depth 4 -Compress)-ceq (ConvertTo-Json -InputObject $right -Depth 4 -Compress)}
 };$observed.certificate_stores=$stores;$observed
}
