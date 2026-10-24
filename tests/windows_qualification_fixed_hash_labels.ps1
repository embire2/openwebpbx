#Requires -Version 7.4
# Exact qualifier functions; owned temporary hash only, no service/task/ACL access.
[CmdletBinding()]
param([string]$SourcePath=(Join-Path $PSScriptRoot 'windows-updater-qualification.ps1'))
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($SourcePath,[ref]$tokens,[ref]$errors)
if($errors){throw 'The qualifier did not parse.'}
$names=@('Hash','QualificationSnapshotPaths','QualificationHashFailureFields','QualificationSnapshotHashFailure','SnapshotHash','QualificationFailureObservation')
$definitions=@{}
foreach($name in $names){
 $found=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true))
 if($found.Count -ne 1){throw 'Exactly one actual qualifier function is required.'}
 $definitions[$name]=$found[0].Extent.Text;. ([scriptblock]::Create($definitions[$name]))
}
$controls=0
function Must([bool]$Value){$script:controls++;if(!$Value){throw ('Fixed hash label control refused: '+$script:controls)}}
$sentinel='PRIVATE_FIXED_HASH_VALUE_MUST_NEVER_ESCAPE'
$share=[IO.IOException]::new($sentinel,[int]-2147024864)
$cases=@(
 @('C:\ProgramData\OpenWebPBX\phone-health-instance.json','phone_health_metadata'),
 @('C:\ProgramData\OpenWebPBX\stun.json','stun_metadata'),
 @('C:\ProgramData\OpenWebPBX\meet-ca.pem','meet_ca'),
 @('C:\ProgramData\OpenWebPBX\meet-proxy.json','meet_proxy_metadata'),
 @('C:\ProgramData\OpenWebPBX\upgrade.lock','upgrade_lock'),
 @('C:\ProgramData\OpenWebPBX\call-records.hold','cdr_hold')
)
$paths=QualificationSnapshotPaths;Must ($paths.Count -eq 45)
foreach($case in $cases){
 foreach($path in $case[0],$case[0].ToUpperInvariant().Replace('\','/')){
  $record=QualificationSnapshotHashFailure $path 'after_normal_protected' $share
  Must ($record.Count -eq 7 -and $record.file_label -ceq $case[1] -and $record.category -ceq 'config' -and $record.config_scope -ceq 'none')
  Must ($record.stage -ceq 'after_normal_protected' -and $record.exception_type -ceq 'IOException' -and $record.hresult -eq -2147024864 -and $record.win32_code -eq 32)
  $encoded=$record|ConvertTo-Json -Depth 8 -Compress
  Must (!$encoded.Contains($sentinel) -and !$encoded.Contains($path) -and !$encoded.Contains('C:'))
 }
 foreach($path in ($case[0]+'-'+$sentinel),('C:\ProgramData\OpenWebPBX-neighbour\'+[IO.Path]::GetFileName($case[0]))){
  $record=QualificationSnapshotHashFailure $path 'after_normal_protected' $share
  Must ($record.file_label -ceq 'unknown');Must (!(($record|ConvertTo-Json -Compress).Contains($sentinel)))
 }
}
$script:hashCalls=0;$script:injected=$share
function Get-FileHash {
 param([string]$LiteralPath,[string]$Algorithm)
 $script:hashCalls++
 if($script:injected){throw $script:injected}
 Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $LiteralPath -Algorithm $Algorithm
}
foreach($case in $cases){
 $script:hashCalls=0;$script:qualificationFailedHash=$null;$caught=$null
 try{SnapshotHash $case[0] 'after_normal_protected'|Out-Null}catch{$caught=$_}
 Must ($script:hashCalls -eq 1 -and [object]::ReferenceEquals($caught.Exception,$share))
 Must ($script:qualificationFailedHash.file_label -ceq $case[1] -and $script:qualificationFailedHash.stage -ceq 'after_normal_protected')
 $trace="at Hash, C:\private\windows-updater-qualification.ps1: line 91`nat SnapshotHash, C:\private\windows-updater-qualification.ps1: line 124`nat FileSnapshot, C:\private\windows-updater-qualification.ps1: line 351"
 $observed=QualificationFailureObservation $trace $null $null $script:qualificationFailedHash
 Must ($observed.hash_failure.file_label -ceq $case[1] -and $observed.hash_failure.win32_code -eq 32)
 Must (!(($observed|ConvertTo-Json -Depth 12 -Compress).Contains($sentinel)))
 $bad=@{}+$script:qualificationFailedHash;$bad.file_label=$sentinel
 Must ($null -eq (QualificationHashFailureFields $bad))
}
$script:injected=$null
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('openwebpbx-fixed-hash-labels-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $fixture|Out-Null
try{
 $file=Join-Path $fixture ($sentinel+'.bin');[IO.File]::WriteAllBytes($file,[byte[]](3,1,4,1,5,9,2,6))
 $before=(Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant();$time=[IO.File]::GetLastWriteTimeUtc($file)
 $script:hashCalls=0;$script:qualificationFailedHash=$null
 Must ((SnapshotHash $file 'after_normal_protected') -ceq $before)
 Must ($script:hashCalls -eq 1 -and $null -eq $script:qualificationFailedHash)
 Must ((Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $before -and [IO.File]::GetLastWriteTimeUtc($file) -eq $time)
}finally{Remove-Item -LiteralPath $fixture -Recurse -Force}
Must (!(Test-Path -LiteralPath $fixture))
Must ($definitions.Hash -ceq 'function Hash([string]$Path){return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}')
[ordered]@{state='passed';controls=$controls;actual_source_functions=$names.Count;new_fixed_labels=$cases.Count;complete_hash_and_exception_behavior='unchanged';raw_path_and_exception_message_suppressed=$true;real_owned_file_hash_and_bytes_preserved=$true;service_task_acl_access=$false}|ConvertTo-Json -Compress
