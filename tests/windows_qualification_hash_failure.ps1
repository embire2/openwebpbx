#Requires -Version 7.4
# Source-only controls: exact qualifier functions, owned temporary bytes, no service/task/ACL writes.
$ErrorActionPreference='Stop'
$sourcePath=Join-Path $PSScriptRoot 'windows-updater-qualification.ps1'
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($sourcePath,[ref]$tokens,[ref]$parseErrors)
if($parseErrors){throw 'Qualifier source did not parse.'}
$functions=@('Check','Hash','QualificationSnapshotPaths','QualificationHashFailureFields','QualificationSnapshotHashFailure','SnapshotHash','FileSnapshot','QualificationFailureObservation')
$definitions=@{}
foreach($name in $functions){
 $found=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true))
 if($found.Count -ne 1){throw 'One exact source function is required.'}
 $definitions[$name]=$found[0].Extent.Text;. ([scriptblock]::Create($definitions[$name]))
}
$controlCount=0
function Must([bool]$Value){$script:controlCount++;if(!$Value){throw ('Hash observation control refused: '+$script:controlCount)}}
$sentinel='PRIVATE_HASH_VALUE_MUST_NEVER_ESCAPE'
$share=[IO.IOException]::new($sentinel,[int]-2147024864)
$paths=QualificationSnapshotPaths
Must ($paths.Count -eq 45)
# Compare all closed paths, categories, nine scope roots and boundary negatives to the existing Python classifier.
$python=$env:OPENWEB_TEST_PYTHON
if(!$python){foreach($candidate in 'python3','python.exe','python'){ $command=Get-Command $candidate -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1;if($command){$python=$command.Source;break}}}
if(!$python){throw 'Python is required for the actual existing-classifier conformance controls.'}
$code=@'
import json,runpy,sys
m=runpy.run_path(sys.argv[1]);paths=list(m['KNOWN_FILE_PATHS'])
paths += [p.upper().replace('/', chr(92)) for p in paths]
paths += [p+'/PRIVATE_HASH_VALUE_MUST_NEVER_ESCAPE' for p in m['CONFIG_SCOPES']]
paths += [p+'-PRIVATE_HASH_VALUE_MUST_NEVER_ESCAPE/file' for p in m['CONFIG_SCOPES']]
paths += ['C:/private/PRIVATE_HASH_VALUE_MUST_NEVER_ESCAPE', '', 'x'*4097]
rows=[]
for p in paths:
 f=p.replace('\\','/').casefold() if len(p)<=4096 else ''
 rows.append(dict(path=p,file_label=m['KNOWN_FILE_PATHS'].get(f,'unknown'),category=m['file_category'](p) or 'other',config_scope=next((v for k,v in m['CONFIG_SCOPES'].items() if f==k or f.startswith(k+'/')),'none')))
print(json.dumps(rows))
'@
$start=[Diagnostics.ProcessStartInfo]::new($python);$start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
foreach($arg in @('-I','-B','-c',$code,(Join-Path $PSScriptRoot 'windows-compare-json.py'))){$start.ArgumentList.Add($arg)}
$child=[Diagnostics.Process]::Start($start);$stdout=$child.StandardOutput.ReadToEndAsync();$stderr=$child.StandardError.ReadToEndAsync()
try{Must ($child.WaitForExit(15000));Must ($child.ExitCode -eq 0);$cases=$stdout.GetAwaiter().GetResult()|ConvertFrom-Json -AsHashtable}finally{if(!$child.HasExited){$child.Kill()};$child.Dispose()}
foreach($case in $cases){
 $record=QualificationSnapshotHashFailure $case.path 'before_fault_full' $share
 Must ($record.file_label -ceq $case.file_label -and $record.category -ceq $case.category -and $record.config_scope -ceq $case.config_scope)
 Must ($record.hresult -eq -2147024864 -and $record.win32_code -eq 32 -and $record.exception_type -ceq 'IOException')
 Must (!(($record|ConvertTo-Json -Depth 8 -Compress).Contains($sentinel)))
}
$valid=QualificationSnapshotHashFailure 'C:\ProgramData\OpenWebPBX\automatic-backups\worker.lock' 'before_fault_full' $share
Must ($valid.file_label -ceq 'automatic_backups_worker_lock' -and $valid.config_scope -ceq 'automatic_backups')
foreach($stage in 'unobserved','before_fault_full','before_fault_protected','after_fault_full','after_normal_protected'){Must ((QualificationSnapshotHashFailure 'C:\OpenWebPBX\php\php.ini' $stage $share).stage -ceq $stage)}
foreach($name in 'stage','file_label','category','config_scope','exception_type'){$bad=@{}+$valid;$bad[$name]=$sentinel;Must ($null -eq (QualificationHashFailureFields $bad))}
foreach($value in @('32',32L,32.0,$true,-1,65536)){$bad=@{}+$valid;$bad.win32_code=$value;Must ($null -eq (QualificationHashFailureFields $bad))}
foreach($value in @('32',32L,32.0,$true,$null)){$bad=@{}+$valid;$bad.hresult=$value;Must ($null -eq (QualificationHashFailureFields $bad))}
$bad=@{}+$valid;$bad.Remove('win32_code');$bad[$sentinel]=$sentinel;Must ($null -eq (QualificationHashFailureFields $bad))
$bad=@{}+$valid;$bad[$sentinel]=$sentinel;Must ($null -eq (QualificationHashFailureFields $bad))
$validNull=@{}+$valid;$validNull.win32_code=$null;Must ($null -ne (QualificationHashFailureFields $validNull))
$nested=[Exception]::new($sentinel,$share);$record=QualificationSnapshotHashFailure 'private' 'after_fault_full' $nested;Must ($record.exception_type -ceq 'IOException' -and $record.win32_code -eq 32)
$win32=[ComponentModel.Win32Exception]::new(5,$sentinel);$record=QualificationSnapshotHashFailure 'private' 'after_fault_full' $win32;Must ($record.exception_type -ceq 'Win32Exception' -and $record.win32_code -eq 5)
$other=[InvalidOperationException]::new($sentinel);$record=QualificationSnapshotHashFailure 'private' 'after_fault_full' $other;Must ($record.exception_type -ceq 'OtherError' -and $null -eq $record.win32_code)
$trace="at Hash, C:\private\windows-updater-qualification.ps1: line 64`nat SnapshotHash, C:\private\windows-updater-qualification.ps1: line 100`nat FileSnapshot, C:\private\windows-updater-qualification.ps1: line 249"
$observed=QualificationFailureObservation $trace $null $null $valid
Must ($observed.hash_failure.file_label -ceq 'automatic_backups_worker_lock')
foreach($without in 'Hash','SnapshotHash','FileSnapshot'){$reduced=($trace -split "`n"|Where-Object {$_ -notmatch ('^at '+$without+',')}) -join "`n";$out=QualificationFailureObservation $reduced $null $null $valid;Must (!$out.ContainsKey('hash_failure'))}
Must (!((QualificationFailureObservation $trace $null $null $bad).ContainsKey('hash_failure')))
Must (!(($observed|ConvertTo-Json -Depth 12 -Compress).Contains($sentinel)))
# Actual Hash delegates exactly once; failures preserve the exact original exception, including observer failure.
$script:hashCalls=0;$script:injected=$null
function Get-FileHash {
 param([string]$LiteralPath,[string]$Algorithm)
 $script:hashCalls++;if($script:injected){throw $script:injected}
 Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $LiteralPath -Algorithm $Algorithm
}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('openwebpbx-hash-observer-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $fixture|Out-Null
try{
 $file=Join-Path $fixture ($sentinel+'.bin');[IO.File]::WriteAllBytes($file,[byte[]](1,9,4,8,2,3));$expected=(Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant();$time=[IO.File]::GetLastWriteTimeUtc($file)
 $script:hashCalls=0;$script:qualificationFailedHash=$null;Must ((SnapshotHash $file 'before_fault_full') -ceq $expected);Must ($script:hashCalls -eq 1 -and $null -eq $script:qualificationFailedHash)
 $script:injected=$share;$script:hashCalls=0;$caught=$null;try{SnapshotHash $file 'after_fault_full'|Out-Null}catch{$caught=$_}
 Must ($script:hashCalls -eq 1 -and [object]::ReferenceEquals($caught.Exception,$share));Must ($script:qualificationFailedHash.stage -ceq 'after_fault_full' -and $script:qualificationFailedHash.file_label -ceq 'unknown')
 $saved=(Get-Item Function:\QualificationSnapshotHashFailure).ScriptBlock
 function QualificationSnapshotHashFailure {throw $sentinel}
 $script:hashCalls=0;$caught=$null;try{SnapshotHash $file 'after_fault_full'|Out-Null}catch{$caught=$_}
 Must ($script:hashCalls -eq 1 -and [object]::ReferenceEquals($caught.Exception,$share) -and $null -eq $script:qualificationFailedHash)
 Set-Item Function:\QualificationSnapshotHashFailure $saved
 # Non-snapshot Hash cannot acquire the previous snapshot's metadata in the public projection.
 $script:qualificationFailedHash=$valid;$caught=$null;try{Hash $file|Out-Null}catch{$caught=$_}
 Must ([object]::ReferenceEquals($caught.Exception,$share));Must (!((QualificationFailureObservation 'at Hash, C:\private\windows-updater-qualification.ps1: line 64' $null $null $script:qualificationFailedHash).ContainsKey('hash_failure')))
 $script:injected=$null
 # Actual owned snapshot enumeration/hashing with a read-only fictional ACL provider for Linux portability.
 function Get-Acl {param([string]$LiteralPath,[string]$Path)[pscustomobject]@{Sddl='fictional-owned-acl'}}
 $root=Join-Path $fixture 'root';$state=Join-Path $fixture 'state';$engine=Join-Path $fixture 'engine';$configuration=Join-Path $fixture 'configuration'
 foreach($dir in @($root,$state,$engine,$configuration,(Join-Path $root 'web'),(Join-Path $root 'updater'))){New-Item -ItemType Directory $dir -Force|Out-Null}
 [IO.File]::WriteAllBytes((Join-Path $root ('web/'+$sentinel+'.bin')),[byte[]](5,6,7));[IO.File]::WriteAllBytes((Join-Path $configuration 'config.conf'),[byte[]](8,9))
 $script:hashCalls=0;$script:qualificationFailedHash=$valid;$snapshot=FileSnapshot -Stage before_fault_full
 Must ($script:hashCalls -eq 2 -and $null -eq $script:qualificationFailedHash)
 Must ($snapshot.Count -eq 8 -and $snapshot[(Join-Path $configuration 'config.conf')].bytes -eq 2)
 $script:injected=$share;$script:hashCalls=0;$caught=$null;try{FileSnapshot -Stage after_fault_full|Out-Null}catch{$caught=$_}
 Must ([object]::ReferenceEquals($caught.Exception,$share) -and $script:hashCalls -eq 1 -and $script:qualificationFailedHash.stage -ceq 'after_fault_full')
 foreach($frame in 'Hash','SnapshotHash','FileSnapshot'){Must ($caught.ScriptStackTrace -match ('(?m)^at '+$frame+','))}
 Must (!(($script:qualificationFailedHash|ConvertTo-Json -Compress).Contains($sentinel)))
 $script:injected=$null
 Must ((Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $expected -and [IO.File]::GetLastWriteTimeUtc($file) -eq $time)
}finally{Remove-Item -LiteralPath $fixture -Recurse -Force}
Must (!(Test-Path -LiteralPath $fixture))
$functionText=$definitions.FileSnapshot
Must ($functionText.Contains('$record.sha256=SnapshotHash $item.FullName $Stage') -and $functionText.Contains('sha256=(SnapshotHash $path $Stage)'))
foreach($stage in 'before_fault_full','before_fault_protected','after_fault_full','after_normal_protected'){Must ([regex]::Matches([IO.File]::ReadAllText($sourcePath),"-Stage '"+$stage+"'").Count -eq 1)}
Must ($definitions.Hash -ceq 'function Hash([string]$Path){return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}')
[ordered]@{state='passed';controls=$controlCount;actual_source_functions=$functions.Count;actual_existing_python_classifier_conformance=$true;real_owned_file_hash_and_snapshot=$true;acl_dependency='fictional_read_only';original_exception_and_single_call_preserved=$true;observer_failure_preserved=$true;no_service_task_or_acl_mutation=$true}|ConvertTo-Json -Compress
