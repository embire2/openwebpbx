#Requires -Version 5.1
# QA only: two fixed owned endpoints, fictional OPTIONS, ordinary Windows TLS.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Hostname,[Parameter(Mandatory)][int]$Port,[Parameter(Mandatory)][string]$ReportPath,[switch]$DisposableHostedRunner)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
function Assert-MeetWssPathRunner([bool]$Disposable,[Collections.IDictionary]$Environment,[string]$Edition,[int]$Major,[int]$Build,[bool]$Is64Bit,$OperatingSystem){
 if(!$Disposable -or $Edition -cne 'Desktop' -or $Major -ne 5 -or !$Is64Bit -or $Build -lt 26100 -or $Environment.GITHUB_ACTIONS -cne 'true' -or $Environment.RUNNER_ENVIRONMENT -cne 'github-hosted' -or $Environment.RUNNER_OS -cne 'Windows' -or $Environment.GITHUB_REPOSITORY -cne 'embire2/openwebpbx' -or $Environment.GITHUB_EVENT_NAME -cne 'workflow_dispatch' -or $OperatingSystem.ProductType -notin 2,3 -or $OperatingSystem.Caption -notmatch '^Microsoft Windows Server 2025(?:\s|$)'){throw 'The owned disposable native Windows Server 2025 runner is required.'}
}
function Assert-MeetWssPathTarget([string]$Name,[int]$Number){
 if($Name -cne 'windowsqa.example.invalid' -or $Number -ne 8443){throw 'Only the fixed fictional installed meeting target is allowed.'}
}
function Assert-MeetWssPathReport([string]$Path,[string]$Root){
 $prefix=$Root.TrimEnd('\')+'\'
 if(!$Path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or $Path.Substring($prefix.Length) -cnotmatch '^[a-f0-9]{24}\\evidence\\meeting-wss-(before|after)\.safe\.json$'){throw 'Only the existing owned native qualification evidence report is allowed.'}
}
function Assert-MeetWssPathHosts([byte[]]$Bytes){
 $text=[Text.Encoding]::GetEncoding(28591).GetString($Bytes)
 if($text.IndexOf([char]0) -ge 0){throw 'The owned meeting hosts mappings are required.'}
 foreach($name in 'openweb-meet.internal','windowsqa.example.invalid'){
  $matches=@(foreach($line in ($text -split '\r?\n')){
   $parts=@(($line -split '#',2)[0].Trim() -split '\s+'|Where-Object {$_})
   if($parts.Count -gt 1 -and @($parts[1..($parts.Count-1)]|Where-Object {$_ -ieq $name}).Count){,$parts}
  })
  if($matches.Count -ne 1 -or $matches[0][0] -cne '127.0.0.1'){throw 'The two fixed meeting hosts must each resolve through one owned loopback mapping.'}
 }
}
function Assert-MeetWssPathProxy([xml]$Configuration,[bool]$Enabled,[bool]$PreserveHost,[int]$IgnoreFlags){
 $rules=@($Configuration.SelectNodes('/configuration/system.webServer/rewrite/rules/rule')|Where-Object {$_.GetAttribute('name') -ceq 'OpenWebPBX Meet'})
 if(!$Enabled -or $PreserveHost -or $IgnoreFlags -ne 0 -or $rules.Count -ne 1 -or $rules[0].match.url -cne '^meet-sip/$' -or $rules[0].action.url -cne 'https://openweb-meet.internal:7444/' -or $rules[0].action.appendQueryString -cne 'false'){throw 'The installed owned strict meeting proxy is required.'}
}
function Get-MeetWssPathFields($Record){
 $fields=@('observed','connected','sent','response_received','large_sent','large_response_received','status_code','large_status_code','phase','error_kind','closed_exact','elapsed_ms')
 $keys=if($Record -is [Collections.IDictionary]){@($Record.Keys)}elseif($Record -is [pscustomobject]){@($Record.PSObject.Properties|ForEach-Object Name)}else{return $null}
 if($keys.Count -ne 12 -or @($keys|Where-Object {$_ -cnotin $fields}).Count){return $null}
 $safe=@{}
 foreach($field in 'observed','connected','sent','response_received','large_sent','large_response_received','closed_exact'){if($Record.$field -isnot [bool]){return $null};$safe[$field]=$Record.$field}
 foreach($field in 'status_code','large_status_code','elapsed_ms'){
  $value=$Record.$field;$maximum=if($field -ceq 'elapsed_ms'){6000}else{699}
  if(($value -isnot [int] -and $value -isnot [long]) -or $value -lt 0 -or $value -gt $maximum){return $null};$safe[$field]=[int]$value
 }
 if($Record.phase -isnot [string] -or $Record.phase -cnotin 'connect','send','receive','complete','unavailable' -or $Record.error_kind -isnot [string] -or $Record.error_kind -cnotin 'none','timeout','tls','websocket','other','unavailable'){return $null}
 $safe.phase=$Record.phase;$safe.error_kind=$Record.error_kind;return $safe
}
function Get-MeetWssPathOrdinary([string]$Path,[bool]$Directory=$false){
 $full=[IO.Path]::GetFullPath($Path);$item=Get-Item -LiteralPath $full -Force
 if([bool]$item.PSIsContainer -ne $Directory){throw 'An existing ordinary owned observation path is required.'}
 for($current=$full;$current;$current=[IO.Path]::GetDirectoryName($current)){
  if((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'An observation path contains a redirect.'}
  if([IO.Path]::GetDirectoryName($current) -eq $current){break}
 }
 return $full
}
function Assert-MeetWssPathPrivate([string]$Directory){
 $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
 try{$allowed=@('S-1-5-18','S-1-5-32-544',$identity.User.Value)}finally{$identity.Dispose()}
 $acl=Get-Acl -LiteralPath $Directory
 foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){
  if($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and $rule.IdentityReference.Value -cnotin $allowed){throw 'Existing private caller-owned observation storage is required.'}
 }
}
try{
 Assert-MeetWssPathTarget $Hostname $Port
 $runner=@{};foreach($name in 'GITHUB_ACTIONS','RUNNER_ENVIRONMENT','RUNNER_OS','GITHUB_REPOSITORY','GITHUB_EVENT_NAME'){$runner[$name]=[Environment]::GetEnvironmentVariable($name)}
 # Reject the platform before querying a Windows provider.
 if(!$DisposableHostedRunner -or $PSVersionTable.PSEdition -cne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or [Environment]::OSVersion.Version.Build -lt 26100 -or $runner.GITHUB_ACTIONS -cne 'true' -or $runner.RUNNER_ENVIRONMENT -cne 'github-hosted' -or $runner.RUNNER_OS -cne 'Windows' -or $runner.GITHUB_REPOSITORY -cne 'embire2/openwebpbx' -or $runner.GITHUB_EVENT_NAME -cne 'workflow_dispatch'){throw 'Explicit native disposable Windows is required.'}
 $os=Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 2
 Assert-MeetWssPathRunner ([bool]$DisposableHostedRunner) $runner $PSVersionTable.PSEdition $PSVersionTable.PSVersion.Major ([Environment]::OSVersion.Version.Build) ([Environment]::Is64BitProcess) $os
 $report=[IO.Path]::GetFullPath($ReportPath);$parent=Get-MeetWssPathOrdinary ([IO.Path]::GetDirectoryName($report)) $true
 Assert-MeetWssPathReport $report ([IO.Path]::GetFullPath((Join-Path $env:ProgramData 'OpenWebPBX\native-qualification')))
 if(Test-Path -LiteralPath $report){throw 'A new report beneath existing private native evidence storage is required.'}
 Assert-MeetWssPathPrivate $parent
 $hosts=Get-MeetWssPathOrdinary (Join-Path $env:windir 'System32\drivers\etc\hosts')
 Assert-MeetWssPathHosts ([IO.File]::ReadAllBytes($hosts))
 $web=Get-MeetWssPathOrdinary 'C:\OpenWebPBX\web\web.config'
 Add-Type -Path "$env:windir\System32\inetsrv\Microsoft.Web.Administration.dll"
 $manager=[Microsoft.Web.Administration.ServerManager]::new()
 try{
  $site=$manager.Sites['OpenWebPBX']
  if(!$site -or [IO.Path]::GetFullPath($site.Applications['/'].VirtualDirectories['/'].PhysicalPath).TrimEnd('\') -cne 'C:\OpenWebPBX\web' -or @($site.Bindings|Where-Object {$_.Protocol -ceq 'https' -and $_.BindingInformation -ceq '*:8443:windowsqa.example.invalid'}).Count -ne 1){throw 'The fixed owned IIS site and binding are required.'}
  $proxy=$manager.GetApplicationHostConfiguration().GetSection('system.webServer/proxy')
  $flags=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\IIS Extensions\Application Request Routing\Parameters' -Name SecureConnectionIgnoreFlags
  Assert-MeetWssPathProxy ([xml][IO.File]::ReadAllText($web)) ([bool]$proxy['enabled']) ([bool]$proxy['preserveHostHeader']) ([int]$flags.SecureConnectionIgnoreFlags)
 }finally{$manager.Dispose()}
 $publicCertificate=Get-MeetWssPathOrdinary (Join-Path $env:ProgramData 'OpenWebPBX\meet-ca.pem')
 $pem=[IO.File]::ReadAllText($publicCertificate);$certificates=[regex]::Matches($pem,'-----BEGIN CERTIFICATE-----\s*([A-Za-z0-9+/=\s]+?)\s*-----END CERTIFICATE-----')
 if($certificates.Count -ne 1 -or $pem -match 'PRIVATE KEY'){throw 'The installed public backend certificate is required.'}
 $certificate=[Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String($certificates[0].Groups[1].Value))
 try{
  if($certificate.HasPrivateKey -or $certificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName,$false) -cne 'openweb-meet.internal' -or !(Test-Path -LiteralPath ('Cert:\LocalMachine\Root\'+$certificate.Thumbprint))){throw 'Existing exact backend trust is required.'}
  $trusted=Get-Item -LiteralPath ('Cert:\LocalMachine\Root\'+$certificate.Thumbprint)
  try{if([Convert]::ToBase64String($trusted.RawData) -cne [Convert]::ToBase64String($certificate.RawData)){throw 'The installed backend certificate differs from its existing trust.'}}finally{$trusted.Dispose()}
 }finally{$certificate.Dispose()}
 Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.WebSockets;
using System.Security.Authentication;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
public static class OpenWebMeetWssPathProbe {
 public static Dictionary<string,object> Probe(bool frontend) {
  return ProbeUri(new Uri(frontend ? "wss://windowsqa.example.invalid:8443/meet-sip/" : "wss://openweb-meet.internal:7444/"));
 }
 static void Await(Task task, Stopwatch clock, CancellationTokenSource cancel) {
  int remaining=4500-(int)clock.ElapsedMilliseconds;
  if(remaining<=0 || !task.Wait(remaining)){cancel.Cancel();throw new TimeoutException();}
  task.GetAwaiter().GetResult();
 }
 static string ErrorKind(Exception error, bool canceled) {
  if(canceled)return "timeout";
  bool websocket=false;
  for(int depth=0;error!=null && depth<12;depth++,error=error.InnerException){
   if(error is TimeoutException || error is OperationCanceledException)return "timeout";
   if(error is AuthenticationException)return "tls";
   var web=error as WebException;
   if(web!=null && (web.Status==WebExceptionStatus.TrustFailure || web.Status==WebExceptionStatus.SecureChannelFailure))return "tls";
   if(error is WebSocketException || error is WebException)websocket=true;
  }
  return websocket ? "websocket" : "other";
 }
 static string Request(string callId, bool large) {
  string head="OPTIONS sip:openweb-meet.internal SIP/2.0\r\nVia: SIP/2.0/WSS invalid.invalid;branch=z9hG4bK"+Guid.NewGuid().ToString("N")+"\r\nFrom: <sip:wss-path@invalid.invalid>;tag="+Guid.NewGuid().ToString("N")+"\r\nTo: <sip:wss-path@invalid.invalid>\r\nCall-ID: "+callId+"\r\nCSeq: 1 OPTIONS\r\nMax-Forwards: 0\r\n";
  string tail="Content-Length: 0\r\n\r\n";
  string padding=large ? "X-OpenWeb-Test: "+new string('x',8192-Encoding.ASCII.GetByteCount(head+tail+"X-OpenWeb-Test: \r\n"))+"\r\n" : "";
  return head+padding+tail;
 }
 static int Status(string message,string callId) {
  int end=message.IndexOf("\r\n\r\n",StringComparison.Ordinal);if(end<0)return 0;
  string[] lines=message.Substring(0,end).Split(new string[]{"\r\n"},StringSplitOptions.None);
  if(lines.Length>64)return 0;
  var status=Regex.Match(lines[0],@"^SIP/2\.0 ([1-6][0-9]{2})(?: [\x20-\x7e]*)?$",RegexOptions.CultureInvariant);
  if(!status.Success)return 0;
  int ids=0,sequences=0;
  for(int index=1;index<lines.Length;index++){
   int colon=lines[index].IndexOf(':');if(colon<=0)continue;
   string name=lines[index].Substring(0,colon),value=lines[index].Substring(colon+1).Trim(' ','\t');
   if(name.Equals("Call-ID",StringComparison.OrdinalIgnoreCase)||name.Equals("i",StringComparison.OrdinalIgnoreCase)){if(value!=callId)return 0;ids++;}
   if(name.Equals("CSeq",StringComparison.OrdinalIgnoreCase)){if(!Regex.IsMatch(value,@"^1[ \t]+OPTIONS$",RegexOptions.CultureInvariant))return 0;sequences++;}
  }
  return ids==1 && sequences==1 ? Int32.Parse(status.Groups[1].Value,System.Globalization.CultureInfo.InvariantCulture) : 0;
 }
 static int Receive(ClientWebSocket socket,string callId,Stopwatch clock,CancellationTokenSource cancel,ref Task pending) {
  byte[] buffer=new byte[8192];
  for(int messages=0;messages<4;messages++){
   using(var body=new MemoryStream()){
    WebSocketReceiveResult result;
    do{
     var receive=socket.ReceiveAsync(new ArraySegment<byte>(buffer),cancel.Token);pending=receive;Await(receive,clock,cancel);result=receive.GetAwaiter().GetResult();
     if(result.MessageType!=WebSocketMessageType.Text || body.Length+result.Count>16384)throw new WebSocketException();
     body.Write(buffer,0,result.Count);
    }while(!result.EndOfMessage);
    int status=Status(new UTF8Encoding(false,true).GetString(body.ToArray()),callId);if(status!=0)return status;
   }
  }
  throw new WebSocketException();
 }
 // Private core is reachable by local-fixture reflection tests, never a script URI parameter.
 static Dictionary<string,object> ProbeUri(Uri target) {
  var report=new Dictionary<string,object>{{"observed",true},{"connected",false},{"sent",false},{"response_received",false},{"large_sent",false},{"large_response_received",false},{"status_code",0},{"large_status_code",0},{"phase","connect"},{"error_kind","none"},{"closed_exact",false},{"elapsed_ms",0}};
  var clock=Stopwatch.StartNew();ClientWebSocket socket=null;CancellationTokenSource cancel=null;Task pending=null;bool cleanup=true;
  try{
   cancel=new CancellationTokenSource();cancel.CancelAfter(4500);socket=new ClientWebSocket();
   socket.Options.AddSubProtocol("sip");socket.Options.UseDefaultCredentials=false;socket.Options.Credentials=null;socket.Options.Proxy=null;socket.Options.KeepAliveInterval=TimeSpan.Zero;socket.Options.SetBuffer(8192,8192);
   pending=socket.ConnectAsync(target,cancel.Token);Await(pending,clock,cancel);
   if(socket.State!=WebSocketState.Open || socket.SubProtocol!="sip")throw new WebSocketException();report["connected"]=true;
   for(int exchange=0;exchange<2;exchange++){
    bool large=exchange==1;string callId=Guid.NewGuid().ToString("N")+"@invalid.invalid";byte[] request=Encoding.ASCII.GetBytes(Request(callId,large));
    report["phase"]="send";pending=socket.SendAsync(new ArraySegment<byte>(request),WebSocketMessageType.Text,true,cancel.Token);Await(pending,clock,cancel);report[large?"large_sent":"sent"]=true;
    report["phase"]="receive";int status=Receive(socket,callId,clock,cancel,ref pending);report[large?"large_status_code":"status_code"]=status;report[large?"large_response_received":"response_received"]=true;
   }
   report["phase"]="complete";
  }catch(Exception error){report["error_kind"]=ErrorKind(error,cancel!=null && cancel.IsCancellationRequested);}
  finally{
   if(cancel!=null){try{cancel.Cancel();}catch{cleanup=false;}}
   if(socket!=null){try{socket.Abort();}catch{cleanup=false;}try{socket.Dispose();}catch{cleanup=false;}}
   if(pending!=null && !pending.IsCompleted){try{pending.Wait(Math.Max(0,5000-(int)clock.ElapsedMilliseconds));}catch{}}
   if(pending!=null && !pending.IsCompleted)cleanup=false;
   if(cancel!=null){try{cancel.Dispose();}catch{cleanup=false;}}
   report["closed_exact"]=cleanup;report["elapsed_ms"]=Math.Min(6000,(int)clock.ElapsedMilliseconds);
  }
  return report;
 }
}
'@
 $backend=Get-MeetWssPathFields ([OpenWebMeetWssPathProbe]::Probe($false));$frontend=Get-MeetWssPathFields ([OpenWebMeetWssPathProbe]::Probe($true))
 if(!$backend -or !$frontend){throw 'The WSS observer did not produce its closed schema.'}
 $facts=[ordered]@{schema=1;state='observed';backend=$backend;frontend=$frontend}
 $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($facts|ConvertTo-Json -Depth 4 -Compress))
 $stream=[IO.File]::Open($report,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
 try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
 if(!$backend.closed_exact -or !$frontend.closed_exact){throw 'Owned WSS observation cleanup did not complete.'}
 Write-Output 'OBSERVED fixed owned backend and frontend WSS paths; this is diagnostic evidence only'
}catch{throw 'The owned WSS path observation could not run completely; inspect its closed report if present.'}
