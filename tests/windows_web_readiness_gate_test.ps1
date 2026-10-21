# QA-only actual safe-projector controls; no Windows services or certificates.
$ErrorActionPreference='Stop';$checks=0
function Check([bool]$Value){if(!$Value){throw 'Readiness gate privacy control failed.'};$script:checks++}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'windows-suite.ps1'),[ref]$tokens,[ref]$errors)
Check ($errors.Count -eq 0)
$functions=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'SafeWebReadinessReport'},$true))
Check ($functions.Count -eq 1);Invoke-Expression $functions[0].Extent.Text
$valid=@{schema=1;state='passed';case='native_windows_readiness_tls_boolean';checks=29;cleanup_exact=$true;phase='complete';error_type='none';source_line=0;manifest_helper_hash=$true;scalar_boolean=$true;trusted_tls=$true;actual_iis=$true}
$result=SafeWebReadinessReport $valid
Check ($result.state -ceq 'passed' -and $result.checks -eq 29 -and $result.scalar_boolean -eq $true)
$extra=@{}+$valid;$extra.body='PRIVATE_NEVER_PUBLISH';$extra.path='PRIVATE_NEVER_PUBLISH';$extra.exception='PRIVATE_NEVER_PUBLISH'
Check (((SafeWebReadinessReport $extra)|ConvertTo-Json -Depth 8) -cnotmatch 'PRIVATE_NEVER_PUBLISH')
foreach($field in 'manifest_helper_hash','scalar_boolean','trusted_tls','actual_iis','cleanup_exact'){
 foreach($value in 'true',1,$null){$copy=@{}+$valid;$copy[$field]=$value;Check ($null -eq (SafeWebReadinessReport $copy))}
 $copy=@{}+$valid;$copy[$field]=$false;$observed=SafeWebReadinessReport $copy;Check ($null -ne $observed -and $observed[$field] -is [bool] -and !$observed[$field])
}
foreach($case in @(
 @{field='schema';value='1'},@{field='schema';value=2},@{field='case';value='foreign_case'},@{field='state';value='PRIVATE_NEVER_PUBLISH'},
 @{field='checks';value='29'},@{field='checks';value=-1},@{field='checks';value=101},@{field='phase';value='PRIVATE_NEVER_PUBLISH'},
 @{field='error_type';value='PRIVATE_NEVER_PUBLISH'},@{field='source_line';value='1'},@{field='source_line';value=-1},@{field='source_line';value=100000}
)){$copy=@{}+$valid;$copy[$case.field]=$case.value;Check ($null -eq (SafeWebReadinessReport $copy))}
$failed=@{}+$valid;$failed.state='failed';$failed.phase='fixture';$failed.error_type='AuthenticationException';$failed.source_line=123;$failed.actual_iis=$false
$result=SafeWebReadinessReport $failed;Check ($result.state -ceq 'failed' -and $result.error_type -ceq 'AuthenticationException' -and $result.source_line -eq 123 -and !$result.actual_iis)
Write-Output ('PASS '+$checks+' actual Windows readiness gate type/privacy controls; no native acceptance claimed')
