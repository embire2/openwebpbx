param([string]$SourceRoot='')
# Exact-source success ACL controls. Native mode uses only a unique temporary
# tree, never installed PBX files, services, tasks, IIS or a database.
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
if([string]::IsNullOrWhiteSpace($SourceRoot)){$SourceRoot=Split-Path $PSScriptRoot -Parent}
if($PSVersionTable.PSEdition -eq 'Desktop'){$env:PSModulePath=$PSHOME+'\Modules;'+[Environment]::GetFolderPath('ProgramFiles')+'\WindowsPowerShell\Modules'}
$script:checks=0;$native=[Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
function AssertControl([bool]$Value){if(!$Value){throw ('Upgrade permission control failed at source line '+(@(Get-PSCallStack)[1].ScriptLineNumber))};$script:checks++}
$inheritedAce={([int]$_.AceFlags -band [int][Security.AccessControl.AceFlags]::Inherited) -ne 0}
$explicitAce={([int]$_.AceFlags -band [int][Security.AccessControl.AceFlags]::Inherited) -eq 0}
foreach($value in 0,16,17,1){
 $ace=[pscustomobject]@{AceFlags=[Security.AccessControl.AceFlags]$value}
 AssertControl ((@($ace|Where-Object $inheritedAce).Count -eq 1) -eq (($value -band 16) -ne 0))
 AssertControl ((@($ace|Where-Object $explicitAce).Count -eq 1) -eq (($value -band 16) -eq 0))
}
function ParseSource([string]$Path){
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
 AssertControl ($errors.Count -eq 0);return $ast
}
$supportPath=Join-Path $SourceRoot 'packaging/windows/Support-Recovery.ps1'
$upgradePath=Join-Path $SourceRoot 'packaging/windows/Upgrade-OpenWebPBX.ps1'
$support=Get-Content -LiteralPath $supportPath -Raw;$ast=ParseSource $supportPath
$names=@('Get-OpenWebUpgradePermissionScope','Get-OpenWebUpgradePermissions','Restore-OpenWebUpgradePermissions')
foreach($name in $names){
 $nodes=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true))
 AssertControl ($nodes.Count -eq 1)
 $body=$nodes[0].Extent.Text
 if(!$native -and $name -ceq 'Restore-OpenWebUpgradePermissions'){
  # Only the native dependency load is omitted in portable mode; capture,
  # validation, sorting and setter invocation are the exact production body.
  $dependency=". (Join-Path `$PSScriptRoot 'File-Security.ps1')"
  AssertControl (@([regex]::Matches($body,[regex]::Escape($dependency))).Count -eq 1)
  $body=$body.Replace($dependency,'')
  # RawSecurityDescriptor is Windows-only. The native run executes the real
  # constructor; portable fixtures mock only that constructor boundary.
  $constructor='[Security.AccessControl.RawSecurityDescriptor]::new($permission.Sddl)'
  AssertControl (@([regex]::Matches($body,[regex]::Escape($constructor))).Count -eq 1)
  $body=$body.Replace($constructor,'(ReadControlDescriptor $permission.Sddl)')
 }
 if($native){. $supportPath;break}else{Invoke-Expression $body}
}
$upgrade=Get-Content -LiteralPath $upgradePath -Raw;$upgradeAst=ParseSource $upgradePath
$hardening=@($upgradeAst.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Run' -and $node.Extent.Text -like 'Run icacls.exe @($root,*'},$true))
AssertControl ($hardening.Count -eq 1)
$hardeningGuard=$hardening[0].Parent
while($hardeningGuard -and $hardeningGuard -isnot [Management.Automation.Language.IfStatementAst]){$hardeningGuard=$hardeningGuard.Parent}
AssertControl ($hardeningGuard -and $hardeningGuard.Extent.Text.Contains('if(!(Test-OpenWebProgramRootPolicy -Root $root))'))
$capture=$upgrade.IndexOf('$upgradePermissions=@(Get-OpenWebUpgradePermissions')
$firstWriter=$upgrade.IndexOf('foreach ($part in ''web'',''server'',''desktop'',''acme'')')
$replay=$upgrade.IndexOf('Restore-OpenWebUpgradePermissions -Permissions $upgradePermissions')
$start=$upgrade.IndexOf('StartPbx; ResumeEngine; $stopped = $false; CheckHealth $version')
AssertControl ($capture -gt $hardening[0].Extent.EndOffset -and $capture -lt $firstWriter)
AssertControl ($replay -gt $upgrade.IndexOf("SaveJournal 'validating'") -and $replay -lt $start)
foreach($writer in 'configure-notifications.ps1','Install-NativeEngine.ps1','Install-LocalCodec.ps1','Configure-PHP.ps1','configure-music.php','Install-Backups.ps1','Install-MailQueue.ps1','Install-TenantDomains.ps1','Install-PhoneHealth.ps1'){
 $position=$upgrade.LastIndexOf('"$payload\'+$writer+'"')
 AssertControl ($position -gt $capture -and $position -lt $replay)
}
AssertControl ($upgrade.Contains('Restore-OpenWebSupport -Backup $Backup -Root $root -StateRoot $private -EngineRoot $switch'))
foreach($name in $names){
 $node=$ast.Find({param($value)$value -is [Management.Automation.Language.FunctionDefinitionAst] -and $value.Name -ceq $name},$true)
 foreach($forbidden in 'Copy-Item','Remove-Item','WriteAllText','Register-ScheduledTask','TaskSecurity','support-state.json','installation.json','updater-install.json','CommonAcl'){
  AssertControl (!$node.Extent.Text.Contains($forbidden))
 }
}
$outer=Join-Path ([IO.Path]::GetTempPath()) ('openweb-upgrade-permissions-'+[Guid]::NewGuid().ToString('N'))
$root=Join-Path $outer 'legacy/program';$state=Join-Path $outer 'state';$engine=Join-Path $outer 'engine'
$script:fakeAcls=@{};$script:writes=New-Object 'Collections.Generic.List[object]'
$originalSddl='O:BAG:BAD:PAI(A;;FA;;;BA)(A;;FA;;;SY)(A;;FR;;;AU)'
$hardenedSddl='O:BAG:BAD:PAI(A;;FA;;;BA)(A;;FA;;;SY)(A;;FR;;;BU)'
$changedSddl='O:BAG:BAD:PAI(A;;FA;;;BA)(A;;FA;;;SY)(A;;FR;;;LS)'
if(!$native){
 # This portable legacy filesystem fixture is deliberately nonmatching. The
 # actual descriptor policy has separate native and portable predicate controls.
 function Test-OpenWebProgramRootPolicy {return $false}
 function ReadControlDescriptor([string]$Value){
  if($Value -notin @($originalSddl,$hardenedSddl,$changedSddl)){throw 'Portable descriptor fixture refused.'}
  @{Owner='fixture-owner';Group='fixture-group';ControlFlags=4;BinaryLength=96}
 }
 function Get-Acl {param([string]$LiteralPath,[switch]$Audit,[object]$ErrorAction)
  $path=[IO.Path]::GetFullPath($LiteralPath)
  if(!$script:fakeAcls.ContainsKey($path)){$script:fakeAcls[$path]=$originalSddl}
  @{Sddl=$script:fakeAcls[$path]}
 }
 function Set-OpenWebFileSddl {param([string]$LiteralPath,[string]$Sddl)
  $script:writes.Add(@{Path=$LiteralPath;Sddl=$Sddl});$script:fakeAcls[$LiteralPath]=$Sddl
 }
}
function CurrentAcl([string]$Path){(Get-Acl -LiteralPath $Path -ErrorAction Stop).Sddl}
function HasAuthenticatedUsersWrite([string]$Sddl){
 $descriptor=[Security.AccessControl.RawSecurityDescriptor]::new($Sddl)
 foreach($ace in $descriptor.DiscretionaryAcl){
  if($ace -is [Security.AccessControl.CommonAce] -and $ace.AceQualifier -eq [Security.AccessControl.AceQualifier]::AccessAllowed -and $ace.SecurityIdentifier.Value -ceq 'S-1-5-11' -and ($ace.AccessMask -band 0x000d0116)){return $true}
 }
 return $false
}
function NewText([string]$Path,[string]$Text='original'){
 $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path));[IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))
 if(!$native){$script:fakeAcls[$Path]=$originalSddl}
}
function AlterAcl([string]$Path){
 if($native){$grant=if((Get-Item -LiteralPath $Path -Force).PSIsContainer){'*S-1-5-19:(OI)(CI)R'}else{'*S-1-5-19:R'};& icacls.exe $Path /grant $grant|Out-Null;AssertControl ($LASTEXITCODE -eq 0)}
 else{$script:fakeAcls[$Path]=$changedSddl}
}
function CopyRecord($Record){@{Path=$Record.Path;Directory=$Record.Directory;Sddl=$Record.Sddl}}
function Refuse($Records){
 $refused=$false;try{Restore-OpenWebUpgradePermissions -Permissions $Records -Root $root -StateRoot $state -EngineRoot $engine}catch{$refused=$true}
 AssertControl $refused
}
try{
 $null=[IO.Directory]::CreateDirectory($outer)
 if($native){& icacls.exe $outer /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F'|Out-Null;AssertControl ($LASTEXITCODE -eq 0)}
 $php=Join-Path $root 'php/php.ini';$track=Join-Path $state 'storage/openweb-music/16000/lofi-beat-loop-schmoop.wav'
 $notification=Join-Path $state 'mobile-notifications/config.json';$recording=Join-Path $state 'storage/recordings/owned.wav'
 foreach($path in $php,$track,$notification,$recording,(Join-Path $root 'php/extras/ssl/openssl.cnf'),(Join-Path $root 'php/extras/ssl/cacert.pem'),(Join-Path $state 'native-engine.json'),(Join-Path $state 'local-codec.json'),(Join-Path $state 'meet-ca.pem'),(Join-Path $state 'meet-proxy.json'),(Join-Path $state 'phone-health-instance.json'),(Join-Path $state 'stun.json'),(Join-Path $engine 'libbcg729.dll')){NewText $path}
 # Reproduce a legacy inherited writable program tree; capture only after the
 # exact product hardening statement, never from the rollback snapshot.
 if($native){& icacls.exe (Join-Path $outer 'legacy') /grant '*S-1-5-11:(OI)(CI)M'|Out-Null;AssertControl ($LASTEXITCODE -eq 0)}
 $preHardening=CurrentAcl $php
 if($native){AssertControl ((HasAuthenticatedUsersWrite $preHardening) -and !(Test-OpenWebProgramRootPolicy -Root $root))}
 if($native){function Run([string]$Exe,[string[]]$Arguments){& $Exe @Arguments|Out-Null;if($LASTEXITCODE){throw 'Owned hardening control failed.'}};& ([scriptblock]::Create($hardeningGuard.Extent.Text));AssertControl (Test-OpenWebProgramRootPolicy -Root $root)}
 else{$script:fakeAcls[$php]=$hardenedSddl;$script:fakeAcls[$root]=$hardenedSddl}
 $postHardening=CurrentAcl $php;$programAcl=CurrentAcl $root
 AssertControl ($preHardening -cne $postHardening)
 if($native){AssertControl (!(HasAuthenticatedUsersWrite $postHardening))}
 $permissions=@(Get-OpenWebUpgradePermissions -Root $root -StateRoot $state -EngineRoot $engine)
 AssertControl (@($permissions|Where-Object {$_.Path -ceq $php -and $_.Sddl -ceq $postHardening}).Count -eq 1)
 AssertControl (@($permissions|Where-Object {$_.Path -ceq $recording -or $_.Path -ceq $root}).Count -eq 0)
 $scope=Get-OpenWebUpgradePermissionScope -Root $root -StateRoot $state -EngineRoot $engine
 $expectedFiles=@($php,(Join-Path $root 'php/extras/ssl/openssl.cnf'),(Join-Path $root 'php/extras/ssl/cacert.pem'),(Join-Path $state 'native-engine.json'),(Join-Path $state 'local-codec.json'),(Join-Path $state 'meet-ca.pem'),(Join-Path $state 'meet-proxy.json'),(Join-Path $state 'phone-health-instance.json'),(Join-Path $state 'stun.json'),(Join-Path $engine 'libbcg729.dll'))
 AssertControl ($scope.Files.Count -eq 10 -and !(Compare-Object ($scope.Files|Sort-Object) ($expectedFiles|Sort-Object)))
 $expectedDirectories=@('mobile-notifications','mail','meet-proxy','stun-setup','phone-health-runtime','automatic-backups','backup-restore','backup-control','backup-downloads','codec-compiler-cache','codec-build','storage/openweb-music'|ForEach-Object {Join-Path $state $_})
 AssertControl ($scope.Directories.Count -eq 12 -and !(Compare-Object ($scope.Directories|Sort-Object) ($expectedDirectories|Sort-Object)))
 foreach($name in 'installation.json','runtime.json','updater-install.json','updater-original-startup.json'){
  AssertControl (!(($scope.Files -join '|').Contains($name)))
 }
 $recordingAcl=CurrentAcl $recording;$recordingBytes=[Convert]::ToBase64String([IO.File]::ReadAllBytes($recording))
 foreach($path in $php,$track,$notification){
  [IO.File]::WriteAllText($path,'UPDATED-CONTENT',[Text.UTF8Encoding]::new($false));AlterAcl $path
 }
 if($native){
  . (Join-Path $SourceRoot 'packaging/windows/File-Security.ps1')
  $descriptor=[Security.AccessControl.RawSecurityDescriptor]::new((CurrentAcl $track))
  $oldOwner=$descriptor.Owner.Value;$oldGroup=$descriptor.Group.Value
  $descriptor.Owner=[Security.Principal.SecurityIdentifier]$(if($oldOwner -ceq 'S-1-5-18'){'S-1-5-32-544'}else{'S-1-5-18'})
  $descriptor.Group=[Security.Principal.SecurityIdentifier]$(if($oldGroup -ceq 'S-1-5-18'){'S-1-5-32-544'}else{'S-1-5-18'})
  Set-OpenWebFileSddl -LiteralPath $track -Sddl ($descriptor.GetSddlForm([Security.AccessControl.AccessControlSections]::All))
  $changed=[Security.AccessControl.RawSecurityDescriptor]::new((CurrentAcl $track))
  AssertControl ($changed.Owner.Value -cne $oldOwner -and $changed.Group.Value -cne $oldGroup)
 }
 # Change an actual captured parent before publishing a new child. The child
 # therefore has inherited changed access plus its own explicit access, and
 # must retain both when the original parent descriptor is replayed.
 AlterAcl (Split-Path $track -Parent)
 $newFile=Join-Path $state 'storage/openweb-music/16000/new-default.wav';NewText $newFile 'NEW-CONTENT';AlterAcl $newFile;$newFileAcl=CurrentAcl $newFile
 if($native){
  $descriptor=[Security.AccessControl.RawSecurityDescriptor]::new($newFileAcl)
  $localService=@($descriptor.DiscretionaryAcl|Where-Object {$_ -is [Security.AccessControl.CommonAce] -and $_.SecurityIdentifier.Value -ceq 'S-1-5-19'})
  AssertControl (@($localService|Where-Object $inheritedAce).Count -gt 0)
  AssertControl (@($localService|Where-Object $explicitAce).Count -gt 0)
 }
 $newDirectory=Join-Path $state 'mail';$null=[IO.Directory]::CreateDirectory($newDirectory);$newDirectoryAcl=CurrentAcl $newDirectory;$newPrivate=Join-Path $newDirectory 'new.lock';NewText $newPrivate 'NEW-PRIVATE';$newPrivateAcl=CurrentAcl $newPrivate
 Restore-OpenWebUpgradePermissions -Permissions $permissions -Root $root -StateRoot $state -EngineRoot $engine
 foreach($permission in $permissions){AssertControl ((CurrentAcl $permission.Path) -ceq $permission.Sddl)}
 foreach($path in $php,$track,$notification){AssertControl ([IO.File]::ReadAllText($path) -ceq 'UPDATED-CONTENT')}
 AssertControl ((CurrentAcl $php) -ceq $postHardening -and (CurrentAcl $php) -cne $preHardening)
 if($native){AssertControl (!(HasAuthenticatedUsersWrite (CurrentAcl $php)))}
 AssertControl ((CurrentAcl $root) -ceq $programAcl)
 AssertControl ((CurrentAcl $newFile) -ceq $newFileAcl -and [IO.File]::ReadAllText($newFile) -ceq 'NEW-CONTENT')
 AssertControl ((CurrentAcl $newPrivate) -ceq $newPrivateAcl -and [IO.File]::ReadAllText($newPrivate) -ceq 'NEW-PRIVATE')
 AssertControl ((CurrentAcl $newDirectory) -ceq $newDirectoryAcl)
 AssertControl ((CurrentAcl $recording) -ceq $recordingAcl -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($recording)) -ceq $recordingBytes)
 if(!$native){
  $seenFile=$false;$previousDepth=-1
  foreach($write in $script:writes){
   $entry=@($permissions|Where-Object {$_.Path -ceq $write.Path})[0]
   if(!$entry.Directory){$seenFile=$true}else{AssertControl (!$seenFile);$depth=$entry.Path.Split([IO.Path]::DirectorySeparatorChar).Count;AssertControl ($depth -ge $previousDepth);$previousDepth=$depth}
  }
 }
 $original=@($permissions|Where-Object {$_.Path -ceq $php})[0]
 $firstOriginal=@($permissions|Where-Object {$_.Path -ceq $track})[0]
 foreach($bad in @(
  @{Path=$php;Directory='false';Sddl=$original.Sddl},@{Path=$php;Directory=$false;Sddl=''},
  @{Path=$php;Directory=$false;Sddl=('x'*131073)},@{Path=$php;Directory=$false;Sddl=('x'+[char]0)},
  @{Path=$php;Directory=$false;Sddl='not-sddl'},@{Path=$php;Directory=$false;Sddl='O:BAD:(A;;FA;;;BA)'},
  @{Path=$php;Directory=$false;Sddl='G:BAD:(A;;FA;;;BA)'},@{Path=$php;Directory=$false;Sddl='O:BAG:BA'},
  @{Path=$recording;Directory=$false;Sddl=$original.Sddl},@{Path=$root;Directory=$true;Sddl=$original.Sddl},
  @{Path=(Join-Path $state 'mobile-notifications-extra/file');Directory=$false;Sddl=$original.Sddl},
  @{Path='relative';Directory=$false;Sddl=$original.Sddl},@{Path=$php;Directory=$true;Sddl=$original.Sddl},
  @{Path=(Join-Path $state 'mobile-notifications/missing');Directory=$false;Sddl=$original.Sddl},
  @{Path=(Join-Path $root 'php/../php/php.ini');Directory=$false;Sddl=$original.Sddl}
 )){
  AlterAcl $php;$faultAcl=CurrentAcl $php;AlterAcl $track;$firstFaultAcl=CurrentAcl $track
  Refuse @((CopyRecord $firstOriginal),$bad)
  AssertControl ((CurrentAcl $php) -ceq $faultAcl -and (CurrentAcl $track) -ceq $firstFaultAcl)
 }
 Refuse @((CopyRecord $original),(CopyRecord $original))
 $malformedCapture=Join-Path $state 'codec-build';NewText $malformedCapture
 $refused=$false;try{$null=Get-OpenWebUpgradePermissions -Root $root -StateRoot $state -EngineRoot $engine}catch{$refused=$true};AssertControl $refused
 Remove-Item -LiteralPath $malformedCapture -Force
 # Link and ancestor-link refusal uses an actual reparse object on Windows and
 # a real symbolic link in portable mode; no foreign target is ever written.
 $target=Join-Path $outer 'link-target';$null=[IO.Directory]::CreateDirectory($target)
 $link=Join-Path $state 'codec-build'
 if($native){$null=New-Item -ItemType Junction -Path $link -Target $target}else{$null=New-Item -ItemType SymbolicLink -Path $link -Target $target}
 $refused=$false;try{$null=Get-OpenWebUpgradePermissions -Root $root -StateRoot $state -EngineRoot $engine}catch{$refused=$true};AssertControl $refused
 NewText (Join-Path $target 'child')
 Refuse @(@{Path=(Join-Path $link 'child');Directory=$false;Sddl=$original.Sddl})
 AssertControl ([IO.File]::ReadAllText((Join-Path $target 'child')) -ceq 'original')
 [IO.Directory]::Delete($link)
 $empty=Join-Path $outer 'empty';$null=[IO.Directory]::CreateDirectory($empty)
 AssertControl (@(Get-OpenWebUpgradePermissions -Root $empty -StateRoot $empty -EngineRoot $empty).Count -eq 0)
 Restore-OpenWebUpgradePermissions -Permissions @() -Root $empty -StateRoot $empty -EngineRoot $empty
 AssertControl $true
}finally{
 if(Test-Path -LiteralPath $outer){Remove-Item -LiteralPath $outer -Recurse -Force}
}
AssertControl (!(Test-Path -LiteralPath $outer))
[Console]::Out.WriteLine((@{state='passed';checks=$script:checks;native_file_security=$native;installed_resources_accessed=$false}|ConvertTo-Json -Compress))
