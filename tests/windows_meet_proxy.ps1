# Native controls for the actual IIS proxy and the private encrypted endpoint.
# The installed mode reads the existing fictional qualification instance only.
[CmdletBinding()]
param([switch]$Installed,[string]$Hostname='windowsqa.example.invalid',[int]$Port=8443)
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'packaging\windows\Meet-Proxy.ps1')
$checks=[Collections.Generic.List[string]]::new()
function Check([bool]$Value,[string]$Name){if(!$Value){throw "Meeting transport control failed: $Name"};$checks.Add($Name)}
function Refuses([scriptblock]$Action,[string]$Name){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Check $failed $Name}
$temporary=Join-Path $env:TEMP ('openweb-meet-controls-'+[Guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $temporary|Out-Null
try{
 $before=[Text.Encoding]::GetEncoding(28591).GetBytes("# foreign comment $([char]0xe9)`r`n127.0.0.1 localhost`r`n")
 $plan=Get-OpenWebMeetHostsPlan $before
 Check $plan.Changed 'absent private hostname is appended'
 Check ([Convert]::ToBase64String($plan.Bytes[0..($before.Length-1)]) -ceq [Convert]::ToBase64String($before)) 'foreign hosts bytes are preserved'
 Check (!(Get-OpenWebMeetHostsPlan $plan.Bytes).Changed) 'repeated hosts plan is idempotent'
 Refuses {Get-OpenWebMeetHostsPlan ([Text.Encoding]::ASCII.GetBytes("198.51.100.2 openweb-meet.internal`r`n"))} 'foreign hosts address refuses'
 Refuses {Get-OpenWebMeetHostsPlan ([Text.Encoding]::ASCII.GetBytes("127.0.0.1 openweb-meet.internal`r`n127.0.0.1 openweb-meet.internal`r`n"))} 'duplicate hosts alias refuses'
 Refuses {Get-OpenWebMeetHostsPlan ([Text.Encoding]::Unicode.GetBytes("127.0.0.1 localhost`r`n"))} 'ambiguous hosts encoding refuses'
 $config=Join-Path $temporary 'web.config'
 $text='<configuration><system.webServer><handlers><add name="ForeignHandler" path="*.fixture" verb="GET" modules="StaticFileModule"/></handlers><rewrite><rules><rule name="ForeignRule"><match url="^fixture$"/><action type="None"/></rule></rules></rewrite></system.webServer></configuration>'
 [IO.File]::WriteAllText($config,$text);Set-OpenWebMeetWebConfig $config
 $xml=[xml](Get-Content -LiteralPath $config -Raw);$rules=@($xml.configuration.'system.webServer'.rewrite.rules.rule)
 Check ($rules.Count -eq 2 -and $rules[0].name -eq 'OpenWebPBX Meet' -and $rules[1].name -eq 'ForeignRule') 'owned exact route precedes unchanged foreign rule'
 Check ($rules[0].match.url -ceq '^meet-sip/$' -and $rules[0].action.url -ceq 'https://openweb-meet.internal:7444/' -and $rules[0].action.appendQueryString -ceq 'false') 'route has fixed private TLS target and no query'
 Check (@($rules[0].conditions.add).Count -eq 4) 'HTTPS GET WebSocket and empty-query guards are present'
 Check ($xml.configuration.'system.webServer'.handlers.add.name -ceq 'ForeignHandler') 'foreign IIS handlers are unchanged'
 $sealed=[IO.File]::ReadAllBytes($config)
 Refuses {Set-OpenWebMeetWebConfig $config} 'existing meeting rule refuses ambiguous replacement'
 Check ([Convert]::ToBase64String([IO.File]::ReadAllBytes($config)) -ceq [Convert]::ToBase64String($sealed)) 'refused IIS configuration remains exact'
 if($Installed){
  if($Hostname -cnotmatch '^[a-z0-9.-]+$' -or $Port -lt 1 -or $Port -gt 65535){throw 'Use a controlled qualification hostname and port.'}
  $state=Join-Path $env:ProgramData 'OpenWebPBX';$ledger=Get-Content (Join-Path $state 'meet-proxy.json') -Raw|ConvertFrom-Json
  $certificate=Get-OpenWebMeetCertificate (Join-Path $state 'meet-ca.pem')
  Check ($ledger.Schema -eq 1 -and $ledger.Complete -and $ledger.Thumbprint -ceq $certificate.Thumbprint) 'installed ownership ledger matches current certificate'
  $proxy=Get-OpenWebMeetProxyState;$reg=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\IIS Extensions\Application Request Routing\Parameters' -Name SecureConnectionIgnoreFlags
  Check ($proxy.Enabled -and !$proxy.PreserveHostHeader -and $reg.SecureConnectionIgnoreFlags -eq 0) 'ARR uses strict backend identity validation'
  $runtime=& 'C:\OpenWebPBX\php\php.exe' (Join-Path $PSScriptRoot 'windows_meet_runtime.php')
  if($LASTEXITCODE){throw 'The installed native meeting runtime is unavailable.'}
  $runtime=$runtime|ConvertFrom-Json
  Check ($runtime.conference_module -eq $true) 'actual native conference mixer module is loaded'
  Check ($runtime.vp8_video_codec -eq $true) 'actual native VP8 video codec is available'
  function BackendTls([string]$Name){
   $tcp=[Net.Sockets.TcpClient]::new();$ssl=$null
   try{$tcp.Connect('127.0.0.1',7444);$ssl=[Net.Security.SslStream]::new($tcp.GetStream(),$false);$ssl.AuthenticateAsClient($Name);if(!$ssl.IsAuthenticated -or !$ssl.IsEncrypted){throw 'TLS did not authenticate.'}}
   finally{if($ssl){$ssl.Dispose()};$tcp.Dispose()}
  }
  BackendTls 'openweb-meet.internal';Check $true 'private backend TLS validates through Windows trust'
  Refuses {BackendTls 'different-meeting.example.invalid'} 'wrong private backend hostname is rejected'
  $socket=[Net.WebSockets.ClientWebSocket]::new();$socket.Options.AddSubProtocol('sip');$cancel=[Threading.CancellationTokenSource]::new(15000)
  try{
   $socket.ConnectAsync([Uri]("wss://${Hostname}:$Port/meet-sip/"),$cancel.Token).GetAwaiter().GetResult()
   Check ($socket.State -eq 'Open' -and $socket.SubProtocol -ceq 'sip') 'actual IIS encrypted SIP WebSocket upgrade succeeds'
  }finally{$socket.Abort();$socket.Dispose();$cancel.Dispose()}
  $socket=[Net.WebSockets.ClientWebSocket]::new();$socket.Options.AddSubProtocol('sip');$cancel=[Threading.CancellationTokenSource]::new(10000)
  try{Refuses {$socket.ConnectAsync([Uri]("wss://${Hostname}:$Port/meet-sip/?foreign=1"),$cancel.Token).GetAwaiter().GetResult()} 'query-altered meeting WebSocket refuses'}finally{$socket.Abort();$socket.Dispose();$cancel.Dispose()}
 }
 [ordered]@{schema=1;checks=$checks.Count;passed=@($checks);installed=[bool]$Installed}|ConvertTo-Json -Depth 4
}finally{Remove-Item -LiteralPath $temporary -Recurse -Force}
