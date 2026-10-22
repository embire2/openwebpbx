# QA only. Importing this helper performs no server or filesystem operation.
. (Join-Path $PSScriptRoot 'windows-suite-iis-diagnostics.ps1')
function Get-SuiteIndependentFailureClass($Failure){
 $depth=0
 for($exception=$Failure.Exception;$exception -and $depth -lt 5;$exception=$exception.InnerException){
  $depth++
  if($exception -is [Security.Authentication.AuthenticationException]){return 'tls'}
  if($exception -is [Threading.Tasks.TaskCanceledException] -or $exception -is [TimeoutException]){return 'timeout'}
 }
 return 'transport'
}
function Assert-SuiteIndependentOrdinary([string]$Path,[bool]$Directory){
 $full=[IO.Path]::GetFullPath($Path);$item=Get-Item -LiteralPath $full -Force
 if([bool]$item.PSIsContainer -ne $Directory){throw 'The owned health path has an unexpected type.'}
 for($current=$full;$current;$current=[IO.Path]::GetDirectoryName($current)){
  if((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'The owned health path contains a redirect.'}
  if([IO.Path]::GetDirectoryName($current) -eq $current){break}
 }
 return $full
}
function Get-SuiteIndependentHealth {
 if($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:RUNNER_OS -ne 'Windows' -or $env:GITHUB_REPOSITORY -ne 'embire2/openwebpbx'){throw 'Disposable hosted independent health checks required.'}
 $result=[ordered]@{schema=1;local_service=$false;local_version_matches=$false;trusted_iis=$false;local_class='transport';iis_class='transport';iis_status=0}
 try{
  $health=Invoke-RestMethod -Uri 'http://127.0.0.1:8087/health' -TimeoutSec 5 -MaximumRedirection 0
  if($health.state -is [string] -and $health.state -ceq 'Running'){$result.local_service=$true;$result.local_class='running'}else{$result.local_class='response'}
  try{
   $installationPath=Assert-SuiteIndependentOrdinary (Join-Path $env:ProgramData 'OpenWebPBX\installation.json') $false
   if((Get-Item -LiteralPath $installationPath).Length -le 65536){$installation=Get-Content -LiteralPath $installationPath -Raw|ConvertFrom-Json;$result.local_version_matches=$health.version -is [string] -and $installation.Version -is [string] -and $health.version -cmatch '^\d+\.\d+\.\d+$' -and $health.version -ceq $installation.Version}
  }catch{}
 }catch{$result.local_class=Get-SuiteIndependentFailureClass $_}
 $handler=$null;$client=$null;$response=$null;$stream=$null;$sessionRoot=$null;$sessionBefore=$null;$sessionIds=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
 try{
  $sessionRoot=Assert-SuiteIndependentOrdinary (Join-Path $env:ProgramData 'OpenWebPBX\sessions') $true
  $sessionBefore=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach($item in Get-ChildItem -LiteralPath $sessionRoot -File -Force){[void]$sessionBefore.Add($item.Name)}
  $handler=[Net.Http.HttpClientHandler]::new();$handler.AllowAutoRedirect=$false;$handler.UseProxy=$false;$handler.UseCookies=$false
  $client=[Net.Http.HttpClient]::new($handler);$client.Timeout=[TimeSpan]::FromSeconds(10);$client.MaxResponseContentBufferSize=1MB;$observedAt=[DateTime]::UtcNow
  # Normal operating-system CA, hostname and revocation behavior is retained.
  # No validation callback or insecure transport option is installed.
  $response=$client.GetAsync('https://windowsqa.example.invalid:8443/login.php',[Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
  $result.iis_status=[int]$response.StatusCode
  if($response.Headers.Contains('Set-Cookie')){
   foreach($cookie in $response.Headers.GetValues('Set-Cookie')){foreach($match in [regex]::Matches($cookie,'(?:^|[,;]\s*)PHPSESSID=([a-zA-Z0-9,-]{16,128})(?:;|$)')){[void]$sessionIds.Add($match.Groups[1].Value)}}
  }
  $body=''
  try{
   $stream=$response.Content.ReadAsStreamAsync().GetAwaiter().GetResult();$bytes=[IO.MemoryStream]::new();$buffer=New-Object byte[] 8192;$cancel=[Threading.CancellationTokenSource]::new(10000)
   try{
    while(($count=$stream.ReadAsync($buffer,0,$buffer.Length,$cancel.Token).GetAwaiter().GetResult()) -gt 0){if($bytes.Length+$count -gt 1MB){throw 'The health response exceeded its bound.'};$bytes.Write($buffer,0,$count)}
    $body=[Text.Encoding]::UTF8.GetString($bytes.ToArray())
   }finally{$cancel.Dispose();$bytes.Dispose()}
  }catch{if($result.iis_status -eq 200){throw}}
  if($result.iis_status -ne 200){$result.iis_class='http_status'}elseif($response.Content.Headers.ContentType.MediaType -ceq 'text/html' -and $body -match '<form\b' -and $body -match 'name=["'']username["'']' -and $body -match 'name=["'']password["'']'){$result.trusted_iis=$true;$result.iis_class='ready'}else{$result.iis_class='content'}
  if($result.iis_status -ge 500){try{$result.iis_diagnostics=Get-SuiteIndependentIisDiagnostics $observedAt $body $work $client $sessionIds}catch{}}
 }catch{$result.iis_class=Get-SuiteIndependentFailureClass $_}
 finally{
  if($stream){$stream.Dispose()};if($response){$response.Dispose()};if($client){$client.Dispose()}elseif($handler){$handler.Dispose()}
  try{
   foreach($id in $sessionIds){
    $name='sess_'+$id
    if(!$sessionRoot -or $null -eq $sessionBefore -or $sessionBefore.Contains($name)){throw 'The anonymous health session was not newly owned.'}
    $path=Join-Path $sessionRoot $name
    if(Test-Path -LiteralPath $path){$null=Assert-SuiteIndependentOrdinary $path $false;Remove-Item -LiteralPath $path -Force}
   }
  }catch{$result.trusted_iis=$false;$result.iis_class='cleanup_refused'}
 }
 return $result
}
function TenantDomainsAcceptanceHook([DateTime]$StartedAt){
 try{TenantDomainsHook;if($facts.gates.tenant_domains -cne 'passed'){throw 'The native tenant gate did not produce its required result.'};return}
 catch{
  $failure=$_;RememberSuiteFailure $failure 'native tenant-domain qualification';$facts.gates.tenant_domains='unqualified'
  try{
   $path=Join-Path $work 'tenant-domains-native.json';$null=Assert-SuiteIndependentOrdinary $path $false;$file=Get-Item -LiteralPath $path -Force
   if($file.Length -lt 2 -or $file.Length -gt 65536 -or $file.LastWriteTimeUtc -lt $StartedAt.ToUniversalTime().AddSeconds(-2) -or $file.LastWriteTimeUtc -gt [DateTime]::UtcNow.AddSeconds(2)){throw 'The native tenant report is invalid.'}
   $record=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json;$safe=SafeTenantDomainsReport $record
   if(!$safe -or $safe.cleanup_exact -isnot [bool] -or !$safe.cleanup_exact -or $record.phase -cin 'cleanup','complete' -or $record.actual_acme -isnot [string] -or $record.actual_acme -cne 'unqualified' -or $record.real_registry_dns_mutations -isnot [bool] -or $record.real_registry_dns_mutations -or ($record.checks -isnot [int] -and $record.checks -isnot [long]) -or $record.checks -lt 0 -or $record.checks -gt 1000){throw 'Exact owned fixture recovery is not proved.'}
   $facts.tenant_domains_failure=$safe
  }catch{$facts.tenant_domains_continuation='aborted_report';throw $failure}
  $health=[ordered]@{schema=1;engine_idle=$false;local_service=$false;trusted_iis=$false;local_class='unavailable';iis_class='unavailable';iis_status=0}
  try{
   $observer=NativeStartupFailure -StartedAt $StartedAt -PrivateDirectory $work
   $health.engine_idle=[bool](NativeIdleIsHealthy $observer)
   $web=Get-SuiteIndependentHealth
   if(($web.schema -isnot [int] -and $web.schema -isnot [long]) -or $web.schema -ne 1 -or $web.local_service -isnot [bool] -or $web.trusted_iis -isnot [bool] -or $web.local_class -isnot [string] -or $web.local_class -cnotin 'running','response','tls','timeout','transport' -or $web.iis_class -isnot [string] -or $web.iis_class -cnotin 'ready','tls','timeout','http_status','content','transport','cleanup_refused' -or ($web.iis_status -isnot [int] -and $web.iis_status -isnot [long]) -or ($web.iis_status -ne 0 -and ($web.iis_status -lt 100 -or $web.iis_status -gt 599))){throw 'The independent health record is invalid.'}
   foreach($name in 'local_service','trusted_iis','local_class','iis_class','iis_status'){$health[$name]=$web.$name}
   if($web.local_version_matches -is [bool]){$health.local_version_matches=$web.local_version_matches}
   if($null -ne $web.iis_diagnostics){$diagnostics=ConvertTo-SuiteIisDiagnostics $web.iis_diagnostics;if($null -ne $diagnostics){$health.iis_diagnostics=$diagnostics;if(!$diagnostics.probe.fixture_cleanup){$health.trusted_iis=$false;$health.iis_class='cleanup_refused'}}}
   $facts.tenant_domains_independent_health=$health
   if(!$health.engine_idle -or !$health.local_service -or !$health.trusted_iis -or $health.local_class -cne 'running' -or $health.iis_class -cne 'ready' -or $health.iis_status -ne 200){throw 'Independent idle service and trusted IIS health are not proved.'}
  }catch{$facts.tenant_domains_independent_health=$health;$facts.tenant_domains_continuation='aborted_health';throw $failure}
  # Later evidence is independent. This failed gate and primary failure remain.
  $facts.tenant_domains_continuation='independent gates only'
 }
}

function PhoneHealthAcceptanceHook([DateTime]$StartedAt){
 try{PhoneHealthHook;if($facts.gates.phone_health -cne 'passed'){throw 'The native phone health gate did not produce its required result.'};return}
 catch{
  $failure=$_;RememberSuiteFailure $failure 'native phone health qualification';$facts.gates.phone_health='unqualified'
  $facts.release_eligible=$false;$facts.owner_transaction_eligible=$false
  try{
   # This exception is diagnostic replay only. Normal complete qualification
   # still stops on this failed feature. No flag can turn the failure green.
   if(!$ReplaySuiteRunId -or $ReplaySuiteRunId -cnotmatch '^[1-9][0-9]{0,19}$'){throw 'Only an explicit unchanged-candidate replay may continue.'}
   $path=Join-Path $work 'phone-health-native.json';$null=Assert-SuiteIndependentOrdinary $path $false;$file=Get-Item -LiteralPath $path -Force
   if($file.Length -lt 2 -or $file.Length -gt 65536 -or $file.LastWriteTimeUtc -lt $StartedAt.ToUniversalTime().AddSeconds(-2) -or $file.LastWriteTimeUtc -gt [DateTime]::UtcNow.AddSeconds(2)){throw 'The native phone health report is invalid.'}
   $record=Get-Content -LiteralPath $path -Raw|ConvertFrom-Json;$safe=SafePhoneHealthFailure $record
   if(($record.schema -isnot [int] -and $record.schema -isnot [long]) -or $record.schema -ne 1 -or $record.producer -isnot [string] -or $record.producer -cne 'windows_phone_health_acceptance.ps1' -or $record.state -isnot [string] -or $record.state -cne 'failed' -or $record.actual_native_windows -isnot [bool] -or !$record.actual_native_windows -or $record.physical_phone_audio -isnot [bool] -or $record.physical_phone_audio -or $record.policy_signalling_doubles -isnot [bool] -or !$record.policy_signalling_doubles -or $record.diagnostic_recovery_exact -isnot [bool] -or !$record.diagnostic_recovery_exact -or $safe.diagnostic_recovery_exact -isnot [bool] -or !$safe.diagnostic_recovery_exact -or @($record.PSObject.Properties.Name|Where-Object {$_ -ceq 'diagnostic_recovery_failure'}).Count){throw 'Exact native-worker recovery is not proved.'}
   foreach($gate in 'installed_task','installed_system_observer','installed_continuous_observer','installed_restart','installed_collector','cleanup'){if($record.gates.$gate -isnot [string] -or $record.gates.$gate -cne 'passed'){throw 'The recovered native worker prerequisites are incomplete.'}}
   if($record.gates.native_worker -isnot [string] -or $record.gates.native_worker -cnotin 'pending','failed'){throw 'Only the failed native worker case may continue.'}
   $facts.phone_health_failure=$safe
  }catch{$facts.phone_health_continuation='aborted_report';throw $failure}
  $health=[ordered]@{schema=1;engine_idle=$false;local_service=$false;local_version_matches=$false;trusted_iis=$false}
  try{
   $observer=NativeStartupFailure -StartedAt $StartedAt -PrivateDirectory $work;$health.engine_idle=[bool](NativeIdleIsHealthy $observer)
   $web=Get-SuiteIndependentHealth
   if(($web.schema -isnot [int] -and $web.schema -isnot [long]) -or $web.schema -ne 1 -or $web.local_service -isnot [bool] -or $web.local_version_matches -isnot [bool] -or $web.trusted_iis -isnot [bool] -or $web.local_class -isnot [string] -or $web.local_class -cne 'running' -or $web.iis_class -isnot [string] -or $web.iis_class -cne 'ready' -or ($web.iis_status -isnot [int] -and $web.iis_status -isnot [long]) -or $web.iis_status -ne 200){throw 'The independent recovered health record is invalid.'}
   foreach($name in 'local_service','local_version_matches','trusted_iis'){$health[$name]=$web.$name}
   $facts.phone_health_independent_health=$health
   if(!$health.engine_idle -or !$health.local_service -or !$health.local_version_matches -or !$health.trusted_iis){throw 'Independent idle service and trusted IIS health are not proved.'}
  }catch{$facts.phone_health_independent_health=$health;$facts.phone_health_continuation='aborted_health';throw $failure}
  $facts.phone_health_continuation='independent gates only'
 }
}
