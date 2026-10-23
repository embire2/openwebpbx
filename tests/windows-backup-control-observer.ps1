# QA only: invoke the actual installed control once, retaining its original ErrorRecord.
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('plan','hold','recover-startup','resume-factory')][string]$Operation,[Parameter(Mandatory)][string]$Request,[Parameter(Mandatory)][string]$PackageRoot,[Parameter(Mandatory)][string]$DiagnosticPath)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
function BackupControlErrorType($ErrorObject){
 $allowed=@('System.Exception','System.IO.IOException','System.IO.FileNotFoundException','System.IO.DirectoryNotFoundException','System.UnauthorizedAccessException','System.ArgumentException','System.ArgumentNullException','System.InvalidOperationException','System.FormatException','System.ComponentModel.Win32Exception','System.Security.SecurityException','System.DllNotFoundException','System.EntryPointNotFoundException','System.Management.Automation.RuntimeException','System.Management.Automation.MethodInvocationException','System.Management.Automation.ActionPreferenceStopException','System.Management.Automation.CommandNotFoundException','System.Management.Automation.ParameterBindingException','System.Management.Automation.ParameterBindingValidationException','System.Management.Automation.ItemNotFoundException','System.Management.Automation.ProviderInvocationException','Microsoft.PowerShell.Commands.ServiceCommandException')
 $name=$ErrorObject.GetType().FullName;if($name -cin $allowed){return $name};return 'other'
}
function BackupControlBasename([string]$Path){
 $name=[IO.Path]::GetFileName($Path.Replace('\','/'))
 if($name -cin 'Backup-Control.ps1','CallRecords.Common.ps1','UpgradeRecovery.Common.ps1','Write-PrivateState.ps1','File-Security.ps1','windows-backup-control-observer.ps1'){return $name};return 'external_component'
}
function BackupControlFailureFields($Record,[string]$Operation,[string]$Phase,[int]$Exit,[bool]$Pinned){
 $safe=@{schema=1;producer='windows-backup-control-observer.ps1';operation=$Operation;phase=$Phase;exit_code=$Exit;source_pins_verified=$Pinned;invocations=if($Phase -ceq 'observer_preflight'){0}else{1};original_error_observed=($null -ne $Record -and $Phase -cne 'observer_preflight');error_type='unavailable';inner_error_type='unavailable';hresult=0L;source_basename='external_component';source_line=0;caller_basename='external_component';caller_line=0}
 if($null -eq $Record){return $safe}
 $safe.error_type=BackupControlErrorType $Record.Exception
 $inner=$Record.Exception;for($depth=0;$depth -lt 8 -and $inner.InnerException;$depth++){$inner=$inner.InnerException}
 $safe.inner_error_type=BackupControlErrorType $inner;$safe.hresult=([long]$inner.HResult -band 4294967295L)
 $safe.source_basename=BackupControlBasename ([string]$Record.InvocationInfo.ScriptName)
 $line=$Record.InvocationInfo.ScriptLineNumber;if($line -gt 0 -and $line -lt 1000000){$safe.source_line=[int]$line}
 $stack=[string]$Record.ScriptStackTrace
 if($stack.Length -le 32768){foreach($frame in @($stack -split "`n"|Select-Object -First 16)){
  if($frame -match ',\s+(.+):\s+line\s+([0-9]{1,6})\s*$'){
   $name=BackupControlBasename $Matches[1];$number=[int]$Matches[2]
   if($name -ceq 'Backup-Control.ps1' -and $number -gt 0){$safe.caller_basename=$name;$safe.caller_line=$number;break}
  }
 }}
 return $safe
}
function InvokeObservedBackupControl([string]$Path,[string]$Operation,[string]$Request){
 # Each invocation starts a fresh stock PowerShell process. Clear only this QA
 # process's error baseline before the exact original script is called once.
 $original=$null;$code=0;$phase='bootstrap';$global:LASTEXITCODE=0;$Error.Clear()
 try{
  & $Path -Operation $Operation -Request $Request
  $code=$LASTEXITCODE
  if($code -ne 0){$phase='operation';if($Error.Count){$original=$Error[0]}}
 }catch{$original=$_;$code=1;$phase='bootstrap'}
 return @{exit_code=[int]$code;phase=$phase;error_record=$original}
}
function WriteBackupControlObservation([string]$Path,$Record){
 $raw=[Text.UTF8Encoding]::new($false).GetBytes(($Record|ConvertTo-Json -Depth 4 -Compress))
 if($raw.Length -gt 8192){throw 'The closed control observation exceeded its bound.'}
 $file=[IO.File]::Open($Path,'CreateNew','Write','None');try{$file.Write($raw,0,$raw.Length);$file.Flush($true)}finally{$file.Dispose()}
}
function AssertBackupControlObserverContext([string]$PackageRoot,[string]$DiagnosticPath){
 if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or $PSVersionTable.PSEdition -cne 'Desktop' -or ![Environment]::Is64BitProcess -or $env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows' -or $env:GITHUB_REPOSITORY -cne 'embire2/openwebpbx'){throw 'Only the explicit disposable native Windows control invocation is eligible.'}
 $directory=Get-Item -LiteralPath (Split-Path -Parent $DiagnosticPath) -Force
 if(!$directory.PSIsContainer -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -or (Test-Path -LiteralPath $DiagnosticPath)){throw 'A new private diagnostic file is required.'}
 $acl=Get-Acl -LiteralPath $directory.FullName
 if(!$acl.AreAccessRulesProtected -or $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cnotin 'S-1-5-18','S-1-5-32-544'){throw 'Private diagnostic directory ownership is required.'}
 foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){if($rule.AccessControlType -ne 'Allow' -or $rule.IdentityReference.Value -cnotin 'S-1-5-18','S-1-5-32-544'){throw 'The diagnostic directory grants unrelated access.'}}
 $manifestPath=Join-Path $PackageRoot 'release-manifest.json';$item=Get-Item -LiteralPath $manifestPath -Force
 if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $item.Length -gt 32MB){throw 'The candidate manifest is unavailable.'}
 $manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8|ConvertFrom-Json
 if($manifest.version -cne '1.0.20'){throw 'The exact candidate manifest is required.'}
 foreach($name in 'Backup-Control.ps1','CallRecords.Common.ps1','UpgradeRecovery.Common.ps1','Write-PrivateState.ps1','File-Security.ps1'){
  $path=Join-Path 'C:\OpenWebPBX\tools' $name;$item=Get-Item -LiteralPath $path -Force
  if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $manifest.files.$name -cnotmatch '^[a-f0-9]{64}$' -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $manifest.files.$name){throw 'The actual control import closure differs from its candidate manifest.'}
 }
}
$pinned=$false;$result=$null
try{
 AssertBackupControlObserverContext $PackageRoot $DiagnosticPath;$pinned=$true
 $result=InvokeObservedBackupControl 'C:\OpenWebPBX\tools\Backup-Control.ps1' $Operation $Request
}catch{$result=@{exit_code=1;phase='observer_preflight';error_record=$_}}
if($result.exit_code -ne 0){
 try{WriteBackupControlObservation $DiagnosticPath (BackupControlFailureFields $result.error_record $Operation $result.phase $result.exit_code $pinned)}catch{} # Never replace the original control failure.
 if($result.phase -ceq 'bootstrap' -and $result.error_record){throw $result.error_record} # Let the stock host render the original uncaught import error privately.
 exit $result.exit_code
}
