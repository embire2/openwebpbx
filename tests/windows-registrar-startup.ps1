#Requires -RunAsAdministrator
#Requires -Version 7.4
[CmdletBinding()]
param(
 [Parameter(Mandatory)][string]$EngineRoot,
 [Parameter(Mandatory)][string]$Registrar,
 [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$RegistrarSha256,
 [Parameter(Mandatory)][string]$Report,
 [switch]$DisposableHostedRunner
)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if(!$DisposableHostedRunner -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:RUNNER_OS -ne 'Windows' -or $env:GITHUB_REPOSITORY -ne 'embire2/openwebpbx'){
 throw 'Use only this repository disposable Windows hosted runner.'
}
$prefix=[IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')+'\'
foreach($path in $EngineRoot,$Registrar,$Report){
 if(![IO.Path]::GetFullPath($path).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Private native probe inputs must belong to this runner.'}
}
function Hash([string]$Path){(Get-FileHash -LiteralPath $Path).Hash.ToLowerInvariant()}
if((Hash "$EngineRoot\FreeSwitch.dll") -ne '8553d88348093d5067d93369aa9793b38fe9e3c9c9ca0c38216791700bd7f726' -or
 (Hash "$EngineRoot\pthread.dll") -ne '2d9d70378f13dcc06eed72005e74a12c6f7ba085e5fd31f97be49b7ef87cfdad' -or
 (Hash "$EngineRoot\mod\mod_sofia.dll") -ne 'ccf98b4c8ff99f2d670e88ec605f837795e4b878a2984c1df2ea36d9319aeff5' -or
 (Hash $Registrar) -ne $RegistrarSha256){throw 'The independently pinned native probe inputs changed.'}
foreach($port in 18023,19060){
 $tcp=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$port)
 try{$tcp.Start()}finally{$tcp.Stop()}
}
$udp=[Net.Sockets.UdpClient]::new();try{$udp.Client.Bind([Net.IPEndPoint]::new([Net.IPAddress]::Loopback,19060))}finally{$udp.Dispose()}
$scope=Join-Path $env:RUNNER_TEMP ('openwebpbx-registrar-startup-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scope|Out-Null
& icacls.exe $scope /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F'|Out-Null
if($LASTEXITCODE){throw 'The native probe private directory could not be secured.'}
function WritePrivate([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))}
function ReadFrame($Reader){
 $headers=@{}
 while($null -ne ($line=$Reader.ReadLine())){
  if($line -eq ''){break};$separator=$line.IndexOf(':')
  if($separator -gt 0){$headers[$line.Substring(0,$separator).Trim().ToLowerInvariant()]=$line.Substring($separator+1).Trim()}
 }
 $body=''
 if($headers.ContainsKey('content-length')){
  $length=[int]$headers['content-length'];if($length -lt 0 -or $length -gt 1048576){throw 'The private native reply exceeded its bound.'}
  $chars=New-Object char[] $length;$read=0
  while($read -lt $length){$count=$Reader.Read($chars,$read,$length-$read);if($count -le 0){throw 'The private native reply ended early.'};$read+=$count};$body=-join $chars
 }
 @{headers=$headers;body=$body}
}
function Case([string]$Name,[string]$Module){
 $root=Join-Path $scope $Name
 foreach($part in 'conf','conf\autoload_configs','mod','db','log','run','scripts','sounds','recordings'){New-Item -ItemType Directory -Path (Join-Path $root $part)|Out-Null}
 foreach($file in Get-ChildItem -LiteralPath $EngineRoot -File|Where-Object {$_.Extension -in '.dll','.exe'}){Copy-Item -LiteralPath $file.FullName -Destination $root}
 foreach($supportModule in 'mod_commands.dll','mod_event_socket.dll','mod_console.dll','mod_logfile.dll'){Copy-Item -LiteralPath "$EngineRoot\mod\$supportModule" -Destination "$root\mod"}
 Copy-Item -LiteralPath $Module -Destination "$root\mod\mod_sofia.dll"
 $secret=[Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
 WritePrivate "$root\conf\freeswitch.xml" @'
<?xml version="1.0" encoding="utf-8"?>
<document type="freeswitch/xml">
 <section name="configuration">
  <X-PRE-PROCESS cmd="include" data="autoload_configs/*.xml"/>
 </section>
 <section name="directory"/>
 <section name="dialplan"/>
</document>
'@
 WritePrivate "$root\conf\autoload_configs\modules.conf.xml" '<configuration name="modules.conf"><modules><load module="mod_console"/><load module="mod_logfile"/><load module="mod_commands"/><load module="mod_sofia"/><load module="mod_event_socket"/></modules></configuration>'
 WritePrivate "$root\conf\autoload_configs\switch.conf.xml" '<configuration name="switch.conf"><settings><param name="rtp-start-port" value="39000"/><param name="rtp-end-port" value="39100"/><param name="max-sessions" value="10"/></settings></configuration>'
 WritePrivate "$root\conf\autoload_configs\console.conf.xml" '<configuration name="console.conf"><mappings><map name="all" value="info"/></mappings></configuration>'
 WritePrivate "$root\conf\autoload_configs\logfile.conf.xml" '<configuration name="logfile.conf"><profiles><profile name="default"><settings><param name="rollover" value="1048576"/></settings><mappings><map name="all" value="debug"/></mappings></profile></profiles></configuration>'
 WritePrivate "$root\conf\autoload_configs\event_socket.conf.xml" ('<configuration name="event_socket.conf"><settings><param name="listen-ip" value="127.0.0.1"/><param name="listen-port" value="18023"/><param name="password" value="'+$secret+'"/></settings></configuration>')
 WritePrivate "$root\conf\autoload_configs\sofia.conf.xml" '<configuration name="sofia.conf"><global_settings/><profiles><profile name="private_probe"><domains/><settings><param name="sip-ip" value="127.0.0.1"/><param name="rtp-ip" value="127.0.0.1"/><param name="ext-sip-ip" value="127.0.0.1"/><param name="ext-rtp-ip" value="127.0.0.1"/><param name="sip-port" value="19060"/><param name="context" value="private_probe"/><param name="dialplan" value="XML"/><param name="auth-calls" value="true"/><param name="inbound-codec-prefs" value="PCMU"/><param name="outbound-codec-prefs" value="PCMU"/><param name="tls" value="false"/></settings></profile></profiles></configuration>'
 $facts=[ordered]@{name=$Name;registrar_sha256=(Hash $Module);private_loopback_only=$true;authenticated=$false;registrar_loaded=$false;profile_ready=$false;clean_shutdown=$false;process_exit=$null}
 $process=$null;$socket=$null;$stream=$null;$reader=$null;$stdout=$null;$stderr=$null
 try{
  $start=[Diagnostics.ProcessStartInfo]::new("$root\FreeSwitchConsole.exe");$start.WorkingDirectory=$root
  $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.RedirectStandardInput=$true
  foreach($argument in @('-nonat','-nort','-base',$root,'-conf',"$root\conf",'-mod',"$root\mod",'-db',"$root\db",'-log',"$root\log",'-run',"$root\run")){[void]$start.ArgumentList.Add($argument)}
  $process=[Diagnostics.Process]::Start($start);$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
  $clock=[Diagnostics.Stopwatch]::StartNew()
  while(!$process.HasExited -and $clock.Elapsed.TotalSeconds -lt 20){
   $socket=[Net.Sockets.TcpClient]::new()
   try{$socket.Connect('127.0.0.1',18023);break}catch{$socket.Dispose();$socket=$null;Start-Sleep -Milliseconds 200}
  }
  if(!$socket){throw 'The private event listener did not start.'}
  $socket.ReceiveTimeout=3000;$socket.SendTimeout=3000;$stream=$socket.GetStream();$stream.ReadTimeout=3000;$stream.WriteTimeout=3000
  $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::ASCII,$false,4096,$true)
  $hello=ReadFrame $reader;if($hello.headers['content-type'] -ne 'auth/request'){throw 'The private event greeting is invalid.'}
  $bytes=[Text.Encoding]::ASCII.GetBytes("auth $secret`n`n");$stream.Write($bytes,0,$bytes.Length);$auth=ReadFrame $reader
  if($auth.headers['reply-text'] -ne '+OK accepted'){throw 'The private event authentication failed.'};$facts.authenticated=$true
  $bytes=[Text.Encoding]::ASCII.GetBytes("api module_exists mod_sofia`n`n");$stream.Write($bytes,0,$bytes.Length);$reply=ReadFrame $reader
  $facts.registrar_loaded=$reply.body.Trim() -eq 'true'
  $clock.Restart()
  while(!$process.HasExited -and $clock.Elapsed.TotalSeconds -lt 20){
   $bytes=[Text.Encoding]::ASCII.GetBytes("api sofia status profile private_probe`n`n");$stream.Write($bytes,0,$bytes.Length);$reply=ReadFrame $reader
   if($reply.body -match '(?m)^SIP-IP\s+127\.0\.0\.1\s*$'){$facts.profile_ready=$true;break};Start-Sleep -Milliseconds 200
  }
  $facts.profile_wait_seconds=[Math]::Round($clock.Elapsed.TotalSeconds,3)
  $bytes=[Text.Encoding]::ASCII.GetBytes("api shutdown`n`n");$stream.Write($bytes,0,$bytes.Length)
  $facts.clean_shutdown=$process.WaitForExit(10000) -and $process.ExitCode -eq 0
 }catch{
  $facts.error_type=$_.Exception.GetType().Name;$facts.source_line=[int]$_.InvocationInfo.ScriptLineNumber
 }finally{
  if($reader){$reader.Dispose()};if($stream){$stream.Dispose()};if($socket){$socket.Dispose()}
  if($process){
   if(!$process.HasExited){$process.Kill($true);[void]$process.WaitForExit(10000)}
   $facts.process_exit=$process.ExitCode
   if($stdout){WritePrivate "$root\private.out" ($stdout.GetAwaiter().GetResult())};if($stderr){WritePrivate "$root\private.err" ($stderr.GetAwaiter().GetResult())}
   $process.Dispose()
  }
 }
 $facts
}
$cases=@(Case 'stock' "$EngineRoot\mod\mod_sofia.dll";Case 'candidate' $Registrar)
$passed=@($cases|Where-Object {!$_.authenticated -or !$_.registrar_loaded -or !$_.profile_ready -or !$_.clean_shutdown -or $_.process_exit -ne 0}).Count -eq 0
WritePrivate $Report (@{schema=1;scope='disposable loopback-only registrar startup';passed=$passed;cases=$cases}|ConvertTo-Json -Depth 6)
if(!$passed){throw 'The actual stock/candidate listener and clean shutdown gate failed. Native calling remains unqualified.'}
Write-Host 'Both independently pinned registrars started their private phone listener and shut down cleanly. SIP/media qualification remains separate.'
