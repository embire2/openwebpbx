#Requires -Version 5.1
[CmdletBinding()]param([string]$SourceRoot)
# Actual helper with only icacls execution and ACL readback bound to fixtures.
# Ordinary owned files and their byte hashes remain real. Native proof is separate.
$ErrorActionPreference='Stop';$checks=0
if(!$SourceRoot){$SourceRoot=Split-Path $PSScriptRoot -Parent}
function Verify([bool]$Value){$script:checks++;if(!$Value){throw ('Canary contract ACL control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)}}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-updater-qualification.ps1'),[ref]$tokens,[ref]$errors)
Verify (@($errors).Count -eq 0)
$functions=@{}
foreach($name in 'Check','Hash','SecureCanaryFaultContract'){
 $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))
 Verify ($nodes.Count -eq 1);$functions[$name]=$nodes[0].Extent.Text
}
Verify ([regex]::Matches($functions.SecureCanaryFaultContract,[regex]::Escape('"$env:SystemRoot\System32\icacls.exe"')).Count -eq 2)
$bound=$functions.SecureCanaryFaultContract.Replace('"$env:SystemRoot\System32\icacls.exe"','Invoke-OwnedIcacls')
foreach($name in 'Check','Hash'){. ([ScriptBlock]::Create($functions[$name]))}
. ([ScriptBlock]::Create($bound))
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('OpenWebCanaryContractAcl-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $temporary
$bytes=[Text.Encoding]::UTF8.GetBytes('{"schema":1,"fictional_owned_control":true}')
function Rule([string]$Sid){return [pscustomobject]@{IdentityReference=[pscustomobject]@{Value=$Sid};IsInherited=$false;AccessControlType=[Security.AccessControl.AccessControlType]::Allow;FileSystemRights=[Security.AccessControl.FileSystemRights]::FullControl;InheritanceFlags=[Security.AccessControl.InheritanceFlags]::None;PropagationFlags=[Security.AccessControl.PropagationFlags]::None}}
function ResetFixture([string]$Name='canary-fault-contract.json'){
 $script:target=Join-Path $temporary $Name;[IO.File]::WriteAllBytes($target,$bytes)
 $script:calls=[Collections.Generic.List[object]]::new();$script:aclReads=0;$script:failCommand=0;$script:alterBytes=$false
 $script:acl=[pscustomobject]@{AreAccessRulesProtected=$true;owner='S-1-5-32-544';rules=@((Rule 'S-1-5-32-544'),(Rule 'S-1-5-18'))}
 $acl|Add-Member ScriptMethod GetOwner {param($Type) return [pscustomobject]@{Value=$this.owner}}
 $acl|Add-Member ScriptMethod GetAccessRules {param($Explicit,$Inherited,$Type) return $this.rules}
}
function Invoke-OwnedIcacls([string]$Path,[Parameter(ValueFromRemainingArguments=$true)][string[]]$Options){
 Verify ($Path -ceq $target)
 $calls.Add(@{path=$Path;options=$Options})
 $global:LASTEXITCODE=if($failCommand -eq $calls.Count){87}else{0}
 if($alterBytes -and $calls.Count -eq 2){[IO.File]::WriteAllText($target,'changed only by this owned negative fixture')}
}
function Get-Acl([string]$LiteralPath){Verify ($LiteralPath -ceq $target);$script:aclReads++;return $acl}
function Refuses([string]$Message,[int]$Commands,[int]$Reads=0){
 $errorRecord=$null;try{SecureCanaryFaultContract $target $temporary}catch{$errorRecord=$_}
 Verify ($null -ne $errorRecord -and $errorRecord.Exception.Message -ceq $Message -and $calls.Count -eq $Commands -and $aclReads -eq $Reads)
}
try{
 foreach($name in 'canary-fault-contract.json','canary-host-sentinel.json'){
  ResetFixture $name;$before=Hash $target;$output=@(SecureCanaryFaultContract $target $temporary)
  Verify ($output.Count -eq 0 -and $calls.Count -eq 2 -and $aclReads -eq 1 -and (Hash $target) -ceq $before)
  Verify (($calls[0].options -join '|') -ceq '/inheritance:r|/grant:r|*S-1-5-32-544:F|*S-1-5-18:F')
  Verify (($calls[1].options -join '|') -ceq '/setowner|*S-1-5-32-544')
 }
 ResetFixture;$script:acl.rules=@($acl.rules[1],$acl.rules[0]);SecureCanaryFaultContract $target $temporary
 Verify ($calls.Count -eq 2 -and $aclReads -eq 1)
 ResetFixture;$script:failCommand=1
 Refuses 'The owned canary contract DACL command failed.' 1
 Verify ((Hash $target) -ceq (Hash (Join-Path $temporary 'canary-host-sentinel.json')))
 ResetFixture;$script:failCommand=2
 Refuses 'The owned canary contract owner command failed.' 2
 foreach($case in 'unprotected','foreign_owner','missing_system','extra_identity','duplicate_admin','deny','inherited','partial_rights','inheritance_flags','propagation_flags'){
  ResetFixture;$before=Hash $target;$message='The owned canary contract grants unexpected access.'
  switch($case){
   'unprotected'{$acl.AreAccessRulesProtected=$false;$message='The owned canary contract protection or owner differs.'}
   'foreign_owner'{$acl.owner='S-1-5-19';$message='The owned canary contract protection or owner differs.'}
   'missing_system'{$acl.rules=@($acl.rules[0]);$message='The owned canary contract protection or owner differs.'}
   'extra_identity'{$acl.rules+=Rule 'S-1-5-19';$message='The owned canary contract protection or owner differs.'}
   'duplicate_admin'{$acl.rules=@((Rule 'S-1-5-32-544'),(Rule 'S-1-5-32-544'))}
   'deny'{$acl.rules[0].AccessControlType=[Security.AccessControl.AccessControlType]::Deny}
   'inherited'{$acl.rules[0].IsInherited=$true}
   'partial_rights'{$acl.rules[0].FileSystemRights=[Security.AccessControl.FileSystemRights]::Read}
   'inheritance_flags'{$acl.rules[0].InheritanceFlags=[Security.AccessControl.InheritanceFlags]::ObjectInherit}
   'propagation_flags'{$acl.rules[0].PropagationFlags=[Security.AccessControl.PropagationFlags]::InheritOnly}
  }
  Refuses $message 2 1;Verify ((Hash $target) -ceq $before)
 }
 ResetFixture;$script:alterBytes=$true
 Refuses 'The owned canary contract content changed.' 2 1
 ResetFixture 'unexpected.json'
 Refuses 'Only the two exact owned canary contracts may be secured.' 0
 ResetFixture;[IO.File]::WriteAllBytes($target,(New-Object byte[] 65537))
 Refuses 'An ordinary bounded owned canary contract is required.' 0
 ResetFixture;$nested=Join-Path $temporary 'nested';$null=New-Item -ItemType Directory -Path $nested;$script:target=Join-Path $nested 'canary-fault-contract.json';[IO.File]::WriteAllBytes($target,$bytes)
 Refuses 'Only the two exact owned canary contracts may be secured.' 0
 ResetFixture;$script:target='canary-fault-contract.json'
 Refuses 'An absolute owned contract path is required.' 0
 # Caller has only the two constant filenames and no combined owner/grant command.
 Verify ($ast.Extent.Text.Contains("foreach(`$file in 'canary-fault-contract.json','canary-host-sentinel.json'){SecureCanaryFaultContract (Join-Path `$contractDirectory `$file) `$contractDirectory}"))
 Verify (!$ast.Extent.Text.Contains("/grant:r '*S-1-5-32-544:F' '*S-1-5-18:F' /setowner"))
}finally{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Recurse -Force}}
Verify (!(Test-Path -LiteralPath $temporary))
@{schema=1;state='passed';actual_source_controls=$checks;owned_file_bytes_real=$true;native_icacls_executed=$false;test_bindings='fixed icacls executable and ACL readback only';foreign_objects_or_services_changed=$false}|ConvertTo-Json -Compress
