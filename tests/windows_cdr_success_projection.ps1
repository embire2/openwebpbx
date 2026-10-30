param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$source=Join-Path $SourceRoot 'tests/windows-suite.ps1';$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The actual suite source must parse.'}
$functions=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'ReadSuiteCdrBackgroundImport'},$true))
if($functions.Count -ne 1){throw 'Exactly one actual CDR success projection is required.'}
. ([scriptblock]::Create($functions[0].Extent.Text))
$script:checks=0
function Check([bool]$Value,[string]$Label){if(!$Value){throw ('CDR success projection control failed: '+$Label)};$script:checks++}
function Clone($Row){$Row|ConvertTo-Json -Depth 8|ConvertFrom-Json}
function Refuse($Rows,[string]$Label){$bad=$false;try{$null=ReadSuiteCdrBackgroundImport $Rows}catch{$bad=$true};Check $bad $Label}
$row=[pscustomobject]@{case='native_localservice_cdr_background_import';passed=$true;actual_background_import=$true;actual_localservice_identity=$true;backend_pid_unchanged=$true;read_only_observer=$true;no_explicit_importer=$true;before_system_drain=$true;exact_call_domain_correlation=$true;history_sources_exact=$true;spool_absent=$true;matched_cdr_rows=1;answered_cdr_rows=1;history_rows=2;history_owner_rows=2;polls=1;elapsed_seconds=0}
$fields=@($row.PSObject.Properties.Name)
function RoundTrip($Row){
 $safe=ReadSuiteCdrBackgroundImport @($Row)
 Check ($safe.Count -eq 17 -and @($safe.Keys|Where-Object {$_ -cnotin $fields}).Count -eq 0) 'exact17 closed output fields'
 $encoded=$safe|ConvertTo-Json -Depth 4 -Compress
 Check ($encoded -notmatch 'uuid|password|secret|source_ip|call_id|[A-Za-z]:\\|/private/') 'no private identifiers or paths'
 $decoded=$encoded|ConvertFrom-Json
 Check (@($decoded.PSObject.Properties.Name).Count -eq 17) 'JSON retains exact closed object'
 foreach($flag in 'passed','actual_background_import','actual_localservice_identity','backend_pid_unchanged','read_only_observer','no_explicit_importer','before_system_drain','exact_call_domain_correlation','history_sources_exact','spool_absent'){Check ($decoded.$flag -is [bool] -and $decoded.$flag) ('JSON typed true '+$flag)}
 foreach($field in 'matched_cdr_rows','answered_cdr_rows','history_rows','history_owner_rows','polls'){$value=$decoded.$field;Check (($value -is [int] -or $value -is [long]) -and $value -eq $Row.$field) ('JSON exact integer '+$field)}
 Check (($decoded.elapsed_seconds -is [int] -or $decoded.elapsed_seconds -is [long] -or $decoded.elapsed_seconds -is [double]) -and ![double]::IsNaN([double]$decoded.elapsed_seconds) -and ![double]::IsInfinity([double]$decoded.elapsed_seconds) -and $decoded.elapsed_seconds -eq $Row.elapsed_seconds) 'JSON finite elapsed numeric shape'
}
RoundTrip $row
Refuse @() 'missing proof';Refuse @($row,$row) 'duplicate exact proof'
foreach($field in $fields){$x=Clone $row;$x.PSObject.Properties.Remove($field);Refuse @($x) ('missing '+$field)}
foreach($field in 'passed','actual_background_import','actual_localservice_identity','backend_pid_unchanged','read_only_observer','no_explicit_importer','before_system_drain','exact_call_domain_correlation','history_sources_exact','spool_absent'){
 foreach($value in @($false,'true',1,@($true),$null)){$x=Clone $row;$x.$field=$value;Refuse @($x) ('strict true '+$field)}
}
foreach($field in 'matched_cdr_rows','answered_cdr_rows','history_rows','history_owner_rows'){
 foreach($value in @('1',1.0,$true,0,3,@(1),$null)){$x=Clone $row;$x.$field=$value;Refuse @($x) ('exact integer '+$field)}
 $x=Clone $row;$x.$field=[long]$row.$field;RoundTrip $x
}
foreach($value in @('1',1.0,$true,0,27,@(1),$null)){$x=Clone $row;$x.polls=$value;Refuse @($x) 'strict bounded integer polls'}
foreach($value in @(1,26,[long]26)){$x=Clone $row;$x.polls=$value;RoundTrip $x}
foreach($value in @('0',$true,-.01,30.01,[double]::NaN,[double]::PositiveInfinity,[double]::NegativeInfinity,@(1),$null)){$x=Clone $row;$x.elapsed_seconds=$value;Refuse @($x) 'finite bounded numeric elapsed'}
foreach($value in @(0,30,[long]30,[single]1.5,[double]1.5)){$x=Clone $row;$x.elapsed_seconds=$value;RoundTrip $x}
foreach($field in 'private_uuid','source_ip','raw_log','password'){$x=Clone $row;$x|Add-Member -NotePropertyName $field -NotePropertyValue 'private-fixture-value';Refuse @($x) ('privacy field '+$field)}
$x=Clone $row;$x.case=$x.case.ToUpperInvariant();Refuse @($x) 'case spelling is exact'
$x=Clone $row;$value=$x.spool_absent;$x.PSObject.Properties.Remove('spool_absent');$x|Add-Member -NotePropertyName Spool_Absent -NotePropertyValue $value;Refuse @($x) 'field spelling is exact'
Refuse @(@{case=$row.case}) 'dictionary is not the producer object'
$assignments=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$facts.native_cdr_background_import'},$true))
Check ($assignments.Count -eq 1) 'one parent receipt assignment'
$branch=$assignments[0].Parent
while($branch -and $branch -isnot [Management.Automation.Language.IfStatementAst]){$branch=$branch.Parent}
$expected='$NativeDiagnosticsOnly','$UpgradeDiagnosticsOnly','$BackupsDiagnosticsOnly','$ReplaySuiteRunId','$SkipPhoneHealthForNativeDiagnostics','$HoldDiagnosticsOnly'
$actual=$branch.Clauses[0].Item1.Extent.Text
$expectedCondition='!$NativeDiagnosticsOnly-and!$UpgradeDiagnosticsOnly-and!$BackupsDiagnosticsOnly-and(!$ReplaySuiteRunId-or$Public21ToCandidate22)-and!$SkipPhoneHealthForNativeDiagnostics-and!$HoldDiagnosticsOnly'
Check (($actual -replace '\s','') -ceq $expectedCondition) 'only normal full or strict public21 replay without diagnostic flags can publish receipt'
Check ($assignments[0].Right.Extent.Text -ceq 'ReadSuiteCdrBackgroundImport $native.checks') 'assignment receives only freshly validated actual native checks'
# Execute only the actual pure projection branch, never the surrounding suite.
$publish=[scriptblock]::Create($branch.Extent.Text)
foreach($disabled in @('normal','strict public21 replay')+@($expected)){
 foreach($flag in $expected){Set-Variable -Name $flag.Substring(1) -Value $false}
 $Public21ToCandidate22=$false
 if($disabled -ceq 'strict public21 replay'){$Public21ToCandidate22=$true;$ReplaySuiteRunId='41103840154'}
 elseif($disabled -cne 'normal'){Set-Variable -Name $disabled.Substring(1) -Value $true}
 $facts=@{gates=@{native_sip_audio='unqualified'}};$native=@{checks=@($row)}
 & $publish
 Check ($facts.ContainsKey('native_cdr_background_import') -eq ($disabled -cin 'normal','strict public21 replay')) ('actual branch receipt presence '+$disabled)
 Check ($facts.gates.native_sip_audio -ceq 'unqualified') 'projection branch cannot promote calling gates'
}
foreach($flag in @($expected|Where-Object {$_ -cne '$ReplaySuiteRunId'})){
 foreach($item in $expected){Set-Variable -Name $item.Substring(1) -Value $false}
 $Public21ToCandidate22=$true;$ReplaySuiteRunId='41103840154';Set-Variable -Name $flag.Substring(1) -Value $true
 $facts=@{gates=@{native_sip_audio='unqualified'}};$native=@{checks=@($row)}
 & $publish
 Check (!$facts.ContainsKey('native_cdr_background_import') -and $facts.gates.native_sip_audio -ceq 'unqualified') ('strict public21 replay still denies diagnostic '+$flag)
}
foreach($flag in $expected){Set-Variable -Name $flag.Substring(1) -Value $false}
$Public21ToCandidate22=$false
$facts=@{gates=@{native_sip_audio='unqualified'}};$native=@{checks=@()};$refused=$false
try{& $publish}catch{$refused=$true}
Check ($refused -and !$facts.ContainsKey('native_cdr_background_import') -and $facts.gates.native_sip_audio -ceq 'unqualified') 'missing normal proof refuses before receipt or gate assignment'

$normal=$branch.Parent.Extent.Text
Check ($normal.IndexOf('$facts.native_cdr_background_import=') -lt $normal.IndexOf("`$facts.gates.native_sip_audio='passed'")) 'validation precedes native SIP passed gate'
$text=[IO.File]::ReadAllText($source)
$dom="CheckedPython @((Join-Path `$source 'tests/windows_smtp_notice.py'),'SMTPNoticeControls.test_actual_dom_success_and_refusals')"
$post="CheckedPython @((Join-Path `$source 'tests/windows_smtp_notice.py'),'--php-executable','C:\OpenWebPBX\php\php.exe','SMTPNoticeControls.test_actual_php_post_notice_and_refusals')"
$php="`$phase='native PHP runtime qualification';PhpRuntimeQualificationHook"
Check ($text.Contains($dom) -and $text.Contains($post) -and $text.IndexOf($dom) -lt $text.IndexOf($php) -and $text.IndexOf($post) -gt $text.IndexOf($php)) 'DOM stays early; seven PHP POST cases require actual installed runtime matrix first'
[pscustomobject]@{schema=1;state='passed';checks=$script:checks;scope='actual_PowerShell_AST_closed_CDR_success_projection_and_SMTP_hook_order';native_importer_qualified=$false;installed_server_changed=$false}|ConvertTo-Json -Compress
