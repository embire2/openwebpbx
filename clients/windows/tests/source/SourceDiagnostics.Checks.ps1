# SPDX-License-Identifier: AGPL-3.0-or-later
# Actual helper/outcome controls only. The SDK collection body never executes.
#Requires -Version 7.4
param([string]$Collector=(Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'tools/Collect-CorrespondingSource.ps1'))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Collector,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Actual collector source must parse.'}
foreach($name in 'AssertSourceRelative','AssertSourceUrl','CollectSourceRepo','AssertSourceHostedOutput','WriteSourceJson','NewSourceDiagnosticContext','SourceDiagnosticReason','WriteSourceDiagnostic'){
 $f=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));if($f.Count -ne 1){throw 'One actual diagnostic function is required.'};. ([scriptblock]::Create($f[0].Extent.Text))
}
$checks=0
function Check([bool]$Value,[string]$Label){if(!$Value){throw ('Source diagnostic control failed: '+$Label)};$script:checks++}
function Refuse([scriptblock]$Action,[string]$Label){$bad=$false;try{$null=& $Action}catch{$bad=$true};Check $bad $Label}
$main=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.TryStatementAst] -and $n.Body.Extent.Text.Contains('$lock=Get-Content -LiteralPath $SourceLock')},$true))
Check ($main.Count -eq 1 -and $main[0].CatchClauses.Count -eq 1 -and $null -ne $main[0].Finally) 'one actual top-level preservation scope'
$catch=$main[0].CatchClauses[0].Body.Extent.Text;$finally=$main[0].Finally.Extent.Text
$root=Join-Path ([IO.Path]::GetTempPath()) ('phone-source-diagnostics-'+[Guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Path $root
$temp=Split-Path $root -Parent;$leaf=Join-Path $root 'collector.json'
$allRepos=[Collections.Generic.List[object]]::new();$allFiles=[Collections.Generic.List[object]]::new();$totalBytes=0L
$fields=@('schema','producer','state','stage','operation','source_kind','exception_type','source_basename','source_line','sdk_repository_count','exported_file_count','exported_source_bytes','repository_depth','git_exit_code','refusal_reason','binary_source_mapping_verified','store_accepted')
try{
 $context=NewSourceDiagnosticContext $leaf $temp
 Check ($context.path -ceq $leaf -and $context.stage -ceq 'bootstrap' -and $context.operation -ceq 'read_lock') 'fresh exact diagnostic context'
 Refuse {NewSourceDiagnosticContext (Join-Path $root 'wrong.json') $temp} 'foreign leaf refused'
 Refuse {NewSourceDiagnosticContext (Join-Path (Join-Path $temp 'wrong-parent') 'collector.json') $temp} 'foreign nonce directory refused'
 [IO.File]::WriteAllText((Join-Path $root 'foreign'),'owned fixture marker');Refuse {NewSourceDiagnosticContext $leaf $temp} 'nonempty caller directory refused';Remove-Item (Join-Path $root 'foreign')
 if(!$IsWindows){$link=Join-Path $root 'link';$null=New-Item -ItemType SymbolicLink -Path $link -Target $temp;Refuse {AssertSourceHostedOutput (Join-Path $link 'collector.json') $temp} 'reparse ancestry refused';Remove-Item -LiteralPath $link}
 $allRepos.Add(@{fixture='one'});$allFiles.Add(@{fixture='one'});$totalBytes=3L
 $sourceDiagnostic=$context;$sourceDiagnostic.stage='sdk_graph';$sourceDiagnostic.operation='git_fetch_https';$sourceDiagnostic.source_kind='sdk_submodule';$sourceDiagnostic.repository_depth=1;$sourceDiagnostic.git_exit_code=128
 $sourcePrimaryFailure=$null;$observed=$null
 $scope=[scriptblock]::Create("try { throw 'A pinned source Git operation failed; no archive is qualified.' } catch "+$catch+" finally "+$finally)
 try{. $scope}catch{$observed=$_}
 Check ($null -ne $observed -and $observed.Exception.Message -ceq 'A pinned source Git operation failed; no archive is qualified.') 'original actual exception survives observation'
 $raw=[IO.File]::ReadAllText($leaf);$report=$raw|ConvertFrom-Json
 Check (@($report.PSObject.Properties.Name).Count -eq 17 -and @(Compare-Object @($report.PSObject.Properties.Name|Sort-Object) @($fields|Sort-Object) -CaseSensitive).Count -eq 0) 'exact17 closed fields'
 Check ($report.state -ceq 'failed' -and $report.refusal_reason -ceq 'git_exit_nonzero' -and $report.git_exit_code -eq 128) 'actual closed Git refusal captured'
 Check ($report.sdk_repository_count -eq 1 -and $report.exported_file_count -eq 1 -and $report.exported_source_bytes -eq 3) 'one-item collection counters are counts, not dictionary property counts'
 Check ($report.source_basename -ceq 'external_component' -and $report.source_line -gt 0 -and $raw.Length -lt 4096) 'original bounded fixture source/type shape'
 Check (!$report.binary_source_mapping_verified -and !$report.store_accepted -and $raw -notmatch 'https://|/tmp/|\\Users\\|pinned source Git operation failed') 'no URLs/paths/raw messages or approval claims'
 Refuse {WriteSourceDiagnostic $sourceDiagnostic $observed} 'existing leaf cannot be overwritten';Remove-Item -LiteralPath $leaf
 # Preserve the actual source catch/finally while replacing only collection with an inert failing operation.
 $sourcePrimaryFailure=$null;$sourceDiagnostic=NewSourceDiagnosticContext $leaf $temp
 $original=[InvalidOperationException]::new('PRIVATE_FIXTURE_MESSAGE_MUST_NOT_EXPORT');$seen=$null
 $scope=[scriptblock]::Create("try { throw `$original } catch "+$catch+" finally "+$finally)
 try{. $scope}catch{$seen=$_}
 $report=Get-Content $leaf -Raw|ConvertFrom-Json
 Check ([object]::ReferenceEquals($seen.Exception,$original) -and $report.exception_type -ceq 'System.InvalidOperationException' -and $report.refusal_reason -ceq 'unknown') 'original exception object and unknown refusal reason preserved'
 Check ([IO.File]::ReadAllText($leaf) -notmatch 'PRIVATE_FIXTURE|FIXTURE_MESSAGE') 'unknown message never exported';Remove-Item $leaf
 $sourcePrimaryFailure=$null;$sourceDiagnostic=NewSourceDiagnosticContext $leaf $temp
 $scope=[scriptblock]::Create("try { [IO.File]::WriteAllText(`$leaf,'collision'); throw `$original } catch "+$catch+" finally "+$finally)
 $seen=$null;try{. $scope}catch{$seen=$_}
 Check ([object]::ReferenceEquals($seen.Exception,$original) -and [IO.File]::ReadAllText($leaf) -ceq 'collision') 'diagnostic write failure cannot replace first actual exception or overwrite leaf';Remove-Item $leaf
 $sourcePrimaryFailure=$null;$sourceDiagnostic=NewSourceDiagnosticContext $leaf $temp
 $scope=[scriptblock]::Create("try { [IO.File]::WriteAllText(`$leaf,'collision') } catch "+$catch+" finally "+$finally)
 Refuse {. $scope} 'diagnostic publication failure without an earlier error refuses success';Remove-Item $leaf
 $sourcePrimaryFailure=$null;$sourceDiagnostic=NewSourceDiagnosticContext $leaf $temp;$sourceDiagnostic.stage='complete';$sourceDiagnostic.operation='complete';$sourceDiagnostic.source_kind='candidate_packet';$sourceDiagnostic.repository_depth=9;$sourceDiagnostic.git_exit_code=$null
 WriteSourceDiagnostic $sourceDiagnostic $null;$complete=Get-Content $leaf -Raw|ConvertFrom-Json
 Check ($complete.state -ceq 'completed' -and $complete.exception_type -ceq 'none' -and $complete.source_line -eq 0 -and $null -eq $complete.git_exit_code -and $complete.refusal_reason -ceq 'none') 'completed candidate remains explicitly not a binary/Store pass';Remove-Item $leaf
 foreach($bad in @('PRIVATE_FIXTURE',1,$null)){$sourceDiagnostic.stage=$bad;Refuse {WriteSourceDiagnostic $sourceDiagnostic $null} 'nonenum diagnostic stage refused'}
 $sourceDiagnostic.stage='bootstrap';$sourceDiagnostic.git_exit_code=$true;Refuse {WriteSourceDiagnostic $sourceDiagnostic $null} 'boolean cannot masquerade as Git exit'
 $sourceDiagnostic.git_exit_code=$null;$totalBytes=1.5;Refuse {WriteSourceDiagnostic $sourceDiagnostic $null} 'fractional source counter refused';$totalBytes=0L
 $sourcePrimaryFailure=$null;$sourceDiagnostic=NewSourceDiagnosticContext $leaf $temp
 $lock=@{bounds=@{max_recursion_depth=8;max_repositories=128}}
 $scope=[scriptblock]::Create("try { CollectSourceRepo 'https://github.com/BelledonneCommunications/linphone-sdk.git' ('a'*40) 'vendor/recursive-fixture' 9 } catch "+$catch+" finally "+$finally)
 $seen=$null;try{. $scope}catch{$seen=$_};$depthReport=Get-Content -LiteralPath $leaf -Raw|ConvertFrom-Json
 Check ($null -ne $seen -and $depthReport.state -ceq 'failed' -and $depthReport.repository_depth -eq 9 -and $depthReport.refusal_reason -ceq 'source_graph_bound' -and $depthReport.operation -ceq 'validate_input' -and $null -eq $depthReport.git_exit_code) 'actual attempted depth9 refuses before Git and retains bounded diagnostic'
 Remove-Item -LiteralPath $leaf

 $text=[IO.File]::ReadAllText($Collector)
 Check ($text.Contains("`$Mode -cne 'Collect'") -and $text.Contains("`$sourceDiagnostic=NewSourceDiagnosticContext `$DiagnosticPath `$env:RUNNER_TEMP") -and $text.IndexOf('$sourceDiagnostic=NewSourceDiagnosticContext') -lt $text.IndexOf('$lock=Get-Content -LiteralPath $SourceLock')) 'sidecar context/hosted-only guard precedes observed bootstrap'
}finally{Remove-Item -LiteralPath $root -Recurse -Force}
[ordered]@{schema=1;state='passed_actual_closed_diagnostic_components';checks=$checks;actual_SDK_collection=$false;historical_failure_cause_proven=$false;source_archive_produced=$false;binary_source_mapping_verified=$false}|ConvertTo-Json -Compress
