# WindowsPhone public metadata only. Callers stage under the actual shared maintenance lock.
. (Join-Path $PSScriptRoot 'UpgradeRecovery.Common.ps1')
. (Join-Path $PSScriptRoot 'File-Security.ps1')
. (Join-Path $PSScriptRoot 'Restore-Gates.ps1')
$script:WindowsPhoneCatalogueTask='OpenWebPBX-WindowsPhoneCatalogue'
function Get-OpenWebWindowsPhoneCatalogueTaskHash {
 param([string]$Xml)
 if(!$Xml -or $Xml.Length -gt 1048576){throw 'The catalogue task definition is invalid.'}
 $settings=[Xml.XmlReaderSettings]::new();$settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit;$settings.XmlResolver=$null;$settings.MaxCharactersInDocument=1048576
 $reader=[Xml.XmlReader]::Create([IO.StringReader]::new($Xml),$settings);$document=[Xml.XmlDocument]::new();$document.XmlResolver=$null
 try{$document.Load($reader)}finally{$reader.Dispose()};$enabled=@($document.SelectNodes('//*[local-name()="Settings"]/*[local-name()="Enabled"]'))
 if($enabled.Count -ne 1 -or $enabled[0].InnerText -cnotin 'true','false'){throw 'The catalogue task enabled choice is invalid.'}
 # Enabled is the one administrator-owned choice, independent of definition ownership.
 $enabled[0].InnerText='owned-enabled-choice';$sha=[Security.Cryptography.SHA256]::Create()
 try{return([BitConverter]::ToString($sha.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($document.OuterXml)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
}
function Write-OpenWebWindowsPhoneCatalogueState {
 param([string]$Path,$Value)
 $temporary=Join-Path (Split-Path $Path -Parent) ('.owned-'+[Guid]::NewGuid().ToString('N')+'.new');$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 5 -WarningAction Stop))
 $primary=$null
 try{$file=[IO.File]::Open($temporary,'CreateNew','Write','None');try{$file.Write($bytes,0,$bytes.Length);$file.Flush($true)}finally{$file.Dispose()};Initialize-OpenWebUpgradeRecoveryNative;[OpenWebPbx.UpgradeRecoveryNativeV1]::Commit($temporary,$Path)}catch{$primary=$_;throw}finally{try{if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force -ErrorAction Stop}}catch{if(!$primary){throw};$primary.Exception.Data['catalogue_owned_temporary_cleanup_failed']=$true}}
}
function Get-OpenWebWindowsPhoneCataloguePaths {
 param([string]$Root='C:\OpenWebPBX',[string]$StateRoot=(Join-Path $env:ProgramData 'OpenWebPBX'))
 [pscustomobject]@{Root=[IO.Path]::GetFullPath($Root);StateRoot=[IO.Path]::GetFullPath($StateRoot);Directory=Join-Path $StateRoot 'windows-phone-catalogue';Php=Join-Path $Root 'php\php.exe';Ini=Join-Path $Root 'php\php.ini';Runner=Join-Path $Root 'tools\WindowsPhoneCatalogue.ps1';Worker=Join-Path $Root 'tools\windows-phone-catalogue.php';PublicKey=Join-Path $Root 'web\resources\windows-phone\release-public.pem';PowerShell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'}
}
function Assert-OpenWebWindowsPhoneCatalogueTask {
 param($Task,$Paths)
 if(!$Task){return}
 $principal=$Task.Principal.UserId
 if($principal -notin 'SYSTEM','S-1-5-18','NT AUTHORITY\SYSTEM'){throw 'A foreign WindowsPhone catalogue task was preserved.'}
 $expected='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$Paths.Runner+'" -Action Refresh'
 if($Task.TaskPath -cne '\' -or @($Task.Actions).Count -ne 1 -or $Task.Actions[0].Execute -ine $Paths.PowerShell -or $Task.Actions[0].Arguments -cne $expected -or $Task.Principal.LogonType -cne 'ServiceAccount' -or $Task.Principal.RunLevel -cne 'Highest'){throw 'A foreign WindowsPhone catalogue task action was preserved.'}
 if($Task.Settings.Enabled -isnot [bool]){throw 'The WindowsPhone catalogue task choice is invalid.'}
 if(!$Task.Settings.Enabled -and $Task.State -eq 'Running'){throw 'A disabled running WindowsPhone catalogue task needs review.'}
 $proofPath=Assert-OpenWebRecoveryProtected (Join-Path $Paths.Directory 'task.json')
 $proof=Get-Content -LiteralPath $proofPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
 if(@($proof.PSObject.Properties).Count -ne 4 -or ($proof.schema -isnot [int] -and $proof.schema -isnot [long]) -or $proof.schema -ne 1 -or $proof.component -cne 'windows-free-phone' -or $proof.definition_sha256 -isnot [string] -or $proof.security -isnot [string]){throw 'The catalogue task ownership record is invalid.'}
 $hash=Get-OpenWebWindowsPhoneCatalogueTaskHash ([string](Export-ScheduledTask -TaskName $script:WindowsPhoneCatalogueTask -ErrorAction Stop))
 $scheduler=New-Object -ComObject Schedule.Service;$scheduler.Connect();$security=[string]$scheduler.GetFolder('\').GetTask($script:WindowsPhoneCatalogueTask).GetSecurityDescriptor(7)
 if($hash -cne $proof.definition_sha256 -or $security -cne $proof.security){throw 'Changed catalogue task triggers, settings or security were preserved.'}
}
function Assert-OpenWebWindowsPhoneCatalogueState {
 param($Paths,[string]$AllowedStage)
 if(!(Test-Path -LiteralPath $Paths.Directory)){return}
 $null=Assert-OpenWebRecoveryProtected -Path $Paths.Directory -Directory
 $marker=Join-Path $Paths.Directory 'owner.json'
 $null=Assert-OpenWebRecoveryProtected $marker
 $record=Get-Content -LiteralPath $marker -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
 if(@($record.PSObject.Properties).Count -ne 3 -or $record.schema -isnot [int] -and $record.schema -isnot [long] -or $record.schema -ne 1 -or $record.component -cne 'windows-free-phone' -or $record.key_id -cne 'windows-phone-release-1'){throw 'A foreign WindowsPhone catalogue state directory was preserved.'}
 foreach($item in Get-ChildItem -LiteralPath $Paths.Directory -Force){
  $stage=$AllowedStage -and $item.FullName -ieq [IO.Path]::GetFullPath($AllowedStage) -and $item.Name -cmatch '^\.(accepted-[0-9a-f]{64}|publication-[0-9a-f]{32})\.new$'
  if($item.PSIsContainer -or (!$stage -and $item.Name -cnotin 'owner.json','refresh.lock','accepted.json','publication.json','task.json','activation.json')){throw 'Unknown WindowsPhone catalogue state was preserved.'}
  $null=Assert-OpenWebRecoveryProtected $item.FullName
 }
}
function Set-OpenWebWindowsPhoneCatalogueDirectory {
 param($Paths)
 Assert-OpenWebWindowsPhoneCatalogueState $Paths
 if(Test-Path -LiteralPath $Paths.Directory){return}
 $null=Assert-OpenWebRecoveryProtected -Path $Paths.StateRoot -Directory
 $acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetAccessRuleProtection($true,$false)
 foreach($sid in 'S-1-5-18','S-1-5-32-544'){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),[Security.AccessControl.FileSystemRights]::FullControl,[Security.AccessControl.InheritanceFlags]'ObjectInherit,ContainerInherit',[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow))}
 $web=[Security.Principal.NTAccount]::new('IIS AppPool\OpenWebPBX').Translate([Security.Principal.SecurityIdentifier])
 $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($web,[Security.AccessControl.FileSystemRights]::ReadAndExecute,[Security.AccessControl.InheritanceFlags]'ObjectInherit,ContainerInherit',[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow))
 # StateRoot is protected; source/upgrade rollback snapshots preserve original absence.
 $null=New-Item -ItemType Directory -Path $Paths.Directory -ErrorAction Stop;Set-Acl -LiteralPath $Paths.Directory -AclObject $acl -ErrorAction Stop
 $bytes=[Text.UTF8Encoding]::new($false).GetBytes('{"schema":1,"component":"windows-free-phone","key_id":"windows-phone-release-1"}')
 $stream=[IO.File]::Open((Join-Path $Paths.Directory 'owner.json'),'CreateNew','Write','None');try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
 $stream=[IO.File]::Open((Join-Path $Paths.Directory 'refresh.lock'),'CreateNew','Write','None');try{$stream.Flush($true)}finally{$stream.Dispose()}
 Assert-OpenWebWindowsPhoneCatalogueState $Paths
}
function Stop-OpenWebWindowsPhoneCatalogue {
 param($Paths,[IO.FileStream]$MaintenanceLock)
 Assert-OpenWebRecoveryLock -MaintenanceLock $MaintenanceLock -StateRoot $Paths.StateRoot
 $task=Get-ScheduledTask -TaskName $script:WindowsPhoneCatalogueTask -ErrorAction SilentlyContinue;Assert-OpenWebWindowsPhoneCatalogueTask $task $Paths
 if($task){Disable-ScheduledTask -TaskName $script:WindowsPhoneCatalogueTask|Out-Null;if($task.State -eq 'Running'){Stop-ScheduledTask -TaskName $script:WindowsPhoneCatalogueTask}}
 for($attempt=0;$attempt -lt 40;$attempt++){
  $children=@(Get-CimInstance Win32_Process -Filter "Name='php.exe'" -ErrorAction Stop|Where-Object {$_.ExecutablePath -ieq $Paths.Php -and $_.CommandLine -and $_.CommandLine.Contains($Paths.Worker)})
  $current=Get-ScheduledTask -TaskName $script:WindowsPhoneCatalogueTask -ErrorAction SilentlyContinue
  if(!$children.Count -and (!$current -or $current.State -ne 'Running')){return}
  Start-Sleep -Milliseconds 250
 }
 throw 'The owned WindowsPhone catalogue worker did not stop; no helper was replaced.'
}
function Install-OpenWebWindowsPhoneCatalogue {
 param([string]$PackageRoot,[ValidateSet('install','upgrade')][string]$Owner,[string]$Root='C:\OpenWebPBX',[string]$StateRoot=(Join-Path $env:ProgramData 'OpenWebPBX'),[IO.FileStream]$MaintenanceLock)
 Assert-OpenWebRecoveryLock -MaintenanceLock $MaintenanceLock -StateRoot $StateRoot
 $paths=Get-OpenWebWindowsPhoneCataloguePaths $Root $StateRoot
 foreach($file in $paths.Php,$paths.Ini,$paths.PublicKey){$null=Assert-OpenWebRecoveryProtected $file}
 $manifest=Get-Content -LiteralPath (Join-Path $PackageRoot 'release-manifest.json') -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
 $version=(Get-Content -LiteralPath (Join-Path $PackageRoot 'VERSION') -Raw -Encoding UTF8).Trim();if($version -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'){throw 'The catalogue activation version is invalid.'}
 $names=@('WindowsPhoneCatalogue.Common.ps1','WindowsPhoneCatalogue.ps1','Install-WindowsPhoneCatalogue.ps1','windows-phone-catalogue.php')
 foreach($name in $names){$file=Assert-OpenWebRecoveryProtected (Join-Path $PackageRoot $name);if((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -cne $manifest.files.$name){throw 'The WindowsPhone catalogue helper differs from the signed release.'}}
 $task=Get-ScheduledTask -TaskName $script:WindowsPhoneCatalogueTask -ErrorAction SilentlyContinue;Assert-OpenWebWindowsPhoneCatalogueTask $task $paths;Assert-OpenWebWindowsPhoneCatalogueState $paths
 $originalEnabled=if($task){[bool]$task.Settings.Enabled}else{$false}
 try{
  Stop-OpenWebWindowsPhoneCatalogue $paths $MaintenanceLock
  Set-OpenWebWindowsPhoneCatalogueDirectory $paths
  foreach($name in $names){Copy-Item -LiteralPath (Join-Path $PackageRoot $name) -Destination (Join-Path $Root ('tools\'+$name)) -Force -ErrorAction Stop}
  $action=New-ScheduledTaskAction -Execute $paths.PowerShell -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$paths.Runner+'" -Action Refresh')
  $trigger=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Hours 6)
  $boot=New-ScheduledTaskTrigger -AtStartup;$principal=New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
  Register-ScheduledTask -TaskName $script:WindowsPhoneCatalogueTask -Action $action -Trigger @($trigger,$boot) -Principal $principal -Settings (New-ScheduledTaskSettingsSet -Disable -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances IgnoreNew -StartWhenAvailable) -Force|Out-Null
  Disable-ScheduledTask -TaskName $script:WindowsPhoneCatalogueTask|Out-Null
  $scheduler=New-Object -ComObject Schedule.Service;$scheduler.Connect();$scheduler.GetFolder('\').GetTask($script:WindowsPhoneCatalogueTask).SetSecurityDescriptor('D:P(A;;FA;;;SY)(A;;FA;;;BA)',0)
  Write-OpenWebWindowsPhoneCatalogueState -Path (Join-Path $paths.Directory 'task.json') -Value @{schema=1;component='windows-free-phone';definition_sha256=(Get-OpenWebWindowsPhoneCatalogueTaskHash ([string](Export-ScheduledTask -TaskName $script:WindowsPhoneCatalogueTask)));security=([string]$scheduler.GetFolder('\').GetTask($script:WindowsPhoneCatalogueTask).GetSecurityDescriptor(7))}
  $proof=Get-Content -LiteralPath (Join-Path $paths.Directory 'task.json') -Raw -Encoding UTF8|ConvertFrom-Json
  Write-OpenWebWindowsPhoneCatalogueState -Path (Join-Path $paths.Directory 'activation.json') -Value @{schema=1;component='windows-free-phone';owner=$Owner;version=$version;task_before_exists=[bool]$task;enable_on_commit=if($task){$originalEnabled}else{$true};phase='prepared';task_definition_sha256=$proof.definition_sha256}
 }catch{if($task -and $originalEnabled){try{Enable-ScheduledTask -TaskName $script:WindowsPhoneCatalogueTask|Out-Null}catch{}};throw}
}
function Complete-OpenWebWindowsPhoneCatalogueActivation {
 param([ValidateSet('install','upgrade')][string]$Owner,[string]$Root='C:\OpenWebPBX',[string]$StateRoot=(Join-Path $env:ProgramData 'OpenWebPBX'),[IO.FileStream]$MaintenanceLock)
 Assert-OpenWebRecoveryLock -MaintenanceLock $MaintenanceLock -StateRoot $StateRoot
 $paths=Get-OpenWebWindowsPhoneCataloguePaths $Root $StateRoot;$path=Join-Path $paths.Directory 'activation.json'
 if(!(Test-Path -LiteralPath $path)){return}
 $null=Assert-OpenWebRecoveryProtected $path;$record=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
 if(@($record.PSObject.Properties).Count -ne 8 -or ($record.schema -isnot [int] -and $record.schema -isnot [long]) -or $record.schema -ne 1 -or $record.component -cne 'windows-free-phone' -or $record.owner -isnot [string] -or $record.owner -cnotin 'install','upgrade' -or $record.version -isnot [string] -or $record.enable_on_commit -isnot [bool] -or $record.task_before_exists -isnot [bool] -or (!$record.task_before_exists -and !$record.enable_on_commit) -or $record.phase -isnot [string] -or $record.phase -cnotin 'prepared','complete' -or $record.task_definition_sha256 -isnot [string] -or $record.task_definition_sha256 -cnotmatch '^[a-f0-9]{64}$'){throw 'The catalogue activation intent is invalid; it was preserved.'}
 # A terminal intent never overrides a later administrator enabled choice.
 if($record.phase -ceq 'complete'){return}
 if($record.owner -cne $Owner){throw 'A different catalogue activation origin must recover normally.'}
 $installed=Get-Content -LiteralPath (Join-Path $StateRoot 'installation.json') -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
 $version=(Get-Content -LiteralPath (Join-Path $Root 'web\VERSION') -Raw -Encoding UTF8).Trim()
 if($installed.Completed -isnot [bool] -or !$installed.Completed -or $installed.Version -isnot [string] -or $installed.Version -cne $record.version -or $version -cne $record.version){throw 'The catalogue activation has no matching completed installation.'}
 Assert-OpenWebUpgradeAllowed -StateRoot $StateRoot
 $journal=Join-Path $StateRoot 'updates\install-journal.json'
 if($Owner -ceq 'install'){if(Test-Path -LiteralPath $journal){throw 'An update journal must recover before fresh catalogue activation.'}}
 else{$j=Get-Content -LiteralPath $journal -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop;if($j.state -cne 'completed' -or $j.version -cne $record.version){throw 'Catalogue upgrade activation requires its matching durable completed journal.'}}
 $task=Get-ScheduledTask -TaskName $script:WindowsPhoneCatalogueTask -ErrorAction Stop;Assert-OpenWebWindowsPhoneCatalogueTask $task $paths
 $proof=Get-Content -LiteralPath (Join-Path $paths.Directory 'task.json') -Raw -Encoding UTF8|ConvertFrom-Json
 if($proof.definition_sha256 -cne $record.task_definition_sha256){throw 'Catalogue activation belongs to a different task definition.'}
 if($record.enable_on_commit){Enable-ScheduledTask -TaskName $script:WindowsPhoneCatalogueTask|Out-Null}else{Disable-ScheduledTask -TaskName $script:WindowsPhoneCatalogueTask|Out-Null}
 $verified=Get-ScheduledTask -TaskName $script:WindowsPhoneCatalogueTask -ErrorAction Stop
 if([bool]$verified.Settings.Enabled -cne $record.enable_on_commit){throw 'The catalogue enabled choice did not apply; activation remains prepared.'}
 $record.phase='complete';Write-OpenWebWindowsPhoneCatalogueState -Path $path -Value $record
}
function Start-OpenWebWindowsPhoneCatalogue {
 param([string]$Root='C:\OpenWebPBX',[string]$StateRoot=(Join-Path $env:ProgramData 'OpenWebPBX'))
 $paths=Get-OpenWebWindowsPhoneCataloguePaths $Root $StateRoot;$task=Get-ScheduledTask -TaskName $script:WindowsPhoneCatalogueTask -ErrorAction Stop;Assert-OpenWebWindowsPhoneCatalogueTask $task $paths;Assert-OpenWebWindowsPhoneCatalogueState $paths
 if($task.Settings.Enabled){Start-ScheduledTask -TaskName $script:WindowsPhoneCatalogueTask}
}
function Assert-OpenWebWindowsPhoneCatalogueRollback {
 param([string]$PackageRoot,[string]$Backup,[string]$Root='C:\OpenWebPBX',[string]$StateRoot=(Join-Path $env:ProgramData 'OpenWebPBX'),[IO.FileStream]$MaintenanceLock)
 Assert-OpenWebRecoveryLock -MaintenanceLock $MaintenanceLock -StateRoot $StateRoot
 $paths=Get-OpenWebWindowsPhoneCataloguePaths $Root $StateRoot;Assert-OpenWebWindowsPhoneCatalogueState $paths
 if(!(Test-Path -LiteralPath (Join-Path $paths.Directory 'accepted.json')) -and !(Test-Path -LiteralPath (Join-Path $paths.Directory 'publication.json'))){return}
 foreach($file in $paths.Php,$paths.Ini,$paths.PublicKey){$null=Assert-OpenWebRecoveryProtected $file}
 $helper=Assert-OpenWebRecoveryProtected (Join-Path $PackageRoot 'windows-phone-catalogue.php')
 $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$paths.Php;$start.Arguments='-c "'+$paths.Ini+'" "'+$helper+'" --rollback-check "'+(Join-Path $Backup 'windows-phone-catalogue')+'"';$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $child=[Diagnostics.Process]::new();$child.StartInfo=$start
 try{if(!$child.Start()){throw 'The read-only catalogue rollback check did not start.'};$out=$child.StandardOutput.ReadToEndAsync();$err=$child.StandardError.ReadToEndAsync();if(!$child.WaitForExit(15000)){try{$child.Kill()}catch{};throw 'The catalogue rollback preflight exceeded its deadline.'};if(!$out.Wait(2000) -or !$err.Wait(2000) -or $out.Result.Length -gt 1024 -or $err.Result.Length -gt 32768 -or $child.ExitCode -ne 0){throw 'Operator rollback would lower or conflict with machine WindowsPhone trust; no services or cache were changed.'};$r=$out.Result|ConvertFrom-Json -ErrorAction Stop;if($r.schema -ne 1 -or $r.state -cne 'rollback_allowed'){throw 'The catalogue rollback preflight was not verified.'}}finally{$child.Dispose()}
}
function Assert-OpenWebWindowsPhoneCatalogueParentLease {
 param($Paths)
 foreach($file in $Paths.Php,$Paths.Ini,$Paths.Worker){$null=Assert-OpenWebRecoveryProtected $file}
 $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$Paths.Php;$start.Arguments='-c "'+$Paths.Ini+'" "'+$Paths.Worker+'" --assert-exclusive';$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $child=[Diagnostics.Process]::new();$child.StartInfo=$start
 try{if(!$child.Start()){throw 'The parent-lease probe did not start.'};$out=$child.StandardOutput.ReadToEndAsync();$err=$child.StandardError.ReadToEndAsync();if(!$child.WaitForExit(15000)){try{$child.Kill()}catch{};throw 'The parent-lease probe exceeded its deadline.'};if(!$out.Wait(2000) -or !$err.Wait(2000) -or $out.Result.Length -gt 1024 -or $err.Result.Length -gt 32768 -or $child.ExitCode -ne 0){throw 'The exclusive parent catalogue byte lease was not verified.'};$r=$out.Result|ConvertFrom-Json -ErrorAction Stop;if($r.schema -ne 1 -or $r.state -cne 'exclusive_parent_held'){throw 'The parent-lease probe returned an invalid observation.'}}finally{$child.Dispose()}
}
