# Dot-sourced by the trusted upgrade transaction while upgrade.lock is held.
function Save-OpenWebSupport {
 param([string]$Backup,[string]$PackageRoot,[string]$Root,[string]$StateRoot,[string]$EngineRoot)
 $record=[ordered]@{schema=1;Files=@{};Directories=@{};Acls=@{};Tasks=@{};OpenSshClient=(Get-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0).State.ToString()}
 $fastcgi="$Root\php\php-cgi.exe"
 $filter="system.webServer/fastCgi/application[@fullPath='$fastcgi']/environmentVariables/environmentVariable[@name='OPENSSL_CONF']"
 $environment=Get-WebConfiguration -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter $filter
 $record.PhpEnvironment=@{Exists=[bool]$environment;Value=if($environment){[string]$environment.value}else{''};ProcessValue=$env:OPENSSL_CONF}
 $files=@("$Root\php\php.ini","$Root\php\extras\ssl\openssl.cnf","$Root\php\extras\ssl\cacert.pem","$StateRoot\native-engine.json","$StateRoot\local-codec.json","$StateRoot\updater-original-startup.json","$EngineRoot\libbcg729.dll")
 $native=Get-Content "$PackageRoot\engine\native-manifest.json" -Raw | ConvertFrom-Json
 foreach($entry in $native.files.PSObject.Properties){if($entry.Name -notlike 'mod/*'){$files+=Join-Path $EngineRoot $entry.Name}}
 $index=0
 foreach($path in $files){
  $exists=Test-Path -LiteralPath $path -PathType Leaf
  $copy='support-files/'+($index++)
  $record.Files[$path]=@{Exists=$exists;Copy=$copy}
  if($exists){New-Item -ItemType Directory -Force "$Backup\support-files" | Out-Null;Copy-Item -LiteralPath $path -Destination (Join-Path $Backup $copy);$record.Acls[$path]=(Get-Acl -LiteralPath $path).Sddl}
 }
 $directories=@{'backup-runtime'="$Root\backup-runtime";'acme-runtime'="$Root\acme";'mobile-notifications'="$StateRoot\mobile-notifications";'mail-state'="$StateRoot\mail";'updater-slots'="$Root\updater\slots"}
 foreach($name in $directories.Keys){
  $path=$directories[$name];$exists=Test-Path -LiteralPath $path -PathType Container
  $record.Directories[$name]=@{Path=$path;Exists=$exists}
  if($exists){CopyTree $path (Join-Path $Backup $name)}
 }
 foreach($path in @("$Root\tools","$EngineRoot\mod","$EngineRoot\sounds","$EngineRoot\conf","$StateRoot\mobile-notifications","$StateRoot\mail","$Root\backup-runtime","$Root\acme","$Root\updater")){
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
  if($task){Export-ScheduledTask -TaskName $name | Set-Content "$Backup\$name.xml" -Encoding UTF8;if($name -in 'OpenWebPBX-Backups','OpenWebPBX Outgoing Mail','OpenWebPBX-Cleanup'){Disable-ScheduledTask -TaskName $name | Out-Null}}
 }
 WriteState "$Backup\support-state.json" $record
}
function Restore-OpenWebSupport {
 param([string]$Backup,[string]$Root,[string]$StateRoot,[string]$EngineRoot)
 if(!(Test-Path "$Backup\support-state.json")){return} # Old immutable backups.
 $record=Get-Content "$Backup\support-state.json" -Raw | ConvertFrom-Json
 if($record.schema -ne 1){throw 'The support recovery inventory is invalid.'}
 $allowed=@("$Root\php","$Root\backup-runtime","$Root\acme","$Root\tools","$Root\updater","$StateRoot\native-engine.json","$StateRoot\local-codec.json","$StateRoot\updater-original-startup.json","$StateRoot\mobile-notifications","$StateRoot\mail","$EngineRoot")
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
  if($entry.Name -notin 'backup-runtime','acme-runtime','mobile-notifications','mail-state','updater-slots'){throw 'The support recovery folder inventory is invalid.'}
  $target=Check-SupportPath $entry.Value.Path
  if($entry.Value.Exists){CopyTree (Join-Path $Backup $entry.Name) $target -Mirror}
  else{Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue}
 }
 foreach($entry in $record.Acls.PSObject.Properties){
  $target=Check-SupportPath $entry.Name
  if(!(Test-Path -LiteralPath $target)){throw 'A support recovery permission target is missing.'}
  $item=Get-Item -LiteralPath $target -Force
  if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'A support recovery permission target is a link or junction.'}
  $acl=if($item.PSIsContainer){[Security.AccessControl.DirectorySecurity]::new()}else{[Security.AccessControl.FileSecurity]::new()}
  $acl.SetSecurityDescriptorSddlForm([string]$entry.Value);Set-Acl -LiteralPath $target -AclObject $acl
 }
 foreach($entry in $record.Tasks.PSObject.Properties){
  if($entry.Name -notin 'OpenWebPBX-Backups','OpenWebPBX Outgoing Mail','OpenWebPBX-Updater-Restart','OpenWebPBX-Cleanup'){throw 'The support recovery task inventory is invalid.'}
  if($entry.Value.Exists){
   Register-ScheduledTask -TaskName $entry.Name -Xml (Get-Content "$Backup\$($entry.Name).xml" -Raw) -Force | Out-Null
   if(!$entry.Value.Enabled){Disable-ScheduledTask -TaskName $entry.Name | Out-Null}
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
