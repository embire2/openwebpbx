#Requires -RunAsAdministrator
#Requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PackageRoot,[switch]$DisposableHostedRunner,[Parameter(Mandatory)][string]$InputPath,[Parameter(Mandatory)][string]$ReportPath)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if(!$DisposableHostedRunner -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:RUNNER_OS -ne 'Windows' -or $env:GITHUB_REPOSITORY -ne 'embire2/openwebpbx'){throw 'Only the owned disposable hosted Windows instance may run this hook.'}
$fixtureInput=Get-Content -LiteralPath $InputPath -Raw|ConvertFrom-Json
$root='C:\OpenWebPBX';$state=Join-Path $env:ProgramData 'OpenWebPBX';$switch='C:\Program Files\FreeSWITCH';$configuration=Join-Path $env:ProgramData 'fusionpbx'
$installed=Get-Content "$state\installation.json" -Raw|ConvertFrom-Json
if(!$fixtureInput.restore_server -or !$installed.RestoreServer -or !$installed.Completed -or $installed.DomainName -ne 'windowsqa.example.invalid' -or $installed.AdminEmail -ne $fixtureInput.admin_email -or $fixtureInput.run_id -ne $env:GITHUB_RUN_ID){throw 'The exact owned restore-ready factory is required.'}
$assemblyVersion=[Reflection.AssemblyName]::GetAssemblyName("$root\server\OpenWebPbx.Server.dll").Version
if($assemblyVersion -ne [version]($installed.Version+'.0')){throw 'The real installed service assembly and installation version differ; metadata cannot simulate a baseline.'}
$work=Join-Path (Split-Path $InputPath -Parent) ('upgrade-private-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work|Out-Null
& icacls.exe $work /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F'|Out-Null
if($LASTEXITCODE){throw 'Private upgrade qualification permissions could not be secured.'}
$python="$root\backup-runtime\python.exe";$helper="$root\tools\Upgrade-OpenWebPBX.ps1";$fixture=$null;$phase='private snapshots';$gatePlan=$null
$managerSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;$managerSession=[Diagnostics.Process]::GetCurrentProcess().SessionId
$managerName='OpenWebPBX-Manager-'+$managerSid;$managerExe="$root\desktop\OpenWebPbx.Desktop.exe";$managerOriginal=$null;$managerOwned=$false;$managerStarted=$null;$managerAvailable=$false
$report=[ordered]@{schema=1;state='running';checks=@();gates=[ordered]@{direct_113_helper_reapply='pending';direct_failure_rollback='pending';restore_gate_startup='pending';manager_reopen_success='unqualified';manager_reopen_rollback='unqualified';installed_upgrade='unqualified';failure_rollback='unqualified';legacy_106_upgrade='unqualified'};signed_fixtures='absent';baseline='installed candidate; same-version direct reapply is not a newer signed update'}
function Hash([string]$Path){return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function WriteJson([string]$Path,$Value){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))}
function Check([bool]$Value,[string]$Message){if(!$Value){throw $Message}}
function Python([string[]]$Arguments){& $python -I @Arguments;if($LASTEXITCODE){throw 'A private database or restore-gate qualification operation failed.'}}
function InvokeHelper([string]$Path,[string[]]$Arguments,[string]$Name){
 $stdout=Join-Path $work ($Name+'.out');$stderr=Join-Path $work ($Name+'.err')
 $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe';$start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.CreateNoWindow=$true
 $start.Environment['PSModulePath']=(Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/Modules')+';'+(Join-Path $env:ProgramFiles 'WindowsPowerShell/Modules')
 foreach($argument in @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$Path)+$Arguments){$start.ArgumentList.Add($argument)}
 $process=[Diagnostics.Process]::Start($start);$out=$process.StandardOutput.ReadToEndAsync();$err=$process.StandardError.ReadToEndAsync()
 if(!$process.WaitForExit(1200000)){throw 'The native upgrade helper did not finish in its bounded time; its durable journal must recover it.'}
 [IO.File]::WriteAllText($stdout,$out.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($stderr,$err.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($false));$code=$process.ExitCode;$process.Dispose();return $code
}
$probe=Join-Path $work 'private-probe.py'
$code=@'
import hashlib,hmac,importlib.util,json,os,sys,uuid
from pathlib import Path
if os.name!='nt' or os.environ.get('GITHUB_ACTIONS')!='true':raise SystemExit(2)
spec=importlib.util.spec_from_file_location('backup',Path('C:/OpenWebPBX/tools/backups.py'));b=importlib.util.module_from_spec(spec);spec.loader.exec_module(b)
action=sys.argv[1];path=Path(sys.argv[2]);settings=b.read_settings()
key_file=path.parent/'audit.key'
if not key_file.exists():key_file.write_bytes(os.urandom(32))
key=key_file.read_bytes()
def digest(value):return hmac.new(key,json.dumps(value,sort_keys=True,separators=(',',':')).encode(),hashlib.sha256).hexdigest()
def save(value):path.write_text(json.dumps(value,sort_keys=True),encoding='utf-8')
if action=='database':
 installation=json.loads((b.STATE/'installation.json').read_text(encoding='utf-8-sig'))
 admin=settings|{'database.0.username':'postgres','database.0.password':installation['PostgresPassword']}
 identity=b.query(admin,"select jsonb_build_object('name',datname,'oid',oid,'owner',datdba,'acl',datacl::text) from pg_database where datname=current_database()",json_result=True)
 roles=b.query(admin,"select json_agg(t order by oid) from (select oid,rolname,rolsuper,rolinherit,rolcreaterole,rolcreatedb,rolcanlogin,rolreplication,rolbypassrls,rolconnlimit,rolpassword,rolvaliduntil,(select coalesce(json_agg(s order by setdatabase),'[]') from (select setdatabase,setconfig from pg_db_role_setting where setrole=a.oid) s) role_config from pg_authid a) t",json_result=True)
 memberships=b.query(admin,"select coalesce(json_agg(t order by roleid,member,grantor),'[]') from pg_auth_members t",json_result=True)
 schema=b.query(admin,"select coalesce(json_agg(t order by name),'[]') from (select nspname name,pg_get_userbyid(nspowner) owner,nspacl::text acl from pg_namespace where nspname='public') t",json_result=True)
 tables=b.query(settings,"select coalesce(json_agg(t order by name),'[]') from (select c.relname name,pg_get_userbyid(c.relowner) owner,c.relacl::text acl from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind in ('r','p')) t",json_result=True)
 columns=b.query(settings,"select coalesce(json_agg(t order by table_name,ordinal_position),'[]') from (select table_name,column_name,ordinal_position,data_type,udt_name,is_nullable,column_default from information_schema.columns where table_schema='public') t",json_result=True)
 # Background heartbeats/logs can change after service recovery. Their schema
 # stays covered; all customer and security/routing table values remain exact.
 volatile={'v_pbx_update_status','v_pbx_backup_status','v_pbx_update_commands','v_pbx_job_slots','v_user_logs','v_logs','v_pbx_user_presence','v_pbx_presence'}
 values={}
 for entry in tables:
  table=entry['name']
  if table in volatile:continue
  quoted='"'+table.replace('"','""')+'"'
  rows=b.query(settings,"select coalesce(json_agg(t order by row_to_json(t)::text),'[]') from "+quoted+' t',json_result=True)
  values[table]=digest(rows)
 save({'identity':digest(identity),'roles':digest(roles),'memberships':digest(memberships),'schema':digest(schema),'tables':digest(tables),'columns':digest(columns),'values':values,'table_count':len(tables)})
elif action=='holds':
 if (b.RESTORE/'journal.json').exists():raise RuntimeError('An unrelated restore journal exists')
 with b.exclusive_guard(b.UPGRADE_LOCK):
  plan=b.control('plan');save(plan);b.install_service_holds(plan)
elif action=='release':
 plan=json.loads(path.read_text());b.control('recover-startup',plan)
 for name in b.HELD_UNITS:(b.RESTORE/('hold-'+name)).unlink(missing_ok=True)
 b.control('resume-factory',plan)
elif action=='pending':
 identifier=str(uuid.uuid4());b.query(settings,"insert into v_pbx_update_commands(command_uuid,action) values("+b.literal(identifier)+",'check')");save({'command':identifier})
elif action=='pending-check':
 identifier=json.loads(path.read_text())['command']
 if b.query(settings,'select status from v_pbx_update_commands where command_uuid='+b.literal(identifier))!='pending':raise RuntimeError('A held update was claimed')
elif action=='pending-remove':
 identifier=json.loads(path.read_text())['command'];b.query(settings,'delete from v_pbx_update_commands where command_uuid='+b.literal(identifier))
else:raise RuntimeError('Unsupported private qualification operation')
'@
[IO.File]::WriteAllText($probe,$code,[Text.UTF8Encoding]::new($false))
function DatabaseSnapshot([string]$Name){$file=Join-Path $work ($Name+'-database.json');Python @($probe,'database',$file);return Get-Content -LiteralPath $file -Raw|ConvertFrom-Json -AsHashtable}
function FilesSnapshot {
 $directories=@("$root\web","$root\server","$root\desktop","$root\tools","$root\backup-runtime","$root\acme","$root\updater\slots",$configuration,"$switch\conf","$switch\scripts","$switch\mod","$switch\sounds","$state\storage","$state\mobile-notifications","$state\phone-tls","$state\public-access")
 $files=@{}
 # Parent DACLs determine inherited access and need independent recovery even
 # when every child file hash matches. Keep volatile siblings outside the scan.
 foreach($parent in $root,"$root\updater",$state,$switch){
  if(Test-Path -LiteralPath $parent){
   $item=Get-Item -LiteralPath $parent -Force
   Check ($item.PSIsContainer -and !($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) 'A snapshot parent directory is unavailable or linked.'
   $files[$parent]=@{acl=(Get-Acl -LiteralPath $parent).Sddl;directory=$true}
  }
 }
 foreach($directory in $directories){if(Test-Path -LiteralPath $directory){
  foreach($item in @(Get-Item -LiteralPath $directory)+@(Get-ChildItem -LiteralPath $directory -Recurse -Force)){
   if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'A qualification snapshot encountered a link or junction.'}
   $entry=@{acl=(Get-Acl -LiteralPath $item.FullName).Sddl;directory=[bool]$item.PSIsContainer}
   if(!$item.PSIsContainer){$entry.sha256=Hash $item.FullName;$entry.bytes=$item.Length};$files[$item.FullName]=$entry
  }
 }}
 foreach($path in @("$state\installation.json","$state\runtime.json","$state\phone-tls.json","$state\native-engine.json","$state\local-codec.json","$state\updater-install.json","$root\php\php.ini","$root\php\extras\ssl\openssl.cnf","$root\php\extras\ssl\cacert.pem")){
  if(Test-Path -LiteralPath $path){$files[$path]=@{acl=(Get-Acl -LiteralPath $path).Sddl;directory=$false;sha256=(Hash $path);bytes=(Get-Item $path).Length}}
 }
 return $files
}
function TaskSnapshot {
 $tasks=@{}
 $scheduler=New-Object -ComObject Schedule.Service;$scheduler.Connect()
 foreach($name in 'OpenWebPBX-Backups','OpenWebPBX-Cleanup','OpenWebPBX-Updater-Restart','OpenWebPBX Outgoing Mail','OpenWebPBX Certificate Renewal','OpenWebPBX Pending Phone Certificate'){
  $task=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
  if(!$task){$tasks[$name]=@{exists=$false};continue}
  $xml=[xml](Export-ScheduledTask -TaskName $name);$xml.PreserveWhitespace=$false
  $tasks[$name]=@{exists=$true;enabled=[bool]$task.Settings.Enabled;xml=$xml.OuterXml;acl=(Get-Acl -LiteralPath (Join-Path $env:SystemRoot ('System32/Tasks/'+$name))).Sddl;security=$scheduler.GetFolder('\').GetTask($name).GetSecurityDescriptor(7)}
 }
 return $tasks
}
function Equal([object]$Before,[object]$After,[string]$Message){
 # Hashtable ordering differs between fresh deserialization and COM queries.
 $beforeFile=Join-Path $work 'compare-before.json';$afterFile=Join-Path $work 'compare-after.json';WriteJson $beforeFile $Before;WriteJson $afterFile $After
 & $python -I -c 'import json,sys;assert json.load(open(sys.argv[1],encoding="utf-8-sig"))==json.load(open(sys.argv[2],encoding="utf-8-sig"))' $beforeFile $afterFile *> $null
 Check ($LASTEXITCODE -eq 0) $Message
}
function StopUpdater {if((Get-Service OpenWebPBXUpdater).Status -ne 'Stopped'){Stop-Service OpenWebPBXUpdater;(Get-Service OpenWebPBXUpdater).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(45))}}
function Journal {return Get-Content "$state\updates\install-journal.json" -Raw|ConvertFrom-Json}
function ManagerTaskValid([bool]$RequireEnabled=$true) {
 $task=Get-ScheduledTask -TaskName $managerName -ErrorAction SilentlyContinue
 if(!$task){return $false}
 $sid=if($task.Principal.UserId -like 'S-1-*'){$task.Principal.UserId}else{([Security.Principal.NTAccount]::new($task.Principal.UserId)).Translate([Security.Principal.SecurityIdentifier]).Value}
 return ($sid -eq $managerSid -and [string]$task.Principal.LogonType -eq 'Interactive' -and [string]$task.Principal.RunLevel -eq 'Limited' -and @($task.Actions).Count -eq 1 -and $task.Actions.Execute -eq $managerExe -and !$task.Actions.Arguments -and $task.Actions.WorkingDirectory -eq (Split-Path $managerExe) -and [string]$task.Settings.MultipleInstances -eq 'IgnoreNew' -and $task.Settings.ExecutionTimeLimit -eq 'PT0S' -and (!$RequireEnabled -or $task.Settings.Enabled) -and $task.Description -eq 'Reopen the OpenWeb PBX manager for this user after a verified update.')
}
function OwnedManagerProcesses {
 $found=@()
 foreach($record in @(Get-CimInstance Win32_Process -Filter "Name='OpenWebPbx.Desktop.exe'")){
  $owner=Invoke-CimMethod -InputObject $record -MethodName GetOwnerSid
  if($record.ExecutablePath -eq $managerExe -and $owner.ReturnValue -eq 0 -and $owner.Sid -eq $managerSid -and $record.SessionId -eq $managerSession){
   $process=Get-Process -Id $record.ProcessId -ErrorAction SilentlyContinue
   if($process -and $process.StartTime.ToUniversalTime() -ge $managerStarted){$found+=$process}
  }
 }
 return $found
}
function WaitManager([int]$PreviousPid=0,[DateTime]$NotBefore=[DateTime]::MinValue){
 $deadline=[DateTime]::UtcNow.AddSeconds(90)
 $expected=[Reflection.AssemblyName]::GetAssemblyName("$root\desktop\OpenWebPbx.Desktop.dll").Version
 Check ($expected -eq [version]((Get-Content "$state\installation.json" -Raw|ConvertFrom-Json).Version+'.0')) 'The installed desktop assembly does not match the real installed version.'
 $title='OpenWeb PBX '+$expected.ToString(3)
 do{
  foreach($process in @(OwnedManagerProcesses)){
   $process.Refresh()
   if($process.Id -ne $PreviousPid -and $process.StartTime.ToUniversalTime() -ge $NotBefore -and $process.MainWindowHandle -ne [IntPtr]::Zero -and $process.Responding -and $process.MainWindowTitle -eq $title -and (ManagerTaskValid)){return $process}
  }
  Start-Sleep -Milliseconds 500
 }while([DateTime]::UtcNow -lt $deadline)
 return $null
}
function BeginManager {
 # The product helper closes all manager processes. Refuse a foreign/pre-existing
 # one even on this disposable machine rather than touching an unrelated window.
 Check (@(Get-CimInstance Win32_Process -Filter "Name='OpenWebPbx.Desktop.exe'").Count -eq 0) 'A pre-existing manager must not be used or closed by this qualification.'
 if($managerSession -eq 0 -or ![Environment]::UserInteractive){$report.manager_environment='interactive session unavailable';return}
 $task=Get-ScheduledTask -TaskName $managerName -ErrorAction SilentlyContinue
 $original=@{exists=[bool]$task}
 if($task){
  Check (ManagerTaskValid $false) 'The pre-existing own manager task does not match the installed interactive manager contract.'
  $scheduler=New-Object -ComObject Schedule.Service;$scheduler.Connect();$native=$scheduler.GetFolder('\').GetTask($managerName)
  $original.xml=Export-ScheduledTask -TaskName $managerName;$original.enabled=[bool]$task.Settings.Enabled;$original.security=$native.GetSecurityDescriptor(7)
  $original.file_acl=(Get-Acl -LiteralPath (Join-Path $env:SystemRoot ('System32/Tasks/'+$managerName))).Sddl
 }
 $script:managerOriginal=$original;WriteJson (Join-Path $work 'manager-task-original.json') $original
 $script:managerOwned=$true;$script:managerStarted=[DateTime]::UtcNow
 $start=[Diagnostics.ProcessStartInfo]::new($managerExe);$start.UseShellExecute=$false;$start.WorkingDirectory=Split-Path $managerExe
 $start.Environment['PSModulePath']=(Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/Modules')+';'+(Join-Path $env:ProgramFiles 'WindowsPowerShell/Modules')
 $process=[Diagnostics.Process]::Start($start);$process.Dispose()
 $visible=WaitManager
 if($visible){$script:managerAvailable=$true;WriteJson (Join-Path $work 'manager-initial.json') @{pid=$visible.Id;owner=$managerSid;session=$managerSession;title=$visible.MainWindowTitle}}
 else{$report.manager_environment='initial responsive installed window unavailable';ClearManager}
}
function AssertManagerReopened([int]$PreviousPid,[DateTime]$NotBefore,[string]$Gate){
 if(!$managerAvailable){return}
 Check (!(Get-Process -Id $PreviousPid -ErrorAction SilentlyContinue)) 'The helper did not close the original owned desktop manager.'
 Check (@((Journal).manager_tasks) -contains $managerName) 'The durable update journal did not record the actual owned interactive restart task.'
 $visible=WaitManager $PreviousPid $NotBefore
 Check ($null -ne $visible) 'The helper did not automatically reopen a responsive installed desktop in its original owner/session.'
 WriteJson (Join-Path $work ($Gate+'.json')) @{previous_pid=$PreviousPid;new_pid=$visible.Id;owner=$managerSid;session=$managerSession;title=$visible.MainWindowTitle}
 $report.gates[$Gate]='passed'
}
function CurrentManagerPid {
 if(!$managerAvailable){return 0}
 $visible=WaitManager
 Check ($null -ne $visible -and @(OwnedManagerProcesses).Count -eq 1) 'The original owned responsive manager is unavailable before the helper runs.'
 return $visible.Id
}
function ClearManager {
 if(!$managerOwned){return}
 foreach($process in @(OwnedManagerProcesses)){Stop-Process -Id $process.Id -Force -ErrorAction Stop}
 $task=Get-ScheduledTask -TaskName $managerName -ErrorAction SilentlyContinue
 if($task){
  Check (ManagerTaskValid) 'Cleanup refused a changed manager task outside the owned contract.'
  Stop-ScheduledTask -TaskName $managerName
 }
 if($managerOriginal.exists){
  Register-ScheduledTask -TaskName $managerName -Xml $managerOriginal.xml -Force|Out-Null
  if($managerOriginal.enabled){Enable-ScheduledTask -TaskName $managerName|Out-Null}else{Disable-ScheduledTask -TaskName $managerName|Out-Null}
  $scheduler=New-Object -ComObject Schedule.Service;$scheduler.Connect();$native=$scheduler.GetFolder('\').GetTask($managerName)
  # TASK_DONT_ADD_PRINCIPAL_ACE avoids silently widening the exact old task DACL.
  $native.SetSecurityDescriptor($managerOriginal.security,0x10)
  $acl=[Security.AccessControl.FileSecurity]::new();$acl.SetSecurityDescriptorSddlForm($managerOriginal.file_acl);Set-Acl -LiteralPath (Join-Path $env:SystemRoot ('System32/Tasks/'+$managerName)) -AclObject $acl
  Check ((Export-ScheduledTask -TaskName $managerName) -eq $managerOriginal.xml -and (Get-ScheduledTask -TaskName $managerName).Settings.Enabled -eq $managerOriginal.enabled -and (Get-Acl -LiteralPath (Join-Path $env:SystemRoot ('System32/Tasks/'+$managerName))).Sddl -eq $managerOriginal.file_acl -and $native.GetSecurityDescriptor(7) -eq $managerOriginal.security) 'The original own manager task XML/enabled state/file and Scheduler security did not restore exactly.'
 }elseif($task){Unregister-ScheduledTask -TaskName $managerName -Confirm:$false}
 $script:managerOwned=$false;$script:managerAvailable=$false
}
function FaultPayload {
 $payload=Join-Path $work 'forced-payload'
 & robocopy.exe $PackageRoot $payload /E /COPY:DAT /DCOPY:T /R:1 /W:1 /NFL /NDL /NJH /NJS /NP|Out-Null
 if($LASTEXITCODE -ge 8){throw 'The private forced-failure payload could not be prepared.'}
 $fault=@'
<?php
if(PHP_SAPI!=='cli'||getenv('GITHUB_ACTIONS')!=='true')exit(2);
require ($argv[1]??'').'/resources/require.php';
$db=$database->db;$db->exec('CREATE TABLE openweb_windows_rollback_fixture(id integer PRIMARY KEY);INSERT INTO openweb_windows_rollback_fixture VALUES(1)');
$p=$db->prepare('update v_pbx_restore set config=config || cast(:extra as jsonb)');$p->execute(['extra'=>'{"forced_rollback_fixture":true}']);
if($p->rowCount()!==1)exit(74);
passthru('powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '.escapeshellarg(__DIR__.'/forced-failure.ps1'),$code);
exit(73);
'@
 $faultPs=@'
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted'){throw 'Private hosted fixture only.'}
$state=Join-Path $env:ProgramData 'OpenWebPBX';$installation=Get-Content "$state/installation.json" -Raw|ConvertFrom-Json
if(!$installation.RestoreServer -or $installation.DomainName -ne 'windowsqa.example.invalid'){throw 'Private owned instance only.'}
[IO.File]::WriteAllText('C:/OpenWebPBX/backup-runtime/rollback-fixture-only.txt','Owned new-file recovery check')
[IO.File]::WriteAllText("$state/mobile-notifications/config.json",'{"forced_fixture":true}')
[IO.File]::WriteAllText("$state/native-engine.json",'{"schema":1,"forced_fixture":true}')
[xml]$task=Export-ScheduledTask -TaskName OpenWebPBX-Backups
$task.Task.Settings.Hidden='true';Register-ScheduledTask -TaskName OpenWebPBX-Backups -Xml $task.OuterXml -Force|Out-Null
$scheduler=New-Object -ComObject Schedule.Service;$scheduler.Connect();$native=$scheduler.GetFolder('\').GetTask('OpenWebPBX-Backups')
$before=$native.GetSecurityDescriptor(7);$security=[Security.AccessControl.RawSecurityDescriptor]::new($before)
# Change only this owned task's read access; no new ability to run the task.
$ace=[Security.AccessControl.CommonAce]::new([Security.AccessControl.AceFlags]::None,[Security.AccessControl.AceQualifier]::AccessAllowed,0x00120089,[Security.Principal.SecurityIdentifier]::new('S-1-5-19'),$false,$null)
$security.DiscretionaryAcl.InsertAce($security.DiscretionaryAcl.Count,$ace)
$native.SetSecurityDescriptor($security.GetSddlForm(([Security.AccessControl.AccessControlSections]::Owner -bor [Security.AccessControl.AccessControlSections]::Group -bor [Security.AccessControl.AccessControlSections]::Access)),0x10)
if($native.GetSecurityDescriptor(7) -eq $before){throw 'The owned task security fault did not take effect.'}
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'fault-witness.json'),'{"database_and_customer_mutated":true,"notification_mutated":true,"native_metadata_mutated":true,"new_file_created":true,"task_changed":true,"task_security_changed":true}')
'@
 [IO.File]::WriteAllText((Join-Path $payload 'bootstrap.php'),$fault,[Text.UTF8Encoding]::new($false))
 [IO.File]::WriteAllText((Join-Path $payload 'forced-failure.ps1'),$faultPs,[Text.UTF8Encoding]::new($false))
 $manifest=Get-Content (Join-Path $payload 'release-manifest.json') -Raw|ConvertFrom-Json -AsHashtable
 $manifest.files['bootstrap.php']=Hash (Join-Path $payload 'bootstrap.php');$manifest.files['forced-failure.ps1']=Hash (Join-Path $payload 'forced-failure.ps1')
 WriteJson (Join-Path $payload 'release-manifest.json') $manifest
 return $payload
}
function SignedChecks {
 if($fixtureInput.upgrade_archive -or $fixtureInput.failure_archive){
  $script:phase='signed fixture inputs';$report.signed_fixtures='supplied'
  foreach($field in 'upgrade_archive','upgrade_feed','upgrade_target_version','failure_archive','failure_feed','failure_target_version'){Check (![string]::IsNullOrWhiteSpace([string]$fixtureInput.$field)) 'Both complete signed normal/failure fixture contracts are required.'}
  $current=Get-Content "$state\installation.json" -Raw|ConvertFrom-Json
  Check ([version]$fixtureInput.upgrade_target_version -gt [version]$current.Version) 'A real lower-version lab baseline is required; installed-version metadata must never be lowered to fake a signed upgrade.'
  StopUpdater;$database=DatabaseSnapshot 'before-signed'
  $result=InvokeHelper $helper @('-Archive',$fixtureInput.upgrade_archive,'-FeedEnvelope',$fixtureInput.upgrade_feed,'-TargetVersion',$fixtureInput.upgrade_target_version,'-Check') 'signed-preflight';Check ($result -eq 0) 'The original installed verifier/helper did not accept the signed candidate.'
  $result=InvokeHelper $helper @('-Archive',$fixtureInput.upgrade_archive,'-FeedEnvelope',$fixtureInput.upgrade_feed,'-TargetVersion',$fixtureInput.upgrade_target_version) 'signed-upgrade';Check ($result -eq 0 -and (Journal).state -eq 'completed') 'The original installed helper signed upgrade did not complete.'
  StopUpdater;Equal $database (DatabaseSnapshot 'after-signed') 'The signed upgrade changed protected DB/security/customer data.';$report.gates.installed_upgrade='passed'
  $files=FilesSnapshot;$tasks=TaskSnapshot;$database=DatabaseSnapshot 'before-signed-failure'
  $result=InvokeHelper $helper @('-Archive',$fixtureInput.failure_archive,'-FeedEnvelope',$fixtureInput.failure_feed,'-TargetVersion',$fixtureInput.failure_target_version) 'signed-failure';Check ($result -ne 0 -and (Journal).state -eq 'rolled_back') 'The verified signed failure did not finish exact rollback.'
  StopUpdater;Equal $database (DatabaseSnapshot 'after-signed-failure') 'The signed rollback changed DB identity/security/customer state.';Equal $files (FilesSnapshot) 'Signed rollback changed byte/owner/DACL inventories.';Equal $tasks (TaskSnapshot) 'Signed rollback changed task state/security.';$report.gates.failure_rollback='passed'
  $report.checks+='Actual original installed signed-package verification/upgrade and signed failure rollback; private laboratory baseline, not a historical public Windows release'
 }
}

try{
 Check ((Hash $helper) -eq (Hash (Join-Path $PackageRoot 'Upgrade-OpenWebPBX.ps1'))) 'Direct reapply requires the identical installed helper, not an unqualified replacement.'
 if($installed.Version -eq '1.0.12'){$report.baseline='private laboratory service 1.0.12 built from candidate source; not a historical public Windows 1.0.12 release'}
 if(!(Test-Path "$state\phone-tls.json")){
  Import-Module WebAdministration;$binding=Get-WebBinding -Name OpenWebPBX -Protocol https|Select-Object -First 1
  $thumbprint=if($binding.certificateHash -is [string]){$binding.certificateHash}else{([BitConverter]::ToString($binding.certificateHash)).Replace('-','')}
  Check ($thumbprint -match '^[a-fA-F0-9]{40,64}$') 'The trusted fixture HTTPS certificate is unavailable.'
  $result=InvokeHelper "$root\tools\Enable-PhoneTLS.ps1" @('-CertificateThumbprint',$thumbprint) 'source-phone-tls';Check ($result -eq 0 -and (Test-Path "$state\phone-tls.json")) 'Source private phone TLS material did not prepare.'
 }
 $fixtureDirectory=Join-Path $state 'backup-qualification';New-Item -ItemType Directory -Force $fixtureDirectory|Out-Null
 $fixture=Join-Path $fixtureDirectory ('upgrade-'+[Guid]::NewGuid().ToString('N')+'.json');Copy-Item -LiteralPath $InputPath -Destination $fixture
 $prior=$env:OPENWEB_WINDOWS_BACKUP_TEST;$env:OPENWEB_WINDOWS_BACKUP_TEST='1'
 Push-Location "$root\web"
 try{& "$root\php\php.exe" (Join-Path $PSScriptRoot 'windows-backups-fixture.php') create $fixture;Check ($LASTEXITCODE -eq 0) 'The owned preservation PBX fixture failed.'}finally{Pop-Location}
 StopUpdater;SignedChecks
 $before=DatabaseSnapshot 'before-reapply'
 $protected=@{};foreach($path in "$configuration\config.conf","$configuration\openweb-template.key","$state\runtime.json","$state\mobile-notifications\config.json","$state\phone-tls.json"){if(Test-Path $path){$protected[$path]=@{hash=(Hash $path);acl=(Get-Acl $path).Sddl}}}
 $phase='actual direct helper reapply';$result=InvokeHelper (Join-Path $PackageRoot 'Upgrade-OpenWebPBX.ps1') @('-Check') 'direct-preflight';Check ($result -eq 0) 'The installed helper bytes did not pass native preflight.'
 BeginManager
 $oldManager=CurrentManagerPid;$managerInvocation=[DateTime]::UtcNow
 $result=InvokeHelper (Join-Path $PackageRoot 'Upgrade-OpenWebPBX.ps1') @() 'direct-install';Check ($result -eq 0 -and (Journal).state -eq 'completed') 'The direct same-version helper reapply did not complete.'
 AssertManagerReopened $oldManager $managerInvocation 'manager_reopen_success'
 StopUpdater;Equal $before (DatabaseSnapshot 'after-reapply') 'Direct reapply changed preserved database/security/routing data.'
 foreach($path in $protected.Keys){Check ((Hash $path) -eq $protected[$path].hash -and (Get-Acl $path).Sddl -eq $protected[$path].acl) 'Direct reapply changed protected credentials, keys, TLS or notification bytes/ACLs.'}
 $report.gates.direct_113_helper_reapply='passed';$report.checks+='Actual identical installed-1.0.13 helper native preflight and same-version reapply; protected PBX/PG roles/database/keys/notifications/TLS preserved'
 $phase='actual direct post-deploy rollback';$payload=FaultPayload
 $files=FilesSnapshot;$tasks=TaskSnapshot;$database=DatabaseSnapshot 'before-failure'
 WriteJson (Join-Path $work 'before-files.json') $files;WriteJson (Join-Path $work 'before-tasks.json') $tasks
 $oldManager=CurrentManagerPid;$managerInvocation=[DateTime]::UtcNow
 $result=InvokeHelper (Join-Path $payload 'Upgrade-OpenWebPBX.ps1') @() 'forced-direct';Check ($result -ne 0 -and (Journal).state -eq 'rolled_back') 'The post-deploy fault did not finish its actual automatic rollback.'
 AssertManagerReopened $oldManager $managerInvocation 'manager_reopen_rollback'
 $witness=Get-Content (Join-Path $payload 'fault-witness.json') -Raw|ConvertFrom-Json
 foreach($field in 'database_and_customer_mutated','notification_mutated','native_metadata_mutated','new_file_created','task_changed','task_security_changed'){Check ($witness.$field -eq $true) 'The injected failure did not reach every required native mutation.'}
 StopUpdater;Equal $database (DatabaseSnapshot 'after-failure') 'The real rollback changed DB identity, owner/grants, roles/credentials, schema or preserved table values.'
 Equal $files (FilesSnapshot) 'The real rollback changed file bytes, original/new-file inventory or owner/DACL.'
 Equal $tasks (TaskSnapshot) 'The real rollback changed original task XML, enabled state, task-file ACL or Scheduler security.'
 Check (!(Test-Path "$root\backup-runtime\rollback-fixture-only.txt")) 'Rollback retained a newly created private runtime file.'
 $report.gates.direct_failure_rollback='passed';$report.checks+='Actual post-deploy DB/config/notification/native metadata/new-file/task fault; automatic rollback restored exact files/SDDL/tasks and HMAC-verified DB/security/customer values'
 if($managerAvailable){$report.checks+='Actual installed WinUI window automatically closes and reopens after successful reapply and forced rollback, with real assembly/title, original SID/session and new PID'}
 ClearManager
 $phase='restore gate native startup';$gatePlan=Join-Path $work 'gate-plan.json';Python @($probe,'holds',$gatePlan)
 $result=InvokeHelper $helper @('-Check') 'held-preflight';Check ($result -ne 0) 'A restore hold allowed upgrade preflight.'
 $result=InvokeHelper $helper @('-Recover') 'held-recover';Check ($result -eq 0) 'Held boot recovery did not preserve web-only administration.'
 Check ((Get-Service FreeSWITCH).Status -eq 'Stopped' -and (Get-Service OpenWebPBX).Status -eq 'Stopped') 'Held recovery started calls or jobs.'
 $pending=Join-Path $work 'pending-command.json';Python @($probe,'pending',$pending)
 Set-Service OpenWebPBXUpdater -StartupType Manual;Start-Service OpenWebPBXUpdater;Start-Sleep -Seconds 25
 Python @($probe,'pending-check',$pending)
 Check ((Get-Service FreeSWITCH).Status -eq 'Stopped' -and (Get-Service OpenWebPBX).Status -eq 'Stopped') 'The actual updater startup bypassed call/job restore holds.'
 StopUpdater;Python @($probe,'pending-remove',$pending);Python @($probe,'release',$gatePlan);$gatePlan=$null
 $report.gates.restore_gate_startup='passed';$report.checks+='Actual installed helper and .NET updater startup retain all restore holds and refuse claiming a pending update while web-only administration stays available'

 $report.state='passed'
}catch{
 $report.state='failed';$report.failed_phase=$phase
 $report.error_type=$_.Exception.GetType().FullName;$report.source_basename=if($_.InvocationInfo.ScriptName){Split-Path -Leaf $_.InvocationInfo.ScriptName}else{'windows-upgrade-acceptance.ps1'};$report.source_line=[int]$_.InvocationInfo.ScriptLineNumber
 Write-Error ('Windows upgrade acceptance failed in '+$phase+'. Private recovery evidence retained.') -ErrorAction Continue
}finally{
 try{ClearManager}catch{$report.state='failed';$report.failed_phase='owned manager cleanup'}
 if($gatePlan){try{StopUpdater;Python @($probe,'release',$gatePlan)}catch{$report.state='failed';$report.failed_phase='restore hold cleanup'}}
 if($fixture -and (Test-Path $fixture)){
  try{Push-Location "$root\web";try{& "$root\php\php.exe" (Join-Path $PSScriptRoot 'windows-backups-fixture.php') clear $fixture;Check ($LASTEXITCODE -eq 0) 'Owned upgrade PBX cleanup failed.'}finally{Pop-Location}}catch{$report.state='failed';$report.failed_phase='owned fixture cleanup'}
  Remove-Item -LiteralPath $fixture -Force -ErrorAction SilentlyContinue
 }
 if($null -eq $prior){Remove-Item Env:\OPENWEB_WINDOWS_BACKUP_TEST -ErrorAction SilentlyContinue}else{$env:OPENWEB_WINDOWS_BACKUP_TEST=$prior}
 if($report.state -eq 'passed' -and (Get-Service OpenWebPBXUpdater).Status -ne 'Running'){Start-Service OpenWebPBXUpdater}
 WriteJson $ReportPath $report
}
if($report.state -ne 'passed'){throw 'The actual upgrade acceptance hook failed; no passing qualification is implied.'}
Write-Output 'Direct helper reapply, exact forced rollback and restore startup gates passed. Signed/historical gates are recorded separately.'
