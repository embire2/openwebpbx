[CmdletBinding()]
param([string]$Original23Helper='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'packaging/windows/PhpRuntime.Common.ps1')
$checks=0
function Check([bool]$Allowed,[string]$Message){if(!$Allowed){throw $Message};$script:checks++}
function Refused([scriptblock]$Action,[string]$Message){$denied=$false;try{& $Action|Out-Null}catch{$denied=$true};Check $denied $Message}
function Context {
 @{
  CallerPath='C:\OpenWebPBX\tools\Upgrade-OpenWebPBX.ps1';CallerSha256='527e17a9349fd5e9f3b1d048fd2f4526495e2cdc5e28f836fe79d8fd17ff1eec'
  HelperSha256=('a'*64);ManifestHelperSha256=('a'*64);PackageRoot='verified-package';Payload='verified-package';VerifiedPackagePath='verified-package'
  Archive='original-signed-package.zip';FeedEnvelope='original-envelope.json';TargetVersion='1.0.27';VerifiedVersion='1.0.27';PackageVersion='1.0.27';InstalledVersion='1.0.23';Completed=$true
  Check=$false;Automatic=$false;Recover=$false;RestoreBackup='';ParentExtraction='owned-parent-staging'
  EnginePaused=$false;Stopped=$false;BackupReady=$false;Success=$false;OperatorUpdaterStopped=$false;OperatorUpdaterWasRunning=$false
  RestoreStarted=$false;RecoveryRestoreStarted=$false;OperatorRollback=$false;UpgradeCommitted=$false
  Backup='';PhpRuntime=$null;CallRecordsHold=$null;RecoveryEntry=$null
 }
}
$context=Context
$plan=Get-OpenWebUpgradeDelegationPlan -Context $context -Original23
Check ($plan.Original23 -and $plan.Arguments[-1] -ceq '1.0.27') 'Original23 delegates only to the matching verified current release.'
Check ($plan.Arguments[($plan.Arguments.IndexOf('-Archive')+1)] -ceq $context.Archive -and $plan.Arguments[($plan.Arguments.IndexOf('-FeedEnvelope')+1)] -ceq $context.FeedEnvelope) 'The original archive and signed envelope remain unchanged.'
foreach($field in 'CallerSha256','InstalledVersion','CallerPath','TargetVersion'){
 $context=Context;$context[$field]='incorrect'
 Refused {Get-OpenWebUpgradeDelegationPlan -Context $context -Original23} ('Original23 refuses incorrect '+$field)
}
foreach($field in 'Archive','FeedEnvelope','VerifiedVersion','VerifiedPackagePath','ManifestHelperSha256'){
 $context=Context;$context[$field]=''
 Refused {Get-OpenWebUpgradeDelegationPlan -Context $context -Original23} ('Unsigned or unbound context refuses: '+$field)
}
foreach($field in 'EnginePaused','Stopped','BackupReady','Success','OperatorUpdaterStopped','OperatorUpdaterWasRunning','RestoreStarted','RecoveryRestoreStarted','OperatorRollback','UpgradeCommitted'){
 $context=Context;$context[$field]=$true
 Refused {Get-OpenWebUpgradeDelegationPlan -Context $context -Original23} ('No delegation after parent side effect '+$field)
}
foreach($field in 'PhpRuntime','CallRecordsHold','RecoveryEntry','Backup'){
 $context=Context;$context[$field]='prepared'
 Refused {Get-OpenWebUpgradeDelegationPlan -Context $context -Original23} ('No delegation after parent preparation '+$field)
}
foreach($mode in 'Recover','RestoreBackup'){
 $context=Context;if($mode -ceq 'Recover'){$context.Recover=$true}else{$context.RestoreBackup='previous-owned-backup'}
 Refused {Get-OpenWebUpgradeDelegationPlan -Context $context} ('Forward delegation refuses '+$mode)
}
foreach($field in 'Check','Automatic'){
 $context=Context;$context[$field]=$true
 $plan=Get-OpenWebUpgradeDelegationPlan -Context $context -Original23
 Check ($plan.Arguments -ccontains ('-'+$field)) ('Original '+$field+' mode is retained.')
 $context[$field]='true'
 Refused {Get-OpenWebUpgradeDelegationPlan -Context $context -Original23} ('String coercion cannot invent '+$field+' permission.')
}
$context=Context;$context.CallerSha256=$context.HelperSha256
Check ($null -eq (Get-OpenWebUpgradeDelegationPlan -Context $context)) 'Identical helper content continues without recursion, even in a new extraction.'
$context=Context;$context.CallerSha256=('b'*64);$context.InstalledVersion='1.0.27';$context.TargetVersion='1.0.28';$context.VerifiedVersion='1.0.28';$context.PackageVersion='1.0.28'
Check ($null -ne (Get-OpenWebUpgradeDelegationPlan -Context $context)) 'A future signed complete release uses its own current transaction.'
$context.InstalledVersion='1.0.29'
Refused {Get-OpenWebUpgradeDelegationPlan -Context $context} 'Delegation cannot lower the installed version.'
# Exercise the real child exit path: stdout must remain log output, never turn
# the returned exit code into an array or suppress deferred/recovery outcomes.
$shell=(Get-Process -Id $PID).Path
foreach($code in 0,1,2,75){
 $outcome=Invoke-OpenWebUpgradeDelegationProcess -Command $shell -Arguments @('-NoProfile','-NonInteractive','-Command',('Write-Output "owned child diagnostic"; exit '+$code))
 Check ($outcome -is [int] -and $outcome -eq $code) ('Child exit '+$code+' propagates exactly with stdout retained.')
 Check ($ErrorActionPreference -ceq 'Stop') 'Child launch preserves the parent error preference.'
}
foreach($source in 'PhpRuntime.Common.ps1','Upgrade-OpenWebPBX.ps1'){
 $tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root ('packaging/windows/'+$source)),[ref]$tokens,[ref]$errors)
 Check ($errors.Count -eq 0) ($source+' parses on the actual PowerShell runtime.')
}
if($Original23Helper){
 Check ((Get-FileHash -LiteralPath $Original23Helper -Algorithm SHA256).Hash.ToLowerInvariant() -ceq '527e17a9349fd5e9f3b1d048fd2f4526495e2cdc5e28f836fe79d8fd17ff1eec') 'Cleanup evidence must use the exact original public23 helper.'
 $tokens=$null;$errors=$null;$stock=[Management.Automation.Language.Parser]::ParseFile($Original23Helper,[ref]$tokens,[ref]$errors)
 Check ($errors.Count -eq 0) 'Exact original23 helper parses.'
 $main=@($stock.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})
 Check ($main.Count -eq 1) 'Original23 has one main transaction finally block.'
 $finally=[scriptblock]::Create($main[0].Finally.Extent.Text.Trim().TrimStart('{').TrimEnd('}'))
 $work=Join-Path ([IO.Path]::GetTempPath()) ('openweb-delegation-'+[Guid]::NewGuid().ToString('N'))
 New-Item -ItemType Directory -Path $work|Out-Null
 $oldPg=$env:PGPASSWORD
 try{
  $extracted=Join-Path $work 'parent-stage';$child=Join-Path $work 'child-stage';New-Item -ItemType Directory -Path $extracted,$child|Out-Null
  [IO.File]::WriteAllText((Join-Path $child 'journal.txt'),'child-owned-and-unchanged')
  $lock=[IO.File]::Open((Join-Path $work 'maintenance.lock'),'CreateNew','ReadWrite','None');$originalHandle=$lock.SafeFileHandle;$lock.Dispose()
  $priorPgPassword='original-environment-fixture';$phpRuntime=$null;$script:enginePaused=$false;$stopped=$false;$script:operatorUpdaterStopped=$false;$restoreStarted=$false;$script:operatorUpdaterWasRunning=$false
  function ResumeEngine{throw 'A stale parent must not resume an old engine.'}
  function Start-Service{throw 'A stale parent must not start an old updater.'}
  . $finally
  Check (!(Test-Path -LiteralPath $extracted)) 'Exact parent finally removes only its owned staging tree.'
  Check ([IO.File]::ReadAllText((Join-Path $child 'journal.txt')) -ceq 'child-owned-and-unchanged') 'Exact parent cleanup preserves the child extraction and journal.'
  Check ($originalHandle.IsClosed -and !$lock.CanRead -and !$lock.CanWrite -and $env:PGPASSWORD -ceq $priorPgPassword) 'Parent cleanup only restores its environment and idempotently disposes its released lock.'
 }finally{
  if($null -eq $oldPg){Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue}else{$env:PGPASSWORD=$oldPg}
  Remove-Item -LiteralPath $work -Recurse -Force
 }
}
Write-Host "Windows verified upgrade delegation: $checks controls passed."
