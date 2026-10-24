# SPDX-License-Identifier: AGPL-3.0-or-later
# Actual mode, routing, closed receipt and export controls; transport/OS are not run.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
. (Join-Path $SourceRoot 'tests/windows-threecx-suite-mode.ps1')
$script:checks=0
function Check([bool]$Value){if(!$Value){throw ('Import wiring control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
function Refuses([scriptblock]$Action){$failed=$false;try{& $Action}catch{$failed=$true};Check $failed}
function Clone($Value){return ($Value|ConvertTo-Json -Depth 20|ConvertFrom-Json)}
$suite=Join-Path $SourceRoot 'tests/windows-suite.ps1';$text=[IO.File]::ReadAllText($suite);$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($suite,[ref]$tokens,[ref]$errors);Check ($errors.Count -eq 0)
function SelectFunction([string]$Name){$found=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Name},$true));Check ($found.Count -eq 1);return $found[0].Extent.Text}
foreach($name in 'AssertNativeDiagnosticsMode','AssertFactoryNativeDiagnosticsMode','InvokeSuitePhoneHealthQualification'){Invoke-Expression (SelectFunction $name)}
$sha='a'*40;$ref='embire2/openwebpbx/.github/workflows/windows-suite.yml@refs/heads/qualification'
$valid=@($true,$true,$true,$false,$false,$false,$false,'','40005106134','39903796050','39823852979','','')
AssertThreecxImportSuiteMode @valid;Check $true
foreach($native in $false,$true){foreach($skip in $false,$true){foreach($hold in $false,$true){foreach($upgrade in $false,$true){foreach($backup in $false,$true){foreach($fallback in $false,$true){
 $allowed=$native -and $skip -and !$hold -and !$upgrade -and !$backup -and !$fallback
 $failed=$false;try{AssertThreecxImportSuiteMode $true $native $skip $hold $upgrade $backup $fallback '' '40005106134' '39903796050' '39823852979' '' ''}catch{$failed=$true};Check ($failed -eq !$allowed)
 AssertThreecxImportSuiteMode $false $native $skip $hold $upgrade $backup $fallback 'foreign-package' 'wrong' 'wrong' 'wrong' 'pin' 'pin';Check $true
}}}}}}
foreach($index in 7,8,9,10,11,12){$values=$valid.Clone();$values[$index]='foreign';Refuses {AssertThreecxImportSuiteMode @values}}
foreach($index in 8,9,10){$values=$valid.Clone();$values[$index]='';Refuses {AssertThreecxImportSuiteMode @values}}
AssertNativeDiagnosticsMode $true $false $false $false '' $ref $sha $sha;Check $true
Refuses {AssertNativeDiagnosticsMode $true $false $false $false '' $ref ('b'*40) $sha}
# The original factory-skip predicate remains unchanged and still refuses replay.
Refuses {AssertFactoryNativeDiagnosticsMode $true $true '40005106134' ''}
AssertFactoryNativeDiagnosticsMode $true $true '' '';Check $true
function ReplayFactsFixture {
 return @{state='running';gates=@{fresh='passed';web_readiness='passed';phone_health='unqualified';native_sip_audio='unqualified';meeting_browser='unqualified';native_clock='unqualified';native_providers='unqualified';native_call_me_back='unqualified';backups='unqualified';threecx_import_diagnostic='unqualified'};
 artifacts=@{native_run='39903796050';engine_run='39823852979';candidate_sha256='d0799878b04a8564c4ae074a34d9a3cf809432eb39230f8edf4011f4bd55042e'};
 replay=@{original_run='40005106134';exact_zip_sha256='d0799878b04a8564c4ae074a34d9a3cf809432eb39230f8edf4011f4bd55042e';windows_runtime_source_identical=$true;runtime_overlays=$false};checks=@()}
}
AssertThreecxImportAcceptedReplay (ReplayFactsFixture);Check $true
foreach($field in 'original_run','exact_zip_sha256','windows_runtime_source_identical','runtime_overlays','producer_provenance'){
 $fixture=ReplayFactsFixture;$fixture.replay[$field]='bad';Refuses {AssertThreecxImportAcceptedReplay $fixture}
}
foreach($field in 'native_run','engine_run','candidate_sha256'){$fixture=ReplayFactsFixture;$fixture.artifacts[$field]='bad';Refuses {AssertThreecxImportAcceptedReplay $fixture}}
$work=Join-Path ([IO.Path]::GetTempPath()) ('openweb-threecx-wiring-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($work)
try{
 $facts=ReplayFactsFixture;InvokeThreecxImportEmptyFactory $facts $true $true $true $false $work
 Check ($facts.native_factory_phone_health_skipped -is [bool] -and $facts.native_factory_phone_health_skipped)
 Check ($facts.native_factory_fresh_package -is [bool] -and !$facts.native_factory_fresh_package)
 Check ($facts.threecx_accepted_replay_new_installation -is [bool] -and $facts.threecx_accepted_replay_new_installation)
 Check (!$facts.release_eligible -and !$facts.owner_transaction_eligible)
 foreach($case in 'validation','native','skip','hold','fresh','web','failure','report','replay'){
  $facts=ReplayFactsFixture;$validated=$true;$native=$true;$skip=$true;$hold=$false
  switch($case){validation{$validated=$false};native{$native=$false};skip{$skip=$false};hold{$hold=$true};fresh{$facts.gates.fresh='pending'};web{$facts.gates.web_readiness='failed'};failure{$facts.phone_health_failure=@{failed=$true}};report{[IO.File]::WriteAllText((Join-Path $work 'phone-health-native.json'),'{}')};replay{$facts.replay.original_run='other'}}
  Refuses {InvokeThreecxImportEmptyFactory $facts $validated $native $skip $hold $work};Check (!$facts.ContainsKey('native_factory_phone_health_skipped'))
  if(Test-Path -LiteralPath (Join-Path $work 'phone-health-native.json')){Remove-Item -LiteralPath (Join-Path $work 'phone-health-native.json')}
 }
 $caseNames=@('threecx_https_multipart_csrf_preview','threecx_https_import_original_credentials_media','threecx_imported_sip_original_credentials','threecx_imported_direct_decoded_two_way','threecx_imported_ring_group_decoded_two_way','threecx_imported_peer_cleanup')
 $good=Clone @{schema=1;state='passed';diagnostic_case='threecx_import';native_factory_empty_before_fixture=$true;threecx_upload_cleanup=$true;
  full_release_eligible=$false;owner_eligible=$false;public_eligible=$false;restore_eligible=$false;signed_upgrade_eligible=$false;
  checks=@($caseNames|ForEach-Object {@{case=$_;passed=$true}});
  gates=@{native_sip_audio='pending';meeting_browser='pending';native_clock='pending';native_providers='pending';native_call_me_back='pending';smtp='pending';notification_store='pending';cleanup='passed';public_acme='unqualified';physical_devices='unqualified';carrier='unqualified';android_hardware='unqualified';ui_render='unqualified';threecx_import_diagnostic='passed'};
  cleanup='Original factory rows/contacts/identity/profile/config/certificate binding restored; owned CA/leaf and private probe task removed'}
 $safe=ReadSuiteThreecxImportDiagnostic $good;Check ($safe.state -ceq 'passed' -and $safe.cases.Count -eq 6)
 $copy=Clone $good;$copy|Add-Member NoteProperty private_password 'NEVER_EXPORT';$safe=ReadSuiteThreecxImportDiagnostic $copy;Check (($safe|ConvertTo-Json -Depth 8) -cnotmatch 'NEVER_EXPORT|private_password')
 foreach($field in 'full_release_eligible','owner_eligible','public_eligible','restore_eligible','signed_upgrade_eligible'){
  foreach($value in $true,0,'false',$null){$copy=Clone $good;$copy.$field=$value;Refuses {ReadSuiteThreecxImportDiagnostic $copy|Out-Null}}
 }
 foreach($field in 'native_factory_empty_before_fixture','threecx_upload_cleanup'){
  foreach($value in $false,1,'true',$null){$copy=Clone $good;$copy.$field=$value;Refuses {ReadSuiteThreecxImportDiagnostic $copy|Out-Null}}
 }
 foreach($field in $good.gates.PSObject.Properties.Name){$copy=Clone $good;$copy.gates.$field='WRONG';Refuses {ReadSuiteThreecxImportDiagnostic $copy|Out-Null}}
 for($index=0;$index -lt 6;$index++){
  $copy=Clone $good;$copy.checks[$index].passed=$false;Refuses {ReadSuiteThreecxImportDiagnostic $copy|Out-Null}
  $copy=Clone $good;$copy.checks[$index]|Add-Member NoteProperty password 'NEVER_EXPORT';Refuses {ReadSuiteThreecxImportDiagnostic $copy|Out-Null}
 }
 $copy=Clone $good;$copy.cleanup='failed';Refuses {ReadSuiteThreecxImportDiagnostic $copy|Out-Null}
 $copy=Clone $good;$copy.checks+=@('NEVER_EXPORT');Refuses {ReadSuiteThreecxImportDiagnostic $copy|Out-Null}
 $copy=Clone $good;$copy.checks+=@('Normal generated-factory login bcrypt12-to-10 rehash proved with unchanged password, then original hash restored during cleanup');ReadSuiteThreecxImportDiagnostic $copy|Out-Null;Check $true
 # Execute the actual suite route with only an acceptance-result adapter.
 $begin=$text.IndexOf('# BEGIN qualification-gate-routing');$end=$text.IndexOf('# END qualification-gate-routing');Check ($begin -ge 0 -and $end -gt $begin)
 $route=[scriptblock]::Create($text.Substring($begin,$end-$begin))
 function NativeAcceptanceHook {return $script:report}
 function Start-SuiteRecoveryPki {throw 'No recovery hook is permitted for import diagnostics.'}
 function AcceptanceHook {throw 'No upgrade hook is permitted for import diagnostics.'}
 function LoopbackSftp {throw 'No backup hook is permitted for import diagnostics.'}
 $ThreecxImportOnly=$true;$NativeDiagnosticsOnly=$true;$SkipPhoneHealthForNativeDiagnostics=$true;$HoldDiagnosticsOnly=$false;$UpgradeDiagnosticsOnly=$false;$BackupsDiagnosticsOnly=$false;$ReplaySuiteRunId='40005106134'
 $script:report=$good;$facts=ReplayFactsFixture;. $route
 Check ($facts.state -ceq 'partial' -and $facts.gates.threecx_import_diagnostic -ceq 'passed')
 foreach($gate in 'native_sip_audio','meeting_browser','native_clock','native_providers','native_call_me_back','backups'){Check ($facts.gates[$gate] -ceq 'unqualified')}
 Check (!$facts.ContainsKey('native_cdr_background_import'))
 $script:report=Clone $good;$script:report.threecx_upload_cleanup=$false;$facts=ReplayFactsFixture;Refuses {. $route};Check ($facts.gates.threecx_import_diagnostic -ceq 'unqualified')
 # Execute actual candidate-export branch and private-input bool branch.
 $exports=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.StartsWith('if($ThreecxImportOnly){AssertThreecxImportAcceptedReplay ')},$true));Check ($exports.Count -eq 1)
 $script:exportCalls=0;function ExportOriginalCandidate($Release){$script:exportCalls++}
 $facts=ReplayFactsFixture;$ThreecxImportOnly=$true;Invoke-Expression $exports[0].Extent.Text;Check ($exportCalls -eq 0)
 $ThreecxImportOnly=$false;Invoke-Expression $exports[0].Extent.Text;Check ($exportCalls -eq 1)
 $ThreecxImportOnly=$true;$facts.replay.exact_zip_sha256='bad';Refuses {Invoke-Expression $exports[0].Extent.Text};Check ($exportCalls -eq 1)
 $inputBranches=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.StartsWith('if($ThreecxImportOnly){$acceptance.threecx_import_only=')},$true));Check ($inputBranches.Count -eq 1)
 foreach($ThreecxImportOnly in $false,$true){$acceptance=@{schema=1};Invoke-Expression $inputBranches[0].Extent.Text;if($ThreecxImportOnly){Check ($acceptance.threecx_import_only -is [bool] -and $acceptance.threecx_import_only)}else{Check (!$acceptance.ContainsKey('threecx_import_only'))}}
 $workflow=[IO.File]::ReadAllText((Join-Path $SourceRoot '.github/workflows/windows-suite.yml'))
 Check ($workflow.Contains("      threecx_import_only:`n        description:") -and $workflow.Contains('THREECX_IMPORT_ONLY: ${{ inputs.threecx_import_only }}'))
 Check ($workflow.Contains('if: ${{ always() && !inputs.threecx_import_only }}'))
 Check ($workflow.Contains("if(`$env:THREECX_IMPORT_ONLY -ceq 'true'){`$producerOptions.ThreecxImportOnly=`$true}"))
 Check ($text.IndexOf('AssertThreecxImportSuiteMode $ThreecxImportOnly') -lt $text.IndexOf('PrivateDirectory $work'))
 $inputBlocks=@([regex]::Matches($workflow,'(?m)^      threecx_import_only:\r?\n(?:        [^\r\n]+\r?\n){4}'));Check ($inputBlocks.Count -eq 1)
 Check ($inputBlocks[0].Value.Contains('        default: false') -and $inputBlocks[0].Value.Contains('        type: boolean'))
 $envLines=@($workflow.Split("`n")|Where-Object {$_.Trim().StartsWith('if($env:THREECX_IMPORT_ONLY')});Check ($envLines.Count -eq 2)
 $oldInput=$env:THREECX_IMPORT_ONLY
 try{
  foreach($value in @($null,'','false','true','False','TRUE','1','0','yes','true ')){
   $env:THREECX_IMPORT_ONLY=$value;$producerOptions=@{};$failed=$false
   try{foreach($line in $envLines){Invoke-Expression $line.Trim()}}catch{$failed=$true}
   Check ($failed -eq ($value -cnotin @($null,'','false','true')))
   if(!$failed){Check ($producerOptions.ContainsKey('ThreecxImportOnly') -eq ($value -ceq 'true'));if($value -ceq 'true'){Check ($producerOptions.ThreecxImportOnly -is [bool] -and $producerOptions.ThreecxImportOnly)}}
  }
 }finally{if($null -eq $oldInput){Remove-Item Env:\THREECX_IMPORT_ONLY -ErrorAction SilentlyContinue}else{$env:THREECX_IMPORT_ONLY=$oldInput}}
 # Default/false compatibility through the actual entire route. Only external
 # hooks are adapters; the original typed CDR acceptance function executes.
 Invoke-Expression (SelectFunction 'ReadSuiteCdrBackgroundImport')
 $cdr=@{case='native_localservice_cdr_background_import';passed=$true;matched_cdr_rows=1;answered_cdr_rows=1;history_rows=2;history_owner_rows=2;polls=1;elapsed_seconds=0.1}
 foreach($flag in 'actual_background_import','actual_localservice_identity','backend_pid_unchanged','read_only_observer','no_explicit_importer','before_system_drain','exact_call_domain_correlation','history_sources_exact','spool_absent'){$cdr[$flag]=$true}
 $full=Clone @{state='passed';checks=@($cdr);gates=@{meeting_browser='passed';native_clock='passed';native_providers='passed';native_call_me_back='passed'}}
 $backupStub=Join-Path $work 'backups.ps1';[IO.File]::WriteAllText($backupStub,"param(`$PackageRoot,`$AdminEmail,`$AdminPassword,[switch]`$DisposableFactory,`$SftpConfig)`n`$trace.Add('backups')")
 [void][IO.Directory]::CreateDirectory((Join-Path $work 'backup-qualification'))
 [IO.File]::WriteAllText((Join-Path $work 'backup-qualification/report.json'),'{"state":"passed","fully_qualified":true,"checks":[]}')
 function Join-Path([string]$Path,[string]$ChildPath){if($ChildPath -ceq 'windows-backups.ps1'){return $backupStub};return [IO.Path]::Combine($Path,$ChildPath)}
 function NativeAcceptanceHook {$trace.Add('native');return $script:report}
 function Start-SuiteRecoveryPki {param($PackageRoot,$SourceRoot,$Work)$trace.Add('pki');return @{owned=$true}}
 function AcceptanceHook {$trace.Add('upgrade');return [pscustomobject]@{gates=@{direct_113_helper_reapply='passed'}}}
 function LoopbackSftp {$trace.Add('sftp');return 'fictional'}
 $NativeDiagnosticsOnly=$false;$SkipPhoneHealthForNativeDiagnostics=$false;$HoldDiagnosticsOnly=$false;$UpgradeDiagnosticsOnly=$false;$BackupsDiagnosticsOnly=$false;$ReplaySuiteRunId='';$state=$work;$source=$SourceRoot;$admin='fictional';$password='fictional';$PackageRoot='fictional'
 foreach($variant in 'false','absent'){
  $trace=[Collections.Generic.List[string]]::new();$script:report=$full;$facts=ReplayFactsFixture;$facts.gates.Remove('threecx_import_diagnostic')
  if($variant -ceq 'false'){$ThreecxImportOnly=$false;. $route}else{
   # Bind the actual suite parameters with the new switch absent. This is
   # independent of an enabled diagnostic switch in the invoking CI parent.
   $ThreecxImportOnly=$true;$defaultRoute=[scriptblock]::Create($ast.ParamBlock.Extent.Text+"`n. `$route");& $defaultRoute
  }
  Check (($trace -join '|') -ceq 'native|pki|upgrade|sftp|backups')
  Check ($facts.gates.native_sip_audio -ceq 'passed' -and $facts.gates.backups -ceq 'passed' -and $facts.native_cdr_background_import.case -ceq 'native_localservice_cdr_background_import')
  Check (!$facts.ContainsKey('threecx_import_diagnostic') -and !$facts.gates.ContainsKey('threecx_import_diagnostic'))
 }
 $ThreecxImportOnly=$false;$trace=[Collections.Generic.List[string]]::new();$script:report=Clone $full;$script:report.checks=@();$facts=ReplayFactsFixture
 Refuses {. $route};Check (($trace -join '|') -ceq 'native' -and $facts.gates.native_sip_audio -ceq 'unqualified')
 $holdCalls=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.CommandElements.Count -gt 0 -and $node.CommandElements[0] -is [Management.Automation.Language.ScriptBlockExpressionAst] -and $node.Extent.Text.Contains('windows_hold_diagnostics_controls.ps1')},$true))
 Check ($holdCalls.Count -eq 1)
 $source=$SourceRoot
 foreach($ThreecxImportOnly in $false,$true){Invoke-Expression $holdCalls[0].Extent.Text;Check $?}
}finally{[IO.Directory]::Delete($work,$true)}
@{state='passed';checks=$script:checks;actual_source_guards_routing_receipts=$true;native_windows=$false}|ConvertTo-Json -Compress
