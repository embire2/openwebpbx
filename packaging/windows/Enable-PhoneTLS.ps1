#Requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory)][string]$CertificateThumbprint,[string]$FullChainPath)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$private=Join-Path $env:ProgramData 'OpenWebPBX'
$configuration=Join-Path $env:ProgramData 'fusionpbx\config.conf'
$root='C:\OpenWebPBX'
if(!(Test-Path $configuration)){throw 'Install the PBX before enabling secure phone connections.'}
$setupLock=[IO.File]::Open("$private\upgrade.lock",'OpenOrCreate','ReadWrite','None')
try {
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
 try {& "$root\php\php.exe" "$PSScriptRoot\phone-tls.php" "$root\web" $inputFile $Stage;if($LASTEXITCODE){throw 'Secure phone setup failed.'}}finally{Pop-Location}
}
try {
 Export-PfxCertificate -Cert $certificate -FilePath $pfx -Password (ConvertTo-SecureString $secret -AsPlainText -Force) -ChainOption BuildChain -CryptoAlgorithmOption AES256_SHA256|Out-Null
 $request=@{pfx=$pfx;password=$secret;configuration=$configuration;directory=$directory;chain=$chainPem;previous="$backup\profile.json"}
 [IO.File]::WriteAllText($inputFile,($request|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
 Php 'idle'
 $bindAddress=([Net.IPAddress]::Parse((Get-Content "$inputFile.bind" -Raw).Trim())).ToString()
 $applied=$true;Php 'apply'
 Restart-Service FreeSWITCH
 $verified=$false
 for($attempt=0;$attempt -lt 20;$attempt++){
  $socket=New-Object Net.Sockets.TcpClient
  try {
   $socket.Connect($bindAddress,5061)
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
 @{CertificateThumbprint=$CertificateThumbprint;Hostname=$phoneHost;Port=5061}|ConvertTo-Json|Set-Content "$private\phone-tls.json" -Encoding UTF8
 Write-Host "Secure phones are ready for ${phoneHost}:5061. Allow TCP 5061 and the configured audio ports only where required."
}catch{
 if($applied){
  try {if(Test-Path "$backup\profile.json"){Php 'rollback'};Copy-Item "$backup\config.conf" $configuration -Force;if($hadDirectory){Copy-Item "$backup\phone-tls\*" $directory -Recurse -Force}else{Remove-Item $directory -Recurse -Force};Restart-Service FreeSWITCH}catch{Write-Warning "Phone TLS recovery needs attention. Private backup: $backup"}
 }
 throw
}finally{
 Remove-Item $inputFile,"$inputFile.bind",$pfx -Force -ErrorAction SilentlyContinue
 $secret=$null;$request=$null;$secretBytes=$null;$chain.Dispose()
}
}finally{$setupLock.Dispose()}
