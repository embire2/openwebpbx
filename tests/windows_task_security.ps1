# Exact-source controls only. No task, file ACL, service or installed PBX is read.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent),[switch]$PortableOnly)
$ErrorActionPreference='Stop';$checks=0;$nativeChecks=0
. (Join-Path $PSScriptRoot 'windows-task-security-equal-boundary.ps1')
function AssertControl([bool]$Value){if(!$Value){throw ('Task security control failed at line '+(@(Get-PSCallStack)[1].ScriptLineNumber))};$script:checks++}
function SourceFunction([string]$Path,[string]$Name){
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
 AssertControl ($errors.Count -eq 0)
 $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Name},$true))
 AssertControl ($nodes.Count -eq 1);return $nodes[0]
}
function LoadControlFunction($Node){Invoke-Expression ($Node.Extent.Text -replace ('^function '+$Node.Name+'\b'),('function global:'+$Node.Name))}
$support=Join-Path $SourceRoot 'packaging/windows/Support-Recovery.ps1'
$descriptorNode=SourceFunction $support 'Test-OpenWebTaskSecurityEquivalent';LoadControlFunction $descriptorNode
AssertControl ($descriptorNode.Extent.Text -notmatch '(?i)\b(CommonAcl|DiscretionaryAcl\s*\]::new)\b')
$fallback=@($descriptorNode.FindAll({param($n)$n -is [Management.Automation.Language.TryStatementAst]},$true))
AssertControl ($fallback.Count -eq 1)
$statements=@($fallback[0].Body.Statements)
AssertControl ($statements[0].Extent.Text -ceq '$before=[Security.AccessControl.RawSecurityDescriptor]::new($Original)' -and $statements[1].Extent.Text -ceq '$after=[Security.AccessControl.RawSecurityDescriptor]::new($Current)')
# SDDL has no field for an otherwise ordinary RawAcl's revision. Exercise that
# and opaque callback data on actual raw objects using the unchanged AST body
# after its two string constructors, instead of losing them in serialization.
$rawFallback=[scriptblock]::Create('param($before,$after) try {'+[Environment]::NewLine+((@($statements|Select-Object -Skip 2|ForEach-Object {$_.Extent.Text})) -join [Environment]::NewLine)+[Environment]::NewLine+'} catch { return $false }')
AssertControl (Test-OpenWebTaskSecurityEquivalent 'O:SYG:BAD:(A;;FA;;;SY)' 'O:SYG:BAD:(A;;FA;;;SY)')
foreach($pair in @(@('',''),@(' ',' '),@($null,$null),@('not a descriptor','not the same descriptor'),@(('x'*65537),('x'*65537)))){
 AssertControl (!(Test-OpenWebTaskSecurityEquivalent $pair[0] $pair[1]))
}
$restore=(SourceFunction $support 'Restore-OpenWebSupport').Extent.Text
AssertControl ([regex]::Matches($restore,'Test-OpenWebTaskSecurityEquivalent').Count -eq 2)
AssertControl ($restore.Contains('SetSecurityDescriptor([string]$entry.Value.Security,0x10)'))
AssertControl ($restore.Contains('(Get-Acl -LiteralPath $taskFile).Sddl -ne $entry.Value.FileAcl'))
$upgrade=Join-Path $SourceRoot 'tests/windows-upgrade-acceptance.ps1';$updater=Join-Path $SourceRoot 'tests/windows-updater-qualification.ps1'
$snapshotFunctions=@()
foreach($path in $upgrade,$updater){
 $snapshot=SourceFunction $path 'TaskSnapshot';AssertControl ($snapshot.Extent.Text.Contains('GetSecurityDescriptor(7)') -and !$snapshot.Extent.Text.Contains('Test-OpenWebTaskSecurityEquivalent'))
 $snapshotFunctions+=,(SourceFunction $path 'EqualTaskSnapshots')
 $genericEqual=SourceFunction $path 'Equal'
 AssertControl (Test-GenericEqualTaskSecurityBoundary $genericEqual ($path -ceq $updater))
}
# Preserve the old refusal, then exercise the narrow actual-AST exception.
$actualEqual=SourceFunction $updater 'Equal';$actualText=$actualEqual.Extent.Text
AssertControl ($actualText -match 'TaskSecurity|TaskSnapshot|security')
AssertControl (!(Test-GenericEqualTaskSecurityBoundary $actualEqual))
$observer='if($Label -ceq ''normal-task-contract-security'' -and $report.comparison_result -ceq ''different''){try{$task=QualificationTaskDifference $Before $After;if($task){$script:qualificationComparisonFailure.task=$task}}catch{}}'
AssertControl ($actualText.Contains($observer))
$mutations=@(
 $actualText.Replace($observer,'').Replace('try{CheckedProcess',('try{'+$observer+';CheckedProcess')),
 $actualText.Replace($observer,'').Replace("('compare-'+`$Label)}catch{",("('compare-'+`$Label);"+$observer+'}catch{')),
 $actualText.Replace($observer,$observer.Replace('normal-task-contract-security','normal-tasks')),
 $actualText.Replace($observer,$observer.Replace("'different'","'equal'")),
 $actualText.Replace($observer,$observer.Replace("`$Label -ceq","`$Label -cne")),
 $actualText.Replace($observer,$observer.Replace('QualificationTaskDifference $Before $After','QualificationTaskDifference (Normalize $Before) $After')),
 $actualText.Replace($observer,$observer.Replace('catch{}','catch{throw}')),
 $actualText.Replace('$a,$b)','$b,$a)'),
 $actualText.Replace('windows-compare-json.py','not-the-exact-comparator.py'),
 $actualText.Replace("@('-I','-B',","@('-B',"),
 $actualText.Replace("@('-I','-B',","@('-I',"),
 $actualText.Replace('backup-runtime\python.exe','backup-runtime\pythonw.exe'),
 $actualText.Replace('WriteJson $a $Before','WriteJson $a (Normalize $Before)'),
 $actualText.Replace('WriteJson $b $After','WriteJson $b $Before'),
 $actualText.Replace('WriteJson $a $Before','WriteJson $a (Test-OpenWebTaskSecurityEquivalent $Before $After)'),
 $actualText.Replace("`n  throw`n","`n  return`n"),
 $actualText.Replace("`n  throw`n","`n  throw 'replacement failure'`n"),
 $actualText.Replace("`n  throw`n","`n  exit 0`n"),
 $actualText.Replace("`n  throw`n","`n  break`n"),
 $actualText.Replace("`n  throw`n","`n  continue`n"),
 $actualText.Replace("`n  throw`n","`n  `$Before.Remove('acl');throw`n"),
 $actualText.Replace('$path=Join-Path $work','return;$path=Join-Path $work'),
 $actualText.Replace("('compare-'+`$Label)}catch{","('compare-'+`$Label)}catch [IO.IOException]{"),
 $actualText.Replace("`n }`n}","`n }finally{Write-Output UNEXPECTED}`n}"),
 $actualText.Replace('$report=@{comparison_result=',"TaskSnapshot;`$report=@{comparison_result="),
 $actualText.Replace('$report=@{comparison_result=',"Test-OpenWebTaskSecurityEquivalent `$Before `$After;`$report=@{comparison_result=")
)
foreach($changed in $mutations){
 AssertControl ($changed -cne $actualText)
 $tokens=$null;$errors=$null;$parsed=[Management.Automation.Language.Parser]::ParseInput($changed,[ref]$tokens,[ref]$errors)
 AssertControl ($errors.Count -eq 0)
 $equal=@($parsed.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Equal'},$true))
 AssertControl ($equal.Count -eq 1 -and !(Test-GenericEqualTaskSecurityBoundary $equal[0] $true))
}
AssertControl ((Get-Content $upgrade -Raw).Contains(". (Join-Path `$PackageRoot 'Support-Recovery.ps1')"))
AssertControl ((Get-Content $updater -Raw).Contains(". (Join-Path `$package 'Support-Recovery.ps1')"))
AssertControl ((Get-Content $upgrade -Raw) -notmatch 'Equal \$tasks \(TaskSnapshot\)')
AssertControl ((Get-Content $updater -Raw) -notmatch 'Equal \$beforeTasks \(TaskSnapshot\)')
AssertControl ((SourceFunction $updater 'NormalTaskPreservation').Extent.Text.Contains("EqualTaskSnapshots `$normalizedBefore `$normalizedAfter 'normal-task-contract-security'"))
# Exercise both actual task-only wrappers. This Equal stub recursively compares
# every remaining scalar/key without converting, discarding or normalizing it.
function ExactValue($A,$B){
 if($A -is [Collections.IDictionary] -and $B -is [Collections.IDictionary]){
  if($A.Count -ne $B.Count){return $false}
  foreach($key in $A.Keys){if($B.Keys -cnotcontains $key -or !(ExactValue $A[$key] $B[$key])){return $false}};return $true
 }
 if($null -eq $A -or $null -eq $B){return ($null -eq $A -and $null -eq $B)}
 return ($A.GetType() -eq $B.GetType() -and [object]::Equals($A,$B))
}
function Check([bool]$Value,[string]$Message){if(!$Value){throw 'Owned task control refusal.'}}
function Equal($Before,$After,[string]$Message){$script:equalCalls++;Check (ExactValue $Before $After) $Message}
function TaskFixture([string]$Security){return @{'fictional-owned-task'=@{exists=$true;enabled=$false;xml='<Task><Settings><Enabled>false</Enabled></Settings></Task>';acl='EXACT_FILE_ACL';security=$Security};'fictional-absent-task'=@{exists=$false}}}
function ExpectTaskRefusal($A,$B){$refused=$false;try{EqualTaskSnapshots $A $B 'owned control'}catch{$refused=$true};AssertControl $refused}
foreach($node in $snapshotFunctions){
 LoadControlFunction $node;$equalCalls=0;$a=TaskFixture 'O:SYG:BAD:(A;;FA;;;SY)';$b=TaskFixture 'O:SYG:BAD:(A;;FA;;;SY)'
 EqualTaskSnapshots $a $b 'owned control';AssertControl ($equalCalls -eq 1)
 AssertControl ($a['fictional-owned-task'].ContainsKey('security') -and $b['fictional-owned-task'].ContainsKey('security'))
 foreach($field in 'xml','acl','enabled','exists','security'){
  $b=TaskFixture 'O:SYG:BAD:(A;;FA;;;SY)'
  if($field -in 'enabled','exists'){$b['fictional-owned-task'][$field]=!$b['fictional-owned-task'][$field]}else{$b['fictional-owned-task'][$field]='DIFFERENT'}
  ExpectTaskRefusal $a $b
 }
 $b=TaskFixture 'O:SYG:BAD:(A;;FA;;;SY)';$b['fictional-owned-task'].Remove('security');ExpectTaskRefusal $a $b
 $b=TaskFixture 'O:SYG:BAD:(A;;FA;;;SY)';$b['fictional-owned-task'].extra='DIFFERENT';ExpectTaskRefusal $a $b
 $b=TaskFixture 'O:SYG:BAD:(A;;FA;;;SY)';$b.Remove('fictional-absent-task');ExpectTaskRefusal $a $b
 $b=TaskFixture 'O:SYG:BAD:(A;;FA;;;SY)';$b.extra=@{exists=$false};ExpectTaskRefusal $a $b
 $b=TaskFixture 'O:SYG:BAD:(A;;FA;;;SY)';$b['fictional-absent-task'].security='UNEXPECTED';ExpectTaskRefusal $a $b
}
if($PortableOnly){Write-Output ('PASS '+$checks+' exact-source/metadata/refusal controls; RawSecurityDescriptor Windows controls NOT RUN');return}
if($env:OS -ne 'Windows_NT'){throw 'Actual RawSecurityDescriptor controls require Windows; use -PortableOnly for the explicitly limited source checks.'}
$portableCount=$checks
function CloneDescriptor($Value){$bytes=New-Object byte[] $Value.BinaryLength;$Value.GetBinaryForm($bytes,0);return [Security.AccessControl.RawSecurityDescriptor]::new($bytes,0)}
function DescriptorText($Value){return $Value.GetSddlForm([Security.AccessControl.AccessControlSections]::All)}
function ReorderedDescriptor($Value,[int[]]$Order,[bool]$SetAutoInherited=$true){
 $copy=CloneDescriptor $Value;$acl=[Security.AccessControl.RawAcl]::new($Value.DiscretionaryAcl.Revision,$Order.Count)
 foreach($index in $Order){$acl.InsertAce($acl.Count,$Value.DiscretionaryAcl[$index])};$copy.DiscretionaryAcl=$acl
 if($SetAutoInherited){$copy.SetFlags([Security.AccessControl.ControlFlags]([int]$copy.ControlFlags -bor 0x400))};return $copy
}
function AssertDescriptorResult($Before,$After,[bool]$Expected){
 $a=DescriptorText $Before;$b=DescriptorText $After
 $beforeBytes=New-Object byte[] $Before.BinaryLength;$afterBytes=New-Object byte[] $After.BinaryLength;$Before.GetBinaryForm($beforeBytes,0);$After.GetBinaryForm($afterBytes,0)
 $actual=Test-OpenWebTaskSecurityEquivalent $a $b
 if($actual -ne $Expected){throw ('Task security public_string comparison failed; source caller line '+(@(Get-PSCallStack)[1].ScriptLineNumber))}
 AssertControl ($actual -eq $Expected)
 AssertControl ((DescriptorText $Before) -ceq $a -and (DescriptorText $After) -ceq $b)
 $a2=New-Object byte[] $Before.BinaryLength;$b2=New-Object byte[] $After.BinaryLength;$Before.GetBinaryForm($a2,0);$After.GetBinaryForm($b2,0)
 AssertControl ([Convert]::ToBase64String($beforeBytes) -ceq [Convert]::ToBase64String($a2) -and [Convert]::ToBase64String($afterBytes) -ceq [Convert]::ToBase64String($b2))
}
function AssertRawResult($Before,$After,[bool]$Expected){
 $beforeBytes=New-Object byte[] $Before.BinaryLength;$afterBytes=New-Object byte[] $After.BinaryLength;$Before.GetBinaryForm($beforeBytes,0);$After.GetBinaryForm($afterBytes,0)
 $actual=@(& $rawFallback $Before $After)
 if($actual.Count -ne 1 -or $actual[0] -isnot [bool] -or $actual[0] -ne $Expected){throw ('Task security raw_body comparison failed; source caller line '+(@(Get-PSCallStack)[1].ScriptLineNumber))}
 AssertControl ($actual.Count -eq 1 -and $actual[0] -is [bool] -and $actual[0] -eq $Expected)
 $a2=New-Object byte[] $Before.BinaryLength;$b2=New-Object byte[] $After.BinaryLength;$Before.GetBinaryForm($a2,0);$After.GetBinaryForm($b2,0)
 AssertControl ([Convert]::ToBase64String($beforeBytes) -ceq [Convert]::ToBase64String($a2) -and [Convert]::ToBase64String($afterBytes) -ceq [Convert]::ToBase64String($b2))
}
$original=[Security.AccessControl.RawSecurityDescriptor]::new('O:SYG:BAD:(A;;FA;;;SY)(A;;FR;;;BA)(A;;FW;;;LS)(A;OIIO;FR;;;BU)')
$changed=ReorderedDescriptor $original @(0,3,1,2)
AssertControl (([int]$original.ControlFlags -bxor [int]$changed.ControlFlags) -eq 0x400)
AssertDescriptorResult $original $changed $true
AssertDescriptorResult $original (ReorderedDescriptor $original @(3,2,1,0) $false) $true
$onlyAi=CloneDescriptor $original;$onlyAi.SetFlags([Security.AccessControl.ControlFlags]([int]$onlyAi.ControlFlags -bor 0x400));AssertDescriptorResult $original $onlyAi $true
AssertDescriptorResult $onlyAi (ReorderedDescriptor $onlyAi @(3,2,1,0)) $true
AssertDescriptorResult $changed $original $false
foreach($attribute in 'Owner','Group'){$bad=CloneDescriptor $changed;$bad.$attribute=[Security.Principal.SecurityIdentifier]::new('S-1-5-20');AssertDescriptorResult $original $bad $false}
foreach($flag in 0x1,0x2,0x4,0x8,0x10,0x20,0x100,0x200,0x800,0x1000,0x2000,0x4000){
 $bad=CloneDescriptor $changed;$bad.SetFlags([Security.AccessControl.ControlFlags]([int]$bad.ControlFlags -bxor $flag));AssertRawResult $original $bad $false
 # Windows omits SACL protection from SDDL when the SACL is null. Its raw
 # negative remains above; the string negative below uses a present SACL.
 if($flag -eq 0x1000){AssertDescriptorResult $original $bad $false}
}
foreach($mutation in 'mask','sid','flags','added','removed','multiplicity','revision','empty','null','deny','callback','object'){
 $bad=CloneDescriptor $changed;$acl=$bad.DiscretionaryAcl
 switch($mutation){
  mask {$ace=$acl[0];$acl.RemoveAce(0);$acl.InsertAce(0,[Security.AccessControl.CommonAce]::new($ace.AceFlags,$ace.AceQualifier,($ace.AccessMask -bxor 1),$ace.SecurityIdentifier,$false,$null))}
  sid {$ace=$acl[0];$acl.RemoveAce(0);$acl.InsertAce(0,[Security.AccessControl.CommonAce]::new($ace.AceFlags,$ace.AceQualifier,$ace.AccessMask,[Security.Principal.SecurityIdentifier]::new('S-1-5-20'),$false,$null))}
  flags {$ace=$acl[0];$acl.RemoveAce(0);$acl.InsertAce(0,[Security.AccessControl.CommonAce]::new([Security.AccessControl.AceFlags]([int]$ace.AceFlags -bxor 0x10),$ace.AceQualifier,$ace.AccessMask,$ace.SecurityIdentifier,$false,$null))}
  added {$acl.InsertAce($acl.Count,$acl[0])}
  removed {$acl.RemoveAce(0)}
  multiplicity {$acl.RemoveAce(1);$acl.InsertAce(1,$acl[0])}
  revision {$replacement=[Security.AccessControl.RawAcl]::new(4,$acl.Count);foreach($ace in $acl){$replacement.InsertAce($replacement.Count,$ace)};$bad.DiscretionaryAcl=$replacement}
  empty {$bad.DiscretionaryAcl=[Security.AccessControl.RawAcl]::new(2,0)}
  null {$bad.DiscretionaryAcl=$null}
  deny {$ace=$acl[0];$acl.RemoveAce(0);$acl.InsertAce(0,[Security.AccessControl.CommonAce]::new($ace.AceFlags,[Security.AccessControl.AceQualifier]::AccessDenied,$ace.AccessMask,$ace.SecurityIdentifier,$false,$null))}
  callback {$ace=$acl[0];$acl.RemoveAce(0);$acl.InsertAce(0,[Security.AccessControl.CommonAce]::new($ace.AceFlags,$ace.AceQualifier,$ace.AccessMask,$ace.SecurityIdentifier,$true,[byte[]]@(1,2,3,4)))}
  object {$ace=$acl[0];$acl.RemoveAce(0);$acl.InsertAce(0,[Security.AccessControl.ObjectAce]::new($ace.AceFlags,$ace.AceQualifier,$ace.AccessMask,$ace.SecurityIdentifier,[Security.AccessControl.ObjectAceFlags]::None,[Guid]::Empty,[Guid]::Empty,$false,$null))}
 }
 AssertRawResult $original $bad $false
 if($mutation -notin 'revision','callback','object'){AssertDescriptorResult $original $bad $false}
}
# Even the same unsupported ACEs reordered must fail fallback, not become an
# ordering-insensitive comparison for mixed deny/object/callback semantics.
# OA without a GUID converts to ordinary Allowed, so this fixture needs one:
# https://learn.microsoft.com/en-us/windows/win32/secauthz/ace-strings
foreach($sddl in 'O:SYG:BAD:(D;;FW;;;LS)(A;;FA;;;SY)','O:SYG:BAD:(OA;;FR;11111111-2222-3333-4444-555555555555;;LS)(A;;FA;;;SY)'){
 $unsupported=[Security.AccessControl.RawSecurityDescriptor]::new($sddl)
 if($sddl.Contains('(OA;')){AssertControl ($unsupported.DiscretionaryAcl[0] -is [Security.AccessControl.ObjectAce] -and $unsupported.DiscretionaryAcl[0].AceType -eq [Security.AccessControl.AceType]::AccessAllowedObject -and $unsupported.DiscretionaryAcl[0].ObjectAceType -eq [Guid]'11111111-2222-3333-4444-555555555555')}
 AssertDescriptorResult $unsupported (ReorderedDescriptor $unsupported @(1,0)) $false
}
# Opaque callback data is binary, not an unconditioned XA string. Keep its
# exact ACE bytes and compare the actual raw fallback, without SDDL conversion.
$callbackDescriptor=CloneDescriptor $original;$callbackAcl=[Security.AccessControl.RawAcl]::new(2,2)
$callbackAcl.InsertAce(0,[Security.AccessControl.CommonAce]::new([Security.AccessControl.AceFlags]::None,[Security.AccessControl.AceQualifier]::AccessAllowed,1,[Security.Principal.SecurityIdentifier]::new('S-1-5-19'),$true,[byte[]]@(1,2,3,4)))
$callbackAcl.InsertAce(1,$original.DiscretionaryAcl[0]);$callbackDescriptor.DiscretionaryAcl=$callbackAcl
AssertControl ($callbackDescriptor.DiscretionaryAcl[0].IsCallback -and $callbackDescriptor.DiscretionaryAcl[0].AceType -eq [Security.AccessControl.AceType]::AccessAllowedCallback)
AssertRawResult $callbackDescriptor (ReorderedDescriptor $callbackDescriptor @(1,0)) $false
$duplicates=[Security.AccessControl.RawSecurityDescriptor]::new('O:SYG:BAD:(A;;FR;;;LS)(A;;FR;;;LS)(A;;FA;;;SY)')
AssertDescriptorResult $duplicates (ReorderedDescriptor $duplicates @(2,1,0)) $true
$bad=ReorderedDescriptor $duplicates @(2,1,0);$bad.DiscretionaryAcl.RemoveAce(1);$bad.DiscretionaryAcl.InsertAce(1,$bad.DiscretionaryAcl[0]);AssertDescriptorResult $duplicates $bad $false
$withSacl=[Security.AccessControl.RawSecurityDescriptor]::new('O:SYG:BAD:(A;;FR;;;LS)(A;;FA;;;SY)S:(AU;SA;FR;;;WD)(AU;FA;FW;;;BA)')
AssertDescriptorResult $withSacl (ReorderedDescriptor $withSacl @(1,0)) $true
$protectedSacl=ReorderedDescriptor $withSacl @(1,0);$protectedSacl.SetFlags([Security.AccessControl.ControlFlags]([int]$protectedSacl.ControlFlags -bor 0x2000))
$reparsedSacl=[Security.AccessControl.RawSecurityDescriptor]::new((DescriptorText $protectedSacl))
AssertControl ($null -ne $reparsedSacl.SystemAcl -and [int]$protectedSacl.ControlFlags -eq [int]$reparsedSacl.ControlFlags -and ([int]$reparsedSacl.ControlFlags -band 0x2000) -eq 0x2000)
AssertDescriptorResult $withSacl $protectedSacl $false
foreach($mode in 'removed','reordered','mask','revision'){
 $bad=ReorderedDescriptor $withSacl @(1,0)
 switch($mode){
  removed {$bad.SystemAcl=$null}
  reordered {$acl=[Security.AccessControl.RawAcl]::new(2,2);$acl.InsertAce(0,$bad.SystemAcl[1]);$acl.InsertAce(1,$bad.SystemAcl[0]);$bad.SystemAcl=$acl}
  mask {$ace=$bad.SystemAcl[0];$bad.SystemAcl.RemoveAce(0);$bad.SystemAcl.InsertAce(0,[Security.AccessControl.CommonAce]::new($ace.AceFlags,$ace.AceQualifier,($ace.AccessMask -bxor 1),$ace.SecurityIdentifier,$false,$null))}
  revision {$acl=[Security.AccessControl.RawAcl]::new(4,2);foreach($ace in $bad.SystemAcl){$acl.InsertAce($acl.Count,$ace)};$bad.SystemAcl=$acl}
 };AssertRawResult $withSacl $bad $false;if($mode -ne 'revision'){AssertDescriptorResult $withSacl $bad $false}
}
foreach($sddl in 'O:SYG:BAD:NO_ACCESS_CONTROL','O:SYG:BAD:','O:SYG:BA'){
 $unusual=[Security.AccessControl.RawSecurityDescriptor]::new($sddl);$bad=CloneDescriptor $unusual;$bad.SetFlags([Security.AccessControl.ControlFlags]([int]$bad.ControlFlags -bor 0x400))
 # Without DACL_PRESENT, SDDL omits D: and cannot carry this AI-only mutation.
 # https://learn.microsoft.com/en-us/windows/win32/secauthz/security-descriptor-string-format
 if($sddl -ceq 'O:SYG:BA'){AssertRawResult $unusual $bad $false}else{AssertDescriptorResult $unusual $bad $false}
}
$bad=CloneDescriptor $changed;$bad.ResourceManagerControl=1;AssertRawResult $original $bad $false
foreach($node in $snapshotFunctions){LoadControlFunction $node;$a=TaskFixture (DescriptorText $original);$b=TaskFixture (DescriptorText $changed);$equalCalls=0;EqualTaskSnapshots $a $b 'owned control';AssertControl ($equalCalls -eq 1 -and $a['fictional-owned-task'].security -ceq (DescriptorText $original) -and $b['fictional-owned-task'].security -ceq (DescriptorText $changed))}
Write-Output ('PASS '+$portableCount+' exact-source/metadata/refusal and '+($checks-$portableCount)+' actual RawSecurityDescriptor controls; no task or PBX accessed')
