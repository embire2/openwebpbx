# Closed parser/projector controls with fictional logs; no IIS/PHP/server invoked.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
. (Join-Path $SourceRoot 'tests/windows-suite-iis-diagnostics.ps1')
$checks=0
function Assert([bool]$Value){if(!$Value){throw ('Closed IIS diagnostics failed at test line '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
$now=[DateTime]::UtcNow;$stamp=$now.ToString('yyyy-MM-dd HH:mm:ss',[Globalization.CultureInfo]::InvariantCulture)
$html='<h3>HTTP Error 500.19 - Internal Server Error</h3><tr><th>Error Code</th><td>0x80070021</td></tr><tr><th>Config File</th><td>C:\PRIVATE_NEVER_PUBLISH\web.config</td></tr><h4>Config Source</h4><pre><code>   23: PRIVATE_NEVER_PUBLISH</code></pre>'
$page=Read-SuiteIisErrorPage $html
Assert ($page.state -ceq 'read' -and $page.status -eq 500 -and $page.substatus -eq 19 -and $page.error_code -ceq '0x80070021' -and $page.config_basename -ceq 'web.config' -and $page.config_line -eq 23)
Assert (($page|ConvertTo-Json) -cnotmatch 'PRIVATE_NEVER_PUBLISH|C:')
Assert ((Read-SuiteIisErrorPage ('x'*1048577)).state -ceq 'unavailable')
$header='#Fields: date time cs-method cs-uri-stem cs-uri-query s-port c-ip sc-status sc-substatus sc-win32-status'
$line=$stamp+' GET /login.php PRIVATE_NEVER_PUBLISH 8443 127.0.0.1 500 19 13'
$w3c=Read-SuiteIisLog ($header+"`n"+$line) $now
Assert ($w3c.state -ceq 'read' -and $w3c.status -eq 500 -and $w3c.substatus -eq 19 -and $w3c.win32_status -eq 13)
Assert (($w3c|ConvertTo-Json) -cnotmatch 'PRIVATE_NEVER_PUBLISH|login|127\.0')
foreach($replace in @(@('/login.php','/PRIVATE_NEVER_PUBLISH'),@('127.0.0.1','198.51.100.2'),@('8443','443'),@(' GET ',' POST '),@('500 19 13','500 1000 13'),@('500 19 13','500 19 4294967296'),@('500 19 13','500.1 19 13'))){Assert ((Read-SuiteIisLog ($header+"`n"+$line.Replace($replace[0],$replace[1])) $now).state -ceq 'unavailable')}
Assert ((Read-SuiteIisLog ($header+"`n"+$line) $now.AddMinutes(2)).state -ceq 'unavailable')
$phpStamp=$now.ToString('dd-MMM-yyyy HH:mm:ss',[Globalization.CultureInfo]::InvariantCulture)
$php='['+$phpStamp+' UTC] PHP Fatal error: Uncaught PDOException: PRIVATE_NEVER_PUBLISH in C:\PRIVATE_NEVER_PUBLISH\pbx_tenant_domains.php:123'
$log=Read-SuitePhpLog $php $now
Assert ($log.state -ceq 'read' -and $log.error_class -ceq 'PDOException' -and $log.source_basename -ceq 'pbx_tenant_domains.php' -and $log.source_line -eq 123)
Assert (($log|ConvertTo-Json) -cnotmatch 'PRIVATE_NEVER_PUBLISH|C:')
Assert ((Read-SuitePhpLog ($php.Replace('pbx_tenant_domains.php','PRIVATE_NEVER_PUBLISH.php')) $now).source_basename -ceq 'external_component')
Assert ((Read-SuitePhpLog $php $now.AddMinutes(2)).state -ceq 'unavailable')
Assert ((Read-SuitePhpLog $php.Replace(' UTC]',' UNKNOWN]') $now).state -ceq 'unavailable')
function Probe {
 [pscustomobject]@{schema=1;sapi='cgi-fcgi';ini_matches=$true;pdo_pgsql=$true;config_readable=$true;application_status=500;error_class='PDOException';source_basename='pbx_tenant_domains.php';source_line=123;password='PRIVATE_NEVER_PUBLISH';body='PRIVATE_NEVER_PUBLISH'}
}
$safe=ConvertTo-SuitePhpProbe (Probe);Assert ($safe.error_class -ceq 'PDOException' -and ($safe|ConvertTo-Json) -cnotmatch 'PRIVATE_NEVER_PUBLISH|password|body')
foreach($field in 'schema','sapi','ini_matches','pdo_pgsql','config_readable','application_status','error_class','source_basename','source_line'){
 foreach($bad in $null,'PRIVATE_NEVER_PUBLISH',@('PRIVATE_NEVER_PUBLISH')){$record=Probe;$record.$field=$bad;Assert ($null -eq (ConvertTo-SuitePhpProbe $record))}
}
function Diagnostic {
 [pscustomobject]@{schema=1;error_page=$page;w3c=$w3c;php_log=$log;mwa=[pscustomobject]@{schema=1;state='error';stage='handlers';error_type='COMException';hresult=-2147024863;message='PRIVATE_NEVER_PUBLISH'};probe=[pscustomobject]@{state='read';fixture_cleanup=$true;cgi_status=200;cli=(Probe);cgi=(Probe);password='PRIVATE_NEVER_PUBLISH'};body='PRIVATE_NEVER_PUBLISH'}
}
$safe=ConvertTo-SuiteIisDiagnostics (Diagnostic)
Assert ($safe.mwa.hresult -eq -2147024863 -and $safe.php_log.error_class -ceq 'PDOException' -and $safe.probe.fixture_cleanup)
Assert (($safe|ConvertTo-Json -Depth 8) -cnotmatch 'PRIVATE_NEVER_PUBLISH|password|message|body')
foreach($pair in @(@('error_page','error_code'),@('error_page','config_basename'),@('error_page','config_line'),@('w3c','win32_status'),@('php_log','error_class'),@('php_log','source_basename'),@('php_log','source_line'),@('mwa','stage'),@('mwa','error_type'),@('mwa','hresult'),@('probe','fixture_cleanup'),@('probe','cgi_status'))){
 $record=(Diagnostic)|ConvertTo-Json -Depth 8|ConvertFrom-Json;$record.($pair[0]).($pair[1])='PRIVATE_NEVER_PUBLISH';Assert ($null -eq (ConvertTo-SuiteIisDiagnostics $record))
}
$record=Diagnostic;$record.probe.fixture_cleanup=$false;Assert (!(ConvertTo-SuiteIisDiagnostics $record).probe.fixture_cleanup)
$phpSource=[IO.File]::ReadAllText((Join-Path $SourceRoot 'tests/windows-suite-iis-probe.php'))
foreach($fence in @('REMOTE_ADDR','HTTP_HOST','REQUEST_METHOD','hash_equals','time()>$expires','register_shutdown_function','error_get_last','C:/OpenWebPBX/web/login.php','if(!$openwebQaCli){')){Assert ($phpSource.Contains($fence))}
Assert ($phpSource -cnotmatch 'phpinfo\s*\(')
Write-Output ('PASS '+$checks+' actual IIS/PHP parser, scope and privacy controls; no server invoked')
