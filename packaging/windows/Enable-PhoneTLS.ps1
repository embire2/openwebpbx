#Requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory)][string]$CertificateThumbprint,[string]$FullChainPath,[IO.FileStream]$MaintenanceLock,[switch]$PrepareRestored)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$private=Join-Path $env:ProgramData 'OpenWebPBX'
$configuration=Join-Path $env:ProgramData 'fusionpbx\config.conf'
$root='C:\OpenWebPBX'
if(!(Test-Path $configuration)){throw 'Install the PBX before enabling secure phone connections.'}
$setupLock=$MaintenanceLock
if(!$setupLock){$setupLock=[IO.File]::Open("$private\upgrade.lock",'OpenOrCreate','ReadWrite','None')}
try {
. "$PSScriptRoot\Restore-Gates.ps1"
. "$PSScriptRoot\Write-PrivateState.ps1"
$restoreGate=Get-OpenWebRestoreGate -StateRoot $private
if($restoreGate.Blocked){throw 'Complete interrupted backup recovery before configuring phone certificates.'}
if($PrepareRestored){
 if(!$restoreGate.Calls -or (Get-Service FreeSWITCH).Status -ne 'Stopped'){throw 'Offline certificate preparation requires restored calls to remain held and stopped.'}
}else{
 if($restoreGate.Calls -and (Get-Service FreeSWITCH).Status -ne 'Running'){throw 'Use -PrepareRestored to configure the replacement phone certificate while restored calls remain held.'}
}
$hostLine=Get-Content $configuration | Where-Object {$_ -match '^openweb\.public_host\s*='} | Select-Object -Last 1
$phoneHost=($hostLine -split '=',2)[1].Trim()
if(!$phoneHost -or $phoneHost -eq 'localhost' -or $phoneHost -notmatch '^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'){throw 'Set a public PBX hostname and trusted HTTPS certificate before enabling Android phones.'}
$certificate=Get-Item -LiteralPath "Cert:\LocalMachine\My\$CertificateThumbprint"
if(!$certificate.HasPrivateKey -or $certificate.NotAfter -le (Get-Date) -or $certificate.NotBefore -gt (Get-Date) -or $certificate.Subject -eq $certificate.Issuer){throw 'Choose a current, exportable certificate issued by a trusted certificate authority.'}
$chain=New-Object Security.Cryptography.X509Certificates.X509Chain
$chain.ChainPolicy.RevocationMode=[Security.Cryptography.X509Certificates.X509RevocationMode]::Online
if(!$chain.Build($certificate)){throw 'Windows could not verify the phone certificate chain.'}
$chainPem=''
foreach($element in $chain.ChainElements){$chainPem+="-----BEGIN CERTIFICATE-----`n"+[Convert]::ToBase64String($element.Certificate.RawData,[Base64FormattingOptions]::InsertLineBreaks)+"`n-----END CERTIFICATE-----`n"}
# Preserve the CA's cross-signed path when it differs from Windows' preferred
# trust path. The PHP helper checks the leaf and every supplied issuer signature.
if($FullChainPath){
 $chainFile=Get-Item -LiteralPath $FullChainPath
 if($chainFile.Length -gt 262144){throw 'The certificate chain file is too large.'}
 $chainPem=[IO.File]::ReadAllText($chainFile.FullName)
}
$directory=Join-Path $private 'phone-tls'
$backup=Join-Path "$private\backups" ('phone-tls-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force $backup|Out-Null
& icacls.exe $backup /inheritance:r /grant '*S-1-5-32-544:(OI)(CI)F' /grant '*S-1-5-18:(OI)(CI)F'|Out-Null
if($LASTEXITCODE){throw 'Private certificate backup access could not be secured.'}
Copy-Item $configuration "$backup\config.conf"
$hadMetadata=Test-Path "$private\phone-tls.json"
if($hadMetadata){Copy-Item "$private\phone-tls.json" "$backup\phone-tls.json"}
$hadDirectory=Test-Path $directory
if($hadDirectory){Copy-Item $directory "$backup\phone-tls" -Recurse}
New-Item -ItemType Directory -Force $directory|Out-Null
& icacls.exe $directory /inheritance:r /grant '*S-1-5-32-544:(OI)(CI)F' /grant '*S-1-5-18:(OI)(CI)F'|Out-Null
if($LASTEXITCODE){throw 'Private phone certificate access could not be secured.'}
$inputFile=Join-Path $backup 'request.json';$pfx=Join-Path $backup 'certificate.pfx';$applied=$false
$secretBytes=New-Object byte[] 32;$random=[Security.Cryptography.RandomNumberGenerator]::Create();$random.GetBytes($secretBytes);$random.Dispose()
$secret=[Convert]::ToBase64String($secretBytes)
function Php([string]$Stage){
 Push-Location "$root\web"
 try {
  & "$root\php\php.exe" "$PSScriptRoot\phone-tls.php" "$root\web" $inputFile $Stage
  if($LASTEXITCODE -eq 75){$error=[InvalidOperationException]::new('Finish active calls before updating the phone certificate.');$error.Data['OpenWebPhoneTLSBusy']=$true;throw $error}
  if($LASTEXITCODE){
   $failure=[InvalidOperationException]::new('Secure phone setup failed.')
   $diagnostic=$inputFile+'.failure.json'
   if(Test-Path -LiteralPath $diagnostic -PathType Leaf){
    try{
     $file=Get-Item -LiteralPath $diagnostic
     if($file.Length -le 2048 -and !($file.Attributes -band [IO.FileAttributes]::ReparsePoint)){
      $record=[IO.File]::ReadAllText($diagnostic)|ConvertFrom-Json
      if($record.schema -eq 1 -and $record.error_type -match '^[A-Za-z0-9_]{1,80}$' -and $record.source_basename -in 'phone-tls.php','phone-tls-chain.php','pbx_phone_auth.php','pbx_sip_domain.php','event_socket.php','config.php','database.php','external_component' -and $record.source_line -gt 0 -and $record.source_line -lt 100000 -and $record.stage -in 'idle','bind','resume','ready','apply','rollback','initialization'){
       $failure.Data['OpenWebPhoneTLSPhpFailure']=$record
      }
     }
    }catch{}
   }
   throw $failure
  }
 }finally{Pop-Location}
}
try {
 Export-PfxCertificate -Cert $certificate -FilePath $pfx -Password (ConvertTo-SecureString $secret -AsPlainText -Force) -ChainOption BuildChain -CryptoAlgorithmOption AES256_SHA256|Out-Null
 $request=@{hostname=$phoneHost;pfx=$pfx;password=$secret;configuration=$configuration;directory=$directory;chain=$chainPem;previous="$backup\profile.json"}
 [IO.File]::WriteAllText($inputFile,($request|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
 if(!$PrepareRestored){
  Php 'idle'
  $bindAddress=([Net.IPAddress]::Parse((Get-Content "$inputFile.bind" -Raw).Trim())).ToString()
 }
 $applied=$true;Php 'apply'
 if(!$PrepareRestored){
 Restart-Service FreeSWITCH
 $verified=$false
 for($attempt=0;$attempt -lt 20;$attempt++){
  $socket=New-Object Net.Sockets.TcpClient
  try {
   $connecting=$socket.ConnectAsync($bindAddress,5061)
   if(!$connecting.Wait(5000)){throw 'The secure phone listener did not respond.'}
   $connecting.GetAwaiter().GetResult()
   $stream=New-Object Net.Security.SslStream($socket.GetStream(),$false)
   $stream.ReadTimeout=5000;$stream.WriteTimeout=5000
   # The default certificate validator checks the selected public hostname and
   # Windows trust store. Never install a validation callback that accepts all.
   $stream.AuthenticateAsClient($phoneHost)
   if(!$stream.IsAuthenticated -or !$stream.IsEncrypted){throw 'Phone TLS handshake failed.'}
   $verified=$true;$stream.Dispose();break
  }catch {Start-Sleep -Seconds 1}finally{$socket.Dispose()}
 }
 if(!$verified){throw 'The phone certificate or TLS listener could not be verified for the public PBX hostname.'}
 Php 'ready'
 }
 Write-OpenWebPrivateState -Path "$private\phone-tls.json" -Value @{PreparedRestored=[bool]$PrepareRestored;CertificateThumbprint=$CertificateThumbprint;Hostname=$phoneHost;Port=5061;ExpiresUtc=$certificate.NotAfter.ToUniversalTime().ToString('o');RestorePending=$false}
 if($PrepareRestored){Write-Host 'Replacement phone certificate prepared. Calls remain held until explicit activation and the native TLS test pass.'}else{Write-Host "Secure phones are ready for ${phoneHost}:5061. Allow TCP 5061 and the configured audio ports only where required."}
}catch{
 if($applied){
  try {if(Test-Path "$backup\profile.json"){Php 'rollback'};Copy-Item "$backup\config.conf" $configuration -Force;if($hadDirectory){Copy-Item "$backup\phone-tls\*" $directory -Recurse -Force}else{Remove-Item $directory -Recurse -Force};if($hadMetadata){Copy-Item "$backup\phone-tls.json" "$private\phone-tls.json" -Force}else{Remove-Item "$private\phone-tls.json" -Force -ErrorAction SilentlyContinue};if(!$PrepareRestored){Restart-Service FreeSWITCH}}catch{Write-Warning "Phone TLS recovery needs attention. Private backup: $backup"}
 }
 throw
}finally{
 if(!$PrepareRestored -and (Test-Path "$inputFile.paused")){try{Php 'resume'}catch{Write-Warning 'Review private certificate recovery before accepting new calls.'}}
 Remove-Item $inputFile,"$inputFile.bind",$pfx -Force -ErrorAction SilentlyContinue
 $secret=$null;$request=$null;$secretBytes=$null;$chain.Dispose()
}
}finally{if(!$MaintenanceLock){$setupLock.Dispose()}}
