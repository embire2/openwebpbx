#Requires -Version 7.4
# SPDX-License-Identifier: AGPL-3.0-or-later
# Actual QA functions, owned files; explicit ACL/CDR-plan adapters, no services.
$ErrorActionPreference='Stop';$checks=0;$sentinel='PRIVATE_PATH_AND_MESSAGE_NEVER_COPY'
if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){throw 'These local controls use explicit POSIX-only ACL/CDR-plan adapters; native Windows execution is refused before fixture I/O.'}
function Assert([bool]$Value){if(!$Value){throw ('Upgrade hash control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
function Clone($Value){return($Value|ConvertTo-Json -Depth 16|ConvertFrom-Json -AsHashtable)}
function Definitions([string]$Path){$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors);Assert ($errors.Count -eq 0);$out=@{};foreach($node in $ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){$out[$node.Name]=$node.Extent.Text};return $out}
. (Join-Path $PSScriptRoot 'windows-upgrade-hash-observer.ps1')
. (Join-Path $PSScriptRoot 'windows-hold-failure-fields.ps1')
$definitions=Definitions (Join-Path $PSScriptRoot 'windows-upgrade-acceptance.ps1')
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('openweb-upgrade-hash-'+[Guid]::NewGuid().ToString('N'));New-Item -ItemType Directory $fixture|Out-Null
$file=Join-Path $fixture ($sentinel+'.bin');[IO.File]::WriteAllBytes($file,[byte[]](1,2,3,4));$before=[IO.File]::ReadAllBytes($file);$time=[IO.File]::GetLastWriteTimeUtc($file)
$roots=@{root='C:\OpenWebPBX';state='C:\ProgramData\OpenWebPBX';configuration='C:\ProgramData\fusionpbx';engine='C:\Program Files\FreeSWITCH';work='C:\qa\owned';package='C:\qa\package'}
$root=$roots.root;$state=$roots.state;$configuration=$roots.configuration;$switch=$roots.engine;$work=$roots.work;$PackageRoot=$roots.package
$source=Join-Path $fixture 'windows-upgrade-acceptance.ps1'
[IO.File]::WriteAllText($source,($definitions.Hash+"`n"+$definitions.FilesSnapshot+"`n"),[Text.UTF8Encoding]::new($false));. $source
try{
 $expected=(Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
 Assert ((Hash $file) -ceq $expected)
 $holder=[IO.File]::Open($file,'Open','ReadWrite','None')
 try{$caught=$null;try{Hash $file|Out-Null}catch{$caught=$_};Assert ($null -ne $caught);$real=$caught.Exception.Data['openweb_qa_hash_failure'];Assert ($null -ne $real);Assert ($real.frames[0].function -ceq 'Hash');Assert (($real|ConvertTo-Json -Depth 12) -cnotmatch $sentinel)}finally{$holder.Dispose()}
 # The command adapter injects exact original ErrorRecord objects and counts
 # invocations, while successful tests use the actual unchanged native cmdlet.
 $script:injected=$null;$script:hashCalls=@()
 function Get-FileHash {param([string]$LiteralPath,[string]$Algorithm)$script:hashCalls+=,@{path=$LiteralPath;algorithm=$Algorithm};if($script:injected){throw $script:injected};return Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $LiteralPath -Algorithm $Algorithm}
 $errorObject=[IO.IOException]::new($sentinel,[int]-2147024864)
 $script:injected=$errorObject
 foreach($mode in 'observed','observer_throws','validator_throws'){
  $errorObject.Data.Clear();$errorObject.Data['original_private_entry']=$sentinel;$errorObject.Data['openweb_qa_hash_failure']=@{stale=$sentinel};$script:hashCalls=@();$savedObserver=(Get-Command ObserveUpgradeHashFailure).ScriptBlock;$savedValidator=(Get-Command UpgradeHashFailureFields).ScriptBlock
  if($mode -ceq 'observer_throws'){Set-Item Function:ObserveUpgradeHashFailure -Value {throw 'observer-private-failure'}}
  if($mode -ceq 'validator_throws'){Set-Item Function:UpgradeHashFailureFields -Value {throw 'validator-private-failure'}}
  $caught=$null;try{Hash $file|Out-Null}catch{$caught=$_}
  Assert ([object]::ReferenceEquals($caught.Exception,$errorObject));Assert ($caught.Exception.Message -ceq $sentinel);Assert ($script:hashCalls.Count -eq 1 -and $script:hashCalls[0].path -ceq $file -and $script:hashCalls[0].algorithm -ceq 'SHA256')
  Assert ($errorObject.Data['original_private_entry'] -ceq $sentinel)
  Assert ($caught.ScriptStackTrace -match '(?m)^at Hash,');Assert ($errorObject.Data.Contains('openweb_qa_hash_failure') -eq ($mode -ceq 'observed'))
  if($mode -ceq 'observed'){$valid=Clone $errorObject.Data['openweb_qa_hash_failure'];Assert ($valid.hresult -eq -2147024864 -and $valid.base_hresult -eq -2147024864 -and $valid.win32_code -eq 32)}
  Set-Item Function:ObserveUpgradeHashFailure -Value $savedObserver;Set-Item Function:UpgradeHashFailureFields -Value $savedValidator
 }
 $script:injected=$null;$script:hashCalls=@();Assert ((Hash $file) -ceq $expected -and $script:hashCalls.Count -eq 1)
 # Execute the complete original FilesSnapshot against only newly owned trees.
 # Linux lacks Windows DACLs: this one reader and the configured CDR path are
 # explicit read-only adapters, not Windows ACL/installed-plan acceptance.
 function Get-Acl {param([string]$LiteralPath,[string]$Path)[pscustomobject]@{Sddl='owned-fixture-acl'}}
 function Check([bool]$Value,[string]$Message){if(!$Value){throw $Message}}
 $root=Join-Path $fixture 'root';$state=Join-Path $fixture 'state';$configuration=Join-Path $fixture 'configuration';$switch=Join-Path $fixture 'engine';$work=Join-Path $fixture 'work';$PackageRoot=Join-Path $fixture 'package'
 foreach($dir in @($root,$state,$configuration,$switch,$work,$PackageRoot,(Join-Path $root 'web'),(Join-Path $root 'updater'))){New-Item -ItemType Directory $dir -Force|Out-Null}
 [IO.File]::WriteAllText((Join-Path $PackageRoot 'CallRecords.Common.ps1'),'function Get-OpenWebCallRecordPlan {param($PackageRoot,$Root,$EngineRoot)return @{Path=(Join-Path $EngineRoot "log/xml_cdr")}}')
 $owned=Join-Path $root ('web/'+$sentinel+'.bin');[IO.File]::WriteAllBytes($owned,[byte[]](8,9));[IO.File]::WriteAllBytes((Join-Path $configuration 'config.conf'),[byte[]](4,5,6))
 $script:hashCalls=@();$snapshot=FilesSnapshot;Assert ($script:hashCalls.Count -eq 2 -and $snapshot[$owned].bytes -eq 2 -and $snapshot[(Join-Path $configuration 'config.conf')].bytes -eq 3)
 # Preserve actual captured frames/exception while supplying only the explicit
 # Windows classification roots; all actual file I/O remains in the owned tree.
 $script:classificationRoots=$roots;$script:actualObserver=(Get-Command ObserveUpgradeHashFailure).ScriptBlock
 function ObserveUpgradeHashFailure {param($Path,$Failure,$Frames,$Roots)& $script:actualObserver $Path $Failure $Frames $script:classificationRoots}
 $script:injected=$errorObject;$script:hashCalls=@();$caught=$null;try{FilesSnapshot|Out-Null}catch{$caught=$_};Assert ([object]::ReferenceEquals($caught.Exception,$errorObject) -and $script:hashCalls.Count -eq 1);Assert ($caught.ScriptStackTrace -match '(?m)^at FilesSnapshot,')
 $ordered=$caught.Exception.Data['openweb_qa_hash_failure'].frames;Assert ($ordered.Count -eq 2 -and $ordered[0].function -ceq 'Hash' -and $ordered[1].function -ceq 'FilesSnapshot')
 Set-Item Function:ObserveUpgradeHashFailure -Value $script:actualObserver
 $script:injected=$null;$root=$roots.root;$state=$roots.state;$configuration=$roots.configuration;$switch=$roots.engine;$work=$roots.work;$PackageRoot=$roots.package
 $frames=@([pscustomobject]@{FunctionName='Hash';ScriptName='C:\qa\windows-upgrade-acceptance.ps1';ScriptLineNumber=28},[pscustomobject]@{FunctionName='FilesSnapshot';ScriptName='C:\qa\windows-upgrade-acceptance.ps1';ScriptLineNumber=459},[pscustomobject]@{FunctionName='<ScriptBlock>';ScriptName='C:\qa\windows-upgrade-acceptance.ps1';ScriptLineNumber=736})
 $failure=[Management.Automation.ErrorRecord]::new($errorObject,$sentinel,[Management.Automation.ErrorCategory]::ReadError,$sentinel)
 foreach($case in @(@('C:\ProgramData\OpenWebPBX\upgrade.lock','state','upgrade_lock'),@('C:\ProgramData\OpenWebPBX\automatic-backups\worker.lock','automatic_backups','backup_worker_lock'),@('C:\Program Files\FreeSWITCH\log\xml_cdr\.openweb-import.lock','engine_logs','cdr_import_lock'),@('C:\ProgramData\fusionpbx\config.conf','configuration','config'),@('C:\qa\owned\forced-payload\bootstrap.php','fault_payload','fault_bootstrap'),@('C:\qa\owned\forced-payload\forced-failure.ps1','fault_payload','fault_script'),@('C:\OpenWebPBX\tools\Upgrade-OpenWebPBX.ps1','tools','installed_upgrade_helper'),@('C:\qa\package\Upgrade-OpenWebPBX.ps1','package','candidate_upgrade_helper'),@('C:\ProgramData\OpenWebPBX\backup-control\private-name.json','backup_control','unknown'),@('C:\OpenWebPBX-neighbour\secret.bin','other','unknown'),@('C:\OpenWebPBX\..\secret.bin','other','unknown'))){
  $observed=ObserveUpgradeHashFailure $case[0] $failure $frames $roots;Assert ($observed.category -ceq $case[1] -and $observed.file_label -ceq $case[2]);Assert (($observed|ConvertTo-Json -Depth 12) -cnotmatch 'private-name|secret.bin|PRIVATE_PATH');Assert ($observed.frames.Count -eq 3 -and $observed.win32_code -eq 32)
 }
 $nested=[InvalidOperationException]::new($sentinel,$errorObject);$nestedRecord=[Management.Automation.ErrorRecord]::new($nested,$sentinel,[Management.Automation.ErrorCategory]::ReadError,$null)
 $nestedObservation=ObserveUpgradeHashFailure 'C:\ProgramData\OpenWebPBX\upgrade.lock' $nestedRecord $frames $roots
 Assert ($nestedObservation.error_type -ceq 'InvalidOperationException' -and $nestedObservation.base_error_type -ceq 'IOException' -and $nestedObservation.hresult -eq $nested.HResult -and $nestedObservation.base_hresult -eq $errorObject.HResult -and $nestedObservation.win32_code -eq 32)
 for($depth=0;$depth -lt 8;$depth++){$nested=[InvalidOperationException]::new($sentinel,$nested)}
 $nestedRecord=[Management.Automation.ErrorRecord]::new($nested,$sentinel,[Management.Automation.ErrorCategory]::ReadError,$null)
 Assert ($null -eq (ObserveUpgradeHashFailure 'C:\ProgramData\OpenWebPBX\upgrade.lock' $nestedRecord $frames $roots))
 $valid=ObserveUpgradeHashFailure 'C:\ProgramData\OpenWebPBX\upgrade.lock' $failure $frames $roots
 Assert ($null -ne (UpgradeHashFailureFields ($valid|ConvertTo-Json -Depth 12|ConvertFrom-Json)))
 foreach($key in @($valid.Keys)){
  foreach($bad in @($null,$sentinel,$true,1.5,@{})){if($key -ceq 'win32_code' -and $null -eq $bad){continue};$copy=Clone $valid;$copy[$key]=$bad;Assert ($null -eq (UpgradeHashFailureFields $copy))}
  $copy=Clone $valid;$copy.Remove($key);Assert ($null -eq (UpgradeHashFailureFields $copy))
 }
 $copy=Clone $valid;$copy.message=$sentinel;Assert ($null -eq (UpgradeHashFailureFields $copy))
 foreach($key in 'hresult','base_hresult'){foreach($bad in -2147483649L,2147483648L){$copy=Clone $valid;$copy[$key]=$bad;Assert ($null -eq (UpgradeHashFailureFields $copy))}}
 foreach($bad in -1,33,65536){$copy=Clone $valid;$copy.win32_code=$bad;Assert ($null -eq (UpgradeHashFailureFields $copy))}
 foreach($key in 'function','source_basename','source_line'){$copy=Clone $valid;$copy.frames[0][$key]=$sentinel;Assert ($null -eq (UpgradeHashFailureFields $copy))}
 foreach($bad in 0,100001,$true){$copy=Clone $valid;$copy.frames[0].source_line=$bad;Assert ($null -eq (UpgradeHashFailureFields $copy))}
 $copy=Clone $valid;$copy.frames=@($copy.frames[1]);Assert ($null -eq (UpgradeHashFailureFields $copy))
 $copy=Clone $valid;$copy.frames=@($copy.frames[0],$copy.frames[0]);Assert ($null -eq (UpgradeHashFailureFields $copy))
 $copy=Clone $valid;$copy.frames=@();Assert ($null -eq (UpgradeHashFailureFields $copy))
 $copy=Clone $valid;$copy.frames[0].message=$sentinel;Assert ($null -eq (UpgradeHashFailureFields $copy))
 # Load actual parent function definitions only; top-level native actions do not run.
 $parents=Definitions (Join-Path $PSScriptRoot 'windows-suite.ps1');foreach($name in $parents.Keys){Invoke-Expression $parents[$name]}
 $record=@{source_basename='windows-upgrade-acceptance.ps1';source_line=28;error_type='System.IO.IOException';failed_phase='actual direct post-deploy rollback';hash_failure=$valid}
 $safe=SafeFailureFields ([pscustomobject]$record);Assert ($null -ne $safe.hash_failure -and $safe.hash_failure.win32_code -eq 32);Assert (($safe|ConvertTo-Json -Depth 12) -cnotmatch $sentinel)
 $plain=Clone $record;$plain.Remove('hash_failure');$original=SafeFailureFields ([pscustomobject]$plain);$without=Clone $safe;$without.Remove('hash_failure');Assert ($without.Count -eq $original.Count);foreach($key in $original.Keys){Assert ($without[$key] -ceq $original[$key])}
 $copy=Clone $record;$copy.hash_failure.message=$sentinel;Assert (!(SafeFailureFields ([pscustomobject]$copy)).ContainsKey('hash_failure'))
 $copy=Clone $record;$copy.source_basename='windows-suite.ps1';Assert (!(SafeFailureFields ([pscustomobject]$copy)).ContainsKey('hash_failure'))
 $copy=Clone $record;$copy.error_type='System.ArgumentException';Assert (!(SafeFailureFields ([pscustomobject]$copy)).ContainsKey('hash_failure'))
 $saved=(Get-Command UpgradeHashFailureFields).ScriptBlock;Set-Item Function:UpgradeHashFailureFields -Value {throw $sentinel};$safe=SafeFailureFields ([pscustomobject]$record);Assert (!$safe.ContainsKey('hash_failure') -and $safe.source_line -eq 28);Set-Item Function:UpgradeHashFailureFields -Value $saved
 Assert ((Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $expected -and [IO.File]::GetLastWriteTimeUtc($file) -eq $time)
}finally{Remove-Item -LiteralPath $fixture -Recurse -Force}
Assert (!(Test-Path -LiteralPath $fixture))
@{state='passed';controls=$checks;actual_hash_and_snapshot_source=$true;real_owned_read_and_share_refusal=$true;acl_cdr_plan_and_path_classification_roots='explicit_read_only_adapters';exception_identity_and_once_only_call=$true;failure_only_parent_projection=$true;no_service_or_configuration_changes=$true}|ConvertTo-Json -Compress
