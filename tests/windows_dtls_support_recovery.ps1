param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent),[string]$PreviousSupport='')
# Execute the actual support capture/recovery functions against an isolated
# Windows temporary installation. Adapters replace only unrelated IIS, optional
# capability and Task Scheduler boundaries; file contents and NTFS ACLs are real.
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'This regression requires native Windows file security.'}
$script:checks=0;$script:taskReads=0;$script:taskWrites=0
function AssertControl([bool]$Value){if(!$Value){throw ('DTLS support recovery control failed at line '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
$priorRestore=$null
if($PreviousSupport){. $PreviousSupport;$priorRestore=${function:Restore-OpenWebSupport}}
. (Join-Path $SourceRoot 'packaging/windows/Support-Recovery.ps1')
. (Join-Path $SourceRoot 'packaging/windows/File-Security.ps1')
. (Join-Path $SourceRoot 'packaging/windows/Dtls.Common.ps1')
function Get-WindowsCapability {param([switch]$Online,[string]$Name) @{State='Installed'}}
function Get-WebConfiguration {param([string]$PSPath,[string]$Filter) return $null}
function Remove-WebConfigurationProperty {param([string]$PSPath,[string]$Filter,[string]$Name,[hashtable]$AtElement,[object]$ErrorAction)}
function Get-ScheduledTask {param([string]$TaskName,[object]$ErrorAction) $script:taskReads++;return $null}
function Unregister-ScheduledTask {param([string]$TaskName,[switch]$Confirm,[object]$ErrorAction) $script:taskWrites++}
function WriteState([string]$Path,$Value){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 20),[Text.UTF8Encoding]::new($false))}
function CopyTree([string]$Source,[string]$Destination,[switch]$Mirror){
 if($Mirror -and (Test-Path -LiteralPath $Destination)){Remove-Item -LiteralPath $Destination -Recurse -Force}
 $null=[IO.Directory]::CreateDirectory($Destination)
 foreach($item in Get-ChildItem -LiteralPath $Source -Force){Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force}
}
function TextFile([string]$Path,[string]$Text){$null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path));[IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))}
function Acl([string]$Path){(Get-Acl -LiteralPath $Path).Sddl}
function FixtureAcl([string]$Path,[string]$Descriptor){$acl=[Security.AccessControl.FileSecurity]::new();$acl.SetSecurityDescriptorSddlForm($Descriptor);Set-Acl -LiteralPath $Path -AclObject $acl}
function TreeCheckpoint([string]$Path){
 $rows=@();if(Test-Path -LiteralPath $Path){foreach($item in @((Get-Item -LiteralPath $Path))+@(Get-ChildItem -LiteralPath $Path -Force -Recurse)){
  $rows+=,@{path=$item.FullName;directory=[bool]$item.PSIsContainer;sddl=(Acl $item.FullName);bytes=if($item.PSIsContainer){''}else{[Convert]::ToBase64String([IO.File]::ReadAllBytes($item.FullName))}}
 }};return ($rows|Sort-Object path|ConvertTo-Json -Depth 8 -Compress)
}
$outer=Join-Path ([IO.Path]::GetTempPath()) ('openweb-dtls-support-'+[Guid]::NewGuid().ToString('N'))
$envBefore=$env:OPENSSL_CONF
try{
 $null=[IO.Directory]::CreateDirectory($outer)
 & icacls.exe $outer /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F'|Out-Null;AssertControl ($LASTEXITCODE -eq 0)
 foreach($certificateExisted in $false,$true){foreach($stateExisted in $false,$true){
  $case=Join-Path $outer ('case-'+[int]$certificateExisted+'-'+[int]$stateExisted)
  $root=Join-Path $case 'program';$state=Join-Path $case 'state';$engine=Join-Path $case 'engine';$backup=Join-Path $case 'snapshot';$package=Join-Path $case 'package'
  foreach($path in $root,$state,$engine,$backup,(Join-Path $engine 'cert')){$null=[IO.Directory]::CreateDirectory($path)}
  TextFile (Join-Path $package 'engine/native-manifest.json') '{"files":{}}'
  $certificate=Join-Path $engine 'cert/dtls-srtp.pem';$custom=Join-Path $engine 'cert/custom.pem';$dtlsState=Join-Path $state 'dtls-setup'
  TextFile $custom 'CUSTOM-KEY-DO-NOT-CHANGE'
  if($certificateExisted){TextFile $certificate 'OLD-INVALID-STOCK-KEY';FixtureAcl $certificate 'O:BAG:BAD:PAI(A;;FA;;;BA)(A;;FA;;;SY)(A;;FR;;;BU)'}
  if($stateExisted){TextFile (Join-Path $dtlsState 'existing/journal.json') 'ORIGINAL-JOURNAL';TextFile (Join-Path $dtlsState 'existing/before.pem') 'ORIGINAL-PRIOR-KEY'}
  $customBefore=TreeCheckpoint $custom;$parentBefore=Acl (Split-Path $certificate -Parent);$certificateBefore=TreeCheckpoint $certificate;$stateBefore=TreeCheckpoint $dtlsState
  Save-OpenWebSupport -Backup $backup -PackageRoot $package -Root $root -StateRoot $state -EngineRoot $engine
  $record=Get-Content -LiteralPath (Join-Path $backup 'support-state.json') -Raw|ConvertFrom-Json
  AssertControl ([bool]$record.Files.$certificate.Exists -eq $certificateExisted)
  AssertControl ([bool]$record.Directories.'dtls-setup'.Exists -eq $stateExisted)
  AssertControl ($record.DtlsCertificateDirectory.Exists -eq $true -and $record.DtlsCertificateDirectory.Path -ceq (Split-Path $certificate -Parent))
  AssertControl ([string]$record.Acls.($record.DtlsCertificateDirectory.Path) -ceq $parentBefore)
  & icacls.exe (Split-Path $certificate -Parent) /grant '*S-1-5-19:R'|Out-Null;AssertControl ($LASTEXITCODE -eq 0)
  AssertControl ((Acl (Split-Path $certificate -Parent)) -cne $parentBefore)
  if($certificateExisted){AssertControl ([string]$record.Acls.$certificate -ceq (Acl $certificate))}
  TextFile $certificate 'NEW-PROTECTED-OWNED-KEY';FixtureAcl $certificate 'O:BAG:BAD:PAI(A;;FA;;;BA)(A;;FA;;;SY)'
  TextFile (Join-Path $dtlsState 'new/journal.json') 'NEW-COMMITTED-JOURNAL'
  if($stateExisted){TextFile (Join-Path $dtlsState 'existing/before.pem') 'CHANGED-PRIOR-KEY';Remove-Item -LiteralPath (Join-Path $dtlsState 'existing/journal.json') -Force}
  AssertControl ((TreeCheckpoint $certificate) -cne $certificateBefore -and (TreeCheckpoint $dtlsState) -cne $stateBefore)
  Restore-OpenWebSupport -Backup $backup -Root $root -StateRoot $state -EngineRoot $engine
  AssertControl ((TreeCheckpoint $certificate) -ceq $certificateBefore)
  AssertControl ((TreeCheckpoint $dtlsState) -ceq $stateBefore)
  AssertControl ((TreeCheckpoint $custom) -ceq $customBefore)
  AssertControl ((Acl (Split-Path $certificate -Parent)) -ceq $parentBefore)
  AssertControl ((Test-Path -LiteralPath $certificate) -eq $certificateExisted)
  AssertControl ((Test-Path -LiteralPath $dtlsState) -eq $stateExisted)
 }}
 AssertControl ($script:taskReads -eq 24 -and $script:taskWrites -eq 24)
 # The previous implementation silently swallowed a held native file's delete
 # error. A refused cleanup must retain that private evidence and must never
 # report recovery success while an originally absent identity/state remains.
 $variants=@(@{name='current';restore=${function:Restore-OpenWebSupport};refuse=$true})
 if($null -ne $priorRestore){$variants+=@{name='previous';restore=$priorRestore;refuse=$false}}
 foreach($variant in $variants){foreach($heldPart in 'certificate','state'){
  $case=Join-Path $outer ('held-'+$variant.name+'-'+$heldPart)
  $root=Join-Path $case 'program';$state=Join-Path $case 'state';$engine=Join-Path $case 'engine';$backup=Join-Path $case 'snapshot';$package=Join-Path $case 'package'
  foreach($path in $root,$state,$engine,$backup,(Join-Path $engine 'cert')){$null=[IO.Directory]::CreateDirectory($path)}
  TextFile (Join-Path $package 'engine/native-manifest.json') '{"files":{}}'
  $certificate=Join-Path $engine 'cert/dtls-srtp.pem';$dtlsState=Join-Path $state 'dtls-setup';$custom=Join-Path $engine 'cert/custom.pem';TextFile $custom 'UNRELATED-CUSTOM-IDENTITY';$customBefore=TreeCheckpoint $custom
  Save-OpenWebSupport -Backup $backup -PackageRoot $package -Root $root -StateRoot $state -EngineRoot $engine
  $heldFile=if($heldPart -ceq 'certificate'){$certificate}else{Join-Path $dtlsState 'owned/journal.json'};TextFile $heldFile 'PRIVATE-RECOVERY-EVIDENCE'
  $beforeWrites=$script:taskWrites;$handle=[IO.File]::Open($heldFile,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
  try{
   $refused=$false;try{& $variant.restore -Backup $backup -Root $root -StateRoot $state -EngineRoot $engine}catch{$refused=$true}
   AssertControl ($refused -eq $variant.refuse)
   AssertControl ((Test-Path -LiteralPath $heldFile) -and [IO.File]::ReadAllText($heldFile) -ceq 'PRIVATE-RECOVERY-EVIDENCE')
   AssertControl ($script:taskWrites -eq ($beforeWrites+$(if($variant.refuse){0}else{6})))
  }finally{$handle.Dispose()}
  # Once the exact owned handle closes, the unchanged current recovery can
  # complete, proving the refusal was causal rather than a fixture failure.
  Restore-OpenWebSupport -Backup $backup -Root $root -StateRoot $state -EngineRoot $engine
  AssertControl (!(Test-Path -LiteralPath $certificate) -and !(Test-Path -LiteralPath $dtlsState))
  AssertControl ((TreeCheckpoint $custom) -ceq $customBefore)
 }}
 # A missing MSI cert parent is a separate presence contract. Use the actual
 # private journal writer/reader and exact native directory creator to make
 # the ownership proof; unrelated engine files are never copied or deleted.
 function ParentFixture([string]$Parent,[string]$PrivateState,[bool]$CrashIntent=$false){
  $certificate=Join-Path $Parent 'dtls-srtp.pem';$setup=Join-Path $PrivateState 'dtls-setup';New-OpenWebDtlsPrivate $setup
  $id=[Guid]::NewGuid().ToString('N');$transaction=Join-Path $setup $id;New-OpenWebDtlsPrivate $transaction
  $bytes=[Text.UTF8Encoding]::new($false).GetBytes('OWNED-DESIRED-DTLS-KEY');Write-OpenWebDtlsNew (Join-Path $transaction 'desired.pem') $bytes
  $fileSddl=(New-OpenWebDtlsAcl -ServiceSid 'S-1-5-18').GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)
  $parentSddl=(New-OpenWebDtlsAcl -Directory -ServiceSid 'S-1-5-18').GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)
  $journal=[ordered]@{schema=1;kind='openwebpbx-dtls';transaction=$id;computer=[Environment]::MachineName;certificate=$certificate;state='applying';service=@{sid='S-1-5-18';account='LocalSystem';path='fictional';start_mode='Manual'};before_exists=$false;before_sha256=$null;before_sddl=$null;desired_sha256=(Get-OpenWebDtlsHash (Join-Path $transaction 'desired.pem'));desired_sddl=$fileSddl;parent_path=$Parent;parent_before_exists=$false;parent_before_sddl=$null;parent_desired_sddl=$parentSddl;parent_create_intent=$true;parent_created=$false}
  Write-OpenWebDtlsJournal (Join-Path $transaction 'journal.json') $journal
  New-OpenWebDtlsCertificateDirectory $Parent $parentSddl
  if(!$CrashIntent){Set-OpenWebDtlsCertificate $certificate $bytes $fileSddl;$journal.parent_created=$true;$journal.state='committed';Write-OpenWebDtlsJournal (Join-Path $transaction 'journal.json') $journal}
  return @{journal=$journal;directory=$transaction;parent_sddl=$parentSddl;certificate=$certificate}
 }
 function HoldDirectory([string]$Path){
  if(-not ('OpenWebDtlsSupport.HeldDirectory' -as [type])){Add-Type -TypeDefinition @'
using System; using System.ComponentModel; using System.Runtime.InteropServices; using Microsoft.Win32.SafeHandles;
namespace OpenWebDtlsSupport { public static class HeldDirectory {
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern SafeFileHandle CreateFileW(string path,uint access,uint share,IntPtr attributes,uint disposition,uint flags,IntPtr template);
 public static SafeFileHandle Open(string path) {var handle=CreateFileW(path,1,3,IntPtr.Zero,3,0x02200000,IntPtr.Zero);if(handle.IsInvalid){int error=Marshal.GetLastWin32Error();handle.Dispose();throw new Win32Exception(error);}return handle;}
}}
'@};return [OpenWebDtlsSupport.HeldDirectory]::Open($Path)
 }
 foreach($mode in 'committed','crash_intent','held_parent','foreign_child','changed_acl','missing_proof','baseline_proof','duplicate_proof'){
  $case=Join-Path $outer ('parent-'+$mode);$root=Join-Path $case 'program';$state=Join-Path $case 'state';$engine=Join-Path $case 'engine';$backup=Join-Path $case 'snapshot';$package=Join-Path $case 'package'
  foreach($path in $root,$state,$engine,$backup){$null=[IO.Directory]::CreateDirectory($path)}
  TextFile (Join-Path $package 'engine/native-manifest.json') '{"files":{}}';$parent=Join-Path $engine 'cert';$custom=Join-Path $engine 'unrelated-custom.pem';TextFile $custom 'UNRELATED-ENGINE-KEY';$customBefore=TreeCheckpoint $custom
  Save-OpenWebSupport -Backup $backup -PackageRoot $package -Root $root -StateRoot $state -EngineRoot $engine
  $record=Get-Content -LiteralPath (Join-Path $backup 'support-state.json') -Raw|ConvertFrom-Json;AssertControl ($record.DtlsCertificateDirectory.Exists -eq $false)
  $fixture=ParentFixture $parent $state ($mode -ceq 'crash_intent');$certificate=$fixture.certificate;$journalFile=Join-Path $fixture.directory 'journal.json';$held=$null
  switch($mode){
   'held_parent'{$held=HoldDirectory $parent}
   'foreign_child'{TextFile (Join-Path $parent 'foreign.pem') 'UNRELATED-CERTIFICATE'}
   'changed_acl'{& icacls.exe $parent /grant '*S-1-5-19:R'|Out-Null;AssertControl ($LASTEXITCODE -eq 0)}
   'missing_proof'{Remove-Item -LiteralPath $journalFile -Force}
   'baseline_proof'{$baseline=Join-Path (Join-Path $backup 'dtls-setup') $fixture.journal.transaction;$null=[IO.Directory]::CreateDirectory($baseline);Copy-Item -LiteralPath $journalFile -Destination (Join-Path $baseline 'journal.json')}
   'duplicate_proof'{$otherId=[Guid]::NewGuid().ToString('N');$other=Join-Path (Join-Path $state 'dtls-setup') $otherId;New-OpenWebDtlsPrivate $other;Write-OpenWebDtlsNew (Join-Path $other 'desired.pem') ([IO.File]::ReadAllBytes((Join-Path $fixture.directory 'desired.pem')));$duplicate=@{};foreach($key in $fixture.journal.Keys){$duplicate[$key]=$fixture.journal[$key]};$duplicate.transaction=$otherId;Write-OpenWebDtlsJournal (Join-Path $other 'journal.json') $duplicate}
  }
  $beforeWrites=$script:taskWrites;$beforeCert=TreeCheckpoint $certificate;$beforeJournal=if(Test-Path -LiteralPath $journalFile){[IO.File]::ReadAllText($journalFile)}else{''}
  $parentFailure=$null;$refused=$false;try{Restore-OpenWebSupport -Backup $backup -Root $root -StateRoot $state -EngineRoot $engine}catch{$refused=$true;$parentFailure=$_}
  $normal=$mode -in 'committed','crash_intent'
  if($refused -eq $normal){if($null -ne $parentFailure){throw ('Unexpected owned parent recovery '+$mode+': '+$parentFailure.Exception.Message+' '+$parentFailure.ScriptStackTrace)}else{throw ('Expected native parent refusal was not observed for '+$mode)}}
  AssertControl ($refused -ne $normal)
  AssertControl ((TreeCheckpoint $custom) -ceq $customBefore)
  if($normal){AssertControl (!(Test-Path -LiteralPath $parent) -and !(Test-Path -LiteralPath (Join-Path $state 'dtls-setup')));AssertControl ($script:taskWrites -eq $beforeWrites+6)}
  else{
   AssertControl ((Test-Path -LiteralPath $parent) -and $script:taskWrites -eq $beforeWrites)
   if($mode -ceq 'held_parent'){
    AssertControl (!(Test-Path -LiteralPath $certificate) -and (Test-Path -LiteralPath $journalFile));$held.Dispose();$held=$null
    Restore-OpenWebSupport -Backup $backup -Root $root -StateRoot $state -EngineRoot $engine
    AssertControl (!(Test-Path -LiteralPath $parent) -and !(Test-Path -LiteralPath (Join-Path $state 'dtls-setup')))
   }else{
    AssertControl ((TreeCheckpoint $certificate) -ceq $beforeCert)
    if($beforeJournal){AssertControl ([IO.File]::ReadAllText($journalFile) -ceq $beforeJournal)}
    if($mode -ceq 'foreign_child'){AssertControl ([IO.File]::ReadAllText((Join-Path $parent 'foreign.pem')) -ceq 'UNRELATED-CERTIFICATE')}
   }
  }
  if($held){$held.Dispose()}
 }
 foreach($replacement in 'missing','file','junction','ancestor_junction'){
  $case=Join-Path $outer ('existing-parent-'+$replacement);$root=Join-Path $case 'program';$state=Join-Path $case 'state';$engine=Join-Path $case 'engine';$backup=Join-Path $case 'snapshot';$package=Join-Path $case 'package'
  foreach($path in $root,$state,$engine,$backup){$null=[IO.Directory]::CreateDirectory($path)};TextFile (Join-Path $package 'engine/native-manifest.json') '{"files":{}}'
  $parent=Join-Path $engine 'cert';TextFile (Join-Path $parent 'dtls-srtp.pem') 'ORIGINAL-KEY';TextFile (Join-Path $parent 'custom.pem') 'ORIGINAL-CUSTOM-KEY'
  Save-OpenWebSupport -Backup $backup -PackageRoot $package -Root $root -StateRoot $state -EngineRoot $engine
  $foreign=Join-Path $case 'unrelated';$null=[IO.Directory]::CreateDirectory($foreign);$link=$null
  if($replacement -ceq 'ancestor_junction'){
   Move-Item -LiteralPath $engine -Destination (Join-Path $case 'original-engine');TextFile (Join-Path $foreign 'cert/dtls-srtp.pem') 'UNRELATED-KEY';$link=$engine;$null=New-Item -ItemType Junction -Path $link -Target $foreign
  }else{
   Move-Item -LiteralPath $parent -Destination (Join-Path $case 'original-cert')
   if($replacement -ceq 'file'){TextFile $parent 'UNRELATED-PARENT-FILE'}
   if($replacement -ceq 'junction'){TextFile (Join-Path $foreign 'dtls-srtp.pem') 'UNRELATED-KEY';$link=$parent;$null=New-Item -ItemType Junction -Path $link -Target $foreign}
  }
  $foreignBefore=TreeCheckpoint $foreign;$writesBefore=$script:taskWrites;$refused=$false
  try{
   try{Restore-OpenWebSupport -Backup $backup -Root $root -StateRoot $state -EngineRoot $engine}catch{$refused=$true}
   AssertControl ($refused -and $script:taskWrites -eq $writesBefore)
   AssertControl ((TreeCheckpoint $foreign) -ceq $foreignBefore)
   if($replacement -ceq 'missing'){AssertControl (!(Test-Path -LiteralPath $parent))}
   if($replacement -ceq 'file'){AssertControl ([IO.File]::ReadAllText($parent) -ceq 'UNRELATED-PARENT-FILE')}
  }finally{if($link -and (Test-Path -LiteralPath $link)){[IO.Directory]::Delete($link,$false)}}
 }
 if($null -ne $priorRestore){
  $case=Join-Path $outer 'old-missing-parent';$root=Join-Path $case 'program';$state=Join-Path $case 'state';$engine=Join-Path $case 'engine';$backup=Join-Path $case 'snapshot';$package=Join-Path $case 'package'
  foreach($path in $root,$state,$engine,$backup){$null=[IO.Directory]::CreateDirectory($path)};TextFile (Join-Path $package 'engine/native-manifest.json') '{"files":{}}';$parent=Join-Path $engine 'cert'
  Save-OpenWebSupport -Backup $backup -PackageRoot $package -Root $root -StateRoot $state -EngineRoot $engine;$fixture=ParentFixture $parent $state
  & $priorRestore -Backup $backup -Root $root -StateRoot $state -EngineRoot $engine
  AssertControl ((Test-Path -LiteralPath $parent) -and !(Test-Path -LiteralPath $fixture.certificate) -and !(Test-Path -LiteralPath (Join-Path $state 'dtls-setup')))
 }
}finally{
 if((Get-Variable -Name held -ErrorAction SilentlyContinue) -and $null -ne $held){$held.Dispose();$held=$null}
 if($null -eq $envBefore){Remove-Item Env:\OPENSSL_CONF -ErrorAction SilentlyContinue}else{$env:OPENSSL_CONF=$envBefore}
 if(Test-Path -LiteralPath $outer){Remove-Item -LiteralPath $outer -Recurse -Force}
}
AssertControl (!(Test-Path -LiteralPath $outer))
[Console]::Out.WriteLine((@{state='passed';checks=$script:checks;native_file_security=$true;installed_resources_accessed=$false;calling_or_database_service_actions=$false;task_boundary='explicit unrelated doubles';paired_previous_absence_negatives=[bool]$PreviousSupport}|ConvertTo-Json -Compress))
