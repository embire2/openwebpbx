# Source/map controls; native mode additionally uses retained actual descriptors.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent),[string]$PythonExe='python3',[switch]$NativeDescriptors,[string]$OriginalPackageRoot,[string]$NativeEvidence)
$ErrorActionPreference='Stop';$checks=0
. (Join-Path $SourceRoot 'tests/windows_updater_file_acl_observation.ps1')
. (Join-Path $SourceRoot 'tests/windows-empty-tenant-private-files.ps1')
. (Join-Path $SourceRoot 'tests/windows-signed-empty-tenant.ps1')
$nativePredicate=[scriptblock]::Create((Get-Item Function:Test-WindowsSignedTenantAclTransition).Definition)
function Verify([bool]$v){if(!$v){throw ('Signed tenant control '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
function Hash([string]$p){(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()}
function WriteJson($p,$v){[IO.File]::WriteAllText($p,($v|ConvertTo-Json -Depth 14),[Text.UTF8Encoding]::new($false))}
$work=Join-Path ([IO.Path]::GetTempPath()) ('signed-tenant-controls-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory $work|Out-Null
$marker=$false;$badProof=$false;$script:absentCalls=0
function Test-Path {param([string]$LiteralPath)
 if($LiteralPath-ceq 'C:\ProgramData\OpenWebPBX-Installation\onboarding-required'){return $script:marker}
 return Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath
}
function Test-WindowsSignedTenantAclTransition($Before,$After,$Kind,$Old,$New){return $Before-ceq 'old-source-4' -and $After-ceq 'new-source-5' -and $Kind-cin 'public_directory','inherited_public_directory','public_file'}
function Python([string[]]$Arguments){
 Verify ([IO.Path]::GetFileName($Arguments[0])-ceq 'windows_empty_tenant_private_files.py')
 $c=Get-Content -LiteralPath $Arguments[1] -Raw|ConvertFrom-Json -AsHashtable
 Verify ($c.files.Count-eq 3 -and $c.expected_host-ceq 'windowsqa.example.invalid')
 WriteJson $Arguments[2] @{schema=1;state='passed';original_policy_required=[bool]$script:badProof;p256_ready_binding=$true;exact_source_proof=$true}
}
function Maps {
 $before=@{'C:\ProgramData\OpenWebPBX\runtime.json'=@{directory=$false;acl='original-secret-SDDL';sha256=('a'*64);bytes=10}}
 foreach($p in (Get-WindowsEmptyTenantPaths).Keys){$r=@{directory=(Get-WindowsEmptyTenantPaths)[$p].EndsWith('directory');acl='old-source-4'};if(!$r.directory){$r.bytes=241;$r.sha256='b'*64};$before[$p]=$r}
 $after=@{};foreach($p in $before.Keys){$r=@{};foreach($k in $before[$p].Keys){$r[$k]=$before[$p][$k]};if((Get-WindowsEmptyTenantPaths)[$p]-cin 'public_directory','inherited_public_directory','public_file'){$r.acl='new-source-5'};$after[$p]=$r}
 return @{before=$before;after=$after}
}
function Run($m){$d=Join-Path $work ([guid]::NewGuid().ToString('N'));New-Item -ItemType Directory $d|Out-Null;Get-WindowsSignedTenantComparisonCopy $m.before $m.after 'old-package' 'new-package' 'windowsqa.example.invalid' (Join-Path $d 'proof.json')}
function Deny([scriptblock]$change){$m=Maps;& $change $m;$failed=$false;try{$null=Run $m}catch{$failed=$true};Verify $failed}
try{
 $m=Maps;$a=$m.before|ConvertTo-Json -Depth 12 -Compress;$z=$m.after|ConvertTo-Json -Depth 12 -Compress;$copy=Run $m
 foreach($p in $m.before.Keys){foreach($k in $m.before[$p].Keys){Verify ([object]::Equals($copy[$p][$k],$m.before[$p][$k]))}}
 Verify (($m.before|ConvertTo-Json -Depth 12 -Compress)-ceq $a -and ($m.after|ConvertTo-Json -Depth 12 -Compress)-ceq $z)
 foreach($p in @('C:\ProgramData\fusionpbx\tenant-domains-instance-key.pem','C:\ProgramData\OpenWebPBX\tenant-domains\ready.json','C:\ProgramData\OpenWebPBX\tenant-domains\proofs\.well-known\openwebpbx-instance\web.config')){
  foreach($k in 'bytes','sha256'){$m=Maps;$m.after[$p][$k]=if($k-ceq 'bytes'){242}else{'c'*64};$failed=$false;try{$null=Run $m}catch{$failed=$true};Verify $failed}
 }
 Deny {param($m)$m.after['C:\ProgramData\fusionpbx\tenant-domains-instance-key.pem'].acl='new-source-5'}
 Deny {param($m)$m.after['C:\ProgramData\OpenWebPBX\tenant-domains\private'].acl='new-source-5'}
 Deny {param($m)$m.before.Remove('C:\ProgramData\OpenWebPBX\tenant-domains\private')}
 Deny {param($m)$m.after.Remove('C:\ProgramData\OpenWebPBX\tenant-domains\ready.json')}
 Deny {param($m)$m.after['C:\ProgramData\OpenWebPBX\tenant-domains'].extra='unknown'}
 Deny {param($m)$m.after['C:\ProgramData\OpenWebPBX\tenant-domains'].acl='unknown-grant'}
 $marker=$true;Deny {param($m)};$marker=$false;$badProof=$true;Deny {param($m)};$badProof=$false
 foreach($case in 'unknown_add','old_bytes','old_acl','old_remove'){
  $m=Maps;switch($case){unknown_add{$m.after['C:\ProgramData\OpenWebPBX\unexpected']=@{directory=$true;acl='unknown'}}old_bytes{$m.after['C:\ProgramData\OpenWebPBX\runtime.json'].bytes=11}old_acl{$m.after['C:\ProgramData\OpenWebPBX\runtime.json'].acl='changed'}old_remove{$m.after.Remove('C:\ProgramData\OpenWebPBX\runtime.json')}}
  $copy=Run $m;$left=Join-Path $work ('before-'+$case+'.json');$right=Join-Path $work ('after-'+$case+'.json');WriteJson $left $m.before;WriteJson $right $copy
  & $PythonExe -I -B (Join-Path $SourceRoot 'tests/windows-compare-json.py') $left $right|Out-Null;Verify ($LASTEXITCODE-eq 1)
 }
 # Import the actual wait and exact caller block, not hand-copied equivalents.
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-updater-qualification.ps1'),[ref]$tokens,[ref]$errors);Verify (!$errors.Count)
 foreach($name in 'ReadQualificationTenantIdleObservation','QualificationFailureObservation','WaitActualTenantIdle','QualificationSnapshotPaths'){$n=@($ast.FindAll({param($x)$x-is [Management.Automation.Language.FunctionDefinitionAst] -and $x.Name-ceq $name},$true));Verify ($n.Count-eq 1);Invoke-Expression $n[0].Extent.Text}
 $script:enabled=$true;$script:taskState='Ready';$script:processCount=0;$script:taskResult=0;$script:runTime=[DateTime]::UtcNow;$script:missing=$false;$script:polls=0
 function Get-ScheduledTask {return @{Settings=@{Enabled=$script:enabled};State=$script:taskState}}
 function Assert-OpenWebQualificationTenantTask($Task){Verify ($null-ne $Task)}
 function Get-ScheduledTaskInfo {return @{LastTaskResult=$script:taskResult;LastRunTime=$script:runTime}}
 $script:processQueries=0;$script:missingPath=$null
 function Get-OpenWebQualificationTenantProcesses {$script:processQueries++;return $script:processCount}
 function Check([bool]$v,[string]$m){if(!$v){throw $m}}
 function Test-Path {param([string]$LiteralPath)if((Get-WindowsEmptyTenantPaths).Contains($LiteralPath)){return !$script:missing-and $LiteralPath-cne $script:missingPath};if($LiteralPath-ceq 'C:\ProgramData\OpenWebPBX-Installation\onboarding-required'){return $script:marker};return Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath}
 function Start-Sleep {$script:polls++;throw 'one bounded fixture poll'}
 WaitActualTenantIdle;Verify ($polls-eq 0)
 $validIdle=$script:qualificationTenantIdleObservation
 Verify ($validIdle.task_state-ceq 'Ready'-and $validIdle.native_process_count-eq 0-and $validIdle.last_task_result-eq 0-and $validIdle.last_run_observed-and @($validIdle.path_presence.Values|Where-Object {!$_}).Count-eq 0)
 foreach($case in 'disabled','running','queued','process','never_ran','failed_run','missing'){
  $enabled=$true;$taskState='Ready';$processCount=0;$taskResult=0;$runTime=[DateTime]::UtcNow;$missing=$false;$polls=0;$processQueries=0
  switch($case){disabled{$enabled=$false}running{$taskState='Running'}queued{$taskState='Queued'}process{$processCount=1}never_ran{$runTime=[DateTime]::MinValue}failed_run{$taskResult=1}missing{$missing=$true}}
  $failed=$false;try{WaitActualTenantIdle}catch{$failed=$true};Verify $failed;if($case-cne 'disabled'){Verify ($polls-eq 1)}
  $observed=$script:qualificationTenantIdleObservation
  if($case-ceq 'disabled'){Verify ($null-eq $observed-and $processQueries-eq 0);continue}
  Verify ($null-ne $observed)
  switch($case){
   running{Verify ($observed.task_state-ceq 'Running'-and $null-eq $observed.native_process_count-and $processQueries-eq 0)}
   queued{Verify ($observed.task_state-ceq 'Queued'-and $null-eq $observed.native_process_count-and $processQueries-eq 0)}
   process{Verify ($observed.native_process_count-eq 1-and $processQueries-eq 1)}
   never_ran{Verify (!$observed.last_run_observed)}
   failed_run{Verify ($observed.last_task_result-eq 1)}
   missing{Verify (@($observed.path_presence.Values|Where-Object {!$_}).Count-eq 8)}
  }
 }
 $missing=$false;$taskState='Ready';$processCount=0;$taskResult=0;$runTime=[DateTime]::UtcNow
 $labels=@('tenant_root','private_root','proofs_root','well_known_root','proof_root','instance_key','ready_json','proof_config');$index=0
 foreach($path in (Get-WindowsEmptyTenantPaths).Keys){
  $missingPath=$path;$failed=$false;try{WaitActualTenantIdle}catch{$failed=$true};Verify $failed
  $observed=$script:qualificationTenantIdleObservation
  Verify (@($observed.path_presence.Values|Where-Object {!$_}).Count-eq 1-and !$observed.path_presence[$labels[$index++]])
 };$missingPath=$null
 # The actual failure projector exposes only the last complete, closed sample.
 $trace='at Check, C:\private\windows-updater-qualification.ps1: line 50'+"`n"+'at WaitActualTenantIdle, C:\private\windows-updater-qualification.ps1: line 324'
 foreach($wire in $validIdle,($validIdle|ConvertTo-Json -Depth 8|ConvertFrom-Json)){
  $safe=QualificationFailureObservation $trace $null $null $null $null $null $null $wire
  Verify ($safe.tenant_idle.task_state-ceq 'Ready'-and ($safe|ConvertTo-Json -Depth 8 -Compress)-cnotmatch 'C:\\\\private|C:\\\\ProgramData')
 }
 foreach($case in 'schema','state_array','enabled_string','process_bool','process_negative','result_string','result_overflow','run_array','path_array','path_value','path_unknown','extra'){
  $bad=$validIdle|ConvertTo-Json -Depth 8|ConvertFrom-Json -AsHashtable
  switch($case){schema{$bad.schema=$true}state_array{$bad.task_state=@('Ready')}enabled_string{$bad.task_enabled='true'}process_bool{$bad.native_process_count=$false}process_negative{$bad.native_process_count=-1}result_string{$bad.last_task_result='0'}result_overflow{$bad.last_task_result=4294967296L}run_array{$bad.last_run_observed=@($true)}path_array{$bad.path_presence=@($true)}path_value{$bad.path_presence.ready_json='PRIVATE_PATH'}path_unknown{$bad.path_presence.Remove('ready_json');$bad.path_presence.PRIVATE_PATH=$true}extra{$bad.PRIVATE_PATH='PRIVATE_VALUE'}}
  Verify ($null-eq (ReadQualificationTenantIdleObservation $bad))
  $safe=QualificationFailureObservation $trace $null $null $null $null $null $null $bad;Verify (!$safe.ContainsKey('tenant_idle'))
 }
 $safe=QualificationFailureObservation 'at Check, C:\private\windows-updater-qualification.ps1: line 50' $null $null $null $null $null $null $validIdle;Verify (!$safe.ContainsKey('tenant_idle'))
 $wait=@($ast.FindAll({param($x)$x-is [Management.Automation.Language.FunctionDefinitionAst]-and $x.Name-ceq 'WaitActualTenantIdle'},$true))[0].Extent.Text
 Verify ($wait.Contains('[DateTime]::UtcNow.AddSeconds(600)')-and $wait.Contains('Start-Sleep -Milliseconds 250'))
 # The genuine encrypted observer is retained even if original Equal or a later
 # task/operator assertion refuses. Raw record names never appear in facts.
 $assigned=@($ast.FindAll({param($x)$x-is [Management.Automation.Language.AssignmentStatementAst] -and $x.Left.Extent.Text-ceq '$afterProtectedFiles'},$true));Verify ($assigned.Count-eq 1)
 $block=$assigned[0].Parent;while($block-isnot [Management.Automation.Language.StatementBlockAst]){$block=$block.Parent};$nodes=@($block.Statements);$i=0;while(![object]::ReferenceEquals($nodes[$i],$assigned[0])){$i++}
 $caller=[scriptblock]::Create((($nodes[$i..($i+5)]|ForEach-Object {$_.Extent.Text})-join "`n"));Verify ($caller.ToString().Contains('Equal $protected $normalProtectedFiles'))
 $priorSHA=$env:GITHUB_SHA;$priorRun=$env:GITHUB_RUN_ID;$env:GITHUB_SHA='e'*40;$env:GITHUB_RUN_ID='12345'
 try{
  $m=Maps;$protected=$m.before;$script:callerAfter=$m.after;$actualCandidate=$true;$package='old';$actualPackage='new';$qa=$work
  function FileSnapshot {return $script:callerAfter}
  foreach($later in $false,$true){
   $qa=Join-Path $work ([guid]::NewGuid().ToString('N'));New-Item -ItemType Directory $qa|Out-Null;$facts=@{};function Equal($Before,$After,$Label){if($script:later){throw 'original Equal refusal'}}
   $script:later=$later;$caught=$null;try{& $caller;if(!$later){throw 'later task failure'}}catch{$caught=$_}
   Verify ($null-ne $caught -and $facts.signed_empty_tenant_file_security.state-ceq 'captured' -and $facts.signed_empty_tenant_file_security.changed_count-eq 6)
   Verify (($facts|ConvertTo-Json -Depth 14 -Compress)-cnotmatch 'original-secret-SDDL|C:\\\\ProgramData')
   if(!$later){Verify ($facts.signed_empty_tenant_component.branch-ceq 'existing-public-acl4-to5' -and $facts.signed_empty_tenant_component.empty_ready_bytes_exact)}else{Verify (!$facts.signed_empty_tenant_component)}
  }
 }finally{$env:GITHUB_SHA=$priorSHA;$env:GITHUB_RUN_ID=$priorRun}
 # Route both real shared proof callsites through the actual signed helper.
 # Only the child launch is adapted; no Python worker or installed path is used.
 & {
  $router=@($ast.FindAll({param($x)$x-is [Management.Automation.Language.FunctionDefinitionAst]-and $x.Name-ceq 'Python'},$true));Verify ($router.Count-eq 1)
  $qa=Join-Path $work 'content-router';New-Item -ItemType Directory $qa|Out-Null;$root=Join-Path $work 'installed';$inputFile=Join-Path $qa 'fixture-input.json'
  $routeRoot=Join-Path $work 'router-source';New-Item -ItemType Directory $routeRoot|Out-Null
  $routerFile=Join-Path $routeRoot 'windows-updater-qualification.ps1';[IO.File]::WriteAllText($routerFile,$router[0].Extent.Text);. $routerFile
  [IO.File]::WriteAllBytes((Join-Path $routeRoot 'windows_empty_tenant_private_files.py'),[IO.File]::ReadAllBytes((Join-Path $SourceRoot 'tests/windows_empty_tenant_private_files.py')))
  $script:routeCalls=@();$script:badRouterHash=$false;$script:linkedRouterContext=$false
  function CheckedProcess([string]$Executable,[string[]]$Arguments,[string]$Label){$script:routeCalls+=@{exe=$Executable;arguments=$Arguments;label=$Label}}
  function Hash([string]$Path){if($script:badRouterHash){return '0'*64};return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
  function Get-Item {param([string]$LiteralPath,[switch]$Force)
   if($script:linkedRouterContext-and $LiteralPath-ceq $script:routerContext){return @{PSIsContainer=$false;Attributes=[IO.FileAttributes]::ReparsePoint}}
   return Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath -Force:$Force
  }
  foreach($action in 'setup','prepare-pki','request','serve','validate'){
   $script:routeCalls=@();Python $action;Verify ($routeCalls.Count-eq 1)
   $call=$routeCalls[0];Verify ($call.exe-ceq "$root\backup-runtime\python.exe"-and $call.label-ceq ('python-'+$action)-and ($call.arguments-join '|')-ceq (@('-I','-B',(Join-Path $routeRoot 'windows-updater-fixture.py'),'--input',$inputFile,'--action',$action)-join '|'))
  }
  $fixtureCalls=@($ast.FindAll({param($x)$x-is [Management.Automation.Language.CommandAst]-and $x.GetCommandName()-ceq 'Python'},$true));Verify ($fixtureCalls.Count-eq 4)
  foreach($call in $fixtureCalls){$script:routeCalls=@();Invoke-Expression $call.Extent.Text;Verify ($routeCalls.Count-eq 1-and $routeCalls[0].label-cin 'python-setup','python-prepare-pki','python-request')}
  $output=Join-Path $qa 'signed-empty-tenant-content.safe.json'
  foreach($leaf in 'windows-signed-empty-tenant.ps1','windows-empty-tenant-private-files.ps1'){
   $shared=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot ('tests/'+$leaf)),[ref]$tokens,[ref]$errors);Verify (!$errors.Count)
   $calls=@($shared.FindAll({param($x)$x-is [Management.Automation.Language.CommandAst]-and $x.GetCommandName()-ceq 'Python'},$true));Verify ($calls.Count-eq 1)
   $context=Join-Path $qa $(if($leaf-ceq 'windows-signed-empty-tenant.ps1'){'signed-empty-tenant-content-context.private.json'}else{'empty-tenant-content-context.private.json'});[IO.File]::WriteAllText($context,'{}');$ContentProofPath=$output;$script:routeCalls=@()
   $callFile=Join-Path $routeRoot $leaf;[IO.File]::WriteAllText($callFile,$calls[0].Extent.Text);. $callFile
   Verify ($routeCalls.Count-eq 1);$call=$routeCalls[0]
   Verify ($call.exe-ceq "$root\backup-runtime\python.exe"-and $call.label-ceq 'signed-empty-tenant-content'-and ($call.arguments-join '|')-ceq (@('-I','-B',(Join-Path $routeRoot 'windows_empty_tenant_private_files.py'),$context,$output)-join '|'))
  }
  $proofScript=Join-Path $routeRoot 'windows_empty_tenant_private_files.py';$script:routerContext=$context
  foreach($case in 'missing','unknown_action','extra_positional','scalar','empty','one','two','four','nested','foreign_script','foreign_context','foreign_output','occupied_output','script_hash','linked_context'){
   $value=@($proofScript,$context,$output);$script:routeCalls=@();$script:badRouterHash=$false;$script:linkedRouterContext=$false
   switch($case){missing{$value=$null}unknown_action{$value='PRIVATE_ACTION'}scalar{$value=1}empty{$value=@()}one{$value=@($proofScript)}two{$value=@($proofScript,$context)}four{$value+=@('PRIVATE_EXTRA')}nested{$value=@(@($proofScript),$context,$output)}foreign_script{$value[0]=Join-Path $PSScriptRoot 'windows-updater-fixture.py'}foreign_context{$value[1]=Join-Path $qa 'PRIVATE_CONTEXT'}foreign_output{$value[2]=Join-Path $qa 'PRIVATE_OUTPUT'}occupied_output{[IO.File]::WriteAllText($output,'occupied')}script_hash{$script:badRouterHash=$true}linked_context{$script:linkedRouterContext=$true}}
   $caught=$null;try{if($case-ceq 'extra_positional'){Python 'setup' 'PRIVATE_EXTRA'}else{Python $value}}catch{$caught=$_}
   Verify ($null-ne $caught-and $routeCalls.Count-eq 0)
   if($case-ceq 'occupied_output'){Remove-Item -LiteralPath $output}
  }
  $trace='at CheckedProcess, C:\private\windows-updater-qualification.ps1: line 231'+"`n"+'at Python, C:\private\windows-updater-qualification.ps1: line 432'
  $safe=QualificationFailureObservation $trace @{caller='CheckedProcess';label='signed-empty-tenant-content';completion='exit';exit_code=7}
  Verify ($safe.child.label-ceq 'signed-empty-tenant-content'-and $safe.child.exit_code-eq 7)
 }
 $nativeChecks=0
 if($NativeDescriptors){
  Verify ([Environment]::OSVersion.Platform-eq [PlatformID]::Win32NT)
  $evidence=Get-Content -LiteralPath $NativeEvidence -Raw|ConvertFrom-Json;$candidate=Join-Path $SourceRoot 'packaging/windows'
  foreach($row in $evidence.actual.items){
   $kinds=@{'state/tenant-domains'='public_directory';'state/tenant-domains/proofs'='inherited_public_directory';'state/tenant-domains/proofs/.well-known'='inherited_public_directory';'state/tenant-domains/proofs/.well-known/openwebpbx-instance'='public_directory';'state/tenant-domains/ready.json'='public_file';'state/tenant-domains/proofs/.well-known/openwebpbx-instance/web.config'='public_file'}
   $kind=$kinds[[string]$row.relative];if(!$kind){continue}
   $after=[string]$row.SDDL;$before=[Security.AccessControl.RawSecurityDescriptor]::new($after)
   for($j=$before.DiscretionaryAcl.Count-1;$j-ge 0;$j--){if($before.DiscretionaryAcl[$j].SecurityIdentifier.Value-ceq 'S-1-5-19'){$before.DiscretionaryAcl.RemoveAce($j)}}
   $old=$before.GetSddlForm([Security.AccessControl.AccessControlSections]::All)
   Verify (& $nativePredicate $old $after $kind $OriginalPackageRoot $candidate);$nativeChecks++
   Verify (!(& $nativePredicate $after $old $kind $OriginalPackageRoot $candidate));$nativeChecks++
   foreach($case in 'owner','group','control','mask','unknown','creator_group','deny','duplicate'){
    $bad=[Security.AccessControl.RawSecurityDescriptor]::new($after)
    switch($case){owner{$bad.Owner=[Security.Principal.SecurityIdentifier]::new('S-1-5-17')}group{$bad.Group=[Security.Principal.SecurityIdentifier]::new('S-1-5-17')}control{$bad.SetFlags([Security.AccessControl.ControlFlags]([int]$bad.ControlFlags-bxor [int][Security.AccessControl.ControlFlags]::DiscretionaryAclAutoInherited))}mask{$bad.DiscretionaryAcl[0].AccessMask=1}unknown{$bad.DiscretionaryAcl[4].SecurityIdentifier=[Security.Principal.SecurityIdentifier]::new('S-1-5-20')}creator_group{$bad.DiscretionaryAcl[4].SecurityIdentifier=[Security.Principal.SecurityIdentifier]::new('S-1-3-1')}deny{$a=$bad.DiscretionaryAcl[4];$bad.DiscretionaryAcl[4]=[Security.AccessControl.CommonAce]::new($a.AceFlags,[Security.AccessControl.AceQualifier]::AccessDenied,$a.AccessMask,$a.SecurityIdentifier,$false,$null)}duplicate{$bad.DiscretionaryAcl.InsertAce(5,$bad.DiscretionaryAcl[4])}}
    Verify (!(& $nativePredicate $old ($bad.GetSddlForm([Security.AccessControl.AccessControlSections]::All)) $kind $OriginalPackageRoot $candidate));$nativeChecks++
   }
  };Verify ($nativeChecks-eq 60)
 }
 @{state='passed';checks=$checks;native_descriptor_checks=$nativeChecks;actual_native=[bool]$NativeDescriptors;source_map_adapters=$true;no_host_product_actions=$true}|ConvertTo-Json -Compress
}finally{Remove-Item -LiteralPath $work -Recurse -Force}
