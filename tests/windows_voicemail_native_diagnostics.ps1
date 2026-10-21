#Requires -Version 7.4
[CmdletBinding()]
param()
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:RUNNER_OS -ne 'Windows' -or $env:GITHUB_REPOSITORY -ne 'embire2/openwebpbx' -or [Environment]::OSVersion.Version.Build -lt 26100){throw 'Explicit owned disposable Server2025 diagnostic runner required.'}
$source=Split-Path $PSScriptRoot -Parent;$work=Join-Path $env:RUNNER_TEMP ('openweb-vm-diagnostic-'+[Guid]::NewGuid().ToString('N'));$output=Join-Path $env:RUNNER_TEMP 'openweb-vm-diagnostic-public'
New-Item -ItemType Directory -Path $work,$output|Out-Null
& icacls.exe $work /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F'|Out-Null
if($LASTEXITCODE){throw 'Private diagnostic storage required.'}
$facts=[ordered]@{schema=1;case='native_windows_voicemail_defaults_diagnostic';state='running';source_commit=$env:GITHUB_SHA;product_runtime_modified=$false;cases=@();cleanup='pending';phase='prerequisites'}
$pg=$null;$data=$null;$started=$false
function Checkpoint {
 [IO.File]::WriteAllText((Join-Path $output 'qualification.json'),($facts|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
}
function Run([string]$Exe,[string[]]$Arguments,[string]$Label){
 $facts.active_child=if($Label -cin @('initdb','start','stop','runtime','extract')){$Label}else{'unknown'};Checkpoint
 $start=[Diagnostics.ProcessStartInfo]::new((Get-Command $Exe -ErrorAction Stop).Source);$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 foreach($argument in $Arguments){$start.ArgumentList.Add($argument)}
 $process=[Diagnostics.Process]::Start($start);$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync();$code=$null
 try{
  $deadline=if($Label -ceq 'runtime'){180000}else{90000}
  if(!$process.WaitForExit($deadline)){
   try{$process.Kill($true);$null=$process.WaitForExit(5000)}catch{}
   $facts.child_label=$facts.active_child;$facts.child_class='deadline';$facts.child_exit=$null;Checkpoint;throw 'The owned diagnostic child exceeded its closed deadline.'
  }
  $code=$process.ExitCode;$outReady=$stdout.Wait(5000);$errReady=$stderr.Wait(5000)
  if(!$facts.child_streams){$facts.child_streams=@{}};$facts.child_streams[$Label]=@{direct_exit=[int]$code;stdout_closed=[bool]$outReady;stderr_closed=[bool]$errReady}
  if($outReady){[IO.File]::AppendAllText("$work\$Label.private.out",$stdout.GetAwaiter().GetResult())}
  if($errReady){[IO.File]::AppendAllText("$work\$Label.private.err",$stderr.GetAwaiter().GetResult())}
  if($code){
   $facts.child_label=$facts.active_child;$facts.child_exit=[int]$code;$facts.child_class='other'
   $errorText=if($errReady){$stderr.GetAwaiter().GetResult()}else{''}
   foreach($entry in @(@('administrator','cannot be run as administrator|administrative permissions'),@('permissions','permission denied|access is denied'),@('binaries','same version|could not find.*postgres|could not find.*share|postgres.bki'),@('arguments','invalid option|unrecognized option|not recognized'),@('directory_exists','exists but is not empty'),@('locale','encoding|locale'))){if($errorText -match $entry[1]){$facts.child_class=$entry[0];break}}
   Checkpoint;throw ('Owned diagnostic child failed: '+$Label)
  }
  Checkpoint
 }finally{$process.Dispose()}
}
function OwnedPostgres {
 if(!$data -or !$pg){return @()}
 $wanted=[IO.Path]::GetFullPath((Join-Path $pg 'postgres.exe'));$directory=[IO.Path]::GetFullPath($data).Replace('/','\')
 return @(Get-CimInstance Win32_Process -Filter "Name='postgres.exe'"|Where-Object {$_.ExecutablePath -and [IO.Path]::GetFullPath($_.ExecutablePath) -ieq $wanted -and $_.CommandLine -and $_.CommandLine.Replace('/','\').Contains($directory)})
}
function StageFixedFixture([string]$Original,[string]$Destination){
 if((Get-FileHash $Original -Algorithm SHA256).Hash.ToLowerInvariant() -cne '0c468f70d5836c4112ce850d168026317c7e6fa094eaa3d066da5097cfd87d45' -or (Test-Path -LiteralPath $Destination)){throw 'The exact preserved original fixture and a new destination are required.'}
 $old=@'
    $installed = config::load(rtrim(getenv('ProgramData') ?: 'C:/ProgramData', '/\\').'/fusionpbx/config.conf');
    $host = $installed->get('database.0.host'); $port = $installed->get('database.0.port'); $name = $installed->get('database.0.name');
    if ($host !== '127.0.0.1' || !ctype_digit((string)$port) || !preg_match('/^[a-zA-Z0-9_]+$/D', (string)$name)) throw new RuntimeException('Only the disposable local factory database is allowed.');
    $connection = new PDO('pgsql:host='.$host.';port='.$port.';dbname='.$name, $installed->get('database.0.username'), $installed->get('database.0.password'), [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
    config::$config = null;
'@
 $new=@'
    // Match config::read() INI semantics without its immutable PROJECT_ROOT
    // side effect; the real singleton below must first load our owned fixture.
    $installed = parse_ini_file(rtrim(getenv('ProgramData') ?: 'C:/ProgramData', '/\\').'/fusionpbx/config.conf', false);
    if (!is_array($installed)) throw new RuntimeException('The disposable factory database configuration is unavailable.');
    $host = $installed['database.0.host'] ?? null; $port = $installed['database.0.port'] ?? null; $name = $installed['database.0.name'] ?? null;
    $username = $installed['database.0.username'] ?? null; $password = $installed['database.0.password'] ?? null;
    if ($host !== '127.0.0.1' || !ctype_digit((string)$port) || !preg_match('/^[a-zA-Z0-9_]+$/D', (string)$name) || !is_string($username) || !is_string($password)) throw new RuntimeException('Only the disposable local factory database is allowed.');
    $connection = new PDO('pgsql:host='.$host.';port='.$port.';dbname='.$name, $username, $password, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
'@
 $text=[IO.File]::ReadAllText($Original);$fixed=$text.Replace($old,$new)
 [IO.File]::WriteAllText($Destination,$fixed,[Text.UTF8Encoding]::new($false))
 if((Get-FileHash $Destination -Algorithm SHA256).Hash.ToLowerInvariant() -cne '8e08a91444c9ccba8bf730b8d568287bca592714990ab834b2159a66ffb839d1'){throw 'The staged INI-only correction differs from its peer-reviewed source.'}
 return $Destination
}
function PhpCase([string]$Mode,[string]$Php,[string]$Port,[string]$Fixture){
 $safePath=Join-Path $work ($Mode+'.safe.json');$start=[Diagnostics.ProcessStartInfo]::new($Php);$start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 foreach($arg in @($Fixture,$source,$safePath)){$start.ArgumentList.Add($arg)}
 $start.Environment['OPENWEB_WINDOWS_NATIVE_TEST']='1';$start.Environment['OPENWEB_VOICEMAIL_TEST_USER']='postgres';$start.Environment.Remove('OPENWEB_VOICEMAIL_TEST_PASSWORD')|Out-Null
 if($Mode.EndsWith('explicit_dsn')){$start.Environment['OPENWEB_VOICEMAIL_TEST_DSN']='pgsql:host=127.0.0.1;port='+$Port+';dbname=postgres'}else{$start.Environment.Remove('OPENWEB_VOICEMAIL_TEST_DSN')|Out-Null;$start.Environment['ProgramData']=Join-Path $work 'factory-programdata'}
 $process=[Diagnostics.Process]::Start($start);$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
 try{
  if(!$process.WaitForExit(60000)){try{$process.Kill($true)}catch{};throw 'The actual PHP fixture exceeded its bounded diagnostic time.'}
  [IO.File]::WriteAllText("$work\$Mode.private.out",$stdout.GetAwaiter().GetResult());[IO.File]::WriteAllText("$work\$Mode.private.err",$stderr.GetAwaiter().GetResult())
  $record=[ordered]@{mode=$Mode;exit_code=$process.ExitCode;state=if($process.ExitCode){'failed'}else{'passed'}}
  if(Test-Path -LiteralPath $safePath){
   $row=Get-Content -LiteralPath $safePath -Raw|ConvertFrom-Json
   if($row.schema -eq 1 -and $row.state -ceq 'failed' -and $row.error_type -cin @('RuntimeException','InvalidArgumentException','PDOException','TypeError','ValueError','Error','Exception') -and $row.source_basename -cin @('windows_voicemail_defaults.php','app_defaults.php','config.php','pbx_voicemail_policy.php','external_component') -and ($row.source_line -is [long] -or $row.source_line -is [int])){
    if($row.source_line -ge 1 -and $row.source_line -le 99999 -and ($row.checks_completed -is [int] -or $row.checks_completed -is [long]) -and $row.checks_completed -ge 0 -and $row.checks_completed -le 128){$record.failure=@{error_type=$row.error_type;source_basename=$row.source_basename;source_line=[int]$row.source_line;checks_completed=[int]$row.checks_completed}}
   }
  }
  return $record
 }finally{$process.Dispose()}
}
try{
 $zip=Join-Path $work 'php.zip';Invoke-WebRequest 'https://downloads.php.net/~windows/releases/php-8.4.27-nts-Win32-vs17-x64.zip' -OutFile $zip
 if((Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant() -cne '93bd8a815a52156606fb906d0573437908c61f96e2cc52c03a51e36a41bf5236'){throw 'Pinned official PHP bytes differ.'}
 $phpRoot=Join-Path $work 'php';Expand-Archive $zip $phpRoot
 [IO.File]::WriteAllText((Join-Path $phpRoot 'php.ini'),('extension_dir="'+$phpRoot.Replace('\','/')+'/ext"'+"`n"+'extension=pdo_pgsql'+"`n"),[Text.UTF8Encoding]::new($false))
 $pgZip=Join-Path $work 'postgresql.zip';Invoke-WebRequest 'https://get.enterprisedb.com/postgresql/postgresql-18.6-5-windows-x64-binaries.zip' -OutFile $pgZip
 if((Get-FileHash $pgZip -Algorithm SHA256).Hash.ToLowerInvariant() -cne 'e2246ba91d22345bc3d017586c09ede52d9df180b1eeb480f050445f1cad84e2'){throw 'Pinned official PostgreSQL bytes differ.'}
 Run tar.exe @('-xf',$pgZip,'-C',$work) 'extract';$pg=Join-Path $work 'pgsql\bin'
 $facts.phase='microsoft_runtime';Run (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $source 'packaging/windows/Ensure-Runtime.ps1')) 'runtime'
 $facts.microsoft_runtime_uses_actual_installer=$true;$facts.phase='prerequisites'
 $data=Join-Path $work 'pg-data';$port=([Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0));$port.Start();$number=$port.LocalEndpoint.Port;$port.Stop();$port=[string]$number
 # PostgreSQL restarts with its restricted setup-user token. Preserve the
 # old Admin/SYSTEM-only failure, then grant the exact installing SID as the
 # actual installer does; do not broaden any other path or principal.
 $legacyData=Join-Path $work 'legacy-pg-data';$legacyRefused=$false
 try{Run (Join-Path $pg 'initdb.exe') @('-D',$legacyData,'-A','trust','-U','postgres','--encoding=UTF8','--locale=C') 'initdb'}catch{$legacyRefused=$true}
 if(!$legacyRefused -or $facts.child_exit -ne -1073741515){throw 'The original restricted setup-user ACL refusal was not reproduced.'}
 $facts.prerequisite_acl_negative=@{exit_code=[int]$facts.child_exit;setup_sid_rule_present=$false}
 foreach($key in 'child_label','child_exit','child_class'){$facts.Remove($key)}
 $setupSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
 & icacls.exe $work /grant:r ('*'+$setupSid+':(OI)(CI)F')|Out-Null
 if($LASTEXITCODE){throw 'The exact setup identity ACL could not be applied.'}
 $acl=Get-Acl -LiteralPath $work
 $matches=@($acl.Access|Where-Object {$_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -ceq $setupSid -and $_.AccessControlType -eq 'Allow' -and $_.FileSystemRights.HasFlag([Security.AccessControl.FileSystemRights]::FullControl)})
 if(!$acl.AreAccessRulesProtected -or $acl.Access.Count -ne 3 -or $matches.Count -ne 1){throw 'The private setup-user ACL is not the exact intended three-principal policy.'}
 Run (Join-Path $pg 'initdb.exe') @('-D',$data,'-A','trust','-U','postgres','--encoding=UTF8','--locale=C') 'initdb'
 $facts.prerequisite_acl_positive=@{setup_sid_rule_present=$true;initdb_exit=0}

 Run (Join-Path $pg 'pg_ctl.exe') @('-D',$data,'-l',(Join-Path $work 'postgres.private.log'),'-o',('-h 127.0.0.1 -p '+$port),'-w','start') 'start';$started=$true
 $configRoot=Join-Path $work 'factory-programdata\fusionpbx';New-Item -ItemType Directory -Path $configRoot|Out-Null
 [IO.File]::WriteAllText((Join-Path $configRoot 'config.conf'),("document.root = $source`ndatabase.0.type = pgsql`ndatabase.0.host = 127.0.0.1`ndatabase.0.port = $port`ndatabase.0.name = postgres`ndatabase.0.username = postgres`ndatabase.0.password = `n"),[Text.UTF8Encoding]::new($false))
 $facts.phase='actual_native_php';$originalFixture=Join-Path $work 'original-voicemail-defaults.php'
 Invoke-WebRequest 'https://raw.githubusercontent.com/embire2/openwebpbx/3f8e25330b2bd3aefab076286b38b780c3980bd6/tests/windows_voicemail_defaults.php' -OutFile $originalFixture
 $fixedFixture=StageFixedFixture $originalFixture (Join-Path $work 'fixed-voicemail-defaults.php')
 $facts.fixture_bindings=@{original_source_commit='3f8e25330b2bd3aefab076286b38b780c3980bd6';original_sha256='0c468f70d5836c4112ce850d168026317c7e6fa094eaa3d066da5097cfd87d45';fixed_sha256='8e08a91444c9ccba8bf730b8d568287bca592714990ab834b2159a66ffb839d1';change='readonly_factory_INI_without_project_constants'}
 foreach($mode in 'old_explicit_dsn','old_factory_config','fixed_explicit_dsn','fixed_factory_config'){$fixture=if($mode.StartsWith('old_')){$originalFixture}else{$fixedFixture};$facts.cases+=PhpCase $mode (Join-Path $phpRoot 'php.exe') $port $fixture}

 $facts.phase='database_isolation';$sql="select count(*) from pg_namespace where nspname like 'vm_defaults_%'; select count(*) from pg_tables where schemaname='public';"
 $counts=& (Join-Path $pg 'psql.exe') -h 127.0.0.1 -p $port -U postgres -d postgres -A -t -c $sql 2>>"$work\isolation.private.err"
 if($LASTEXITCODE -or @($counts).Count -ne 2 -or $counts[0] -cne '0' -or $counts[1] -cne '0'){throw 'The fixture did not preserve its owned isolated database.'}
 $facts.database_isolation=$true
 $oldFactory=@($facts.cases|Where-Object mode -ceq 'old_factory_config')
 $positive=@($facts.cases|Where-Object {$_.mode -cin @('old_explicit_dsn','fixed_explicit_dsn','fixed_factory_config')})
 $negative=$oldFactory.Count -eq 1 -and $oldFactory[0].state -ceq 'failed' -and $oldFactory[0].failure.error_type -ceq 'RuntimeException' -and $oldFactory[0].failure.checks_completed -eq 18
 $facts.old_factory_constants_negative=[bool]$negative
 $facts.state=if($negative -and $positive.Count -eq 3 -and @($positive|Where-Object state -cne 'passed').Count -eq 0){'passed'}else{'failed'}
}catch{$facts.state='failed';$facts.error_type=$_.Exception.GetType().Name;$facts.source_line=[int]$_.InvocationInfo.ScriptLineNumber}
finally{
 try{
  $pidFile=if($data){Join-Path $data 'postmaster.pid'}else{$null};$owned=@(OwnedPostgres)
  if($started -or $owned.Count -or ($pidFile -and (Test-Path -LiteralPath $pidFile))){
   if(!$data -or [IO.Path]::GetFullPath($data) -cne [IO.Path]::GetFullPath((Join-Path $work 'pg-data'))){throw 'Only the exact owned data directory may be stopped.'}
   if($pidFile -and (Test-Path -LiteralPath $pidFile)){$item=Get-Item -LiteralPath $pidFile;if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked database PID refused.'};$lines=[IO.File]::ReadAllLines($pidFile);if($lines.Count -lt 2 -or [IO.Path]::GetFullPath($lines[1]) -ine [IO.Path]::GetFullPath($data)){throw 'Foreign database PID identity refused.'}}
   try{Run (Join-Path $pg 'pg_ctl.exe') @('-D',$data,'-m','fast','-w','stop') 'stop'}catch{if(@(OwnedPostgres).Count){throw}}
   $started=$false
  }
  if(@(OwnedPostgres).Count){throw 'An owned private PostgreSQL process is still running.'}
  $facts.cleanup='owned private PostgreSQL stopped; no PBX, installed configuration or customer data modified'
 }catch{$facts.state='failed';$facts.cleanup='failed'}
 [IO.File]::WriteAllText((Join-Path $output 'qualification.json'),($facts|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
}
if($facts.state -cne 'passed'){throw 'Native voicemail fixture diagnostic failed; only closed facts are exported.'}
