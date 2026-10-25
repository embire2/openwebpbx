param([string]$Source=(Join-Path $PSScriptRoot 'windows-restore-qualification.ps1'))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Source parse refused.'}
$nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'RestoredMeetingSupplement'},$true))
if($nodes.Count -ne 1){throw 'One actual supplemental parent function required.'}
# Anonymous extracted functions have no file-backed PSScriptRoot. Adapt only
# that automatic path value; the child/binding APIs below remain explicit doubles.
$definition=$nodes[0].Extent.Text.Replace('$PSScriptRoot',("'"+$PSScriptRoot.Replace("'","''")+"'"))
. ([scriptblock]::Create($definition))
$owned=Join-Path ([IO.Path]::GetTempPath()) ('restored-meet-parent-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $owned
$state=Join-Path $owned 'state';$null=New-Item -ItemType Directory -Path $state
$inputFile=Join-Path $owned 'input.json';[IO.File]::WriteAllText($inputFile,'{}')
$source=Split-Path $PSScriptRoot -Parent;$python='explicit-unexecuted-child-adapter';$Role='Target';$BaseVersion='1.0.20';$BaseSuiteRunId='12345';$checks=0;$cases=0
function Check([bool]$Value,[string]$Message){if(!$Value){throw 'Actual supplemental parent guard refused.'};$script:checks++}
function PrivateDirectory([string]$Path){$null=New-Item -ItemType Directory -Path $Path -Force}
function Set-SuiteFixtureBinding([switch]$Read){$script:bindingReads++;return @{hash=[byte[]]@(1,2,$(if($script:badBinding -and $script:bindingReads -gt 1){4}else{3}));store='My'}}
function CheckedProcess($Executable,$Arguments,$Name,$Cwd,$Timeout){
 if($Executable -cne 'explicit-unexecuted-child-adapter' -or $Arguments[0] -cne '-I' -or $Arguments[1] -cne '-B' -or $Arguments[2] -cne (Join-Path $PSScriptRoot 'windows_restored_meeting.py') -or $Arguments[3] -cne '--input' -or $Arguments[4] -cne $inputFile -or $Arguments[5] -cne '--adapter' -or $Name -cne 'restored-conference-supplement' -or $Cwd -cne $source -or $Timeout -ne 600000){throw 'Original supplemental invocation changed.'}
 $path=$Arguments[6]
 if(!(Test-Path -LiteralPath $path) -or [IO.Path]::GetDirectoryName($path) -cne (Join-Path $state 'native-qualification')){throw 'Owned adapter creation mismatch.'}
 if(!$script:keepScope){Remove-Item -LiteralPath $path}
 [IO.File]::WriteAllText((Join-Path $owned 'restored-conference.safe.json'),($script:record|ConvertTo-Json -Depth 8 -Compress))
}
$environment=@{};foreach($name in 'GITHUB_RUN_ID','GITHUB_SHA'){$environment[$name]=[Environment]::GetEnvironmentVariable($name)}
try{
 $env:GITHUB_RUN_ID='123456';$env:GITHUB_SHA='d'*40
 $base=@{schema=1;state='passed';producer='windows_restored_meeting.py';run_id=$env:GITHUB_RUN_ID;source_commit=$env:GITHUB_SHA;base_suite_run_id=$BaseSuiteRunId;base_archive_sha256=('a'*64);media=@{checks=9;wss_roundtrips=16;host_frames=10;guest_frames=10;host_tone_ratio=.66;guest_tone_ratio=.9;physical_camera='unqualified'};original_meetings_and_members_preserved=$true;original_bindings_and_holds_preserved=$true;owned_processes_closed=$true;owned_native_scope_removed=$true;remaining_calls=0;existing_invitation_continuity='unqualified';physical_camera='unqualified';external_nat='unqualified'}
 $mutations=@('valid','schema_bool','foreign_run','foreign_source','foreign_archive','private_extra','missing_field','process_survivor','scope_survivor','audio_threshold','frames_bool','roundtrips','physical_claim','binding_changed','actual_scope_survived')
 foreach($case in $mutations){
  $script:record=($base|ConvertTo-Json -Depth 8|ConvertFrom-Json -AsHashtable)
  $script:bindingReads=0;$script:badBinding=$false;$script:keepScope=$false
  switch($case){
   schema_bool{$script:record.schema=$true}
   foreign_run{$script:record.run_id='999'}
   foreign_source{$script:record.source_commit='e'*40}
   foreign_archive{$script:record.base_archive_sha256='b'*64}
   private_extra{$script:record.private='do not project'}
   missing_field{$script:record.Remove('owned_processes_closed')}
   process_survivor{$script:record.owned_processes_closed=$false}
   scope_survivor{$script:record.owned_native_scope_removed=$false}
   audio_threshold{$script:record.media.host_tone_ratio=.65}
   frames_bool{$script:record.media.host_frames=$true}
   roundtrips{$script:record.media.wss_roundtrips=15}
   physical_claim{$script:record.physical_camera='passed'}
   binding_changed{$script:badBinding=$true}
   actual_scope_survived{$script:keepScope=$true}
  }
  $facts=@{base_archive_sha256=('a'*64);gates=@{}}
  $accepted=$false;$failure=$null;try{RestoredMeetingSupplement;$accepted=$true}catch{$failure=$_}
  if($accepted -ne ($case -ceq 'valid')){throw "Unexpected actual parent result for $case at $($failure.InvocationInfo.ScriptLineNumber): $($failure.Exception.Message)"}
  if($accepted){if($facts.gates.restored_browser_conference_two_way_decoded_audio_video -cne 'passed' -or $facts.qualification_mode -cne 'restored_conference_supplement'){throw 'No closed supplemental gate was retained.'}}
  elseif($facts.gates.ContainsKey('restored_browser_conference_two_way_decoded_audio_video')){throw 'Failure promoted a gate.'}
  $cases++
 }
}finally{
 foreach($name in $environment.Keys){[Environment]::SetEnvironmentVariable($name,$environment[$name])}
 Remove-Item -LiteralPath $owned -Recurse -Force
}
if(Test-Path -LiteralPath $owned){throw 'Owned parent-control fixture survived.'}
@{schema=1;state='passed';cases=$cases;assertions=$checks;actual_parent_source=$true;automatic_source_path_adapter=$true;installed_services_or_browser_called=$false;owned_fixture_removed=$true}|ConvertTo-Json -Compress
