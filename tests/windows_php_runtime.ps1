[CmdletBinding()]
param([Parameter(Mandatory)][string]$SourceRoot,[Parameter(Mandatory)][string]$WorkRoot,[string]$OriginalRuntime='C:\OpenWebPBX\php')
# Real native PHP, ZIP, robocopy, NTFS and held-file checks in a private copy.
# No installed binary, service, pool, task or database is changed.
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'Native Windows is required.'}
$checks=0
function Check([bool]$Value){$script:checks++;if(!$Value){throw ('PHP runtime control failed at line '+(Get-PSCallStack)[1].ScriptLineNumber)}}
function CopyTree([string]$From,[string]$To,[switch]$Mirror){
 $mode=if($Mirror){'/MIR'}else{'/E'}
 & robocopy.exe $From $To $mode /COPY:DAT /DCOPY:T /R:0 /W:0 /NFL /NDL /NJH /NJS /NP|Out-Null
 if($LASTEXITCODE -ge 8){throw 'The owned native runtime copy failed.'}
}
function Snapshot([string]$Directory){
 $rows=@{}
 foreach($item in @((Get-Item -LiteralPath $Directory -Force))+@(Get-ChildItem -LiteralPath $Directory -Force -Recurse)){
  Check (!($item.Attributes -band [IO.FileAttributes]::ReparsePoint))
  $name=$item.FullName.Substring($Directory.Length)
  $rows[$name]=@{Directory=[bool]$item.PSIsContainer;Sddl=(Get-Acl -LiteralPath $item.FullName).Sddl;Hash=if($item.PSIsContainer){''}else{(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash}}
 }
 return $rows
}
function Same($Before,$After){
 Check ($Before.Count -eq $After.Count)
 foreach($key in $Before.Keys){Check ($After.ContainsKey($key));foreach($field in 'Directory','Sddl','Hash'){Check ($Before[$key][$field] -ceq $After[$key][$field])}}
}
function RestoreFixture($Snapshot,[string]$Backup,[string]$Directory){
 CopyTree $Backup $Directory -Mirror
 foreach($key in @($Snapshot.Keys|Sort-Object @{Expression={if($Snapshot[$_].Directory){0}else{1}}},Length)){
  Set-OpenWebFileSddl -LiteralPath ($Directory+$key) -Sddl $Snapshot[$key].Sddl
 }
 Same $Snapshot (Snapshot $Directory)
}
. (Join-Path $SourceRoot 'packaging/windows/PhpRuntime.Common.ps1')
. (Join-Path $SourceRoot 'packaging/windows/File-Security.ps1')
$null=Assert-OpenWebPhpOrdinary -Path $WorkRoot -Directory
$null=Assert-OpenWebPhpOrdinary -Path $OriginalRuntime -Directory
$outer=Join-Path $WorkRoot ('php-runtime-'+[Guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($outer)
& icacls.exe $outer /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F'|Out-Null;Check ($LASTEXITCODE -eq 0)
$prepared=$null;$hold=$null;$phase='prepare'
try{
 $updates=Join-Path $outer 'updates';$null=[IO.Directory]::CreateDirectory($updates)
 $prepared=Prepare-OpenWebPhpRuntime -UpdatesRoot $updates
 Check ($prepared.Version -ceq '8.4.27' -and $prepared.Files.Count -gt 50)
 $root=Join-Path $outer 'program';$php=Join-Path $root 'php';$sealed=Join-Path $outer 'sealed';$backup=Join-Path $sealed 'php'
 CopyTree $OriginalRuntime $php
 [IO.File]::WriteAllText((Join-Path $php 'php.ini'),"; private fixture configuration`r`nmemory_limit=373M`r`n",[Text.UTF8Encoding]::new($false))
 $custom=Join-Path $php 'ext/owned-custom-extension.fixture';[IO.File]::WriteAllText($custom,'PRESERVE-CUSTOM-EXTENSION')
 $descriptor='O:BAG:BAD:PAI(A;;FA;;;BA)(A;;FA;;;SY)(A;;FR;;;BU)';$acl=[Security.AccessControl.FileSecurity]::new();$acl.SetSecurityDescriptorSddlForm($descriptor);Set-Acl -LiteralPath $custom -AclObject $acl
 $before=Snapshot $php;CopyTree $php $backup
 $sealedFiles=@{};$sealedAcls=@{}
 foreach($key in $before.Keys){$sealedAcls[$php+$key]=$before[$key].Sddl;if(!$before[$key].Directory){$sealedFiles['php/'+$key.TrimStart('\').Replace('\','/')]=$before[$key].Hash}}
 [IO.File]::WriteAllText((Join-Path $sealed 'backup-manifest.json'),(@{schema=1;files=$sealedFiles}|ConvertTo-Json -Depth 5))
 [IO.File]::WriteAllText((Join-Path $sealed 'support-state.json'),(@{schema=1;Acls=$sealedAcls}|ConvertTo-Json -Depth 5))
 $phase='sealed_backup';Check (Test-OpenWebPhpBackup -Backup $sealed -Root $root)
 $extra=Join-Path $backup 'unsealed-extra.fixture';[IO.File]::WriteAllText($extra,'UNSEALED-EXTRA')
 $refused=$false;try{Test-OpenWebPhpBackup -Backup $sealed -Root $root|Out-Null}catch{$refused=$true};Check $refused;[IO.File]::Delete($extra)
 $extra=Join-Path $backup 'unsealed-empty';$null=[IO.Directory]::CreateDirectory($extra)
 $refused=$false;try{Test-OpenWebPhpBackup -Backup $sealed -Root $root|Out-Null}catch{$refused=$true};Check $refused;[IO.Directory]::Delete($extra)
 $legacy=Join-Path $outer 'legacy';$null=[IO.Directory]::CreateDirectory($legacy)
 [IO.File]::WriteAllText((Join-Path $legacy 'backup-manifest.json'),'{"schema":1,"files":{}}')
 Check (!(Test-OpenWebPhpBackup -Backup $legacy -Root $root));$null=[IO.Directory]::CreateDirectory((Join-Path $legacy 'php'))
 $refused=$false;try{Test-OpenWebPhpBackup -Backup $legacy -Root $root|Out-Null}catch{$refused=$true};Check $refused
 $oldVersion=(& (Join-Path $php 'php.exe') -n -r 'echo PHP_VERSION;') -join '';Check ($LASTEXITCODE -eq 0)
 $phase='changed_stage_refusal';$expected=$prepared.Files['php.exe'];$prepared.Files['php.exe']='0'*64
 $refused=$false;try{Install-OpenWebPhpRuntime -Prepared $prepared -Root $root}catch{$refused=$true};Check $refused;Same $before (Snapshot $php);$prepared.Files['php.exe']=$expected
 $phase='unexpected_config_refusal';$injected=Join-Path $prepared.Directory 'php.ini';[IO.File]::WriteAllText($injected,'UNLISTED-CONFIG-MUST-NOT-COPY')
 $refused=$false;try{Install-OpenWebPhpRuntime -Prepared $prepared -Root $root}catch{$refused=$true};Check $refused;Same $before (Snapshot $php);[IO.File]::Delete($injected)
 $phase='hardlink_refusal';$null=New-Item -ItemType HardLink -Path $injected -Target (Join-Path $php 'php.ini')
 $refused=$false;try{Install-OpenWebPhpRuntime -Prepared $prepared -Root $root}catch{$refused=$true};Check $refused;Same $before (Snapshot $php);[IO.File]::Delete($injected)
 $phase='native_upgrade';Install-OpenWebPhpRuntime -Prepared $prepared -Root $root
 $newVersion=(& (Join-Path $php 'php.exe') -n -r 'echo PHP_VERSION;') -join '';Check ($LASTEXITCODE -eq 0 -and $newVersion -ceq '8.4.27')
 foreach($name in 'php.ini','ext\owned-custom-extension.fixture'){$after=Snapshot $php;foreach($field in 'Hash','Sddl'){Check ($before['\'+$name][$field] -ceq $after['\'+$name][$field])}}
 $phase='complete_runtime_rollback';RestoreFixture $before $backup $php
 Check (((& (Join-Path $php 'php.exe') -n -r 'echo PHP_VERSION;') -join '') -ceq $oldVersion)
 $phase='held_runtime_refusal';$hold=[IO.File]::Open((Join-Path $php 'php8.dll'),'Open','Read','Read')
 $refused=$false;try{Install-OpenWebPhpRuntime -Prepared $prepared -Root $root}catch{$refused=$true};Check $refused
 $hold.Dispose();$hold=$null;RestoreFixture $before $backup $php
 $phase='retry';Install-OpenWebPhpRuntime -Prepared $prepared -Root $root;Check (((& (Join-Path $php 'php.exe') -n -r 'echo PHP_VERSION;') -join '') -ceq '8.4.27')
 $phase='linked_target_refusal';$linked=Join-Path $outer 'linked-program';$null=[IO.Directory]::CreateDirectory($linked)
 $null=New-Item -ItemType Junction -Path (Join-Path $linked 'php') -Target $php
 $unchanged=Snapshot $php;$refused=$false;try{Install-OpenWebPhpRuntime -Prepared $prepared -Root $linked}catch{$refused=$true};Check $refused;Same $unchanged (Snapshot $php)
 [IO.Directory]::Delete((Join-Path $linked 'php'))
 $phase='complete';@{schema=1;state='passed';actual_native=$true;checks=$checks;old_version=$oldVersion;new_version=$newVersion;vendor_files=$prepared.Files.Count;installed_server_changed=$false;full_installer_acceptance='reported separately'}|ConvertTo-Json -Compress
}catch{
 @{schema=1;state='failed';phase=$phase;checks=$checks;error_type=$_.Exception.GetType().Name;source_line=[int]$_.InvocationInfo.ScriptLineNumber;installed_server_changed=$false}|ConvertTo-Json -Compress
 throw
}finally{
 if($hold){$hold.Dispose()}
 # Both paths are generated children inside the private, owned test leaf.
 if(Test-Path -LiteralPath $outer){Remove-Item -LiteralPath $outer -Recurse -Force -ErrorAction Stop}
}
