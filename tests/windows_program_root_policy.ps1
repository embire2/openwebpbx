param([string]$SourceRoot='')
# The native run uses actual RawSecurityDescriptor/CommonAce instances. Portable
# mode binds only these Windows constructor/class boundaries to fixture objects.
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
if([string]::IsNullOrWhiteSpace($SourceRoot)){$SourceRoot=Split-Path $PSScriptRoot -Parent}
$native=[Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$script:checks=0
function Check([bool]$Value){if(!$Value){throw ('Program-root policy control failed at line '+(@(Get-PSCallStack)[1].ScriptLineNumber))};$script:checks++}
class OpenWebPolicyControlAce {
 [bool]$IsCallback=$false
 [int]$AceType=0
 [int]$AceQualifier=0
 [int]$AceFlags=3
 [int]$AccessMask
 [object]$SecurityIdentifier
}
class OpenWebPolicyControlAcl : System.Collections.ArrayList {[int]$Revision=2}
function SourceAst([string]$Path){
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
 Check ($errors.Count -eq 0);return $ast
}
$supportPath=Join-Path $SourceRoot 'packaging/windows/Support-Recovery.ps1'
$ast=SourceAst $supportPath
foreach($name in 'Test-OpenWebProgramRootDescriptorPolicy','Test-OpenWebProgramRootPolicy'){
 $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))
 Check ($nodes.Count -eq 1);$body=$nodes[0].Extent.Text
 if(!$native){
  if($name -ceq 'Test-OpenWebProgramRootDescriptorPolicy'){
   $binding='[Security.AccessControl.CommonAce]';Check ([regex]::Matches($body,[regex]::Escape($binding)).Count -eq 1)
   $body=$body.Replace($binding,'[OpenWebPolicyControlAce]')
  }else{
   $binding='[Security.AccessControl.RawSecurityDescriptor]::new($sddl)';Check ([regex]::Matches($body,[regex]::Escape($binding)).Count -eq 1)
   $body=$body.Replace($binding,'(ReadPolicyControlDescriptor $sddl)')
  }
 }
 . ([scriptblock]::Create($body))
}
$upgrade=SourceAst (Join-Path $SourceRoot 'packaging/windows/Upgrade-OpenWebPBX.ps1')
$commands=@($upgrade.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Run' -and $n.Extent.Text -like 'Run icacls.exe @($root,*'},$true))
Check ($commands.Count -eq 1)
$guard=$commands[0].Parent
while($guard -and $guard -isnot [Management.Automation.Language.IfStatementAst]){$guard=$guard.Parent}
Check ($null -ne $guard -and $guard.Extent.Text.Contains('if(!(Test-OpenWebProgramRootPolicy -Root $root))'))
$script:actualGuard=[scriptblock]::Create($guard.Extent.Text)
$script:validSddl='O:BAG:BAD:P(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)(A;OICI;0x1200a9;;;BU)'
$script:legacySddl='O:BAG:BAD:AI(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)(A;OICI;0x1200a9;;;BU)'
$script:extraSddl='O:BAG:BAD:P(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)(A;OICI;0x1200a9;;;BU)(A;OICI;0x1200a9;;;LS)'
function NewControlAce([string]$Sid,[int]$Mask,[int]$Flags=3,[int]$Qualifier=0,[bool]$Callback=$false){
 if($native){return [Security.AccessControl.CommonAce]::new([Security.AccessControl.AceFlags]$Flags,[Security.AccessControl.AceQualifier]$Qualifier,$Mask,[Security.Principal.SecurityIdentifier]::new($Sid),$Callback,$null)}
 $ace=[OpenWebPolicyControlAce]::new();$ace.SecurityIdentifier=[pscustomobject]@{Value=$Sid};$ace.AccessMask=$Mask;$ace.AceFlags=$Flags;$ace.AceQualifier=$Qualifier;$ace.AceType=$Qualifier;$ace.IsCallback=$Callback;return $ace
}
function SetControlAcl($Descriptor,[object[]]$Aces,[int]$Revision=2){
 if($native){$acl=[Security.AccessControl.RawAcl]::new([byte]$Revision,$Aces.Count);foreach($ace in $Aces){$acl.InsertAce($acl.Count,$ace)}}
 else{$acl=[OpenWebPolicyControlAcl]::new();$acl.Revision=$Revision;foreach($ace in $Aces){$null=$acl.Add($ace)}}
 $Descriptor.DiscretionaryAcl=$acl
}
function NewControlDescriptor([string]$Case='exact'){
 if($native){$d=[Security.AccessControl.RawSecurityDescriptor]::new($script:validSddl)}
 else{$d=[pscustomobject]@{Owner='BA';Group='BA';BinaryLength=128;ControlFlags=36868;DiscretionaryAcl=$null;SystemAcl=$null}}
 $ba=NewControlAce 'S-1-5-32-544' 2032127;$sy=NewControlAce 'S-1-5-18' 2032127;$bu=NewControlAce 'S-1-5-32-545' 1179817
 SetControlAcl $d @($ba,$sy,$bu)
 switch($Case){
  'exact' {}
  'reordered' {SetControlAcl $d @($bu,$sy,$ba)}
  'owner-different' {if($native){$d.Owner=[Security.Principal.SecurityIdentifier]::new('S-1-5-19')}else{$d.Owner='LS'}}
  'group-different' {if($native){$d.Group=[Security.Principal.SecurityIdentifier]::new('S-1-5-19')}else{$d.Group='LS'}}
  'sacl-present' {if($native){$sacl=[Security.AccessControl.RawAcl]::new(2,1);$sacl.InsertAce(0,(NewControlAce 'S-1-5-18' 2032127 64 2));$d.SystemAcl=$sacl;$d.SetFlags($d.ControlFlags -bor [Security.AccessControl.ControlFlags]::SystemAclPresent)}else{$d.SystemAcl='unobserved-audit'}}
  'owner-null' {$d.Owner=$null}
  'group-null' {$d.Group=$null}
  'unprotected' {if($native){$d.SetFlags([Security.AccessControl.ControlFlags]([int]$d.ControlFlags -band (-bnot 4096)))}else{$d.ControlFlags=32772}}
  'dacl-absent' {if($native){$d.SetFlags([Security.AccessControl.ControlFlags]([int]$d.ControlFlags -band (-bnot 4)))}else{$d.ControlFlags=36864}}
  'acl-null' {$d.DiscretionaryAcl=$null}
  'revision4' {SetControlAcl $d @($ba,$sy,$bu) 4}
  'empty' {SetControlAcl $d @()}
  'missing' {SetControlAcl $d @($ba,$bu)}
  'extra' {SetControlAcl $d @($ba,$sy,$bu,(NewControlAce 'S-1-5-19' 1179817))}
  'duplicate' {SetControlAcl $d @($ba,$ba,$bu)}
  'wrong-sid' {SetControlAcl $d @((NewControlAce 'S-1-5-19' 2032127),$sy,$bu)}
  'ba-mask' {$ba.AccessMask=1179817;SetControlAcl $d @($ba,$sy,$bu)}
  'bu-write' {$bu.AccessMask=2032127;SetControlAcl $d @($ba,$sy,$bu)}
  'inherited' {$ba.AceFlags=[Security.AccessControl.AceFlags]19;SetControlAcl $d @($ba,$sy,$bu)}
  'inherit-only' {$ba.AceFlags=[Security.AccessControl.AceFlags]11;SetControlAcl $d @($ba,$sy,$bu)}
  'no-propagate' {$ba.AceFlags=[Security.AccessControl.AceFlags]7;SetControlAcl $d @($ba,$sy,$bu)}
  'missing-ci' {$ba.AceFlags=[Security.AccessControl.AceFlags]1;SetControlAcl $d @($ba,$sy,$bu)}
  'deny' {SetControlAcl $d @((NewControlAce 'S-1-5-32-544' 2032127 3 1),$sy,$bu)}
  'callback' {SetControlAcl $d @((NewControlAce 'S-1-5-32-544' 2032127 3 0 $true),$sy,$bu)}
  'object' {if($native){$object=[Security.AccessControl.ObjectAce]::new([Security.AccessControl.AceFlags]3,[Security.AccessControl.AceQualifier]0,2032127,[Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'),[Security.AccessControl.ObjectAceFlags]0,[Guid]::Empty,[Guid]::Empty,$false,$null)}else{$object=[pscustomobject]@{SecurityIdentifier=@{Value='S-1-5-32-544'};AccessMask=2032127;AceFlags=3;IsCallback=$false;AceType=0;AceQualifier=0}};SetControlAcl $d @($object,$sy,$bu)}
  'oversize' {if($native){throw 'Oversize fixture has no native descriptor encoding.'};$d.BinaryLength=262145}
  default {throw 'Unknown descriptor fixture.'}
 }
 return $d
}
function DescriptorFingerprint($Descriptor){
 if($native){$bytes=New-Object byte[] $Descriptor.BinaryLength;$Descriptor.GetBinaryForm($bytes,0);return [Convert]::ToBase64String($bytes)}
 return ($Descriptor|ConvertTo-Json -Depth 12 -Compress)
}
$positive=@('exact','reordered','owner-different','group-different','sacl-present')
$negative=@('owner-null','group-null','unprotected','dacl-absent','acl-null','revision4','empty','missing','extra','duplicate','wrong-sid','ba-mask','bu-write','inherited','inherit-only','no-propagate','missing-ci','deny','callback','object')
if(!$native){$negative+='oversize'}
foreach($case in @($positive)+@($negative)){
 $descriptor=NewControlDescriptor $case;$before=DescriptorFingerprint $descriptor
 Check ((Test-OpenWebProgramRootDescriptorPolicy $descriptor) -eq ($case -in $positive))
 Check ((DescriptorFingerprint $descriptor) -ceq $before)
}
function ReadPolicyControlDescriptor([string]$Sddl){
 if($Sddl -ceq $script:validSddl){return NewControlDescriptor}
 if($Sddl -ceq $script:legacySddl){return NewControlDescriptor 'unprotected'}
 if($Sddl -ceq $script:extraSddl){return NewControlDescriptor 'extra'}
 throw 'Portable constructor fixture refused.'
}
$script:aclValue=$script:validSddl;$script:aclFailure=$false;$script:aclCalls=0
function Get-Acl {param([string]$LiteralPath,[object]$ErrorAction)
 $script:aclCalls++;Check ($LiteralPath -ceq $script:expectedAclPath -and $ErrorAction -ceq 'Stop')
 if($script:aclFailure){throw 'Fictional security-provider failure.'};return @{Sddl=$script:aclValue}
}
$script:runs=New-Object 'Collections.Generic.List[object]'
function Run($File,[object[]]$Arguments){$script:runs.Add(@{File=$File;Arguments=$Arguments})}
function ApplyActualGuard([string]$Path){$root=$Path;. $script:actualGuard}
function GuardFails([string]$Path){
 $script:runs.Clear();$failed=$false;try{ApplyActualGuard $Path}catch{$failed=$true}
 Check $failed;Check ($script:runs.Count -eq 0)
}
$outer=Join-Path ([IO.Path]::GetTempPath()) ('openweb-root-policy-'+[Guid]::NewGuid().ToString('N'))
try{
 $root=Join-Path $outer 'program';$null=[IO.Directory]::CreateDirectory($root);$script:expectedAclPath=[IO.Path]::GetFullPath($root)
 ApplyActualGuard $root;Check ($script:runs.Count -eq 0)
 foreach($validNonmatching in $script:legacySddl,$script:extraSddl){
  $script:runs.Clear();$script:aclValue=$validNonmatching;ApplyActualGuard $root;Check ($script:runs.Count -eq 1)
  $call=$script:runs[0];Check ($call.File -ceq 'icacls.exe');Check ($call.Arguments.Count -eq 6 -and $call.Arguments[0] -ceq $root)
  Check (($call.Arguments[1..5] -join '|') -ceq '/inheritance:r|/grant:r|*S-1-5-32-544:(OI)(CI)F|*S-1-5-18:(OI)(CI)F|*S-1-5-32-545:(OI)(CI)RX')
 }
 $script:aclFailure=$true;GuardFails $root;$script:aclFailure=$false
 foreach($bad in @($null,'',' ',('x'*131073),('x'+[char]0+'x'),'not-a-descriptor')){$script:aclValue=$bad;GuardFails $root}
 $script:aclValue=$script:validSddl;$priorAclCalls=$script:aclCalls
 GuardFails (Join-Path $outer 'missing');Check ($script:aclCalls -eq $priorAclCalls)
 $file=Join-Path $outer 'ordinary-file';[IO.File]::WriteAllText($file,'fixture');GuardFails $file;Check ($script:aclCalls -eq $priorAclCalls)
 $target=Join-Path $outer 'target';$null=[IO.Directory]::CreateDirectory((Join-Path $target 'child'))
 $link=Join-Path $outer 'directory-link'
 if($native){$null=New-Item -ItemType Junction -Path $link -Target $target}else{$null=New-Item -ItemType SymbolicLink -Path $link -Target $target}
 GuardFails $link;GuardFails (Join-Path $link 'child');Check ($script:aclCalls -eq $priorAclCalls)
 # Remove the known link itself; never recurse through its target.
 Remove-Item -LiteralPath $link -Force -ErrorAction Stop
 Check (Test-Path -LiteralPath (Join-Path $target 'child'))
}finally{
 if(Test-Path -LiteralPath $outer){Remove-Item -LiteralPath $outer -Recurse -Force -ErrorAction Stop}
}
Check (!(Test-Path -LiteralPath $outer))
@{state='passed';checks=$script:checks;native_descriptor=$native;portable_binding=(!$native);scope='exact helper AST; native RawSecurityDescriptor/CommonAce on Windows; owned paths and fictional Get-Acl results; no installed PBX access'}|ConvertTo-Json -Compress
