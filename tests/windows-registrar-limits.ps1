#Requires -Version 7.4
# SPDX-License-Identifier: AGPL-3.0-or-later
#Requires -RunAsAdministrator
param(
 [Parameter(Mandatory)][string]$EngineRoot,
 [Parameter(Mandatory)][string]$CandidateModule,
 [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedCandidateSha256,
 [Parameter(Mandatory)][string]$Python,
 [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedPythonSha256,
 [Parameter(Mandatory)][string]$Report,
 [switch]$DisposableHostedRunner
)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$engine=[IO.Path]::GetFullPath($EngineRoot)
if(!$DisposableHostedRunner -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:RUNNER_OS -ne 'Windows' -or $env:GITHUB_REPOSITORY -ne 'embire2/openwebpbx'){throw 'Only a disposable hosted Windows runner is allowed.'}
$prefix=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')+'\'
foreach($path in $EngineRoot,$CandidateModule,$Report){if(![IO.Path]::GetFullPath($path).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Private native inputs must belong to this runner.'}}
function Hash([string]$Path){(Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant()}
if((Hash $CandidateModule) -ne $ExpectedCandidateSha256){throw 'Exact qualified registrar required.'}
if((Hash $Python) -ne $ExpectedPythonSha256){throw 'Exact private Python required.'}
$pins=@{'FreeSwitch.dll'='8553d88348093d5067d93369aa9793b38fe9e3c9c9ca0c38216791700bd7f726';'pthread.dll'='2d9d70378f13dcc06eed72005e74a12c6f7ba085e5fd31f97be49b7ef87cfdad';'mod\mod_sofia.dll'='ccf98b4c8ff99f2d670e88ec605f837795e4b878a2984c1df2ea36d9319aeff5'}
foreach($file in $pins.Keys){if((Hash (Join-Path $engine $file)) -ne $pins[$file]){throw 'The exact original MSI native family is required.'}}
foreach($port in 18224,19264){$tcp=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$port);try{$tcp.Start()}finally{$tcp.Stop()}}
$udp=[Net.Sockets.UdpClient]::new();try{$udp.Client.Bind([Net.IPEndPoint]::new([Net.IPAddress]::Loopback,19264))}finally{$udp.Dispose()}
$id=[Guid]::NewGuid().ToString('N').Substring(0,24);$root=Join-Path $env:RUNNER_TEMP ('openwebpbx-native-limits-'+$id)
New-Item -ItemType Directory -Path $root|Out-Null
& icacls.exe $root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F'|Out-Null
if($LASTEXITCODE){throw 'Private probe ACL failed.'}
function WritePrivate([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))}
foreach($part in 'conf','conf\autoload_configs','mod','db','log','run','scripts','sounds','recordings'){New-Item -ItemType Directory -Path (Join-Path $root $part)|Out-Null}
foreach($file in Get-ChildItem -LiteralPath $engine -File|Where-Object {$_.Extension -in '.dll','.exe'}){Copy-Item -LiteralPath $file.FullName -Destination $root}
foreach($file in 'mod_commands.dll','mod_event_socket.dll','mod_console.dll','mod_logfile.dll'){Copy-Item -LiteralPath "$engine\mod\$file" -Destination "$root\mod"}
Copy-Item -LiteralPath $CandidateModule -Destination "$root\mod\mod_sofia.dll"
foreach($file in 'windows-registrar-limits.py','sip_trunk_live.py','pbx_v20_restore_native.py'){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $root}
$random=[Security.Cryptography.RandomNumberGenerator]::Create();function Secret{ $bytes=New-Object byte[] 32;$random.GetBytes($bytes);([BitConverter]::ToString($bytes)).Replace('-','') }
$realm='native-limit-'+$id+'.invalid';$secret=Secret
$users=@(@{number='9001';auth='9002';password=(Secret)},@{number='9002';auth='fixture-9002';password=(Secret)})
$xml="<document type=`"freeswitch/xml`">`n<section name=`"configuration`">`n<X-PRE-PROCESS cmd=`"include`" data=`"autoload_configs/*.xml`"/>`n</section>`n<section name=`"directory`"><domain name=`"$realm`"><groups><group name=`"default`"><users>"
foreach($user in $users){$xml+='<user id="'+$user.auth+'"><params><param name="password" value="'+$user.password+'"/><param name="max-registrations-per-extension" value="1"/></params><variables><variable name="sip-force-user" value="'+$user.auth+'"/><variable name="user_context" value="private_limits"/></variables></user>'}
$xml+="`n"+'</users></group></groups></domain></section><section name="dialplan"/></document>'
WritePrivate "$root\conf\freeswitch.xml" $xml
WritePrivate "$root\conf\autoload_configs\modules.conf.xml" '<configuration name="modules.conf"><modules><load module="mod_console"/><load module="mod_logfile"/><load module="mod_commands"/><load module="mod_sofia"/><load module="mod_event_socket"/></modules></configuration>'
WritePrivate "$root\conf\autoload_configs\switch.conf.xml" '<configuration name="switch.conf"><settings><param name="rtp-start-port" value="39200"/><param name="rtp-end-port" value="39220"/><param name="max-sessions" value="5"/></settings></configuration>'
WritePrivate "$root\conf\autoload_configs\console.conf.xml" '<configuration name="console.conf"><mappings><map name="all" value="info"/></mappings></configuration>'
WritePrivate "$root\conf\autoload_configs\logfile.conf.xml" '<configuration name="logfile.conf"><profiles><profile name="default"><settings><param name="rollover" value="1048576"/></settings><mappings><map name="all" value="debug"/></mappings></profile></profiles></configuration>'
WritePrivate "$root\conf\autoload_configs\event_socket.conf.xml" ('<configuration name="event_socket.conf"><settings><param name="listen-ip" value="127.0.0.1"/><param name="listen-port" value="18224"/><param name="password" value="'+$secret+'"/></settings></configuration>')
WritePrivate "$root\conf\autoload_configs\sofia.conf.xml" '<configuration name="sofia.conf"><global_settings><param name="reg-deny-binding-fetch-and-no-lookup" value="false"/></global_settings><profiles><profile name="private_limits"><domains/><settings><param name="sip-ip" value="127.0.0.1"/><param name="rtp-ip" value="127.0.0.1"/><param name="ext-sip-ip" value="127.0.0.1"/><param name="ext-rtp-ip" value="127.0.0.1"/><param name="sip-port" value="19264"/><param name="context" value="private_limits"/><param name="dialplan" value="XML"/><param name="auth-calls" value="true"/><param name="auth-all-packets" value="false"/><param name="inbound-reg-force-matching-username" value="false"/><param name="challenge-realm" value="auto_to"/><param name="multiple-registrations" value="true"/><param name="log-auth-failures" value="true"/><param name="inbound-codec-prefs" value="PCMU"/><param name="outbound-codec-prefs" value="PCMU"/><param name="tls" value="false"/></settings></profile></profiles></configuration>'
WritePrivate "$root\input.json" (@{schema=1;qualification=$true;scope='fictional-loopback-registration-limits';realm=$realm;users=$users;esl_password=$secret;esl_port=18224;sip_port=19264}|ConvertTo-Json -Depth 8)
function StartPrivate([string]$Executable,[string[]]$Arguments,[string]$WorkingDirectory){$start=New-Object Diagnostics.ProcessStartInfo;$start.FileName=$Executable;$start.WorkingDirectory=$WorkingDirectory;$start.Arguments=($Arguments|ForEach-Object {'"'+$_+'"'}) -join ' ';$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.RedirectStandardInput=$true;[Diagnostics.Process]::Start($start)}
function Frame($Reader){$headers=@{};while($null -ne ($line=$Reader.ReadLine())){if($line -eq ''){break};$p=$line.IndexOf(':');if($p -gt 0){$headers[$line.Substring(0,$p).Trim()]=$line.Substring($p+1).Trim()}};$body='';if($headers.ContainsKey('Content-Length')){$size=[int]$headers['Content-Length'];if($size -lt 0 -or $size -gt 1048576){throw 'Owned reply exceeded its bound.'};$chars=New-Object char[] $size;$read=0;while($read -lt $size){$count=$Reader.Read($chars,$read,$size-$read);if($count -le 0){throw 'Owned reply ended early.'};$read+=$count};$body=-join $chars};@{headers=$headers;body=$body}}
$process=$null;$child=$null;$socket=$null;$reader=$null;$out=$null;$err=$null;$facts=[ordered]@{schema=1;scope='fictional loopback-only native contact limits';registrar_sha256=$ExpectedCandidateSha256;original_owner_services_touched=$false;postgresql_or_lua_loaded=$false;private_sqlite_only=$true;original_native_hashes_preserved=$false;profile_ready=$false;clean_shutdown=$false}
try{
 $process=StartPrivate "$root\FreeSwitchConsole.exe" @('-nonat','-nort','-base',$root,'-conf',"$root\conf",'-mod',"$root\mod",'-db',"$root\db",'-log',"$root\log",'-run',"$root\run") $root
 $out=$process.StandardOutput.ReadToEndAsync();$err=$process.StandardError.ReadToEndAsync()
 for($i=0;$i -lt 100 -and !$process.HasExited;$i++){$socket=[Net.Sockets.TcpClient]::new();try{$socket.Connect('127.0.0.1',18224);break}catch{$socket.Dispose();$socket=$null;Start-Sleep -Milliseconds 200}}
 if(!$socket){throw 'Owned event listener did not start.'};$socket.ReceiveTimeout=5000;$socket.SendTimeout=5000;$stream=$socket.GetStream();$reader=[IO.StreamReader]::new($stream,[Text.Encoding]::ASCII)
 if((Frame $reader).headers['Content-Type'] -ne 'auth/request'){throw 'Owned event greeting failed.'};$bytes=[Text.Encoding]::ASCII.GetBytes("auth $secret`n`n");$stream.Write($bytes,0,$bytes.Length);if((Frame $reader).headers['Reply-Text'] -ne '+OK accepted'){throw 'Owned event authentication failed.'}
 for($i=0;$i -lt 100;$i++){$bytes=[Text.Encoding]::ASCII.GetBytes("api sofia status profile private_limits`n`n");$stream.Write($bytes,0,$bytes.Length);$reply=Frame $reader;if($reply.body -match '(?m)^SIP-IP\s+127\.0\.0\.1\s*$'){$facts.profile_ready=$true;break};Start-Sleep -Milliseconds 200}
 if(!$facts.profile_ready){throw 'Owned loopback profile did not start.'}
 $child=StartPrivate $Python @('-I',"$root\windows-registrar-limits.py",'--input',"$root\input.json") $root;$childOut=$child.StandardOutput.ReadToEndAsync();$childErr=$child.StandardError.ReadToEndAsync()
 if(!$child.WaitForExit(180000)){$child.Kill();throw 'The bounded private registration probe exceeded its deadline.'}
 WritePrivate "$root\python.private.out" ($childOut.GetAwaiter().GetResult());WritePrivate "$root\python.private.err" ($childErr.GetAwaiter().GetResult());$facts.peer_exit=$child.ExitCode
 if(Test-Path "$root\registration-report.json"){$facts.registration=Get-Content "$root\registration-report.json" -Raw|ConvertFrom-Json}
 $bytes=[Text.Encoding]::ASCII.GetBytes("api shutdown`n`n");$stream.Write($bytes,0,$bytes.Length);$facts.clean_shutdown=$process.WaitForExit(10000) -and $process.ExitCode -eq 0
}catch{$facts.error_type=$_.Exception.GetType().Name;$facts.source_line=[int]$_.InvocationInfo.ScriptLineNumber}
finally{
 if($reader){$reader.Dispose()};if($socket){$socket.Dispose()};if($child){if(!$child.HasExited){$child.Kill();[void]$child.WaitForExit(10000)};$child.Dispose()}
 if($process){if(!$process.HasExited){$process.Kill();[void]$process.WaitForExit(10000)};$facts.final_exit=$process.ExitCode;if($out){WritePrivate "$root\private.out" ($out.GetAwaiter().GetResult())};if($err){WritePrivate "$root\private.err" ($err.GetAwaiter().GetResult())};$process.Dispose()}
 $random.Dispose();$preserved=$true;foreach($file in $pins.Keys){if((Hash (Join-Path $engine $file)) -ne $pins[$file]){$preserved=$false}};$facts.original_native_hashes_preserved=$preserved
 $facts.state=if($facts.clean_shutdown -and $facts.peer_exit -eq 0 -and $facts.registration.individual_tuples_authenticated -and $facts.registration.both_orders_accepted -and $facts.registration.same_account_second_contact_refused -and $facts.registration.contacts_after_cleanup -eq 0 -and $facts.original_native_hashes_preserved){'passed'}else{'failed'}
 WritePrivate "$root\report.json" ($facts|ConvertTo-Json -Depth 10)
 WritePrivate $Report ($facts|ConvertTo-Json -Depth 10)
}
if($facts.state -ne 'passed'){throw 'Actual native registration quotas did not pass.'}
Write-Host 'PASS actual native limit-one identity collision/both orders/second-contact refusal/refresh/unregister/wrong-password/clean-shutdown checks; no customer or physical result.'
