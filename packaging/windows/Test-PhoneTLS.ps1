#Requires -RunAsAdministrator
[CmdletBinding()]
param([switch]$MaintenanceLockHeld)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$private=Join-Path $env:ProgramData 'OpenWebPBX';$root='C:\OpenWebPBX'
$lock=$null;$request=$null
try {
 if(!$MaintenanceLockHeld){$lock=[IO.File]::Open("$private\upgrade.lock",'OpenOrCreate','ReadWrite','None')}
 . "$PSScriptRoot\Restore-Gates.ps1"
 . "$PSScriptRoot\Write-PrivateState.ps1"
 if((Get-OpenWebRestoreGate -StateRoot $private).Blocked){throw 'Complete interrupted restore recovery before checking phone TLS.'}
 $metadata=Get-Content "$private\phone-tls.json" -Raw | ConvertFrom-Json
 if($metadata.RestorePending -or $metadata.Hostname -notmatch '^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$' -or $metadata.Port -ne 5061){throw 'Prepare the replacement phone certificate before activating calls.'}
 $request=Join-Path $private ('tls-check-'+[Guid]::NewGuid().ToString('N')+'.json')
 [IO.File]::WriteAllText($request,(@{configuration=(Join-Path $env:ProgramData 'fusionpbx\config.conf')} | ConvertTo-Json),[Text.UTF8Encoding]::new($false))
 $bind=''
 Push-Location "$root\web"
 try {
  & "$root\php\php.exe" "$PSScriptRoot\phone-tls.php" "$root\web" $request 'bind'
  if($LASTEXITCODE){throw 'The native phone listener address is unavailable.'}
  $bind=([Net.IPAddress]::Parse((Get-Content "$request.bind" -Raw).Trim())).ToString()
 }finally{Pop-Location}
 $verified=$false
 for($attempt=0;$attempt -lt 20;$attempt++){
  $socket=[Net.Sockets.TcpClient]::new();$stream=$null
  try{
   $connection=$socket.ConnectAsync($bind,5061)
   if(!$connection.Wait(5000)){throw 'The phone TLS listener did not answer.'}
   $stream=[Net.Security.SslStream]::new($socket.GetStream(),$false)
   $stream.ReadTimeout=5000;$stream.WriteTimeout=5000
   $stream.AuthenticateAsClient([string]$metadata.Hostname)
   if(!$stream.IsAuthenticated -or !$stream.IsEncrypted){throw 'The trusted phone TLS handshake failed.'}
   $remote=[Security.Cryptography.X509Certificates.X509Certificate2]::new($stream.RemoteCertificate)
   if($remote.Thumbprint -ne $metadata.CertificateThumbprint){throw 'The listener did not present the prepared phone certificate.'}
   $verified=$true;break
  }catch{if($attempt -eq 19){throw};Start-Sleep -Seconds 1}
  finally{if($stream){$stream.Dispose()};$socket.Dispose()}
 }
 if(!$verified){throw 'The trusted phone TLS listener did not become ready.'}
 Push-Location "$root\web"
 try{& "$root\php\php.exe" "$PSScriptRoot\phone-tls.php" "$root\web" $request 'ready';if($LASTEXITCODE){throw 'Phone TLS readiness could not be saved.'}}finally{Pop-Location}
 $metadata | Add-Member -NotePropertyName PreparedRestored -NotePropertyValue $false -Force
 Write-OpenWebPrivateState -Path "$private\phone-tls.json" -Value $metadata
 Write-Host 'Native phone TLS hostname, certificate and trusted chain verified.'
 exit 0
}catch{
 Write-Error 'Native phone TLS did not pass. Keep restored calls held and check the replacement certificate and listener.' -ErrorAction Continue
 exit 1
}finally{
 if($request){Remove-Item $request,"$request.bind" -Force -ErrorAction SilentlyContinue}
 if($lock){$lock.Dispose()}
}
