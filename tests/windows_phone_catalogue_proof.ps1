function Read-WindowsPhoneCatalogueCommitBinding($Value){
 $fields=@('schema','bytes','sha256','stdout_bytes','stderr_bytes','php_action','php_child_exit')
 $keys=if($Value -is [pscustomobject]){@($Value.PSObject.Properties.Name)}elseif($Value -is [Collections.IDictionary]){@($Value.Keys)}else{@()}
 if($keys.Count-ne $fields.Count -or @($keys|Where-Object {$_ -cnotin $fields}).Count){throw 'The original commit binding shape differs.'}
 foreach($n in 'schema','bytes','stdout_bytes','stderr_bytes','php_child_exit'){if($Value.$n -isnot [int] -and $Value.$n -isnot [long]){throw 'The original commit binding integer differs.'}}
 if($Value.schema-ne 1 -or $Value.stdout_bytes-lt 0 -or $Value.stdout_bytes-gt 65536 -or $Value.stderr_bytes-lt 0 -or $Value.stderr_bytes-gt 65536 -or $Value.bytes-ne (8+$Value.stdout_bytes+$Value.stderr_bytes) -or $Value.bytes-gt 131080 -or $Value.sha256 -isnot [string] -or $Value.sha256-cnotmatch '^[a-f0-9]{64}$' -or $Value.php_child_exit-lt [int]::MinValue -or $Value.php_child_exit-gt [int]::MaxValue){throw 'The original commit size/hash/exit binding differs.'}
 if($Value.php_action -isnot [string] -or $Value.php_action-cnotin '--seed','--hold','--refresh','--assert-exclusive','--prepared-stage-check','--read','--before-rename','--after-rename','commit_without_parent','before_enable','after_enable','after_complete','unrecognised'){throw 'The original commit child action differs.'}
 $result=[ordered]@{};foreach($field in $fields){$result[$field]=$Value.$field};return $result
}
function Read-WindowsPhoneCatalogueOriginalBinding($Value){
 $fields=@('schema','bytes','sha256','stdout_characters','stderr_characters')
 $keys=if($Value -is [pscustomobject]){@($Value.PSObject.Properties.Name)}elseif($Value -is [Collections.IDictionary]){@($Value.Keys)}else{@()}
 if($keys.Count -ne $fields.Count -or @($keys|Where-Object {$_ -cnotin $fields}).Count){throw 'The original child binding shape differs.'}
 foreach($n in 'schema','bytes','stdout_characters','stderr_characters'){if($Value.$n -isnot [int] -and $Value.$n -isnot [long]){throw 'The original child binding integer differs.'}}
 if($Value.schema -ne 1 -or $Value.stdout_characters -lt 0 -or $Value.stdout_characters -gt 32768 -or $Value.stderr_characters -lt 0 -or $Value.stderr_characters -gt 32768 -or $Value.bytes -ne (8+2*($Value.stdout_characters+$Value.stderr_characters)) -or $Value.bytes -gt 131080 -or $Value.sha256 -isnot [string] -or $Value.sha256 -cnotmatch '^[a-f0-9]{64}$'){throw 'The exact original child size/hash binding differs.'}
 $result=[ordered]@{};foreach($field in $fields){$result[$field]=$Value.$field};return $result
}
# Closed receipt consumer; safe to dot-source without native actions.
function Get-WindowsPhoneCatalogueNativeCases {
 return @('php_crypto_fixture_seeded','php_parent_blocks_dotnet_exclusive','php_parent_blocks_other_php','parent_commit_uses_real_movefileex','commit_child_refuses_without_parent','dotnet_parent_blocks_php','php_recovers_after_dotnet_release','before_rename_child_killed_only_after_prepared_stage','before_rename_recovery_forward','after_rename_child_killed_only_after_prepared_journal','after_rename_recovery_forward','expired_prepared_highwater_unavailable','fresh_higher_release_after_expired_recovery','partial_stage_preserved','native_task_staged_disabled','native_task_foreign_action_preserved','native_task_foreign_trigger_preserved','native_task_foreign_principal_preserved','native_task_foreign_settings_preserved','native_task_foreign_security_preserved','native_activation_requires_completed_install','native_activation_preserves_disabled_choice','native_activation_before_enable_kill_recovery','native_activation_after_enable_kill_recovery','native_activation_after_complete_kill_recovery','native_activation_terminal_preserves_admin_choice','native_scheduled_worker_system_identity','native_owned_task_removed_only','source_runtime_whole_inventory_exact','original_services_files_exact')
}
function Read-WindowsPhoneCatalogueQualificationRecord {
 param($Record,[ValidateSet('Desktop','Core')][string]$Edition,[string]$SourceManifestSha256,[string]$PhpSha256)
 $positive=@('actual_ntfs','actual_php_flock','actual_powershell_exclusive','actual_movefileex','actual_scheduler','actual_system_worker','actual_activation_child_kills','real_primitive_checkpoint_wrappers','path_fetch_clock_taskname_adapters','reader_sid_adapter','whole_source_runtime_exact','original_services_files_tasks_exact')
 $negative=@('private_key_persisted','installed_server_changed','iis_or_database_or_firewall_changed','actual_iis_reader_tested','full_upgrade_restore_qualified','production_release_published')
 $fields=@('schema','producer','state','edition','source_manifest_sha256','php_executable_sha256','checks','cases','ephemeral_rsa_bits')+$positive+$negative
 if($null -eq $Record -or $Record.GetType().FullName -cne 'System.Management.Automation.PSCustomObject' -or @($Record.PSObject.Properties).Count -ne $fields.Count){throw 'The catalogue component record shape differs.'}
 foreach($name in $Record.PSObject.Properties.Name){if($name -cnotin $fields){throw 'An unknown catalogue component field was refused.'}}
 foreach($field in 'schema','checks','ephemeral_rsa_bits'){if($Record.$field -isnot [int] -and $Record.$field -isnot [long]){throw 'A catalogue component integer is mistyped.'}}
 $expected=@(Get-WindowsPhoneCatalogueNativeCases)
 if($Record.schema -ne 1 -or $Record.checks -ne $expected.Count -or $Record.ephemeral_rsa_bits -ne 3072 -or $Record.producer -isnot [string] -or $Record.producer -cne 'windows_phone_catalogue_native.ps1' -or $Record.state -isnot [string] -or $Record.state -cne 'passed' -or $Record.edition -isnot [string] -or $Record.edition -cne $Edition){throw 'The catalogue component identity differs.'}
 foreach($binding in @(@('source_manifest_sha256',$SourceManifestSha256),@('php_executable_sha256',$PhpSha256))){if($binding[1] -cnotmatch '^[a-f0-9]{64}$' -or $Record.($binding[0]) -isnot [string] -or $Record.($binding[0]) -cne $binding[1]){throw 'The catalogue component source/runtime binding differs.'}}
 if($Record.cases -isnot [array] -or $Record.cases.Count -ne $expected.Count){throw 'The complete catalogue cases are required.'}
 foreach($name in $Record.cases){if($name -isnot [string]){throw 'A catalogue case is mistyped.'}}
 if(($Record.cases -join '|') -cne ($expected -join '|')){throw 'An omitted, duplicate, unknown or reordered catalogue case was refused.'}
 foreach($name in $positive){if($Record.$name -isnot [bool] -or !$Record.$name){throw 'An actual catalogue primitive was not proved.'}}
 foreach($name in $negative){if($Record.$name -isnot [bool] -or $Record.$name){throw 'An unsupported catalogue qualification claim was refused.'}}
 $safe=[ordered]@{};foreach($name in $fields){$safe[$name]=$Record.$name};return $safe
}

function Get-WindowsPhoneCatalogueFailureMetadata {
 param([Management.Automation.ErrorRecord]$Failure)
 $name=[IO.Path]::GetFileName([string]$Failure.InvocationInfo.ScriptName)
 if($name -cnotin 'windows_phone_catalogue_native.ps1','windows-phone-catalogue-qualification.ps1','WindowsPhoneCatalogue.Common.ps1','UpgradeRecovery.Common.ps1','File-Security.ps1','Restore-Gates.ps1','PhpRuntime.Common.ps1','windows_phone_catalogue_proof.ps1'){$name='external_component'}
 $line=[int]$Failure.InvocationInfo.ScriptLineNumber;if($line -lt 0 -or $line -gt 100000){$line=0}
 $type=$Failure.Exception.GetType().FullName
 if($type -cnotin 'System.Management.Automation.RuntimeException','System.Management.Automation.MethodInvocationException','System.Management.Automation.ActionPreferenceStopException','System.Management.Automation.ParseException','System.Management.Automation.ParameterBindingException','System.Management.Automation.ItemNotFoundException','System.Management.Automation.CommandNotFoundException','System.IO.IOException','System.IO.FileNotFoundException','System.UnauthorizedAccessException','System.ArgumentException','System.InvalidOperationException','System.TimeoutException'){$type='external_error'}
 return [ordered]@{source_basename=$name;source_line=$line;error_type=$type}
}
function Read-WindowsPhoneCataloguePhpFailure {
 param($Value)
 $fields=@('schema','producer','state','source_basename','source_line','error_type')
 if($null -eq $Value -or $Value.GetType().FullName -cne 'System.Management.Automation.PSCustomObject' -or @($Value.PSObject.Properties).Count -ne $fields.Count){throw 'The PHP fixture diagnostic shape differs.'}
 foreach($name in $Value.PSObject.Properties.Name){if($name -cnotin $fields){throw 'An unknown PHP fixture diagnostic field was refused.'}}
 if(($Value.schema -isnot [int] -and $Value.schema -isnot [long]) -or $Value.schema -ne 1 -or $Value.producer -isnot [string] -or $Value.producer -cne 'windows_phone_catalogue_native.php' -or $Value.state -isnot [string] -or $Value.state -cne 'failed'){throw 'The PHP fixture diagnostic identity differs.'}
 if(($Value.source_line -isnot [int] -and $Value.source_line -isnot [long]) -or $Value.source_line -lt 0 -or $Value.source_line -gt 100000 -or $Value.source_basename -isnot [string] -or $Value.source_basename -cnotin 'windows-phone-catalogue.php','windows_phone_catalogue_native.php','refresh.fixture.php','pbx_windows_phone_catalogue.php','external_component' -or $Value.error_type -isnot [string] -or $Value.error_type -cnotin 'RuntimeException','InvalidArgumentException','UnexpectedValueException','JsonException','TypeError','ValueError','Error','ErrorException','windows_phone_catalogue_failure','external_error'){throw 'The PHP fixture diagnostic source or type differs.'}
 $safe=[ordered]@{};foreach($name in $fields){$safe[$name]=$Value.$name};return $safe
}
function Get-WindowsPhoneCatalogueChildOutput {
 param([string]$Action,[bool]$ExpectedSuccess,[string]$Stdout,[string]$Stderr)
 if($Stdout.Length -gt 32768 -or $Stderr.Length -gt 32768){throw 'The owned output observation exceeds its original bound.'}
 $text=$Stdout.Trim();$shape='empty'
 if($text){$shape='non_json';try{$null=$text|ConvertFrom-Json -ErrorAction Stop;$shape=if($text.StartsWith('{')){'json_object'}elseif($text.StartsWith('[')){'json_array'}else{'json_scalar'}}catch{}}
 $allowed=@('--seed','--hold','--refresh','--assert-exclusive','--prepared-stage-check','--read','--before-rename','--after-rename','commit_without_parent','before_enable','after_enable','after_complete')
 $row=[pscustomobject]@{action=if($Action -cin $allowed){$Action}else{'unrecognised'};expected_success=$ExpectedSuccess;stdout_characters=$Stdout.Length;stderr_characters=$Stderr.Length;stdout_shape=$shape;php_warning_prefix=($text.StartsWith('Warning:') -or $text.StartsWith('PHP Warning:'))}
 return (Read-WindowsPhoneCatalogueChildOutput $row)
}
function Read-WindowsPhoneCatalogueChildOutput {
 param($Value)
 $fields=@('action','expected_success','stdout_characters','stderr_characters','stdout_shape','php_warning_prefix')
 $keys=if($Value -is [pscustomobject]){@($Value.PSObject.Properties.Name)}elseif($Value -is [Collections.IDictionary]){@($Value.Keys)}else{@()}
 if($keys.Count -ne $fields.Count -or @($keys|Where-Object {$_ -cnotin $fields}).Count){throw 'The owned child output shape differs.'}
 if($Value.action -isnot [string] -or $Value.action -cnotin '--seed','--hold','--refresh','--assert-exclusive','--prepared-stage-check','--read','--before-rename','--after-rename','commit_without_parent','before_enable','after_enable','after_complete','unrecognised' -or $Value.stdout_shape -isnot [string] -or $Value.stdout_shape -cnotin 'empty','non_json','json_object','json_array','json_scalar'){throw 'A fixed child action/output class is required.'}
 foreach($flag in 'expected_success','php_warning_prefix'){if($Value.$flag -isnot [bool]){throw 'A child output flag is mistyped.'}}
 foreach($size in 'stdout_characters','stderr_characters'){if(($Value.$size -isnot [int] -and $Value.$size -isnot [long]) -or $Value.$size -lt 0 -or $Value.$size -gt 32768){throw 'The child output observation exceeds its bound.'}}
 if(($Value.stdout_characters -eq 0 -and $Value.stdout_shape -cne 'empty') -or ($Value.php_warning_prefix -and $Value.stdout_shape -cne 'non_json')){throw 'The child output observation is inconsistent.'}
 $out=[ordered]@{};foreach($field in $fields){$out[$field]=$Value.$field};return $out
}
function Read-WindowsPhoneCatalogueNativeFailure {
 param($Value,[ValidateSet('Desktop','Core')][string]$Edition)
 $fields=@('schema','producer','state','phase','source_basename','source_line','error_type','edition','php_child_exit','php_failure','php_output','php_original','commit_original','child_processes_closed','owned_task_removed','original_vectors_preserved','owned_scope_retained','cleanup_required','actual_native_qualified')
 if($null -eq $Value -or $Value.GetType().FullName -cne 'System.Management.Automation.PSCustomObject' -or @($Value.PSObject.Properties).Count -ne $fields.Count){throw 'The native catalogue diagnostic shape differs.'}
 foreach($name in $Value.PSObject.Properties.Name){if($name -cnotin $fields){throw 'An unknown native catalogue diagnostic field was refused.'}}
 if(($Value.schema -isnot [int] -and $Value.schema -isnot [long]) -or $Value.schema -ne 1 -or $Value.producer -isnot [string] -or $Value.producer -cne 'windows_phone_catalogue_native.ps1' -or $Value.state -isnot [string] -or $Value.state -cne 'failed' -or $Value.edition -isnot [string] -or $Value.edition -cne $Edition){throw 'The native catalogue diagnostic identity differs.'}
 if($Value.phase -isnot [string] -or $Value.phase -cnotin 'preflight','preparation','initialization','seed','mutual_exclusion','interruption','scheduler','preservation','report'){throw 'The native catalogue phase differs.'}
 if(($Value.source_line -isnot [int] -and $Value.source_line -isnot [long]) -or $Value.source_line -lt 0 -or $Value.source_line -gt 100000 -or $Value.source_basename -isnot [string] -or $Value.source_basename -cnotin 'windows_phone_catalogue_native.ps1','windows-phone-catalogue-qualification.ps1','WindowsPhoneCatalogue.Common.ps1','UpgradeRecovery.Common.ps1','File-Security.ps1','Restore-Gates.ps1','PhpRuntime.Common.ps1','windows_phone_catalogue_proof.ps1','external_component' -or $Value.error_type -isnot [string] -or $Value.error_type -cnotin 'System.Management.Automation.RuntimeException','System.Management.Automation.MethodInvocationException','System.Management.Automation.ActionPreferenceStopException','System.Management.Automation.ParseException','System.Management.Automation.ParameterBindingException','System.Management.Automation.ItemNotFoundException','System.Management.Automation.CommandNotFoundException','System.IO.IOException','System.IO.FileNotFoundException','System.UnauthorizedAccessException','System.ArgumentException','System.InvalidOperationException','System.TimeoutException','external_error'){throw 'The native catalogue diagnostic source or type differs.'}
 if($null -ne $Value.php_child_exit -and (($Value.php_child_exit -isnot [int] -and $Value.php_child_exit -isnot [long]) -or $Value.php_child_exit -lt [int]::MinValue -or $Value.php_child_exit -gt [int]::MaxValue)){throw 'The PHP fixture exit is mistyped.'}
 $php=$null;if($null -ne $Value.php_failure){if($null -eq $Value.php_child_exit -or $Value.php_child_exit -eq 0){throw 'The PHP diagnostic requires its original failed child exit.'};$php=Read-WindowsPhoneCataloguePhpFailure $Value.php_failure}
 $output=$null;if($null -ne $Value.php_output){if($null -eq $Value.php_child_exit){throw 'The output observation requires its original child exit.'};$output=Read-WindowsPhoneCatalogueChildOutput $Value.php_output}
 $original=$null;if($null -ne $Value.php_original){if($null -eq $output){throw 'The retained original requires its child output projection.'};$original=Read-WindowsPhoneCatalogueOriginalBinding $Value.php_original;if($original.stdout_characters -ne $output.stdout_characters -or $original.stderr_characters -ne $output.stderr_characters){throw 'The original and projected output sizes differ.'}}
 $commit=$null;if($null-ne $Value.commit_original){$commit=Read-WindowsPhoneCatalogueCommitBinding $Value.commit_original;if($null-eq $Value.php_child_exit -or $commit.php_child_exit-ne $Value.php_child_exit -or $null-ne $original){throw 'The commit stream requires its exclusive original PHP failure binding.'}}
 foreach($flag in 'child_processes_closed','owned_task_removed','original_vectors_preserved','owned_scope_retained','cleanup_required','actual_native_qualified'){if($Value.$flag -isnot [bool]){throw 'A native diagnostic flag is mistyped.'}}
 if($Value.actual_native_qualified -or ($Value.owned_scope_retained -and !$Value.cleanup_required -and (!$Value.child_processes_closed -or !$Value.owned_task_removed -or !$Value.original_vectors_preserved))){throw 'A native failure cannot claim unverified cleanup or qualification.'}
 $safe=[ordered]@{};foreach($name in $fields){$safe[$name]=$Value.$name};$safe.php_failure=$php;$safe.php_output=$output;$safe.php_original=$original;$safe.commit_original=$commit;return $safe
}
