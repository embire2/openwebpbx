param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
. (Join-Path $SourceRoot 'tests/windows-hold-failure-fields.ps1')
$checks=0
function Check([bool]$Value){if(!$Value){throw ('Hold diagnostic refusal control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
function Clone($Value){return ($Value|ConvertTo-Json -Depth 20|ConvertFrom-Json)}
$peer=@{contact='registered';contact_query_failed=$false;receiver_running=$true;receiver_failure='none';registration_observed=$true;registration_code=200;requested_expires=120;accepted_expires=120;registration_age_ms=1234;new_invites=1;new_dialogs=1;acked_dialogs=1;ended_dialogs=0}
$record=[pscustomobject]@{hold_diagnostics=@{schema=1;stage='transfer_destination';elapsed_ms=20000;codes=@{invite=200;hold=200;resume=200;transfer=202};before=@{caller=$peer;first=$peer;second=$peer};after=@{caller=$peer;first=$peer;second=$peer}}}
$safe=HoldFailureFields $record;Check ($safe.hold_diagnostics.after.second.contact -ceq 'registered')
$copy=Clone $record;$copy.hold_diagnostics|Add-Member NoteProperty private_raw 'secret-never-export';$copy.hold_diagnostics.before.first|Add-Member NoteProperty authentication 'secret-never-export';Check ((HoldFailureFields $copy|ConvertTo-Json -Depth 20) -cnotmatch 'secret-never-export')
foreach($stage in 'before','initial_invite','initial_destination','initial_media','hold_request','hold_music','resume_request','resumed_audio','transfer_request','transfer_destination','transferred_audio','end_transferred_call','complete'){$copy=Clone $record;$copy.hold_diagnostics.stage=$stage;Check ((HoldFailureFields $copy).hold_diagnostics.stage -ceq $stage)}
foreach($bad in 'TRANSFER_DESTINATION','private-never-export',1,$null,@('transfer_destination')){$copy=Clone $record;$copy.hold_diagnostics.stage=$bad;Check ((HoldFailureFields $copy).Count -eq 0)}
foreach($field in 'schema','elapsed_ms'){
 foreach($bad in '1',$true,@(1),-1,[double]::NaN){$copy=Clone $record;$copy.hold_diagnostics.$field=$bad;Check ((HoldFailureFields $copy).Count -eq 0)}
}
foreach($code in 'invite','hold','resume','transfer'){
 foreach($bad in '200',$true,@(200),-1,700,$null){$copy=Clone $record;$copy.hold_diagnostics.codes.$code=$bad;Check ((HoldFailureFields $copy).Count -eq 0)}
}
foreach($phase in 'before','after'){foreach($name in 'caller','first','second'){
 foreach($field in 'contact_query_failed','receiver_running','registration_observed'){foreach($bad in 'true',1,@($true),$null){$copy=Clone $record;$copy.hold_diagnostics.$phase.$name.$field=$bad;Check ((HoldFailureFields $copy).Count -eq 0)}}
 foreach($field in 'registration_code','requested_expires','accepted_expires','registration_age_ms','new_invites','new_dialogs','acked_dialogs','ended_dialogs'){foreach($bad in '1',$true,@(1),[double]::NaN,$null){$copy=Clone $record;$copy.hold_diagnostics.$phase.$name.$field=$bad;Check ((HoldFailureFields $copy).Count -eq 0)}}
 foreach($field in 'contact','receiver_failure'){foreach($bad in 'private-never-export',1,@('registered'),$null){$copy=Clone $record;$copy.hold_diagnostics.$phase.$name.$field=$bad;Check ((HoldFailureFields $copy).Count -eq 0)}}
}}
$minimal=HoldFailureFields @{hold_diagnostics=@{schema=1;stage='hold_music';snapshot_unavailable=$true;private='secret-never-export'}};Check ($minimal.hold_diagnostics.snapshot_unavailable -is [bool] -and $minimal.hold_diagnostics.snapshot_unavailable -and $minimal.hold_diagnostics.Count -eq 3)
$cases=@(
 @{case='native_hold_diagnostic_immediate';passed=$true;correlation=.9;held_seconds=8},
 @{case='native_hold_diagnostic_natural_expiry_observed';passed=$true;requested_expires=120;negotiated_expires=@(120,120,120);no_product_registration_change=$true},
 @{case='native_hold_diagnostic_reregistered';passed=$true;correlation=.9;held_seconds=8},
 @{case='native_hold_diagnostic_identical_tuple_reregistered';passed=$true;exact_tuples_preserved=$true;all_three_actual_contacts_returned=$true;no_product_registration_change=$true})
AssertNativeHoldDiagnosticCases $cases;Check $true
foreach($index in 0,1,2,3){$copy=Clone $cases;$copy[$index].passed=$false;$failed=$false;try{AssertNativeHoldDiagnosticCases $copy}catch{$failed=$true};Check $failed}
$failed=$false;try{AssertNativeHoldDiagnosticCases @($cases+$cases[0])}catch{$failed=$true};Check $failed
foreach($value in @(.74999,'0.9',$true,[double]::NaN,[double]::PositiveInfinity)){$copy=Clone $cases;$copy[0].correlation=$value;$failed=$false;try{AssertNativeHoldDiagnosticCases $copy}catch{$failed=$true};Check $failed}
foreach($value in @(0,181,'120',$true)){$copy=Clone $cases;$copy[1].negotiated_expires=@(120,$value,120);$failed=$false;try{AssertNativeHoldDiagnosticCases $copy}catch{$failed=$true};Check $failed}
$tokens=$null;$errors=$null;$suitePath=Join-Path $SourceRoot 'tests/windows-suite.ps1';$ast=[Management.Automation.Language.Parser]::ParseFile($suitePath,[ref]$tokens,[ref]$errors);Check ($errors.Count -eq 0)
$nodes=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'AssertHoldDiagnosticsMode'},$true));Check ($nodes.Count -eq 1);Invoke-Expression $nodes[0].Extent.Text
foreach($hold in $false,$true){foreach($native in $false,$true){foreach($upgrade in $false,$true){foreach($backup in $false,$true){foreach($provided in '', 'FOREIGN'){
 $allowed=!$hold -or ($native -and !$upgrade -and !$backup -and !$provided);$failed=$false;try{AssertHoldDiagnosticsMode $hold $native $upgrade $backup $provided}catch{$failed=$true};Check ($failed -eq !$allowed)
}}}}}
$text=[IO.File]::ReadAllText($suitePath);$begin=$text.IndexOf('# BEGIN qualification-gate-routing');$end=$text.IndexOf('# END qualification-gate-routing');Check ($begin -ge 0 -and $end -gt $begin);$route=[scriptblock]::Create($text.Substring($begin,$end-$begin))
function NativeAcceptanceHook {return $script:report}
$UpgradeDiagnosticsOnly=$false;$BackupsDiagnosticsOnly=$false;$NativeDiagnosticsOnly=$true;$SkipPhoneHealthForNativeDiagnostics=$false;$work='UNUSED'
foreach($HoldDiagnosticsOnly in $false,$true){
 $script:report=[pscustomobject]@{native_factory_empty_before_fixture=$true;diagnostic_case='hold';full_release_eligible=$false;owner_eligible=$false;public_eligible=$false;restore_eligible=$false;signed_upgrade_eligible=$false;gates=@{hold_diagnostic='passed';meeting_browser='passed';native_clock='passed';native_providers='passed';native_call_me_back='passed'}}
 $facts=@{state='running';gates=@{native_sip_audio='unqualified';meeting_browser='unqualified';native_clock='unqualified';native_providers='unqualified';native_call_me_back='unqualified';backups='unqualified'}};. $route
 if($HoldDiagnosticsOnly){foreach($gate in 'native_sip_audio','meeting_browser','native_clock','native_providers','native_call_me_back'){Check ($facts.gates[$gate] -ceq 'unqualified')};Check ($facts.hold_diagnostic -ceq 'passed' -and $facts.state -ceq 'partial')}
 else{foreach($gate in 'native_sip_audio','meeting_browser','native_clock','native_providers','native_call_me_back'){Check ($facts.gates[$gate] -ceq 'passed')}}
}
$HoldDiagnosticsOnly=$true
foreach($field in 'full_release_eligible','owner_eligible','public_eligible','restore_eligible','signed_upgrade_eligible','native_factory_empty_before_fixture'){
 foreach($bad in @($(if($field -ceq 'native_factory_empty_before_fixture'){$false}else{$true}),'false',0,$null,@($false))){$copy=$script:report.PSObject.Copy();$copy.$field=$bad;$old=$script:report;$script:report=$copy;$facts=@{state='running';gates=@{}};$failed=$false;try{. $route}catch{$failed=$true}finally{$script:report=$old};Check $failed}
}
[ordered]@{schema=1;state='passed';checks=$checks;actual_source_projection_and_routing=$true;server_or_call_actions=$false}|ConvertTo-Json -Compress
