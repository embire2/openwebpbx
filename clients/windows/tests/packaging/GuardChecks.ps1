# SPDX-License-Identifier: AGPL-3.0-or-later
#Requires -Version 7.4
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$client=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent;$tool=Join-Path $client 'tools/Test-ClientPackage.ps1';$checks=0
function Check([bool]$Value){if(!$Value){throw ('Package guard '+($script:checks+1)+' failed.')};$script:checks++}
$errors=$null;$tokens=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($tool,[ref]$tokens,[ref]$errors);Check (!$errors)
$writers=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.TryStatementAst] -and $n.Body.Extent.Text -match '^\{\$file=\[IO.File\]::Open\(\$Report,'},$true));Check ($writers.Count-eq 1)
$root=Join-Path ([IO.Path]::GetTempPath()) ('phone-package-guards-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root)
try{
 $Report=Join-Path $root 'already-present.json';[IO.File]::WriteAllText($Report,'foreign-sentinel');$result=[ordered]@{state='failed'}
 $primary=[Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('original-primary'),'Original',[Management.Automation.ErrorCategory]::OperationStopped,$null);$failure=$primary
 . ([scriptblock]::Create($writers[0].Extent.Text));Check ([object]::ReferenceEquals($failure,$primary));Check ($primary.Exception.Data['receipt_write_failed']-eq $true);Check ([IO.File]::ReadAllText($Report)-ceq 'foreign-sentinel')
 $failure=$null;. ([scriptblock]::Create($writers[0].Extent.Text));Check ($null-ne $failure);Check (![object]::ReferenceEquals($failure,$primary));Check ([IO.File]::ReadAllText($Report)-ceq 'foreign-sentinel')
 $Report=Join-Path $root 'new.json';$failure=$primary;. ([scriptblock]::Create($writers[0].Extent.Text));Check ([object]::ReferenceEquals($failure,$primary));Check ((Get-Content $Report -Raw|ConvertFrom-Json).state-ceq 'failed')
 $main=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.TryStatementAst] -and $n.Body.Extent.Text.Contains('[void][IO.Directory]::CreateDirectory($root);$rootCreated=$true')},$true));Check ($main.Count-eq 1);Check ($main[0].Body.Extent.Text.Contains('Push-Location $client;try{if((& $dotnet --version)'));Check ($main[0].Finally.Extent.Text.Contains('$rootCreated'))
 foreach($name in @('Certificate.ps1','Interface.ps1')){
  $file=Join-Path $PSScriptRoot $name;$syntax=$null;$tok=$null;[void][Management.Automation.Language.Parser]::ParseFile($file,[ref]$tok,[ref]$syntax);Check (!$syntax)
  $info=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path);$info.UseShellExecute=$false;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.Environment['GITHUB_ACTIONS']='false'
  foreach($value in (@('-NoLogo','-NoProfile','-File',$file)+$(if($name-ceq 'Certificate.ps1'){@('-Mode','Create','-Nonce',('a'*32),'-Root',$root)}else{@('-Mode','Verify','-Nonce',('a'*32),'-Root',$root,'-ProcessId','1','-StartedUtcTicks','1','-Executable','C:\invalid\OpenWebPbx.Phone.App.exe')}))){[void]$info.ArgumentList.Add($value)}
  $p=[Diagnostics.Process]::Start($info);$stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync();try{if(!$p.WaitForExit(10000)){$p.Kill($true);throw 'Offhost guard child did not refuse promptly.'};Check ($p.ExitCode-ne 0);Check ($stdout.GetAwaiter().GetResult().Length-eq 0);Check ($stderr.GetAwaiter().GetResult().Length-gt 0);Check ([IO.File]::ReadAllText((Join-Path $root 'already-present.json'))-ceq 'foreign-sentinel')}finally{$p.Dispose()}
 }
}finally{[IO.Directory]::Delete($root,$true)}
"PASS $checks actual package source/primary-receipt/offhost guard controls; no Windows certificate/deployment execution"
$certificateFile=Join-Path $PSScriptRoot 'Certificate.ps1';$certificateAst=[Management.Automation.Language.Parser]::ParseFile($certificateFile,[ref]$tokens,[ref]$errors);Check (!$errors)
$guard=@($certificateAst.FindAll({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-ceq 'AssertOwnedKey'},$true));Check ($guard.Count-eq 1);. ([scriptblock]::Create($guard[0].Extent.Text))
function KeyValue([bool]$Machine=$false,[string]$Name='owned',[string]$Provider='Microsoft Software Key Storage Provider',[Security.Cryptography.CngExportPolicies]$Export=[Security.Cryptography.CngExportPolicies]::None){[pscustomobject]@{IsMachineKey=$Machine;KeyName=$Name;Provider=[pscustomobject]@{Provider=$Provider};ExportPolicy=$Export}}
AssertOwnedKey (KeyValue) 'owned';Check $true
foreach($key in @((KeyValue -Machine $true),(KeyValue -Name 'foreign'),(KeyValue -Provider 'Foreign KSP'),(KeyValue -Export AllowExport),(KeyValue -Export AllowPlaintextExport),(KeyValue -Export AllowArchiving),(KeyValue -Export AllowPlaintextArchiving),([pscustomobject]@{IsMachineKey='false';KeyName='owned';Provider=[pscustomobject]@{Provider='Microsoft Software Key Storage Provider'};ExportPolicy=[Security.Cryptography.CngExportPolicies]::None}),([pscustomobject]@{IsMachineKey=$false;KeyName='owned';Provider=[pscustomobject]@{Provider='Microsoft Software Key Storage Provider'};ExportPolicy=0}))){$refused=$false;try{AssertOwnedKey $key 'owned'}catch{$refused=$true};Check $refused}
"PASS $checks total actual package source/receipt/offhost/mock-CNG boundary controls; CNG keys/stores are explicit doubles"
. (Join-Path $PSScriptRoot 'HelperOwnership.ps1')
$package=[pscustomobject]@{data_parent='C:\Users\fixture\AppData\Local\Packages\Own.Dev_123\LocalState\OpenWebPBX Free Phone';family_name='Own.Dev_123';full_name='Own.Dev_1.0.0.0_x64__123'}
$exe=$package.data_parent+'\direct\updates\helper-'+('a'*32)+'\OpenWebPbx.Phone.Updater.exe';$expected='b'*64;$bundle='c'*64;$sid='S-1-5-21-123'
$journal=[pscustomobject]@{schema=1;producer='WindowsPhoneUpdaterOwnership';pid=[long]42;created_utc_ticks=[long]1234;executable=$exe;executable_sha256=$expected;installed_full_name=$package.full_name;family_name=$package.family_name;data_parent=$package.data_parent;package_sha256=$bundle;request_sha256=('d'*64);user_sid=$sid;parent_id=41;parent_started_utc_ticks=1200;parent_path='C:\Program Files\WindowsApps\Own.Dev_1.0.0.0_x64__123\OpenWebPbx.Phone.App.exe'}
$observed=[pscustomobject]@{pid=42;created_utc_ticks=1234;executable=$exe;executable_sha256=$expected};$parents=@([pscustomobject]@{pid=41;created_utc_ticks=1200;executable=$journal.parent_path})
AssertPackageHelperOwnership $observed $journal $package $expected $bundle $parents $sid;Check $true
foreach($field in @('pid','created_utc_ticks','executable_sha256','installed_full_name','family_name','data_parent','package_sha256','request_sha256','user_sid','parent_id','parent_started_utc_ticks','parent_path','executable')){$copy=$journal|ConvertTo-Json|ConvertFrom-Json;$copy.$field=if($field-in 'pid','created_utc_ticks','parent_id','parent_started_utc_ticks'){[long]999}else{'foreign'};$refused=$false;try{AssertPackageHelperOwnership $observed $copy $package $expected $bundle $parents $sid}catch{$refused=$true};Check $refused}
foreach($field in @('pid','created_utc_ticks','executable','executable_sha256')){$copy=$observed|ConvertTo-Json|ConvertFrom-Json;$copy.$field=if($field-in 'pid','created_utc_ticks'){[long]999}else{'foreign'};$refused=$false;try{AssertPackageHelperOwnership $copy $journal $package $expected $bundle $parents $sid}catch{$refused=$true};Check $refused}
$refused=$false;try{AssertPackageHelperOwnership $observed $journal $package $expected $bundle @($parents[0],$parents[0]) $sid}catch{$refused=$true};Check $refused
"PASS $checks total package source/receipt/offhost/mock-key/helper-ownership controls; no native key/process/install execution"
$installation=[IO.File]::ReadAllText((Join-Path $client 'src/OpenWebPbx.Phone.Windows/ClientInstallation.cs'))
Check ($installation.Contains('WorkingDirectory = Path.GetDirectoryName(executable)!'))
Check (!$installation.Contains('WorkingDirectory = AppContext.BaseDirectory'))
"PASS $checks total bounded package source/adaptor controls; native install and real key scope still pending"
$cleanupBlock=@($ast.FindAll({param($n)$n-is [Management.Automation.Language.TryStatementAst] -and $n.CatchClauses.Count-eq 1 -and $n.CatchClauses[0].Body.Extent.Text.Contains('$result.cached_helper_cleanup_error=')},$true));Check ($cleanupBlock.Count-eq 1)
$finalScan=@($cleanupBlock[0].Body.Statements|Where-Object {$_.Extent.Text.StartsWith('$remaining=@(')});Check ($finalScan.Count-eq 1)
$lastCheck=$cleanupBlock[0].Body.Statements[-1];Check ($lastCheck-is [Management.Automation.Language.TryStatementAst] -and $lastCheck.Body.Extent.Text.Contains('An owned cached helper remains'))
$finalCheck=[scriptblock]::Create($finalScan[0].Extent.Text+"`n"+$lastCheck.Extent.Text)
& {
 param($CheckSource)
 $cache='C:\owned\direct\updates';$script:finalProcess=$null
 function Get-Process{param($Name,$ErrorAction) @($script:finalProcess)}
 function FakeProcess([string]$Path,[bool]$Exited){$fake=[pscustomobject]@{HasExited=$Exited;MainModule=[pscustomobject]@{FileName=$Path};disposed=$false};$fake|Add-Member ScriptMethod Dispose {$this.disposed=$true};$fake}
 foreach($case in @([pscustomobject]@{path=($cache+'\helper-owned\OpenWebPbx.Phone.Updater.exe');exited=$false;refuse=$true},[pscustomobject]@{path='C:\foreign\OpenWebPbx.Phone.Updater.exe';exited=$false;refuse=$false},[pscustomobject]@{path=($cache+'\helper-owned\OpenWebPbx.Phone.Updater.exe');exited=$true;refuse=$false})){$script:finalProcess=FakeProcess $case.path $case.exited;$refused=$false;try{. $CheckSource}catch{$refused=$true};if($refused-ne $case.refuse -or !$script:finalProcess.disposed){throw 'The actual terminal helper guard missed a live helper or retained its observation handle.'}}
} $finalCheck
Check $true
$finallyText=$main[0].Finally.Extent.Text;Check ($finallyText.IndexOf('$result.process_cleanup_error=')-lt $finallyText.IndexOf('$result.cached_helper_cleanup_error='))
Check ($finallyText.Contains('$rootItem=Get-Item -LiteralPath $root -Force;if(!$rootItem.PSIsContainer -or ($rootItem.Attributes-band [IO.FileAttributes]::ReparsePoint))'))
"PASS $checks total bounded package controls; final helper process observations are explicit doubles"
