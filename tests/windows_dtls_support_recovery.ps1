param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
# Execute the actual support capture/recovery functions against an isolated
# Windows temporary installation. Adapters replace only unrelated IIS, optional
# capability and Task Scheduler boundaries; file contents and NTFS ACLs are real.
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'This regression requires native Windows file security.'}
$script:checks=0;$script:taskReads=0;$script:taskWrites=0
function AssertControl([bool]$Value){if(!$Value){throw ('DTLS support recovery control failed at line '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
. (Join-Path $SourceRoot 'packaging/windows/Support-Recovery.ps1')
. (Join-Path $SourceRoot 'packaging/windows/File-Security.ps1')
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
}finally{
 if($null -eq $envBefore){Remove-Item Env:\OPENSSL_CONF -ErrorAction SilentlyContinue}else{$env:OPENSSL_CONF=$envBefore}
 if(Test-Path -LiteralPath $outer){Remove-Item -LiteralPath $outer -Recurse -Force}
}
AssertControl (!(Test-Path -LiteralPath $outer))
[Console]::Out.WriteLine((@{state='passed';checks=$script:checks;native_file_security=$true;installed_resources_accessed=$false;calling_or_database_service_actions=$false;task_boundary='explicit unrelated doubles'}|ConvertTo-Json -Compress))
