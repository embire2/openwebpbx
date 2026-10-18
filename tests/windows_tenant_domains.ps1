# Actual source AST controls; Windows additionally applies real owned-file ACLs.
[CmdletBinding()]param([string]$SourceRoot='')
$ErrorActionPreference='Stop';if(!$SourceRoot){$SourceRoot=Split-Path $PSScriptRoot -Parent}
$count=0
function Check([bool]$Value,[string]$Name){if(!$Value){throw $Name};$script:count++}
function Refuses([scriptblock]$Action,[string]$Name){$failed=$false;try{& $Action}catch{$failed=$true};Check $failed $Name}
function LoadFunctions([string]$Path,[string[]]$Names){
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors);if($errors){throw 'Actual source did not parse.'}
 foreach($name in $Names){$items=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true));if($items.Count -ne 1){throw 'Actual unique function required.'};. ([scriptblock]::Create($items[0].Extent.Text))
  Set-Item -Path ('function:script:'+$name) -Value (Get-Item ('function:'+$name)).ScriptBlock
 }
}
LoadFunctions (Join-Path $SourceRoot 'packaging/windows/PublicAccess.Common.ps1') @('Assert-OpenWebPublicEmail','Assert-OpenWebOrdinaryPath')
LoadFunctions (Join-Path $SourceRoot 'packaging/windows/Tenant-Domains.ps1') @('Assert-OpenWebTenantName','Get-OpenWebTenantAclTarget','Set-OpenWebTenantAcl','Read-OpenWebTenantInput')
foreach($name in 'abc.openwebpbx.com','company-123.openwebpbx.com'){Check ((Assert-OpenWebTenantName $name) -ceq $name) 'Exact leased name'}
foreach($name in 'domains.openwebpbx.com.evil.invalid','a.openwebpbx.com','abc.def.openwebpbx.com','Abc.openwebpbx.com','*.openwebpbx.com','abc.openwebpbx.com:443',"abc.openwebpbx.com`n",'abc.openwebpbx.com/path'){Refuses {Assert-OpenWebTenantName $name} 'Non-lease hostname refused'}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('openweb-tenant-acl-'+[Guid]::NewGuid().ToString('N'));$oldProgramData=$env:ProgramData
try{
 New-Item -ItemType Directory -Path $fixture|Out-Null;$fixtureInput=Join-Path $fixture 'certificate-input.json'
 # Portable input checks delegate only the Windows path lookup, retaining the
 # actual parser/closed schema/email/name predicates and real fixture bytes.
 $originalPathCheck=(Get-Item function:Get-OpenWebTenantAclTarget).ScriptBlock
 function Get-OpenWebTenantAclTarget([string]$Path,[bool]$Directory){return $Path}
 $valid=@{names=@('qa-one.openwebpbx.com','qa-two.openwebpbx.com');key_hash=('a'*64);contact='operator@example.invalid'}
 [IO.File]::WriteAllText($fixtureInput,($valid|ConvertTo-Json));$read=Read-OpenWebTenantInput $fixtureInput;Check ($read.names.Count -eq 2) 'Actual bounded JSON parser'
 foreach($bad in @(@{names=@('qa-one.openwebpbx.com','qa-one.openwebpbx.com');key_hash=('a'*64);contact='operator@example.invalid'},@{names=@('qa-one.openwebpbx.com');key_hash=('a'*64);contact='bad'},@{names=@('qa-one.openwebpbx.com');key_hash=('a'*64);contact='operator@example.invalid';unknown='private-value'})){
  [IO.File]::WriteAllText($fixtureInput,($bad|ConvertTo-Json));Refuses {Read-OpenWebTenantInput $fixtureInput} 'Malformed input refused'
 }
 [IO.File]::WriteAllText($fixtureInput,('x'*8193));Refuses {Read-OpenWebTenantInput $fixtureInput} 'Oversize input refused'
 Set-Item function:Get-OpenWebTenantAclTarget $originalPathCheck
 if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){
  $env:ProgramData=$fixture;$config=Join-Path $fixture 'fusionpbx';$state=Join-Path $fixture 'OpenWebPBX\tenant-domains';$private=Join-Path $state 'private';New-Item -ItemType Directory -Path $config,$private -Force|Out-Null
  $before=(Get-Acl -LiteralPath $fixture).Sddl;$key=Join-Path $config 'tenant-domains-instance-key.pem';[IO.File]::WriteAllText($key,'fictional-private-key');Set-OpenWebTenantAcl $key $false $false
  $acl=Get-Acl -LiteralPath $key;Check $acl.AreAccessRulesProtected 'Real private key inheritance disabled';Check ($acl.Access.Count -eq 2) 'Real private key only two privileged rules'
  foreach($rule in $acl.Access){Check ($rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -in 'S-1-5-18','S-1-5-32-544') 'No web-user key access'}
  Refuses {Set-OpenWebTenantAcl $key $false $true} 'Private key cannot become web-readable'
  Set-OpenWebTenantAcl $private $true $false;$marker=Join-Path $state 'ready.json';[IO.File]::WriteAllText($marker,'{}');Set-OpenWebTenantAcl $marker $false $true
  $rules=(Get-Acl -LiteralPath $marker).Access;Check ($rules.Count -eq 3) 'Public ready marker has bounded IIS read rule';Check (@($rules|Where-Object {$_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -eq 'S-1-5-32-568' -and ([int]$_.FileSystemRights -band [int][Security.AccessControl.FileSystemRights]::Write) -ne 0}).Count -eq 0) 'IIS cannot write ready marker'
  $outside=Join-Path $fixture 'outside';[IO.File]::WriteAllText($outside,'original');$outsideAcl=(Get-Acl -LiteralPath $outside).Sddl;Refuses {Set-OpenWebTenantAcl $outside $false $false} 'Outside target refused';Check ((Get-Acl -LiteralPath $outside).Sddl -ceq $outsideAcl) 'Outside security exact';Check ((Get-Acl -LiteralPath $fixture).Sddl -ceq $before) 'Containing security exact';Check ([IO.File]::ReadAllText($key) -ceq 'fictional-private-key') 'Key bytes exact'
 }else{Write-Output 'Windows actual ACL/IIS/ACME execution not qualified on this platform.'}
}finally{
 $env:ProgramData=$oldProgramData
 if(Test-Path -LiteralPath $fixture){$item=Get-Item -LiteralPath $fixture -Force;if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Owned fixture became a link.'};Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction Stop}
}
Write-Output "PASS $count actual AST/input/owned-ACL tenant-domain controls."
