# Native, isolated recovery controls. No installed paths, services or tasks.
param([Parameter(Mandatory)][string]$SourceDirectory,[Parameter(Mandatory)][string]$FixtureRoot)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if([Environment]::OSVersion.Platform-ne[PlatformID]::Win32NT){throw 'Actual Windows is required'}
$script:checks=0;$script:cases=@();$script:caseIndex=0;$script:locks=@();$started=[DateTime]::UtcNow
function Check([bool]$Value,[string]$Label){if(!$Value){throw ('Native consumed-CDR control failed: '+$Label)};$script:checks++}
$fixture=[IO.Path]::GetFullPath($FixtureRoot)
Check ($fixture-cmatch '^C:\\QCR-[a-f0-9]{8}\\data$') 'external fixture path'
Check (!(Test-Path -LiteralPath $fixture)) 'fresh fixture'
function Directory([string]$Path){$acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetSecurityDescriptorSddlForm('O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)');[void][IO.DirectoryInfo]::new($Path).Create($acl)}
Directory $fixture
. (Join-Path $SourceDirectory 'UpgradeRecovery.Common.ps1')
. (Join-Path $SourceDirectory 'CallRecords.Common.ps1')
. (Join-Path $SourceDirectory 'File-Security.ps1')
# The sole adapter replaces PHP directory discovery, never security or IO.
function Get-OpenWebCallRecordPlan {param($PackageRoot,$Root,$EngineRoot)return $script:casePlan}
function Hash([string]$Path){return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Acl([string]$Path){return (Get-Acl -LiteralPath $Path).Sddl}
function NewCase([string]$Name,[switch]$Custom,[switch]$Nested){
 $script:caseIndex++;$base=Join-Path $fixture ($script:caseIndex.ToString('D2')+'-'+$Name);Directory $base
 $state=Join-Path $base 'state';$config=Join-Path $base 'fusionpbx';$engine=Join-Path $base 'engine'
 foreach($p in $state,$config,$engine){Directory $p};[IO.File]::WriteAllText((Join-Path $config 'config.conf'),'native-fixture-only')
 $log=if($Custom){Join-Path $base 'custom-log'}else{Join-Path $engine 'log'};Directory $log;$spool=Join-Path $log 'xml_cdr';Directory $spool
 foreach($child in 'archive','failed'){Directory (Join-Path $spool $child)}
 $survivor=Join-Path $spool 'survivor.keep';[IO.File]::WriteAllText($survivor,'original native survivor bytes')
 $record=Join-Path $(if($Nested){Join-Path $spool 'archive'}else{$spool}) 'a_11111111-2222-3333-4444-555555555555.cdr.xml';[IO.File]::WriteAllText($record,'<cdr>owned</cdr>')
 [IO.File]::WriteAllBytes((Join-Path $spool '.openweb-import.lock'),[byte[]]@())
 $lock=[IO.File]::Open((Join-Path $state 'upgrade.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$script:locks+=,$lock
 $script:casePlan=@{Path=$spool;Log=$log;LogExists=$true}
 $snapshot=Get-OpenWebCallRecordAccessSnapshot -PackageRoot $SourceDirectory -Root $base -StateRoot $state -EngineRoot $engine -MaintenanceLock $lock
 $old=Acl $survivor;$bytes=Hash $survivor;$acl=Get-Acl -LiteralPath $survivor
 $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-19'),[Security.AccessControl.FileSystemRights]::Read,[Security.AccessControl.AccessControlType]::Allow));Set-Acl -LiteralPath $survivor -AclObject $acl
 Check ((Acl $survivor)-cne$old) ($Name+' survivor changed only by fixture')
 return @{Name=$Name;Base=$base;State=$state;Config=$config;Engine=$engine;Log=$log;Spool=$spool;Survivor=$survivor;Record=$record;Lock=$lock;Snapshot=$snapshot;OriginalAcl=$old;ChangedAcl=(Acl $survivor);Hash=$bytes}
}
function Restore($Case){Restore-OpenWebCallRecordAccess -Snapshot $Case.Snapshot -StateRoot $Case.State -EngineRoot $Case.Engine -MaintenanceLock $Case.Lock}
function Denied($Case){
 $caught=$null;try{Restore $Case}catch{$caught=$_}
 Check ($null-ne$caught) ($Case.Name+' refused')
 Check ((Acl $Case.Survivor)-ceq$Case.ChangedAcl) ($Case.Name+' no prevalidation security write')
 Check ((Hash $Case.Survivor)-ceq$Case.Hash) ($Case.Name+' survivor bytes unchanged')
 $script:cases+=@{name=$Case.Name;state='denied';exceptionType=$caught.Exception.GetBaseException().GetType().Name}
}
function Link([string]$Path,[string]$Target,[switch]$Junction,[switch]$Hard){
 $options=@('/c','mklink');if($Junction){$options+='/J'}elseif($Hard){$options+='/H'};$options+=@($Path,$Target)
 $global:LASTEXITCODE=$null;& "$env:SystemRoot/System32/cmd.exe" @options|Out-Null;Check ($global:LASTEXITCODE-eq0) 'actual native link created'
}
try{
 foreach($name in 'consumed-prefixed','consumed-plain'){
  $c=NewCase $name
  if($name-ceq'consumed-plain'){$plain=Join-Path $c.Spool '11111111-2222-3333-4444-555555555555.cdr.xml';Move-Item -LiteralPath $c.Record -Destination $plain;foreach($e in $c.Snapshot.Entries){if($e.Path-ceq$c.Record){$e.Path=$plain}};$c.Record=$plain}
  Remove-Item -LiteralPath $c.Record;Restore $c
  Check (!(Test-Path -LiteralPath $c.Record)) ($name+' never recreates XML')
  Check ((Acl $c.Survivor)-ceq$c.OriginalAcl) ($name+' exact original survivor SDDL')
  Check ((Hash $c.Survivor)-ceq$c.Hash) ($name+' exact original survivor bytes')
  $script:cases+=@{name=$name;state='passed'}
 }
 $c=NewCase 'present-record';$recordHash=Hash $c.Record;$recordAcl=Acl $c.Record;Restore $c
 Check ((Hash $c.Record)-ceq$recordHash-and(Acl $c.Record)-ceq$recordAcl-and(Acl $c.Survivor)-ceq$c.OriginalAcl) 'present record bytes and SDDL exact';$script:cases+=@{name=$c.Name;state='passed'}
 foreach($name in 'missing-importer','missing-arbitrary','missing-upper','missing-noncanonical','missing-directory','missing-nested','custom-spool','malformed-leaf-sddl','untrusted-leaf-owner','untrusted-current-spool-owner','existing-file-type','existing-directory-type','existing-hardlink','dangling-file-symlink','spool-junction','ancestor-junction','existing-access-denied','existing-sharing-error'){
  $c=if($name-ceq'custom-spool'){NewCase $name -Custom}elseif($name-ceq'missing-nested'){NewCase $name -Nested}else{NewCase $name}
  switch($name){
   'missing-importer' {Remove-Item -LiteralPath (Join-Path $c.Spool '.openweb-import.lock')}
   'missing-arbitrary' {Remove-Item -LiteralPath $c.Record;foreach($e in $c.Snapshot.Entries){if($e.Path-ceq$c.Record){$e.Path=Join-Path $c.Spool 'arbitrary.txt'}}}
   'missing-upper' {Remove-Item -LiteralPath $c.Record;foreach($e in $c.Snapshot.Entries){if($e.Path-ceq$c.Record){$e.Path=Join-Path $c.Spool 'a_AAAAAAAA-2222-3333-4444-555555555555.cdr.xml'}}}
   'missing-noncanonical' {Remove-Item -LiteralPath $c.Record;foreach($e in $c.Snapshot.Entries){if($e.Path-ceq$c.Record){$e.Path=Join-Path $c.Spool 'a_11111111-2222-3333-4444-555555555555.cdr.xml.extra'}}}
   'missing-directory' {Remove-Item -LiteralPath (Join-Path $c.Spool 'archive')}
   'missing-nested' {Remove-Item -LiteralPath $c.Record}
   'custom-spool' {Remove-Item -LiteralPath $c.Record}
   'malformed-leaf-sddl' {Remove-Item -LiteralPath $c.Record;foreach($e in $c.Snapshot.Entries){if($e.Path-ceq$c.Record){$e.Sddl='invalid'}}}
   'untrusted-leaf-owner' {Remove-Item -LiteralPath $c.Record;foreach($e in $c.Snapshot.Entries){if($e.Path-ceq$c.Record){$d=[Security.AccessControl.RawSecurityDescriptor]::new($e.Sddl);$d.Owner=[Security.Principal.SecurityIdentifier]::new('S-1-5-17');$e.Sddl=$d.GetSddlForm([Security.AccessControl.AccessControlSections]::All)}}}
   'untrusted-current-spool-owner' {Remove-Item -LiteralPath $c.Record;$d=[Security.AccessControl.RawSecurityDescriptor]::new((Acl $c.Spool));$d.Owner=[Security.Principal.SecurityIdentifier]::new('S-1-5-17');Set-OpenWebFileSddl -LiteralPath $c.Spool -Sddl $d.GetSddlForm([Security.AccessControl.AccessControlSections]::All)}
   'existing-file-type' {Remove-Item -LiteralPath $c.Record;Directory $c.Record}
   'existing-directory-type' {$path=Join-Path $c.Spool 'archive';Remove-Item -LiteralPath $path;[IO.File]::WriteAllText($path,'now an ordinary file')}
   'existing-hardlink' {Link (Join-Path $c.Base 'hardlink-copy.xml') $c.Record -Hard}
   'dangling-file-symlink' {Remove-Item -LiteralPath $c.Record;Link $c.Record (Join-Path $c.Base 'missing-target.xml')}
   'spool-junction' {Remove-Item -LiteralPath $c.Spool -Recurse -Force;$target=Join-Path $c.Base 'junction-target';Directory $target;[IO.File]::WriteAllText((Join-Path $target 'survivor.keep'),'original native survivor bytes');$c.ChangedAcl=Acl (Join-Path $target 'survivor.keep');Link $c.Spool $target -Junction}
   'ancestor-junction' {Remove-Item -LiteralPath $c.Log -Recurse -Force;$target=Join-Path $c.Base 'ancestor-target';Directory $target;Directory (Join-Path $target 'xml_cdr');[IO.File]::WriteAllText((Join-Path $target 'xml_cdr/survivor.keep'),'original native survivor bytes');$c.ChangedAcl=Acl (Join-Path $target 'xml_cdr/survivor.keep');Link $c.Log $target -Junction}
   'existing-access-denied' {$d=[Security.AccessControl.RawSecurityDescriptor]::new((Acl $c.Record));$ace=[Security.AccessControl.CommonAce]::new([Security.AccessControl.AceFlags]::None,[Security.AccessControl.AceQualifier]::AccessDenied,1,[Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'),$false,$null);$d.DiscretionaryAcl.InsertAce(0,$ace);Set-OpenWebFileSddl -LiteralPath $c.Record -Sddl $d.GetSddlForm([Security.AccessControl.AccessControlSections]::All)}
   'existing-sharing-error' {$hold=[IO.File]::Open($c.Record,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$script:locks+=,$hold}
  }
  Denied $c
 }
 Check (([DateTime]::UtcNow-$started).TotalSeconds-lt120) 'original native control bound'
 [ordered]@{passed=$true;checks=$checks;cases=$cases;elapsedSeconds=([DateTime]::UtcNow-$started).TotalSeconds;actualNativeFilesystemAclAndLinks=$true;actualExclusiveOwnedMaintenanceLock=$true;onlyPhpDirectoryPlanAdapted=$true;missingAdmissionOwnerContract='captured-missing-leaf-and-current-spool';productPathsOrServicesOrTasksTouched=$false}|ConvertTo-Json -Depth 10 -Compress
}finally{foreach($h in $script:locks){if($h){$h.Dispose()}}}
