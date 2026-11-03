param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$script:checks=0
function Check([bool]$Value,[string]$Message='Tenant process exit control failed'){if(!$Value){throw $Message};$script:checks++}
function ImportActual([string]$Path,[string]$Name){
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors);Check (!$errors.Count)
 $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-ceq $Name},$true));Check ($nodes.Count-eq 1)
 Set-Item ('function:script:'+ $Name) ([scriptblock]::Create($nodes[0].Body.Extent.Text.Substring(1,$nodes[0].Body.Extent.Text.Length-2)))
 return $nodes[0].Extent.Text
}
$helper=Join-Path $SourceRoot 'tests/windows-upgrade-health-quiescence.ps1'
$inventorySource=ImportActual $helper 'Get-OpenWebQualificationTenantProcesses'
$waitSource=ImportActual (Join-Path $SourceRoot 'tests/windows-updater-qualification.ps1') 'WaitActualTenantIdle'
$root='C:\OpenWebPBX';$oldSystemRoot=$env:SystemRoot;$env:SystemRoot='C:\Windows'
function CimFailure([Microsoft.Management.Infrastructure.NativeErrorCode]$Code){
 # Controlled typed exception adapter only; actual native MI code has a separate OS proof.
 $e=[Microsoft.Management.Infrastructure.CimException]::new('Controlled CIM failure')
 $field=$e.GetType().GetField('<NativeErrorCode>k__BackingField',[Reflection.BindingFlags]'Instance,NonPublic');Check ($null-ne $field)
 $field.SetValue($e,$Code);return $e
}
function Row([string]$Kind='python',[uint32]$Id=4242){
 $exe,$cmd=switch($Kind){
  python {'C:\OpenWebPBX\backup-runtime\python.exe';'python -I -B "C:\OpenWebPBX\tools\tenant-domains.py"'}
  php {'C:\OpenWebPBX\php\php.exe';'php "C:\OpenWebPBX\tools\tenant-domains.php"'}
  powershell {'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe';'powershell -File "C:\OpenWebPBX\tools\Tenant-Domains.ps1"'}
  acme {'C:\OpenWebPBX\acme\wacs.exe';'wacs --friendlyname "OpenWebPBX-tenants-012345abcdef"'}
 }
 return [pscustomobject]@{ExecutablePath=$exe;CommandLine=$cmd;ProcessId=$Id;OwnerSid='S-1-5-18';OwnerResult=0}
}
function Reset {
 $script:rows=@(Row);$script:freshRows=@();$script:ownerFailure=$null;$script:queryFailure=$null;$script:ownerCalls=0;$script:inventoryCalls=0;$script:freshCalls=0;$script:sleeps=0;$script:emptyAfterSleep=$false
}
function Get-CimInstance {
 [CmdletBinding()]param([string]$ClassName,[string]$Filter,[int]$OperationTimeoutSec)
 Check ($ClassName-ceq 'Win32_Process' -and $OperationTimeoutSec-eq 3)
 if($Filter-ceq "Name='python.exe' OR Name='php.exe' OR Name='powershell.exe' OR Name='wacs.exe'"){$script:inventoryCalls++;return $script:rows}
 Check ($Filter-ceq 'ProcessId=4242');$script:freshCalls++
 if($script:queryFailure){throw $script:queryFailure};return $script:freshRows
}
function Invoke-CimMethod {
 [CmdletBinding()]param($InputObject,[string]$MethodName,[int]$OperationTimeoutSec)
 Check ($MethodName-ceq 'GetOwnerSid' -and $OperationTimeoutSec-eq 3);$script:ownerCalls++
 if($script:ownerFailure -and [object]::ReferenceEquals($InputObject,$script:rows[0])){throw $script:ownerFailure}
 return [pscustomobject]@{ReturnValue=$InputObject.OwnerResult;Sid=$InputObject.OwnerSid}
}
function Refuses([scriptblock]$Body,$Expected=$null){
 $caught=$null;try{& $Body|Out-Null}catch{$caught=$_};Check ($null-ne $caught)
 if($Expected){Check ([object]::ReferenceEquals($caught.Exception,$Expected))}
}
try{
 foreach($kind in 'python','php','powershell','acme'){
  Reset;$script:rows=@(Row $kind);Check ((Get-OpenWebQualificationTenantProcesses)-eq 1);Check ($freshCalls-eq 0)
  $script:ownerFailure=CimFailure NotFound;Check ((Get-OpenWebQualificationTenantProcesses)-eq 1);Check ($freshCalls-eq 1)
 }
 Reset;Check ((Get-OpenWebQualificationTenantProcesses)-eq 1);$rows[0].OwnerSid='FOREIGN';Refuses {Get-OpenWebQualificationTenantProcesses};$rows[0].OwnerSid='S-1-5-18';$rows[0].OwnerResult=1;Refuses {Get-OpenWebQualificationTenantProcesses}
 foreach($code in 'AccessDenied','InvalidOperationTimeout','Failed','Ok','InvalidClass'){
  Reset;$script:ownerFailure=CimFailure $code;Refuses {Get-OpenWebQualificationTenantProcesses} $ownerFailure;Check ($freshCalls-eq 0)
 }
 Reset;$script:ownerFailure=[InvalidOperationException]::new('Not found');$ownerFailure.Data['NativeErrorCode']=6;Refuses {Get-OpenWebQualificationTenantProcesses} $ownerFailure;Check ($freshCalls-eq 0)
 foreach($presence in 'same','reused','foreign'){
  Reset;$script:ownerFailure=CimFailure NotFound;$script:freshRows=@(Row)
  if($presence-ceq 'reused'){$freshRows[0]|Add-Member CreationDate ([DateTime]::UtcNow)}
  if($presence-ceq 'foreign'){$freshRows[0].ExecutablePath='C:\Foreign\python.exe';$freshRows[0].OwnerSid='FOREIGN'}
  Refuses {Get-OpenWebQualificationTenantProcesses} $ownerFailure;Check ($freshCalls-eq 1)
 }
 foreach($code in 'AccessDenied','InvalidOperationTimeout'){
  Reset;$script:ownerFailure=CimFailure NotFound;$script:queryFailure=CimFailure $code;Refuses {Get-OpenWebQualificationTenantProcesses} $ownerFailure;Check ($freshCalls-eq 1)
 }
 Reset;$rows[0].ExecutablePath='C:\Foreign\python.exe';$script:ownerFailure=CimFailure NotFound;Refuses {Get-OpenWebQualificationTenantProcesses};Check ($ownerCalls-eq 0 -and $freshCalls-eq 0)
 foreach($id in @($null,0,4242,'4242')){
  Reset;$rows[0].ProcessId=$id;$script:ownerFailure=CimFailure NotFound;Refuses {Get-OpenWebQualificationTenantProcesses} $ownerFailure;Check ($freshCalls-eq 0)
 }
 # A vanished first row cannot hide a foreign later row from the same inventory.
 Reset;$script:rows=@((Row), (Row php 5000));$rows[1].OwnerSid='FOREIGN';$script:ownerFailure=CimFailure NotFound;Refuses {Get-OpenWebQualificationTenantProcesses};Check ($ownerCalls-eq 2 -and $freshCalls-eq 1)
 Reset;$script:rows=@();Check ((Get-OpenWebQualificationTenantProcesses)-eq 0)
 # Execute the original600s/250ms caller: one conservative busy sample must
 # resample the whole inventory before a later actual empty sample is idle.
 function Get-ScheduledTask {param([string]$TaskName);Check ($TaskName-ceq 'OpenWebPBX-TenantDomains');return @{Settings=@{Enabled=$true};State='Ready'}}
 function Assert-OpenWebQualificationTenantTask($Task){Check $Task.Settings.Enabled}
 function Get-ScheduledTaskInfo {param([string]$TaskName,[string]$TaskPath);return @{LastTaskResult=0;LastRunTime=[DateTime]::UtcNow}}
 function Get-WindowsEmptyTenantPaths {return [ordered]@{a=1;b=1;c=1;d=1;e=1;f=1;g=1;h=1}}
 function Test-Path {param([string]$LiteralPath);return $true}
 function ReadQualificationTenantIdleObservation($Record){return $Record}
 function Start-Sleep {param([int]$Milliseconds);Check ($Milliseconds-eq 250);$script:sleeps++;if($script:emptyAfterSleep){$script:rows=@()}}
 Reset;$script:ownerFailure=CimFailure NotFound;$script:emptyAfterSleep=$true;WaitActualTenantIdle
 Check ($sleeps-eq 1 -and $inventoryCalls-eq 2 -and $freshCalls-eq 1 -and $script:qualificationTenantIdleObservation.native_process_count-eq 0)
 Check ($waitSource.Contains('[DateTime]::UtcNow.AddSeconds(600)') -and $waitSource.Contains('Start-Sleep -Milliseconds 250'))
 Check ($inventorySource.Contains('$count++;continue') -and !$inventorySource.Contains('return 1'))
 Write-Output ('PASS '+$checks+' actual inventory and original600s caller controls; typed CIM adapters only, native OS proof separate')
}finally{$env:SystemRoot=$oldSystemRoot}
