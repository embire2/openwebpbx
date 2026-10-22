# Actual extracted mode and routing guards; no PBX/runtime operation.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$checks=0
function Check([bool]$Value){if(!$Value){throw ('Native factory diagnostics guard failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-suite.ps1'),[ref]$tokens,[ref]$errors);Check (!$errors.Count)
foreach($name in 'AssertFactoryNativeDiagnosticsMode','InvokeSuitePhoneHealthQualification'){$nodes=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true));Check ($nodes.Count -eq 1);Invoke-Expression $nodes[0].Extent.Text}
foreach($skip in $false,$true){foreach($native in $false,$true){foreach($replay in '', '123'){foreach($package in '', 'owned-package'){
 $failed=$false;try{AssertFactoryNativeDiagnosticsMode $skip $native $replay $package}catch{$failed=$true}
 Check ($failed -eq ($skip -and (!$native -or $replay -ne '' -or $package -ne '')))
}}}}
$calls=0
function PhoneHealthAcceptanceHook([DateTime]$StartedAt){$script:calls++;Check ($StartedAt.Kind -eq 'Utc');throw 'normal-mandatory-health-fixture'}
$work=Join-Path ([IO.Path]::GetTempPath()) ('openweb-factory-guards-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($work)
function ResetFixture {
 $script:factoryDiagnosticsSourceValidated=$true;$script:NativeDiagnosticsOnly=$true;$script:ReplaySuiteRunId='';$script:calls=0
 $script:facts=[ordered]@{gates=[ordered]@{fresh='passed';web_readiness='passed';phone_health='unqualified'};release_eligible=$true;owner_transaction_eligible=$true}
}
try{
 ResetFixture;InvokeSuitePhoneHealthQualification $true;Check ($calls -eq 0);Check ($facts.native_factory_phone_health_skipped -is [bool] -and $facts.native_factory_phone_health_skipped);Check ($facts.native_factory_fresh_package -is [bool] -and $facts.native_factory_fresh_package);Check ($facts.gates.phone_health -ceq 'unqualified');Check (!$facts.release_eligible -and !$facts.owner_transaction_eligible)
 foreach($case in 'validation','native','replay','fresh','web','failure','report'){
  ResetFixture
  switch($case){validation{$factoryDiagnosticsSourceValidated=$false};native{$NativeDiagnosticsOnly=$false};replay{$ReplaySuiteRunId='123'};fresh{$facts.gates.fresh='pending'};web{$facts.gates.web_readiness='failed'};failure{$facts.phone_health_failure=@{diagnostic_recovery_exact=$true}};report{[IO.File]::WriteAllText((Join-Path $work 'phone-health-native.json'),'{}')}}
  $failed=$false;try{InvokeSuitePhoneHealthQualification $true}catch{$failed=$true};Check $failed;Check ($calls -eq 0);Check (!$facts.Contains('native_factory_phone_health_skipped'))
  if(Test-Path -LiteralPath (Join-Path $work 'phone-health-native.json')){Remove-Item -LiteralPath (Join-Path $work 'phone-health-native.json')}
 }
 ResetFixture;$failed=$false;try{InvokeSuitePhoneHealthQualification $false}catch{$failed=$_.Exception.Message -ceq 'normal-mandatory-health-fixture'};Check $failed;Check ($calls -eq 1);Check (!$facts.Contains('native_factory_phone_health_skipped'))
 $route=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'InvokeSuitePhoneHealthQualification'},$true));Check ($route.Count -eq 1);Check ($route[0].Extent.Text -ceq 'InvokeSuitePhoneHealthQualification $SkipPhoneHealthForNativeDiagnostics')
 $source=[IO.File]::ReadAllText((Join-Path $SourceRoot 'tests/windows-suite.ps1'));Check ($source.Contains("`$facts.mode='native_factory_diagnostics_only'"));Check ($source.Contains("`$facts.release_eligible=`$false;`$facts.owner_transaction_eligible=`$false"))
 $native=[IO.File]::ReadAllText((Join-Path $SourceRoot 'tests/windows-native-acceptance.ps1'));Check ($native.Contains("`$result.factory_empty -isnot [bool]"));Check ($native.Contains('native_factory_empty_before_fixture=$true'))
 $workflow=[IO.File]::ReadAllText((Join-Path $SourceRoot '.github/workflows/windows-suite.yml'));Check ($workflow.Contains('skip_phone_health_for_native_diagnostics:'));Check ($workflow.Contains('SKIP_PHONE_HEALTH_FOR_NATIVE_DIAGNOSTICS:'));Check ($workflow.Contains('producerOptions.SkipPhoneHealthForNativeDiagnostics=$true'))
}finally{Remove-Item -LiteralPath $work -Recurse -Force}
"PASS $checks actual AST fresh-only/normal-mandatory/routing/facts controls; no PBX invoked"
