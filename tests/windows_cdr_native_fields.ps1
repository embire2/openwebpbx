param([string]$SourcePath=(Join-Path $PSScriptRoot 'windows-native-acceptance.ps1'))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($SourcePath,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Native acceptance source does not parse.'}
foreach($name in 'AssertCdrBackgroundNativeCase','CompletedMediaCases','CollectNativeProgress'){
 $functions=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true))
 if($functions.Count -ne 1){throw 'Exactly one actual acceptance function is required.'}
 . ([scriptblock]::Create($functions[0].Extent.Text))
}
$script:checks=0
function Check([bool]$Value,[string]$Label){if(!$Value){throw ('CDR consumer control failed: '+$Label)};$script:checks++}
function Refuse($Rows,[string]$Label){$bad=$false;try{AssertCdrBackgroundNativeCase $Rows}catch{$bad=$true};Check $bad $Label}
function Clone($Row){$Row|ConvertTo-Json -Depth 8|ConvertFrom-Json}
$row=[pscustomobject]@{case='native_localservice_cdr_background_import';passed=$true;actual_background_import=$true;actual_localservice_identity=$true;backend_pid_unchanged=$true;read_only_observer=$true;no_explicit_importer=$true;before_system_drain=$true;exact_call_domain_correlation=$true;history_sources_exact=$true;spool_absent=$true;matched_cdr_rows=1;answered_cdr_rows=1;history_rows=2;history_owner_rows=2;polls=1;elapsed_seconds=0}
AssertCdrBackgroundNativeCase @($row);Check $true 'exact closed producer-shaped case'
$completed=@(CompletedMediaCases @($row));Check ($completed.Count -eq 1 -and $completed[0] -ceq $row.case) 'validated completion is visible'
Refuse @() 'missing case';Refuse @($row,$row) 'duplicate case'
foreach($name in @($row.PSObject.Properties.Name)){
 $x=Clone $row;$x.PSObject.Properties.Remove($name);Refuse @($x) ('missing '+$name)
}
foreach($name in 'passed','actual_background_import','actual_localservice_identity','backend_pid_unchanged','read_only_observer','no_explicit_importer','before_system_drain','exact_call_domain_correlation','history_sources_exact','spool_absent'){
 foreach($value in @($false,'true',1,@($true),$null)){$x=Clone $row;$x.$name=$value;Refuse @($x) ('typed true '+$name)}
}
foreach($name in 'matched_cdr_rows','answered_cdr_rows','history_rows','history_owner_rows'){
 foreach($value in @('1',1.0,$true,0,3,@(1),$null)){$x=Clone $row;$x.$name=$value;Refuse @($x) ('exact integer '+$name)}
 $x=Clone $row;$x.$name=[long]$row.$name;AssertCdrBackgroundNativeCase @($x);Check $true ('long integer '+$name)
}
foreach($value in @('1',1.0,$true,0,27,@(1),$null)){$x=Clone $row;$x.polls=$value;Refuse @($x) 'bounded integer polls'}
foreach($value in @(1,26,[long]26)){$x=Clone $row;$x.polls=$value;AssertCdrBackgroundNativeCase @($x);Check $true 'inclusive poll boundary'}
foreach($value in @('0',$true,-.01,30.01,[double]::NaN,[double]::PositiveInfinity,[double]::NegativeInfinity,@(1),$null)){$x=Clone $row;$x.elapsed_seconds=$value;Refuse @($x) 'finite bounded elapsed'}
foreach($value in @(0,30,[long]30,[single]1.5,[double]1.5)){$x=Clone $row;$x.elapsed_seconds=$value;AssertCdrBackgroundNativeCase @($x);Check $true 'elapsed accepted boundary/type'}
$x=Clone $row;$x|Add-Member -NotePropertyName raw_log -NotePropertyValue 'private';Refuse @($x) 'unlisted field refuses'
$x=Clone $row;$x.actual_background_import=$false;Check (@(CompletedMediaCases @($x)).Count -eq 0) 'incomplete scope is never a completed public case'
Check (@(CompletedMediaCases @($row,$row)).Count -eq 0) 'duplicate cannot publish a completed case'
$x=Clone $row;$x.case=$x.case.ToUpperInvariant();Refuse @($x) 'case name is exact'
$x=Clone $row;$value=$x.spool_absent;$x.PSObject.Properties.Remove('spool_absent');$x|Add-Member -NotePropertyName Spool_Absent -NotePropertyValue $value;Refuse @($x) 'field spelling is exact'
$calls=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'AssertCdrBackgroundNativeCase'},$true))
Check ($calls.Count -eq 2) 'normal-full validator plus validated completed-case path'
$branches=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.IfStatementAst] -and $node.Clauses[0].Item1.Extent.Text -ceq '$HoldDiagnosticsOnly' -and $node.ElseClause -and $node.ElseClause.Extent.Text.Contains('AssertWelcomeNativeCase')},$true))
Check ($branches.Count -eq 1 -and $branches[0].ElseClause.Extent.Text.Contains('AssertCdrBackgroundNativeCase $native.checks') -and !$branches[0].Clauses[0].Item2.Extent.Text.Contains('AssertCdrBackgroundNativeCase')) 'mandatory full-only proof retains separate hold diagnostic'
$work=Join-Path ([IO.Path]::GetTempPath()) ('openweb-cdr-snapshots-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($work)|Out-Null
function WriteSnapshot([string]$Name,[string]$State,$Rows,[string]$Producer='windows-native-acceptance.py'){
 $value=[ordered]@{schema=1;producer=$Producer;state=$State;checks=@($Rows)}
 [IO.File]::WriteAllText((Join-Path $work $Name),($value|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
}
function HasCdr($Facts){return @($Facts.completed_media_cases|Where-Object {$_ -ceq $row.case}).Count -eq 1}
try{
 WriteSnapshot 'software-native-report.json' 'failed' @($row)
 WriteSnapshot 'native-progress.json' 'running' @($row)
 $facts=@{completed_media_cases=@()};CollectNativeProgress $facts $work
 Check ((HasCdr $facts) -and $facts.native_child_state -ceq 'failed') 'terminal and progress are snapshots, not duplicate executions'
 $invalid=Clone $row;$invalid.spool_absent=$false
 WriteSnapshot 'software-native-report.json' 'failed' @($invalid)
 $facts=@{completed_media_cases=@()};CollectNativeProgress $facts $work
 Check ($facts.completed_media_cases.Count -eq 0) 'older progress cannot mask incomplete terminal scope'
 WriteSnapshot 'software-native-report.json' 'failed' @($row,$row)
 $facts=@{completed_media_cases=@()};CollectNativeProgress $facts $work
 Check ($facts.completed_media_cases.Count -eq 0) 'genuine duplicate terminal cases still refuse'
 WriteSnapshot 'software-native-report.json' 'failed' @()
 $facts=@{completed_media_cases=@()};CollectNativeProgress $facts $work
 Check ($facts.completed_media_cases.Count -eq 0 -and $facts.native_child_state -ceq 'failed') 'empty terminal snapshot takes precedence over older progress'
 Remove-Item -LiteralPath (Join-Path $work 'software-native-report.json')
 $facts=@{completed_media_cases=@()};CollectNativeProgress $facts $work
 Check ((HasCdr $facts) -and !$facts.ContainsKey('native_child_state')) 'running snapshot remains available before a terminal report'
 WriteSnapshot 'software-native-report.json' 'failed' @($row) 'foreign.py'
 $facts=@{completed_media_cases=@()};CollectNativeProgress $facts $work
 Check ((HasCdr $facts) -and !$facts.ContainsKey('native_child_state')) 'foreign report cannot replace the valid progress producer'
}finally{Remove-Item -LiteralPath $work -Recurse -Force}
[pscustomobject]@{schema=1;state='passed';checks=$script:checks;scope='actual_PowerShell_AST_closed_CDR_consumer';native_importer_qualified=$false;installed_server_changed=$false}|ConvertTo-Json -Compress
