# SPDX-License-Identifier: AGPL-3.0-or-later
#Requires -Version 7.4
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'RuntimeReceipt.ps1')
$checks=0;function Check([bool]$Value){if(!$Value){throw ('Package runtime control '+($script:checks+1)+' failed.')};$script:checks++}
$valid=[ordered]@{schema=1;producer='PackageRuntimeProbe';mode='Ambient';stage='get_acl';getacl_invoked=$true;getacl_succeeded=$false;acl_matches_native_read=$false;explicit_stock_import=$false;command_observed=$false;certificate_mutation=$false;package_mutation=$false;module_paths=[ordered]@{count=4;parent_shell_count=1;stock_count=1};failure=@([ordered]@{type='RuntimeException';hresult=-2146233087;category='NotSpecified';id='other'})}
$json=$valid|ConvertTo-Json -Depth 8 -Compress;$value=ReadPackageRuntimeReceipt $json 'Ambient' 1;Check (!$value.getacl_succeeded -and $value.failure.Count-eq 1)
foreach($mutation in @(@{schema='1'},@{schema=2},@{producer='foreign'},@{mode='Stock'},@{stage='private'},@{getacl_succeeded=1},@{getacl_succeeded=$true;getacl_invoked=$false},@{acl_matches_native_read=$true},@{explicit_stock_import=$true},@{certificate_mutation=$true},@{package_mutation=$true},@{command_observed=$true},@{command_count=33},@{unknown='secret'},@{module_paths=@{count=1;parent_shell_count=2;stock_count=1}},@{failure=@(@{type='RuntimeException';hresult='1'})},@{failure=@(@{type='RuntimeException';hresult=1;message='secret'})},@{failure=@(@{type='RuntimeException';hresult=1;category='NotSpecified';id='private'})},@{failure=@(@{type='RuntimeException';hresult=1;category='private';id='other'})},@{failure=@(@{type='RuntimeException';hresult=1;id='other'})})){
 $m=$json|ConvertFrom-Json -AsHashtable;foreach($key in $mutation.Keys){$m[$key]=$mutation[$key]};$refused=$false;try{ReadPackageRuntimeReceipt ($m|ConvertTo-Json -Depth 8 -Compress) 'Ambient' 1|Out-Null}catch{$refused=$true};Check $refused
}
foreach($bad in @('not-json',$json.Replace('"schema":1,','"schema":1,"schema":1,'),$json.Replace('"id":"other"','"id":"other","id":"other"'))){$refused=$false;try{ReadPackageRuntimeReceipt $bad 'Ambient' 1|Out-Null}catch{$refused=$true};Check $refused}
$success=$json|ConvertFrom-Json -AsHashtable;$success.getacl_succeeded=$true;$success.acl_matches_native_read=$true;$success.Remove('failure');$value=ReadPackageRuntimeReceipt ($success|ConvertTo-Json -Depth 8 -Compress) 'Ambient' 0;Check $value.getacl_succeeded
$refused=$false;try{ReadPackageRuntimeReceipt $json 'Ambient' 0|Out-Null}catch{$refused=$true};Check $refused
$probe=Join-Path $PSScriptRoot 'RuntimeProbe.ps1';$parent=Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'tools/Test-PackageRuntime.ps1';$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($probe,[ref]$tokens,[ref]$errors);Check (!$errors)
$errorFunction=@($ast.FindAll({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-ceq 'RuntimeError'},$true));Check ($errorFunction.Count-eq 1);. ([scriptblock]::Create($errorFunction[0].Extent.Text))
try{throw [InvalidOperationException]::new('private-path-and-message')}catch{$rows=@(RuntimeError $_);$text=$rows|ConvertTo-Json -Depth 5 -Compress;Check (!$text.Contains('private-path'));Check ($rows[0].type-ceq 'InvalidOperationException')}
[void][Management.Automation.Language.Parser]::ParseFile($parent,[ref]$tokens,[ref]$errors);Check (!$errors)
$root=Join-Path ([IO.Path]::GetTempPath()) ('phone-runtime-guard-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root)
try{
 foreach($file in @($probe,$parent)){
  $info=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path);$info.UseShellExecute=$false;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.Environment['GITHUB_ACTIONS']='false'
  $args=@('-NoProfile','-File',$file);if($file-ceq $probe){$args+=@('-Mode','Ambient','-Nonce',('a'*32),'-Root',$root,'-ParentShellRoot',$root)}else{$args+=@('-SourceCommit',('b'*40),'-Report',(Join-Path $root 'report.json'))};foreach($arg in $args){[void]$info.ArgumentList.Add($arg)}
  $p=[Diagnostics.Process]::Start($info);$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync();try{if(!$p.WaitForExit(10000)){$p.Kill($true);throw 'Offhost child deadline'};Check ($p.ExitCode-ne 0);Check ($out.GetAwaiter().GetResult().Length-eq 0 -and $err.GetAwaiter().GetResult().Length-gt 0);Check (@(Get-ChildItem $root -Force).Count-eq 0)}finally{$p.Dispose()}
 }
}finally{[IO.Directory]::Delete($root,$true)}
"PASS $checks actual runtime observer/strict-receipt/offhost controls; native cmdlet/module behavior is untested"

. (Join-Path $PSScriptRoot 'NativeSecurity.ps1')
$proof=[ordered]@{type_is_cmdlet=$true;module_name_matches=$true;module_equals_stock_home=$true;module_equals_assembly_directory=$false;assembly_under_windows=$true;assembly_name_matches=$true;assembly_version_matches=$true;assembly_token_matches=$true;implementing_type_matches=$true}
AssertPackageNativeSecurityProvenance $proof;Check $true
$proof.module_equals_stock_home=$false;$proof.module_equals_assembly_directory=$true;AssertPackageNativeSecurityProvenance $proof;Check $true
foreach($name in @('type_is_cmdlet','module_name_matches','assembly_under_windows','assembly_name_matches','assembly_version_matches','assembly_token_matches','implementing_type_matches','module_equals_assembly_directory')){$copy=[ordered]@{};foreach($key in $proof.Keys){$copy[$key]=$proof[$key]};$copy[$name]=$false;$refused=$false;try{AssertPackageNativeSecurityProvenance $copy}catch{$refused=$true};Check $refused}
foreach($value in @('true',1,$null)){$copy=[ordered]@{};foreach($key in $proof.Keys){$copy[$key]=$proof[$key]};$copy.type_is_cmdlet=$value;$refused=$false;try{AssertPackageNativeSecurityProvenance $copy}catch{$refused=$true};Check $refused}
"PASS $checks total runtime observer/receipt/native-identity adapter controls; actual stock ACL read still pending"

$savedHome=$HOME;$actualCommand=Get-Command Get-Item -CommandType Cmdlet -ErrorAction Stop
$actualProvenance=GetPackageNativeSecurityProvenance $actualCommand
Check ($HOME-ceq $savedHome)
Check ($actualProvenance.type_is_cmdlet-is [bool] -and $actualProvenance.type_is_cmdlet -and $actualProvenance.assembly_version_major-is [int])
Check (!$actualProvenance.module_name_matches -and !$actualProvenance.implementing_type_matches)
"PASS $checks total runtime observer/receipt/actual-cmdlet-provenance controls; this foreign cmdlet is not native Security acceptance"
