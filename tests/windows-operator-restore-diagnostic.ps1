# QA-only wrapper: one unchanged installed helper invocation, closed errors only.
param([Parameter(Mandatory)][string]$Context)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
function Get-QualificationOperatorRestoreError($Failure){
 $types=@('RuntimeException','IOException','UnauthorizedAccessException','Win32Exception','InvalidOperationException','MethodInvocationException','ItemNotFoundException','FileNotFoundException','DirectoryNotFoundException','ArgumentException','NotSupportedException','other')
 $type=$Failure.Exception.GetType().Name;if($type-cnotin $types){$type='other'}
 $native=$null;$cursor=$Failure.Exception
 for($i=0;$i-lt 8-and $null-ne $cursor;$i++){
  if($cursor-is [ComponentModel.Win32Exception]){if($cursor.NativeErrorCode-ge 0-and $cursor.NativeErrorCode-le 65535){$native=[int]$cursor.NativeErrorCode};break}
  if($cursor-is [IO.IOException]){$bits=([int64]$cursor.HResult-band 4294967295L);if(($bits-band 4294901760L)-eq 2147942400L){$native=[int]($bits-band 65535L);break}}
  $cursor=$cursor.InnerException
 }
 $sources=@('Upgrade-OpenWebPBX.ps1','UpgradeRecovery.Common.ps1','Onboarding-Upgrade.Common.ps1','PhoneHealth-Security.ps1','Restore-Gates.ps1','CallRecords.Common.ps1','Support-Recovery.ps1','PhpRuntime.Common.ps1','File-Security.ps1','Dtls.Common.ps1','Web-Readiness.ps1','windows-operator-restore-diagnostic.ps1');$basename='unknown';$line=0
 if($Failure.InvocationInfo.ScriptName){$candidate=Split-Path -Leaf $Failure.InvocationInfo.ScriptName;if($candidate-cin $sources-and $Failure.InvocationInfo.ScriptLineNumber-gt 0-and $Failure.InvocationInfo.ScriptLineNumber-le 100000){$basename=$candidate;$line=[int]$Failure.InvocationInfo.ScriptLineNumber}}
 if($basename-ceq 'unknown'-and $Failure.ScriptStackTrace-and $Failure.ScriptStackTrace.Length-le 16384){foreach($frame in ([regex]::Split($Failure.ScriptStackTrace,'\r?\n')|Select-Object -First 32)){$m=[regex]::Match($frame,'(?:^|[\\/])(?<source>[^\\/\r\n:]{1,80}): line (?<line>[0-9]{1,5})$');if($m.Success-and $m.Groups['source'].Value-cin $sources-and [int]$m.Groups['line'].Value-gt 0){$basename=$m.Groups['source'].Value;$line=[int]$m.Groups['line'].Value;break}}}
 return @{schema=1;producer='windows-operator-restore-error';state='failed';exception_type=$type;hresult=[int]$Failure.Exception.HResult;win32_code=$native;source_basename=$basename;source_line=$line}
}
function Get-QualificationOperatorJournal {
 try{
  $path='C:\ProgramData\OpenWebPBX\updates\install-journal.json';$item=Get-Item -LiteralPath $path -Force
  if($item.PSIsContainer-or ($item.Attributes-band [IO.FileAttributes]::ReparsePoint)-or $item.Length-le 0-or $item.Length-gt 65536){return $null}
  $j=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
  if($j.state-isnot [string]-or $j.state-cnotin 'prepared','quiescing','validating','deploying','migrating','completed','rolling_back','rolled_back','recovery_required'-or $j.version-isnot [string]-or $j.version-cnotin '1.0.21','1.0.22'-or $j.operator_rollback-isnot [bool]){return $null}
  $safe=@{state=$j.state;version=$j.version;operator_rollback=$j.operator_rollback}
  if($j.finalization.phase-is [string]-and $j.finalization.phase-cin 'service_selection','background_tasks','manager_resume','complete'){$safe.phase=$j.finalization.phase};return $safe
 }catch{return $null}
}
$p=Get-Content -LiteralPath $Context -Raw|ConvertFrom-Json
if($env:GITHUB_ACTIONS-cne 'true'-or $env:RUNNER_ENVIRONMENT-cne 'github-hosted'-or $env:GITHUB_REPOSITORY-cne 'embire2/openwebpbx'-or $p.run_id-cne $env:GITHUB_RUN_ID){throw 'Only the current disposable qualification is allowed.'}
if($p.schema-ne 1-or $p.helper_path-cne 'C:\OpenWebPBX\tools\Upgrade-OpenWebPBX.ps1'-or $p.helper_sha256-cnotmatch '^[a-f0-9]{64}$'-or (Get-FileHash -LiteralPath $p.helper_path).Hash.ToLowerInvariant()-cne $p.helper_sha256-or (Get-FileHash -LiteralPath $PSCommandPath).Hash.ToLowerInvariant()-cne $p.wrapper_sha256){throw 'The exact installed helper and reviewed wrapper are required.'}
$helper=[string]$p.helper_path;$backup=[string]$p.backup_path;$output=[string]$p.failure_output
if(!$backup-or $output-cne (Join-Path (Split-Path $Context -Parent) 'operator-restore-error.safe.json')-or (Test-Path -LiteralPath $output)){throw 'The exact one-use private diagnostic output is required.'}
try{
 & $helper -RestoreBackup $backup
}catch{
 $primary=$_
 try{
  $record=Get-QualificationOperatorRestoreError $primary;$journal=Get-QualificationOperatorJournal;if($journal){$record.journal=$journal}
  $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($record|ConvertTo-Json -Depth 5 -Compress));$stream=[IO.File]::Open($output,'CreateNew','Write','None');try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
 }catch{}
 throw $primary
}
