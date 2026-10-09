#Requires -RunAsAdministrator
[CmdletBinding()]
param([string]$RestoreBackup = '', [switch]$Check, [string]$Archive, [string]$FeedEnvelope, [string]$TargetVersion, [switch]$Recover, [switch]$Automatic)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = 'C:\OpenWebPBX'
$private = Join-Path $env:ProgramData 'OpenWebPBX'
$config = Join-Path $env:ProgramData 'fusionpbx'
$switch = 'C:\Program Files\FreeSWITCH'
$payload = $PSScriptRoot
$updates = Join-Path $private 'updates'
$journalPath = Join-Path $updates 'install-journal.json'
$extracted = $null
$exitCode=0;$script:deferred=$false;$script:enginePaused=$false;$restoreStarted=$false;$recoveryRestoreStarted=$false;$script:operatorRollback=$false
if(-not ('OpenWebUpdateState' -as [type])){Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class OpenWebUpdateState {
 [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
 public static extern bool MoveFileEx(string oldName,string newName,int flags);
}
'@}
function WriteState([string]$Path,$Value) {
 $temp=$Path+'.'+[Guid]::NewGuid().ToString('N')+'.new'
 $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes(($Value|ConvertTo-Json -Depth 8))
 try{
  $file=[IO.File]::Open($temp,'CreateNew','Write','None')
  try{$file.Write($bytes,0,$bytes.Length);$file.Flush($true)}finally{$file.Dispose()}
  if(![OpenWebUpdateState]::MoveFileEx($temp,$Path,9)){throw 'Durable update state could not be committed.'}
 }finally{Remove-Item $temp -Force -ErrorAction SilentlyContinue}
}
function SaveJournal([string]$Phase) {
 $record=@{schema=1;state=$Phase;version=$version;previous_version=$previousVersion;backup_path=$backup;updated_at=[DateTime]::UtcNow.ToString('o');manager_tasks=@($script:managerTasks);operator_rollback=[bool]$script:operatorRollback}
 WriteState $journalPath $record
}
function WaitPool([string]$Wanted) {
 for($i=0;$i -lt 160;$i++){if((Get-WebAppPoolState OpenWebPBX).Value -eq $Wanted){return};Start-Sleep -Milliseconds 250}
 throw 'The PBX web application pool did not reach its required state.'
}
function ResumeManagers {
 foreach($task in $script:managerTasks){try{Start-ScheduledTask -TaskName $task -ErrorAction Stop}catch{Write-Warning 'A previously open manager can be reopened from its normal shortcut.'}}
}
$script:managerTasks=@()
function PrepareManagers {
 # Each manager registers an interactive-token task for its own Windows user.
 # Only tasks for currently running manager owners are eligible to reopen.
 foreach($process in Get-CimInstance Win32_Process -Filter "Name='OpenWebPbx.Desktop.exe'"){
  $owner=Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid
  if($owner.ReturnValue -eq 0){
   $name='OpenWebPBX-Manager-'+$owner.Sid
   $task=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
   if(!$task){
    # Bootstrap managers from 1.0.3 did not register a restart task. Use the
    # existing process owner's interactive token, never the service identity.
    $principal=New-ScheduledTaskPrincipal -UserId $owner.Sid -LogonType Interactive -RunLevel Limited
    $action=New-ScheduledTaskAction -Execute "$root\desktop\OpenWebPbx.Desktop.exe" -WorkingDirectory "$root\desktop"
    $settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings $settings -Force|Out-Null
    $task=Get-ScheduledTask -TaskName $name
   }
   $taskSid=$null
   if($task){try{$taskSid=if($task.Principal.UserId -like 'S-1-*'){$task.Principal.UserId}else{(New-Object Security.Principal.NTAccount($task.Principal.UserId)).Translate([Security.Principal.SecurityIdentifier]).Value}}catch{}}
   if($task -and $task.Principal.LogonType -eq 'Interactive' -and $taskSid -eq $owner.Sid){$script:managerTasks+=$name}
   else{throw 'The manager could not be prepared to reopen. Close it before requesting installation again.'}
  }
 }
}


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
 if ((Get-WebAppPoolState OpenWebPBX).Value -ne 'Stopped') { Stop-WebAppPool OpenWebPBX }; WaitPool 'Stopped'
 foreach ($name in 'OpenWebPBX', 'FreeSWITCH') { Stop-Service $name; (Get-Service $name).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(40)) }
 Get-Process OpenWebPbx.Desktop -ErrorAction SilentlyContinue | Stop-Process -Force
}
function StartPbx {
 foreach ($name in 'FreeSWITCH', 'OpenWebPBX') { if((Get-Service $name).Status -ne 'Running'){Start-Service $name} }
 if ((Get-WebAppPoolState OpenWebPBX).Value -ne 'Started') { Start-WebAppPool OpenWebPBX }; WaitPool 'Started'
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
function PauseEngine {
 $probe=@'
<?php
require "C:/OpenWebPBX/web/resources/require.php";
$paused=false;
try {
 if(trim(event_socket::api("fsctl pause_check"))!=="false")exit(75);
 if(!str_starts_with(event_socket::api("fsctl pause"),"+OK"))exit(1);
 $paused=true;
 foreach(["show channels as json","show calls as json"] as $command){$state=json_decode(event_socket::api($command),true);if(!isset($state["row_count"])||(int)$state["row_count"]!==0){event_socket::api("fsctl resume");exit(75);}}
}catch(Throwable){if($paused)event_socket::api("fsctl resume");exit(1);}
'@
 $file=Join-Path $private ('update-pause-'+[Guid]::NewGuid().ToString('N')+'.php')
 [IO.File]::WriteAllText($file,$probe,(New-Object Text.UTF8Encoding($false)))
 Push-Location "$root\web"
 try{& "$root\php\php.exe" $file;if($LASTEXITCODE -ne 0){$script:deferred=$true;throw 'Calls or existing maintenance prevent this update.'};$script:enginePaused=$true}finally{Pop-Location;Remove-Item $file -Force -ErrorAction SilentlyContinue}
}
function ResumeEngine {
 if(!$script:enginePaused){return}
 $file=Join-Path $private ('update-resume-'+[Guid]::NewGuid().ToString('N')+'.php')
 [IO.File]::WriteAllText($file,'<?php require "C:/OpenWebPBX/web/resources/require.php";event_socket::api("fsctl resume");',(New-Object Text.UTF8Encoding($false)))
 Push-Location "$root\web"
 try{& "$root\php\php.exe" $file|Out-Null}finally{Pop-Location;Remove-Item $file -Force -ErrorAction SilentlyContinue;$script:enginePaused=$false}
}
function CheckWindow {
 $probe = '<?php require "C:/OpenWebPBX/web/resources/require.php"; $r=$database->db->query("select mode,maintenance_hour,maintenance_duration from v_pbx_update_policies where scope_key=''instance''")->fetch(PDO::FETCH_ASSOC);if(!$r || $r["mode"]!=="automatic" || ((int)gmdate("G")-(int)$r["maintenance_hour"]+24)%24 >= (int)$r["maintenance_duration"])exit(75);'
 $file=Join-Path $private ('update-window-'+[Guid]::NewGuid().ToString('N')+'.php')
 [IO.File]::WriteAllText($file,$probe,(New-Object Text.UTF8Encoding($false)))
 Push-Location "$root\web"
 try{& "$root\php\php.exe" $file;if($LASTEXITCODE -ne 0){$script:deferred=$true;throw 'The automatic update is outside the allowed maintenance window.'}}finally{Pop-Location;Remove-Item $file -Force -ErrorAction SilentlyContinue}
}
function CheckIdle {
 $probe = '<?php require "C:/OpenWebPBX/web/resources/require.php"; $v=json_decode(event_socket::api("show channels as json"),true); if(!is_array($v)||!isset($v["row_count"])) {fwrite(STDERR,"The call engine is unavailable.\n");exit(1);} if((int)$v["row_count"]!==0) {fwrite(STDERR,"Finish active calls before updating.\n");exit(1);} echo "Call engine is idle.\n";'
 $probeFile = Join-Path $private ('upgrade-probe-' + [Guid]::NewGuid().ToString('N') + '.php')
 [IO.File]::WriteAllText($probeFile, $probe, (New-Object Text.UTF8Encoding($false)))
 Push-Location "$root\web"
 try { & "$root\php\php.exe" $probeFile; if($LASTEXITCODE -ne 0){$script:deferred=$true;throw 'Waiting for the call engine to be idle.'} } finally { Pop-Location; Remove-Item $probeFile -Force -ErrorAction SilentlyContinue }
}
function SealBackup([string]$Backup) {
 $schemaOwner=& "$root\pgsql\bin\psql.exe" -h 127.0.0.1 -p 5433 -U postgres -d fusionpbx -w -X -Atc "select pg_get_userbyid(nspowner) from pg_namespace where nspname='public'"
 if($LASTEXITCODE -or !$schemaOwner){throw 'The PBX schema owner could not be recorded.'}
 $files=@{}
 foreach($item in Get-ChildItem $Backup -Recurse -Force -File){
  $relative=$item.FullName.Substring($Backup.TrimEnd('\').Length+1).Replace('\','/')
  if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Backup links are not permitted.'}
  $handle=[IO.File]::Open($item.FullName,'Open','ReadWrite','Read')
  try{$handle.Flush($true)}finally{$handle.Dispose()}
  $files[$relative]=(Get-FileHash $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
 }
 WriteState "$Backup\backup-manifest.json" @{schema=1;files=$files}
 WriteState "$Backup\complete.json" @{version=$state.Version;created=[DateTime]::UtcNow.ToString('o');schema_owner=[string]$schemaOwner;integrity_sha256=(Get-FileHash "$Backup\backup-manifest.json" -Algorithm SHA256).Hash.ToLowerInvariant()}
}
function VerifyBackup([string]$Backup) {
 $marker=Get-Content "$Backup\complete.json" -Raw|ConvertFrom-Json
 if(!$marker.integrity_sha256 -or !(Test-Path "$Backup\backup-manifest.json") -or (Get-FileHash "$Backup\backup-manifest.json" -Algorithm SHA256).Hash -ne $marker.integrity_sha256){throw 'The recovery backup has no valid integrity record.'}
 $manifest=Get-Content "$Backup\backup-manifest.json" -Raw|ConvertFrom-Json
 $prefix=[IO.Path]::GetFullPath($Backup).TrimEnd('\')+'\'
 foreach($entry in $manifest.files.PSObject.Properties){
  $path=[IO.Path]::GetFullPath((Join-Path $Backup $entry.Name))
  if(!$path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or !(Test-Path $path -PathType Leaf) -or ((Get-Item $path).Attributes -band [IO.FileAttributes]::ReparsePoint) -or (Get-FileHash $path -Algorithm SHA256).Hash -ne $entry.Value){throw 'The recovery backup failed integrity verification.'}
 }
 if(!$manifest.files.'database.dump' -or !$manifest.files.'installation.json'){throw 'The recovery backup is incomplete.'}
}
function RestorePbx([string]$Backup) {
 if (!(Test-Path "$Backup\complete.json")) { throw 'The selected backup is incomplete.' }
 VerifyBackup $Backup
 foreach ($part in 'web', 'server', 'desktop') { CopyTree "$Backup\$part" "$root\$part" -Mirror }
 CopyTree "$Backup\config" $config -Mirror
 CopyTree "$Backup\switch-scripts" "$switch\scripts" -Mirror
 CopyTree "$Backup\switch-conf" "$switch\conf" -Mirror
 Copy-Item "$Backup\installation.json" "$private\installation.json" -Force
 Copy-Item "$Backup\runtime.json" "$private\runtime.json" -Force
 if(Test-Path "$Backup\updater-install.json"){
  WriteState "$private\updater-install.json" (Get-Content "$Backup\updater-install.json" -Raw|ConvertFrom-Json)
  $previousUpdater=Get-Content "$private\updater-install.json" -Raw|ConvertFrom-Json
  & sc.exe config OpenWebPBXUpdater binPath= ('"'+$previousUpdater.Executable+'"')|Out-Null
 }
 if(!(Test-Path "$Backup\updater-install.json") -and (Test-Path "$private\updater-install.json") -and (Test-Path "$root\tools\Remove-Updater.ps1")){& "$root\tools\Remove-Updater.ps1"}
 if(Test-Path "$Backup\tools"){CopyTree "$Backup\tools" "$root\tools" -Mirror}
 if(Test-Path "$Backup\phone-tls"){CopyTree "$Backup\phone-tls" "$private\phone-tls" -Mirror}
 if(Test-Path "$Backup\phone-tls.json"){Copy-Item "$Backup\phone-tls.json" "$private\phone-tls.json" -Force}
 # Storage is preserved by an upgrade. Restore its snapshot only when an operator
 # explicitly chooses rollback; automatic recovery must not remove new media.
 if ($RestoreBackup -or $script:operatorRollback) { CopyTree "$Backup\storage" "$private\storage" -Mirror }
 # Preserve the database OID and the independent updater's connections. The
 # Windows installer owns this dedicated database/public schema; restore all
 # PBX objects in one transaction, including removing failed-migration objects.
 $restoreSql=Join-Path $updates ('restore-'+[Guid]::NewGuid().ToString('N')+'.sql')
 $transactionSql=$restoreSql+'.transaction'
 $backupState=Get-Content "$Backup\complete.json" -Raw|ConvertFrom-Json
 $schemaOwner=if($backupState.schema_owner){[string]$backupState.schema_owner}else{'pg_database_owner'}
 $quotedOwner='"'+$schemaOwner.Replace('"','""')+'"'
 try{
  Run "$root\pgsql\bin\pg_restore.exe" @('--exit-on-error','--file',$restoreSql,"$Backup\database.dump")
  $writer=New-Object IO.StreamWriter($transactionSql,$false,(New-Object Text.UTF8Encoding($false)))
  try{
   $writer.WriteLine('BEGIN; DROP SCHEMA public CASCADE; CREATE SCHEMA public AUTHORIZATION fusionpbx; GRANT USAGE ON SCHEMA public TO PUBLIC;')
   $reader=[IO.File]::OpenText($restoreSql);$buffer=New-Object char[] 65536
   try{while(($count=$reader.Read($buffer,0,$buffer.Length)) -gt 0){$writer.Write($buffer,0,$count)}}finally{$reader.Dispose()}
   $writer.WriteLine('ALTER SCHEMA public OWNER TO '+$quotedOwner+';')
   if($RestoreBackup -or $script:operatorRollback){$writer.WriteLine('DO $$ BEGIN IF to_regclass(''public.v_pbx_update_policies'') IS NOT NULL THEN UPDATE public.v_pbx_update_policies SET mode=''notify'',updated_at=now() WHERE scope_key=''instance''; END IF; END $$;')}
   $writer.WriteLine('COMMIT;')
  }finally{$writer.Dispose()}
  Run "$root\pgsql\bin\psql.exe" @('-h','127.0.0.1','-p','5433','-U','postgres','-d','fusionpbx','-w','-X','-v','ON_ERROR_STOP=1','-f',$transactionSql)
 }finally{Remove-Item $restoreSql,$transactionSql -Force -ErrorAction SilentlyContinue}
 Remove-Item "$private\cache\*" -Recurse -Force -ErrorAction SilentlyContinue
}

if (!(Test-Path "$private\installation.json")) { throw 'Install OpenWeb PBX before applying an update.' }
$state = Get-Content "$private\installation.json" -Raw | ConvertFrom-Json
$previousVersion = $state.Version
$version = $previousVersion
New-Item -ItemType Directory -Force $updates|Out-Null
if (!$state.Completed) { throw 'Complete the existing installation before updating it.' }
Import-Module WebAdministration
$lock = $null; $stopped = $false; $backupReady = $false; $backup = ''; $success = $false
$priorPgPassword = $env:PGPASSWORD
try {
 try{$lock = [IO.File]::Open("$private\upgrade.lock", 'OpenOrCreate', 'ReadWrite', 'None')}catch [IO.IOException]{$script:deferred=$true;throw 'Another PBX update is running.'}
 $env:PGPASSWORD = $state.PostgresPassword
 if($Recover){
  if(Test-Path $journalPath){
   $journal=Get-Content $journalPath -Raw|ConvertFrom-Json
   if($journal.state -in 'prepared','quiescing','deploying','migrating','validating','rolling_back','recovery_required'){
    $backup=$journal.backup_path;$version=$journal.version;$previousVersion=$journal.previous_version
    $script:managerTasks=@($journal.manager_tasks)
    $script:operatorRollback=[bool]$journal.operator_rollback
    if(!(Test-Path "$backup\complete.json")){
     if($journal.state -notin 'prepared','quiescing'){throw 'The interrupted update has no complete recovery backup.'}
     $script:enginePaused=($journal.state -eq 'quiescing');StartPbx;ResumeEngine;CheckHealth $previousVersion;SaveJournal 'rolled_back'
    }else{
     VerifyBackup $backup;SaveJournal 'rolling_back';$recoveryRestoreStarted=$true;$stopped=$true;StopPbx
     RestorePbx $backup;$state=Get-Content "$private\installation.json" -Raw|ConvertFrom-Json;StartPbx;$stopped=$false;CheckHealth $previousVersion;SaveJournal 'rolled_back'
    }
    ResumeManagers
    $state=Get-Content "$private\installation.json" -Raw|ConvertFrom-Json
   }
  }
  StartPbx;CheckHealth $state.Version
  Write-Host 'Update recovery checked; the phone system is running.'
  return
 }
 if($Archive){
  if(!$FeedEnvelope -or !$TargetVersion){throw 'A signed feed and target version are required.'}
  $installedUpdater=Get-Content "$private\updater-install.json" -Raw|ConvertFrom-Json
  $extracted=Join-Path "$updates\staging" ([Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force "$updates\staging"|Out-Null
  $verify=& $installedUpdater.Executable --verify-package --archive $Archive --feed-envelope $FeedEnvelope --target-version $TargetVersion --extract-to $extracted
  if($LASTEXITCODE){throw 'The signed release package could not be verified. No services were stopped.'}
  $verified=($verify -join "`n")|ConvertFrom-Json
  $payload=$verified.package_path
  if($verified.version -ne $TargetVersion){throw 'The signed release version is incorrect.'}
 }

 if ($RestoreBackup) {
  if ($Check) { throw 'Use -Check for an update, or -RestoreBackup for recovery.' }
  $backup = [IO.Path]::GetFullPath($RestoreBackup).TrimEnd('\')
  $backupRoot = [IO.Path]::GetFullPath("$private\backups").TrimEnd('\') + '\'
  if (!$backup.StartsWith($backupRoot, [StringComparison]::OrdinalIgnoreCase) -or !(Test-Path "$backup\complete.json")) { throw 'Choose a completed private OpenWeb PBX update backup.' }
  $expected = (Get-Content "$backup\complete.json" -Raw | ConvertFrom-Json).version
  VerifyBackup $backup
  CheckIdle
  PrepareManagers;PauseEngine
  $version=$expected;$previousVersion=$expected;$script:operatorRollback=$true;$restoreStarted=$true
  SaveJournal 'rolling_back'
  $stopped = $true; StopPbx
  RestorePbx $backup;$state=Get-Content "$private\installation.json" -Raw|ConvertFrom-Json
  StartPbx;ResumeEngine;$stopped = $false; CheckHealth $expected;SaveJournal 'rolled_back';ResumeManagers
  $success = $true
  if(Get-Service OpenWebPBXUpdater -ErrorAction SilentlyContinue){Start-ScheduledTask OpenWebPBX-Updater-Restart}
  Write-Host "Previous installation restored. Backup: $backup"
  return
 }
 $version = (Get-Content "$payload\VERSION" -Raw).Trim()
 if ($version -notmatch '^\d+\.\d+\.\d+$' -or [version]$version -lt [version]$state.Version) { throw 'Choose a valid release at least as new as the installed version.' }
 if (!(Test-Path "$payload\release-manifest.json")) { throw 'Extract the complete release, including its file manifest.' }
 $manifest = Get-Content "$payload\release-manifest.json" -Raw | ConvertFrom-Json
 if ($manifest.version -ne $version) { throw 'The update manifest version does not match the release.' }
 $hashes = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
 foreach($entry in $manifest.files.PSObject.Properties){$hashes.Add($entry.Name,[string]$entry.Value)}
 Write-Host "Verifying $($hashes.Count) release files..."
 $packageRoot = [IO.Path]::GetFullPath($payload).TrimEnd('\') + '\'
 foreach ($entry in $hashes.GetEnumerator()) {
  $path = [IO.Path]::GetFullPath((Join-Path $payload $entry.Key))
  if (!$path.StartsWith($packageRoot, [StringComparison]::OrdinalIgnoreCase) -or !(Test-Path -LiteralPath $path -PathType Leaf) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry.Value) { throw 'Update file verification failed. Download and extract the release again.' }
 }
 foreach ($required in 'web/resources/require.php', 'server/OpenWebPbx.Server.exe', 'desktop/OpenWebPbx.Desktop.exe', 'bootstrap.php') {
  if (!$hashes.ContainsKey($required)) { throw 'The release manifest is missing a required component.' }
 }
 foreach ($item in Get-ChildItem $payload -Force -Recurse) {
  if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Release links are not permitted.' }
  if (!$item.PSIsContainer -and $item.FullName -ne "$payload\release-manifest.json") {
   $relative = $item.FullName.Substring($packageRoot.Length).Replace('\','/')
   if (!$hashes.ContainsKey($relative)) { throw 'The extracted release contains files missing from its manifest.' }
  }
 }
 # Never stage private machine files or source-control data into the web root.
 foreach ($item in Get-ChildItem "$payload\web" -Force -Recurse) {
  if ($item.Name -eq '.git' -or $item.Name -like '.env*' -or $item.Extension -in '.dump','.key','.pfx') { throw 'The release contains a private configuration path.' }
 }
 CheckIdle
 if ($Check) { Write-Host "OpenWeb PBX $version update files and installed call engine passed preflight."; return }
 if($Automatic){CheckWindow}
 CheckIdle
 $backup = Join-Path "$private\backups" ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
 Write-Host 'Release verified. Saving a private backup before updating the server...'
 New-Item -ItemType Directory -Force $backup | Out-Null
 & icacls.exe $backup /inheritance:r /grant '*S-1-5-32-544:(OI)(CI)F' /grant '*S-1-5-18:(OI)(CI)F' | Out-Null
 if ($LASTEXITCODE) { throw 'Private backup access could not be secured.' }
 foreach ($part in 'web','server','desktop') { CopyTree "$root\$part" "$backup\$part" }
 CopyTree $config "$backup\config"
 CopyTree "$switch\scripts" "$backup\switch-scripts"
 CopyTree "$switch\conf" "$backup\switch-conf"
 CopyTree "$private\storage" "$backup\storage"
 Copy-Item "$private\installation.json","$private\runtime.json" $backup
 if(Test-Path "$private\updater-install.json"){Copy-Item "$private\updater-install.json" $backup}
 if(Test-Path "$root\tools"){CopyTree "$root\tools" "$backup\tools"}
 if(Test-Path "$private\phone-tls"){CopyTree "$private\phone-tls" "$backup\phone-tls"}
 if(Test-Path "$private\phone-tls.json"){Copy-Item "$private\phone-tls.json" $backup}
 SaveJournal 'prepared'
 PrepareManagers
 if($Automatic){CheckWindow}
 PauseEngine
 SaveJournal 'quiescing'
 $stopped = $true; StopPbx
 # Capture media completed during the online copy before taking the matching
 # database snapshot. The second copy transfers only the changed files.
 CopyTree "$private\storage" "$backup\storage" -Mirror
 Run "$root\pgsql\bin\pg_dump.exe" @('-h','127.0.0.1','-p','5433','-U','postgres','-d','fusionpbx','-w','-Fc',"--file=$backup\database.dump")
 SealBackup $backup
 $backupReady = $true
 SaveJournal 'deploying'
 Write-Host 'Backup complete. Updating the application and call-engine scripts...'
 # Keep local optional applications and server.json; only reviewed release files
 # are replaced. Database, settings, keys and existing media are never re-created.
 foreach ($part in 'web','server','desktop') { CopyTree "$payload\$part" "$root\$part" }
 SaveJournal 'migrating'
 Push-Location "$root\web"
 try {
  Run "$root\php\php.exe" @('core\upgrade\upgrade_schema.php')
  foreach ($step in '--defaults','--group','--menu') { Run "$root\php\php.exe" @('core\upgrade\upgrade.php',$step) }
  Run "$root\php\php.exe" @("$payload\bootstrap.php","$root\web",'migrate')
 } finally { Pop-Location }
 CopyTree "$root\web\app\switch\resources\scripts" "$switch\scripts"
 CopyTree "$root\web\app\pbx_setup\resources\switch\scripts\app\pbx_setup" "$switch\scripts\app\pbx_setup"
 Copy-Item "$root\web\app\pbx_setup\resources\prompts\*.wav" "$switch\sounds\openwebpbx" -Force
 Copy-Item "$root\web\app\pbx_setup\resources\prompts\openweb.xml" "$switch\conf\languages\en\ivr\openweb.xml" -Force
 Remove-Item "$private\cache\*" -Recurse -Force -ErrorAction SilentlyContinue
 $state.Version = $version
 WriteState "$private\installation.json" $state
 SaveJournal 'validating'
 StartPbx; ResumeEngine; $stopped = $false; CheckHealth $version
 if(Test-Path "$payload\updater\OpenWebPbx.Updater.exe"){& "$payload\Install-Updater.ps1" -PackageRoot $payload -DeferRestart}
 SaveJournal 'completed'
 ResumeManagers
 $success = $true
 Write-Host "OpenWeb PBX $version is running. Private backup: $backup"
 Write-Host "To roll back: .\Upgrade-OpenWebPBX.ps1 -RestoreBackup '$backup'"
} catch {
 $failure = $_
 if($restoreStarted -or $recoveryRestoreStarted){
  try{$stopped=$true;StopPbx}catch{}
  SaveJournal 'recovery_required'
  Write-Warning 'The selected backup has not fully restored. Keep maintenance in place and run recovery after correcting the error.'
 } elseif ($backupReady -and !$RestoreBackup) {
  Write-Warning 'The update failed. Restoring the previous application and database.'
  try { SaveJournal 'rolling_back'; $stopped = $true; StopPbx; RestorePbx $backup; StartPbx; ResumeEngine; $stopped = $false; CheckHealth $previousVersion; SaveJournal 'rolled_back'; ResumeManagers }
  catch { SaveJournal 'recovery_required'; Write-Warning "Automatic recovery needs attention. The private backup is $backup" }
 } elseif ($stopped) { try { StartPbx; $stopped = $false; SaveJournal 'rolled_back'; ResumeManagers } catch { SaveJournal 'recovery_required' } }
 if($Archive -or $Recover){
  $exitCode=if($script:deferred){75}elseif($Recover -or ((Test-Path $journalPath) -and (Get-Content $journalPath -Raw|ConvertFrom-Json).state -eq 'recovery_required')){2}else{1}
  Write-Warning 'The update did not complete. Review the private update log and status.'
 }else{throw $failure}
} finally {
 if ($null -eq $priorPgPassword) { Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue } else { $env:PGPASSWORD = $priorPgPassword }
 if($script:enginePaused -and !$stopped){try{ResumeEngine}catch{}}
 if ($extracted -and (Test-Path $extracted)) { Remove-Item $extracted -Recurse -Force -ErrorAction SilentlyContinue }
 if ($lock) { $lock.Dispose() }
}

if($success -and !$Recover -and !$RestoreBackup){
 $updater=Get-Service OpenWebPBXUpdater -ErrorAction SilentlyContinue
 if($updater -and $updater.Status -ne 'Running'){Start-Service OpenWebPBXUpdater}
 elseif($updater -and !$Archive){Start-ScheduledTask OpenWebPBX-Updater-Restart}
}
if($Archive -or $Recover){exit $exitCode}
