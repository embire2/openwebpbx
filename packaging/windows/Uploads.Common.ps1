# SPDX-License-Identifier: AGPL-3.0-or-later
# Fixed IIS objects owned by encrypted-backup admission, not public proxy rules.
function Get-OpenWebUploadArguments {return '-c "C:\ProgramData\OpenWebPBX\upload-admission\php.ini"'}
function Test-OpenWebUploadPoolIdentity {
 param($Value)
 # WebAdministration returns the canonical name on Windows PowerShell; the
 # administration API returns its enum. Do not coerce arbitrary values to 4.
 if($Value -is [string]){return $Value -ceq 'ApplicationPoolIdentity'}
 if($null -eq $Value){return $false}
 if($Value.GetType().FullName -ceq 'Microsoft.Web.Administration.ProcessModelIdentityType'){return [int]$Value -eq 4}
 if($Value -is [int] -or $Value -is [uint32]){return $Value -eq 4}
 return $false
}
function Assert-OpenWebUploadObjects {
 Import-Module WebAdministration
 $site=Get-Website -Name 'OpenWebPBX Upload Gate' -ErrorAction SilentlyContinue
 if($site){
  if([string]$site.physicalPath -ine 'C:\OpenWebPBX\upload-gate' -or [string]$site.applicationPool -cne 'OpenWebPBXUploadGate' -or @($site.bindings.Collection).Count -ne 1 -or [string]$site.bindings.Collection[0].bindingInformation -cne '127.0.0.1:9089:' -or [string]$site.bindings.Collection[0].protocol -cne 'http'){throw 'Preserve and review the existing upload-admission IIS site.'}
 }
 foreach($other in Get-Website){if($other.Name -cne 'OpenWebPBX Upload Gate'){foreach($binding in $other.bindings.Collection){if([string]$binding.bindingInformation -match ':9089:'){throw 'The private upload-admission port is already assigned. Preserve the existing website.'}}}}
 $pool=Get-Item IIS:\AppPools\OpenWebPBXUploadGate -ErrorAction SilentlyContinue
 if($pool -and (!(Test-OpenWebUploadPoolIdentity $pool.processModel.identityType) -or [string]$pool.managedRuntimeVersion -ne '')){throw 'Preserve and review the existing upload-admission application pool.'}
}
function Save-OpenWebUploadsSystem {
 param([string]$Destination)
 Assert-OpenWebUploadObjects
 $site=Get-Website -Name 'OpenWebPBX Upload Gate' -ErrorAction SilentlyContinue
 $pool=Get-Item IIS:\AppPools\OpenWebPBXUploadGate -ErrorAction SilentlyContinue
 $arguments=Get-OpenWebUploadArguments
 $application=Get-WebConfiguration -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter "system.webServer/fastCgi/application[@fullPath='C:\OpenWebPBX\php\php-cgi.exe'][@arguments='$arguments']"
 Add-Type -Path "$env:windir\System32\inetsrv\Microsoft.Web.Administration.dll"
 $manager=New-Object Microsoft.Web.Administration.ServerManager;$sections=@{}
 try{foreach($name in 'system.webServer/handlers','system.webServer/modules','system.webServer/serverRuntime'){$sections[$name]=[string]$manager.GetApplicationHostConfiguration().GetSection($name,'OpenWebPBX').OverrideMode}}finally{$manager.Dispose()}
 $state=@{schema=1;site_exists=[bool]$site;pool_exists=[bool]$pool;fastcgi_exists=[bool]$application;site_running=($site -and $site.State -eq 'Started');pool_running=($pool -and (Get-WebAppPoolState OpenWebPBXUploadGate).Value -eq 'Started');main_runtime=[string](Get-Item IIS:\AppPools\OpenWebPBX).managedRuntimeVersion;main_pipeline=[string](Get-Item IIS:\AppPools\OpenWebPBX).managedPipelineMode}
 $state.main_sections=$sections
 [IO.File]::WriteAllText($Destination,($state|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
}
function Restore-OpenWebUploadsSystem {
 param([string]$Snapshot)
 Add-Type -Path "$env:windir\System32\inetsrv\Microsoft.Web.Administration.dll"
 $state=Get-Content -LiteralPath $Snapshot -Raw -Encoding UTF8|ConvertFrom-Json
 if($state.schema -ne 1 -or $state.main_runtime -cnotin '','v4.0' -or $state.main_pipeline -cnotin 'Integrated','Classic'){throw 'The original upload-admission snapshot needs review.'}
 foreach($name in 'site_exists','pool_exists','fastcgi_exists','site_running','pool_running'){if($state.$name -isnot [bool]){throw 'The original upload-admission snapshot is invalid.'}}
 $names=@('system.webServer/handlers','system.webServer/modules','system.webServer/serverRuntime')
 if(@($state.main_sections.PSObject.Properties).Count -ne $names.Count){throw 'The original IIS section snapshot is invalid.'}
 foreach($name in $names){if($state.main_sections.$name -cnotin 'Inherit','Allow','Deny'){throw 'The original IIS section snapshot is invalid.'}}
 Assert-OpenWebUploadObjects
 $site=Get-Website -Name 'OpenWebPBX Upload Gate' -ErrorAction SilentlyContinue
 if($site){
  if(!$state.site_exists){Remove-Website -Name 'OpenWebPBX Upload Gate'}
  elseif($state.site_running){Start-Website -Name 'OpenWebPBX Upload Gate'}else{Stop-Website -Name 'OpenWebPBX Upload Gate'}
 }
 $pool=Get-Item IIS:\AppPools\OpenWebPBXUploadGate -ErrorAction SilentlyContinue
 if($pool){
  if(!$state.pool_exists){Remove-WebAppPool -Name OpenWebPBXUploadGate}
  elseif($state.pool_running){Start-WebAppPool -Name OpenWebPBXUploadGate}else{Stop-WebAppPool -Name OpenWebPBXUploadGate}
 }
 if(!$state.fastcgi_exists){$arguments=Get-OpenWebUploadArguments;Remove-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter 'system.webServer/fastCgi' -Name '.' -AtElement @{fullPath='C:\OpenWebPBX\php\php-cgi.exe';arguments=$arguments} -ErrorAction SilentlyContinue}
 Set-ItemProperty IIS:\AppPools\OpenWebPBX managedRuntimeVersion $state.main_runtime
 Set-ItemProperty IIS:\AppPools\OpenWebPBX managedPipelineMode $state.main_pipeline
 $manager=New-Object Microsoft.Web.Administration.ServerManager
 try{foreach($name in $names){$manager.GetApplicationHostConfiguration().GetSection($name,'OpenWebPBX').OverrideMode=[Enum]::Parse([Microsoft.Web.Administration.OverrideMode],[string]$state.main_sections.$name)};$manager.CommitChanges()}finally{$manager.Dispose()}
}
