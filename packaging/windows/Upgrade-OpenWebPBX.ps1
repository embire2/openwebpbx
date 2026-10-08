#Requires -RunAsAdministrator
[CmdletBinding()]
param([string]$RestoreBackup = '', [switch]$Check)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = 'C:\OpenWebPBX'
$private = Join-Path $env:ProgramData 'OpenWebPBX'
$config = Join-Path $env:ProgramData 'fusionpbx'
$switch = 'C:\Program Files\FreeSWITCH'

function Run([string]$Exe, [string[]]$Arguments) {
 $prior = $ErrorActionPreference
 try { $ErrorActionPreference = 'Continue'; & $Exe @Arguments; $code = $LASTEXITCODE }
 finally { $ErrorActionPreference = $prior }
 if ($code -ne 0) { throw "A required update command failed (exit $code): $(Split-Path $Exe -Leaf)" }
}
function CopyTree([string]$From, [string]$To, [switch]$Mirror) {
 $mode = if ($Mirror) { '/MIR' } else { '/E' }
 & robocopy.exe $From $To $mode /COPY:DAT /DCOPY:T /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
 if ($LASTEXITCODE -ge 8) { throw 'A server folder could not be copied.' }
}
function StopPbx {
 if((Get-Website -Name OpenWebPBX).State -ne 'Stopped'){Stop-Website OpenWebPBX}
 if ((Get-WebAppPoolState OpenWebPBX).Value -ne 'Stopped') { Stop-WebAppPool OpenWebPBX }
 foreach ($name in 'OpenWebPBX', 'FreeSWITCH') { Stop-Service $name; (Get-Service $name).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(40)) }
 Get-Process OpenWebPbx.Desktop -ErrorAction SilentlyContinue | Stop-Process -Force
}
function StartPbx {
 foreach ($name in 'FreeSWITCH', 'OpenWebPBX') { Start-Service $name }
 if ((Get-WebAppPoolState OpenWebPBX).Value -ne 'Started') { Start-WebAppPool OpenWebPBX }
 if((Get-Website -Name OpenWebPBX).State -ne 'Started'){Start-Website OpenWebPBX}
}
function CheckHealth([string]$ExpectedVersion) {
 for ($attempt = 0; $attempt -lt 30; $attempt++) {
  try {
   $health = Invoke-RestMethod 'http://127.0.0.1:8087/health' -TimeoutSec 3
   if ($health.state -eq 'Running' -and $health.version -eq $ExpectedVersion) {
    $login = Invoke-WebRequest ('https://' + $state.DomainName + ':' + $state.HttpsPort + '/login.php') -UseBasicParsing -TimeoutSec 5
    if($login.StatusCode -eq 200){return}
   }
  } catch { }
  Start-Sleep -Seconds 2
 }
 throw 'The updated call service or trusted HTTPS sign-in page did not become ready.'
}
function CheckIdle {
 $probe = '<?php require "C:/OpenWebPBX/web/resources/require.php"; $v=json_decode(event_socket::api("show channels as json"),true); if(!is_array($v)||!isset($v["row_count"])) {fwrite(STDERR,"The call engine is unavailable.\n");exit(1);} if((int)$v["row_count"]!==0) {fwrite(STDERR,"Finish active calls before updating.\n");exit(1);} echo "Call engine is idle.\n";'
 $probeFile = Join-Path $private ('upgrade-probe-' + [Guid]::NewGuid().ToString('N') + '.php')
 [IO.File]::WriteAllText($probeFile, $probe, (New-Object Text.UTF8Encoding($false)))
 Push-Location "$root\web"
 try { Run "$root\php\php.exe" @($probeFile) } finally { Pop-Location; Remove-Item $probeFile -Force -ErrorAction SilentlyContinue }
}
function RestorePbx([string]$Backup) {
 if (!(Test-Path "$Backup\complete.json")) { throw 'The selected backup is incomplete.' }
 foreach ($part in 'web', 'server', 'desktop') { CopyTree "$Backup\$part" "$root\$part" -Mirror }
 CopyTree "$Backup\config" $config -Mirror
 CopyTree "$Backup\switch-scripts" "$switch\scripts" -Mirror
 CopyTree "$Backup\switch-conf" "$switch\conf" -Mirror
 Copy-Item "$Backup\installation.json" "$private\installation.json" -Force
 Copy-Item "$Backup\runtime.json" "$private\runtime.json" -Force
 if(Test-Path "$Backup\phone-tls"){CopyTree "$Backup\phone-tls" "$private\phone-tls" -Mirror}
 if(Test-Path "$Backup\phone-tls.json"){Copy-Item "$Backup\phone-tls.json" "$private\phone-tls.json" -Force}
 # Storage is preserved by an upgrade. Restore its snapshot only when an operator
 # explicitly chooses rollback; automatic recovery must not remove new media.
 if ($RestoreBackup) { CopyTree "$Backup\storage" "$private\storage" -Mirror }
 # Restore the database itself so a failed migration's newly created objects
 # cannot survive an otherwise successful rollback. PBX clients are stopped.
 & "$root\pgsql\bin\psql.exe" -h 127.0.0.1 -p 5433 -U postgres -d postgres -w -X -v ON_ERROR_STOP=1 -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='fusionpbx' AND pid <> pg_backend_pid()" | Out-Null
 if($LASTEXITCODE){throw 'Database clients could not be closed for recovery.'}
 Run "$root\pgsql\bin\pg_restore.exe" @('-h','127.0.0.1','-p','5433','-U','postgres','-d','postgres','-w','--create','--clean','--if-exists','--exit-on-error',"$Backup\database.dump")
 Remove-Item "$private\cache\*" -Recurse -Force -ErrorAction SilentlyContinue
}

if (!(Test-Path "$private\installation.json")) { throw 'Install OpenWeb PBX before applying an update.' }
$state = Get-Content "$private\installation.json" -Raw | ConvertFrom-Json
$previousVersion = $state.Version
if (!$state.Completed) { throw 'Complete the existing installation before updating it.' }
Import-Module WebAdministration
$lock = $null; $stopped = $false; $backupReady = $false; $backup = ''; $success = $false
$priorPgPassword = $env:PGPASSWORD
try {
 $lock = [IO.File]::Open("$private\upgrade.lock", 'OpenOrCreate', 'ReadWrite', 'None')
 $env:PGPASSWORD = $state.PostgresPassword
 if ($RestoreBackup) {
  if ($Check) { throw 'Use -Check for an update, or -RestoreBackup for recovery.' }
  $backup = [IO.Path]::GetFullPath($RestoreBackup).TrimEnd('\')
  $backupRoot = [IO.Path]::GetFullPath("$private\backups").TrimEnd('\') + '\'
  if (!$backup.StartsWith($backupRoot, [StringComparison]::OrdinalIgnoreCase) -or !(Test-Path "$backup\complete.json")) { throw 'Choose a completed private OpenWeb PBX update backup.' }
  $expected = (Get-Content "$backup\complete.json" -Raw | ConvertFrom-Json).version
  CheckIdle
  $stopped = $true; StopPbx
  RestorePbx $backup; StartPbx; $stopped = $false; CheckHealth $expected
  $success = $true
  Write-Host "Previous installation restored. Backup: $backup"
  return
 }
 $version = (Get-Content "$PSScriptRoot\VERSION" -Raw).Trim()
 if ($version -notmatch '^\d+\.\d+\.\d+$' -or [version]$version -lt [version]$state.Version) { throw 'Choose a valid release at least as new as the installed version.' }
 if (!(Test-Path "$PSScriptRoot\release-manifest.json")) { throw 'Extract the complete release, including its file manifest.' }
 $manifest = Get-Content "$PSScriptRoot\release-manifest.json" -Raw | ConvertFrom-Json
 if ($manifest.version -ne $version) { throw 'The update manifest version does not match the release.' }
 $hashes = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
 foreach($entry in $manifest.files.PSObject.Properties){$hashes.Add($entry.Name,[string]$entry.Value)}
 Write-Host "Verifying $($hashes.Count) release files..."
 $packageRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
 foreach ($entry in $hashes.GetEnumerator()) {
  $path = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot $entry.Key))
  if (!$path.StartsWith($packageRoot, [StringComparison]::OrdinalIgnoreCase) -or !(Test-Path -LiteralPath $path -PathType Leaf) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry.Value) { throw 'Update file verification failed. Download and extract the release again.' }
 }
 foreach ($required in 'web/resources/require.php', 'server/OpenWebPbx.Server.exe', 'desktop/OpenWebPbx.Desktop.exe', 'bootstrap.php') {
  if (!$hashes.ContainsKey($required)) { throw 'The release manifest is missing a required component.' }
 }
 foreach ($item in Get-ChildItem $PSScriptRoot -Force -Recurse) {
  if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Release links are not permitted.' }
  if (!$item.PSIsContainer -and $item.FullName -ne "$PSScriptRoot\release-manifest.json") {
   $relative = $item.FullName.Substring($packageRoot.Length).Replace('\','/')
   if (!$hashes.ContainsKey($relative)) { throw 'The extracted release contains files missing from its manifest.' }
  }
 }
 # Never stage private machine files or source-control data into the web root.
 foreach ($item in Get-ChildItem "$PSScriptRoot\web" -Force -Recurse) {
  if ($item.Name -eq '.git' -or $item.Name -like '.env*' -or $item.Extension -in '.dump','.key','.pfx') { throw 'The release contains a private configuration path.' }
 }
 CheckIdle
 if ($Check) { Write-Host "OpenWeb PBX $version update files and installed call engine passed preflight."; return }
 $backup = Join-Path "$private\backups" ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
 Write-Host 'Release verified. Saving a private backup before updating the server...'
 New-Item -ItemType Directory -Force $backup | Out-Null
 & icacls.exe $backup /inheritance:r /grant '*S-1-5-32-544:(OI)(CI)F' /grant '*S-1-5-18:(OI)(CI)F' | Out-Null
 if ($LASTEXITCODE) { throw 'Private backup access could not be secured.' }
 $stopped = $true; StopPbx
 Run "$root\pgsql\bin\pg_dump.exe" @('-h','127.0.0.1','-p','5433','-U','postgres','-d','fusionpbx','-w','-Fc',"--file=$backup\database.dump")
 foreach ($part in 'web','server','desktop') { CopyTree "$root\$part" "$backup\$part" }
 CopyTree $config "$backup\config"
 CopyTree "$switch\scripts" "$backup\switch-scripts"
 CopyTree "$switch\conf" "$backup\switch-conf"
 CopyTree "$private\storage" "$backup\storage"
 Copy-Item "$private\installation.json","$private\runtime.json" $backup
 if(Test-Path "$private\phone-tls"){CopyTree "$private\phone-tls" "$backup\phone-tls"}
 if(Test-Path "$private\phone-tls.json"){Copy-Item "$private\phone-tls.json" $backup}
 @{version=$state.Version;created=(Get-Date).ToUniversalTime().ToString('o')} | ConvertTo-Json | Set-Content "$backup\complete.json" -Encoding UTF8
 $backupReady = $true
 Write-Host 'Backup complete. Updating the application and call-engine scripts...'
 # Keep local optional applications and server.json; only reviewed release files
 # are replaced. Database, settings, keys and existing media are never re-created.
 foreach ($part in 'web','server','desktop') { CopyTree "$PSScriptRoot\$part" "$root\$part" }
 Push-Location "$root\web"
 try {
  Run "$root\php\php.exe" @('core\upgrade\upgrade_schema.php')
  foreach ($step in '--defaults','--group','--menu') { Run "$root\php\php.exe" @('core\upgrade\upgrade.php',$step) }
  Run "$root\php\php.exe" @("$PSScriptRoot\bootstrap.php","$root\web",'migrate')
 } finally { Pop-Location }
 CopyTree "$root\web\app\switch\resources\scripts" "$switch\scripts"
 CopyTree "$root\web\app\pbx_setup\resources\switch\scripts\app\pbx_setup" "$switch\scripts\app\pbx_setup"
 Copy-Item "$root\web\app\pbx_setup\resources\prompts\*.wav" "$switch\sounds\openwebpbx" -Force
 Copy-Item "$root\web\app\pbx_setup\resources\prompts\openweb.xml" "$switch\conf\languages\en\ivr\openweb.xml" -Force
 Remove-Item "$private\cache\*" -Recurse -Force -ErrorAction SilentlyContinue
 $state.Version = $version
 [IO.File]::WriteAllText("$private\installation.json", ($state | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
 StartPbx; $stopped = $false; CheckHealth $version
 $success = $true
 Write-Host "OpenWeb PBX $version is running. Private backup: $backup"
 Write-Host "To roll back: .\Upgrade-OpenWebPBX.ps1 -RestoreBackup '$backup'"
} catch {
 $failure = $_
 if ($backupReady -and !$RestoreBackup) {
  Write-Warning 'The update failed. Restoring the previous application and database.'
  try { $stopped = $true; StopPbx; RestorePbx $backup; StartPbx; $stopped = $false; CheckHealth $previousVersion }
  catch { Write-Warning "Automatic recovery needs attention. The private backup is $backup" }
 } elseif ($stopped) { try { StartPbx; $stopped = $false } catch { } }
 throw $failure
} finally {
 if ($null -eq $priorPgPassword) { Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue } else { $env:PGPASSWORD = $priorPgPassword }
 if ($lock) { $lock.Dispose() }
}
