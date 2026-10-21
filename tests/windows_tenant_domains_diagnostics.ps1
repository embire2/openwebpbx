# Exercise the actual report projector without invoking IIS, a worker or a PBX.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-suite.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The actual suite must parse.'}
foreach($name in 'SafeQueueFailureFields','SafeVoicemailFailureFields','SafeMailboxFailureFields','SafeHotelFailureFields','SafeSmtpFailureFields','SafeNativeCleanupFields','SafeFailureFields','SafeTenantDomainsReport'){
 $nodes=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true))
 if($nodes.Count -ne 1){throw 'The actual report projector must be unique.'}
 Invoke-Expression $nodes[0].Extent.Text
}
$checks=0
function Check([bool]$Value){if(!$Value){throw 'The tenant-domain report projection failed.'};$script:checks++}
function Record {
 [pscustomobject]@{schema=1;state='failed';case='native_windows_tenant_alias_worker_iis_https';phase='proof_prepare';exception_type='RuntimeException';source_basename='Tenant-Domains.ps1';source_line=123;cleanup_exact=$true;password='PRIVATE_NEVER_PUBLISH';message='PRIVATE_NEVER_PUBLISH';hostname='PRIVATE_NEVER_PUBLISH'}
}
$record=Record;$safe=SafeTenantDomainsReport $record
Check ($safe.active_case -ceq 'native_windows_tenant_proof_prepare' -and $safe.error_type -ceq 'RuntimeException' -and $safe.source_basename -ceq 'Tenant-Domains.ps1' -and $safe.source_line -eq 123 -and $safe.cleanup_exact -is [bool] -and $safe.cleanup_exact)
Check (($safe|ConvertTo-Json -Depth 8) -cnotmatch 'PRIVATE_NEVER_PUBLISH|password|hostname|message')
foreach($phase in 'initialization','packaged_task','worker_identity','proof_prepare','fixture_certificate','alias_certify','static_proof_https','alias_guard','foreign_binding','cleanup','complete'){
 $record=Record;$record.phase=$phase;$safe=SafeTenantDomainsReport $record
 Check ($safe.active_case -ceq ('native_windows_tenant_'+$phase))
}
foreach($field in 'schema','state','case','phase','exception_type','source_basename','source_line'){
 foreach($bad in $null,$true,'PRIVATE_NEVER_PUBLISH',@('PRIVATE_NEVER_PUBLISH')){
  $record=Record;$record.$field=$bad
  Check ($null -eq (SafeTenantDomainsReport $record))
 }
}
foreach($line in -1,0,100000,1.5,'123'){$record=Record;$record.source_line=$line;Check ($null -eq (SafeTenantDomainsReport $record))}
foreach($value in 'true',1,@($true),$null){$record=Record;$record.cleanup_exact=$value;$safe=SafeTenantDomainsReport $record;Check (!$safe.ContainsKey('cleanup_exact'))}
$record=Record;$record.cleanup_exact=$false;Check ((SafeTenantDomainsReport $record).cleanup_exact -is [bool] -and !(SafeTenantDomainsReport $record).cleanup_exact)
Write-Output ('PASS '+$checks+' actual tenant-domain diagnostic phase/type/privacy controls; no PBX invoked')
