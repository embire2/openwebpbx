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
function Save-OpenWebSupport {
 param([string]$Backup,[string]$PackageRoot,[string]$Root,[string]$StateRoot,[string]$EngineRoot)
 $record=[ordered]@{schema=1;Files=@{};Directories=@{};Acls=@{};Tasks=@{};OpenSshClient=(Get-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0).State.ToString()}
 $fastcgi="$Root\php\php-cgi.exe"
 $filter="system.webServer/fastCgi/application[@fullPath='$fastcgi']/environmentVariables/environmentVariable[@name='OPENSSL_CONF']"
 $environment=Get-WebConfiguration -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter $filter
 $record.PhpEnvironment=@{Exists=[bool]$environment;Value=if($environment){[string]$environment.value}else{''};ProcessValue=$env:OPENSSL_CONF}
 $files=@("$Root\php\php.ini","$Root\php\extras\ssl\openssl.cnf","$Root\php\extras\ssl\cacert.pem","$StateRoot\native-engine.json","$StateRoot\local-codec.json","$StateRoot\updater-original-startup.json","$StateRoot\updater-install.json","$StateRoot\installation.json","$EngineRoot\libbcg729.dll")
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
  'backup-runtime'="$Root\backup-runtime";'acme-runtime'="$Root\acme";'mobile-notifications'="$StateRoot\mobile-notifications";'mail-state'="$StateRoot\mail";'updater-slots'="$Root\updater\slots"
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
 foreach($path in @("$Root\web","$Root\server","$Root\desktop","$Root\tools","$EngineRoot\mod","$EngineRoot\sounds","$EngineRoot\conf","$StateRoot\mobile-notifications","$StateRoot\mail","$Root\backup-runtime","$Root\acme","$Root\updater","$StateRoot\automatic-backups","$StateRoot\backup-restore","$StateRoot\backup-control","$StateRoot\backup-downloads","$StateRoot\codec-compiler-cache","$StateRoot\codec-build","$StateRoot\storage\openweb-music")){
  if(Test-Path -LiteralPath $path -PathType Container){
   $record.Acls[$path]=(Get-Acl -LiteralPath $path).Sddl
   foreach($item in Get-ChildItem -LiteralPath $path -Force -Recurse){
    if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'An owned support folder contains a link or junction.'}
    $record.Acls[$item.FullName]=(Get-Acl -LiteralPath $item.FullName).Sddl
   }
  }
 }
 foreach($name in 'OpenWebPBX-Backups','OpenWebPBX Outgoing Mail','OpenWebPBX-Updater-Restart','OpenWebPBX-Cleanup'){
  $task=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
  $record.Tasks[$name]=@{Exists=[bool]$task;Enabled=if($task){[bool]$task.Settings.Enabled}else{$false}}
  if($task){
   $scheduler=New-Object -ComObject Schedule.Service;$scheduler.Connect()
   $record.Tasks[$name].Security=$scheduler.GetFolder('\').GetTask($name).GetSecurityDescriptor(7)
   $record.Tasks[$name].FileAcl=(Get-Acl -LiteralPath (Join-Path $env:SystemRoot ('System32\Tasks\'+$name))).Sddl
   Export-ScheduledTask -TaskName $name | Set-Content "$Backup\$name.xml" -Encoding UTF8
   if($name -in 'OpenWebPBX-Backups','OpenWebPBX Outgoing Mail','OpenWebPBX-Cleanup'){Disable-ScheduledTask -TaskName $name | Out-Null}
  }
 }
 WriteState "$Backup\support-state.json" $record
}
function Restore-OpenWebSupport {
 param([string]$Backup,[string]$Root,[string]$StateRoot,[string]$EngineRoot)
 if(!(Test-Path "$Backup\support-state.json")){return} # Old immutable backups.
 $record=Get-Content "$Backup\support-state.json" -Raw | ConvertFrom-Json
 if($record.schema -ne 1){throw 'The support recovery inventory is invalid.'}
 $allowed=@($Root,"$StateRoot\native-engine.json","$StateRoot\local-codec.json","$StateRoot\updater-original-startup.json","$StateRoot\updater-install.json","$StateRoot\installation.json","$StateRoot\mobile-notifications","$StateRoot\mail","$StateRoot\automatic-backups","$StateRoot\backup-restore","$StateRoot\backup-control","$StateRoot\backup-downloads","$StateRoot\codec-compiler-cache","$StateRoot\codec-build","$StateRoot\storage\openweb-music","$EngineRoot")
 function Check-SupportPath([string]$Path){
  $full=[IO.Path]::GetFullPath($Path);$valid=$false
  foreach($base in $allowed){if($full.Equals($base,[StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($base.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){$valid=$true;break}}
  if(!$valid){throw 'A support recovery path is outside the owned installation.'}
  return $full
 }
 if(Test-Path "$Backup\switch-mod"){CopyTree "$Backup\switch-mod" "$EngineRoot\mod" -Mirror}
 if(Test-Path "$Backup\switch-sounds"){CopyTree "$Backup\switch-sounds" "$EngineRoot\sounds" -Mirror}
 foreach($entry in $record.Files.PSObject.Properties){
  $target=Check-SupportPath $entry.Name
  if($entry.Value.Exists){
   if($entry.Value.Copy -notmatch '^support-files/[0-9]+$'){throw 'The support recovery file inventory is invalid.'}
   New-Item -ItemType Directory -Force (Split-Path $target -Parent) | Out-Null
   Copy-Item -LiteralPath (Join-Path $Backup $entry.Value.Copy) -Destination $target -Force
  }else{Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue}
 }
 foreach($entry in $record.Directories.PSObject.Properties){
  if($entry.Name -notin 'backup-runtime','acme-runtime','mobile-notifications','mail-state','updater-slots','automatic-backups','backup-restore','backup-control','backup-downloads','codec-compiler-cache','codec-build','openweb-music'){throw 'The support recovery folder inventory is invalid.'}
  $target=Check-SupportPath $entry.Value.Path
  if($entry.Value.Exists){CopyTree (Join-Path $Backup $entry.Name) $target -Mirror}
  else{Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue}
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
  if($entry.Name -notin 'OpenWebPBX-Backups','OpenWebPBX Outgoing Mail','OpenWebPBX-Updater-Restart','OpenWebPBX-Cleanup'){throw 'The support recovery task inventory is invalid.'}
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
