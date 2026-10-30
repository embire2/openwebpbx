#Requires -RunAsAdministrator
# SPDX-License-Identifier: AGPL-3.0-or-later
[CmdletBinding()]
param([Parameter(Mandatory=$true)][ValidateSet('KeyAcl','FilePrivate','FilePublic','DirectoryPrivate','DirectoryPublic','Prepare','Certify','Record')][string]$Operation,[string]$InputFile,[string]$CertificateThumbprint)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
. (Join-Path $PSScriptRoot 'PublicAccess.Common.ps1')
function Assert-OpenWebTenantName([string]$Name){
 if($Name -cnotmatch '^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]\.openwebpbx\.com$'){throw 'An exact leased tenant hostname is required.'};return $Name
}
function Get-OpenWebTenantAclTarget([string]$Path,[bool]$Directory){
 $full=Assert-OpenWebOrdinaryPath $Path $Directory
 $state=[IO.Path]::GetFullPath((Join-Path $env:ProgramData 'OpenWebPBX\tenant-domains'))
 $config=[IO.Path]::GetFullPath((Join-Path $env:ProgramData 'fusionpbx'))
 $inside=$full.Equals($state,[StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($state+'\',[StringComparison]::OrdinalIgnoreCase)
 $key=[IO.Path]::GetDirectoryName($full).Equals($config,[StringComparison]::OrdinalIgnoreCase) -and ([IO.Path]::GetFileName($full) -eq 'tenant-domains-instance-key.pem' -or [IO.Path]::GetFileName($full) -match '^\.tenant-domains-[a-zA-Z0-9_-]+$')
 if(!$inside -and !(!$Directory -and $key)){throw 'The tenant-domain ACL target is outside owned storage.'};return $full
}
function Set-OpenWebTenantAcl([string]$Path,[bool]$Directory,[bool]$Public){
 $Path=Get-OpenWebTenantAclTarget $Path $Directory
 if($Public -and [IO.Path]::GetDirectoryName($Path) -eq (Join-Path $env:ProgramData 'fusionpbx')){throw 'Instance keys are private.'}
 $acl=if($Directory){[Security.AccessControl.DirectorySecurity]::new()}else{[Security.AccessControl.FileSecurity]::new()}
 $acl.SetAccessRuleProtection($true,$false);$acl.SetOwner([Security.Principal.SecurityIdentifier]'S-1-5-32-544')
 $inherit=if($Directory){[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'}else{[Security.AccessControl.InheritanceFlags]::None}
 foreach($sid in 'S-1-5-18','S-1-5-32-544'){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]$sid,'FullControl',$inherit,'None','Allow'))}
 # IIS reads configuration as the application pool, but serves anonymous
 # static nonce files as IUSR by default. Both may read only public state;
 # private keys/certificate inputs retain the two privileged principals.
 if($Public){foreach($sid in 'S-1-5-32-568','S-1-5-17','S-1-5-19'){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]$sid,'ReadAndExecute',$inherit,'None','Allow'))}}
 Set-Acl -LiteralPath $Path -AclObject $acl
 $actual=Get-Acl -LiteralPath $Path
 if(!$actual.AreAccessRulesProtected -or $actual.Owner -ne $acl.Owner -or $actual.Access.Count -ne $acl.Access.Count){throw 'Private tenant-domain ACL verification failed.'}
 $allowed=@('S-1-5-18','S-1-5-32-544');if($Public){$allowed+=@('S-1-5-32-568','S-1-5-17','S-1-5-19')}
 foreach($rule in $actual.Access){$sid=$rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value;if($rule.AccessControlType -ne 'Allow' -or $sid -notin $allowed){throw 'Unexpected tenant-domain ACL.'}}
}
function Read-OpenWebTenantInput([string]$Path){
 $null=Get-OpenWebTenantAclTarget $Path $false
 if((Get-Item -LiteralPath $Path).Length -gt 8192){throw 'Bounded certificate input required.'}
 $value=[IO.File]::ReadAllText($Path)|ConvertFrom-Json
 if(@($value.PSObject.Properties.Name).Count -ne 3 -or @($value.PSObject.Properties.Name|Where-Object {$_ -notin 'names','key_hash','contact'}).Count -or $value.key_hash -cnotmatch '^[a-f0-9]{64}$' -or @($value.names).Count -lt 1 -or @($value.names).Count -gt 50){throw 'Invalid tenant certificate request.'}
 $names=@($value.names|ForEach-Object {Assert-OpenWebTenantName $_}|Sort-Object -Unique)
 if($names.Count -ne @($value.names).Count){throw 'Duplicate certificate names refused.'}
 $null=Assert-OpenWebPublicEmail $value.contact
 return $value
}
function Initialize-OpenWebTenantProof([string]$Root,[string]$State){
 Add-Type -Path (Join-Path $env:windir 'System32\inetsrv\Microsoft.Web.Administration.dll')
 $proof=Join-Path $State 'proofs\.well-known\openwebpbx-instance';$null=Get-OpenWebTenantAclTarget $proof $true
 $manager=[Microsoft.Web.Administration.ServerManager]::new()
 try{
  $site=$manager.Sites['OpenWebPBX'];if(!$site -or [IO.Path]::GetFullPath($site.Applications['/'].VirtualDirectories['/'].PhysicalPath).TrimEnd('\') -ne ($Root+'\web')){throw 'The installed PBX site is required.'}
  $v=$site.Applications['/'].VirtualDirectories['/.well-known/openwebpbx-instance']
  if($v -and [IO.Path]::GetFullPath($v.PhysicalPath) -ne $proof){throw 'The instance proof URL belongs to another configuration.'}
  if(!$v){$null=$site.Applications['/'].VirtualDirectories.Add('/.well-known/openwebpbx-instance',$proof);$manager.CommitChanges()}
 }finally{$manager.Dispose()}
 # Extensionless nonce files are static text, never PHP or executable handlers.
 $config=Join-Path $proof 'web.config';$bytes=[Text.UTF8Encoding]::new($false).GetBytes('<configuration><system.webServer><handlers><clear/><add name="TenantInstanceProof" path="*" verb="GET,HEAD" modules="StaticFileModule" resourceType="File" requireAccess="Read"/></handlers><staticContent><remove fileExtension="."/><mimeMap fileExtension="." mimeType="text/plain"/></staticContent></system.webServer></configuration>')
 if(Test-Path -LiteralPath $config){$null=Get-OpenWebTenantAclTarget $config $false;if([Convert]::ToBase64String([IO.File]::ReadAllBytes($config)) -ne [Convert]::ToBase64String($bytes)){throw 'The instance proof configuration belongs to another configuration.'}}
 else{[IO.File]::WriteAllBytes($config,$bytes);Set-OpenWebTenantAcl $config $false $true}
}
function Invoke-OpenWebTenantOperation {
 $root='C:\OpenWebPBX';$state=Join-Path $env:ProgramData 'OpenWebPBX\tenant-domains';$private=Join-Path $state 'private'
 if($Operation -in 'FilePrivate','FilePublic','DirectoryPrivate','DirectoryPublic','KeyAcl'){
  if($Operation -eq 'KeyAcl' -and [IO.Path]::GetFullPath($InputFile) -ne (Join-Path $env:ProgramData 'fusionpbx\tenant-domains-instance-key.pem')){throw 'The exact instance key is required.'}
  Set-OpenWebTenantAcl $InputFile ($Operation.StartsWith('Directory')) ($Operation.EndsWith('Public'));return @{}
 }
 if($Operation -eq 'Prepare'){Initialize-OpenWebTenantProof $root $state;return @{prepared=$true}}
 $request=Read-OpenWebTenantInput (Join-Path $private 'certificate-input.json');$pending=Join-Path $private 'pending-certificate.json';$cache=Join-Path $private 'certificate.json'
 if($Operation -eq 'Record'){
  foreach($name in $request.names){$null=Get-OpenWebPublicCertificate $CertificateThumbprint $name}
  Write-OpenWebPublicJson $pending @{thumbprint=$CertificateThumbprint;key_hash=$request.key_hash;names=@($request.names)};Set-OpenWebTenantAcl $pending $false $false;return @{recorded=$true}
 }
 $context=Get-OpenWebPublicContext (Join-Path $env:ProgramData 'OpenWebPBX') $root
 $context.Directory=Join-Path $private 'acme'
 if(!(Test-Path -LiteralPath $context.Directory)){New-Item -ItemType Directory -Path $context.Directory|Out-Null};Set-OpenWebTenantAcl $context.Directory $true $false
 $certificate=$null;$thumb=''
 if(Test-Path -LiteralPath $cache){
  $old=Read-OpenWebPublicJson $cache
  if($old.key_hash -eq $request.key_hash){try{foreach($name in $request.names){$certificate=Get-OpenWebPublicCertificate $old.thumbprint $name};if($certificate.NotAfter.ToUniversalTime() -gt [DateTime]::UtcNow.AddDays(30)){$thumb=$old.thumbprint}}catch{$certificate=$null}}
 }
 if(!$thumb){
  $client=Initialize-OpenWebAcme $context
  foreach($name in $request.names){$null=Get-OpenWebPublicSite $name $root;$null=Set-OpenWebPublicBinding $name 'http' '' $root}
  if(Test-Path -LiteralPath $pending){Remove-Item -LiteralPath $pending -Force -ErrorAction Stop}
  $callback=Join-Path $root 'tools\Tenant-Domains.ps1'
  Invoke-OpenWebAcme $context $client @('--source','manual','--host',($request.names -join ','),'--friendlyname',('OpenWebPBX-tenants-'+$request.key_hash.Substring(0,12)),'--validation','selfhosting','--validationmode','http-01','--store','certificatestore','--certificatestore','My','--keepexisting','--installation','script','--script',$callback,'--scriptparameters',"-Operation Record -CertificateThumbprint '{CertThumbprint}'",'--emailaddress',$request.contact,'--accepttos','--notaskscheduler')
  $fresh=Read-OpenWebPublicJson $pending
  if($fresh.key_hash -ne $request.key_hash -or (@($fresh.names)|ConvertTo-Json -Compress) -ne (@($request.names)|ConvertTo-Json -Compress)){throw 'The certificate result does not match the requested aliases.'};$thumb=$fresh.thumbprint
 }
 foreach($name in $request.names){$certificate=Get-OpenWebPublicCertificate $thumb $name;$null=Get-OpenWebPublicSite $name $root;$null=Set-OpenWebPublicBinding $name 'https' $thumb $root;Test-OpenWebPublicHttps $name $thumb}
 Write-OpenWebPublicJson $cache @{thumbprint=$thumb;key_hash=$request.key_hash;names=@($request.names)};Set-OpenWebTenantAcl $cache $false $false
 return @{not_after=$certificate.NotAfter.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'",[Globalization.CultureInfo]::InvariantCulture)}
}
try{
 if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'Windows is required.'}
 # Machine protocol: capture only the deliberate result; native progress and
 # warning streams cannot become JSON, and errors still fail the operation.
 $result=. {Invoke-OpenWebTenantOperation} 3>$null 4>$null 5>$null 6>$null
 $result|ConvertTo-Json -Compress -Depth 8
}catch{
 $category='certificate_pending';$seconds=3600
 # ACME responses stay private. Export only bounded retry metadata, including
 # the provider's Retry-After where its client retained that header in a log.
 $logs=Join-Path $env:ProgramData 'OpenWebPBX\tenant-domains\private\acme\logs'
 if(Test-Path -LiteralPath $logs){
  try{
   $null=Get-OpenWebTenantAclTarget $logs $true
   $last=Get-ChildItem -LiteralPath $logs -File|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 1
   if($last -and !($last.Attributes -band [IO.FileAttributes]::ReparsePoint)){
    $stream=[IO.File]::OpenRead($last.FullName)
    try{$null=$stream.Seek([Math]::Max(0,$stream.Length-65536),[IO.SeekOrigin]::Begin);$reader=[IO.StreamReader]::new($stream);try{$text=$reader.ReadToEnd()}finally{$reader.Dispose()}}finally{$stream.Dispose()}
    if($text -match '(?i)rate.?limit'){$category='rate_limited'}
    $match=[regex]::Match($text,'(?im)Retry-After\s*[:=]\s*([^\r\n]+)')
    if($match.Success){$number=0;if([int]::TryParse($match.Groups[1].Value.Trim(),[ref]$number)){$seconds=$number}else{$date=[DateTimeOffset]::MinValue;if([DateTimeOffset]::TryParse($match.Groups[1].Value.Trim(),[ref]$date)){$seconds=[int][Math]::Ceiling(($date-[DateTimeOffset]::UtcNow).TotalSeconds)}}}
   }
  }catch{} # Diagnostic metadata must not replace the original failed result.
 }
 $seconds=[Math]::Max(60,[Math]::Min(604800,$seconds))
 [Console]::Error.WriteLine((@{error_category=$category;retry_seconds=$seconds}|ConvertTo-Json -Compress));exit 1
}
