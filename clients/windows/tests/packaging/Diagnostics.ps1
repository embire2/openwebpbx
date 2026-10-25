# SPDX-License-Identifier: AGPL-3.0-or-later
function GetPackageCertificateFailure([Management.Automation.ErrorRecord]$Record,[string]$Mode,[string]$Stage){
 if($Mode-cnotin @('Create','Remove') -or $Stage-cnotin @('entry','root','acl','stores','create_preflight','create_intent','native_module','create_certificate','verify_created','write_receipt','add_trust','read_intent','read_receipt','verify_bindings','verify_keys','remove_trust','remove_cache','remove_private','remove_orphan','verify_removed')){throw 'Unknown certificate diagnostic context.'}
 $reasons=@{
  'Only the disposable native Windows certificate fixture is allowed.'='host_guard'
  'The disposable certificate fixture requires the hosted administrator.'='administrator_required'
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
  'The cached public certificate does not match its pre-absent owned identity.'='cache_binding'
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
 if(($names -join ',')-cne ($expected -join ',') -or $value.schema-isnot [long] -or $value.schema-ne 1 -or $value.producer-cne 'PackageCertificateFailure' -or $value.mode-cne $Mode -or $value.stage-cnotin @('entry','root','acl','stores','create_preflight','create_intent','native_module','create_certificate','verify_created','write_receipt','add_trust','read_intent','read_receipt','verify_bindings','verify_keys','remove_trust','remove_cache','remove_private','remove_orphan','verify_removed') -or $value.source-cnotin @('Certificate.ps1','other') -or $value.line-isnot [long] -or $value.line-lt 0 -or $value.line-gt 10000 -or $value.error_type-isnot [string] -or $value.error_type-cnotmatch '^(Exception|[A-Za-z][A-Za-z0-9]{0,90}Exception)$' -or $value.hresult-isnot [long] -or $value.hresult-lt [int]::MinValue -or $value.hresult-gt [int]::MaxValue){throw 'The typed certificate diagnostic differs.'}
 if(($null-eq $value.inner_type)-ne ($null-eq $value.inner_hresult) -or ($null-ne $value.inner_type -and ($value.inner_type-isnot [string] -or $value.inner_type-cnotmatch '^(Exception|[A-Za-z][A-Za-z0-9]{0,90}Exception)$' -or $value.inner_hresult-isnot [long] -or $value.inner_hresult-lt [int]::MinValue -or $value.inner_hresult-gt [int]::MaxValue))){throw 'The typed inner certificate diagnostic differs.'}
 if($value.reason-cnotin @('external_exception','host_guard','administrator_required','root_scope','root_link','root_acl_shape','root_acl_rule','key_scope','receipt_file','receipt_identity','identity_exists','intent_exists','module_absent','module_provenance','created_identity','created_key_type','intent_absent','intent_file','intent_identity','receipt_absent','private_binding','public_binding','private_key_type','cleanup_incomplete','cache_binding')){throw 'Unknown certificate guard reason.'}
 $value
}
function GetPackageChildFailure([string]$Operation,[int]$ExitCode){
 if($Operation-cnotin @('build_authority_controls','authority_controls','publish_app','publish_updater','list_packages','certificate_create','certificate_remove','package_info','ui_update','ui_verify','sign_package','sign_bundle','make_bundle','package_install','seed_data','package_launch','checkpoint','package_remove') -or $ExitCode-eq 0){throw 'The child failure context differs.'}
 [ordered]@{operation=$Operation;exit_code=$ExitCode}
}
function ReadPackageAuthorityObservation([string]$Text){
 if($Text.Length-gt 2048){throw 'The fixture authority observation exceeds its bound.'}
 $document=[Text.Json.JsonDocument]::Parse($Text)
 try{if($document.RootElement.ValueKind-ne [Text.Json.JsonValueKind]::Object){throw 'Fixture authority observation must be an object.'};$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);foreach($entry in $document.RootElement.EnumerateObject()){if(!$seen.Add($entry.Name)){throw 'Fixture authority observation repeats a field.'}}}finally{$document.Dispose()}
 $value=$Text|ConvertFrom-Json;$expected=@('schema','producer','state','stage','error_type','hresult'|Sort-Object)
 if((@($value.PSObject.Properties.Name|Sort-Object)-join ',')-cne ($expected-join ',') -or $value.schema-isnot [long] -or $value.schema-ne 1 -or $value.producer-cne 'PackageFixtureAuthority' -or $value.state-cnotin @('authorized','refused') -or $value.stage-cnotin @('live_host','environment','native_identity','context','package_identity','helper_environment','staged_helper')){throw 'The fixture authority observation scope differs.'}
 if($value.state-ceq 'authorized'){if($value.stage-cne 'package_identity' -or $null-ne $value.error_type -or $null-ne $value.hresult){throw 'The successful fixture authority observation differs.'}}
 elseif($value.error_type-isnot [string] -or $value.error_type-cnotmatch '^(Exception|[A-Za-z][A-Za-z0-9]{0,90}Exception)$' -or $value.hresult-isnot [long] -or $value.hresult-lt [int]::MinValue -or $value.hresult-gt [int]::MaxValue){throw 'The refused fixture authority observation differs.'}
 $value
}
function GetPackageCertificateRemoval([int]$PrivateCount,[int]$TrustCount,[bool]$KeyExists,[int]$CacheCount=-1){
 if($PrivateCount-ne 0 -or $TrustCount-ne 0 -or $KeyExists -or $CacheCount-ne 0){throw 'Owned certificate cleanup is incomplete.'}
 [ordered]@{schema=1;producer='PackageCertificateRemoval';private_certificates=$PrivateCount;public_trust_certificates=$TrustCount;private_key_exists=$KeyExists;private_location='CurrentUser';private_store='My';trust_location='LocalMachine';trust_store='TrustedPeople';cached_public_certificates=$CacheCount;cache_location='CurrentUser';cache_store='CA'}
}
function ReadPackageCertificateRemoval([string]$Text){
 if($Text.Length-gt 1024){throw 'The certificate removal observation exceeds its bound.'}
 $document=[Text.Json.JsonDocument]::Parse($Text)
 try{if($document.RootElement.ValueKind-ne [Text.Json.JsonValueKind]::Object){throw 'Certificate removal observation must be an object.'};$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);foreach($entry in $document.RootElement.EnumerateObject()){if(!$seen.Add($entry.Name)){throw 'Certificate removal observation repeats a field.'}}}finally{$document.Dispose()}
 $value=$Text|ConvertFrom-Json;$expected=@('schema','producer','private_certificates','public_trust_certificates','private_key_exists','private_location','private_store','trust_location','trust_store','cached_public_certificates','cache_location','cache_store'|Sort-Object)
 if((@($value.PSObject.Properties.Name|Sort-Object)-join ',')-cne ($expected-join ',') -or $value.schema-isnot [long] -or $value.schema-ne 1 -or $value.producer-cne 'PackageCertificateRemoval' -or $value.private_certificates-isnot [long] -or $value.private_certificates-ne 0 -or $value.public_trust_certificates-isnot [long] -or $value.public_trust_certificates-ne 0 -or $value.private_key_exists-isnot [bool] -or $value.private_key_exists -or $value.private_location-cne 'CurrentUser' -or $value.private_store-cne 'My' -or $value.trust_location-cne 'LocalMachine' -or $value.trust_store-cne 'TrustedPeople' -or $value.cached_public_certificates-isnot [long] -or $value.cached_public_certificates-ne 0 -or $value.cache_location-cne 'CurrentUser' -or $value.cache_store-cne 'CA'){throw 'The actual private certificate, public trust or key absence was not proved.'};$value
}
function GetPackageSnapshotComparison([string]$Before,[string]$After,[string]$OwnedCertificateSha){
 if($Before.Length-gt 8MB -or $After.Length-gt 8MB){throw 'Package preservation vectors exceed their bound.'}
 if($OwnedCertificateSha -and $OwnedCertificateSha-cnotmatch '^[a-f0-9]{64}$'){throw 'The optional owned certificate byte identity differs.'}
 $first=$Before|ConvertFrom-Json;$last=$After|ConvertFrom-Json;$observed=[ordered]@{}
 foreach($category in @('certificates','packages','registry')){
  $left=@($first.$category);$right=@($last.$category)
  $observed[$category]=[ordered]@{before_count=$left.Count;after_count=$right.Count;matches=(ConvertTo-Json -InputObject $left -Depth 14 -Compress)-ceq (ConvertTo-Json -InputObject $right -Depth 14 -Compress)}
 }
 $stores=[ordered]@{};foreach($location in @('CurrentUser','LocalMachine')){foreach($store in @('My','TrustedPeople','Root','CA')){
  $left=@($first.certificates|Where-Object {$_.location-ceq $location -and $_.store-ceq $store});$right=@($last.certificates|Where-Object {$_.location-ceq $location -and $_.store-ceq $store})
  $stores[$location+'_'+$store]=[ordered]@{before_count=$left.Count;after_count=$right.Count;matches=(ConvertTo-Json -InputObject $left -Depth 4 -Compress)-ceq (ConvertTo-Json -InputObject $right -Depth 4 -Compress);owned_byte_matches=$(if($OwnedCertificateSha){@($right|Where-Object bytes -CEQ $OwnedCertificateSha).Count}else{$null})}
 }};$observed.certificate_stores=$stores
 $roots=[ordered]@{startup_run='Software\Microsoft\Windows\CurrentVersion\Run';startup_approved='Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run';protocol='Software\Classes\openwebpbx';file_association='Software\Classes\.openwebpbx';protocol_choice='Software\Microsoft\Windows\Shell\Associations\UrlAssociations\openwebpbx\UserChoice';file_choice='Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.openwebpbx\UserChoice'}
 $registry=[ordered]@{};foreach($label in $roots.Keys){$path=$roots[$label];$left=@($first.registry|Where-Object {$_.path-ieq $path -or $_.path.StartsWith($path+'\',[StringComparison]::OrdinalIgnoreCase)});$right=@($last.registry|Where-Object {$_.path-ieq $path -or $_.path.StartsWith($path+'\',[StringComparison]::OrdinalIgnoreCase)});$registry[$label]=[ordered]@{before_nodes=$left.Count;after_nodes=$right.Count;matches=(ConvertTo-Json -InputObject $left -Depth 14 -Compress)-ceq (ConvertTo-Json -InputObject $right -Depth 14 -Compress);acl_matches=(ConvertTo-Json -InputObject @($left|Select-Object path,sddl) -Compress)-ceq (ConvertTo-Json -InputObject @($right|Select-Object path,sddl) -Compress)}};$observed.registry_roots=$registry;$observed
}

function GetPackageInterfaceFailure([Management.Automation.ErrorRecord]$Record,[string]$Mode,[string]$Stage){
 if($Mode-cnotin @('Update','Verify') -or $Stage-cnotin @('entry','root','process','load_uia','window','profile','update_banner','get_update','confirmation','install_restart','app_exit','receipt')){throw 'Unknown UI diagnostic context.'}
 $type=$Record.Exception.GetType().Name;if($type-cnotin @('RuntimeException','PSInvalidOperationException','InvalidOperationException','MethodInvocationException','MethodException','CmdletInvocationException','CommandNotFoundException','TypeLoadException','TimeoutException','IOException','UnauthorizedAccessException','ArgumentException','ArgumentNullException','InvalidCastException','ElementNotAvailableException','ElementNotEnabledException','NoClickablePointException','COMException')){ $type='other' }
 $source='other';$line=0
 if($null-ne $Record.InvocationInfo){$name=[IO.Path]::GetFileName([string]$Record.InvocationInfo.ScriptName);$number=[int]$Record.InvocationInfo.ScriptLineNumber;if($name-ceq 'Interface.ps1'-and$number-ge 1-and$number-le 10000){$source='Interface.ps1';$line=$number}}
 [ordered]@{schema=1;producer='PackageInterfaceFailure';mode=$Mode;stage=$Stage;error_type=$type;hresult=[int]$Record.Exception.HResult;source=$source;line=$line}
}
function WritePackageInterfaceFailure([Management.Automation.ErrorRecord]$Record,[string]$Mode,[string]$Stage){
 $value=GetPackageInterfaceFailure $Record $Mode $Stage;$culture=[Globalization.CultureInfo]::InvariantCulture
 [Console]::Error.WriteLine(('OPENWEBPBX_PACKAGE_INTERFACE_OBSERVATION {{"schema":1,"producer":"PackageInterfaceFailure","mode":"{0}","stage":"{1}","error_type":"{2}","hresult":{3},"source":"{4}","line":{5}}}' -f $value.mode,$value.stage,$value.error_type,$value.hresult.ToString($culture),$value.source,$value.line.ToString($culture)))
}
function ReadPackageInterfaceFailure([string]$Text,[string]$Mode){
 if($Text.Length-gt 8MB -or $Mode-cnotin @('Update','Verify')){throw 'The UI diagnostic scope differs.'}
 $prefix='OPENWEBPBX_PACKAGE_INTERFACE_OBSERVATION ';$lines=@($Text-split "`r?`n"|Where-Object {$_.StartsWith($prefix,[StringComparison]::Ordinal)})
 if($lines.Count-ne 1-or$lines[0].Length-gt 4096){throw 'A unique bounded UI diagnostic is required.'}
 $json=$lines[0].Substring($prefix.Length);$document=[Text.Json.JsonDocument]::Parse($json)
 try{if($document.RootElement.ValueKind-ne [Text.Json.JsonValueKind]::Object){throw 'UI diagnostic must be an object.'};$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);foreach($entry in $document.RootElement.EnumerateObject()){if(!$seen.Add($entry.Name)){throw 'UI diagnostic repeats a field.'}}}finally{$document.Dispose()}
 $value=$json|ConvertFrom-Json;$expected=@('schema','producer','mode','stage','error_type','hresult','source','line'|Sort-Object)
 if((@($value.PSObject.Properties.Name|Sort-Object)-join',')-cne($expected-join',')-or$value.schema-isnot[long]-or$value.schema-ne 1-or$value.producer-isnot[string]-or$value.producer-cne'PackageInterfaceFailure'-or$value.mode-isnot[string]-or$value.mode-cne$Mode-or$value.stage-isnot[string]-or$value.stage-cnotin@('entry','root','process','load_uia','window','profile','update_banner','get_update','confirmation','install_restart','app_exit','receipt')-or$value.error_type-isnot[string]-or$value.error_type-cnotin@('RuntimeException','PSInvalidOperationException','InvalidOperationException','MethodInvocationException','MethodException','CmdletInvocationException','CommandNotFoundException','TypeLoadException','TimeoutException','IOException','UnauthorizedAccessException','ArgumentException','ArgumentNullException','InvalidCastException','ElementNotAvailableException','ElementNotEnabledException','NoClickablePointException','COMException','other')-or$value.hresult-isnot[long]-or$value.hresult-lt[int]::MinValue-or$value.hresult-gt[int]::MaxValue-or$value.source-isnot[string]-or$value.source-cnotin@('Interface.ps1','other')-or$value.line-isnot[long]-or$value.line-lt 0-or$value.line-gt 10000-or($value.source-ceq'other'-and$value.line-ne 0)-or($value.source-ceq'Interface.ps1'-and$value.line-lt 1)){throw 'The typed UI diagnostic differs.'}
 $value
}
