# SPDX-License-Identifier: AGPL-3.0-or-later
#Requires -Version 7.4
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Diagnostics.ps1')
$checks=0;function Check([bool]$Value){if(!$Value){throw ('Package diagnostic control '+($script:checks+1)+' failed.')};$script:checks++}
$prefix='OPENWEBPBX_PACKAGE_CERTIFICATE_OBSERVATION '
$original=[Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('private-message-not-exported'),'Original',[Management.Automation.ErrorCategory]::InvalidOperation,$null)
$row=GetPackageCertificateFailure $original 'Create' 'native_module';Check ($row.reason-ceq 'external_exception');Check ($row.error_type-ceq 'InvalidOperationException');Check ($original.Exception.Message-ceq 'private-message-not-exported')
$serialized=$row|ConvertTo-Json -Compress;Check (!$serialized.Contains('private-message'));$valid=ReadPackageCertificateFailure ($prefix+$serialized) 'Create';Check ($valid.hresult-eq $original.Exception.HResult)
foreach($mutation in @(@{schema='1'},@{schema=2},@{producer='foreign'},@{mode='Remove'},@{stage='private/path'},@{source='C:\private'},@{line='12'},@{line=-1},@{error_type='C:\private'},@{hresult='1'},@{hresult=2147483648},@{inner_type='IOException';inner_hresult=$null},@{inner_type='IOException';inner_hresult='1'},@{reason='private-message'},@{unexpected='secret'})){
 $changed=$serialized|ConvertFrom-Json -AsHashtable;foreach($key in $mutation.Keys){$changed[$key]=$mutation[$key]};$refused=$false;try{ReadPackageCertificateFailure ($prefix+($changed|ConvertTo-Json -Compress)) 'Create'|Out-Null}catch{$refused=$true};Check $refused
}
foreach($inputText in @('',($prefix+$serialized+"`n"+$prefix+$serialized),($prefix+('x'*4097)),($prefix+'not-json'),($prefix+$serialized.Replace('"schema":1,','"schema":1,"schema":1,')))){$refused=$false;try{ReadPackageCertificateFailure $inputText 'Create'|Out-Null}catch{$refused=$true};Check $refused}
foreach($exit in @(-2147483648,-1,1,17,2147483647)){$observed=GetPackageChildFailure 'publish_app' $exit;Check ($observed.exit_code-eq $exit -and $observed.operation-ceq 'publish_app')}
foreach($inputValue in @(@{op='foreign';code=17},@{op='publish_app';code=0})){$refused=$false;try{GetPackageChildFailure $inputValue.op $inputValue.code|Out-Null}catch{$refused=$true};Check $refused}
$client=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent;$tool=Join-Path $client 'tools/Test-ClientPackage.ps1';$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($tool,[ref]$tokens,[ref]$errors);Check (!$errors)
$run=@($ast.FindAll({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-ceq 'Run'},$true));Check ($run.Count-eq 1);. ([scriptblock]::Create($run[0].Extent.Text))
$root=Join-Path ([IO.Path]::GetTempPath()) ('phone-package-diagnostic-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root)
$dotnet=(Get-Process -Id $PID).Path # Explicit cwd adapter: execute real PowerShell child in the client directory.
$oldActions=$env:GITHUB_ACTIONS
try{
 $env:GITHUB_ACTIONS='false'
 foreach($mode in @('Create','Remove')){
  $result=[ordered]@{};$caught=$false
  try{Run $dotnet @('-NoLogo','-NoProfile','-File',(Join-Path $PSScriptRoot 'Certificate.ps1'),'-Mode',$mode,'-Nonce',('a'*32),'-Root',$root) 15 ('certificate_'+$mode.ToLowerInvariant())|Out-Null}catch{$caught=$_.Exception.Message-ceq 'An actual package child refused.'}
  Check $caught;Check ($result.child_failures.Count-eq 1 -and $result.child_failures[0].exit_code-eq 1);$detail=$result['certificate_'+$mode.ToLowerInvariant()+'_failure'];Check ($detail.mode-ceq $mode -and $detail.stage-ceq 'entry' -and $detail.reason-ceq 'host_guard' -and $detail.source-ceq 'Certificate.ps1' -and $detail.line-gt 0);Check (@(Get-ChildItem $root -Force).Count-eq 0)
 }
 $child=Join-Path $root 'actual-child.ps1';[IO.File]::WriteAllText($child,"exit 17`n");$result=[ordered]@{};$caught=$false
 try{Run $dotnet @('-NoProfile','-File',$child) 15 'publish_app'|Out-Null}catch{$caught=$_.Exception.Message-ceq 'An actual package child refused.'};Check $caught;Check ($result.child_failures[0].exit_code-eq 17 -and $result.child_failures[0].operation-ceq 'publish_app')
 [IO.File]::WriteAllText($child,"[Console]::Error.WriteLine('OPENWEBPBX_PACKAGE_CERTIFICATE_OBSERVATION invalid');exit 17`n");$result=[ordered]@{};$caught=$false
 try{Run $dotnet @('-NoProfile','-File',$child) 15 'certificate_create'|Out-Null}catch{$caught=$_.Exception.Message-ceq 'An actual package child refused.'};Check $caught;Check ($result.child_failures[0].exit_code-eq 17 -and $result.certificate_create_observation_refused-eq $true)
 [IO.File]::WriteAllText($child,"[Console]::Write('ordinary-result');exit 0`n");$result=[ordered]@{};$value=Run $dotnet @('-NoProfile','-File',$child) 15 'publish_app';Check ($value-ceq 'ordinary-result' -and !$result.Contains('child_failures'))
}finally{$env:GITHUB_ACTIONS=$oldActions;[IO.Directory]::Delete($root,$true)}
"PASS $checks actual producer/strict-consumer/off-host-child/exit controls; no Windows certificate or package mutation"
