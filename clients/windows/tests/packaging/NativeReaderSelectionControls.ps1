# SPDX-License-Identifier: AGPL-3.0-or-later
#Requires -Version 7.4
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'NativeReaderSelection.ps1')
$checks=0;function Check([bool]$Value){if(!$Value){throw ('Native reader observation control '+($script:checks+1)+' failed.')};$script:checks++}
function Candidate($Version){[pscustomobject]@{VersionInfo=[pscustomobject]@{FileVersion=$Version;FileMajorPart=[int]14;FileMinorPart=[int]50;FileBuildPart=[int]1;FilePrivatePart=[int]0};Attributes=[IO.FileAttributes]::Normal;FullName='private-path-must-not-escape'}}
foreach($case in @(@{value='14.50.1.0';shape='four_component_numeric';matches=$true},@{value='14.50.1.0 built by private-label';shape='numeric_prefix_with_suffix';matches=$false},@{value='private-other';shape='other';matches=$false},@{value='';shape='empty';matches=$false},@{value=$null;shape='missing';matches=$false},@{value=1;shape='non_string';matches=$false},@{value=('x'*257);shape='oversized';matches=$false},@{value='999999999999999999.0.0.0';shape='four_component_numeric';matches=$true})){
 $row=GetPackageNativeReaderObservation @((Candidate $case.value));$json=$row|ConvertTo-Json -Depth 5 -Compress;$observed=ReadPackageNativeReaderObservation $json;Check ($observed.candidates[0].file_version_shape-ceq $case.shape -and $observed.candidates[0].matches_original_pattern-eq $case.matches);Check (!$json.Contains('private-') -and !$observed.selection_changed -and !$observed.tool_executed)
 if($case.value-ceq '14.50.1.0'){Check (($observed.candidates[0].parsed_numeric_version-join '.')-ceq '14.50.1.0')}
}
foreach($count in @(0,1,16,17,100)){$rows=@();for($i=0;$i-lt $count;$i++){$rows+=Candidate '14.50.1.0'};$observed=ReadPackageNativeReaderObservation ((GetPackageNativeReaderObservation $rows)|ConvertTo-Json -Depth 5 -Compress);Check ($observed.candidate_count-eq [Math]::Min($count,17) -and $observed.count_capped-eq ($count-gt 16) -and $observed.candidates.Count-eq $(if($count-gt 16){0}else{$count}))}
$json=(GetPackageNativeReaderObservation @((Candidate '14.50.1.0')))|ConvertTo-Json -Depth 5 -Compress
foreach($mutation in @(@{schema='1'},@{schema=2},@{producer='foreign'},@{candidate_count=-1},@{candidate_count=18},@{candidate_count='1'},@{count_capped=$true},@{count_capped=0},@{selection_changed=$true},@{tool_executed=$true},@{path='private'},@{candidates=@()},@{candidates='private'})){$changed=$json|ConvertFrom-Json -AsHashtable;foreach($field in $mutation.Keys){$changed[$field]=$mutation[$field]};$refused=$false;try{ReadPackageNativeReaderObservation ($changed|ConvertTo-Json -Depth 5 -Compress)|Out-Null}catch{$refused=$true};Check $refused}
foreach($mutation in @(@{index='0'},@{index=1},@{file_version_shape='private'},@{matches_original_pattern=$false},@{matches_original_pattern='true'},@{signature_evaluated=$true},@{ordinary_ancestry_evaluated=$true},@{file_reparse_point=1},@{parsed_numeric_version=@(1,2,3)},@{parsed_numeric_version=@('1',2,3,4)},@{resource_version_parts=@(1,2,3,65536)},@{resource_version_parts=$null},@{path='private'})){$changed=$json|ConvertFrom-Json -AsHashtable;foreach($field in $mutation.Keys){$changed.candidates[0][$field]=$mutation[$field]};$refused=$false;try{ReadPackageNativeReaderObservation ($changed|ConvertTo-Json -Depth 5 -Compress)|Out-Null}catch{$refused=$true};Check $refused}
foreach($bad in @('not-json',('x'*16385),$json.Replace('"schema":1,','"schema":1,"schema":1,'),$json.Replace('"index":0,','"index":0,"index":0,'))){$refused=$false;try{ReadPackageNativeReaderObservation $bad|Out-Null}catch{$refused=$true};Check $refused}
$client=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent;$errors=$null;$tokens=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $client 'tools/Test-ClientPackage.ps1'),[ref]$tokens,[ref]$errors);Check (!$errors)
$guards=@($ast.FindAll({param($node)$node-is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith('if(!$readers.Count -or $readers.Count-gt 16 -or')},$true));Check ($guards.Count-eq 1)
& {
 param($Guard)
 foreach($case in @(@{count=0;version='14.50.1.0';refuse=$true},@{count=1;version='14.50.1.0';refuse=$false},@{count=16;version='14.50.1.0';refuse=$false},@{count=17;version='14.50.1.0';refuse=$true},@{count=1;version='14.50.1.0 built by private-label';refuse=$true})){
  $readers=@();for($i=0;$i-lt $case.count;$i++){$readers+=Candidate $case.version};$original=$readers|ConvertTo-Json -Depth 4 -Compress;$refused=$false;try{. $Guard}catch{$refused=$true};$observation=GetPackageNativeReaderObservation $readers;$again=$false;try{. $Guard}catch{$again=$true};Check ($refused-eq $case.refuse -and $again-eq $refused -and ($readers|ConvertTo-Json -Depth 4 -Compress)-ceq $original)
 }
} ([scriptblock]::Create($guards[0].Extent.Text))
$runtime=[Management.Automation.Language.Parser]::ParseFile((Join-Path $client 'tools/Test-PackageRuntime.ps1'),[ref]$tokens,[ref]$errors);Check (!$errors)
$source=[IO.File]::ReadAllText((Join-Path $client 'tools/Test-PackageRuntime.ps1'));Check ($source.Contains('$enumeration[0].Extent.Text') -and $source.Contains('$guard[0].Extent.Text') -and $source.Contains('$result.native_import_reader_preflight_accepted=$false'))
$runtimeBody=@($runtime.FindAll({param($node)$node-is [Management.Automation.Language.TryStatementAst] -and $node.Body.Extent.Text.Contains('$selectionSource=')},$true));Check ($runtimeBody.Count-eq 1)
$statements=@($runtimeBody[0].Body.Statements);$first=-1;$last=-1;for($index=0;$index-lt $statements.Count;$index++){if($statements[$index].Extent.Text.StartsWith('$selectionSource=')){$first=$index};if($statements[$index].Extent.Text.StartsWith('$result.state=')){$last=$index}};Check ($first-ge 0 -and $last-gt $first)
$probe=[scriptblock]::Create((@($statements[$first..($last-1)]|ForEach-Object {$_.Extent.Text})-join "`n"))
& {
 param($Probe)
 # Only filesystem discovery is adapted. The probe extracts and invokes the
 # actual committed package enumeration/guard against these invented candidates.
 function Join-Path($Path,$ChildPath){if([string]::IsNullOrEmpty($Path)){'fixture-root/'+$ChildPath}else{Microsoft.PowerShell.Management\Join-Path $Path $ChildPath}}
 function Test-Path($Path,$PathType){if($Path.Replace('\','/')-like '*Microsoft Visual Studio/*'){return $true};throw 'Unexpected discovery path.'}
 function Get-ChildItem($Path,[switch]$File,$ErrorAction){if($Path.Replace('\','/')-notlike '*Microsoft Visual Studio/*' -or !$File){throw 'Unexpected discovery operation.'};@($script:readerFixture)}
 $script:readerFixture=Candidate '14.50.1.0'
 foreach($path in @('C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Tools\MSVC\14.50\bin\Hostx64\x64\dumpbin.exe','/fixture/Microsoft Visual Studio/2022/Enterprise/VC/Tools/MSVC/14.50/bin/Hostx64/x64/dumpbin.exe')){Check (Test-Path $path -PathType Leaf);Check (@(Get-ChildItem $path -File -ErrorAction Stop).Count-eq 1)}
 foreach($command in @('Test-Path','Get-ChildItem')){$refused=$false;try{if($command-ceq 'Test-Path'){Test-Path 'C:\foreign\dumpbin.exe' -PathType Leaf|Out-Null}else{Get-ChildItem 'C:\foreign\dumpbin.exe' -File -ErrorAction Stop|Out-Null}}catch{$refused=$true};Check $refused}
 foreach($case in @(@{version='14.50.1.0';accepted=$true},@{version='14.50.1.0 built by private-label';accepted=$false})){$script:readerFixture=Candidate $case.version;$result=[ordered]@{};. $Probe;Check ($result.native_import_reader_preflight_accepted-eq $case.accepted -and $result.native_import_reader_selection.candidate_count-ge 1 -and !$result.native_import_reader_selection.tool_executed)}
} $probe
"PASS $checks actual reader-observer/strict-consumer/source-guard controls; candidate metadata are explicit adapters, no native tool selection or trust pass"
