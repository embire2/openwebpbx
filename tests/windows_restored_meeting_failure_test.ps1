param([string]$Source=(Join-Path $PSScriptRoot 'windows-restore-qualification.ps1'))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Source parse refused.'}
$definitions=@{}
foreach($name in 'SafeRestoredConferenceWssChildFields','SafeRestoredConferenceFailure','SafeRestoredConferencePathFields','ReadRestoredConferenceFailure','RestoredMeetingSupplement'){
 $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))
 if($nodes.Count -ne 1){throw 'One exact observed source function required.'}
 $definitions[$name]=$nodes[0].Extent.Text.Replace('$PSScriptRoot',("'"+$PSScriptRoot.Replace("'","''")+"'"))
 . ([scriptblock]::Create($definitions[$name]))
}
$owned=Join-Path ([IO.Path]::GetTempPath()) ('restored-meet-failure-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $owned
$work=Join-Path $owned 'private-output';$null=New-Item -ItemType Directory -Path $work
$path=Join-Path $work 'restored-conference-supplement.out';$checks=0;$cases=0
function Assert([bool]$Value){if(!$Value){throw 'A closed failure observation control refused.'};$script:checks++}
function Copy-ObservedRecord($Value){return ConvertFrom-Json -InputObject ($Value|ConvertTo-Json -Depth 16 -Compress) -AsHashtable}
function WriteOutput([string]$Value){[IO.File]::WriteAllText($path,$Value,[Text.UTF8Encoding]::new($false))}
function GoodChild {return @{caller='CheckedProcess';label='restored-conference-supplement';completion='exit';exit_code=1}}
$base=@{schema=1;state='failed';producer='windows_restored_meeting.py';error_type='RuntimeError';cleanup_verified=$true;source_frames=@(@{source_basename='windows_restored_meeting.py';source_line=123});active_case='native_windows_meeting_decoded_media';owned_process_cleanup_failed=$false;owned_processes_closed=$true}
try{
 Assert ($null -ne (SafeRestoredConferenceFailure $base));$cases++
 $mutations=@(
  @{schema=$true},@{schema=2},@{state='passed'},@{producer='private.py'},@{error_type='PRIVATE_SECRET'},
  @{cleanup_verified=1},@{source_frames=$null},@{source_frames=@{}},@{source_frames=@(1)},
  @{active_case='PRIVATE https://private.example.invalid'},@{owned_process_cleanup_failed=1},@{owned_processes_closed='true'},@{private='PRIVATE SQL password'}
 )
 foreach($edit in $mutations){$row=Copy-ObservedRecord $base;foreach($key in $edit.Keys){$row[$key]=$edit[$key]};Assert ($null -eq (SafeRestoredConferenceFailure $row));$cases++}
 foreach($field in $base.Keys){$row=Copy-ObservedRecord $base;$row.Remove($field);Assert ($null -eq (SafeRestoredConferenceFailure $row));$cases++}
 foreach($edit in @(@{source_basename='PRIVATE.py'},@{source_line=$true},@{source_line=0},@{source_line=1000000},@{source_line=1.5},@{source_line='123'},@{private='PRIVATE UUID'})){
  $row=Copy-ObservedRecord $base;foreach($key in $edit.Keys){$row.source_frames[0][$key]=$edit[$key]};Assert ($null -eq (SafeRestoredConferenceFailure $row));$cases++
 }
 $row=Copy-ObservedRecord $base;$row.source_frames=@($row.source_frames[0])*5;Assert ($null -eq (SafeRestoredConferenceFailure $row));$cases++
 foreach($count in 0,4){$row=Copy-ObservedRecord $base;$row.source_frames=@($row.source_frames[0])*$count;$row.owned_process_cleanup_failed=$null;$row.owned_processes_closed=$null;Assert ($null -ne (SafeRestoredConferenceFailure $row));$cases++}
 foreach($kind in 'RuntimeError','ValueError','TypeError','KeyError','AttributeError','AssertionError','TimeoutError','TimeoutExpired','OSError','FileNotFoundError','PermissionError','JSONDecodeError','SSLError','HTTPError','URLError','external_error'){$row=Copy-ObservedRecord $base;$row.error_type=$kind;Assert ($null -ne (SafeRestoredConferenceFailure $row));$cases++}
 foreach($case in 'unavailable','native_windows_meeting_browser_media','native_windows_meeting_dependencies','native_windows_meeting_unknown','native_windows_meeting_browser_start','native_windows_meeting_owner_page','native_windows_meeting_create','native_windows_meeting_host_join','native_windows_meeting_guest_join','native_windows_meeting_admission','native_windows_meeting_decoded_media','native_windows_meeting_mute','native_windows_meeting_unmute','native_windows_meeting_end'){$row=Copy-ObservedRecord $base;$row.active_case=$case;Assert ($null -ne (SafeRestoredConferenceFailure $row));$cases++}
 $json=$base|ConvertTo-Json -Depth 8 -Compress
 $nodeCode="const d=require(process.argv[1]);process.stdout.write(JSON.stringify({before:d.defaults(),after:d.defaults()}));"
 $pathJson=& node -e $nodeCode (Join-Path $PSScriptRoot 'windows-meet-path-diagnostics.cjs')
 Assert ($LASTEXITCODE -eq 0)
 $withPath=Copy-ObservedRecord $base;$withPath.active_case='native_windows_meeting_browser_start'
 $withPath.meeting_path=ConvertFrom-Json -InputObject $pathJson -AsHashtable
 $withPath.meeting_path.before.backend.status_code=200;$withPath.meeting_path.after.frontend.elapsed_ms=49
 $closed=SafeRestoredConferenceFailure $withPath;Assert ($null -ne $closed -and $closed.Count -eq 10 -and $closed.meeting_path.before.backend.status_code -eq 200 -and $closed.meeting_path.after.frontend.elapsed_ms -eq 49);$cases++
 $pathRecordJson=$withPath|ConvertTo-Json -Depth 9 -Compress
 foreach($case in 'valid-path','nested-duplicate','nested-private','wrong-phase','containers-over-bound'){
  $row=Copy-ObservedRecord $withPath;$script:qualificationFailedChild=GoodChild
  switch($case){
   nested-private{$row.meeting_path.before.backend.raw_header='PRIVATE password'}
   wrong-phase{$row.active_case='native_windows_meeting_decoded_media'}
   containers-over-bound{$row.meeting_path.before.backend.extra=@(@{})*65}
  }
  $value=$row|ConvertTo-Json -Depth 10 -Compress
  if($case -ceq 'nested-duplicate'){$value=$value.Replace('"status_code":200','"status_code":200,"status_code":200')}
  Assert ($value.Length -le 8192);WriteOutput $value
  $observed=ReadRestoredConferenceFailure;Assert (($null -ne $observed) -eq ($case -ceq 'valid-path'));$cases++
 }
 $script:qualificationFailedChild=GoodChild
 foreach($case in 'valid','valid-bound','missing','empty','oversized','malformed','duplicate-root','duplicate-frame','private-extra','invalid-utf8','array-root','null-root','deep-json','directory','file-link','parent-link'){
  if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force}
  WriteOutput $json
  switch($case){
   valid-bound{WriteOutput ($json.PadRight(8192,' '))}
   missing{Remove-Item -LiteralPath $path}
   empty{WriteOutput ''}
   oversized{WriteOutput (' '*8193)}
   malformed{WriteOutput '{'}
   duplicate-root{WriteOutput ($json.Replace('"schema":1','"schema":1,"schema":1'))}
   duplicate-frame{WriteOutput ($json.Replace('"source_line":123','"source_line":123,"source_line":123'))}
   private-extra{$row=Copy-ObservedRecord $base;$row.private='PRIVATE password SQL';WriteOutput ($row|ConvertTo-Json -Depth 8 -Compress)}
   invalid-utf8{[IO.File]::WriteAllBytes($path,[byte[]]@(255,254))}
   array-root{WriteOutput ('['+$json+']')}
   null-root{WriteOutput 'null'}
   deep-json{WriteOutput ('{"x":'+('['*10)+'0'+(']'*10)+'}')}
   directory{Remove-Item -LiteralPath $path;$null=New-Item -ItemType Directory -Path $path}
   file-link{$other=Join-Path $owned 'ordinary.out';[IO.File]::WriteAllText($other,$json);Remove-Item -LiteralPath $path;$null=New-Item -ItemType SymbolicLink -Path $path -Target $other}
   parent-link{$real=Join-Path $owned 'ordinary-parent';$null=New-Item -ItemType Directory -Path $real;[IO.File]::WriteAllText((Join-Path $real 'restored-conference-supplement.out'),$json);$oldWork=$work;$work=Join-Path $owned 'alias-parent';$null=New-Item -ItemType SymbolicLink -Path $work -Target $real}
  }
  $record=ReadRestoredConferenceFailure
  Assert (($null -ne $record) -eq ($case -cin @('valid','valid-bound')))
  if($record){Assert (($record|ConvertTo-Json -Depth 8 -Compress) -notmatch 'PRIVATE|password|https:|SQL')}
  if($case -ceq 'parent-link'){$work=$oldWork}
  $cases++
 }
 if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force};WriteOutput $json
 foreach($edit in @(@{caller='other'},@{label='other'},@{completion='deadline'},@{exit_code=0},@{exit_code=$true},@{exit_code='1'},@{exit_code=4294967296L},@{exit_code=-2147483649L})){
  $script:qualificationFailedChild=GoodChild;foreach($key in $edit.Keys){$script:qualificationFailedChild[$key]=$edit[$key]};Assert ($null -eq (ReadRestoredConferenceFailure));$cases++
 }
 $script:qualificationFailedChild=$null;Assert ($null -eq (ReadRestoredConferenceFailure));$cases++
 # The actual parent makes exactly one original child call and bare-rethrows
 # that same primary exception. Old source is reconstructed only by removing
 # the independently source-hash-checked failure-only catch.
 $state=Join-Path $owned 'state';$null=New-Item -ItemType Directory -Path $state
 $inputFile=Join-Path $owned 'input.json';[IO.File]::WriteAllText($inputFile,'{}')
 $source=Split-Path $PSScriptRoot -Parent;$python='explicit-unexecuted-child-adapter';$Role='Target';$BaseVersion='1.0.20';$BaseSuiteRunId='12345'
 function Check([bool]$Value,[string]$Message){Assert $Value}
 function PrivateDirectory([string]$Path){$null=New-Item -ItemType Directory -Path $Path}
 function Set-SuiteFixtureBinding([switch]$Read){$script:bindingReads++;return @{hash=[byte[]]@(1,2,3);store='My'}}
 function CheckedProcess($Executable,$Arguments,$Name,$Cwd,$Timeout){
  Assert ($Executable -ceq 'explicit-unexecuted-child-adapter' -and $Arguments.Count -eq 7 -and $Arguments[0] -ceq '-I' -and $Arguments[1] -ceq '-B' -and $Arguments[2] -ceq (Join-Path $PSScriptRoot 'windows_restored_meeting.py') -and $Arguments[3] -ceq '--input' -and $Arguments[4] -ceq $inputFile -and $Arguments[5] -ceq '--adapter' -and $Name -ceq 'restored-conference-supplement' -and $Cwd -ceq $source -and $Timeout -eq 600000)
  $script:childCalls++;$script:qualificationFailedChild=GoodChild;WriteOutput $script:childOutput
  throw $script:primary
 }
 $call="CheckedProcess `$python @('-I','-B',(Join-Path '"+$PSScriptRoot.Replace("'","''")+"' 'windows_restored_meeting.py'),'--input',`$inputFile,'--adapter',`$adapter) 'restored-conference-supplement' `$source 600000"
 $addition=" try{"+$call+"}`n catch{`n  try{`$failure=ReadRestoredConferenceFailure;if(`$null -ne `$failure){`$facts.restored_conference_failure=`$failure}}catch{}`n  throw`n }"
 Assert ($definitions.RestoredMeetingSupplement.Contains($addition))
 $oldDefinition=$definitions.RestoredMeetingSupplement.Replace($addition,' '+$call)
 foreach($case in 'old-blind-failure','new-closed-failure','new-closed-path','new-missing-fields','new-observer-throws'){
  $definition=if($case -ceq 'old-blind-failure'){$oldDefinition}else{$definitions.RestoredMeetingSupplement};. ([scriptblock]::Create($definition))
  . ([scriptblock]::Create($definitions.ReadRestoredConferenceFailure))
  if($case -ceq 'new-observer-throws'){function ReadRestoredConferenceFailure {throw 'PRIVATE observer fault'}}
  $facts=@{base_archive_sha256=('a'*64);gates=@{}};$script:bindingReads=0;$script:childCalls=0;$script:primary=[InvalidOperationException]::new('PRIVATE original child failure')
  $script:childOutput=if($case -ceq 'new-missing-fields'){'{"schema":1,"state":"failed"}'}elseif($case -ceq 'new-closed-path'){$pathRecordJson}else{$json}
  $failure=$null;try{RestoredMeetingSupplement;throw 'The original refusal was swallowed.'}catch{$failure=$_}
  Assert ([object]::ReferenceEquals($failure.Exception,$script:primary));Assert ($script:childCalls -eq 1);Assert ($script:bindingReads -eq 1)
  Assert (!$facts.gates.ContainsKey('restored_browser_conference_two_way_decoded_audio_video'));Assert (!$facts.ContainsKey('qualification_mode'))
  Assert ($facts.ContainsKey('restored_conference_failure') -eq ($case -cin @('new-closed-failure','new-closed-path')))
  if($case -ceq 'new-closed-path'){Assert ($facts.restored_conference_failure.meeting_path.before.backend.status_code -eq 200)}
  $cases++
 }
}finally{Remove-Item -LiteralPath $owned -Recurse -Force}
if(Test-Path -LiteralPath $owned){throw 'Owned observation controls survived.'}
$wssChildControls=& (Join-Path $PSScriptRoot 'windows_meet_wss_child_test.ps1') -Source $ast.Extent.File | ConvertFrom-Json
Assert ($wssChildControls.state -ceq 'passed')
@{schema=1;state='passed';cases=$cases;assertions=$checks;wss_child_cases=$wssChildControls.cases;wss_child_checks=$wssChildControls.checks;actual_parent_source=$true;bounded_real_output_files=$true;original_primary_preserved=$true;original_child_called_once=$true;installed_services_or_browser_called=$false;owned_fixture_removed=$true}|ConvertTo-Json -Compress
