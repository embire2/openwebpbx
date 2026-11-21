[CmdletBinding()]
param([Parameter(Mandatory)][string]$Archive,[Parameter(Mandatory)][string]$Evidence,[Parameter(Mandatory)][string]$SHA256)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$version='1.0.29'
$realm='openwebpbx-qa129.invalid'
$port=18443
$started=[DateTimeOffset]::UtcNow
$installerLog=Join-Path $Evidence 'install.private.log'
$final=Join-Path $Evidence 'fresh-install.safe.json'
if($PSVersionTable.PSEdition -ne 'Desktop' -or [Threading.Thread]::CurrentThread.GetApartmentState() -ne 'MTA') {throw 'Use native Windows PowerShell in the documented MTA mode.'}
$os=Get-CimInstance Win32_OperatingSystem
$edition=(Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name InstallationType).InstallationType
if($os.ProductType -eq 1 -or $os.Caption -notmatch 'Windows Server 2025' -or $edition -cne 'Server' -or ![Environment]::Is64BitOperatingSystem){throw 'Actual supported Windows Server 2025 x64 Desktop Experience is required.'}
$serviceNames=@('FreeSWITCH','OpenWebPBX','OpenWebPBX-Database','OpenWebPBXUpdater')
$noPriorPaths=@('C:\OpenWebPBX','C:\ProgramData\OpenWebPBX','C:\ProgramData\OpenWebPBX-Installation','C:\ProgramData\OpenWebPBX-Status','C:\ProgramData\fusionpbx','C:\Program Files\FreeSWITCH','HKLM:\SOFTWARE\OpenWebPBX','HKLM:\SOFTWARE\WOW6432Node\OpenWebPBX')
function Assert-CleanPBX {
 foreach($path in $noPriorPaths){if(Test-Path -LiteralPath $path){throw 'An earlier PBX was found.'}}
 if(@(Get-Service -Name $serviceNames -ErrorAction SilentlyContinue).Count){throw 'An earlier PBX service was found.'}
 if(Get-NetTCPConnection -State Listen -LocalPort 5433,$port -ErrorAction SilentlyContinue){throw 'The fresh setup database or HTTPS port is already assigned.'}
}
$free=(Get-PSDrive C).Free
$vc=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64' -ErrorAction SilentlyContinue
$iisWasInstalled=(Get-WindowsFeature -Name Web-Server).Installed
Assert-CleanPBX
if((Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash.ToLowerInvariant() -cne $SHA256){throw 'Installer bytes differ from the frozen package.'}
$receipt=[ordered]@{version=$version;phase='baseline';windows=$os.Caption;build=$os.BuildNumber;installation_type=$edition;system_drive_bytes_free=$free;windows_iis_preinstalled=[bool]$iisWasInstalled;vc_runtime_before=([string]$vc.Version);earlier_pbx_absent=$true;earlier_pbx_services_absent=$true;database_port_clear=$true;archive_sha256=$SHA256;scope='clean GitHub Windows Server 2025 runner; isolated local-certificate recovery setup without managed registration'}
function Save-Receipt {
 $receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $final -Encoding UTF8
 Write-Host ('Windows standalone qualification: '+$receipt.phase)
}
Save-Receipt
$payload='C:\OW29QA'
if(Test-Path -LiteralPath $payload){throw 'Test archive extraction path already exists.'}
New-Item -ItemType Directory -Path $payload | Out-Null
& tar.exe -xf $Archive -C $payload
if($LASTEXITCODE){throw 'The archive could not be fully extracted.'}
$payload=Join-Path $payload "openwebpbx-$version-windows-x64"
$package=Get-Content -LiteralPath "$payload\installation.json" -Raw | ConvertFrom-Json
if($package.version -cne $version -or $package.package_type -cne 'full' -or $package.previous_installation_required -ne $false){throw 'The standalone archive contract is invalid.'}
$installer=Join-Path $payload 'Install-OpenWebPBX.ps1'
& $installer -Check *> (Join-Path $Evidence 'package-check.private.log')
Assert-CleanPBX
$receipt.phase='applying exact package';$receipt.ordinary_read_only_package_check_passed=$true;Save-Receipt
$plain='Qa!9'+[Guid]::NewGuid().ToString('N')
$password=ConvertTo-SecureString $plain -AsPlainText -Force
$qaFile=Join-Path $Evidence 'temporary-login.private.json'
$admin='qa-admin@example.invalid'
@{email=$admin;password=$plain} | ConvertTo-Json -Compress | Set-Content -LiteralPath $qaFile -Encoding UTF8
$plain=$null
try {
 & $installer -RestoreServer -DomainName $realm -HttpsPort $port -LocalCertificate -AdminEmail $admin -AdminPassword $password *> $installerLog
 $receipt.ordinary_initializer_returned=$true
 $engineDb=Get-Item -LiteralPath 'C:\Program Files\FreeSWITCH\db' -Force
 if(!$engineDb.PSIsContainer -or ($engineDb.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'The installer did not provision an ordinary FreeSWITCH database directory.'}
 $receipt.engine_database_directory_created=$true
 $installation=Get-Content -LiteralPath 'C:\ProgramData\OpenWebPBX\installation.json' -Raw | ConvertFrom-Json
 if($installation.Version -cne $version -or !$installation.Completed){throw 'The native installer did not commit its expected release.'}
 $installedServices=Get-Service -Name $serviceNames
 if(@($installedServices | Where-Object Status -ne 'Running').Count){throw 'An expected PBX service is not running.'}
 $health=Invoke-RestMethod -Uri 'http://127.0.0.1:8087/health' -TimeoutSec 15
 if($health.version -cne $version -or $health.state -cne 'Registration required'){throw 'The expected local ready-and-awaiting-registration state was not observed.'}
 $site=Get-Content -LiteralPath 'C:\OpenWebPBX\desktop\server.json' -Raw | ConvertFrom-Json
 if($site.Address -cne "https://${realm}:$port"){throw 'The installed manager has an unexpected local address.'}
 $selectedUpdater=(Get-CimInstance Win32_Service -Filter "Name='OpenWebPBXUpdater'").PathName.Trim('"')
 if($selectedUpdater -ine "C:\OpenWebPBX\updater\slots\$version\OpenWebPbx.Updater.exe"){throw 'The new updater is not selected by the Windows service.'}
 foreach($path in 'server\OpenWebPbx.Server.dll','desktop\OpenWebPbx.Desktop.dll',"updater\slots\$version\OpenWebPbx.Updater.dll"){
  if([Reflection.AssemblyName]::GetAssemblyName("C:\OpenWebPBX\$path").Version.ToString() -cne "$version.0"){throw 'Unexpected installed native component.'}
 }
 $pgVersion=(Get-Content -LiteralPath 'C:\ProgramData\OpenWebPBX\database\PG_VERSION' -Raw).Trim()
 & 'C:\OpenWebPBX\pgsql\bin\pg_isready.exe' -h 127.0.0.1 -p 5433 -t 10 | Out-Null
 if($pgVersion -cne '18' -or $LASTEXITCODE){throw 'The standalone instance local database is not ready.'}
 . (Join-Path $payload 'Web-Readiness.ps1')
 if(!(Test-OpenWebTrustedLogin $realm $port)){throw 'Local HTTPS login failed normal trust or name validation.'}
 $configuredPhp=Get-Content -LiteralPath 'C:\OpenWebPBX\php\php.ini' -Raw
 if($configuredPhp -notmatch '(?m)^upload_tmp_dir="C:\\ProgramData\\OpenWebPBX\\temp"\r?$' -or !(Test-Path -LiteralPath 'C:\ProgramData\OpenWebPBX\temp' -PathType Container)){throw 'Expected private PHP upload path is unavailable.'}
 & 'C:\OpenWebPBX\php\php.exe' (Join-Path $payload 'check-call-engine.php') 'C:\OpenWebPBX\web' | Out-Null
 if($LASTEXITCODE){throw 'The normal authenticated call-engine readiness contract failed.'}
 $receipt.phase='native ready';$receipt.services=$serviceNames;$receipt.core_state=$health.state;$receipt.local_postgresql=$pgVersion;$receipt.trusted_local_https_login_page=$true;$receipt.private_disk_php_upload=$true;$receipt.native_sip_rtp_readiness=$true;Save-Receipt
 & "$payload\backup-runtime\python.exe" -I -B (Join-Path $PSScriptRoot 'windows-local-login.py') "https://${realm}:$port" $qaFile
 if($LASTEXITCODE){throw 'An ordinary instance administrator could not load the protected Software Updates page.'}
 $receipt.phase='passed';$receipt.ordinary_authenticated_updates=$true;$receipt.completed=[DateTimeOffset]::UtcNow.ToString('o');$receipt.duration_seconds=[math]::Round(([DateTimeOffset]::UtcNow-$started).TotalSeconds,3);Save-Receipt
} catch {
 $receipt.failure_type=$_.Exception.GetType().FullName
 $receipt.failure_script=Split-Path -Leaf $_.InvocationInfo.ScriptName
 $receipt.failure_line=$_.InvocationInfo.ScriptLineNumber
 foreach($key in 'command_basename','command_exit','caller_basename','caller_line'){
  if($_.Exception.Data.Contains($key)){$receipt[$key]=$_.Exception.Data[$key]}
 }
 Save-Receipt
 throw
} finally {
 Remove-Item -LiteralPath $qaFile -Force -ErrorAction SilentlyContinue
}
