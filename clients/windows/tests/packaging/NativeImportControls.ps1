# SPDX-License-Identifier: AGPL-3.0-or-later
#Requires -Version 7.4
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'NativeImports.ps1')
$checks=0;function Check([bool]$Value){if(!$Value){throw ('Import audit control '+($script:checks+1)+' failed.')};$script:checks++}
$fixture=@'
Dump of file owned.dll

File Type: DLL

  Section contains the following imports:

    KERNEL32.dll
                1000 Import Address Table
                2000 Import Name Table
                   0 time date stamp
                   0 Index of first forwarder reference
                    1 FunctionName

  Section contains the following delay load imports:

    VCRUNTIME140.dll
                 1 Characteristics
              3000 Address of HMODULE
              4000 Import Address Table
              5000 Import Name Table
                   2 OtherFunction

  Summary
        1000 .text
'@
$actual=ReadPackageNativeImports $fixture;Check ($actual.normal.Count-eq 1 -and $actual.normal[0]-ceq 'kernel32.dll' -and $actual.delay.Count-eq 1 -and $actual.delay[0]-ceq 'vcruntime140.dll' -and $actual.descriptor_count-eq 2)
foreach($bad in @($fixture.Replace('  Summary','  Unrecognised'),$fixture.Replace('File Type: DLL','File Type: UNKNOWN'),$fixture.Replace('    KERNEL32.dll','    ..\foreign.dll'),$fixture.Replace('    KERNEL32.dll','    C:\secret\foreign.dll'),$fixture.Replace('    KERNEL32.dll','    <Invalid RVA>'),$fixture.Replace('  Section contains the following imports:','  Section contains unknown imports:'),($fixture+"`n    extra.dll"),($fixture+"`nwarning LNK1234"),($fixture+"`0"),('x'*(4MB+1)))){$refused=$false;try{ReadPackageNativeImports $bad|Out-Null}catch{$refused=$true};Check $refused}
foreach($prefix in @('  ','      ',"`t",'')){$refused=$false;try{ReadPackageNativeImports ($fixture.Replace('    KERNEL32.dll',("    KERNEL32.dll`n"+$prefix+'omitted.dll')))|Out-Null}catch{$refused=$true};Check $refused}
$empty=ReadPackageNativeImports "File Type: DLL`n  Summary`n        1000 .text`n";Check ($empty.normal.Count-eq 0 -and $empty.delay.Count-eq 0)
foreach($case in @(@('kernel32.dll',$false,$true,'host_system32_only'),@('api-ms-win-core-libraryloader-l1-2-0.dll',$false,$false,'api_set_contract_name'),@('vcruntime140.dll',$false,$true,'external_vc_runtime'),@('vcruntime140_1.dll',$false,$false,'external_vc_runtime'),@('msvcp140_atomic_wait.dll',$false,$true,'external_vc_runtime'),@('concrt140.dll',$false,$false,'external_vc_runtime'),@('vcruntime140d.dll',$true,$true,'debug_crt_not_redistributable'),@('ucrtbased.dll',$true,$true,'debug_crt_not_redistributable'),@('ucrtbase.dll',$false,$true,'host_system32_only'),@('msvcrt.dll',$false,$true,'host_system32_only'),@('liblinphone.dll',$true,$false,'bundled_candidate'),@('private.dll',$false,$false,'unresolved'))){$observed=GetPackageImportKind $case[0] $case[1] $case[2];Check ($observed.kind-ceq $case[3])}
foreach($name in @('C:\private.dll','../private.dll','private.dll/path','private`n.dll')){$refused=$false;try{GetPackageImportKind $name $false $false|Out-Null}catch{$refused=$true};Check $refused}
"PASS $checks import parser/classification controls using explicit DUMPBIN-output fixtures; actual native import inventory remains pending"
$client=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent;$tool=Join-Path $client 'tools/Test-ClientNativeImports.ps1';$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($tool,[ref]$tokens,[ref]$errors);Check (!$errors)
$reserved=@($ast.FindAll({param($node)$node-is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text-imatch '^\$(home|host|pid|input|args|PSHOME|CODEX_HOME)$'},$true));Check ($reserved.Count-eq 0)
$root=Join-Path ([IO.Path]::GetTempPath()) ('phone-import-controls-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root)
try{
 $info=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path);$info.UseShellExecute=$false;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.Environment['GITHUB_ACTIONS']='false'
 foreach($arg in @('-NoProfile','-File',$tool,'-AppRoot',$root,'-DumpBin',(Join-Path $root 'dumpbin.exe'),'-SourceCommit',('a'*40),'-Report',(Join-Path $root 'report.json'))){[void]$info.ArgumentList.Add($arg)}
 $child=[Diagnostics.Process]::Start($info);$stdout=$child.StandardOutput.ReadToEndAsync();$stderr=$child.StandardError.ReadToEndAsync();try{if(!$child.WaitForExit(10000)){$child.Kill($true);throw 'Offhost import inventory deadline'};Check ($child.ExitCode-ne 0);Check ($stdout.GetAwaiter().GetResult().Length-eq 0 -and $stderr.GetAwaiter().GetResult().Length-gt 0);Check (@(Get-ChildItem $root -Force).Count-eq 0)}finally{$child.Dispose()}
 $writers=@($ast.FindAll({param($node)$node-is [Management.Automation.Language.TryStatementAst] -and $node.Body.Extent.Text.StartsWith('{$bytes=[Text.Encoding]::UTF8.GetBytes(($result|ConvertTo-Json')},$true));Check ($writers.Count-eq 1)
 $Report=Join-Path $root 'existing.json';[IO.File]::WriteAllText($Report,'foreign-sentinel');$result=[ordered]@{state='failed'};$original=[Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('primary-preserved'),'Primary',[Management.Automation.ErrorCategory]::InvalidOperation,$null);$failure=$original
 . ([scriptblock]::Create($writers[0].Extent.Text));Check ([object]::ReferenceEquals($failure,$original));Check ($original.Exception.Data['receipt_write_failed']-eq $true);Check ([IO.File]::ReadAllText($Report)-ceq 'foreign-sentinel')
}finally{[IO.Directory]::Delete($root,$true)}
"PASS $checks total import parser/classification/offhost/primary-preservation controls; no actual Windows import or clean-machine pass"

Add-Type -Path (Join-Path $PSScriptRoot 'NativeImportProcess.cs')
$readerRoot=Join-Path ([IO.Path]::GetTempPath()) ('phone-reader-controls-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($readerRoot)
try{
 $executable=(Get-Process -Id $PID).Path;$child=Join-Path $readerRoot 'child.ps1';$pidFile=Join-Path $readerRoot 'child.pid';$prefix="[IO.File]::WriteAllText('"+$pidFile.Replace("'","''")+"',[string]`$PID);"
 foreach($exitCode in @(0,17)){
  [IO.File]::WriteAllText($child,($prefix+"[Console]::Write('actual-output');exit "+$exitCode));$observed=[OpenWebPbx.PackageAudit.NativeImportProcess]::Run($executable,@('-NoProfile','-File',$child),$readerRoot,5);Check ($observed.ExitCode-eq $exitCode -and $observed.Stdout-ceq 'actual-output' -and $observed.Stderr-ceq '')
 }
 foreach($case in @(@{script="for(`$i=0;`$i-lt 160;`$i++){[Console]::Out.Write(('x'*65536))}";seconds=5;type='InvalidDataException'},@{script="for(`$i=0;`$i-lt 8;`$i++){[Console]::Error.Write(('x'*65536))}";seconds=5;type='InvalidDataException'},@{script='Start-Sleep -Seconds 10';seconds=3;type='OperationCanceledException'})){
  [IO.File]::Delete($pidFile);[IO.File]::WriteAllText($child,($prefix+$case.script));$caught=$null;try{[OpenWebPbx.PackageAudit.NativeImportProcess]::Run($executable,@('-NoProfile','-File',$child),$readerRoot,$case.seconds)|Out-Null}catch{$caught=$_.Exception.InnerException};Check ($caught -and $caught.GetType().Name-ceq $case.type)
  $childId=[int][IO.File]::ReadAllText($pidFile);$stillRunning=$false;try{$process=[Diagnostics.Process]::GetProcessById($childId);try{$stillRunning=!$process.HasExited}finally{$process.Dispose()}}catch [ArgumentException]{};Check (!$stillRunning)
 }
 $primary=[InvalidOperationException]::new('original-private');$caught=$null;try{[OpenWebPbx.PackageAudit.NativeImportProcess]::Complete($primary,[Action]{throw [IO.IOException]::new('cleanup-private')})}catch{$caught=$_.Exception.InnerException};Check ([object]::ReferenceEquals($caught,$primary));Check ($primary.Data.Contains('reader_cleanup_error_type') -and $primary.Data['reader_cleanup_hresult']-is [int]);Check (!($primary.Data['reader_cleanup_error_type'].Contains('private')))
 $caught=$false;try{[OpenWebPbx.PackageAudit.NativeImportProcess]::Complete($null,[Action]{throw [IO.IOException]::new('cleanup-private')})}catch{$caught=$true};Check $caught
}finally{[IO.Directory]::Delete($readerRoot,$true)}
"PASS $checks total actual bounded-child-output/exit/timeout/cleanup-preservation controls; Windows DUMPBIN, native imports and clean-machine behavior remain pending"

$packageTool=Join-Path $client 'tools/Test-ClientPackage.ps1';$packageAst=[Management.Automation.Language.Parser]::ParseFile($packageTool,[ref]$tokens,[ref]$errors);Check (!$errors)
$baseline=@($packageAst.FindAll({param($node)$node-is [Management.Automation.Language.AssignmentStatementAst] -and $node.Extent.Text-ceq '$before=Snapshot'},$true));$hook=@($packageAst.FindAll({param($node)$node-is [Management.Automation.Language.CommandAst] -and $node.Extent.Text.Contains("'Test-ClientNativeImports.ps1') -AppRoot")},$true));$certCreate=@($packageAst.FindAll({param($node)$node-is [Management.Automation.Language.CommandAst] -and $node.Extent.Text-ceq "Cert 'Create'"},$true));Check ($baseline.Count-eq 1 -and $hook.Count-eq 1 -and $certCreate.Count-eq 1);Check ($baseline[0].Extent.StartOffset-lt $hook[0].Extent.StartOffset -and $hook[0].Extent.EndOffset-lt $certCreate[0].Extent.StartOffset)
$scope=@($packageAst.FindAll({param($node)$node-is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith('if($importView.schema-isnot [long]')},$true));$flags=@($packageAst.FindAll({param($node)$node-is [Management.Automation.Language.ForEachStatementAst] -and $node.Extent.Text.Contains('$importView.$flag-isnot [bool]')},$true));Check ($scope.Count-eq 1 -and $flags.Count-eq 2)
& {
 param($Guard)
 $SourceCommit='a'*40;$valid=[ordered]@{schema=[long]1;producer='Test-ClientNativeImports.ps1';source_commit=$SourceCommit;state='observed_unqualified';payload_kind='development_package';development_managed_binary=$true;actual_native_windows=$true;read_only_import_inventory=$true;production_binary_tested=$false;clean_machine_qualified=$false;loader_tested=$false;dynamic_loads_covered=$false;store_accepted=$false};$importView=[pscustomobject]$valid;. $Guard;Check $true
 foreach($field in @('schema','producer','source_commit','state','payload_kind','development_managed_binary','actual_native_windows','read_only_import_inventory','production_binary_tested','clean_machine_qualified','loader_tested','dynamic_loads_covered','store_accepted')){$copy=$valid|ConvertTo-Json|ConvertFrom-Json;$copy.$field=if($field-ceq 'schema'){'1'}elseif($copy.$field-is [bool]){!$copy.$field}else{'foreign'};$importView=$copy;$refused=$false;try{. $Guard}catch{$refused=$true};Check $refused}
} ([scriptblock]::Create($scope[0].Extent.Text+"`n"+($flags.Extent.Text-join "`n")))
"PASS $checks total audit/hook/actual-scope-refusal controls; baseline ordering is actual source, Windows imports and package behavior are unqualified"
