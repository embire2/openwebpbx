#Requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PackageRoot,[switch]$DeferRestart,[switch]$UpgradeLockHeld)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$root='C:\OpenWebPBX';$private=Join-Path $env:ProgramData 'OpenWebPBX';$lock=$null
. (Join-Path $PackageRoot 'PhoneHealth-Security.ps1')
. (Join-Path $PackageRoot 'Uploads.Common.ps1')
function ProtectedDirectory([string]$Path,[string]$WebRights=''){
 $ancestor=[IO.Path]::GetFullPath($Path)
 while($ancestor){if(Test-Path -LiteralPath $ancestor){if((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Protected recovery paths must not contain links or junctions.'}};$parent=[IO.Path]::GetDirectoryName($ancestor);if($parent -eq $ancestor){break};$ancestor=$parent}
 New-Item -ItemType Directory -Path $Path -Force|Out-Null
 $acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetAccessRuleProtection($true,$false);$acl.SetOwner([Security.Principal.SecurityIdentifier]'S-1-5-32-544')
 foreach($sid in 'S-1-5-18','S-1-5-32-544'){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]$sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
 foreach($pool in 'OpenWebPBX','OpenWebPBXUploadGate'){
  if($WebRights){$sid=([Security.Principal.NTAccount]('IIS AppPool\'+$pool)).Translate([Security.Principal.SecurityIdentifier]);$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,$WebRights,'ContainerInherit,ObjectInherit','None','Allow'))}
 }
 Set-Acl -LiteralPath $Path -AclObject $acl
}
try{
 if(!$UpgradeLockHeld){$lock=[IO.File]::Open("$private\upgrade.lock",'OpenOrCreate','ReadWrite','None')}
 $null=Assert-OpenWebHealthProtectedPath "$root\tools" -Directory
 $null=Assert-OpenWebHealthProtectedPath "$root\backup-runtime" -Directory
 $manifest=Get-Content -LiteralPath "$PackageRoot\release-manifest.json" -Raw -Encoding UTF8|ConvertFrom-Json
 $names=@('Install-Reseller.ps1','Protection-Worker.ps1','protection.py','configure-reseller.php','UploadAdmission.cs','upload-gate.php','Uploads.Common.ps1')
 foreach($name in $names){$path=Join-Path $PackageRoot $name;$item=Get-Item -LiteralPath $path -Force;if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $manifest.files.$name){throw 'A reseller/recovery helper differs from this verified release.'}}
 $task=Get-ScheduledTask -TaskName OpenWebPBX-Protection -ErrorAction SilentlyContinue
 if($task){
  if(@($task.Actions).Count -ne 1 -or [string]$task.Actions[0].Execute -ine "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -or [string]$task.Actions[0].Arguments -cne '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\OpenWebPBX\tools\Protection-Worker.ps1"' -or [string]$task.Principal.UserId -notin 'SYSTEM','S-1-5-18'){throw 'Preserve and review the custom recovery task.'}
  Disable-ScheduledTask -TaskName OpenWebPBX-Protection|Out-Null
  if($task.State -eq 'Running'){throw 'The previous recovery worker is still running; no helper was replaced.'}
 }
 $features=Install-WindowsFeature Web-Asp-Net45,Web-Net-Ext45
 if(!$features.Success -or $features.RestartNeeded -eq 'Yes'){throw 'Restart Windows to finish its IIS runtime installation, then run setup again.'}
 Import-Module WebAdministration
 Assert-OpenWebUploadObjects
 if(!(Test-Path IIS:\AppPools\OpenWebPBXUploadGate)){New-WebAppPool -Name OpenWebPBXUploadGate|Out-Null;Set-ItemProperty IIS:\AppPools\OpenWebPBXUploadGate managedRuntimeVersion ''}
 Set-ItemProperty IIS:\AppPools\OpenWebPBX managedRuntimeVersion 'v4.0'
 Set-ItemProperty IIS:\AppPools\OpenWebPBX managedPipelineMode 'Integrated'
 Add-Type -Path "$env:windir\System32\inetsrv\Microsoft.Web.Administration.dll"
 $manager=New-Object Microsoft.Web.Administration.ServerManager
 try{
  foreach($sectionPath in 'system.webServer/handlers','system.webServer/modules','system.webServer/serverRuntime'){$section=$manager.GetApplicationHostConfiguration().GetSection($sectionPath,'OpenWebPBX');$section.OverrideMode=[Microsoft.Web.Administration.OverrideMode]::Allow}
  $manager.CommitChanges()
 }finally{$manager.Dispose()}
 foreach($path in 'tenant-backups','protection'){ProtectedDirectory (Join-Path $private $path)}
 foreach($path in 'tenant-backup-downloads','protection-status','upload-admission'){ProtectedDirectory (Join-Path $private $path) 'ReadAndExecute'}
 ProtectedDirectory "$private\protection-inbox" 'Modify'
 ProtectedDirectory "$root\upload-gate" 'ReadAndExecute'
 foreach($name in $names){Copy-Item -LiteralPath (Join-Path $PackageRoot $name) -Destination "$root\tools\$name" -Force}
 $key="$private\upload-admission\gate.key"
 if(Test-Path -LiteralPath $key){if((Get-Item -LiteralPath $key -Force).Attributes -band [IO.FileAttributes]::ReparsePoint -or [IO.File]::ReadAllText($key) -cnotmatch '^[a-f0-9]{64}$'){throw 'The private upload-admission identity needs review.'}}
 else{$bytes=New-Object byte[] 32;$random=[Security.Cryptography.RandomNumberGenerator]::Create();try{$random.GetBytes($bytes)}finally{$random.Dispose()};[IO.File]::WriteAllText($key,[BitConverter]::ToString($bytes).Replace('-','').ToLowerInvariant(),[Text.UTF8Encoding]::new($false))}
 $phpini=[IO.File]::ReadAllText("$root\php\php.ini")
 $phpini+="`r`nenable_post_data_reading=Off`r`nmemory_limit=128M`r`nmax_execution_time=1800`r`nmax_input_time=1800`r`n"
 [IO.File]::WriteAllText("$private\upload-admission\php.ini",$phpini,[Text.UTF8Encoding]::new($false))
 Copy-Item -LiteralPath "$PackageRoot\upload-gate.php" -Destination "$root\upload-gate\index.php" -Force
 $gateConfig=@'
<?xml version="1.0" encoding="utf-8"?>
<configuration><system.webServer><handlers><clear/><add name="OpenWebGate-PHP" path="index.php" verb="POST" modules="FastCgiModule" scriptProcessor="C:\OpenWebPBX\php\php-cgi.exe" resourceType="File" requireAccess="Script"/></handlers><security><requestFiltering><requestLimits maxAllowedContentLength="0"/></requestFiltering></security><httpErrors existingResponse="PassThrough"/></system.webServer></configuration>
'@
 [IO.File]::WriteAllText("$root\upload-gate\web.config",$gateConfig,[Text.UTF8Encoding]::new($false))
 $arguments=Get-OpenWebUploadArguments;$filter="system.webServer/fastCgi/application[@fullPath='$root\php\php-cgi.exe'][@arguments='$arguments']"
 if(!(Get-WebConfiguration -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter $filter)){Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter 'system.webServer/fastCgi' -Name '.' -Value @{fullPath="$root\php\php-cgi.exe";arguments=$arguments;activityTimeout=1800;requestTimeout=1800;instanceMaxRequests=100;maxInstances=2}}
 $envfilter=$filter+'/environmentVariables'
 if(!(Get-WebConfiguration -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter ($envfilter+"/environmentVariable[@name='OPENSSL_CONF']"))){Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter $envfilter -Name '.' -Value @{name='OPENSSL_CONF';value="$root\php\extras\ssl\openssl.cnf"}}
 New-Item -ItemType Directory -Path "$root\web\bin" -Force|Out-Null
 $assembly="$root\web\bin\OpenWebPbx.UploadAdmission.dll"
 if(Test-Path -LiteralPath $assembly){Remove-Item -LiteralPath $assembly -Force}
 Add-Type -Path "$PackageRoot\UploadAdmission.cs" -OutputAssembly $assembly -OutputType Library -ReferencedAssemblies 'System.dll','System.Web.dll'
 if(!(Get-Website -Name 'OpenWebPBX Upload Gate' -ErrorAction SilentlyContinue)){New-Website -Name 'OpenWebPBX Upload Gate' -PhysicalPath "$root\upload-gate" -ApplicationPool OpenWebPBXUploadGate -IPAddress 127.0.0.1 -Port 9089|Out-Null}
 $manager=New-Object Microsoft.Web.Administration.ServerManager
 try{$section=$manager.GetApplicationHostConfiguration().GetSection('system.webServer/handlers','OpenWebPBX Upload Gate');$section.OverrideMode=[Microsoft.Web.Administration.OverrideMode]::Allow;$manager.CommitChanges()}finally{$manager.Dispose()}
 Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Location 'OpenWebPBX Upload Gate' -Filter 'system.webServer/httpLogging' -Name dontLog -Value $true
 Start-WebAppPool -Name OpenWebPBXUploadGate -ErrorAction SilentlyContinue
 Start-Website -Name 'OpenWebPBX Upload Gate'
 # This pool reads the same session/database files as the application. It has
 # no write access to executable sources, private backups or runtime controls.
 foreach($path in "$private\sessions","$private\cache"){$sid=([Security.Principal.NTAccount]'IIS AppPool\OpenWebPBXUploadGate').Translate([Security.Principal.SecurityIdentifier]);$acl=Get-Acl -LiteralPath $path;$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'Modify','ContainerInherit,ObjectInherit','None','Allow'));Set-Acl -LiteralPath $path -AclObject $acl}
 foreach($path in (Join-Path $env:ProgramData 'fusionpbx'),"$root\web"){$sid=([Security.Principal.NTAccount]'IIS AppPool\OpenWebPBXUploadGate').Translate([Security.Principal.SecurityIdentifier]);$acl=Get-Acl -LiteralPath $path;$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow'));Set-Acl -LiteralPath $path -AclObject $acl}
 & "$root\php\php.exe" "$root\tools\configure-reseller.php" "$root\web"
 if($LASTEXITCODE){throw 'The current reseller/recovery schema could not be prepared.'}
 $action=New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\OpenWebPBX\tools\Protection-Worker.ps1"' -WorkingDirectory "$root\tools"
 $triggers=@((New-ScheduledTaskTrigger -AtStartup),(New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)))
 $principal=New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
 $settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 6) -MultipleInstances IgnoreNew -StartWhenAvailable
 Register-ScheduledTask -TaskName OpenWebPBX-Protection -Description 'OpenWeb PBX authenticated tenant and confirmed instance recovery' -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Force|Out-Null
 if($DeferRestart -or ($task -and !$task.Settings.Enabled) -or (Test-Path "$private\backup-restore\hold-jobs")){Disable-ScheduledTask -TaskName OpenWebPBX-Protection|Out-Null}
 Write-Host 'Reseller packages, scoped APIs, tenant recovery and isolated encrypted uploads installed.'
}finally{if($lock){$lock.Dispose()}}
