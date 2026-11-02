# QA-only public21 empty-worker ACL transition. Never changes permissions/files.
function Get-WindowsSignedTenantAclRecipe([string]$PackageRoot,[bool]$Directory,[bool]$Original){
 if(!$Original){return Get-WindowsEmptyTenantAclRecipe $PackageRoot $Directory $true}
 $path=Join-Path $PackageRoot 'Tenant-Domains.ps1'
 if((Hash $path)-cne '8c81d14f787aa8fa78e28fcf3b1b3a36f3e1d234a8d9920466cbe25c77481428'){throw 'The immutable public21 ACL source differs.'}
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
 $nodes=@($ast.FindAll({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-ceq 'Set-OpenWebTenantAcl'},$true))
 if($errors.Count -or $nodes.Count-ne 1){throw 'The original ACL construction is unavailable.'}
 $body=$nodes[0].Extent.Text;$start=$body.IndexOf(' $acl=if($Directory)');$end=$body.IndexOf(' Set-Acl -LiteralPath $Path -AclObject $acl')
 if($start-lt 0 -or $end-le $start){throw 'The original ACL construction boundary differs.'}
 $Public=$true;return & ([scriptblock]::Create($body.Substring($start,$end-$start)+"`nreturn `$acl"))
}
function Test-WindowsSignedTenantAclTransition([string]$Before,[string]$After,[string]$Kind,[string]$OriginalPackage,[string]$CandidatePackage){
 try{
  if($Kind-cnotin 'public_directory','inherited_public_directory','public_file' -or [string]::IsNullOrWhiteSpace($Before) -or [string]::IsNullOrWhiteSpace($After) -or $Before.Length-gt 131072 -or $After.Length-gt 131072 -or $Before.IndexOf([char]0)-ge 0 -or $After.IndexOf([char]0)-ge 0){return $false}
  $a=[Security.AccessControl.RawSecurityDescriptor]::new($Before);$b=[Security.AccessControl.RawSecurityDescriptor]::new($After)
  if(!$a.Owner -or !$a.Group -or ![object]::Equals($a.Owner,$b.Owner) -or ![object]::Equals($a.Group,$b.Group) -or $a.ControlFlags-ne $b.ControlFlags -or $a.ResourceManagerControl-ne 0 -or $b.ResourceManagerControl-ne 0 -or $a.SystemAcl -or $b.SystemAcl){return $false}
  $inherited=$Kind-ceq 'inherited_public_directory';$directory=$Kind.EndsWith('directory')
  if((!$inherited -and $a.Owner.Value-cne 'S-1-5-32-544') -or ($inherited -and $a.Owner.Value-cnotin 'S-1-5-18','S-1-5-32-544')){return $false}
  $null=[Security.Principal.SecurityIdentifier]::new($a.Group.Value)
  $allowed=[Security.AccessControl.ControlFlags]::SelfRelative-bor [Security.AccessControl.ControlFlags]::DiscretionaryAclPresent-bor [Security.AccessControl.ControlFlags]::DiscretionaryAclProtected-bor [Security.AccessControl.ControlFlags]::DiscretionaryAclAutoInherited
  if(([int]$a.ControlFlags-band (-bnot [int]$allowed))-ne 0 -or !($a.ControlFlags-band [Security.AccessControl.ControlFlags]::DiscretionaryAclPresent) -or [bool]($a.ControlFlags-band [Security.AccessControl.ControlFlags]::DiscretionaryAclProtected)-eq $inherited){return $false}
  foreach($item in @(@{actual=$a;original=$true;package=$OriginalPackage;count=4},@{actual=$b;original=$false;package=$CandidatePackage;count=5})){
   $actual=$item.actual.DiscretionaryAcl;if(!$actual -or $actual.Revision-ne 2 -or $actual.Count-ne $item.count){return $false}
   $recipe=Get-WindowsSignedTenantAclRecipe $item.package $directory $item.original
   $want=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
   foreach($ace in ([Security.AccessControl.RawSecurityDescriptor]::new($recipe.Sddl)).DiscretionaryAcl){
    $flags=$ace.AceFlags;if($inherited){$flags=[Security.AccessControl.AceFlags]([int]$flags-bor [int][Security.AccessControl.AceFlags]::Inherited)}
    $copy=[Security.AccessControl.CommonAce]::new($flags,$ace.AceQualifier,$ace.AccessMask,$ace.SecurityIdentifier,$false,$null)
    $bytes=[byte[]]::new($copy.BinaryLength);$copy.GetBinaryForm($bytes,0);if(!$want.Add([Convert]::ToBase64String($bytes))){return $false}
   }
   foreach($ace in $actual){
    if($ace-isnot [Security.AccessControl.CommonAce] -or $ace.IsCallback -or $ace.AceQualifier-ne [Security.AccessControl.AceQualifier]::AccessAllowed){return $false}
    $bytes=[byte[]]::new($ace.BinaryLength);$ace.GetBinaryForm($bytes,0);if(!$want.Remove([Convert]::ToBase64String($bytes))){return $false}
   };if($want.Count){return $false}
  };return $true
 }catch{return $false}
}
function Get-WindowsSignedTenantComparisonCopy($Before,$After,[string]$OriginalPackage,[string]$CandidatePackage,[string]$ExpectedHost,[string]$ContentProofPath){
 if($Before-isnot [Collections.IDictionary] -or $After-isnot [Collections.IDictionary]){throw 'The exact original private maps are required.'}
 $paths=Get-WindowsEmptyTenantPaths
 # Disabled original workers can leave all eight paths absent. Reuse only the
 # already-reviewed all-eight-absent initialization component in that case.
 $present=@($paths.Keys|Where-Object {$Before.Contains($_)})
 if(!$present.Count){return Get-WindowsEmptyTenantComparisonCopy $Before $After $CandidatePackage $ExpectedHost $ContentProofPath}
 if($present.Count-ne 8 -or @($paths.Keys|Where-Object {!$After.Contains($_)}).Count){throw 'The naturally initialized original eight-entry set must remain complete.'}
 $copy=@{};foreach($p in $After.Keys){$copy[$p]=$After[$p]};$records=@{};$changes=0
 foreach($p in $paths.Keys){
  $a=$Before[$p];$b=$After[$p];$directory=$paths[$p].EndsWith('directory');$keys=if($directory){@('directory','acl')}else{@('directory','acl','bytes','sha256')}
  if(!(Test-WindowsUpdaterAclKeys $a $keys) -or !(Test-WindowsUpdaterAclKeys $b $keys) -or $a.directory-isnot [bool] -or $b.directory-isnot [bool] -or $a.directory-ne $directory -or $b.directory-ne $directory){throw 'Initialized entry shape differs.'}
  foreach($field in $keys|Where-Object {$_-cne 'acl'}){if(![object]::Equals($a[$field],$b[$field])){throw 'Original initialized file bytes/metadata changed.'}}
  if(!$directory){$records[$p]=@{sha256=$a.sha256;bytes=$a.bytes}}
  if($a.acl-cne $b.acl){
   if(!(Test-WindowsSignedTenantAclTransition $a.acl $b.acl $paths[$p] $OriginalPackage $CandidatePackage)){throw 'Only the exact source public ACL4-to5 transition is admitted.'}
   $row=@{};foreach($field in $b.Keys){$row[$field]=$b[$field]};$row.acl=$a.acl;$copy[$p]=$row;$changes++
  }
 }
 if(!$changes){return $After}
 if($records.Count-ne 3 -or (Test-Path -LiteralPath 'C:\ProgramData\OpenWebPBX-Installation\onboarding-required')){throw 'The unchanged legacy empty fixture policy is required.'}
 $context=Join-Path (Split-Path $ContentProofPath -Parent) 'signed-empty-tenant-content-context.private.json'
 if(Test-Path -LiteralPath $context){throw 'The one-use signed content proof is occupied.'}
 WriteJson $context @{expected_host=$ExpectedHost;files=$records;package_root=$CandidatePackage}
 Python @((Join-Path $PSScriptRoot 'windows_empty_tenant_private_files.py'),$context,$ContentProofPath)
 $proof=Get-Content -LiteralPath $ContentProofPath -Raw|ConvertFrom-Json
 if($proof.schema-ne 1 -or $proof.state-cne 'passed' -or $proof.original_policy_required-isnot [bool] -or $proof.original_policy_required -or $proof.p256_ready_binding-isnot [bool] -or !$proof.p256_ready_binding -or $proof.exact_source_proof-isnot [bool] -or !$proof.exact_source_proof){throw 'Exact unchanged empty-ready/P256/proof/policy component failed.'}
 return $copy
}
