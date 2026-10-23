# Execute the actual read-only identity script with explicit native API adapters.
# No installed service, task, filesystem, process or configuration is changed.
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$file=Join-Path $PSScriptRoot 'windows_cdr_service.ps1'
$raw=[IO.File]::ReadAllText($file)
$line=". (Join-Path `$PSScriptRoot 'windows-native-cleanup-writers.ps1')"
if(($raw.Split(@($line),[StringSplitOptions]::None)).Length -ne 2){throw 'Exactly one existing candidate-bound writer guard is required.'}
$body=[scriptblock]::Create($raw.Replace($line,''));$script:checks=0
$original=@{};foreach($name in 'OPENWEB_WINDOWS_NATIVE_TEST','GITHUB_ACTIONS','RUNNER_ENVIRONMENT','RUNNER_OS','GITHUB_REPOSITORY'){$original[$name]=[Environment]::GetEnvironmentVariable($name)}
function Check([bool]$value,[string]$label){if(!$value){throw ('CDR identity control failed: '+$label)};$script:checks++}
function Get-NativeCleanupWriterState {$script:guard++;if($script:mode -ceq 'candidate_failure'){throw 'candidate hash refusal'};return @{Running=($script:mode -cne 'stopped')}}
function Get-CimInstance($ClassName,$Filter,$ErrorAction){
 if($ClassName -ceq 'Win32_Service'){
  if($script:mode -ceq 'service_missing'){return @()}
  $svc=[pscustomobject]@{State='Running';ProcessId=321}
  if($script:mode -ceq 'service_stopped'){$svc.State='Stopped'}
  if($script:mode -ceq 'service_zero_pid'){$svc.ProcessId=0}
  if($script:mode -ceq 'service_duplicate'){return @($svc,$svc)}
  return $svc
 }
 if($Filter -like 'ProcessId=*'){
  if($script:mode -ceq 'process_missing'){return @()}
  $proc=[pscustomobject]@{ExecutablePath='C:\OpenWebPBX\server\OpenWebPbx.Server.exe';ProcessId=321;OwnerSid='S-1-5-19';OwnerReturn=0}
  if($script:mode -ceq 'process_duplicate'){return @($proc,$proc)}
  if($script:mode -ceq 'foreign_exe'){$proc.ExecutablePath='C:\foreign\server.exe'}
  if($script:mode -ceq 'backend_system'){$proc.OwnerSid='S-1-5-18'}
  if($script:mode -ceq 'owner_failure'){$proc.OwnerReturn=1}
  return $proc
 }
 if($Filter -ceq "Name='php.exe'"){
  if($script:mode -cin 'child_local','child_system','child_foreign_parent','child_owner_failure','foreign_php','other_script'){
   $child=[pscustomobject]@{ExecutablePath='C:\OpenWebPBX\php\php.exe';CommandLine='php.exe C:/OpenWebPBX/web/app/pbx_setup/call_records.php';ParentProcessId=321;OwnerSid='S-1-5-19';OwnerReturn=0}
   if($script:mode -ceq 'child_system'){$child.OwnerSid='S-1-5-18'}
   if($script:mode -ceq 'child_foreign_parent'){$child.ParentProcessId=999}
   if($script:mode -ceq 'child_owner_failure'){$child.OwnerReturn=1}
   if($script:mode -ceq 'foreign_php'){$child.ExecutablePath='C:\foreign\php.exe'}
   if($script:mode -ceq 'other_script'){$child.CommandLine='php.exe C:\OpenWebPBX\web\app\pbx_setup\cleanup.php'}
   return $child
  };return @()
 };throw 'An unplanned native API query is refused.'
}
function Invoke-CimMethod($InputObject,$MethodName,$ErrorAction){if($MethodName -cne 'GetOwnerSid'){throw 'Unexpected native method.'};return @{ReturnValue=$InputObject.OwnerReturn;Sid=$InputObject.OwnerSid}}
function Run([string]$mode,[bool]$pass){
 $script:mode=$mode;$script:guard=0;$errorRecord=$null;$out=$null
 try{$out=& $body -PackageRoot 'C:\candidate'|ConvertFrom-Json}catch{$errorRecord=$_}
 if($pass){
  Check ($null -eq $errorRecord) ('positive '+$mode)
  Check ($out.schema -eq 1 -and $out.producer -ceq 'windows_cdr_service.ps1' -and $out.state -ceq 'observed' -and $out.process_id -eq 321) ('closed identity '+$mode)
  Check (@($out.PSObject.Properties).Count -eq 8) ('exact field count '+$mode)
  foreach($flag in 'read_only','actual_localservice_identity','candidate_bound','no_separate_importer'){Check ($out.$flag -is [bool] -and $out.$flag) ('typed flag '+$mode)}
 }else{Check ($null -ne $errorRecord -and $null -eq $out) ('refusal '+$mode)}
 if($mode -cne 'environment'){Check ($script:guard -eq 1) ('actual candidate guard '+$mode)}
}
try{
 $env:OPENWEB_WINDOWS_NATIVE_TEST='1';$env:GITHUB_ACTIONS='true';$env:RUNNER_ENVIRONMENT='github-hosted';$env:RUNNER_OS='Windows';$env:GITHUB_REPOSITORY='embire2/openwebpbx'
 foreach($mode in 'normal','child_local','foreign_php','other_script'){Run $mode $true}
 foreach($mode in 'candidate_failure','stopped','service_missing','service_duplicate','service_stopped','service_zero_pid','process_missing','process_duplicate','foreign_exe','backend_system','owner_failure','child_system','child_foreign_parent','child_owner_failure'){Run $mode $false}
 $env:GITHUB_REPOSITORY='foreign/repo';Run 'environment' $false;Check ($script:guard -eq 0) 'foreign context refuses before native query'
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$errors);Check (!$errors.Count) 'actual source parses'
 $commands=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object {$_.GetCommandName()})
 foreach($name in 'Start-Service','Stop-Service','Set-Service','Invoke-NativeCleanupPhp','Suspend-NativeCleanupWriters','Php','Remove-Item','Set-Content','Copy-Item','Set-Acl'){Check ($name -cnotin $commands) ('no mutation command '+$name)}
 [ordered]@{schema=1;state='passed';checks=$script:checks;scope='actual_identity_script_with_native_API_adapters';actual_installed_importer=$false;installed_server_changed=$false}|ConvertTo-Json -Compress
}finally{foreach($name in $original.Keys){[Environment]::SetEnvironmentVariable($name,$original[$name])}}
