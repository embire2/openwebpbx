# Execute actual Suite typed-report/privacy/replay consumers; no PBX access.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$checks=0
function Check([bool]$Value){if(!$Value){throw ('V20 evidence control refused at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
function Clone($Value){return ($Value|ConvertTo-Json -Depth 15|ConvertFrom-Json)}
function Refuses([scriptblock]$Action){$failed=$false;try{& $Action}catch{$failed=$true};Check $failed}
$tokens=$null;$errors=$null;$path=Join-Path $SourceRoot 'tests/windows-suite.ps1';$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors);Check ($errors.Count -eq 0)
foreach($name in 'ReadThreecxImportQualificationReport','SafeThreecxImportFailure','ThreecxImportQualificationHook'){$nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));Check ($nodes.Count -eq 1);Invoke-Expression $nodes[0].Extent.Text}
$trueFields=@('actual_native_windows','actual_installed_php_pg_zip_restore','configuration_path_adapter','synthetic_archive_only','original_credentials_preserved','custom_greeting_media_exact','default_greeting_unchanged','groups_and_routes_restored','providers_and_dids_disabled','complete_public_rows_exact','global_config_exact','owned_schema_media_key_removed','late_wav_failure_exact_rollback','original_writer_choices_restored')
$falseFields=@('ui_upload_tested','calling_tested','installed_server_changed','historical_failure_cause_proven')
$row=[ordered]@{schema=1;producer='windows_threecx_import_native.ps1';state='passed';cleanup='passed';checks=32;refusal_checks=4;php_version='8.4.27'}
foreach($field in $trueFields){$row[$field]=$true};foreach($field in $falseFields){$row[$field]=$false};$row=Clone $row
$valid=ReadThreecxImportQualificationReport $row;Check ($valid.Count -eq 25 -and $valid.configuration_path_adapter -and !$valid.ui_upload_tested)
foreach($field in $trueFields+$falseFields){foreach($bad in @('true',1,$null,@($true),$(if($field -cin $trueFields){$false}else{$true}))){$copy=Clone $row;$copy.$field=$bad;Refuses {ReadThreecxImportQualificationReport $copy|Out-Null}}}
foreach($field in 'schema','checks','refusal_checks'){foreach($bad in @('32',$true,@(32),[double]::NaN,$null,-1)){$copy=Clone $row;$copy.$field=$bad;Refuses {ReadThreecxImportQualificationReport $copy|Out-Null}}}
foreach($field in 'producer','state','cleanup','php_version'){foreach($bad in @($null,1,@($row.$field),'private-must-not-export')){$copy=Clone $row;$copy.$field=$bad;Refuses {ReadThreecxImportQualificationReport $copy|Out-Null}}}
foreach($bad in 0,31,1001){$copy=Clone $row;$copy.checks=$bad;Refuses {ReadThreecxImportQualificationReport $copy|Out-Null}}
foreach($bad in 0,3,5){$copy=Clone $row;$copy.refusal_checks=$bad;Refuses {ReadThreecxImportQualificationReport $copy|Out-Null}}
foreach($good in 32,33,1000){$copy=Clone $row;$copy.checks=$good;Check ((ReadThreecxImportQualificationReport $copy).checks -eq $good)}
$copy=Clone $row;$copy|Add-Member NoteProperty private_data 'private-must-not-export';Check ((ReadThreecxImportQualificationReport $copy|ConvertTo-Json -Depth 8) -cnotmatch 'private-must-not-export')
$failure=[pscustomobject]@{schema=1;producer='windows_threecx_import_native.ps1';state='failed';cleanup='failed';checks=17;error_type='RuntimeException';source_line=44;writer_restoration_failed=$true;php_failure=[pscustomobject]@{phase='bad_wav_rollback';error_type='InvalidArgumentException';source_basename='pbx_v20_restore.php';source_line=245;cleanup_failed=$false};private_data='private-must-not-export'}
$safe=SafeThreecxImportFailure $failure;Check ($safe.php_failure.phase -ceq 'bad_wav_rollback' -and $safe.writer_restoration_failed -and ($safe|ConvertTo-Json -Depth 8) -cnotmatch 'private-must-not-export')
foreach($field in 'phase','error_type','source_basename','source_line','cleanup_failed'){$copy=Clone $failure;$copy.php_failure.$field='private-must-not-export';$safe=SafeThreecxImportFailure $copy;Check (!$safe.ContainsKey('php_failure') -and ($safe|ConvertTo-Json -Depth 8) -cnotmatch 'private-must-not-export')}
foreach($field in 'producer','state'){$copy=Clone $failure;$copy.$field=@($failure.$field);Check ((SafeThreecxImportFailure $copy).Count -eq 0)}
# Actual hook's replay branch must refuse qualification before any producer/file access.
$ReplaySuiteRunId='39881454549';$facts=@{};ThreecxImportQualificationHook;Check ($facts.threecx_import_qualification -ceq 'unqualified_historical_candidate' -and $facts.Count -eq 1)
$text=[IO.File]::ReadAllText($path);$ready=$text.IndexOf("`$phase='native web readiness qualification';WebReadinessHook");$import=$text.IndexOf("`$phase='native synthetic V20 import qualification';ThreecxImportQualificationHook");$health=$text.IndexOf("`$phase='native STUN qualification';StunHook");Check ($ready -ge 0 -and $import -gt $ready -and $health -gt $import)
[ordered]@{schema=1;state='passed';checks=$checks;actual_suite_consumer=$true;server_actions=$false}|ConvertTo-Json -Compress
