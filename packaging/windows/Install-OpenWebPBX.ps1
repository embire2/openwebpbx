#Requires -RunAsAdministrator
[CmdletBinding()]
param(
 [string]$DomainName='localhost',
 [string]$PublicAddress='',
 [int]$HttpsPort=8443,
 [string]$CertificateThumbprint='',
 [string]$AdminEmail,
 [SecureString]$AdminPassword,
 [switch]$LocalCertificate
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$root='C:\OpenWebPBX'; $private=Join-Path $env:ProgramData 'OpenWebPBX'; $configRoot=Join-Path $env:ProgramData 'fusionpbx'
if ($DomainName -notmatch '^[a-zA-Z0-9.-]+$' -or $HttpsPort -lt 1 -or $HttpsPort -gt 65535) { throw 'Enter a valid server name and HTTPS port.' }
if (!$CertificateThumbprint -and !$LocalCertificate) { throw 'Supply -CertificateThumbprint for a trusted certificate, or -LocalCertificate for a local test installation.' }
if ($CertificateThumbprint) {
 $selectedCertificate=Get-Item -LiteralPath "Cert:\LocalMachine\My\$CertificateThumbprint"
 if (!$selectedCertificate.HasPrivateKey -or $selectedCertificate.NotAfter -le (Get-Date) -or $selectedCertificate.NotBefore -gt (Get-Date)) { throw 'Choose a current certificate with its private key installed on this server.' }
}
if (!(Test-Path "$PSScriptRoot\web\resources\require.php") -or !(Test-Path "$PSScriptRoot\server\OpenWebPbx.Server.exe")) { throw 'Extract the complete Windows release package before running the installer.' }
& "$PSScriptRoot\Ensure-Runtime.ps1"
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw 'Install the required Microsoft runtime before continuing.' }
if ((Test-Path "$configRoot\config.conf") -and !(Test-Path "$private\installation.json")) { throw 'An existing PBX configuration is present. This installer will not overwrite it.' }
function Run([string]$Exe,[string[]]$Arguments) {
 $prior=$ErrorActionPreference
 try {$ErrorActionPreference='Continue'; & $Exe @Arguments; $code=$LASTEXITCODE}
 finally {$ErrorActionPreference=$prior}
 if ($code -ne 0) { throw "A required command failed: $Exe (exit $code)" }
}
function Secret { $b=New-Object byte[] 32; $rng=[Security.Cryptography.RandomNumberGenerator]::Create();try{$rng.GetBytes($b)}finally{$rng.Dispose()};return ([BitConverter]::ToString($b)).Replace('-','').ToLowerInvariant() }
function Download([string]$Url,[string]$Path,[string]$Hash) {
 if (!(Test-Path $Path)) { Run curl.exe @('-fL','--retry','3',$Url,'-o',$Path) }
 if ((Get-FileHash $Path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Hash) { throw "Download verification failed: $(Split-Path $Path -Leaf)" }
}
function WriteUtf8([string]$Path,[string]$Text) { [IO.File]::WriteAllText($Path,$Text,(New-Object Text.UTF8Encoding($false))) }
New-Item -ItemType Directory -Force $root,$private,$configRoot,"$root\packages" | Out-Null
icacls $private /inheritance:r /grant '*S-1-5-32-544:(OI)(CI)F' /grant '*S-1-5-18:(OI)(CI)F' | Out-Null
$setupIdentity=[Security.Principal.WindowsIdentity]::GetCurrent().Name
# initdb deliberately drops its elevated administrator token. Grant the named
# installing account access to its private bootstrap files as well.
icacls $private /grant "${setupIdentity}:(OI)(CI)F" | Out-Null
icacls $configRoot /inheritance:r /grant '*S-1-5-32-544:(OI)(CI)F' /grant '*S-1-5-18:(OI)(CI)F' | Out-Null
if (Test-Path "$private\installation.json") {
 $priorState=Get-Content "$private\installation.json" -Raw|ConvertFrom-Json
 if($priorState.Completed){throw 'OpenWeb PBX is already installed. Use Admin to manage this server.'}
}
if (!(Test-Path "$private\installation.json")) {
 if (!$AdminEmail) {$AdminEmail=Read-Host 'Administrator email'}
 if (!$AdminPassword) {$AdminPassword=Read-Host 'Administrator password (at least 8 characters)' -AsSecureString}
 $ptr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdminPassword)
 try {$plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)} finally {[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)}
 if ($AdminEmail -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$' -or $plain.Length -lt 8) { throw 'Use a valid email and a password of at least eight characters.' }
 WriteUtf8 "$private\setup-secrets.json" (@{AdminEmail=$AdminEmail;AdminPassword=$plain}|ConvertTo-Json);$plain=$null
 $state=@{Version=(Get-Content "$PSScriptRoot\VERSION" -Raw).Trim();DomainName=$DomainName;PublicAddress=$PublicAddress;HttpsPort=$HttpsPort;DatabasePassword=(Secret);PostgresPassword=(Secret);SwitchPassword=(Secret)}
 WriteUtf8 "$private\installation.json" ($state|ConvertTo-Json)
} else { $state=Get-Content "$private\installation.json" -Raw | ConvertFrom-Json; $DomainName=$state.DomainName;$HttpsPort=$state.HttpsPort;$PublicAddress=$state.PublicAddress }
Write-Host 'Installing the Windows web server and PBX components...'
$feature=Install-WindowsFeature Web-Server,Web-CGI,Web-Mgmt-Tools
if (!$feature.Success -or $feature.RestartNeeded -eq 'Yes') { throw 'Windows needs a restart to finish installing its web server. Restart and run this installer again.' }
Download 'https://downloads.php.net/~windows/releases/php-8.4.26-nts-Win32-vs17-x64.zip' "$root\packages\php.zip" 'da68394f9193b7f6b89d0c76861a4034ae10efee7fd55a7255d8118c2acf70d7'
Download 'https://get.enterprisedb.com/postgresql/postgresql-18.6-5-windows-x64-binaries.zip' "$root\packages\postgresql.zip" 'e2246ba91d22345bc3d017586c09ede52d9df180b1eeb480f050445f1cad84e2'
Download 'https://github.com/signalwire/freeswitch/releases/download/v1.11.3/FreeSWITCH-1.11.3-Release-x64.msi' "$root\packages\freeswitch.msi" 'f5649e33ad46be2ebdb1d98019bd149c86519f0dca9f47fb881207045203a34d'
if (!(Test-Path "$root\php\php.exe")) {New-Item -ItemType Directory -Force "$root\php"|Out-Null;Run tar.exe @('-xf',"$root\packages\php.zip",'-C',"$root\php")}
if (!(Test-Path "$root\pgsql\bin\initdb.exe")) {Run tar.exe @('-xf',"$root\packages\postgresql.zip",'-C',$root)}
$switch='C:\Program Files\FreeSWITCH'
if (!(Test-Path "$switch\FreeSwitchConsole.exe")) {
 $p=Start-Process msiexec.exe -ArgumentList @('/i',"$root\packages\freeswitch.msi",'/qn','/norestart') -PassThru -Wait
 if ($p.ExitCode -notin 0,3010) {throw 'The call engine installer did not complete.'}
}
foreach($service in 'OpenWebPBX','FreeSWITCH'){Stop-Service $service -ErrorAction SilentlyContinue}
Import-Module WebAdministration
if(Test-Path IIS:\Sites\OpenWebPBX){Stop-Website OpenWebPBX}
New-Item -ItemType Directory -Force "$root\web","$root\server","$root\desktop","$private\cache","$private\sessions","$private\uploads","$private\temp","$private\storage","$private\logs" | Out-Null
foreach($component in 'web','server','desktop'){
 if(Test-Path "$PSScriptRoot\$component"){
  & robocopy.exe "$PSScriptRoot\$component" "$root\$component" /E /COPY:DAT /DCOPY:T /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
  if($LASTEXITCODE -ge 8){throw "Could not copy $component files."}
 }
}
Copy-Item "$PSScriptRoot\web.config" "$root\web\web.config" -Force
$php=@"
extension_dir="$root\php\ext"
extension=pdo_pgsql
extension=pgsql
extension=pdo_sqlite
extension=sqlite3
extension=mbstring
extension=openssl
extension=curl
extension=zip
extension=gd
extension=sodium
extension=fileinfo
extension=exif
memory_limit=512M
upload_max_filesize=2048M
post_max_size=2060M
max_execution_time=600
max_input_time=600
cgi.force_redirect=0
fastcgi.impersonate=0
session.save_path="$private\sessions"
upload_tmp_dir="$private\temp"
date.timezone=UTC
log_errors=On
error_log="$private\logs\php.log"
display_errors=Off
expose_php=Off
"@
WriteUtf8 "$root\php\php.ini" $php
Write-Host 'Setting up the built-in database on this server for all tenants...'
if (!(Test-Path "$private\database\PG_VERSION")) {
 WriteUtf8 "$private\postgres-password.tmp" $state.PostgresPassword
 try {Run "$root\pgsql\bin\initdb.exe" @('-D',"$private\database",'-U','postgres','--auth=scram-sha-256',"--pwfile=$private\postgres-password.tmp",'--encoding=UTF8','--locale=C')}
 finally {Remove-Item "$private\postgres-password.tmp" -ErrorAction SilentlyContinue}
 Add-Content "$private\database\postgresql.conf" "`nlisten_addresses='127.0.0.1'`nport=5433"
}
icacls "$private\database" /grant '*S-1-5-20:(OI)(CI)M' | Out-Null
icacls $private /grant '*S-1-5-20:RX' | Out-Null
if (!(Get-Service OpenWebPBX-Database -ErrorAction SilentlyContinue)) {Run "$root\pgsql\bin\pg_ctl.exe" @('register','-N','OpenWebPBX-Database','-D',"$private\database",'-U','NT AUTHORITY\NetworkService','-S','auto')}
Start-Service OpenWebPBX-Database
$databaseReady=$false
for($attempt=0;$attempt -lt 30;$attempt++){
 & "$root\pgsql\bin\pg_isready.exe" -h 127.0.0.1 -p 5433 -t 2 2>&1 | Out-Null
 if($LASTEXITCODE -eq 0){$databaseReady=$true;break}
 Start-Sleep -Seconds 2
}
if(!$databaseReady){throw 'The built-in database did not become ready. Check the OpenWebPBX-Database service before running setup again.'}
$priorPgPassword=$env:PGPASSWORD
$env:PGPASSWORD=$state.PostgresPassword
try {
 $role=& "$root\pgsql\bin\psql.exe" -h 127.0.0.1 -p 5433 -U postgres -d postgres -X -w -v ON_ERROR_STOP=1 -Atc "select 1 from pg_roles where rolname='fusionpbx'"
 if($LASTEXITCODE -ne 0){throw 'Setup could not check the built-in database account.'}
 if ($role -ne '1') {"CREATE ROLE fusionpbx LOGIN PASSWORD '$($state.DatabasePassword)';" | & "$root\pgsql\bin\psql.exe" -h 127.0.0.1 -p 5433 -U postgres -d postgres -X -w -v ON_ERROR_STOP=1 | Out-Null;if($LASTEXITCODE){throw 'Database user creation failed.'}}
 $database=& "$root\pgsql\bin\psql.exe" -h 127.0.0.1 -p 5433 -U postgres -d postgres -X -w -v ON_ERROR_STOP=1 -Atc "select 1 from pg_database where datname='fusionpbx'"
 if($LASTEXITCODE -ne 0){throw 'Setup could not check the built-in database.'}
 if($database -ne '1'){Run "$root\pgsql\bin\createdb.exe" @('-h','127.0.0.1','-p','5433','-U','postgres','-O','fusionpbx','fusionpbx')}
 $env:PGPASSWORD=$state.DatabasePassword
 $applicationDatabase=& "$root\pgsql\bin\psql.exe" -h 127.0.0.1 -p 5433 -U fusionpbx -d fusionpbx -X -w -v ON_ERROR_STOP=1 -Atc 'select current_database()'
 if($LASTEXITCODE -ne 0 -or $applicationDatabase -ne 'fusionpbx'){throw 'The application could not connect to its built-in database. Setup has not completed.'}
} finally {
 if($null -eq $priorPgPassword){Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue}
 else{$env:PGPASSWORD=$priorPgPassword}
 $priorPgPassword=$null
}
$sf=$switch.Replace('\','/');$rf=$root.Replace('\','/');$pf=$private.Replace('\','/')
$config=@"
database.0.type = pgsql
database.0.host = 127.0.0.1
database.0.port = 5433
database.0.name = fusionpbx
database.0.username = fusionpbx
database.0.password = $($state.DatabasePassword)
database.1.type = sqlite
database.1.name = core.db
database.1.path = $sf/db
document.root = $rf/web
project.path =
temp.dir = $pf/temp
php.dir = $rf/php
php.bin = php.exe
cache.method = file
cache.location = $pf/cache
cache.settings = true
session.cookie_secure = true
session.cookie_httponly = true
session.cookie_samesite = Lax
switch.conf.dir = $sf/conf
switch.sounds.dir = $sf/sounds
switch.database.dir = $sf/db
switch.storage.dir = $pf/storage
switch.voicemail.dir = $pf/storage/voicemail
switch.recordings.dir = $pf/storage/recordings
switch.scripts.dir = $sf/scripts
switch.event_socket.host = 127.0.0.1
switch.event_socket.port = 8021
switch.event_socket.password = $($state.SwitchPassword)
xml_handler.fs_path = false
xml_handler.reg_as_number_alias = false
xml_handler.number_as_presence_id = true
openweb.public_host = $DomainName
openweb.public_url = https://${DomainName}:$HttpsPort
openweb.public_ip = $PublicAddress
"@
WriteUtf8 "$configRoot\config.conf" $config
if(!(Test-Path "$configRoot\openweb-template.key")){$key=New-Object byte[] 32;$rng=[Security.Cryptography.RandomNumberGenerator]::Create();$rng.GetBytes($key);$rng.Dispose();[IO.File]::WriteAllBytes("$configRoot\openweb-template.key",$key)}
New-Item -ItemType Directory -Force "$switch\scripts","$switch\conf\languages" | Out-Null
$env:OPENWEB_SETUP_SECRETS="$private\setup-secrets.json"
Push-Location "$root\web"
try {
 Run "$root\php\php.exe" @('core\upgrade\upgrade_schema.php')
 Run "$root\php\php.exe" @("$PSScriptRoot\bootstrap.php","$root\web",'domain')
 foreach($step in '--defaults','--group','--menu'){Run "$root\php\php.exe" @('core\upgrade\upgrade.php',$step)}
 Run "$root\php\php.exe" @("$PSScriptRoot\bootstrap.php","$root\web",'migrate')
 if(Test-Path $env:OPENWEB_SETUP_SECRETS){Run "$root\php\php.exe" @("$PSScriptRoot\bootstrap.php","$root\web",'admin')}
}finally{Pop-Location;Remove-Item Env:\OPENWEB_SETUP_SECRETS}
# Use the shipped PBX configuration, not the call engine's demonstration users.
if(!(Test-Path "$private\original-switch-conf")){Copy-Item "$switch\conf" "$private\original-switch-conf" -Recurse -Force}
Remove-Item "$switch\conf\directory\default\*.xml" -ErrorAction SilentlyContinue
Copy-Item "$root\web\app\switch\resources\conf\*" "$switch\conf" -Recurse -Force
Copy-Item "$root\web\app\switch\resources\scripts\*" "$switch\scripts" -Recurse -Force
New-Item -ItemType Directory -Force "$switch\scripts\app\pbx_setup","$switch\sounds\openwebpbx" | Out-Null
Copy-Item "$root\web\app\pbx_setup\resources\switch\scripts\app\pbx_setup\*" "$switch\scripts\app\pbx_setup" -Force
Copy-Item "$root\web\app\pbx_setup\resources\prompts\*.wav" "$switch\sounds\openwebpbx" -Force
Copy-Item "$root\web\app\pbx_setup\resources\prompts\openweb.xml" "$switch\conf\languages\en\ivr\openweb.xml" -Force
[xml]$modules=Get-Content "$switch\conf\autoload_configs\modules.conf.xml"
if(!$modules.configuration.modules.load.Where({$_.module -eq 'mod_pgsql'})){$pg=$modules.CreateElement('load');$pg.SetAttribute('module','mod_pgsql');$modules.configuration.modules.PrependChild($pg)|Out-Null;$modules.Save("$switch\conf\autoload_configs\modules.conf.xml")}
WriteUtf8 "$switch\conf\autoload_configs\event_socket.conf.xml" ('<configuration name="event_socket.conf"><settings><param name="listen-ip" value="127.0.0.1"/><param name="listen-port" value="8021"/><param name="password" value="'+$state.SwitchPassword+'"/></settings></configuration>')
$runtime=@{ConnectionStrings=@{Pbx="Host=127.0.0.1;Port=5433;Database=fusionpbx;Username=fusionpbx;Password=$($state.DatabasePassword)"};Switch=@{Host='127.0.0.1';Port=8021;Password=$state.SwitchPassword}}
WriteUtf8 "$private\runtime.json" ($runtime|ConvertTo-Json -Depth 4)
if(!(Test-Path IIS:\AppPools\OpenWebPBX)){New-WebAppPool OpenWebPBX|Out-Null}
Set-ItemProperty IIS:\AppPools\OpenWebPBX managedRuntimeVersion ''
$fastcgi="$root\php\php-cgi.exe"
if(!(Get-WebConfiguration 'system.webServer/fastCgi/application' | Where-Object fullPath -eq $fastcgi)){Add-WebConfiguration 'system.webServer/fastCgi' -Value @{fullPath=$fastcgi;instanceMaxRequests=10000;maxInstances=4;activityTimeout=900;requestTimeout=900}}
if(!(Test-Path IIS:\Sites\OpenWebPBX)){New-Website -Name OpenWebPBX -PhysicalPath "$root\web" -ApplicationPool OpenWebPBX -Port $HttpsPort -Ssl | Out-Null}
Add-Type -Path "$env:windir\System32\inetsrv\Microsoft.Web.Administration.dll"
$manager=New-Object Microsoft.Web.Administration.ServerManager
try {$section=$manager.GetApplicationHostConfiguration().GetSection('system.webServer/handlers','OpenWebPBX');$section.OverrideMode=[Microsoft.Web.Administration.OverrideMode]::Allow;$manager.CommitChanges()}
finally {$manager.Dispose()}
if(!$CertificateThumbprint){$cert=New-SelfSignedCertificate -DnsName $DomainName -CertStoreLocation Cert:\LocalMachine\My -FriendlyName 'OpenWeb PBX local test';$CertificateThumbprint=$cert.Thumbprint;Export-Certificate -Cert $cert -FilePath "$private\local-test.cer"|Out-Null;Import-Certificate -FilePath "$private\local-test.cer" -CertStoreLocation Cert:\LocalMachine\Root|Out-Null}
(Get-WebBinding -Name OpenWebPBX -Protocol https).AddSslCertificate($CertificateThumbprint,'My')
icacls "$root\web" /grant 'IIS AppPool\OpenWebPBX:(OI)(CI)RX' | Out-Null
icacls "$switch\db" /grant 'IIS AppPool\OpenWebPBX:(OI)(CI)M' | Out-Null
icacls $private /grant 'IIS AppPool\OpenWebPBX:RX' /grant '*S-1-5-19:RX' /grant '*S-1-5-20:RX' | Out-Null
icacls "$private\runtime.json" /grant '*S-1-5-19:R' | Out-Null
icacls $configRoot /grant 'IIS AppPool\OpenWebPBX:(OI)(CI)R' | Out-Null
foreach($dir in 'cache','sessions','uploads','temp','storage','logs'){icacls "$private\$dir" /grant 'IIS AppPool\OpenWebPBX:(OI)(CI)M'|Out-Null}
if(!(Get-Service OpenWebPBX -ErrorAction SilentlyContinue)){Run sc.exe @('create','OpenWebPBX','binPath=',"$root\server\OpenWebPbx.Server.exe",'start=','auto','obj=','NT AUTHORITY\LocalService','DisplayName=','OpenWeb PBX')}
Run sc.exe @('failure','OpenWebPBX','reset=','86400','actions=','restart/60000/restart/60000/restart/60000')
Start-Service FreeSWITCH
Start-Service OpenWebPBX
if ((Get-WebAppPoolState OpenWebPBX).Value -ne 'Started') { Start-WebAppPool OpenWebPBX }
Start-Website OpenWebPBX
$ready=$false
for($attempt=0;$attempt -lt 30;$attempt++){
 try{$ready=(Invoke-RestMethod 'http://127.0.0.1:8087/health' -TimeoutSec 3).state -eq 'Running'}catch{$ready=$false}
 if($ready){break};Start-Sleep -Seconds 2
}
if(!$ready){throw 'The background call service is not ready. Check the private server logs before continuing.'}
if(!$LocalCertificate -and $DomainName -ne 'localhost') {
 try { & "$PSScriptRoot\Enable-PhoneTLS.ps1" -CertificateThumbprint $CertificateThumbprint }
 catch { Write-Warning 'The PBX is installed, but secure phone setup is incomplete. Use Enable-PhoneTLS.ps1 with an exportable trusted certificate before connecting Android phones.' }
}
$cleanup=New-ScheduledTaskAction -Execute "$root\php\php.exe" -Argument "`"$root\web\app\pbx_setup\cleanup.php`"" -WorkingDirectory "$root\web"
$trigger=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(10) -RepetitionInterval (New-TimeSpan -Hours 1)
Register-ScheduledTask -TaskName 'OpenWebPBX-Cleanup' -Action $cleanup -Trigger $trigger -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
WriteUtf8 "$root\desktop\server.json" (@{Address="https://${DomainName}:$HttpsPort"}|ConvertTo-Json)
if(Test-Path "$root\desktop\OpenWebPbx.Desktop.exe"){
 $shell=New-Object -ComObject WScript.Shell
 $shortcut=$shell.CreateShortcut("$env:ProgramData\Microsoft\Windows\Start Menu\Programs\OpenWeb PBX.lnk")
 $shortcut.TargetPath="$root\desktop\OpenWebPbx.Desktop.exe";$shortcut.WorkingDirectory="$root\desktop";$shortcut.Save()
}
if ($state -is [System.Collections.IDictionary]) { $state['Completed']=$true }
else { $state|Add-Member -NotePropertyName Completed -NotePropertyValue $true -Force }
WriteUtf8 "$private\installation.json" ($state|ConvertTo-Json)
Remove-Item "$private\setup-secrets.json" -ErrorAction SilentlyContinue
Write-Host "OpenWeb PBX $($state.Version) is installed at https://${DomainName}:$HttpsPort"
Write-Host 'All tenants share this installation''s built-in database. No separate database server is required.'
Write-Host 'Sign in to Admin, then open Main PBX. Trunks start disabled. Configure your public certificate and firewall before remote use.'

try { & "$PSScriptRoot\Install-Updater.ps1" -PackageRoot $PSScriptRoot }
catch {
 try { & "$PSScriptRoot\Remove-Updater.ps1" } catch { Write-Warning 'Review the private updater startup settings before rebooting.' }
 throw 'The PBX is installed, but its update service could not be enabled. Run Install-Updater.ps1 from this release after correcting the Windows error.'
}
