# Dot-sourced by the trusted upgrade transaction while upgrade.lock is held.
function Test-OpenWebTaskSecurityEquivalent {
 param([string]$Original,[string]$Current)
 if([string]::IsNullOrWhiteSpace($Original) -or [string]::IsNullOrWhiteSpace($Current) -or $Original.Length -gt 65536 -or $Current.Length -gt 65536){return $false}
 if([string]::Equals($Original,$Current,[StringComparison]::Ordinal)){return $true}
 try{
  # Task Scheduler may reorder identical Allow entries and set AutoInherited
  # when applying a descriptor. Never extend this exception to file ACLs.
  $before=[Security.AccessControl.RawSecurityDescriptor]::new($Original)
  $after=[Security.AccessControl.RawSecurityDescriptor]::new($Current)
  if(![object]::Equals($before.Owner,$after.Owner) -or ![object]::Equals($before.Group,$after.Group)){return $false}
  if($before.ResourceManagerControl -ne $after.ResourceManagerControl){return $false}
  $oldFlags=[int]$before.ControlFlags;$newFlags=[int]$after.ControlFlags
  if(($oldFlags -bxor $newFlags) -band (-bnot 0x400)){return $false}
  if(($oldFlags -band 0x400) -and !($newFlags -band 0x400)){return $false}
  $oldSacl=$before.SystemAcl;$newSacl=$after.SystemAcl
  if(($null -eq $oldSacl) -ne ($null -eq $newSacl)){return $false}
  if($null -ne $oldSacl){
   if($oldSacl.BinaryLength -ne $newSacl.BinaryLength){return $false}
   $oldBytes=New-Object byte[] $oldSacl.BinaryLength;$newBytes=New-Object byte[] $newSacl.BinaryLength
   $oldSacl.GetBinaryForm($oldBytes,0);$newSacl.GetBinaryForm($newBytes,0)
   if([Convert]::ToBase64String($oldBytes) -cne [Convert]::ToBase64String($newBytes)){return $false}
  }
  $oldDacl=$before.DiscretionaryAcl;$newDacl=$after.DiscretionaryAcl
  # Null/empty or unusual ACLs retain the exact-text contract above.
  if($null -eq $oldDacl -or $null -eq $newDacl -or $oldDacl.Count -eq 0 -or $oldDacl.Revision -ne $newDacl.Revision -or $oldDacl.BinaryLength -ne $newDacl.BinaryLength -or $oldDacl.Count -ne $newDacl.Count){return $false}
  $counts=[Collections.Generic.Dictionary[string,int]]::new([StringComparer]::Ordinal)
  foreach($ace in $oldDacl){
   if($ace -isnot [Security.AccessControl.CommonAce] -or $ace.IsCallback -or $ace.AceType -ne [Security.AccessControl.AceType]::AccessAllowed -or $ace.AceQualifier -ne [Security.AccessControl.AceQualifier]::AccessAllowed){return $false}
   $bytes=New-Object byte[] $ace.BinaryLength;$ace.GetBinaryForm($bytes,0);$key=[Convert]::ToBase64String($bytes)
   if($counts.ContainsKey($key)){$counts[$key]++}else{$counts.Add($key,1)}
  }
  foreach($ace in $newDacl){
   if($ace -isnot [Security.AccessControl.CommonAce] -or $ace.IsCallback -or $ace.AceType -ne [Security.AccessControl.AceType]::AccessAllowed -or $ace.AceQualifier -ne [Security.AccessControl.AceQualifier]::AccessAllowed){return $false}
   $bytes=New-Object byte[] $ace.BinaryLength;$ace.GetBinaryForm($bytes,0);$key=[Convert]::ToBase64String($bytes)
   if(!$counts.ContainsKey($key) -or $counts[$key] -eq 0){return $false};$counts[$key]--
  }
  foreach($count in $counts.Values){if($count -ne 0){return $false}}
  return $true
 }catch{return $false}
}
function Test-OpenWebProgramRootDescriptorPolicy {
 param($Descriptor)
 if($null -eq $Descriptor.Owner -or $null -eq $Descriptor.Group -or $Descriptor.BinaryLength -gt 262144 -or !([int]$Descriptor.ControlFlags -band [int][Security.AccessControl.ControlFlags]::DiscretionaryAclPresent) -or !([int]$Descriptor.ControlFlags -band [int][Security.AccessControl.ControlFlags]::DiscretionaryAclProtected)){return $false}
 $acl=$Descriptor.DiscretionaryAcl
 if($null -eq $acl -or $acl.Revision -ne 2 -or $acl.Count -ne 3){return $false}
 $expected=@{'S-1-5-32-544'=[int][Security.AccessControl.FileSystemRights]::FullControl;'S-1-5-18'=[int][Security.AccessControl.FileSystemRights]::FullControl;'S-1-5-32-545'=([int][Security.AccessControl.FileSystemRights]::ReadAndExecute -bor [int][Security.AccessControl.FileSystemRights]::Synchronize)}
 foreach($ace in $acl){
  if($ace -isnot [Security.AccessControl.CommonAce] -or $ace.IsCallback -or $ace.AceType -ne [Security.AccessControl.AceType]::AccessAllowed -or $ace.AceQualifier -ne [Security.AccessControl.AceQualifier]::AccessAllowed -or [int]$ace.AceFlags -ne 3){return $false}
  $sid=$ace.SecurityIdentifier.Value
  if(!$expected.ContainsKey($sid) -or $ace.AccessMask -ne $expected[$sid]){return $false}
  $expected.Remove($sid)
 }
 return $expected.Count -eq 0
}
function Test-OpenWebProgramRootPolicy {
 param([string]$Root)
 $item=Get-Item -LiteralPath $Root -Force -ErrorAction Stop
 if(!$item.PSIsContainer){throw 'The program root is not an ordinary directory.'}
 $ancestor=$item
 while($null -ne $ancestor){
  if([int]$ancestor.Attributes -band [int][IO.FileAttributes]::ReparsePoint){throw 'The program root is a link or junction.'}
  $parent=[IO.Path]::GetDirectoryName($ancestor.FullName)
  if(!$parent -or $parent -eq $ancestor.FullName){break}
  $ancestor=Get-Item -LiteralPath $parent -Force -ErrorAction Stop
 }
 $sddl=(Get-Acl -LiteralPath $item.FullName -ErrorAction Stop).Sddl
 if($sddl -isnot [string] -or [string]::IsNullOrWhiteSpace($sddl) -or $sddl.Length -gt 131072 -or $sddl.IndexOf([char]0) -ge 0){throw 'The program root security descriptor is invalid.'}
 $descriptor=[Security.AccessControl.RawSecurityDescriptor]::new($sddl)
 return Test-OpenWebProgramRootDescriptorPolicy $descriptor
}
function Get-OpenWebUpgradePermissionScope {
 param([string]$Root,[string]$StateRoot,[string]$EngineRoot)
 # Existing private/support objects only. Program directories, tasks and mutable
 # installation/updater metadata deliberately keep their upgrade contracts.
 # DTLS owns successful certificate ACLs: valid/custom keys stay exact and
 # repaired keys stay protected. Failure recovery below captures the old key
 # bytes, descriptor and absence independently of this successful replay.
 @{
  Files=@((Join-Path $Root 'php\php.ini'),(Join-Path $Root 'php\extras\ssl\openssl.cnf'),(Join-Path $Root 'php\extras\ssl\cacert.pem'),(Join-Path $StateRoot 'native-engine.json'),(Join-Path $StateRoot 'local-codec.json'),(Join-Path $StateRoot 'meet-ca.pem'),(Join-Path $StateRoot 'meet-proxy.json'),(Join-Path $StateRoot 'phone-health-instance.json'),(Join-Path $StateRoot 'stun.json'),(Join-Path $EngineRoot 'libbcg729.dll'))
  Directories=@('mobile-notifications','mail','meet-proxy','stun-setup','dtls-setup','phone-health-runtime','automatic-backups','backup-restore','backup-control','backup-downloads','codec-compiler-cache','codec-build','storage\openweb-music'|ForEach-Object {Join-Path $StateRoot $_})
 }
}
function Get-OpenWebUpgradePermissions {
 param([string]$Root,[string]$StateRoot,[string]$EngineRoot)
 $scope=Get-OpenWebUpgradePermissionScope -Root $Root -StateRoot $StateRoot -EngineRoot $EngineRoot
 $permissions=New-Object 'Collections.Generic.List[object]'
 foreach($path in @($scope.Files)+@($scope.Directories)){
  if(!(Test-Path -LiteralPath $path)){continue}
  $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
  $directory=$path -in $scope.Directories
  if([bool]$item.PSIsContainer -ne $directory -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'An upgrade permission target is not ordinary local storage.'}
  $ancestor=$item
  while($null -ne $ancestor){
   if($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'An upgrade permission target is a link or junction.'}
   $parent=[IO.Path]::GetDirectoryName($ancestor.FullName)
   if(!$parent -or $parent -eq $ancestor.FullName){break}
   $ancestor=Get-Item -LiteralPath $parent -Force -ErrorAction Stop
  }
  $items=@($item)
  if($directory){$items+=@(Get-ChildItem -LiteralPath $path -Force -Recurse -ErrorAction Stop)}
  foreach($entry in $items){
   if($entry.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'An upgrade permission target is a link or junction.'}
   $sddl=(Get-Acl -LiteralPath $entry.FullName -ErrorAction Stop).Sddl
   if($sddl -isnot [string] -or [string]::IsNullOrWhiteSpace($sddl) -or $sddl.Length -gt 131072 -or $sddl.IndexOf([char]0) -ge 0){throw 'An upgrade permission descriptor is invalid.'}
   $permissions.Add(@{Path=$entry.FullName;Directory=[bool]$entry.PSIsContainer;Sddl=$sddl})
  }
 }
 $permissions
}
function Restore-OpenWebUpgradePermissions {
 param([AllowEmptyCollection()][object[]]$Permissions,[string]$Root,[string]$StateRoot,[string]$EngineRoot)
 $scope=Get-OpenWebUpgradePermissionScope -Root $Root -StateRoot $StateRoot -EngineRoot $EngineRoot
 $files=@($scope.Files|ForEach-Object {[IO.Path]::GetFullPath($_)})
 $directories=@($scope.Directories|ForEach-Object {[IO.Path]::GetFullPath($_).TrimEnd([IO.Path]::DirectorySeparatorChar)})
 $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
 $checked=New-Object 'Collections.Generic.List[object]'
 # Validate the entire captured list before the first security write.
 foreach($permission in $Permissions){
  if($null -eq $permission -or $permission.Path -isnot [string] -or [string]::IsNullOrWhiteSpace($permission.Path) -or $permission.Directory -isnot [bool] -or $permission.Sddl -isnot [string] -or [string]::IsNullOrWhiteSpace($permission.Sddl) -or $permission.Sddl.Length -gt 131072 -or $permission.Sddl.IndexOf([char]0) -ge 0){throw 'An upgrade permission snapshot is invalid.'}
  $descriptor=[Security.AccessControl.RawSecurityDescriptor]::new($permission.Sddl)
  if($null -eq $descriptor.Owner -or $null -eq $descriptor.Group -or !($descriptor.ControlFlags -band [Security.AccessControl.ControlFlags]::DiscretionaryAclPresent) -or $descriptor.BinaryLength -gt 262144){throw 'A complete original upgrade permission descriptor is required.'}
  if(![IO.Path]::IsPathRooted($permission.Path) -or $permission.Path.Length -gt 32767 -or $permission.Path.IndexOf([char]0) -ge 0){throw 'An upgrade permission path is invalid.'}
  $path=[IO.Path]::GetFullPath($permission.Path)
  if(!$path.Equals($permission.Path,[StringComparison]::OrdinalIgnoreCase)){throw 'An upgrade permission path is not canonical.'}
  $allowed=$path -in $files
  foreach($directory in $directories){if($path.Equals($directory,[StringComparison]::OrdinalIgnoreCase) -or $path.StartsWith($directory+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){$allowed=$true;break}}
  if(!$allowed -or !$seen.Add($path)){throw 'An upgrade permission target is outside its original scope or duplicated.'}
  $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
  if([bool]$item.PSIsContainer -ne $permission.Directory){throw 'An upgrade permission target changed its file type.'}
  $ancestor=$item
  while($null -ne $ancestor){
   if($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'An upgrade permission target is a link or junction.'}
   $parent=[IO.Path]::GetDirectoryName($ancestor.FullName)
   if(!$parent -or $parent -eq $ancestor.FullName){break}
   $ancestor=Get-Item -LiteralPath $parent -Force -ErrorAction Stop
  }
  $checked.Add(@{Path=$path;Directory=$permission.Directory;Depth=$path.Split([IO.Path]::DirectorySeparatorChar).Count;Sddl=$permission.Sddl})
 }
 . (Join-Path $PSScriptRoot 'File-Security.ps1')
 foreach($permission in ($checked|Sort-Object @{Expression={if($_.Directory){0}else{1}}},Depth,Path)){
  Set-OpenWebFileSddl -LiteralPath $permission.Path -Sddl $permission.Sddl
 }
}
function Assert-OpenWebUpdaterSlotsRestored {
 param([string]$Source,[string]$Target)
 $inventories=@()
 foreach($path in $Source,$Target){
  $root=Get-Item -LiteralPath $path -Force -ErrorAction Stop
  if(!$root.PSIsContainer -or ($root.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'The updater-slot recovery root is not an ordinary directory.'}
  $inventory=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach($item in Get-ChildItem -LiteralPath $path -Recurse -Force -ErrorAction Stop){
   if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'An updater-slot recovery link or junction was preserved.'}
   $relative=$item.FullName.Substring($root.FullName.TrimEnd('\').Length+1)
   $inventory.Add($relative,@{Directory=[bool]$item.PSIsContainer;Hash=if($item.PSIsContainer){''}else{(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256 -ErrorAction Stop).Hash}})
  }
  $inventories+=,$inventory
 }
 $before=$inventories[0];$after=$inventories[1]
 if($before.Count -ne $after.Count){throw 'The original updater-slot inventory did not fully restore; recovery remains required.'}
 foreach($key in $before.Keys){if(!$after.ContainsKey($key) -or $before[$key].Directory -cne $after[$key].Directory -or $before[$key].Hash -cne $after[$key].Hash){throw 'The original updater-slot bytes or types did not fully restore; recovery remains required.'}}
}
# Greetings use a dedicated Windows media subtree. The caller owns upgrade.lock;
# recovery retains media bytes and restores raw pre-grant file security.
function Assert-OpenWebGreetingDescriptor {
 param([string]$Sddl)
 if([string]::IsNullOrWhiteSpace($Sddl) -or $Sddl.Length -gt 131072 -or $Sddl.IndexOf([char]0) -ge 0){throw 'The greeting permission descriptor is invalid.'}
 $descriptor=[Security.AccessControl.RawSecurityDescriptor]::new($Sddl)
 if($null -eq $descriptor.Owner -or $null -eq $descriptor.Group -or !($descriptor.ControlFlags -band [Security.AccessControl.ControlFlags]::DiscretionaryAclPresent) -or $descriptor.BinaryLength -gt 262144){throw 'Complete original greeting file security is required.'}
}
function Assert-OpenWebGreetingAccessSnapshot {
 param($Snapshot,[string]$StateRoot)
 $state=Assert-OpenWebRecoveryOrdinary -Path $StateRoot -Directory
 $storage=[IO.Path]::GetFullPath((Join-Path $state 'storage'));$root=[IO.Path]::GetFullPath((Join-Path $storage 'greetings'))
 if(($Snapshot.schema -isnot [int] -and $Snapshot.schema -isnot [long]) -or $Snapshot.schema -ne 1 -or $Snapshot.StateRoot -isnot [string] -or $Snapshot.StateRoot -cne $state -or $Snapshot.RootExists -isnot [bool] -or @($Snapshot.Entries).Count -lt 3){throw 'The greeting access snapshot is invalid.'}
 $fields=if($Snapshot -is [Collections.IDictionary]){@($Snapshot.Keys)}else{@($Snapshot.PSObject.Properties.Name)}
 if($fields.Count -ne 4 -or @($fields|Where-Object {$_ -cnotin 'schema','StateRoot','RootExists','Entries'}).Count -or $Snapshot.Entries -isnot [array] -or @($Snapshot.Entries).Count -gt 100000){throw 'The greeting access snapshot fields or bounds are invalid.'}
 $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
 foreach($entry in $Snapshot.Entries){
  $fields=if($entry -is [Collections.IDictionary]){@($entry.Keys)}else{@($entry.PSObject.Properties.Name)}
  if($fields.Count -ne 3 -or @($fields|Where-Object {$_ -cnotin 'Path','Directory','Sddl'}).Count){throw 'The greeting access entry fields are invalid.'}
  if($entry.Path -isnot [string] -or $entry.Directory -isnot [bool] -or $entry.Sddl -isnot [string]){throw 'The greeting access entry is invalid.'}
  $path=[IO.Path]::GetFullPath($entry.Path)
  if($path -cne $entry.Path -or !$seen.Add($path) -or !($path -ieq $state -or $path -ieq $storage -or $path -ieq $root -or $path.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase))){throw 'A greeting permission target is outside its dedicated scope.'}
  Assert-OpenWebGreetingDescriptor $entry.Sddl
  $null=Assert-OpenWebCallRecordOrdinary -Path $path -Directory:$entry.Directory
 }
 foreach($path in $state,$storage,$root){if(!$seen.Contains($path) -or !(@($Snapshot.Entries|Where-Object {$_.Path -ieq $path -and $_.Directory}).Count -eq 1)){throw 'The greeting access ancestors are incomplete.'}}
 if(!$Snapshot.RootExists -and @($Snapshot.Entries).Count -ne 3){throw 'An absent original greeting root cannot have original descendants.'}
 # Include nodes created since capture: inherited grants must never encounter
 # a new junction/link or an unbounded tree before the first security write.
 $current=@(Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction Stop|Select-Object -First 99998)
 if($current.Count -gt 99997){throw 'The current greeting access inventory exceeds its bound.'}
 foreach($item in $current){$null=Assert-OpenWebCallRecordOrdinary -Path $item.FullName -Directory:$item.PSIsContainer}
 return $root
}
function Get-OpenWebGreetingAccessSnapshot {
 param([string]$StateRoot,[IO.FileStream]$MaintenanceLock)
 Assert-OpenWebRecoveryLock -MaintenanceLock $MaintenanceLock -StateRoot $StateRoot
 $state=Assert-OpenWebRecoveryOrdinary -Path $StateRoot -Directory
 $storage=Assert-OpenWebRecoveryOrdinary -Path (Join-Path $state 'storage') -Directory
 $root=Join-Path $storage 'greetings';$exists=[bool](Test-Path -LiteralPath $root)
 # Capture the initial inherited descriptor of an owned new empty root before
 # granting any access. RootExists retains its original absence for rollback.
 if(!$exists){$null=New-Item -ItemType Directory -Path $root -ErrorAction Stop}
 try{
  $null=Assert-OpenWebRecoveryOrdinary -Path $root -Directory
  $items=@((Get-Item -LiteralPath $state -Force),(Get-Item -LiteralPath $storage -Force),(Get-Item -LiteralPath $root -Force))
  $items+=@(Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction Stop|Select-Object -First 99998)
  if($items.Count -gt 100000){throw 'The original greeting access inventory exceeds its bound.'}
  $entries=@(foreach($item in $items){
   $null=Assert-OpenWebCallRecordOrdinary -Path $item.FullName -Directory:$item.PSIsContainer
   $sddl=(Get-Acl -LiteralPath $item.FullName -ErrorAction Stop).Sddl;Assert-OpenWebGreetingDescriptor $sddl
   @{Path=$item.FullName;Directory=[bool]$item.PSIsContainer;Sddl=$sddl}
  })
  $snapshot=@{schema=1;StateRoot=$state;RootExists=$exists;Entries=$entries}
  $null=Assert-OpenWebGreetingAccessSnapshot -Snapshot $snapshot -StateRoot $state
  return $snapshot
 }catch{
  $snapshotFailure=$_
  try{if(!$exists -and (Test-Path -LiteralPath $root) -and @(Get-ChildItem -LiteralPath $root -Force -ErrorAction Stop).Count -eq 0){[IO.Directory]::Delete($root,$false)}}catch{$snapshotFailure.Exception.Data['greeting_empty_root_cleanup_failed']=$true}
  throw $snapshotFailure
 }
}
function Install-OpenWebGreetingAccess {
 param($Snapshot,[string]$StateRoot,[IO.FileStream]$MaintenanceLock)
 Assert-OpenWebRecoveryLock -MaintenanceLock $MaintenanceLock -StateRoot $StateRoot
 $root=Assert-OpenWebGreetingAccessSnapshot -Snapshot $Snapshot -StateRoot $StateRoot
 # No inheritable write permission is added to StateRoot, storage, or tenant media.
 foreach($entry in $Snapshot.Entries){
  if($entry.Path -ieq $StateRoot -or $entry.Path -ieq (Join-Path $StateRoot 'storage')){Add-OpenWebCallRecordRight -Path $entry.Path -Rights ReadAndExecute;continue}
  $inheritance=if($entry.Directory){[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'}else{[Security.AccessControl.InheritanceFlags]::None}
  Add-OpenWebCallRecordRight -Path $entry.Path -Rights Modify -Inheritance $inheritance
 }
}
function Restore-OpenWebGreetingAccess {
 param($Snapshot,[string]$StateRoot,[IO.FileStream]$MaintenanceLock)
 Assert-OpenWebRecoveryLock -MaintenanceLock $MaintenanceLock -StateRoot $StateRoot
 $root=Assert-OpenWebGreetingAccessSnapshot -Snapshot $Snapshot -StateRoot $StateRoot
 # Snapshot validation covers all current nodes before the first security write.
 # Never delete files or recursively delete directories during recovery.
 . (Join-Path $PSScriptRoot 'File-Security.ps1')
 foreach($entry in $Snapshot.Entries|Sort-Object @{Expression={$_.Path.Length}}){Set-OpenWebFileSddl -LiteralPath $entry.Path -Sddl $entry.Sddl}
 if(!$Snapshot.RootExists -and @(Get-ChildItem -LiteralPath $root -Force -ErrorAction Stop).Count -eq 0){[IO.Directory]::Delete($root,$false)}
}

function Save-OpenWebSupport {
 param([string]$Backup,[string]$PackageRoot,[string]$Root,[string]$StateRoot,[string]$EngineRoot,[IO.FileStream]$MaintenanceLock)
 $record=[ordered]@{schema=1;Files=@{};Directories=@{};Acls=@{};Tasks=@{};OpenSshClient=(Get-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0).State.ToString()}
 . (Join-Path $PackageRoot 'CallRecords.Common.ps1')
 $record.CallRecordAccess=Get-OpenWebCallRecordAccessSnapshot -PackageRoot $PackageRoot -Root $Root -StateRoot $StateRoot -EngineRoot $EngineRoot -MaintenanceLock $MaintenanceLock
 $record.GreetingAccess=Get-OpenWebGreetingAccessSnapshot -StateRoot $StateRoot -MaintenanceLock $MaintenanceLock
 try{
 $certificateDirectory=[IO.Path]::GetFullPath((Join-Path $EngineRoot 'cert'))
 $directoryExists=Test-Path -LiteralPath $certificateDirectory
 if($directoryExists){
  $item=Get-Item -LiteralPath $certificateDirectory -Force -ErrorAction Stop
  if(!$item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'The call-engine certificate parent is not an ordinary directory.'}
  $record.Acls[$certificateDirectory]=(Get-Acl -LiteralPath $certificateDirectory -ErrorAction Stop).Sddl
 }
 $record.DtlsCertificateDirectory=@{Path=$certificateDirectory;Exists=[bool]$directoryExists}
 $fastcgi="$Root\php\php-cgi.exe"
 $filter="system.webServer/fastCgi/application[@fullPath='$fastcgi']/environmentVariables/environmentVariable[@name='OPENSSL_CONF']"
 $environment=Get-WebConfiguration -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter $filter
 $record.PhpEnvironment=@{Exists=[bool]$environment;Value=if($environment){[string]$environment.value}else{''};ProcessValue=$env:OPENSSL_CONF}
 $files=@("$Root\php\php.ini","$Root\php\extras\ssl\openssl.cnf","$Root\php\extras\ssl\cacert.pem","$StateRoot\native-engine.json","$StateRoot\local-codec.json","$StateRoot\meet-ca.pem","$StateRoot\meet-proxy.json","$StateRoot\updater-original-startup.json","$StateRoot\updater-install.json","$StateRoot\installation.json","$StateRoot\phone-health-instance.json","$StateRoot\stun.json","$EngineRoot\cert\dtls-srtp.pem","$EngineRoot\libbcg729.dll")
 if(Test-Path (Join-Path $PackageRoot 'Meet-Proxy.ps1')){
  Copy-Item -LiteralPath (Join-Path $PackageRoot 'Meet-Proxy.ps1') -Destination (Join-Path $Backup 'meeting-recovery.ps1')
  Copy-Item -LiteralPath (Join-Path $PackageRoot 'Write-PrivateState.ps1') -Destination (Join-Path $Backup 'Write-PrivateState.ps1')
  . (Join-Path $PackageRoot 'Meet-Proxy.ps1')
  Save-OpenWebMeetSystem -Destination (Join-Path $Backup 'meeting-system.json') -StateRoot $StateRoot
 }
 $native=Get-Content "$PackageRoot\engine\native-manifest.json" -Raw | ConvertFrom-Json
 foreach($entry in $native.files.PSObject.Properties){if($entry.Name -notlike 'mod/*'){$files+=Join-Path $EngineRoot $entry.Name}}
 $index=0
 foreach($path in $files){
  $exists=Test-Path -LiteralPath $path -PathType Leaf
  $copy='support-files/'+($index++)
  $record.Files[$path]=@{Exists=$exists;Copy=$copy}
  if($exists){New-Item -ItemType Directory -Force "$Backup\support-files" | Out-Null;Copy-Item -LiteralPath $path -Destination (Join-Path $Backup $copy);$record.Acls[$path]=(Get-Acl -LiteralPath $path).Sddl}
 }
 $directories=@{
  'backup-runtime'="$Root\backup-runtime";'acme-runtime'="$Root\acme";'mobile-notifications'="$StateRoot\mobile-notifications";'mail-state'="$StateRoot\mail";'meet-proxy'="$StateRoot\meet-proxy";'tenant-domains'="$StateRoot\tenant-domains";'stun-setup'="$StateRoot\stun-setup";'dtls-setup'="$StateRoot\dtls-setup";'phone-health-runtime'="$StateRoot\phone-health-runtime";'updater-slots'="$Root\updater\slots"
  'automatic-backups'="$StateRoot\automatic-backups";'backup-restore'="$StateRoot\backup-restore";'backup-control'="$StateRoot\backup-control";'backup-downloads'="$StateRoot\backup-downloads"
  'codec-compiler-cache'="$StateRoot\codec-compiler-cache";'codec-build'="$StateRoot\codec-build";'openweb-music'="$StateRoot\storage\openweb-music"
 }
 foreach($name in $directories.Keys){
  $path=$directories[$name]
  if(Test-Path -LiteralPath $path){
   $item=Get-Item -LiteralPath $path -Force
   if(!$item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'An owned support directory is a file, link or junction; it was preserved.'}
  }
  $exists=Test-Path -LiteralPath $path -PathType Container
  $record.Directories[$name]=@{Path=$path;Exists=$exists}
  if($exists){CopyTree $path (Join-Path $Backup $name)}
 }
 $record.Acls[$Root]=(Get-Acl -LiteralPath $Root).Sddl
 foreach($path in @("$Root\web","$Root\server","$Root\desktop","$Root\tools","$Root\php","$EngineRoot\mod","$EngineRoot\sounds","$EngineRoot\conf","$StateRoot\mobile-notifications","$StateRoot\mail","$StateRoot\meet-proxy","$StateRoot\tenant-domains","$StateRoot\stun-setup","$StateRoot\dtls-setup","$StateRoot\phone-health-runtime","$Root\backup-runtime","$Root\acme","$Root\updater","$StateRoot\automatic-backups","$StateRoot\backup-restore","$StateRoot\backup-control","$StateRoot\backup-downloads","$StateRoot\codec-compiler-cache","$StateRoot\codec-build","$StateRoot\storage\openweb-music")){
  if(Test-Path -LiteralPath $path -PathType Container){
   $record.Acls[$path]=(Get-Acl -LiteralPath $path).Sddl
   foreach($item in Get-ChildItem -LiteralPath $path -Force -Recurse){
    if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'An owned support folder contains a link or junction.'}
    $record.Acls[$item.FullName]=(Get-Acl -LiteralPath $item.FullName).Sddl
   }
  }
 }
 foreach($name in 'OpenWebPBX-Backups','OpenWebPBX Outgoing Mail','OpenWebPBX-TenantDomains','OpenWebPBX-PhoneHealth','OpenWebPBX-Updater-Restart','OpenWebPBX-Cleanup'){
  $task=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
  $record.Tasks[$name]=@{Exists=[bool]$task;Enabled=if($task){[bool]$task.Settings.Enabled}else{$false}}
  if($task){
   $scheduler=New-Object -ComObject Schedule.Service;$scheduler.Connect()
   $record.Tasks[$name].Security=$scheduler.GetFolder('\').GetTask($name).GetSecurityDescriptor(7)
   $record.Tasks[$name].FileAcl=(Get-Acl -LiteralPath (Join-Path $env:SystemRoot ('System32\Tasks\'+$name))).Sddl
   Export-ScheduledTask -TaskName $name | Set-Content "$Backup\$name.xml" -Encoding UTF8
   if($name -eq 'OpenWebPBX-PhoneHealth'){
    . (Join-Path $PackageRoot 'PhoneHealth-Security.ps1')
    Stop-OpenWebHealthTask -MaintenanceLock $MaintenanceLock -Disable
   }elseif($name -in 'OpenWebPBX-Backups','OpenWebPBX Outgoing Mail','OpenWebPBX-TenantDomains','OpenWebPBX-Cleanup'){Disable-ScheduledTask -TaskName $name | Out-Null}
  }
 }
 WriteState "$Backup\support-state.json" $record
 }catch{
  # Before publication, this local snapshot still owns an absent-before root.
  # Retain any new media, restore only captured security, and keep the original
  # support failure primary if permission/empty-root recovery also refuses.
  $supportFailure=$_
  try{Restore-OpenWebGreetingAccess -Snapshot $record.GreetingAccess -StateRoot $StateRoot -MaintenanceLock $MaintenanceLock}
  catch{$supportFailure.Exception.Data['greeting_pregrant_cleanup_failed']=$true}
  throw $supportFailure
 }
}
function Restore-OpenWebSupport {
 param([string]$Backup,[string]$Root,[string]$StateRoot,[string]$EngineRoot,[IO.FileStream]$MaintenanceLock)
 if(!(Test-Path "$Backup\support-state.json")){return} # Old immutable backups.
 $record=Get-Content "$Backup\support-state.json" -Raw | ConvertFrom-Json
 if($record.schema -ne 1){throw 'The support recovery inventory is invalid.'}
 if($record.PSObject.Properties.Name -ccontains 'CallRecordAccess'){
  . (Join-Path $PSScriptRoot 'CallRecords.Common.ps1')
  Restore-OpenWebCallRecordAccess -Snapshot $record.CallRecordAccess -StateRoot $StateRoot -EngineRoot $EngineRoot -MaintenanceLock $MaintenanceLock
 }
 if($record.PSObject.Properties.Name -ccontains 'GreetingAccess'){Restore-OpenWebGreetingAccess -Snapshot $record.GreetingAccess -StateRoot $StateRoot -MaintenanceLock $MaintenanceLock}
 if(Test-Path (Join-Path $Backup 'meeting-system.json')){
  . (Join-Path $Backup 'meeting-recovery.ps1')
  Restore-OpenWebMeetSystem -Snapshot (Join-Path $Backup 'meeting-system.json') -StateRoot $StateRoot
 }
 $allowed=@($Root,"$StateRoot\native-engine.json","$StateRoot\local-codec.json","$StateRoot\meet-ca.pem","$StateRoot\meet-proxy.json","$StateRoot\updater-original-startup.json","$StateRoot\updater-install.json","$StateRoot\installation.json","$StateRoot\phone-health-instance.json","$StateRoot\stun.json","$StateRoot\mobile-notifications","$StateRoot\mail","$StateRoot\meet-proxy","$StateRoot\tenant-domains","$StateRoot\stun-setup","$StateRoot\dtls-setup","$StateRoot\phone-health-runtime","$StateRoot\automatic-backups","$StateRoot\backup-restore","$StateRoot\backup-control","$StateRoot\backup-downloads","$StateRoot\codec-compiler-cache","$StateRoot\codec-build","$StateRoot\storage\openweb-music","$EngineRoot")
 function Check-SupportPath([string]$Path){
  $full=[IO.Path]::GetFullPath($Path);$valid=$false
  foreach($base in $allowed){if($full.Equals($base,[StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($base.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){$valid=$true;break}}
  if(!$valid){throw 'A support recovery path is outside the owned installation.'}
  return $full
 }
 $certificateDirectory=$null;$removeCertificateDirectory=$false
 if($record.PSObject.Properties.Name -ccontains 'DtlsCertificateDirectory'){
  $parentRecord=$record.DtlsCertificateDirectory
  $expectedParent=[IO.Path]::GetFullPath((Join-Path $EngineRoot 'cert'))
  if($null -eq $parentRecord -or $parentRecord.Path -isnot [string] -or $parentRecord.Exists -isnot [bool] -or !$parentRecord.Path.Equals($expectedParent,[StringComparison]::OrdinalIgnoreCase)){throw 'The original DTLS parent inventory is invalid.'}
  $certificateDirectory=$expectedParent
  if($parentRecord.Exists){
   $originalAcl=@($record.Acls.PSObject.Properties|Where-Object {$_.Name.Equals($expectedParent,[StringComparison]::OrdinalIgnoreCase)})
   if($originalAcl.Count -ne 1 -or $originalAcl[0].Value -isnot [string] -or !$originalAcl[0].Value){throw 'The complete original DTLS parent descriptor is required.'}
   $currentParent=Get-Item -LiteralPath $certificateDirectory -Force -ErrorAction Stop
   if(!$currentParent.PSIsContainer){throw 'The original DTLS parent changed type; it was preserved.'}
   $ancestor=$currentParent
   while($null -ne $ancestor){
    if($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'The original DTLS parent or an ancestor became a link; it was preserved.'}
    $next=[IO.Path]::GetDirectoryName($ancestor.FullName)
    if(!$next -or $next -eq $ancestor.FullName){break};$ancestor=Get-Item -LiteralPath $next -Force -ErrorAction Stop
   }
  }elseif(Test-Path -LiteralPath $certificateDirectory){
   # Validate ownership before deleting any key or restoring the private setup
   # tree. An interrupted empty-parent removal retains this journal for retry.
   . (Join-Path $PSScriptRoot 'Dtls.Common.ps1')
   Assert-OpenWebDtlsOrdinary $certificateDirectory
   $item=Get-Item -LiteralPath $certificateDirectory -Force -ErrorAction Stop
   if(!$item.PSIsContainer){throw 'The new DTLS parent changed type; it was preserved.'}
   $certificate=Join-Path $certificateDirectory 'dtls-srtp.pem';$setup=Join-Path $StateRoot 'dtls-setup'
   Assert-OpenWebDtlsPrivate $setup
   $proofs=@(foreach($transaction in Get-ChildItem -LiteralPath $setup -Force -ErrorAction Stop){
    if(!$transaction.PSIsContainer -or $transaction.Name -cnotmatch '^[a-f0-9]{32}$'){continue}
    if(Test-Path -LiteralPath (Join-Path (Join-Path $Backup 'dtls-setup') $transaction.Name)){continue}
    $j=Read-OpenWebDtlsJournal $transaction.FullName $certificate
    if($j.parent_before_exists -isnot [bool] -or $j.parent_before_exists -or $j.parent_create_intent -isnot [bool] -or !$j.parent_create_intent -or $j.parent_created -isnot [bool] -or $j.parent_path -isnot [string] -or !$j.parent_path.Equals($certificateDirectory,[StringComparison]::OrdinalIgnoreCase) -or $j.parent_desired_sddl -isnot [string] -or !$j.parent_desired_sddl -or $j.before_exists -ne $false -or $j.state -cnotin 'prepared','applying','committed' -or ($j.state -ceq 'committed' -and !$j.parent_created)){throw 'The current DTLS parent ownership journal requires review.'}
    if((Get-Acl -LiteralPath $certificateDirectory -ErrorAction Stop).Sddl -cne $j.parent_desired_sddl){throw 'The new DTLS parent permissions changed; it was preserved.'}
    $children=@(Get-ChildItem -LiteralPath $certificateDirectory -Force -ErrorAction Stop)
    if($children.Count -gt 1){throw 'Unrelated call-engine certificate entries were preserved.'}
    foreach($child in $children){
     if($child.PSIsContainer -or ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -or !$child.FullName.Equals($certificate,[StringComparison]::OrdinalIgnoreCase) -or (Get-OpenWebDtlsHash $child.FullName) -cne $j.desired_sha256 -or (Get-Acl -LiteralPath $child.FullName -ErrorAction Stop).Sddl -cne $j.desired_sddl){throw 'An unrelated call-engine certificate entry was preserved.'}
    }
    $j
   })
   if($proofs.Count -ne 1){throw 'Exactly one new machine-bound DTLS parent ownership proof is required.'}
   $removeCertificateDirectory=$true
  }
 }
 if(Test-Path "$Backup\switch-mod"){CopyTree "$Backup\switch-mod" "$EngineRoot\mod" -Mirror}
 if(Test-Path "$Backup\switch-sounds"){CopyTree "$Backup\switch-sounds" "$EngineRoot\sounds" -Mirror}
 foreach($entry in $record.Files.PSObject.Properties){
  $target=Check-SupportPath $entry.Name
  if($entry.Value.Exists){
   if($entry.Value.Copy -notmatch '^support-files/[0-9]+$'){throw 'The support recovery file inventory is invalid.'}
   New-Item -ItemType Directory -Force (Split-Path $target -Parent) | Out-Null
   Copy-Item -LiteralPath (Join-Path $Backup $entry.Value.Copy) -Destination $target -Force
  }else{
   if($target.Equals([IO.Path]::GetFullPath((Join-Path $EngineRoot 'cert\dtls-srtp.pem')),[StringComparison]::OrdinalIgnoreCase)){
    if(Test-Path -LiteralPath $target){Remove-Item -LiteralPath $target -Force -ErrorAction Stop}
    if(Test-Path -LiteralPath $target){throw 'The original DTLS certificate absence did not restore; private recovery remains required.'}
   }else{Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue}
  }
 }
 if($removeCertificateDirectory){
  # Never recurse here: unrelated or newly arriving files must cause refusal.
  if(@(Get-ChildItem -LiteralPath $certificateDirectory -Force -ErrorAction Stop).Count){throw 'The new DTLS parent is not empty; it was preserved.'}
  [IO.Directory]::Delete($certificateDirectory,$false)
  if(Test-Path -LiteralPath $certificateDirectory){throw 'The original DTLS parent absence did not restore.'}
 }
 foreach($entry in $record.Directories.PSObject.Properties){
  if($entry.Name -notin 'backup-runtime','acme-runtime','mobile-notifications','mail-state','meet-proxy','tenant-domains','stun-setup','dtls-setup','phone-health-runtime','updater-slots','automatic-backups','backup-restore','backup-control','backup-downloads','codec-compiler-cache','codec-build','openweb-music'){throw 'The support recovery folder inventory is invalid.'}
  $target=Check-SupportPath $entry.Value.Path
  if($entry.Value.Exists){
   CopyTree (Join-Path $Backup $entry.Name) $target -Mirror
   # Robocopy can return accepted exit3 while a running extra image remains.
   if($entry.Name -ceq 'updater-slots'){Assert-OpenWebUpdaterSlotsRestored -Source (Join-Path $Backup $entry.Name) -Target $target}
  }
  elseif($entry.Name -ceq 'updater-slots'){
   if(Test-Path -LiteralPath $target){Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop}
   if(Test-Path -LiteralPath $target){throw 'The original updater-slot absence did not restore; recovery remains required.'}
  }
  elseif($entry.Name -ceq 'dtls-setup'){
   if(!$target.Equals([IO.Path]::GetFullPath((Join-Path $StateRoot 'dtls-setup')),[StringComparison]::OrdinalIgnoreCase)){throw 'The DTLS recovery directory does not match its owned path.'}
   if(Test-Path -LiteralPath $target){Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop}
   if(Test-Path -LiteralPath $target){throw 'The original DTLS state absence did not restore; private recovery remains required.'}
  }else{Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue}
 }
 . (Join-Path $PSScriptRoot 'File-Security.ps1')
 $permissions=New-Object 'Collections.Generic.List[object]'
 foreach($entry in $record.Acls.PSObject.Properties){
  $target=Check-SupportPath $entry.Name
  if(!(Test-Path -LiteralPath $target)){throw 'A support recovery permission target is missing.'}
  $item=Get-Item -LiteralPath $target -Force
  if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'A support recovery permission target is a link or junction.'}
  if($entry.Value -isnot [string] -or !$entry.Value -or $entry.Value.Length -gt 131072){throw 'A support recovery permission snapshot is invalid.'}
  $permissions.Add(@{Path=$target;Directory=[bool]$item.PSIsContainer;Depth=$target.Split('\').Count;Sddl=$entry.Value})
 }
 # Native inheritance can update descendants; finish parents before their files.
 foreach($permission in ($permissions|Sort-Object @{Expression={if($_.Directory){0}else{1}}},Depth,Path)){
  Set-OpenWebFileSddl -LiteralPath $permission.Path -Sddl $permission.Sddl
 }
 foreach($entry in $record.Tasks.PSObject.Properties){
  if($entry.Name -notin 'OpenWebPBX-Backups','OpenWebPBX Outgoing Mail','OpenWebPBX-TenantDomains','OpenWebPBX-PhoneHealth','OpenWebPBX-Updater-Restart','OpenWebPBX-Cleanup'){throw 'The support recovery task inventory is invalid.'}
  if($entry.Value.Exists){
   Register-ScheduledTask -TaskName $entry.Name -Xml (Get-Content "$Backup\$($entry.Name).xml" -Raw) -Force | Out-Null
   if($entry.Value.Enabled){Enable-ScheduledTask -TaskName $entry.Name | Out-Null}else{Disable-ScheduledTask -TaskName $entry.Name | Out-Null}
   if($entry.Value.Security){
    $scheduler=New-Object -ComObject Schedule.Service;$scheduler.Connect();$nativeTask=$scheduler.GetFolder('\').GetTask($entry.Name)
    $nativeTask.SetSecurityDescriptor([string]$entry.Value.Security,0x10)
    if(!(Test-OpenWebTaskSecurityEquivalent ([string]$entry.Value.Security) ($nativeTask.GetSecurityDescriptor(7)))){throw 'The original scheduled-task security did not restore.'}
   }
   if($entry.Value.FileAcl){
    $taskFile=Join-Path $env:SystemRoot ('System32\Tasks\'+$entry.Name)
    $acl=[Security.AccessControl.FileSecurity]::new();$acl.SetSecurityDescriptorSddlForm([string]$entry.Value.FileAcl)
    Set-Acl -LiteralPath $taskFile -AclObject $acl
    if((Get-Acl -LiteralPath $taskFile).Sddl -ne $entry.Value.FileAcl){throw 'The original scheduled-task file permissions did not restore.'}
    if($entry.Value.Security -and !(Test-OpenWebTaskSecurityEquivalent ([string]$entry.Value.Security) ($nativeTask.GetSecurityDescriptor(7)))){throw 'Scheduled-task file restoration changed its original security.'}
   }
  }else{Unregister-ScheduledTask -TaskName $entry.Name -Confirm:$false -ErrorAction SilentlyContinue}
 }
 $filter="system.webServer/fastCgi/application[@fullPath='$Root\php\php-cgi.exe']/environmentVariables"
 if($record.PhpEnvironment.Exists){
  Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter "$filter/environmentVariable[@name='OPENSSL_CONF']" -Name value -Value $record.PhpEnvironment.Value
 }else{
  Remove-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter $filter -Name '.' -AtElement @{name='OPENSSL_CONF'} -ErrorAction SilentlyContinue
 }
 if($null -eq $record.PhpEnvironment.ProcessValue){Remove-Item Env:\OPENSSL_CONF -ErrorAction SilentlyContinue}else{$env:OPENSSL_CONF=$record.PhpEnvironment.ProcessValue}
}
