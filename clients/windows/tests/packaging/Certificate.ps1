# SPDX-License-Identifier: AGPL-3.0-or-later
#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Create','Remove')][string]$Mode,[Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$Nonce,[Parameter(Mandatory)][string]$Root)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Diagnostics.ps1')
. (Join-Path $PSScriptRoot 'NativeSecurity.ps1')
$certificateStage='entry'
trap { $certificatePrimary=$_;try{[Console]::Error.WriteLine(('OPENWEBPBX_PACKAGE_CERTIFICATE_OBSERVATION '+((GetPackageCertificateFailure $certificatePrimary $Mode $certificateStage)|ConvertTo-Json -Depth 3 -Compress)))}catch{};throw $certificatePrimary }
if($PSVersionTable.PSEdition -cne 'Desktop' -or $env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows' -or $env:GITHUB_REPOSITORY -cne 'embire2/openwebpbx'){throw 'Only the disposable native Windows certificate fixture is allowed.'}
$principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent());if(!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'The disposable certificate fixture requires the hosted administrator.'}
$expected=Join-Path ([IO.Path]::GetFullPath($env:RUNNER_TEMP)) ('phone-package-'+$Nonce);$certificateStage='root';$Root=[IO.Path]::GetFullPath($Root)
if($Root -ine $expected -or !(Test-Path -LiteralPath $Root -PathType Container)){throw 'The owned private root differs.'}
$parent=[IO.DirectoryInfo]::new($Root);while($parent){if($parent.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'The fixture root is linked.'};$parent=$parent.Parent}
$certificateStage='native_module';$nativeSecurity=GetPackageNativeSecurityCommand
$certificateStage='acl';$acl=& $nativeSecurity.Command -LiteralPath $Root;$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;$rules=@($acl.Access)
if(!$acl.AreAccessRulesProtected -or $rules.Count-ne 2){throw 'The certificate fixture root must be protected.'}
foreach($rule in $rules){$who=$rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value;if($who -notin @($sid,'S-1-5-18') -or $rule.AccessControlType-ne 'Allow' -or ($rule.FileSystemRights-band [Security.AccessControl.FileSystemRights]::FullControl)-ne [Security.AccessControl.FileSystemRights]::FullControl){throw 'The certificate fixture ACL differs.'}}
$subject='CN=FreePhone Development '+$Nonce;$container='OpenWebPBX-FreePhone-Development-'+$Nonce
$provider=[Security.Cryptography.CngProvider]::MicrosoftSoftwareKeyStorageProvider
function AssertOwnedKey($Key,[string]$Container){
 if($null-eq $Key -or $Key.IsMachineKey-isnot [bool] -or $Key.IsMachineKey -or $Key.KeyName-isnot [string] -or $Key.KeyName-cne $Container -or $Key.Provider.Provider-isnot [string] -or $Key.Provider.Provider-cne 'Microsoft Software Key Storage Provider' -or $Key.ExportPolicy-isnot [Security.Cryptography.CngExportPolicies] -or $Key.ExportPolicy-ne [Security.Cryptography.CngExportPolicies]::None){throw 'The private key scope, provider, ownership or export policy is foreign.'}
}
function CertificateSha($Certificate){$sha=[Security.Cryptography.SHA256]::Create();try{[BitConverter]::ToString($sha.ComputeHash($Certificate.RawData)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}}
function ReadCertificateReceipt([string]$Path){
 $item=Get-Item -LiteralPath $Path -Force;if($item.PSIsContainer -or ($item.Attributes-band [IO.FileAttributes]::ReparsePoint) -or $item.Length-lt 64 -or $item.Length-gt 2048){throw 'An ordinary bounded certificate receipt is required.'}
 $receipt=Get-Content -LiteralPath $Path -Raw|ConvertFrom-Json
 if($receipt.schema-ne 1 -or $receipt.thumbprint-isnot [string] -or $receipt.thumbprint-cnotmatch '^[A-Fa-f0-9]{40}$' -or $receipt.subject-cne $subject -or $receipt.container-cne $container -or $receipt.public_sha256-isnot [string] -or $receipt.public_sha256-cnotmatch '^[a-f0-9]{64}$'){throw 'The certificate receipt identity differs.'};$receipt
}
$certificateStage='stores';$my=[Security.Cryptography.X509Certificates.X509Store]::new('My','CurrentUser');$people=[Security.Cryptography.X509Certificates.X509Store]::new('TrustedPeople','LocalMachine');$my.Open('ReadWrite');$people.Open('ReadWrite')
try{
 $mine=@($my.Certificates|Where-Object Subject -CEQ $subject);$trusted=@($people.Certificates|Where-Object Subject -CEQ $subject)
 if($Mode -ceq 'Create'){
  $certificateStage='create_preflight';if($mine.Count -or $trusted.Count -or [Security.Cryptography.CngKey]::Exists($container,$provider) -or (Test-Path -LiteralPath (Join-Path $Root 'certificate.json'))){throw 'The development certificate or private container already exists.'}
  $certificateStage='create_intent';$intent=Join-Path $Root 'certificate-intent.json';if(Test-Path -LiteralPath $intent){throw 'Certificate intent already exists.'}
  $bytes=[Text.Encoding]::UTF8.GetBytes((@{schema=2;nonce=$Nonce;subject=$subject;container=$container;private_location='CurrentUser';private_store='My';trust_location='LocalMachine';trust_store='TrustedPeople'}|ConvertTo-Json -Compress));$file=[IO.File]::Open($intent,'CreateNew','Write','None');try{$file.Write($bytes,0,$bytes.Length);$file.Flush($true)}finally{$file.Dispose()}
  $certificateStage='native_module';$module=Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\Modules\PKI';if(!(Test-Path -LiteralPath $module -PathType Container)){throw 'The native PKI module is absent.'};Import-Module -Name $module -Force -ErrorAction Stop
  $command=Get-Command New-SelfSignedCertificate -CommandType Cmdlet -ErrorAction Stop
  if($command.Module.ModuleBase -ine $module -and !$command.Module.ModuleBase.StartsWith($module+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'The native certificate command provenance differs.'}
  $certificateStage='create_certificate';$cert=& $command -Type Custom -Subject $subject -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA256 -KeyUsage DigitalSignature -KeyExportPolicy NonExportable -Container $container -Provider $provider.Provider -CertStoreLocation 'Cert:\CurrentUser\My' -NotBefore ([DateTime]::UtcNow.AddMinutes(-10)) -NotAfter ([DateTime]::UtcNow.AddDays(1)) -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3','2.5.29.19={text}')
  $certificateStage='verify_created';if($cert.Subject -cne $subject -or !$cert.HasPrivateKey){throw 'The generated development certificate differs.'}
  $createdKey=[Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert);try{if($createdKey-isnot [Security.Cryptography.RSACng]){throw 'The generated key is not CNG.'};AssertOwnedKey $createdKey.Key $container}finally{if($createdKey){$createdKey.Dispose()}}
  $certificateStage='write_receipt';$bytes=[Text.Encoding]::UTF8.GetBytes((@{schema=1;thumbprint=$cert.Thumbprint;subject=$subject;container=$container;public_sha256=(CertificateSha $cert)}|ConvertTo-Json -Compress));$file=[IO.File]::Open((Join-Path $Root 'certificate.json'),'CreateNew','Write','None');try{$file.Write($bytes,0,$bytes.Length);$file.Flush($true)}finally{$file.Dispose()}
  $certificateStage='add_trust';$public=[Security.Cryptography.X509Certificates.X509Certificate2]::new($cert.RawData);try{if($public.HasPrivateKey -or (CertificateSha $public)-cne (CertificateSha $cert)){throw 'The public trust certificate does not match the owned private certificate.'};$people.Add($public)}finally{$public.Dispose()}
 }else{
  $certificateStage='read_intent';$intent=Join-Path $Root 'certificate-intent.json';if(!(Test-Path -LiteralPath $intent -PathType Leaf)){if($mine.Count -or $trusted.Count -or [Security.Cryptography.CngKey]::Exists($container,$provider)){throw 'Foreign development identity lacks ownership intent.'};GetPackageCertificateRemoval $mine.Count $trusted.Count ([Security.Cryptography.CngKey]::Exists($container,$provider))|ConvertTo-Json -Compress;return}
  if((Get-Item -LiteralPath $intent).Length-gt 2048 -or ((Get-Item -LiteralPath $intent).Attributes-band [IO.FileAttributes]::ReparsePoint)){throw 'The certificate intent is unavailable.'};$proof=Get-Content -LiteralPath $intent -Raw|ConvertFrom-Json
  if($proof.schema-ne 2 -or $proof.nonce-cne $Nonce -or $proof.subject-cne $subject -or $proof.container-cne $container -or $proof.private_location-cne 'CurrentUser' -or $proof.private_store-cne 'My' -or $proof.trust_location-cne 'LocalMachine' -or $proof.trust_store-cne 'TrustedPeople' -or $mine.Count-gt 1 -or $trusted.Count-gt 1){throw 'The development certificate ownership differs.'}
  $certificateStage='read_receipt';$receiptPath=Join-Path $Root 'certificate.json';$receipt=$null;if(Test-Path -LiteralPath $receiptPath){$receipt=ReadCertificateReceipt $receiptPath};if($mine.Count -and !$receipt){throw 'The private certificate has no binding receipt; preserve it for review.'}
  $certificateStage='verify_bindings';foreach($cert in $mine){if($cert.Thumbprint-cne $receipt.thumbprint -or $cert.Subject-cne $receipt.subject -or (CertificateSha $cert)-cne $receipt.public_sha256){throw 'The private certificate binding differs.'}}
  if($trusted.Count -and (!$mine.Count -or $trusted[0].Thumbprint -cne $mine[0].Thumbprint -or $trusted[0].HasPrivateKey -or (CertificateSha $trusted[0])-cne $receipt.public_sha256)){throw 'The public trust certificate does not match the owned private certificate.'}
  $keys=@();try{
   $certificateStage='verify_keys';foreach($cert in $mine){$key=[Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert);if($key -isnot [Security.Cryptography.RSACng] -or $key.Key.KeyName-cne $container){if($key){$key.Dispose()};throw 'The private key is foreign.'};try{AssertOwnedKey $key.Key $container}catch{$key.Dispose();throw};$keys+=,$key}
   $certificateStage='remove_trust';foreach($cert in $trusted){$people.Remove($cert)}
   $certificateStage='remove_private';for($i=0;$i -lt $mine.Count;$i++){$my.Remove($mine[$i]);$keys[$i].Key.Delete()}
  }finally{foreach($key in $keys){$key.Dispose()}}
  $certificateStage='remove_orphan';if(!$mine.Count -and [Security.Cryptography.CngKey]::Exists($container,$provider)){$key=[Security.Cryptography.CngKey]::Open($container,$provider);try{AssertOwnedKey $key $container;$key.Delete()}finally{$key.Dispose()}}
  $certificateStage='verify_removed';$my.Close();$people.Close();$my.Open('ReadOnly');$people.Open('ReadOnly')
  if(@($my.Certificates|Where-Object Subject -CEQ $subject).Count -or @($people.Certificates|Where-Object Subject -CEQ $subject).Count -or [Security.Cryptography.CngKey]::Exists($container,$provider)){throw 'Owned certificate cleanup is incomplete.'}
  GetPackageCertificateRemoval @($my.Certificates|Where-Object Subject -CEQ $subject).Count @($people.Certificates|Where-Object Subject -CEQ $subject).Count ([Security.Cryptography.CngKey]::Exists($container,$provider))|ConvertTo-Json -Compress
 }
}finally{$my.Dispose();$people.Dispose()}
