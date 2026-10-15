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
function Check([bool]$Value,[string]$Message){
 if(!$Value){
  $stages=@{
   'The installed helper bytes did not pass native preflight.'='direct_reapply_preflight'
   'The direct same-version helper reapply did not complete.'='direct_reapply_complete'
   'Direct reapply changed preserved database/security/routing data.'='direct_reapply_database_preserved'
   'Direct reapply changed protected credentials, keys, TLS or notification bytes/ACLs.'='direct_reapply_private_files_preserved'
   'A pre-existing manager must not be used or closed by this qualification.'='manager_no_preexisting_process'
   'The installed desktop assembly does not match the real installed version.'='manager_version_matches'
   'The pre-existing own manager task does not match the installed interactive manager contract.'='manager_initial_task_contract'
   'The original owned responsive manager is unavailable before the helper runs.'='manager_original_window_present'
   'The helper did not close the original owned desktop manager.'='manager_original_closed'
   'The durable update journal did not record the actual owned interactive restart task.'='manager_restart_task_recorded'
   'The helper did not automatically reopen a responsive installed desktop in its original owner/session.'='manager_reopened'
  }
  $stage=if($stages.ContainsKey($Message)){$stages[$Message]}else{'qualification_assertion'}
  $script:checkFailure=@{active_case=$stage}
  $callers=@(Get-PSCallStack)
  if($callers.Count -gt 1){
   $caller=$callers[1]
   if($caller.ScriptName -and [IO.Path]::GetFileName($caller.ScriptName) -ceq 'windows-upgrade-acceptance.ps1' -and $caller.ScriptLineNumber -gt 0 -and $caller.ScriptLineNumber -lt 100000){$script:checkFailure.source_basename='windows-upgrade-acceptance.ps1';$script:checkFailure.source_line=[int]$caller.ScriptLineNumber}
  }
  throw $Message
 }
 # A successful assertion accepts the preceding helper result, including an
 # expected forced failure. Later manager/preservation checks have no child.
 $script:helperFailure=$null
}
function ProbeFailure($Record){
 $stages=@('probe_import','probe_settings','database_installation','database_identity','database_roles','database_memberships','database_schema','database_tables','database_columns','database_values','database_save','restore_holds','restore_release','pending_create','pending_check','pending_remove')
 $types=@('BackupError','JSONDecodeError','KeyError','FileNotFoundError','PermissionError','ImportError','ModuleNotFoundError','RuntimeError','ValueError','TypeError','OSError','TimeoutError','AssertionError','UnicodeDecodeError','ExternalFailure')
 if(($Record.schema -isnot [int] -and $Record.schema -isnot [long]) -or $Record.schema -ne 1 -or $Record.active_case -isnot [string] -or $Record.active_case -cnotin $stages -or $Record.error_type -isnot [string] -or $Record.error_type -cnotin $types -or $Record.source_basename -isnot [string] -or $Record.source_basename -cnotin 'private-probe.py','backups.py' -or ($Record.source_line -isnot [int] -and $Record.source_line -isnot [long]) -or $Record.source_line -lt 1 -or $Record.source_line -ge 100000){return $null}
 return @{active_case=$Record.active_case;error_type=$Record.error_type;source_basename=$Record.source_basename;source_line=[int]$Record.source_line}
}
function Python([string[]]$Arguments){
 $failurePath=Join-Path $work 'probe-failure.json';Remove-Item -LiteralPath $failurePath -Force -ErrorAction SilentlyContinue
 & $python -I @Arguments 1>(Join-Path $work 'probe-private.out') 2>(Join-Path $work 'probe-private.err');$code=$LASTEXITCODE
 if($code){
  $script:probeFailure=$null
  if(Test-Path -LiteralPath $failurePath -PathType Leaf){
   $item=Get-Item -LiteralPath $failurePath
   if($item.Length -le 16384 -and !($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){
    try{$script:probeFailure=ProbeFailure (Get-Content -LiteralPath $failurePath -Raw|ConvertFrom-Json)}catch{}
   }
  }
  $script:probeExit=[int]$code
  throw 'A private database or restore-gate qualification operation failed.'
 }
}
function HelperFailure($Record){
 $scripts=@('Upgrade-OpenWebPBX.ps1','Enable-PhoneTLS.ps1','Restore-Gates.ps1','Support-Recovery.ps1','Install-Updater.ps1','Install-NativeEngine.ps1','Install-LocalCodec.ps1','Configure-PHP.ps1','configure-notifications.ps1','Install-Backups.ps1','Install-MailQueue.ps1','Write-PrivateState.ps1')
 $commands=@('php.exe','icacls.exe','pg_dump.exe','pg_restore.exe','psql.exe','robocopy.exe','powershell.exe','python.exe','OpenWebPbx.Updater.exe','OpenWebPbx.Server.exe')
 $safe=@{}
 if($Record.error_type -is [string] -and $Record.error_type -match '^System\.[A-Za-z0-9_.+]{1,150}$'){$safe.error_type=$Record.error_type}
 foreach($prefix in 'source','caller'){
  $name=$Record.($prefix+'_basename');$line=$Record.($prefix+'_line')
  if($name -is [string] -and $name -cin $scripts -and ($line -is [int] -or $line -is [long]) -and $line -gt 0 -and $line -lt 100000){$safe[$prefix+'_basename']=$name;$safe[$prefix+'_line']=[int]$line}
 }
 if($Record.command_basename -is [string] -and $Record.command_basename -cin $commands -and ($Record.command_exit -is [int] -or $Record.command_exit -is [long]) -and $Record.command_exit -ge [int]::MinValue -and $Record.command_exit -le [int]::MaxValue){$safe.command_basename=$Record.command_basename;$safe.command_exit=[int]$Record.command_exit}
 return $safe
}
function HelperLauncher([string]$Path,[string[]]$Arguments,[string]$FailurePath){
 $command="& '"+$Path.Replace("'","''")+"'"
 for($index=0;$index -lt $Arguments.Count;$index++){
  $argument=$Arguments[$index]
  if($argument -cin '-Check','-Recover','-Automatic'){$command+=' '+$argument}
  elseif($argument -cin '-Archive','-FeedEnvelope','-TargetVersion','-CertificateThumbprint','-RestoreBackup'){
   $index++;if($index -ge $Arguments.Count){throw 'A private helper argument is incomplete.'}
   $command+=' '+$argument+" '"+$Arguments[$index].Replace("'","''")+"'"
  }else{throw 'A private helper argument is unsupported.'}
 }
 $template=@'
$ErrorActionPreference='Stop'
function HelperFailure { __FILTER__ }
try {
 $global:LASTEXITCODE=0
 __CALL__
 # An explicit script exit sets $? false for a nonzero result. A successful
 # script may leave a benign native command's LASTEXITCODE behind.
 $helperSucceeded=$?
 if(!$helperSucceeded){exit $LASTEXITCODE}
 exit 0
} catch {
 $record=@{error_type=$_.Exception.GetType().FullName;source_basename=$(if($_.InvocationInfo.ScriptName){[IO.Path]::GetFileName($_.InvocationInfo.ScriptName)}else{''});source_line=[int]$_.InvocationInfo.ScriptLineNumber}
 foreach($field in 'command_basename','command_exit','caller_basename','caller_line'){if($_.Exception.Data.Contains($field)){$record[$field]=$_.Exception.Data[$field]}}
 $safe=HelperFailure ([pscustomobject]$record)
 [IO.File]::WriteAllText('__FAILURE__',($safe|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
 throw
}
'@
 $replacements=@{'__FILTER__'=${function:HelperFailure}.ToString();'__CALL__'=$command;'__FAILURE__'=$FailurePath.Replace("'","''")}
 return [regex]::Replace($template,'__(FILTER|CALL|FAILURE)__',{param($match)$replacements[$match.Value]})
}
function InvokeHelper([string]$Path,[string[]]$Arguments,[string]$Name){
 $stdout=Join-Path $work ($Name+'.out');$stderr=Join-Path $work ($Name+'.err')
 $failurePath=Join-Path $work ($Name+'-failure.json');$launcher=Join-Path $work ($Name+'-launcher.ps1');$script:helperFailure=$null
 Remove-Item -LiteralPath $failurePath -Force -ErrorAction SilentlyContinue
 [IO.File]::WriteAllText($launcher,(HelperLauncher $Path $Arguments $failurePath),[Text.UTF8Encoding]::new($false))
 $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe';$start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.CreateNoWindow=$true
 $start.Environment['PSModulePath']=(Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/Modules')+';'+(Join-Path $env:ProgramFiles 'WindowsPowerShell/Modules')
 foreach($argument in @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$launcher)){$start.ArgumentList.Add($argument)}
 $process=[Diagnostics.Process]::Start($start);$out=$process.StandardOutput.ReadToEndAsync();$err=$process.StandardError.ReadToEndAsync()
 if(!$process.WaitForExit(1200000)){throw 'The native upgrade helper did not finish in its bounded time; its durable journal must recover it.'}
 [IO.File]::WriteAllText($stdout,$out.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($stderr,$err.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($false));$code=$process.ExitCode;$process.Dispose()
 if($code -ne 0 -and (Test-Path -LiteralPath $failurePath -PathType Leaf)){
  $item=Get-Item -LiteralPath $failurePath
  if($item.Length -le 16384 -and !($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){try{$script:helperFailure=HelperFailure (Get-Content -LiteralPath $failurePath -Raw|ConvertFrom-Json)}catch{}}
 }
 return $code
}
$probe=Join-Path $work 'private-probe.py'
$code=@'
import hashlib,hmac,importlib.util,json,os,sys,uuid,traceback
from pathlib import Path
if os.name!='nt' or os.environ.get('GITHUB_ACTIONS')!='true':raise SystemExit(2)
action=sys.argv[1];path=Path(sys.argv[2]);stage='probe_import'
def failure(kind,value,tb):
 allowed_types={'BackupError','JSONDecodeError','KeyError','FileNotFoundError','PermissionError','ImportError','ModuleNotFoundError','RuntimeError','ValueError','TypeError','OSError','TimeoutError','AssertionError','UnicodeDecodeError'}
 frames=[frame for frame in traceback.extract_tb(tb) if Path(frame.filename).name in {'private-probe.py','backups.py'}]
 frame=frames[-1] if frames else None
 safe={'schema':1,'active_case':stage,'error_type':kind.__name__ if kind.__name__ in allowed_types else 'ExternalFailure','source_basename':Path(frame.filename).name if frame else 'private-probe.py','source_line':frame.lineno if frame else 1}
 try:(path.parent/'probe-failure.json').write_text(json.dumps(safe),encoding='utf-8')
 except OSError:pass
 sys.__excepthook__(kind,value,tb)
sys.excepthook=failure
spec=importlib.util.spec_from_file_location('backup',Path('C:/OpenWebPBX/tools/backups.py'));b=importlib.util.module_from_spec(spec);spec.loader.exec_module(b)
stage='probe_settings';settings=b.read_settings()
key_file=path.parent/'audit.key'
if not key_file.exists():key_file.write_bytes(os.urandom(32))
key=key_file.read_bytes()
def digest(value):return hmac.new(key,json.dumps(value,sort_keys=True,separators=(',',':')).encode(),hashlib.sha256).hexdigest()
def save(value):path.write_text(json.dumps(value,sort_keys=True),encoding='utf-8')
if action=='database':
 stage='database_installation'
 installation=json.loads((b.STATE/'installation.json').read_text(encoding='utf-8-sig'))
 admin=settings|{'database.0.username':'postgres','database.0.password':installation['PostgresPassword']}
 stage='database_identity'
 identity=b.query(admin,"select jsonb_build_object('name',datname,'oid',oid,'owner',datdba,'acl',datacl::text) from pg_database where datname=current_database()",json_result=True)
 stage='database_roles'
 roles=b.query(admin,"select json_agg(t order by oid) from (select oid,rolname,rolsuper,rolinherit,rolcreaterole,rolcreatedb,rolcanlogin,rolreplication,rolbypassrls,rolconnlimit,rolpassword,rolvaliduntil,(select coalesce(json_agg(s order by setdatabase),'[]') from (select setdatabase,setconfig from pg_db_role_setting where setrole=a.oid) s) role_config from pg_authid a) t",json_result=True)
 stage='database_memberships'
 memberships=b.query(admin,"select coalesce(json_agg(t order by roleid,member,grantor),'[]') from pg_auth_members t",json_result=True)
 stage='database_schema'
 schema=b.query(admin,"select coalesce(json_agg(t order by name),'[]') from (select nspname name,pg_get_userbyid(nspowner) owner,nspacl::text acl from pg_namespace where nspname='public') t",json_result=True)
 stage='database_tables'
 tables=b.query(settings,"select coalesce(json_agg(t order by name),'[]') from (select c.relname name,pg_get_userbyid(c.relowner) owner,c.relacl::text acl from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind in ('r','p')) t",json_result=True)
 stage='database_columns'
 columns=b.query(settings,"select coalesce(json_agg(t order by table_name,ordinal_position),'[]') from (select table_name,column_name,ordinal_position,data_type,udt_name,is_nullable,column_default from information_schema.columns where table_schema='public') t",json_result=True)
 # Background heartbeats/logs can change after service recovery. Their schema
 # stays covered; all customer and security/routing table values remain exact.
 volatile={'v_pbx_update_status','v_pbx_backup_status','v_pbx_update_commands','v_pbx_job_slots','v_user_logs','v_logs','v_pbx_user_presence','v_pbx_presence'}
 values={}
 stage='database_values'
 for entry in tables:
  table=entry['name']
  if table in volatile:continue
  quoted='"'+table.replace('"','""')+'"'
  rows=b.query(settings,"select coalesce(json_agg(t order by row_to_json(t)::text),'[]') from "+quoted+' t',json_result=True)
  values[table]=digest(rows)
 stage='database_save';save({'identity':digest(identity),'roles':digest(roles),'memberships':digest(memberships),'schema':digest(schema),'tables':digest(tables),'columns':digest(columns),'values':values,'table_count':len(tables)})
elif action=='holds':
 stage='restore_holds'
 if (b.RESTORE/'journal.json').exists():raise RuntimeError('An unrelated restore journal exists')
 with b.exclusive_guard(b.UPGRADE_LOCK):
  plan=b.control('plan');save(plan);b.install_service_holds(plan)
elif action=='release':
 stage='restore_release'
 plan=json.loads(path.read_text());b.control('recover-startup',plan)
 for name in b.HELD_UNITS:(b.RESTORE/('hold-'+name)).unlink(missing_ok=True)
 b.control('resume-factory',plan)
elif action=='pending':
 stage='pending_create'
 identifier=str(uuid.uuid4());b.query(settings,"insert into v_pbx_update_commands(command_uuid,action) values("+b.literal(identifier)+",'check')");save({'command':identifier})
elif action=='pending-check':
 stage='pending_check'
 identifier=json.loads(path.read_text())['command']
 if b.query(settings,'select status from v_pbx_update_commands where command_uuid='+b.literal(identifier))!='pending':raise RuntimeError('A held update was claimed')
elif action=='pending-remove':
 stage='pending_remove'
 identifier=json.loads(path.read_text())['command'];b.query(settings,'delete from v_pbx_update_commands where command_uuid='+b.literal(identifier))
else:raise RuntimeError('Unsupported private qualification operation')
'@
[IO.File]::WriteAllText($probe,$code,[Text.UTF8Encoding]::new($false))
function DatabaseSnapshot([string]$Name){$file=Join-Path $work ($Name+'-database.json');Python @($probe,'database',$file);return Get-Content -LiteralPath $file -Raw|ConvertFrom-Json -AsHashtable}
function FilesSnapshot {
 $directories=@("$root\web","$root\server","$root\desktop","$root\tools","$root\backup-runtime","$root\acme","$root\updater\slots",$configuration,"$switch\conf","$switch\scripts","$switch\mod","$switch\sounds","$state\storage","$state\mobile-notifications","$state\phone-tls","$state\public-access","$state\automatic-backups","$state\backup-restore","$state\backup-control","$state\backup-downloads","$state\codec-compiler-cache","$state\codec-build")
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
 if($probeFailure){
  $report.caller_basename=$report.source_basename;$report.caller_line=$report.source_line
  foreach($entry in $probeFailure.GetEnumerator()){$report[$entry.Key]=$entry.Value}
  $report.command_basename='private-probe.py';$report.command_exit=$probeExit
 }
 if($checkFailure){
  $report.caller_basename=$report.source_basename;$report.caller_line=$report.source_line
  foreach($entry in $checkFailure.GetEnumerator()){$report[$entry.Key]=$entry.Value}
 }
 if($helperFailure -and $checkFailure){
  # Keep the assertion's actual invocation as caller. A product Run wrapper's
  # validated command caller is the more useful child source location.
  if($checkFailure.source_basename){$report.caller_basename=$checkFailure.source_basename;$report.caller_line=$checkFailure.source_line}
  if($helperFailure.caller_basename){$report.source_basename=$helperFailure.caller_basename;$report.source_line=$helperFailure.caller_line}
  elseif($helperFailure.source_basename){$report.source_basename=$helperFailure.source_basename;$report.source_line=$helperFailure.source_line}
  foreach($field in 'error_type','command_basename','command_exit'){if($helperFailure.ContainsKey($field)){$report[$field]=$helperFailure[$field]}}
 }
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
