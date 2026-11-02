# QA-only admission of first empty tenant-worker initialization. Original maps
# and every original file/SDDL comparison remain unchanged.
function Get-WindowsEmptyTenantPaths {
 return [ordered]@{
  'C:\ProgramData\OpenWebPBX\tenant-domains'='public_directory'
  'C:\ProgramData\OpenWebPBX\tenant-domains\private'='private_directory'
  'C:\ProgramData\OpenWebPBX\tenant-domains\proofs'='inherited_public_directory'
  'C:\ProgramData\OpenWebPBX\tenant-domains\proofs\.well-known'='inherited_public_directory'
  'C:\ProgramData\OpenWebPBX\tenant-domains\proofs\.well-known\openwebpbx-instance'='public_directory'
  'C:\ProgramData\fusionpbx\tenant-domains-instance-key.pem'='private_file'
  'C:\ProgramData\OpenWebPBX\tenant-domains\ready.json'='public_file'
  'C:\ProgramData\OpenWebPBX\tenant-domains\proofs\.well-known\openwebpbx-instance\web.config'='public_file'
 }
}
function Get-WindowsEmptyTenantAclRecipe([string]$PackageRoot,[bool]$Directory,[bool]$Public){
 $path=Join-Path $PackageRoot 'Tenant-Domains.ps1'
 $raw=[IO.File]::ReadAllText($path)
 if((Hash $path)-cne '86cd2d18660dc03e0d7097551ab6ab5a413cb541194d4dc1f97d90b6c4080ad3'){throw 'The source-owned tenant ACL recipe differs.'}
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($raw,[ref]$tokens,[ref]$errors)
 $function=@($ast.FindAll({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-ceq 'Set-OpenWebTenantAcl'},$true))
 if($errors.Count -or $function.Count-ne 1){throw 'One exact source ACL function is required.'}
 $body=$function[0].Extent.Text;$start=$body.IndexOf(' $acl=if($Directory)');$end=$body.IndexOf(' Set-Acl -LiteralPath $Path -AclObject $acl')
 if($start-lt 0 -or $end-le $start){throw 'The source ACL construction boundary differs.'}
 # Execute only the exact source descriptor construction, never its Set-Acl or
 # target-path helper. No filesystem permissions are changed by qualification.
 $code=$body.Substring($start,$end-$start)+"`nreturn `$acl"
 return & ([scriptblock]::Create($code))
}
function Test-WindowsEmptyTenantAcl([string]$Sddl,[string]$Kind,[string]$PackageRoot){
 try{
  if([string]::IsNullOrWhiteSpace($Sddl) -or $Sddl.Length-gt 131072 -or $Sddl.IndexOf([char]0)-ge 0 -or $Kind-cnotin 'public_directory','private_directory','inherited_public_directory','public_file','private_file'){return $false}
  $directory=$Kind.EndsWith('directory');$public=$Kind-cne 'private_directory' -and $Kind-cne 'private_file';$inherited=$Kind-ceq 'inherited_public_directory'
  $recipe=Get-WindowsEmptyTenantAclRecipe $PackageRoot $directory $public
  $expected=[Security.AccessControl.RawSecurityDescriptor]::new($recipe.Sddl);$actual=[Security.AccessControl.RawSecurityDescriptor]::new($Sddl)
  if(!$actual.Owner -or !$actual.Group -or $actual.SystemAcl -or $actual.ResourceManagerControl-ne 0 -or !$actual.DiscretionaryAcl -or $actual.DiscretionaryAcl.Revision-ne 2){return $false}
  # The source sets BA ownership on protected entries. Intermediate mkdir
  # parents retain a privileged creator owner. Group is valid SID metadata;
  # the source never sets it and these exact ACEs never grant via Group/CG.
  $owner=$actual.Owner.Value
  if((!$inherited -and $owner-cne 'S-1-5-32-544') -or ($inherited -and $owner-cnotin 'S-1-5-18','S-1-5-32-544')){return $false}
  $null=[Security.Principal.SecurityIdentifier]::new($actual.Group.Value)
  $allowed=[Security.AccessControl.ControlFlags]::SelfRelative-bor [Security.AccessControl.ControlFlags]::DiscretionaryAclPresent-bor [Security.AccessControl.ControlFlags]::DiscretionaryAclProtected-bor [Security.AccessControl.ControlFlags]::DiscretionaryAclAutoInherited
  if(([int]$actual.ControlFlags-band (-bnot [int]$allowed))-ne 0 -or !($actual.ControlFlags-band [Security.AccessControl.ControlFlags]::DiscretionaryAclPresent)){return $false}
  if([bool]($actual.ControlFlags-band [Security.AccessControl.ControlFlags]::DiscretionaryAclProtected)-eq $inherited){return $false}
  if($actual.DiscretionaryAcl.Count-ne $expected.DiscretionaryAcl.Count){return $false}
  $want=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach($ace in $expected.DiscretionaryAcl){
   $flags=$ace.AceFlags;if($inherited){$flags=[Security.AccessControl.AceFlags]([int]$flags-bor [int][Security.AccessControl.AceFlags]::Inherited)}
   $copy=[Security.AccessControl.CommonAce]::new($flags,$ace.AceQualifier,$ace.AccessMask,$ace.SecurityIdentifier,$false,$null)
   $bytes=[byte[]]::new($copy.BinaryLength);$copy.GetBinaryForm($bytes,0);if(!$want.Add([Convert]::ToBase64String($bytes))){return $false}
  }
  foreach($ace in $actual.DiscretionaryAcl){
   if($ace-isnot [Security.AccessControl.CommonAce] -or $ace.IsCallback -or $ace.AceQualifier-ne [Security.AccessControl.AceQualifier]::AccessAllowed -or $ace.SecurityIdentifier.Value-cnotin 'S-1-5-18','S-1-5-32-544','S-1-5-32-568','S-1-5-17','S-1-5-19'){return $false}
   $bytes=[byte[]]::new($ace.BinaryLength);$ace.GetBinaryForm($bytes,0);if(!$want.Remove([Convert]::ToBase64String($bytes))){return $false}
  }
  return $want.Count-eq 0
 }catch{return $false}
}
function Get-WindowsEmptyTenantComparisonCopy($Before,$After,[string]$PackageRoot,[string]$ExpectedHost,[string]$ContentProofPath){
 if($Before-isnot [Collections.IDictionary] -or $After-isnot [Collections.IDictionary]){throw 'The original private maps are required.'}
 $expected=Get-WindowsEmptyTenantPaths;$added=@($After.Keys|Where-Object {!$Before.Contains($_)})
 if(!$added.Count){return $After}
 if($added.Count-ne 8){throw 'Only the complete eight-entry source initialization is modeled.'}
 foreach($path in $expected.Keys){if($Before.Contains($path) -or $added-cnotcontains $path){throw 'The exact eight paths must all be absent before and present after.'}}
 foreach($path in $added){if($path-cnotin @($expected.Keys)){throw 'An unknown private entry was added.'}}
 # Shape and source ACL contracts apply only to new entries. The unchanged
 # original Equal call still owns every original path, byte and full SDDL.
 $records=@{}
 foreach($path in $expected.Keys){
  $row=$After[$path];$directory=$expected[$path].EndsWith('directory');$keys=if($directory){@('directory','acl')}else{@('directory','acl','sha256','bytes')}
  if(!(Test-WindowsUpdaterAclKeys $row $keys) -or $row.directory-isnot [bool] -or $row.directory-ne $directory -or $row.acl-isnot [string] -or !(Test-WindowsEmptyTenantAcl $row.acl $expected[$path] $PackageRoot)){throw 'New source-owned private metadata or ACL differs.'}
  if(!$directory){if($row.sha256-isnot [string] -or $row.sha256-cnotmatch '^[a-f0-9]{64}$' -or ($row.bytes-isnot [int] -and $row.bytes-isnot [long]) -or $row.bytes-lt 1 -or $row.bytes-gt 4096){throw 'New bounded file metadata differs.'};$records[$path]=@{sha256=$row.sha256;bytes=$row.bytes}}
 }
 if(Test-Path -LiteralPath 'C:\ProgramData\OpenWebPBX-Installation\onboarding-required'){throw 'Legacy required-marker policy changed.'}
 $context=Join-Path (Split-Path $ContentProofPath -Parent) 'empty-tenant-content-context.private.json'
 if(Test-Path -LiteralPath $context){throw 'The one-use content proof context is occupied.'}
 WriteJson $context @{expected_host=$ExpectedHost;files=$records;package_root=$PackageRoot}
 Python @((Join-Path $PSScriptRoot 'windows_empty_tenant_private_files.py'),$context,$ContentProofPath)
 $proof=Get-Content -LiteralPath $ContentProofPath -Raw|ConvertFrom-Json
 if($proof.schema-ne 1 -or $proof.state-cne 'passed' -or $proof.original_policy_required-isnot [bool] -or $proof.original_policy_required -or $proof.p256_ready_binding-isnot [bool] -or !$proof.p256_ready_binding -or $proof.exact_source_proof-isnot [bool] -or !$proof.exact_source_proof){throw 'The actual source-owned content and policy proof did not pass.'}
 $copy=@{};foreach($path in $After.Keys){if($path-cnotin @($expected.Keys)){$copy[$path]=$After[$path]}}
 return $copy
}
