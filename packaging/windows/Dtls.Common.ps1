# SPDX-License-Identifier: AGPL-3.0-or-later
function Assert-OpenWebDtlsOrdinary([string]$Path){
 $item=[IO.Path]::GetFullPath($Path)
 while($item){if(Test-Path -LiteralPath $item){if((Get-Item -LiteralPath $item -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'A DTLS path contains a link; it was preserved.'}};$parent=[IO.Path]::GetDirectoryName($item);if($parent -eq $item){break};$item=$parent}
}
function Get-OpenWebDtlsHash([string]$Path){return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function New-OpenWebDtlsAcl([switch]$Directory,[string]$ServiceSid){
 $acl=if($Directory){[Security.AccessControl.DirectorySecurity]::new()}else{[Security.AccessControl.FileSecurity]::new()}
 $acl.SetAccessRuleProtection($true,$false);$acl.SetOwner([Security.Principal.SecurityIdentifier]'S-1-5-32-544');$acl.SetGroup([Security.Principal.SecurityIdentifier]'S-1-5-32-544')
 foreach($sid in 'S-1-5-18','S-1-5-32-544'){
  $rule=if($Directory){[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]$sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow')}else{[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]$sid,'FullControl','Allow')};$acl.AddAccessRule($rule)
 }
 if($ServiceSid -and $ServiceSid -cne 'S-1-5-18'){$rights=if($Directory){'ReadAndExecute'}else{'Read'};$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]$ServiceSid,$rights,'Allow'))};return $acl
}
function New-OpenWebDtlsCertificateDirectory([string]$Path,[string]$Sddl){
 Assert-OpenWebDtlsOrdinary $Path
 if(-not ('OpenWebPbx.DtlsPrivateDirectory' -as [type])){Add-Type -TypeDefinition @'
using System; using System.ComponentModel; using System.Runtime.InteropServices;
namespace OpenWebPbx { public static class DtlsPrivateDirectory {
 [StructLayout(LayoutKind.Sequential)] struct SecurityAttributes { public int Length; public IntPtr Descriptor; [MarshalAs(UnmanagedType.Bool)] public bool Inherit; }
 [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)] static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(string text,uint revision,out IntPtr descriptor,out uint length);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] [return:MarshalAs(UnmanagedType.Bool)] static extern bool CreateDirectoryW(string path,ref SecurityAttributes attributes);
 [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr pointer);
 public static void Create(string path,string sddl) {
  IntPtr descriptor;uint length;if(!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl,1,out descriptor,out length))throw new Win32Exception(Marshal.GetLastWin32Error());
  try {var attributes=new SecurityAttributes();attributes.Length=Marshal.SizeOf(typeof(SecurityAttributes));attributes.Descriptor=descriptor;if(!CreateDirectoryW(path,ref attributes))throw new Win32Exception(Marshal.GetLastWin32Error());}
  finally {LocalFree(descriptor);}
 }
}}
'@}
 [OpenWebPbx.DtlsPrivateDirectory]::Create($Path,$Sddl)
 if((Get-Acl -LiteralPath $Path).Sddl -cne $Sddl){throw 'The new private DTLS directory permissions did not install exactly.'}
}
function Assert-OpenWebDtlsPrivate([string]$Path,[switch]$AllowInherited){
 Assert-OpenWebDtlsOrdinary $Path;$acl=Get-Acl -LiteralPath $Path
 if((!$AllowInherited -and !$acl.AreAccessRulesProtected) -or $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cnotin 'S-1-5-18','S-1-5-32-544'){throw 'Private DTLS recovery permissions changed.'}
 $seen=@();foreach($entry in @($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))){if($entry.IdentityReference.Value -cnotin 'S-1-5-18','S-1-5-32-544' -or $entry.AccessControlType -ne 'Allow' -or $entry.FileSystemRights -ne 'FullControl'){throw 'Private DTLS recovery has foreign access.'};$seen+=@($entry.IdentityReference.Value)}
 if(($seen|Sort-Object -Unique) -join ',' -cne 'S-1-5-18,S-1-5-32-544'){throw 'Private DTLS recovery access is incomplete.'}
}
function New-OpenWebDtlsPrivate([string]$Path){
 Assert-OpenWebDtlsOrdinary $Path
 if(!(Test-Path -LiteralPath $Path)){[void][IO.Directory]::CreateDirectory($Path);Set-Acl -LiteralPath $Path -AclObject (New-OpenWebDtlsAcl -Directory)}
 Assert-OpenWebDtlsPrivate $Path
}
function Write-OpenWebDtlsNew([string]$Path,[byte[]]$Bytes){
 $stream=[IO.FileStream]::new($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,4096,[IO.FileOptions]::WriteThrough)
 # A new empty file may inherit read permissions; protect it before writing any
 # private bytes, including same-directory certificate replacement files.
 try{Set-Acl -LiteralPath $Path -AclObject (New-OpenWebDtlsAcl);$stream.Write($Bytes,0,$Bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
}
function Move-OpenWebDtlsFile([string]$Source,[string]$Target){
 if(-not ('OpenWebPbx.DtlsAtomicFile' -as [type])){Add-Type -TypeDefinition @'
using System; using System.ComponentModel; using System.Runtime.InteropServices;
namespace OpenWebPbx { public static class DtlsAtomicFile {
 [DllImport("kernel32.dll", CharSet=CharSet.Unicode, ExactSpelling=true, SetLastError=true)]
 [return:MarshalAs(UnmanagedType.Bool)] static extern bool MoveFileExW(string source,string target,uint flags);
 public static void Replace(string source,string target) { if(!MoveFileExW(source,target,9))throw new Win32Exception(Marshal.GetLastWin32Error()); }
}}
'@};[OpenWebPbx.DtlsAtomicFile]::Replace($Source,$Target)
}
function Set-OpenWebDtlsCertificate([string]$Path,[byte[]]$Bytes,[string]$Sddl){
 Assert-OpenWebDtlsOrdinary $Path;$temporary=$Path+'.'+[Guid]::NewGuid().ToString('N')+'.new'
 try{Write-OpenWebDtlsNew $temporary $Bytes;Set-OpenWebFileSddl -LiteralPath $temporary -Sddl $Sddl;Move-OpenWebDtlsFile $temporary $Path;if((Get-Acl -LiteralPath $Path).Sddl -cne $Sddl){throw 'The DTLS certificate permissions did not install exactly.'}}
 finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}}
}
function Write-OpenWebDtlsJournal([string]$Path,$Value){
 $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 12))
 Set-OpenWebDtlsCertificate $Path $bytes (New-OpenWebDtlsAcl).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)
}
function Get-OpenWebDtlsService {
 $service=Get-CimInstance Win32_Service -Filter "Name='FreeSWITCH'"
 if(!$service -or $service.State -cne 'Stopped' -or $service.StartMode -cnotin 'Auto','Manual','Disabled'){throw 'Stop the calling engine under maintenance before preparing DTLS.'}
 if($service.PathName -notmatch '^"C:\\Program Files\\FreeSWITCH\\(?:FreeSwitchConsole|FreeSWITCH)\.exe"(?:\s+-service\s*)?$'){throw 'The stopped calling service is outside the owned Windows engine installation.'}
 $account=if($service.StartName -in 'LocalSystem','NT AUTHORITY\SYSTEM'){'S-1-5-18'}else{([Security.Principal.NTAccount]$service.StartName).Translate([Security.Principal.SecurityIdentifier]).Value}
 return [ordered]@{account=[string]$service.StartName;sid=$account;path=[string]$service.PathName;start_mode=[string]$service.StartMode}
}
function Assert-OpenWebDtlsService($Expected){
 $now=Get-OpenWebDtlsService;foreach($field in 'account','sid','path','start_mode'){if($Expected.$field -isnot [string] -or $Expected.$field -cne $now.$field){throw 'The stopped calling-engine identity changed; DTLS recovery refused.'}}
}
function Read-OpenWebDtlsJournal([string]$Directory,[string]$Certificate){
 Assert-OpenWebDtlsPrivate $Directory;$file=Join-Path $Directory 'journal.json';Assert-OpenWebDtlsPrivate $file
 if((Get-Item -LiteralPath $file).Length -gt 16384){throw 'The DTLS recovery journal is too large.'};$j=Get-Content -LiteralPath $file -Raw|ConvertFrom-Json
 if($j.schema -isnot [int] -or $j.schema -ne 1 -or $j.kind -cne 'openwebpbx-dtls' -or $j.transaction -cnotmatch '^[a-f0-9]{32}$' -or $j.transaction -cne [IO.Path]::GetFileName($Directory) -or $j.computer -cne [Environment]::MachineName -or $j.certificate -cne $Certificate -or $j.state -cnotin 'prepared','applying','committed','recovering','recovered','recovery_required' -or $j.before_exists -isnot [bool] -or $j.desired_sha256 -cnotmatch '^[a-f0-9]{64}$' -or !$j.desired_sddl){throw 'The machine-bound DTLS journal requires administrator review.'}
 if($j.service.sid -isnot [string] -or $j.service.sid -cnotmatch '^S-1-[0-9-]+$' -or $j.desired_sddl -cne (New-OpenWebDtlsAcl -ServiceSid $j.service.sid).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)){throw 'The desired private DTLS permissions are not deterministic.'}
 if($j.parent_path -cne [IO.Path]::GetDirectoryName($Certificate) -or $j.parent_before_exists -isnot [bool] -or $j.parent_create_intent -isnot [bool] -or $j.parent_create_intent -eq $j.parent_before_exists -or $j.parent_created -isnot [bool] -or ($j.before_exists -and !$j.parent_before_exists) -or ($j.parent_before_exists -and !$j.parent_before_sddl) -or $j.parent_desired_sddl -cne (New-OpenWebDtlsAcl -Directory -ServiceSid $j.service.sid).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)){throw 'The DTLS parent directory recovery identity is invalid.'}
 $desired=Join-Path $Directory 'desired.pem';Assert-OpenWebDtlsPrivate $desired
 if((Get-Item -LiteralPath $desired).Length -gt 65536 -or (Get-OpenWebDtlsHash $desired) -cne $j.desired_sha256){throw 'The durable desired DTLS identity changed.'}
 if($j.before_exists){$before=Join-Path $Directory 'before.pem';Assert-OpenWebDtlsPrivate $before;if($j.before_sha256 -cnotmatch '^[a-f0-9]{64}$' -or !$j.before_sddl -or (Get-Item -LiteralPath $before).Length -gt 65536 -or (Get-OpenWebDtlsHash $before) -cne $j.before_sha256){throw 'The durable original DTLS identity changed.'}}
 return $j
}
function Undo-OpenWebDtls([string]$Directory,[string]$Certificate){
 $j=Read-OpenWebDtlsJournal $Directory $Certificate;Assert-OpenWebDtlsService $j.service
 Assert-OpenWebDtlsOrdinary $Certificate
 $parent=$j.parent_path
 if($j.parent_before_exists){if(!(Test-Path -LiteralPath $parent -PathType Container) -or (Get-Acl -LiteralPath $parent).Sddl -cne $j.parent_before_sddl){throw 'The original DTLS parent directory changed; it was preserved.'}}
 elseif(Test-Path -LiteralPath $parent){
  if(!(Test-Path -LiteralPath $parent -PathType Container) -or (Get-Acl -LiteralPath $parent).Sddl -cne $j.parent_desired_sddl){throw 'A foreign DTLS parent directory was preserved.'}
  foreach($child in @(Get-ChildItem -LiteralPath $parent -Force)){if($child.PSIsContainer -or $child.FullName -cne $Certificate){throw 'The new DTLS parent contains unrelated material; recovery refused.'}}
 }
 if(Test-Path -LiteralPath $Certificate){$hash=Get-OpenWebDtlsHash $Certificate;$sddl=(Get-Acl -LiteralPath $Certificate).Sddl;if($hash -cne $j.desired_sha256 -and (!$j.before_exists -or $hash -cne $j.before_sha256)){throw 'A foreign DTLS certificate was preserved.'};if($sddl -cne $j.desired_sddl -and (!$j.before_exists -or $sddl -cne $j.before_sddl)){throw 'Foreign DTLS certificate permissions were preserved.'}}
 elseif($j.before_exists){throw 'The original DTLS certificate disappeared outside this transaction.'}
 $j.state='recovering';Write-OpenWebDtlsJournal (Join-Path $Directory 'journal.json') $j
 if($j.before_exists){
  Set-OpenWebDtlsCertificate $Certificate ([IO.File]::ReadAllBytes((Join-Path $Directory 'before.pem'))) $j.before_sddl
  if((Get-OpenWebDtlsHash $Certificate) -cne $j.before_sha256 -or (Get-Acl -LiteralPath $Certificate).Sddl -cne $j.before_sddl){throw 'The original DTLS identity did not recover exactly.'}
 }else{
  if(Test-Path -LiteralPath $Certificate){Remove-Item -LiteralPath $Certificate -Force -ErrorAction Stop}
  if(Test-Path -LiteralPath $Certificate){throw 'The original absence of a DTLS identity did not recover exactly.'}
 }
 if(!$j.parent_before_exists){if(Test-Path -LiteralPath $parent){[IO.Directory]::Delete($parent,$false)};if(Test-Path -LiteralPath $parent){throw 'The original DTLS parent absence did not recover exactly.'}}
 $j.state='recovered';Write-OpenWebDtlsJournal (Join-Path $Directory 'journal.json') $j
}
function Assert-OpenWebDtlsStaging([string]$Directory){
 Assert-OpenWebDtlsPrivate $Directory
 $items=@(Get-ChildItem -LiteralPath $Directory -Force)
 if($items.Count -gt 12){throw 'The interrupted private DTLS staging inventory is unknown.'}
 foreach($item in $items){
  if($item.PSIsContainer -or $item.Name -cnotmatch '^(?:before\.pem|desired\.pem|generation\.cnf|journal\.json(?:\.[a-f0-9]{32}\.new)?)$' -or $item.Length -gt 65536){throw 'Foreign DTLS staging material was preserved.'}
  Assert-OpenWebDtlsOrdinary $item.FullName
  # A crash before the initial file ACL is set can leave only an empty file.
  # Nonempty key/config/journal material must retain admin/SYSTEM-only access.
  if($item.Length){Assert-OpenWebDtlsPrivate $item.FullName -AllowInherited}
 }
}

function Install-OpenWebDtls {
 param([string]$PackageRoot,[string]$Root,[string]$State,[string]$Certificate,[switch]$Recover)
$service=Get-OpenWebDtlsService;$parent=[IO.Path]::GetDirectoryName($Certificate);Assert-OpenWebDtlsOrdinary $parent
if(!(Test-Path -LiteralPath ([IO.Path]::GetDirectoryName($parent)) -PathType Container) -or ((Test-Path -LiteralPath $parent) -and !(Test-Path -LiteralPath $parent -PathType Container))){throw 'The owned engine parent must exist and the DTLS parent must be an ordinary directory or absent.'}
$directory=Join-Path $state 'dtls-setup';New-OpenWebDtlsPrivate $directory
$pending=@();$staging=@();foreach($item in @(Get-ChildItem -LiteralPath $directory -Force)){
 if($item.PSIsContainer -and $item.Name -cmatch '^(staging|abandoned)-[a-f0-9]{32}$'){
  Assert-OpenWebDtlsStaging $item.FullName
  if($item.Name.StartsWith('staging-')){$staging+=@($item.FullName)}
  continue
 }
 if(!$item.PSIsContainer -or $item.Name -cnotmatch '^[a-f0-9]{32}$'){throw 'The private DTLS transaction inventory contains an unknown entry.'}
 $journal=Read-OpenWebDtlsJournal $item.FullName $certificate;if($journal.state -cnotin 'committed','recovered'){$pending+=@($item.FullName)}
}
if($Recover){foreach($transaction in $pending){Undo-OpenWebDtls $transaction $certificate};foreach($unpromoted in $staging){Move-OpenWebDtlsFile $unpromoted (Join-Path $directory ('abandoned-'+[IO.Path]::GetFileName($unpromoted).Substring(8)))};Write-Host 'Private DTLS recovery completed; incomplete staging evidence was retained and the calling engine remains stopped.';return}
if($pending.Count -or $staging.Count){throw 'An interrupted private DTLS setup requires Install-Dtls.ps1 -Recover under the maintenance lock.'}
function Inspect([string]$Path){
 $output=& "$root\php\php.exe" -d display_errors=0 (Join-Path $PackageRoot 'configure-dtls.php') inspect $Path
 if($LASTEXITCODE -ne 0){throw 'The private DTLS certificate could not be inspected.'};$row=$output|ConvertFrom-Json
 if($row.schema -ne 1 -or $row.state -cnotin 'missing','valid','stock_overflow','foreign_invalid'){throw 'The DTLS inspection result is invalid.'};return $row.state
}
$status=Inspect $certificate
if($status -ceq 'valid'){Write-Host 'The current private DTLS certificate is valid and was preserved.';return}
if($status -cnotin 'missing','stock_overflow'){throw 'A custom or unrecognised invalid DTLS certificate was preserved; administrator review is required.'}
$identity=[Guid]::NewGuid().ToString('N');$transaction=Join-Path $directory ('staging-'+$identity);New-OpenWebDtlsPrivate $transaction
$desired=Join-Path $transaction 'desired.pem';$configuration=Join-Path $transaction 'generation.cnf'
Write-OpenWebDtlsNew $configuration ([Text.UTF8Encoding]::new($false).GetBytes("[req]`ndistinguished_name=dn`n[dn]`n"))
$null=& "$root\php\php.exe" -d display_errors=0 (Join-Path $PackageRoot 'configure-dtls.php') generate $desired $configuration
if($LASTEXITCODE -ne 0 -or (Inspect $desired) -cne 'valid'){throw 'A valid private DTLS certificate could not be staged.'}
Set-Acl -LiteralPath $desired -AclObject (New-OpenWebDtlsAcl)
$exists=Test-Path -LiteralPath $certificate
$parentExists=Test-Path -LiteralPath $parent -PathType Container
$journal=[ordered]@{schema=1;kind='openwebpbx-dtls';transaction=$identity;computer=[Environment]::MachineName;certificate=$certificate;state='prepared';service=$service;before_exists=[bool]$exists;before_sha256=$null;before_sddl=$null;desired_sha256=(Get-OpenWebDtlsHash $desired);desired_sddl=(New-OpenWebDtlsAcl -ServiceSid $service.sid).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All);parent_path=$parent;parent_before_exists=[bool]$parentExists;parent_before_sddl=$(if($parentExists){(Get-Acl -LiteralPath $parent).Sddl}else{$null});parent_desired_sddl=(New-OpenWebDtlsAcl -Directory -ServiceSid $service.sid).GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All);parent_create_intent=(!$parentExists);parent_created=$false}
if($exists){$journal.before_sha256=Get-OpenWebDtlsHash $certificate;$journal.before_sddl=(Get-Acl -LiteralPath $certificate).Sddl;Write-OpenWebDtlsNew (Join-Path $transaction 'before.pem') ([IO.File]::ReadAllBytes($certificate))}
Write-OpenWebDtlsJournal (Join-Path $transaction 'journal.json') $journal
$promoted=Join-Path $directory $identity;Move-OpenWebDtlsFile $transaction $promoted;$transaction=$promoted;$desired=Join-Path $transaction 'desired.pem'
try{
 Assert-OpenWebDtlsService $service
 if($journal.parent_before_exists){if(!(Test-Path -LiteralPath $parent -PathType Container) -or (Get-Acl -LiteralPath $parent).Sddl -cne $journal.parent_before_sddl){throw 'The original DTLS parent changed before installation.'}}
 elseif(Test-Path -LiteralPath $parent){throw 'A foreign DTLS parent appeared before installation.'}
 if((Test-Path -LiteralPath $certificate) -ne $exists -or ($exists -and ((Get-OpenWebDtlsHash $certificate) -cne $journal.before_sha256 -or (Get-Acl -LiteralPath $certificate).Sddl -cne $journal.before_sddl))){throw 'The existing DTLS identity changed before installation.'}
 $journal.state='applying';Write-OpenWebDtlsJournal (Join-Path $transaction 'journal.json') $journal
 if(!$journal.parent_before_exists){New-OpenWebDtlsCertificateDirectory $parent $journal.parent_desired_sddl;$journal.parent_created=$true;Write-OpenWebDtlsJournal (Join-Path $transaction 'journal.json') $journal}
 Set-OpenWebDtlsCertificate $certificate ([IO.File]::ReadAllBytes($desired)) $journal.desired_sddl
 if((Inspect $certificate) -cne 'valid' -or (Get-OpenWebDtlsHash $certificate) -cne $journal.desired_sha256){throw 'The installed DTLS certificate did not validate.'}
 Assert-OpenWebDtlsService $service
 $journal.state='committed';Write-OpenWebDtlsJournal (Join-Path $transaction 'journal.json') $journal
 Write-Host 'A valid private DTLS identity is ready; the calling engine remains stopped.'
}catch{
 $failure=$_;try{Undo-OpenWebDtls $transaction $certificate}catch{$journal.state='recovery_required';Write-OpenWebDtlsJournal (Join-Path $transaction 'journal.json') $journal;throw 'Private DTLS recovery requires administrator review; the calling engine remains stopped.'};throw $failure
}

}
