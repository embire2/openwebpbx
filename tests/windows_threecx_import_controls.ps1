# Pure actual-source evidence/refusal controls; no native service or server action.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows_threecx_import_native.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The native synthetic import wrapper does not parse.'}
foreach($name in 'Assert-ThreecxImportReport','Get-ThreecxImportFailure'){$nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));if($nodes.Count -ne 1){throw 'The actual source validator must be uniquely selected.'};Invoke-Expression $nodes[0].Extent.Text}
$checks=0;function Check([bool]$Value){if(!$Value){throw ('Import evidence control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
function Refuses($Row){$failed=$false;try{Assert-ThreecxImportReport $Row}catch{$failed=$true};Check $failed}
function Copy-ImportRecord($Row){$Row|ConvertTo-Json -Depth 8|ConvertFrom-Json}
$good=[pscustomobject]@{schema=1;producer='windows_threecx_import_native.php';state='passed';checks=32;php_version='8.4.27'}
foreach($name in 'actual_windows_native','actual_php_pg_zip_restore','configuration_path_adapter','synthetic_archive_only','original_credentials_preserved','custom_greeting_media_exact','default_greeting_unchanged','groups_and_routes_restored','providers_and_dids_disabled','complete_public_rows_exact','global_config_exact','owned_schema_media_key_removed','late_wav_failure_exact_rollback'){$good|Add-Member NoteProperty $name $true}
foreach($name in 'ui_upload_tested','calling_tested','installed_server_changed','historical_failure_cause_proven'){$good|Add-Member NoteProperty $name $false}
Assert-ThreecxImportReport $good;Check $true
foreach($name in @($good.PSObject.Properties.Name)){
 $copy=Copy-ImportRecord $good;$copy.PSObject.Properties.Remove($name);Refuses $copy
 foreach($bad in @($null,@('true'),@{PRIVATE='secret'})){$copy=Copy-ImportRecord $good;$copy.$name=$bad;Refuses $copy}
 if($good.$name -is [bool]){foreach($bad in @((!$good.$name),[string]$good.$name)){$copy=Copy-ImportRecord $good;$copy.$name=$bad;Refuses $copy}}
}
foreach($bad in 0,31,1001,'32',32.5,$true){$copy=Copy-ImportRecord $good;$copy.checks=$bad;Refuses $copy}
foreach($bad in '8.4.26','8.4.27 ',$true){$copy=Copy-ImportRecord $good;$copy.php_version=$bad;Refuses $copy}
foreach($bad in 'running','failed','Passed'){$copy=Copy-ImportRecord $good;$copy.state=$bad;Refuses $copy}
foreach($bad in $null,$true,'PRIVATE',@($good)){Refuses $bad}
$failure=[pscustomobject]@{state='failed';phase='apply';error_type='PDOException';source_basename='pbx_v20_restore.php';source_line=212;cleanup_failed=$false;password='PRIVATE';sql='PRIVATE'}
$safe=Get-ThreecxImportFailure $failure;Check ($safe.Count -eq 5 -and $safe.phase -ceq 'apply' -and ($safe|ConvertTo-Json -Compress) -cnotmatch 'PRIVATE|password|sql')
foreach($field in 'phase','error_type','source_basename','source_line','cleanup_failed'){$copy=Copy-ImportRecord $failure;$copy.$field='PRIVATE';Check ((Get-ThreecxImportFailure $copy).Count -eq 0)}
Write-Output ('PASS '+$checks+' actual synthetic import validator/type/count/scope/privacy controls; no Windows/PBX invoked')
