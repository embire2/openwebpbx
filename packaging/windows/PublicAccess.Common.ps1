# SPDX-License-Identifier: AGPL-3.0-or-later
# Shared administrator-only public-certificate operations. No code runs on import.
function Assert-OpenWebPublicHostname([string]$Hostname) {
 $name=$Hostname.Trim().ToLowerInvariant()
 if($name.Length -gt 253 -or $name -notmatch '^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$' -or $name -match '\.(localhost|local|invalid|test|example)$') { throw 'Enter a public DNS hostname, without a scheme, port or wildcard.' }
 return $name
}
function Assert-OpenWebPublicAddress([string]$Address) {
 $ip=$null
 if(-not [Net.IPAddress]::TryParse($Address,[ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'Enter the public IPv4 address which forwards to this server.' }
 $b=$ip.GetAddressBytes()
 if($b[0] -in 0,10,127 -or $b[0] -ge 224 -or ($b[0] -eq 169 -and $b[1] -eq 254) -or ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or ($b[0] -eq 192 -and $b[1] -eq 168) -or ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127) -or ($b[0] -eq 198 -and $b[1] -in 18,19) -or ($b[0] -eq 192 -and $b[1] -eq 0 -and $b[2] -in 0,2) -or ($b[0] -eq 198 -and $b[1] -eq 51 -and $b[2] -eq 100) -or ($b[0] -eq 203 -and $b[1] -eq 0 -and $b[2] -eq 113)) { throw 'Use the public address rather than a local, private or carrier-NAT address.' }
 return $ip.ToString()
}
function Resolve-OpenWebPublicAddress([string]$Configured,[string[]]$DnsAddresses) {
 $addresses=@($DnsAddresses|Sort-Object -Unique)
 if([string]::IsNullOrWhiteSpace($Configured)) {
  if($addresses.Count -ne 1) { throw 'Public DNS must have exactly one IPv4 address for automatic setup. Choose the intended public address when using multiple records.' }
  $Configured=$addresses[0]
 }
 $chosen=Assert-OpenWebPublicAddress $Configured
 if(-not $addresses.Count -or @($addresses|Where-Object {$_ -ne $chosen}).Count) { throw 'The public DNS A records must point to the chosen public address. Update DNS, allow propagation and retry.' }
 return $chosen
}
function Assert-OpenWebPublicEmail([string]$Email) {
 try { $mail=[Net.Mail.MailAddress]::new($Email) } catch { throw 'Enter a valid certificate renewal email address.' }
 if($mail.Address -ne $Email -or $Email.Length -gt 254 -or $Email -match '[\r\n\s]' -or $mail.Host -notmatch '\.') { throw 'Enter a valid certificate renewal email address.' }
 return $mail.Address
}
function Assert-OpenWebOrdinaryPath([string]$Path,[bool]$Directory=$false) {
 $full=[IO.Path]::GetFullPath($Path)
 if($full.StartsWith('\\')) { throw 'Public-certificate files must use ordinary local storage.' }
 $item=Get-Item -LiteralPath $full -Force
 if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or [bool]$item.PSIsContainer -ne $Directory) { throw 'Public-certificate files must use ordinary local storage.' }
 $parent=[IO.Path]::GetDirectoryName($full.TrimEnd('\'))
 while($parent) {
  $ancestor=Get-Item -LiteralPath $parent -Force
  if(-not $ancestor.PSIsContainer -or ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Public-certificate storage contains a redirected directory.' }
  $parent=[IO.Path]::GetDirectoryName($parent.TrimEnd('\'))
 }
 return $full
}
function Set-OpenWebPublicPrivateAcl([string]$Directory) {
 $null=Assert-OpenWebOrdinaryPath $Directory $true
 $acl=[Security.AccessControl.DirectorySecurity]::new()
 $acl.SetAccessRuleProtection($true,$false)
 $acl.SetOwner([Security.Principal.SecurityIdentifier]'S-1-5-32-544')
 foreach($sid in 'S-1-5-32-544','S-1-5-18') {
  $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]$sid,[Security.AccessControl.FileSystemRights]::FullControl,[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit',[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow))
 }
 Set-Acl -LiteralPath $Directory -AclObject $acl
}
function Write-OpenWebPublicJson([string]$Path,$Value) {
 if(Test-Path -LiteralPath $Path) { $null=Assert-OpenWebOrdinaryPath $Path }
 $temporary=$Path+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
 try {
  $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 12))
  $file=[IO.FileStream]::new($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
  try { $file.Write($bytes,0,$bytes.Length);$file.Flush($true) } finally { $file.Dispose() }
  if(Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary,$Path,[NullString]::Value) } else { [IO.File]::Move($temporary,$Path) }
 } finally { if(Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}
function Read-OpenWebPublicJson([string]$Path) {
 $null=Assert-OpenWebOrdinaryPath $Path
 if((Get-Item -LiteralPath $Path).Length -gt 65536) { throw 'Public-access state is too large.' }
 return ([IO.File]::ReadAllText($Path)|ConvertFrom-Json)
}
function Get-OpenWebPublicContext([string]$StateRoot,[string]$Root) {
 if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Windows is required.' }
 if(-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run public access setup as an administrator.' }
 if($StateRoot -match '["\r\n]' -or $Root -match '["\r\n]') { throw 'The installed paths contain invalid command characters.' }
 $StateRoot=Assert-OpenWebOrdinaryPath $StateRoot $true
 $Root=Assert-OpenWebOrdinaryPath $Root $true
 $configuration=Join-Path (Join-Path $env:ProgramData 'fusionpbx') 'config.conf'
 $null=Assert-OpenWebOrdinaryPath $configuration
 $installed=Read-OpenWebPublicJson (Join-Path $StateRoot 'installation.json')
 if(-not $installed.Completed) { throw 'Finish installing the PBX before setting up public access.' }
 $directory=Join-Path $StateRoot 'public-access'
 $gates=Join-Path $PSScriptRoot 'Restore-Gates.ps1'
 $null=Assert-OpenWebOrdinaryPath $gates
 . $gates
 return @{StateRoot=$StateRoot;Root=$Root;Directory=$directory;Configuration=$configuration;LockPath=(Join-Path $StateRoot 'upgrade.lock')}
}
function Assert-OpenWebPublicMaintenance($Context,[IO.FileStream]$MaintenanceLock) {
 if($null -eq $MaintenanceLock -or -not $MaintenanceLock.CanRead -or -not $MaintenanceLock.CanWrite -or [IO.Path]::GetFullPath($MaintenanceLock.Name) -ne [IO.Path]::GetFullPath($Context.LockPath)) { throw 'An owned PBX maintenance lock is required.' }
 # Load in this scope, so the shared backup/restore gate is checked freshly.
 . (Join-Path $PSScriptRoot 'Restore-Gates.ps1')
 Assert-OpenWebUpgradeAllowed -StateRoot $Context.StateRoot
}
function Initialize-OpenWebPublicDirectory($Context,[IO.FileStream]$MaintenanceLock) {
 Assert-OpenWebPublicMaintenance $Context $MaintenanceLock
 if(-not (Test-Path -LiteralPath $Context.Directory)) { New-Item -ItemType Directory -Path $Context.Directory|Out-Null }
 Set-OpenWebPublicPrivateAcl $Context.Directory
}
function Get-OpenWebPublicBindingState([string]$Hostname) {
 $manager=[Microsoft.Web.Administration.ServerManager]::new()
 try {
  $binding=@($manager.Sites['OpenWebPBX'].Bindings|Where-Object {$_.Protocol -eq 'https' -and $_.Host -eq $Hostname -and $_.EndPoint.Port -eq 443})
  if($binding.Count -gt 1) { throw 'The public hostname has duplicate HTTPS bindings.' }
  if(-not $binding.Count) { return @{present=$false} }
  return @{present=$true;information=$binding[0].BindingInformation;hash=$binding[0].CertificateHash;store=$binding[0].CertificateStoreName;flags=$binding[0].SslFlags}
 } finally { $manager.Dispose() }
}
function Restore-OpenWebPublicBinding([string]$Hostname,$Previous) {
 $manager=[Microsoft.Web.Administration.ServerManager]::new()
 try {
  $site=$manager.Sites['OpenWebPBX']
  $current=@($site.Bindings|Where-Object {$_.Protocol -eq 'https' -and $_.Host -eq $Hostname -and $_.EndPoint.Port -eq 443})
  if($current.Count -gt 1) { throw 'The public HTTPS binding changed during recovery.' }
  if($Previous.present) {
   if(-not $current.Count -or $current[0].BindingInformation -ne $Previous.information) { throw 'The previous public HTTPS binding needs administrator recovery.' }
   $current[0].CertificateHash=$Previous.hash;$current[0].CertificateStoreName=$Previous.store;$current[0].SslFlags=$Previous.flags
  } elseif($current.Count) { $site.Bindings.Remove($current[0]) }
  $manager.CommitChanges()
 } finally { $manager.Dispose() }
}
function Get-OpenWebPublicCertificate([string]$Thumbprint,[string]$Hostname) {
 if($Thumbprint -notmatch '^[a-fA-F0-9]{40}$') { throw 'The certificate thumbprint is invalid.' }
 $cert=Get-Item -LiteralPath ('Cert:\LocalMachine\My\'+$Thumbprint)
 if(-not $cert.HasPrivateKey -or $cert.NotBefore.ToUniversalTime() -gt [DateTime]::UtcNow -or $cert.NotAfter.ToUniversalTime() -le [DateTime]::UtcNow.AddMinutes(2) -or $cert.Subject -eq $cert.Issuer) { throw 'A current trusted certificate and exportable private key are required.' }
 if(-not @($cert.Extensions|Where-Object {$_.Oid.Value -eq '2.5.29.17'}).Count) { throw 'The public certificate must contain a DNS subject alternative name.' }
 $matches=@($cert.DnsNameList|Where-Object {
  $dns=$_.Punycode.ToLowerInvariant()
  $dns -eq $Hostname -or ($dns.StartsWith('*.') -and $Hostname.EndsWith($dns.Substring(1)) -and $Hostname.Split('.').Count -eq $dns.Split('.').Count)
 })
 if(-not $matches.Count) { throw 'The public hostname is absent from the certificate.' }
 $chain=[Security.Cryptography.X509Certificates.X509Chain]::new()
 try {
  $chain.ChainPolicy.RevocationMode=[Security.Cryptography.X509Certificates.X509RevocationMode]::Online
  if(-not $chain.Build($cert)) { throw 'Windows cannot verify the public certificate chain.' }
 } finally { $chain.Dispose() }
 return $cert
}
function Get-OpenWebPublicSite([string]$Hostname,[string]$Root) {
 Add-Type -Path (Join-Path $env:windir 'System32\inetsrv\Microsoft.Web.Administration.dll')
 $manager=[Microsoft.Web.Administration.ServerManager]::new()
 try {
  $site=$manager.Sites['OpenWebPBX']
  if($null -eq $site -or [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($site.Applications['/'].VirtualDirectories['/'].PhysicalPath)).TrimEnd('\') -ne [IO.Path]::GetFullPath((Join-Path $Root 'web')).TrimEnd('\')) { throw 'The installed OpenWeb PBX website was not found.' }
  foreach($other in $manager.Sites) {
   foreach($binding in $other.Bindings) {
    if($binding.Protocol -in 'http','https' -and $binding.Host -eq $Hostname -and $other.Name -ne 'OpenWebPBX') {
     $ownedAcme=$other.Name -eq 'OpenWebPBX ACME' -and $binding.Protocol -eq 'http' -and $binding.EndPoint.Port -eq 80 -and [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($other.Applications['/'].VirtualDirectories['/'].PhysicalPath)).TrimEnd('\') -eq [IO.Path]::GetFullPath((Join-Path $Root 'acme-http')).TrimEnd('\')
     if(-not $ownedAcme) { throw 'This hostname belongs to another IIS website.' }
    }
   }
  }
  return [int]$site.Id
 } finally { $manager.Dispose() }
}
function Set-OpenWebPublicBinding([string]$Hostname,[string]$Protocol,[string]$Thumbprint='',[string]$Root='C:\OpenWebPBX') {
 $port=if($Protocol -eq 'https'){443}else{80}
 $manager=[Microsoft.Web.Administration.ServerManager]::new()
 try {
  $target='*:'+${port}+':'+$Hostname
  if($Protocol -eq 'http') {
   $webroot=Join-Path $Root 'acme-http'
   if(-not (Test-Path -LiteralPath $webroot)) { New-Item -ItemType Directory -Path $webroot|Out-Null }
   Set-OpenWebPublicPrivateAcl $webroot
   # A separate empty/denied site prevents plain-HTTP access to Admin. The
   # temporary HTTP.sys challenge listener handles its more-specific URL prefix.
   $site=$manager.Sites['OpenWebPBX ACME']
   if($null -eq $site) {
    $site=$manager.Sites.Add('OpenWebPBX ACME','http',$target,$webroot)
    $site.Applications['/'].ApplicationPoolName='OpenWebPBX'
   } elseif([IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($site.Applications['/'].VirtualDirectories['/'].PhysicalPath)).TrimEnd('\') -ne [IO.Path]::GetFullPath($webroot).TrimEnd('\')) { throw 'The ACME website name belongs to another configuration.' }
  } else { $site=$manager.Sites['OpenWebPBX'] }
  $existing=@($site.Bindings|Where-Object {$_.Protocol -eq $Protocol -and $_.Host -eq $Hostname -and $_.EndPoint.Port -eq $port})
  if($existing.Count -gt 1 -or ($existing.Count -eq 1 -and $existing[0].BindingInformation -ne $target)) { throw 'The public hostname has an incompatible IIS binding. Preserve it and resolve the conflict first.' }
  $created=$existing.Count -eq 0
  if($created) { $binding=$site.Bindings.Add($target,$Protocol) } else { $binding=$existing[0] }
  if($Protocol -eq 'https') {
   $binding.CertificateHash=for($i=0;$i -lt $Thumbprint.Length;$i+=2){[Convert]::ToByte($Thumbprint.Substring($i,2),16)}
   $binding.CertificateStoreName='My';$binding.SslFlags=[Microsoft.Web.Administration.SslFlags]::Sni
  }
  $manager.CommitChanges()
  return $created
 } finally { $manager.Dispose() }
}
function Test-OpenWebPublicHttps([string]$Hostname,[string]$Thumbprint) {
 $socket=[Net.Sockets.TcpClient]::new()
 try {
  $connect=$socket.ConnectAsync('127.0.0.1',443)
  if(-not $connect.Wait(10000)) { throw 'The public HTTPS listener did not respond.' }
  $stream=[Net.Security.SslStream]::new($socket.GetStream(),$false)
  try {
   $stream.ReadTimeout=10000;$stream.WriteTimeout=10000
   $authentication=$stream.BeginAuthenticateAsClient($Hostname,$null,$null)
   if(-not $authentication.AsyncWaitHandle.WaitOne(15000)) { throw 'The public HTTPS certificate handshake timed out.' }
   $stream.EndAuthenticateAsClient($authentication)
   $presented=[Security.Cryptography.X509Certificates.X509Certificate2]::new($stream.RemoteCertificate)
   try { if($presented.Thumbprint -ne $Thumbprint) { throw 'IIS presented a different public certificate.' } } finally { $presented.Dispose() }
   if(-not $stream.IsAuthenticated -or -not $stream.IsEncrypted) { throw 'Public HTTPS is not encrypted.' }
  } finally { $stream.Dispose() }
 } finally { $socket.Dispose() }
}
function Set-OpenWebPublicConfiguration([string]$Path,[string]$Hostname,[string]$Address) {
 $original=[IO.File]::ReadAllBytes($Path)
 $text=[Text.UTF8Encoding]::new($false,$true).GetString($original)
 foreach($key in 'openweb.public_host','openweb.public_url','openweb.public_ip') { $text=[regex]::Replace($text,'(?m)^'+[regex]::Escape($key)+'\s*=.*(?:\r?\n|$)','') }
 $text=$text.TrimEnd("`r","`n")+"`r`nopenweb.public_host = $Hostname`r`nopenweb.public_url = https://$Hostname`r`nopenweb.public_ip = $Address`r`n"
 # Replace bytes in the same protected file; do not replace its private ACL.
 $file=[IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::Read)
 try { $bytes=[Text.UTF8Encoding]::new($false).GetBytes($text);$file.SetLength(0);$file.Write($bytes,0,$bytes.Length);$file.Flush($true) } finally { $file.Dispose() }
 return ,$original
}
function Initialize-OpenWebAcme($Context) {
 $client=Join-Path $Context.Root 'acme'
 $null=Assert-OpenWebOrdinaryPath $client $true
 $manifest=Read-OpenWebPublicJson (Join-Path $client 'bundle-manifest.json')
 if($manifest.schema -ne 1 -or $manifest.version -ne '2.4.1.2444' -or $manifest.archive_sha256 -ne 'b53fd863dfe4e02ec8618e9676b331d805fa1d688b83251f797f9339d221dada') { throw 'Use the pinned ACME client from the complete release.' }
 foreach($entry in $manifest.files.PSObject.Properties) {
  if($entry.Name -notmatch '^[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*$') { throw 'The ACME client manifest contains an invalid path.' }
  $path=Join-Path $client $entry.Name
  $null=Assert-OpenWebOrdinaryPath $path
  if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $entry.Value) { throw 'The pinned ACME client integrity check failed.' }
 }
 $defaults=Read-OpenWebPublicJson (Join-Path $client 'settings_default.json')
 $defaults.Client.ConfigurationPath=Join-Path $Context.Directory 'accounts'
 $defaults.Client.LogPath=Join-Path $Context.Directory 'logs'
 $defaults.Store.CertificateStore.PrivateKeyExportable=$true
 $defaults.Store.CertificateStore.DefaultStore='My'
 $defaults.Cache.DeleteStaleFiles=$false
 $defaults.Acme.ValidateServerCertificate=$true
 Write-OpenWebPublicJson (Join-Path $client 'settings.json') $defaults
 return (Join-Path $client 'wacs.exe')
}
function Invoke-OpenWebAcme($Context,[string]$Executable,[string[]]$Arguments) {
 $logs=Join-Path $Context.Directory 'logs'
 if(-not (Test-Path -LiteralPath $logs)) { New-Item -ItemType Directory -Path $logs|Out-Null }
 $null=Assert-OpenWebOrdinaryPath $logs $true
 $log=Join-Path $logs ('operation-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[Guid]::NewGuid().ToString('N').Substring(0,8)+'.log')
 $previousPreference=$ErrorActionPreference
 try {
  # The client may print renewal/account details. Keep its output in the private
  # directory rather than a desktop response or public qualification summary.
  $ErrorActionPreference='Continue';$LASTEXITCODE=$null
  & $Executable @Arguments 2>&1 | Out-File -LiteralPath $log -Encoding UTF8
  $code=$LASTEXITCODE
 } finally { $ErrorActionPreference=$previousPreference }
 if($null -eq $code -or $code -ne 0) { throw 'Certificate issuance or renewal failed. Check public DNS/TCP 80 forwarding and the private ACME log, then retry.' }
}
function Register-OpenWebPublicTasks([string]$Root,[string]$StateRoot) {
 $helper=Join-Path $Root 'tools\Renew-PhoneCertificate.ps1'
 $null=Assert-OpenWebOrdinaryPath $helper
 $executable=Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
 $principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
 $settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::FromMinutes(30))
 foreach($mode in 'renew','pending') {
  $name=if($mode -eq 'renew'){'OpenWebPBX Certificate Renewal'}else{'OpenWebPBX Pending Phone Certificate'}
  $argument='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$helper+'" -Root "'+$Root+'" -StateRoot "'+$StateRoot+'"'
  if($mode -eq 'renew') { $argument+=' -Renew';$trigger=New-ScheduledTaskTrigger -Daily -At '03:17' -RandomDelay ([TimeSpan]::FromHours(2)) }
  else { $trigger=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval ([TimeSpan]::FromMinutes(5)) }
  $existing=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
  if($existing -and $existing.Description -ne 'OpenWeb PBX owned public certificate task') { throw 'A certificate task with this name belongs to another administrator.' }
  $action=New-ScheduledTaskAction -Execute $executable -Argument $argument
  Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'OpenWeb PBX owned public certificate task' -Force|Out-Null
 }
}
