#Requires -Version 7.4
# SPDX-License-Identifier: AGPL-3.0-or-later
# Actual required native case/projection AST; no PBX, database or mail changes.
$ErrorActionPreference='Stop';$checks=0
foreach($pair in @(@('windows-native-acceptance.ps1',@('AssertWelcomeNativeCase','SmtpFailureFields')),@('windows-suite.ps1',@('SafeSmtpFailureFields')))){
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $pair[0]),[ref]$tokens,[ref]$errors)
 if($errors.Count){throw 'The actual native welcome caller does not parse.'}
 foreach($name in $pair[1]){$nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));if($nodes.Count -ne 1){throw 'One exact native welcome function is required.'};Invoke-Expression $nodes[0].Extent.Text}
}
function Check([bool]$Value){if(!$Value){throw ('Welcome scope control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
function Clone($Value){return($Value|ConvertTo-Json -Depth 12|ConvertFrom-Json)}
function Refuse($Rows){$failed=$false;try{AssertWelcomeNativeCase $Rows}catch{$failed=$true};Check $failed}
$flags=@('actual_php_postgresql_dispatcher','two_concurrent_dispatchers','one_actual_loopback_delivery','inline_qr_cid_exact','independent_qr_decoded','qr_and_attached_config_exact','password_free_one_use_setup','used_invitation_suppressed','same_framework_backend','no_php_ini_or_gd_renderer','alias_custody_modelled','tls_readiness_modelled','no_external_mail','actual_windows_native','public_rows_exact','global_mail_config_exact','owned_schema_and_locks_removed','private_credentials_removed')
$row=@{case='native_welcome_inline_qr_config_actual_loopback';passed=$true;state='passed';checks=29;gd_required=$false;decoder_sha256='29f98a91148171460b47a942d137ecc90c4b8097636f23cca65263a56bb025d3'};foreach($flag in $flags){$row[$flag]=$true};$row=[pscustomobject]$row
AssertWelcomeNativeCase @($row);$checks++
Refuse @();Refuse @($row,$row)
foreach($field in @('passed')+$flags){foreach($bad in $false,'true',1,$null){$copy=Clone $row;$copy.$field=$bad;Refuse @($copy)}}
foreach($bad in 28,100001,'29',$true,29.0,$null){$copy=Clone $row;$copy.checks=$bad;Refuse @($copy)}
foreach($bad in $true,'false',0,$null){$copy=Clone $row;$copy.gd_required=$bad;Refuse @($copy)}
foreach($field in 'case','state','decoder_sha256'){foreach($bad in 'private-value',1,$null){$copy=Clone $row;$copy.$field=$bad;Refuse @($copy)}}
$failure=[pscustomobject]@{active_case='native_welcome_inline_qr_config_actual_loopback';welcome_phase='queue';welcome_error_type='PDOException';welcome_source_basename='pbx_mobile.php';welcome_source_line=38;welcome_sqlstate='42P01';welcome_cleanup_failed=$false;password='private-never-copy';body='private-never-copy';raw_stderr='private-never-copy'}
foreach($filter in 'SmtpFailureFields','SafeSmtpFailureFields'){
 $safe=& $filter $failure;Check ($safe.Count -eq 6 -and $safe.welcome_sqlstate -ceq '42P01' -and ($safe|ConvertTo-Json) -notmatch 'private-never-copy|password|body|raw_stderr')
 foreach($pair in @(@('welcome_phase','private-value'),@('welcome_error_type','private-value'),@('welcome_source_basename','C:\private\config.conf'),@('welcome_source_line',0),@('welcome_source_line',100001),@('welcome_source_line','38'),@('welcome_sqlstate','42p01'),@('welcome_sqlstate',42501))){$copy=Clone $failure;$copy.($pair[0])=$pair[1];Check ((& $filter $copy).Count -eq 1)}
 $copy=Clone $failure;$copy.welcome_cleanup_failed='false';Check ((& $filter $copy).Count -eq 5)
 $copy=Clone $failure;$copy.active_case='private-value';Check ((& $filter $copy).Count -eq 0)
}
@{state='passed';checks=$checks;actual_caller_ast=$true;no_pbx_or_mail_changes=$true}|ConvertTo-Json -Compress
