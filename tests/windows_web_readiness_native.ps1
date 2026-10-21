#Requires -RunAsAdministrator
#Requires -Version 5.1
# QA only. Invoke on the explicitly disposable, freshly installed hosted server.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PackageRoot,[Parameter(Mandatory)][string]$ReportPath,[switch]$DisposableHostedRunner)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if(!$DisposableHostedRunner -or $PSVersionTable.PSEdition -eq 'Core' -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:RUNNER_OS -ne 'Windows' -or $env:GITHUB_REPOSITORY -ne 'embire2/openwebpbx' -or [Environment]::OSVersion.Version.Build -lt 26100){throw 'Explicit native Windows Server 2025 disposable runner required.'}
$facts=[ordered]@{schema=1;state='failed';case='native_windows_readiness_tls_boolean';checks=0;cleanup_exact=$false;phase='preflight';error_type='none';source_line=0;manifest_helper_hash=$false;scalar_boolean=$false;trusted_tls=$false;actual_iis=$false}
$reportAllowed=$false;$phase='preflight';$fixtures=[Collections.Generic.List[object]]::new();$failure=$null;$snapshot=$null;$certificate=$null
function Check([bool]$Value){if(!$Value){$exception=[InvalidOperationException]::new('Native readiness assertion failed.');$exception.Data['ReadinessSourceLine']=[int](Get-PSCallStack)[1].ScriptLineNumber;throw $exception};$script:facts.checks++}
function Ordinary([string]$Path,[bool]$Directory=$false){
 $full=[IO.Path]::GetFullPath($Path);$item=Get-Item -LiteralPath $full -Force
 if([bool]$item.PSIsContainer -ne $Directory){throw 'An ordinary owned readiness path is required.'}
 for($current=$full;$current;$current=[IO.Path]::GetDirectoryName($current)){if((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'A readiness path contains a redirect.'};if([IO.Path]::GetDirectoryName($current) -eq $current){break}}
 return $full
}
function StateSnapshot {
 $applicationHost=Ordinary "$env:windir\System32\inetsrv\config\applicationHost.config"
 $hosts=Ordinary "$env:windir\System32\drivers\etc\hosts"
 return [ordered]@{application_host=(Get-FileHash -LiteralPath $applicationHost -Algorithm SHA256).Hash;hosts=(Get-FileHash -LiteralPath $hosts -Algorithm SHA256).Hash;root=@(Get-ChildItem Cert:\LocalMachine\Root|ForEach-Object Thumbprint|Sort-Object);my=@(Get-ChildItem Cert:\LocalMachine\My|ForEach-Object Thumbprint|Sort-Object)}|ConvertTo-Json -Compress
}
try{
 $report= [IO.Path]::GetFullPath($ReportPath);$parent=Ordinary ([IO.Path]::GetDirectoryName($report)) $true
 Check ([IO.Path]::GetFileName($report) -ceq 'web-readiness-native.json' -and [IO.Path]::GetFileName($parent) -cmatch '^openwebpbx-suite-[a-f0-9]{32}$' -and [IO.Path]::GetDirectoryName($parent).Equals([IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase))
 Check (!(Test-Path -LiteralPath $report));$reportAllowed=$true
 $manifestPath=Ordinary (Join-Path $PackageRoot 'release-manifest.json');Check ((Get-Item -LiteralPath $manifestPath).Length -lt 8MB)
 $manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
 $phase='helper';$helper=Ordinary (Join-Path $PackageRoot 'Web-Readiness.ps1')
 Check ($manifest.files.'Web-Readiness.ps1' -is [string] -and $manifest.files.'Web-Readiness.ps1' -cmatch '^[a-f0-9]{64}$' -and (Get-FileHash -LiteralPath $helper -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $manifest.files.'Web-Readiness.ps1')
 . $helper
 Check ($null -ne (Get-Command Test-OpenWebTrustedLogin -CommandType Function -ErrorAction Stop));$facts.manifest_helper_hash=$true
 $phase='certificate';$snapshot=StateSnapshot
 Add-Type -Path "$env:windir\System32\inetsrv\Microsoft.Web.Administration.dll"
 $manager=[Microsoft.Web.Administration.ServerManager]::new()
 try{
  $site=$manager.Sites['OpenWebPBX'];Check ($null -ne $site -and [IO.Path]::GetFullPath($site.Applications['/'].VirtualDirectories['/'].PhysicalPath).TrimEnd('\') -ieq 'C:\OpenWebPBX\web')
  $bindings=@($site.Bindings|Where-Object {$_.Protocol -ceq 'https' -and $_.BindingInformation -ceq '*:8443:windowsqa.example.invalid'})
  Check ($bindings.Count -eq 1 -and $bindings[0].CertificateStoreName -ieq 'My')
  $thumbprint=[BitConverter]::ToString($bindings[0].CertificateHash).Replace('-','')
 }finally{$manager.Dispose()}
 $certificate=Get-Item -LiteralPath ('Cert:\LocalMachine\My\'+$thumbprint)
 Check ($certificate.HasPrivateKey -and $certificate.NotBefore.ToUniversalTime() -lt [DateTime]::UtcNow -and $certificate.NotAfter.ToUniversalTime() -gt [DateTime]::UtcNow)
 # The server side uses the existing key read-only. The real client retains
 # ordinary operating-system CA/SAN checks; no callback or trust bypass exists.
 Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using System.Threading;
public sealed class OpenWebReadinessTlsFixture : IDisposable {
 readonly TcpListener listener;
 readonly Thread thread;
 readonly X509Certificate2 certificate;
 readonly byte[] response;
 public int Port { get; private set; }
 public bool Accepted { get; private set; }
 public bool Handshake { get; private set; }
 public bool Request { get; private set; }
 public bool Finished { get; private set; }
 public bool Alive { get { return thread.IsAlive; } }
 public OpenWebReadinessTlsFixture(X509Certificate2 cert, byte[] bytes) {
  certificate=cert;response=bytes;listener=new TcpListener(IPAddress.Loopback,0);listener.Start(1);
  Port=((IPEndPoint)listener.LocalEndpoint).Port;thread=new Thread(new ThreadStart(Run));thread.IsBackground=true;thread.Start();
 }
 void Run() {
  TcpClient client=null;SslStream tls=null;
  try {
   var accept=listener.AcceptTcpClientAsync();if(!accept.Wait(5000))return;
   client=accept.GetAwaiter().GetResult();Accepted=true;client.ReceiveTimeout=3000;client.SendTimeout=3000;
   tls=new SslStream(client.GetStream(),false);tls.ReadTimeout=3000;tls.WriteTimeout=3000;
   var auth=tls.AuthenticateAsServerAsync(certificate,false,SslProtocols.Tls12,false);if(!auth.Wait(5000))return;
   auth.GetAwaiter().GetResult();Handshake=true;
   int count=0,ending=0;var wanted=new byte[]{13,10,13,10};
   while(count++<16384) {int value=tls.ReadByte();if(value<0)return;ending=value==wanted[ending]?ending+1:(value==13?1:0);if(ending==4){Request=true;break;}}
   if(!Request)return;tls.Write(response,0,response.Length);tls.Flush();
  } catch { /* The negative SAN fixture legitimately rejects the handshake. */ }
  finally {if(tls!=null)tls.Dispose();if(client!=null)client.Close();listener.Stop();Finished=true;}
 }
 public void Dispose() {listener.Stop();if(!thread.Join(15000))throw new TimeoutException("The owned fixture thread did not finish.");}
}
'@
 $phase='fixture';$html='<html><form><input name="username"><input name="password"></form></html>'
 $body=[Text.Encoding]::UTF8.GetBytes($html)
 $valid="HTTP/1.1 200 OK`r`nContent-Type: text/html; charset=utf-8`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n$html"
 $cases=@(
  @{Name='valid';Wire=$valid;HostName='windowsqa.example.invalid';Expected=$true},
  @{Name='server_error';Wire=$valid.Replace('200 OK','500 Internal Server Error');HostName='windowsqa.example.invalid';Expected=$false},
  @{Name='invalid_status';Wire=$valid.Replace('200 OK','2000 Invalid');HostName='windowsqa.example.invalid';Expected=$false},
  @{Name='truncated_length';Wire=$valid.Replace("Content-Length: $($body.Length)","Content-Length: $($body.Length+1)");HostName='windowsqa.example.invalid';Expected=$false},
  @{Name='duplicate_length';Wire=$valid.Replace("Content-Length: $($body.Length)","Content-Length: $($body.Length)`r`nContent-Length: $($body.Length)");HostName='windowsqa.example.invalid';Expected=$false},
  @{Name='ambiguous_framing';Wire=$valid.Replace("Content-Length: $($body.Length)","Content-Length: $($body.Length)`r`nTransfer-Encoding: chunked");HostName='windowsqa.example.invalid';Expected=$false},
  @{Name='wrong_san';Wire=$valid;HostName='wrong.windowsqa.example.invalid';Expected=$false}
 )
 foreach($case in $cases){
  $fixture=[OpenWebReadinessTlsFixture]::new($certificate,[Text.Encoding]::UTF8.GetBytes($case.Wire));$fixtures.Add($fixture)
  try{$actual=@(Test-OpenWebTrustedLogin $case.HostName $fixture.Port);Check ($actual.Count -eq 1 -and $actual[0] -is [bool] -and $actual[0] -eq $case.Expected)}finally{$fixture.Dispose()}
  Check ($fixture.Finished -and !$fixture.Alive -and $fixture.Accepted)
  if($case.Name -cne 'wrong_san'){Check ($fixture.Handshake -and $fixture.Request)}
 }
 $facts.scalar_boolean=$true;$facts.trusted_tls=$true
 $phase='installed_iis';$actual=@(Test-OpenWebTrustedLogin 'windowsqa.example.invalid' 8443)
 Check ($actual.Count -eq 1 -and $actual[0] -is [bool] -and $actual[0]);$facts.actual_iis=$true
 $phase='complete';$facts.state='passed'
}catch{$failure=$_}
finally{
 $cleanup=$true
 foreach($fixture in $fixtures){try{$fixture.Dispose();if(!$fixture.Finished -or $fixture.Alive){$cleanup=$false}}catch{$cleanup=$false}}
 if($snapshot){try{if((StateSnapshot) -cne $snapshot){$cleanup=$false}}catch{$cleanup=$false}}
 $facts.cleanup_exact=$cleanup
 if(!$cleanup){$facts.state='failed';if(!$failure){$phase='cleanup'}}
 $facts.phase=$phase
 if($failure){
  $facts.state='failed';$exception=$failure.Exception;$depth=0
  while($exception.InnerException -and $depth -lt 4){$exception=$exception.InnerException;$depth++}
  $type=$exception.GetType().Name;$facts.error_type=if($type -cin 'InvalidOperationException','RuntimeException','MethodInvocationException','IOException','UnauthorizedAccessException','FileNotFoundException','DirectoryNotFoundException','TimeoutException','AuthenticationException','CryptographicException','ArgumentException'){$type}else{'external_component'}
  $line=$exception.Data['ReadinessSourceLine'];$facts.source_line=if(($line -is [int] -or $line -is [long]) -and $line -ge 1 -and $line -le 99999){[int]$line}else{[Math]::Max(1,[Math]::Min(99999,[int]$failure.InvocationInfo.ScriptLineNumber))}
 }
 if($reportAllowed -and !(Test-Path -LiteralPath $report)){[IO.File]::WriteAllText($report,($facts|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))}
 if($certificate){$certificate.Dispose()}
}
if($facts.state -cne 'passed'){throw 'The native packaged readiness regression failed; inspect its closed report.'}
Write-Output ('PASS '+$facts.checks+' native Windows packaged readiness TLS/Boolean controls')
