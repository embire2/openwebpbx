# Pure actual-source evidence/refusal controls; no native service or server action.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows_threecx_import_native.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The native synthetic import wrapper does not parse.'}
foreach($name in 'Assert-ThreecxImportReport','Get-ThreecxImportFailure','Get-ThreecxRefusalObservation','Get-ThreecxCleanupState'){$nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));if($nodes.Count -ne 1){throw 'The actual source validator must be uniquely selected.'};Invoke-Expression $nodes[0].Extent.Text}
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
# Execute the actual argument-building loop; comma/+ precedence must not split -c.
$argumentLoops=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.ForEachStatementAst] -and $n.Variable.VariablePath.UserPath -ceq 'argument' -and $n.Body.Extent.Text -like '*$start.ArgumentList.Add*'},$true))
Check ($argumentLoops.Count -eq 1)
foreach($root in 'C:\OpenWebPBX','C:\Owned folder\OpenWebPBX'){
 foreach($Arguments in @(@(),@('C:\Owned folder\private input'))){
  $file='D:\source folder\windows_threecx_import_refusals.php';$start=[pscustomobject]@{ArgumentList=[Collections.Generic.List[string]]::new()}
  Invoke-Expression $argumentLoops[0].Extent.Text
  Check ($start.ArgumentList.Count -eq 3+$Arguments.Count)
  Check ($start.ArgumentList[0] -ceq '-c' -and $start.ArgumentList[1] -ceq ($root+'\php\php.ini') -and $start.ArgumentList[2] -ceq $file)
  if($Arguments.Count){Check ($start.ArgumentList[3] -ceq $Arguments[0])}
 }
}
foreach($ending in "`n","`r`n"){
 $record=@{ExitCode=0;Stdout='PASS 4 actual import early-refusal/sentinel-preservation controls; no database or PBX used'+$ending;Stderr=''}
 $safe=Get-ThreecxRefusalObservation $record;Check ($safe.exit_code -eq 0 -and $safe.stdout_shape -ceq 'expected_success' -and $safe.stderr_shape -ceq 'empty' -and $safe.stdout_chars -eq $record.Stdout.Length -and $safe.stderr_chars -eq 0)
}
$record=@{ExitCode=1;Stdout="Could not open input file: PRIVATE`r`n";Stderr=''};$safe=Get-ThreecxRefusalObservation $record;Check ($safe.stdout_shape -ceq 'input_file_unavailable' -and ($safe|ConvertTo-Json -Compress) -cnotmatch 'PRIVATE')
foreach($item in @(@('PHP Warning: PHP Startup: PRIVATE','php_startup_warning'),@('PHP Fatal error: Uncaught RuntimeException: PRIVATE','php_fatal'),@('PHP Warning: PRIVATE','php_warning'),@('PRIVATE','other'))){$record=@{ExitCode=1;Stdout='';Stderr=$item[0]};$safe=Get-ThreecxRefusalObservation $record;Check ($safe.stderr_shape -ceq $item[1] -and $safe.stdout_shape -ceq 'empty' -and ($safe|ConvertTo-Json -Compress) -cnotmatch 'PRIVATE')}
foreach($MainStarted in $false,$true){foreach($Proven in $false,$true){foreach($Restored in $false,$true){foreach($Failed in $false,$true){$expected=if(!$Restored -or $Failed){'failed'}elseif(!$MainStarted -or $Proven){'passed'}else{'unverified'};Check ((Get-ThreecxCleanupState $MainStarted $Proven $Restored $Failed) -ceq $expected)}}}}
Write-Output ('PASS '+$checks+' actual synthetic import validator/type/count/scope/privacy controls; no Windows/PBX invoked')
