# QA-only, closed IIS/PHP observations. Importing this file changes nothing.
function Get-SuitePhpSourceName([string]$Path){
 $name=[IO.Path]::GetFileName($Path.Replace('\','/'))
 if($name -cin 'login.php','require.php','config.php','auto_loader.php','settings.php','cache.php','database.php','pbx_tenant_domains.php','permissions.php','functions.php','check_auth.php','token.php','auth.php','index.php'){return $name}
 return 'external_component'
}
function Read-SuiteIisErrorPage([string]$Body){
 $result=[ordered]@{state='unavailable';status=0;substatus=0;error_code='none';config_basename='none';config_line=0}
 if($Body.Length -gt 1MB){return $result};$text=[Net.WebUtility]::HtmlDecode($Body)
 $match=[regex]::Match($text,'(?i)HTTP Error (500)\.(\d{1,3})\b')
 if($match.Success){$result.state='read';$result.status=500;$result.substatus=[int]$match.Groups[2].Value}
 $match=[regex]::Match($text,'(?is)Error Code.{0,120}?(0x[0-9a-f]{8})\b');if($match.Success){$result.error_code=$match.Groups[1].Value.ToLowerInvariant()}
 $match=[regex]::Match($text,'(?is)Config File.{0,160}?<td[^>]*>(.{0,512}?)</td>')
 if($match.Success){$name=[IO.Path]::GetFileName(([regex]::Replace($match.Groups[1].Value,'<[^>]*>','')).Trim().Replace('\','/'));$result.config_basename=if($name -cin 'web.config','applicationHost.config','php.ini'){$name}else{'external_component'}}
 $match=[regex]::Match($text,'(?is)Config Source.{0,256}?<pre[^>]*>(.{0,4096}?)</pre>')
 if($match.Success){$plain=[regex]::Replace($match.Groups[1].Value,'<[^>]*>','');$line=[regex]::Match($plain,'(?m)^\s*([0-9]{1,6}):');if($line.Success){$result.config_line=[int]$line.Groups[1].Value}}
 return $result
}
function Read-SuiteIisLog([string]$Text,[DateTime]$StartedAt){
 $result=[ordered]@{state='unavailable';status=0;substatus=0;win32_status=0};$fields=$null
 foreach($line in $Text -split '\r?\n'){
  if($line.StartsWith('#Fields: ')){$fields=$line.Substring(9).Split(' ');continue}
  if(!$fields -or !$line -or $line.StartsWith('#')){continue};$parts=$line.Split(' ');if($parts.Count -ne $fields.Count){continue}
  $row=@{};for($i=0;$i -lt $fields.Count;$i++){$row[$fields[$i]]=$parts[$i]}
  if($row['cs-uri-stem'] -cne '/login.php' -or $row['cs-method'] -cne 'GET' -or $row['s-port'] -cne '8443' -or $row['c-ip'] -cnotin '127.0.0.1','::1'){continue}
  $stamp=[DateTime]::MinValue
  if(![DateTime]::TryParseExact(($row['date']+' '+$row['time']),'yyyy-MM-dd HH:mm:ss',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]'AssumeUniversal,AdjustToUniversal',[ref]$stamp) -or $stamp -lt $StartedAt.ToUniversalTime().AddSeconds(-3) -or $stamp -gt [DateTime]::UtcNow.AddSeconds(2)){continue}
  $status=0;$substatus=0;$win32=[long]0
  if(![int]::TryParse($row['sc-status'],[ref]$status) -or $status -lt 100 -or $status -gt 599 -or ![int]::TryParse($row['sc-substatus'],[ref]$substatus) -or $substatus -lt 0 -or $substatus -gt 999 -or ![long]::TryParse($row['sc-win32-status'],[ref]$win32) -or $win32 -lt 0 -or $win32 -gt 4294967295){continue}
  $result=[ordered]@{state='read';status=$status;substatus=$substatus;win32_status=$win32}
 }
 return $result
}
function Read-SuitePhpLog([string]$Text,[DateTime]$StartedAt){
 $result=[ordered]@{state='unavailable';error_class='none';source_basename='none';source_line=0}
 foreach($line in $Text -split '\r?\n'){
  $match=[regex]::Match($line,'^\[(\d{2}-[A-Za-z]{3}-\d{4} \d{2}:\d{2}:\d{2}) (?:UTC|GMT)\] PHP (Fatal error|Parse error|Warning|Notice|Deprecated): (.{0,4096})$')
  if(!$match.Success){continue};$stamp=[DateTime]::MinValue
  if(![DateTime]::TryParseExact($match.Groups[1].Value,'dd-MMM-yyyy HH:mm:ss',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]'AssumeUniversal,AdjustToUniversal',[ref]$stamp) -or $stamp -lt $StartedAt.ToUniversalTime().AddSeconds(-3) -or $stamp -gt [DateTime]::UtcNow.AddSeconds(2)){continue}
  $category=switch($match.Groups[2].Value){'Parse error'{'ParseError'};'Warning'{'warning'};'Notice'{'notice'};'Deprecated'{'deprecated'};default{'fatal_error'}}
  $body=$match.Groups[3].Value;$exceptionMatch=[regex]::Match($body,'\bUncaught (PDOException|TypeError|ValueError|ParseError|RuntimeException|InvalidArgumentException|ErrorException|Exception|Error)\b');if($exceptionMatch.Success){$category=$exceptionMatch.Groups[1].Value}
  $where=[regex]::Match($body,'\bin (.{1,512}?\.php)(?::| on line )([0-9]{1,6})\b')
  $result=[ordered]@{state='read';error_class=$category;source_basename=if($where.Success){Get-SuitePhpSourceName $where.Groups[1].Value}else{'external_component'};source_line=if($where.Success){[int]$where.Groups[2].Value}else{0}}
 }
 return $result
}
function Read-SuiteDiagnosticTail([string]$Path){
 $null=Assert-SuiteIndependentOrdinary $Path $false;$stream=[IO.File]::Open($Path,'Open','Read',([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
 try{$length=[int][Math]::Min($stream.Length,1MB);$null=$stream.Seek(-$length,[IO.SeekOrigin]::End);$bytes=New-Object byte[] $length;$offset=0;while($offset -lt $length){$read=$stream.Read($bytes,$offset,$length-$offset);if(!$read){break};$offset+=$read};return [Text.Encoding]::UTF8.GetString($bytes,0,$offset)}finally{$stream.Dispose()}
}
function ConvertTo-SuitePhpProbe($Record){
 if(($Record.schema -isnot [int] -and $Record.schema -isnot [long]) -or $Record.schema -ne 1 -or $Record.sapi -isnot [string] -or $Record.sapi -cnotin 'cli','cgi-fcgi','other'){return $null}
 foreach($name in 'ini_matches','pdo_pgsql','config_readable'){if($Record.$name -isnot [bool]){return $null}}
 if($Record.error_class -isnot [string] -or $Record.error_class -cnotin 'none','fatal_error','PDOException','TypeError','ValueError','ParseError','RuntimeException','InvalidArgumentException','ErrorException','Exception','Error' -or $Record.source_basename -isnot [string] -or $Record.source_basename -cnotin 'none','external_component','login.php','require.php','config.php','auto_loader.php','settings.php','cache.php','database.php','pbx_tenant_domains.php','permissions.php','functions.php','check_auth.php','token.php','auth.php','index.php'){return $null}
 foreach($pair in @(@('application_status',599),@('source_line',999999))){$value=$Record.($pair[0]);if(($value -isnot [int] -and $value -isnot [long]) -or $value -lt 0 -or $value -gt $pair[1]){return $null}}
 $safe=[ordered]@{schema=1};foreach($name in 'sapi','ini_matches','pdo_pgsql','config_readable','application_status','error_class','source_basename','source_line'){$safe[$name]=$Record.$name};return $safe
}
function ConvertTo-SuiteIisDiagnostics($Record){
 $integer={param($Value,[long]$Min,[long]$Max)return ($Value -is [int] -or $Value -is [long]) -and $Value -ge $Min -and $Value -le $Max}
 $source={param($Value)return $Value -is [string] -and ($Value -cin 'none','external_component' -or (Get-SuitePhpSourceName $Value) -ceq $Value)}
 if(!(& $integer $Record.schema 1 1)){return $null};$safe=[ordered]@{schema=1}
 foreach($name in 'error_page','w3c','php_log'){
  $value=$Record.$name;if($value.state -isnot [string] -or $value.state -cnotin 'read','unavailable'){return $null};$safe[$name]=[ordered]@{state=$value.state}
 }
 foreach($name in 'error_page','w3c'){
  foreach($pair in @(@('status',599),@('substatus',999))){$field=$pair[0];$value=$Record.$name.$field;if(!(& $integer $value 0 $pair[1])){return $null};$safe[$name][$field]=$value}
 }
 $value=$Record.error_page
 if($value.error_code -isnot [string] -or ($value.error_code -cne 'none' -and $value.error_code -cnotmatch '^0x[a-f0-9]{8}$') -or $value.config_basename -isnot [string] -or $value.config_basename -cnotin 'none','external_component','web.config','applicationHost.config','php.ini' -or !(& $integer $value.config_line 0 999999)){return $null}
 foreach($name in 'error_code','config_basename','config_line'){$safe.error_page[$name]=$value.$name}
 if(!(& $integer $Record.w3c.win32_status 0 4294967295)){return $null};$safe.w3c.win32_status=$Record.w3c.win32_status
 $value=$Record.php_log
 if($value.error_class -isnot [string] -or $value.error_class -cnotin 'none','fatal_error','warning','notice','deprecated','PDOException','TypeError','ValueError','ParseError','RuntimeException','InvalidArgumentException','ErrorException','Exception','Error' -or !(& $source $value.source_basename) -or !(& $integer $value.source_line 0 999999)){return $null}
 foreach($name in 'error_class','source_basename','source_line'){$safe.php_log[$name]=$value.$name}
 $value=$Record.mwa
 if(!(& $integer $value.schema 1 1) -or $value.state -isnot [string] -or $value.state -cnotin 'read','error','unavailable' -or $value.stage -isnot [string] -or $value.stage -cnotin 'none','assembly','site','handlers','rewrite','websocket','default_document','complete' -or $value.error_type -isnot [string] -or $value.error_type -cnotin 'none','unknown','RuntimeException','MethodInvocationException','InvalidOperationException','COMException','FileLoadException','FileNotFoundException','DirectoryNotFoundException','UnauthorizedAccessException','ConfigurationErrorsException','ArgumentException','Exception' -or !(& $integer $value.hresult ([int]::MinValue) ([int]::MaxValue))){return $null}
 $safe.mwa=[ordered]@{};foreach($name in 'schema','state','stage','error_type','hresult'){$safe.mwa[$name]=$value.$name}
 $value=$Record.probe
 if($value.state -isnot [string] -or $value.state -cnotin 'read','unavailable' -or $value.fixture_cleanup -isnot [bool] -or !(& $integer $value.cgi_status 0 599)){return $null}
 $safe.probe=[ordered]@{state=$value.state;fixture_cleanup=$value.fixture_cleanup;cgi_status=$value.cgi_status;cli=$null;cgi=$null}
 foreach($name in 'cli','cgi'){if($null -ne $value.$name){$entry=ConvertTo-SuitePhpProbe $value.$name;if($null -eq $entry){return $null};$safe.probe[$name]=$entry}}
 return $safe
}
function Get-SuiteIndependentIisDiagnostics([DateTime]$StartedAt,[string]$Body,[string]$PrivateDirectory,$Client,$SessionIds){
 $result=[ordered]@{schema=1;error_page=(Read-SuiteIisErrorPage $Body);w3c=(Read-SuiteIisLog '' $StartedAt);php_log=(Read-SuitePhpLog '' $StartedAt);mwa=[ordered]@{schema=1;state='unavailable';stage='none';error_type='none';hresult=0};probe=[ordered]@{state='unavailable';fixture_cleanup=$true;cgi_status=0;cli=$null;cgi=$null}}
 try{$result.php_log=Read-SuitePhpLog (Read-SuiteDiagnosticTail (Join-Path $env:ProgramData 'OpenWebPBX\logs\php.log')) $StartedAt}catch{}
 try{
  $config=Join-Path $env:windir 'System32\inetsrv\config\applicationHost.config';$null=Assert-SuiteIndependentOrdinary $config $false
  $settings=[Xml.XmlReaderSettings]::new();$settings.DtdProcessing='Prohibit';$settings.XmlResolver=$null;$settings.MaxCharactersInDocument=32MB;$reader=[Xml.XmlReader]::Create($config,$settings);$xml=[xml]::new();$xml.XmlResolver=$null;try{$xml.Load($reader)}finally{$reader.Dispose()}
  $site=$xml.SelectSingleNode('/configuration/system.applicationHost/sites/site[@name="OpenWebPBX"]');$v=$site.SelectSingleNode('application[@path="/"]/virtualDirectory[@path="/"]')
  if(!$site -or $site.GetAttribute('id') -cnotmatch '^[1-9][0-9]{0,8}$' -or [IO.Path]::GetFullPath($v.GetAttribute('physicalPath')).TrimEnd('\') -ine 'C:\OpenWebPBX\web'){throw 'Owned site required.'}
  $log=Join-Path ($env:SystemDrive+'\') ('inetpub\logs\LogFiles\W3SVC'+$site.GetAttribute('id'))
  foreach($date in @($StartedAt.ToUniversalTime().ToString('yyMMdd'),[DateTime]::UtcNow.ToString('yyMMdd'),(Get-Date).ToString('yyMMdd'))|Select-Object -Unique){$path=Join-Path $log ('u_ex'+$date+'.log');if(Test-Path -LiteralPath $path){$entry=Read-SuiteIisLog (Read-SuiteDiagnosticTail $path) $StartedAt;if($entry.state -ceq 'read'){$result.w3c=$entry}}}
 }catch{}
 try{
  $report=Join-Path $PrivateDirectory 'iis-native-health.json';$start=[Diagnostics.ProcessStartInfo]::new((Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'));$start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.Environment['PSModulePath']=(Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\Modules')+';'+(Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules')
  foreach($arg in @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'windows-suite-iis-observer.ps1'),'-ReportPath',$report)){$start.ArgumentList.Add($arg)}
  $process=[Diagnostics.Process]::Start($start);$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
  try{
   if(!$process.WaitForExit(10000)){$process.Kill($true);throw 'The owned read-only observer timed out.'}
   [IO.File]::WriteAllText((Join-Path $PrivateDirectory 'iis-native.private.out'),$stdout.GetAwaiter().GetResult());[IO.File]::WriteAllText((Join-Path $PrivateDirectory 'iis-native.private.err'),$stderr.GetAwaiter().GetResult())
   $null=Assert-SuiteIndependentOrdinary $report $false;$item=Get-Item -LiteralPath $report;if($item.Length -gt 8192 -or $process.ExitCode){throw 'Invalid native observer report.'};$entry=Get-Content -LiteralPath $report -Raw|ConvertFrom-Json
   if($entry.schema -ne 1 -or $entry.state -cnotin 'read','error' -or $entry.stage -cnotin 'assembly','site','handlers','rewrite','websocket','default_document','complete' -or $entry.error_type -cnotin 'none','unknown','RuntimeException','MethodInvocationException','InvalidOperationException','COMException','FileLoadException','FileNotFoundException','DirectoryNotFoundException','UnauthorizedAccessException','ConfigurationErrorsException','ArgumentException','Exception' -or ($entry.hresult -isnot [int] -and $entry.hresult -isnot [long]) -or $entry.hresult -lt [int]::MinValue -or $entry.hresult -gt [int]::MaxValue){throw 'Invalid native observer fields.'}
   $result.mwa=[ordered]@{schema=1;state=$entry.state;stage=$entry.stage;error_type=$entry.error_type;hresult=[int]$entry.hresult}
  }finally{$process.Dispose()}
 }catch{}
 $fixture=$null;$fixtureBytes=$null;$fixtureOwned=$false;$response=$null
 try{
  $nonce=[Guid]::NewGuid().ToString('N')+[Guid]::NewGuid().ToString('N');$name='openweb-iis-qa-'+[Guid]::NewGuid().ToString('N')+'.php';$fixture=Join-Path 'C:\OpenWebPBX\web' $name
  $source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'windows-suite-iis-probe.php'));if(([regex]::Matches($source,'__OPENWEB_QA_NONCE__')).Count -ne 1 -or ([regex]::Matches($source,'__OPENWEB_QA_EXPIRES__')).Count -ne 1){throw 'The exact QA template is required.'};$fixtureBytes=[Text.UTF8Encoding]::new($false).GetBytes($source.Replace('__OPENWEB_QA_NONCE__',$nonce).Replace('__OPENWEB_QA_EXPIRES__',[DateTimeOffset]::UtcNow.AddMinutes(2).ToUnixTimeSeconds().ToString()));$null=Assert-SuiteIndependentOrdinary 'C:\OpenWebPBX\web' $true
  $file=[IO.File]::Open($fixture,'CreateNew','Write','None');$fixtureOwned=$true;try{$file.Write($fixtureBytes,0,$fixtureBytes.Length)}finally{$file.Dispose()}
  $raw=& 'C:\OpenWebPBX\php\php.exe' $fixture $nonce 2> (Join-Path $PrivateDirectory 'iis-probe-cli.private.err');$exit=$LASTEXITCODE
  if($exit -eq 0 -and ($raw -join "`n").Length -lt 8192){$result.probe.cli=ConvertTo-SuitePhpProbe (($raw -join "`n")|ConvertFrom-Json)}
  $response=$Client.GetAsync(('https://windowsqa.example.invalid:8443/'+$name+'?nonce='+$nonce)).GetAwaiter().GetResult();$result.probe.cgi_status=[int]$response.StatusCode
  if($response.Headers.Contains('Set-Cookie')){foreach($cookie in $response.Headers.GetValues('Set-Cookie')){foreach($match in [regex]::Matches($cookie,'(?:^|[,;]\s*)PHPSESSID=([a-zA-Z0-9,-]{16,128})(?:;|$)')){[void]$SessionIds.Add($match.Groups[1].Value)}}}
  $raw=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult();if($result.probe.cgi_status -eq 200 -and $raw.Length -lt 8192){$result.probe.cgi=ConvertTo-SuitePhpProbe ($raw|ConvertFrom-Json)}
  $result.probe.state='read'
 }catch{}
 finally{
  if($response){$response.Dispose()}
  if($fixtureOwned -and (Test-Path -LiteralPath $fixture)){
   try{$null=Assert-SuiteIndependentOrdinary $fixture $false;if([Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture)) -cne [Convert]::ToBase64String($fixtureBytes)){throw 'The own diagnostic fixture changed.'};Remove-Item -LiteralPath $fixture -Force}catch{$result.probe.fixture_cleanup=$false}
  }
 }
 try{$result.php_log=Read-SuitePhpLog (Read-SuiteDiagnosticTail (Join-Path $env:ProgramData 'OpenWebPBX\logs\php.log')) $StartedAt}catch{}
 return $result
}
