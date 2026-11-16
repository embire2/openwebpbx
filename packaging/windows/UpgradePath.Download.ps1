# Download only archives selected by the independently verified upgrade plan.
# This helper changes no service, trust watermark, installed file or release feed.
function Get-OpenWebUpgradePathArchive {
 [CmdletBinding()]
 param(
  [Parameter(Mandatory)]$Asset,
  [Parameter(Mandatory)][string]$ArchiveDirectory
 )
 $ErrorActionPreference='Stop'
 if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or $PSVersionTable.PSEdition -eq 'Core'){throw 'Use Windows PowerShell for the Windows upgrade download.'}
 $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
 if(!(New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Administrator access is required to stage a server update.'}
 if($Asset.platform -cne 'windows-x64' -or $Asset.name -cnotmatch '\Aopenwebpbx-(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-windows-x64\.zip\z'){throw 'The verified Windows archive identity is invalid.'}
 $version=$Matches[1]+'.'+$Matches[2]+'.'+$Matches[3]
 if($Asset.bytes -isnot [int] -and $Asset.bytes -isnot [long]){throw 'The verified archive size must be an integer.'}
 $expected=[long]$Asset.bytes
 $canonical='https://github.com/embire2/openwebpbx/releases/download/v'+$version+'/'+$Asset.name
 if($expected -lt 1 -or $expected -gt 8GB -or $Asset.sha256 -cnotmatch '\A[a-f0-9]{64}\z' -or $Asset.url -cne $canonical){throw 'The verified Windows archive details are invalid.'}
 if($ArchiveDirectory -notmatch '\A[A-Za-z]:[\\/]' -or $ArchiveDirectory.IndexOfAny([char[]]@([char]0,[char]10,[char]13)) -ge 0 -or $ArchiveDirectory.IndexOf(':',2) -ge 0){throw 'Use an ordinary local private archive directory.'}
 $directory=[IO.Path]::GetFullPath($ArchiveDirectory).TrimEnd('\')
 $allowed=@('S-1-5-18','S-1-5-32-544',$identity.User.Value,($identity.User.AccountDomainSid.Value+'-500'))
 # Do not follow junctions, or accept an ancestor that another account can
 # rename, delete or turn into a different protected-path boundary.
 $ancestor=$directory
 while($ancestor){
  $item=Get-Item -LiteralPath $ancestor -Force
  if(!($item -is [IO.DirectoryInfo]) -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Archive directories must not contain links or junctions.'}
  $acl=Get-Acl -LiteralPath $ancestor
  $owner=$acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
  if($allowed -cnotcontains $owner -and $owner -cne 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'){throw 'An archive directory has an untrusted owner.'}
  # Normal ProgramData permits creating new children. That cannot replace an
  # existing protected directory; deleting children or changing its ACL can.
  $writeMask=if($ancestor -ieq $directory){852310}else{852032}
  foreach($ace in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){
   if($ace.AccessControlType -eq 'Allow' -and ([int]$ace.FileSystemRights -band $writeMask) -and $allowed -cnotcontains $ace.IdentityReference.Value -and $ace.IdentityReference.Value -cne 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'){throw 'An archive directory is writable outside the trusted administrator boundary.'}
  }
  $parent=[IO.Path]::GetDirectoryName($ancestor);if($parent -eq $ancestor){break};$ancestor=$parent
 }
 function Test-ArchiveFile([string]$Path){
  $item=Get-Item -LiteralPath $Path -Force
  if(!($item -is [IO.FileInfo]) -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'An update archive must be an ordinary file.'}
  if($item.Length -ne $expected){return $false}
  (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $Asset.sha256
 }
 function Allowed-ArchiveUri([Uri]$Uri){
  if(!$Uri.IsAbsoluteUri -or $Uri.Scheme -cne 'https' -or $Uri.Port -ne 443 -or $Uri.UserInfo -or $Uri.Fragment -or $Uri.AbsoluteUri.Length -gt 16384){return $false}
  if($Uri.DnsSafeHost -ceq 'github.com'){return $Uri.AbsolutePath.StartsWith('/embire2/openwebpbx/releases/download/',[StringComparison]::Ordinal)}
  $Uri.DnsSafeHost -cin @('release-assets.githubusercontent.com','objects.githubusercontent.com')
 }
 $destination=Join-Path $directory $Asset.name
 $single=$null;$attempt=$null;$partial=$null;$output=$null;$inputStream=$null;$response=$null;$request=$null;$received=0L
 $priorTls=[Net.ServicePointManager]::SecurityProtocol
 try{
  $single=[IO.File]::Open((Join-Path $directory ($Asset.name+'.download.lock')),'OpenOrCreate','ReadWrite','None')
  if(Test-Path -LiteralPath $destination){if(Test-ArchiveFile $destination){return $destination}}
  $drive=New-Object IO.DriveInfo([IO.Path]::GetPathRoot($directory))
  if($drive.AvailableFreeSpace -lt ($expected+10GB)){throw 'The archive download would consume the 10GiB recovery reserve.'}
  $attempt=Join-Path $directory ('download-'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')+'-'+[Guid]::NewGuid().ToString('N'))
  $null=[IO.Directory]::CreateDirectory($attempt)
  $privateAcl=New-Object Security.AccessControl.DirectorySecurity
  $privateAcl.SetAccessRuleProtection($true,$false)
  $privateAcl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
  foreach($sid in @('S-1-5-18','S-1-5-32-544')){
   $privateAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)),[Security.AccessControl.FileSystemRights]::FullControl,([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit),[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)))
  }
  (Get-Item -LiteralPath $attempt).SetAccessControl($privateAcl)
  if(Test-Path -LiteralPath $destination){[IO.File]::Move($destination,(Join-Path $attempt ('previous-invalid-'+$Asset.name)))}
  $partial=Join-Path $attempt ($Asset.name+'.part')
  $output=New-Object IO.FileStream($partial,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
  [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
  $clock=[Diagnostics.Stopwatch]::StartNew();$uri=[Uri]$canonical;$redirects=0
  while($true){
   if(!(Allowed-ArchiveUri $uri)){throw 'The update download redirected outside the trusted release hosts.'}
   if($clock.Elapsed.TotalSeconds -ge 7200){throw 'The archive download exceeded its two-hour time limit.'}
   $request=[Net.HttpWebRequest]::Create($uri)
   $request.Method='GET';$request.AllowAutoRedirect=$false;$request.UseDefaultCredentials=$false;$request.Credentials=$null;$request.PreAuthenticate=$false;$request.Proxy=$null
   $request.Timeout=45000;$request.ReadWriteTimeout=60000;$request.AutomaticDecompression=[Net.DecompressionMethods]::None
   $request.UserAgent='OpenWebPBX-UpgradePath/1';$request.Headers['Accept-Encoding']='identity'
   $response=[Net.HttpWebResponse]$request.GetResponse()
   $status=[int]$response.StatusCode
   if($status -in @(301,302,303,307,308)){
    $location=$response.Headers['Location'];$response.Dispose();$response=$null
    if(!$location -or $redirects -ge 5){throw 'The update download has an incomplete or excessive redirect chain.'}
    $uri=New-Object Uri($uri,$location);$redirects++;continue
   }
   if($status -ne 200 -or ($response.ContentLength -ge 0 -and $response.ContentLength -ne $expected) -or ($response.ContentEncoding -and $response.ContentEncoding -cne 'identity')){throw 'The update server returned an unexpected archive response.'}
   break
  }
  $inputStream=$response.GetResponseStream();$buffer=New-Object byte[] 131072
  while($true){
   if($clock.Elapsed.TotalSeconds -ge 7200){throw 'The archive download exceeded its two-hour time limit.'}
   $count=$inputStream.Read($buffer,0,$buffer.Length)
   if($count -eq 0){break}
   if($received+$count -gt $expected){throw 'The archive download exceeds its signed size.'}
   $output.Write($buffer,0,$count);$received+=$count
  }
  $output.Flush($true);$output.Dispose();$output=$null
  $inputStream.Dispose();$inputStream=$null;$response.Dispose();$response=$null
  if(!(Test-ArchiveFile $partial)){throw 'The downloaded archive does not match its signed size and checksum.'}
  # The staging directory is on the destination volume. Move never overwrites
  # an unexpected existing destination and only exposes the verified full file.
  [IO.File]::Move($partial,$destination)
  return $destination
 }catch{
  if($attempt -and (Test-Path -LiteralPath $attempt)){
   $safe=@{schema=1;state='failed';version=$version;expected_bytes=$expected;received_bytes=$received;error_type=$_.Exception.GetType().FullName;failed_at=[DateTime]::UtcNow.ToString('o')}
   try{[IO.File]::WriteAllText((Join-Path $attempt 'failure.json'),($safe|ConvertTo-Json -Depth 4),(New-Object Text.UTF8Encoding($false)))}catch{}
  }
  throw 'The signed archive could not be downloaded. Any partial download and failure receipt remain in the private archive directory; installed services were not changed.'
 }finally{
  if($inputStream){$inputStream.Dispose()};if($response){$response.Dispose()};if($output){$output.Dispose()};if($request){$request.Abort()}
  [Net.ServicePointManager]::SecurityProtocol=$priorTls
  if($single){$single.Dispose()}
 }
}
