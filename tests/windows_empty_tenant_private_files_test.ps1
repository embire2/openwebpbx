# Pure map/outer-transport controls. ACL/content adapters are explicit here;
# native descriptor controls and real-P256 byte controls are separate.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent),[string]$PythonExe='python3')
$ErrorActionPreference='Stop';$checks=0
. (Join-Path $SourceRoot 'tests/windows_updater_file_acl_observation.ps1')
. (Join-Path $SourceRoot 'tests/windows-empty-tenant-private-files.ps1')
function Verify([bool]$Value){if(!$Value){throw ('Empty tenant map control '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
function Test-WindowsEmptyTenantAcl([string]$Sddl,[string]$Kind,[string]$PackageRoot){return $Sddl-ceq 'fixture-contract'}
function WriteJson([string]$Path,$Value){$Value|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $Path -Encoding utf8}
$work=Join-Path ([IO.Path]::GetTempPath()) ('openweb-empty-tenant-map-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory $work|Out-Null
$marker=$false;$badProof=$false;$calls=0
function Test-Path {param([string]$LiteralPath)
 if($LiteralPath-ceq 'C:\ProgramData\OpenWebPBX-Installation\onboarding-required'){return $script:marker}
 return Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath
}
function Python([string[]]$Arguments){
 $script:calls++;Verify ([IO.Path]::GetFileName($Arguments[0])-ceq 'windows_empty_tenant_private_files.py')
 $context=Get-Content -LiteralPath $Arguments[1] -Raw|ConvertFrom-Json -AsHashtable
 Verify ($context.files.Count-eq 3 -and $context.expected_host-ceq 'windowsqa.example.invalid')
 WriteJson $Arguments[2] @{schema=1;state='passed';original_policy_required=[bool]$script:badProof;p256_ready_binding=$true;exact_source_proof=$true}
}
function Maps {
 $before=@{'C:\ProgramData\OpenWebPBX\runtime.json'=@{directory=$false;acl='original-full-SDDL';sha256=('a'*64);bytes=10}}
 $after=@{};foreach($p in $before.Keys){$after[$p]=@{};foreach($k in $before[$p].Keys){$after[$p][$k]=$before[$p][$k]}}
 $paths=Get-WindowsEmptyTenantPaths
 foreach($p in $paths.Keys){$row=@{directory=$paths[$p].EndsWith('directory');acl='fixture-contract'};if(!$row.directory){$row.bytes=241;$row.sha256='b'*64};$after[$p]=$row}
 return @{before=$before;after=$after}
}
function Run($Maps){
 $d=Join-Path $work ([guid]::NewGuid().ToString('N'));New-Item -ItemType Directory $d|Out-Null
 Get-WindowsEmptyTenantComparisonCopy $Maps.before $Maps.after 'private-source-fixture' 'windowsqa.example.invalid' (Join-Path $d 'proof.json')
}
function Deny([scriptblock]$Change){$m=Maps;& $Change $m;$refused=$false;try{$null=Run $m}catch{$refused=$true};Verify $refused}
try{
 $m=Maps;$beforeRaw=$m.before|ConvertTo-Json -Depth 12 -Compress;$afterRaw=$m.after|ConvertTo-Json -Depth 12 -Compress
 $copy=Run $m;Verify ($copy.Count-eq 1 -and $copy.ContainsKey('C:\ProgramData\OpenWebPBX\runtime.json'));Verify (($m.before|ConvertTo-Json -Depth 12 -Compress)-ceq $beforeRaw -and ($m.after|ConvertTo-Json -Depth 12 -Compress)-ceq $afterRaw)
 # Every old entry remains in the comparison copy; original comparer still
 # rejects old bytes/metadata even when all eight new entries are legitimate.
 foreach($field in 'acl','sha256','bytes','directory'){
  $m=Maps;$old='C:\ProgramData\OpenWebPBX\runtime.json';$m.after[$old][$field]=switch($field){acl{'changed-SDDL'}sha256{'c'*64}bytes{11}directory{$true}}
  $copy=Run $m
  $left=Join-Path $work 'before.json';$right=Join-Path $work 'after.json';WriteJson $left $m.before;WriteJson $right $copy
  & $PythonExe -I -B (Join-Path $SourceRoot 'tests/windows-compare-json.py') $left $right|Out-Null;Verify ($LASTEXITCODE-eq 1)
 }
 $m=Maps;$m.after.Remove('C:\ProgramData\OpenWebPBX\runtime.json');$copy=Run $m
 WriteJson (Join-Path $work 'removed-before.json') $m.before;WriteJson (Join-Path $work 'removed-after.json') $copy
 & $PythonExe -I -B (Join-Path $SourceRoot 'tests/windows-compare-json.py') (Join-Path $work 'removed-before.json') (Join-Path $work 'removed-after.json')|Out-Null;Verify ($LASTEXITCODE-eq 1)
 Deny {param($m)$m.after['C:\ProgramData\OpenWebPBX\unknown-file']=@{directory=$false;acl='fixture-contract';sha256=('b'*64);bytes=1}}
 Deny {param($m)$m.after.Remove('C:\ProgramData\OpenWebPBX\tenant-domains\private')}
 Deny {param($m)$p='C:\ProgramData\OpenWebPBX\tenant-domains\private';$m.before[$p]=$m.after[$p]}
 Deny {param($m)$m.after['C:\ProgramData\OpenWebPBX\tenant-domains'].acl='unknown-grant'}
 Deny {param($m)$m.after['C:\ProgramData\OpenWebPBX\tenant-domains'].extra='unknown-field'}
 Deny {param($m)$m.after['C:\ProgramData\fusionpbx\tenant-domains-instance-key.pem'].bytes=0}
 Deny {param($m)$m.after['C:\ProgramData\fusionpbx\tenant-domains-instance-key.pem'].sha256='not-a-hash'}
 Deny {param($m)$m.after['C:\ProgramData\OpenWebPBX\tenant-domains\ready.json'].directory=$true}
 $marker=$true;Deny {param($m)};$marker=$false
 $badProof=$true;Deny {param($m)};$badProof=$false
 $manual=[IO.File]::ReadAllText((Join-Path $SourceRoot 'tests/windows-upgrade-acceptance.ps1'))
 $start=$manual.IndexOf('$emptyTenantAdmitted=$false');$stop=$manual.IndexOf("  `$BaseVersion='1.0.21';`$CanaryVersion='1.0.22'",$start);Verify ($start-gt 0 -and $stop-gt $start)
 $section=$manual.Substring($start,$stop-$start)
 Verify ($section.IndexOf('Get-WindowsUpdaterAclObservation $private21 $private22')-lt $section.IndexOf('Get-WindowsEmptyTenantComparisonCopy'))
 Verify ($section.IndexOf('Get-WindowsEmptyTenantComparisonCopy')-lt $section.IndexOf('Equal $private21 $privateComparison'))
 Verify ($section.Contains("state-cne 'captured'") -and $section.Contains('throw $comparisonPrimary'))
 Verify ($section.Contains('$report.file_security=$privateSecurityObservation') -and $section.Contains('prior_failed_CI_paths_known=$false'))
 # Exercise the actual report-read/retain/throw caller, not a copied adapter.
 $tokens=$null;$errors=$null;$suiteAst=[Management.Automation.Language.Parser]::ParseInput($manual,[ref]$tokens,[ref]$errors)
 # $manual above is the manual hook; use the actual outer suite for retention.
 $suiteText=[IO.File]::ReadAllText((Join-Path $SourceRoot 'tests/windows-suite.ps1'))
 $suiteAst=[Management.Automation.Language.Parser]::ParseInput($suiteText,[ref]$tokens,[ref]$errors);Verify (!$errors.Count)
 $read=@($suiteAst.FindAll({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-ceq 'Read-EmptyTenantInitializationComponent'},$true));Verify ($read.Count-eq 1);Invoke-Expression $read[0].Extent.Text
 $taskAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-updater-qualification.ps1'),[ref]$tokens,[ref]$errors)
 $labels=@($taskAst.FindAll({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-ceq 'QualificationSnapshotPaths'},$true));Verify ($labels.Count-eq 1);Invoke-Expression $labels[0].Extent.Text
 $assignment=@($suiteAst.FindAll({param($n)$n-is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text-ceq '$transition' -and $n.Right.Extent.Text.Contains('Get-Content -LiteralPath $transitionReport')},$true));Verify ($assignment.Count-eq 1)
 $block=$assignment[0].Parent;while($block-isnot [Management.Automation.Language.StatementBlockAst]){$block=$block.Parent}
 $nodes=@($block.Statements);$index=0;while(![object]::ReferenceEquals($nodes[$index],$assignment[0])){$index++}
 $caller=[scriptblock]::Create((($nodes[$index..($index+5)]|ForEach-Object {$_.Extent.Text})-join "`n"))
 Verify ($caller.ToString().Contains('Read-EmptyTenantInitializationComponent') -and $caller.ToString().Contains('throw $transitionFailure') -and $caller.ToString().Contains('component is invalid'))
 $priorQA=$env:GITHUB_SHA;$priorRun=$env:GITHUB_RUN_ID
 try{
  $env:GITHUB_SHA='d'*40;$env:GITHUB_RUN_ID='12345678'
  $m=Maps;$originalOnly=@{};$addedOnly=@{};foreach($path in (Get-WindowsEmptyTenantPaths).Keys){$addedOnly[$path]=$m.after[$path]}
  $encrypted=Get-WindowsUpdaterAclObservation $originalOnly $addedOnly;Verify ($encrypted.state-ceq 'captured' -and $encrypted.changed_count-eq 8)
  $model=@{schema=1;source_model='first-empty-tenant-worker';new_directories=5;new_files=3;original_private_entries_exact=$true;group_policy='valid SID metadata; no group-relative grants';prior_failed_CI_paths_known=$false}
  $valid=@{state='passed';empty_tenant_initialization=$model;file_security=$encrypted;raw_private_secret='DO_NOT_EXPOSE_THIS_RAW_REPORT'}
  function RememberHookFailure($Record){$script:rememberCalls++}
  $transitionReport=Join-Path $work 'transition-fixture.json'
  foreach($laterFailure in $false,$true){
   $v=$valid|ConvertTo-Json -Depth 14|ConvertFrom-Json -AsHashtable;if($laterFailure){$v.state='failed'};WriteJson $transitionReport $v
   $facts=@{};$script:rememberCalls=0;$transitionFailure=if($laterFailure){[InvalidOperationException]::new('original-later-task-failure')}else{$null};$caught=$null
   try{& $caller}catch{$caught=$_}
   Verify ($facts.public21_empty_tenant_initialization.file_security.encrypted.ciphertext-ceq $encrypted.encrypted.ciphertext)
   Verify (($facts|ConvertTo-Json -Depth 14 -Compress)-cnotmatch 'DO_NOT_EXPOSE_THIS_RAW_REPORT')
   if($laterFailure){Verify ($null-ne $caught -and [object]::ReferenceEquals($caught.Exception,$transitionFailure) -and $rememberCalls-eq 1)}else{Verify ($null-eq $caught -and $rememberCalls-eq 0)}
  }
  # The ninth raw record may be the existing eligible lock-ACE projection.
  $beforeLock=@{'C:\ProgramData\OpenWebPBX\upgrade.lock'=@{directory=$false;bytes=0;sha256=('e'*64);acl='synthetic-before'}}
  $withLock=@{};foreach($path in $addedOnly.Keys){$withLock[$path]=$addedOnly[$path]};$withLock['C:\ProgramData\OpenWebPBX\upgrade.lock']=@{directory=$false;bytes=0;sha256=('e'*64);acl='synthetic-after'}
  $nine=Get-WindowsUpdaterAclObservation $beforeLock $withLock;Verify ($nine.changed_count-eq 9)
  $entry=@($nine.entries|Where-Object file_label -CEQ 'maintenance_lock')[0]
  $entry.entry_kind='file';$entry.descriptor_state='observed';$entry.descriptor=@{text_equal=$false;owner_equal=$true;group_equal=$true;control_flags_xor=0;dacl_binary_equal=$false;sacl_binary_equal=$true;dacl_ace_count_before=4;dacl_ace_count_after=4;dacl_ace_multiset_equal=$true}
  $nineRecord=@{empty_tenant_initialization=$model;file_security=$nine};Verify ($null-ne (Read-EmptyTenantInitializationComponent $nineRecord))
  $entry.descriptor.dacl_binary_equal=$true;Verify ($null-ne (Read-EmptyTenantInitializationComponent $nineRecord))
  foreach($name in 'owner_equal','group_equal','sacl_binary_equal','dacl_ace_multiset_equal'){$entry.descriptor[$name]=$false;Verify ($null-eq (Read-EmptyTenantInitializationComponent $nineRecord));$entry.descriptor[$name]=$true}
  foreach($case in 'unknown_model_key','wrong_count','string_count','false_original','known_prior_paths','unknown_group_policy','unknown_cipher_key','wrong_label','wrong_aad','missing_cipher'){
   $v=$valid|ConvertTo-Json -Depth 14|ConvertFrom-Json -AsHashtable
   switch($case){
    unknown_model_key{$v.empty_tenant_initialization.secret='DO_NOT_EXPOSE_THIS_RAW_REPORT'}
    wrong_count{$v.empty_tenant_initialization.new_files=4}
    string_count{$v.empty_tenant_initialization.new_files='3'}
    false_original{$v.empty_tenant_initialization.original_private_entries_exact=$false}
    known_prior_paths{$v.empty_tenant_initialization.prior_failed_CI_paths_known=$true}
    unknown_group_policy{$v.empty_tenant_initialization.group_policy='unknown'}
    unknown_cipher_key{$v.file_security.raw_acl='DO_NOT_EXPOSE_THIS_RAW_REPORT'}
    wrong_label{$v.file_security.entries[0].file_label='runtime'}
    wrong_aad{$v.file_security.encrypted.aad=[Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes('{}'))}
    missing_cipher{$v.Remove('file_security')}
   }
   WriteJson $transitionReport $v;$facts=@{};$transitionFailure=$null;$caught=$null
   try{& $caller}catch{$caught=$_}
   Verify ($null-ne $caught -and !$facts.ContainsKey('public21_empty_tenant_initialization') -and ($facts|ConvertTo-Json -Depth 14 -Compress)-cnotmatch 'DO_NOT_EXPOSE_THIS_RAW_REPORT')
  }
 }finally{
  if($null-eq $priorQA){Remove-Item Env:GITHUB_SHA -ErrorAction SilentlyContinue}else{$env:GITHUB_SHA=$priorQA};if($null-eq $priorRun){Remove-Item Env:GITHUB_RUN_ID -ErrorAction SilentlyContinue}else{$env:GITHUB_RUN_ID=$priorRun}
 }
 [ordered]@{passed=$true;checks=$checks;actualMapAdmission=$true;originalComparerExecuted=$true;originalMapsUnchanged=$true;nativeACLAdapter=$true;contentIPCAdapter=$true;outerDescriptorAdapter=$true;hostActions=$false}|ConvertTo-Json -Compress
}finally{Remove-Item -LiteralPath $work -Recurse -Force}
