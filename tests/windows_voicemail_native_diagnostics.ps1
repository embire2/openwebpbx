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
$pg=$null;$started=$false
function Run([string]$Exe,[string[]]$Arguments,[string]$Label){
 & $Exe @Arguments 1>>"$work\$Label.private.out" 2>>"$work\$Label.private.err"
 if($LASTEXITCODE){
  $facts.child_label=if($Label -cin @('initdb','start','stop')){$Label}else{'unknown'};$facts.child_exit=[int]$LASTEXITCODE;$facts.child_class='other'
  $errorText=[IO.File]::ReadAllText("$work\$Label.private.err")
  foreach($entry in @(@('administrator','cannot be run as administrator|administrative permissions'),@('permissions','permission denied|access is denied'),@('binaries','same version|could not find.*postgres|could not find.*share|postgres.bki'),@('arguments','invalid option|unrecognized option|not recognized'),@('directory_exists','exists but is not empty'),@('locale','encoding|locale'))){if($errorText -match $entry[1]){$facts.child_class=$entry[0];break}}
  throw ('Owned diagnostic child failed: '+$Label)
 }
}
function PhpCase([string]$Mode,[string]$Php,[string]$Port){
 $safePath=Join-Path $work ($Mode+'.safe.json');$start=[Diagnostics.ProcessStartInfo]::new($Php);$start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 foreach($arg in @((Join-Path $PSScriptRoot 'windows_voicemail_defaults.php'),$source,$safePath)){$start.ArgumentList.Add($arg)}
 $start.Environment['OPENWEB_WINDOWS_NATIVE_TEST']='1';$start.Environment['OPENWEB_VOICEMAIL_TEST_USER']='postgres';$start.Environment.Remove('OPENWEB_VOICEMAIL_TEST_PASSWORD')|Out-Null
 if($Mode -ceq 'explicit_dsn'){$start.Environment['OPENWEB_VOICEMAIL_TEST_DSN']='pgsql:host=127.0.0.1;port='+$Port+';dbname=postgres'}else{$start.Environment.Remove('OPENWEB_VOICEMAIL_TEST_DSN')|Out-Null;$start.Environment['ProgramData']=Join-Path $work 'factory-programdata'}
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
 # The real full installer obtains these exact VC runtimes from its pinned
 # engine MSI before invoking PostgreSQL. Extract the same DLLs privately for
 # this smaller diagnostic; create no engine installation or system service.
 $msi=Join-Path $work 'engine.msi';Invoke-WebRequest 'https://github.com/signalwire/freeswitch/releases/download/v1.11.3/FreeSWITCH-1.11.3-Release-x64.msi' -OutFile $msi
 if((Get-FileHash $msi -Algorithm SHA256).Hash.ToLowerInvariant() -cne 'f5649e33ad46be2ebdb1d98019bd149c86519f0dca9f47fb881207045203a34d'){throw 'Pinned dependency MSI bytes differ.'}
 $runtime=Join-Path $work 'vc-runtime';Run '7z.exe' @('e',$msi,'msvcp140*.dll_amd64.*','vcruntime140*.dll_amd64.*','concrt140*.dll_amd64.*',('-o'+$runtime),'-y') 'extract'
 foreach($file in Get-ChildItem -LiteralPath $runtime -File){$name=$file.Name -replace '_amd64\..*$','';if($name -cnotmatch '^(?:msvcp140(?:_[a-z0-9]+)?|vcruntime140(?:_1)?|concrt140)\.dll$'){throw 'Unexpected pinned private VC dependency.'};Move-Item -LiteralPath $file.FullName -Destination (Join-Path $runtime $name)}
 if(!(Test-Path (Join-Path $runtime 'vcruntime140.dll')) -or !(Test-Path (Join-Path $runtime 'msvcp140.dll'))){throw 'Pinned private VC dependency is incomplete.'}
 $env:PATH=$runtime+';'+$pg+';'+$env:PATH
 $facts.pinned_private_vc_runtime=$true
 $data=Join-Path $work 'pg-data';$port=([Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0));$port.Start();$number=$port.LocalEndpoint.Port;$port.Stop();$port=[string]$number
 Run (Join-Path $pg 'initdb.exe') @('-D',$data,'-A','trust','-U','postgres','--encoding=UTF8','--locale=C') 'initdb'
 Run (Join-Path $pg 'pg_ctl.exe') @('-D',$data,'-l',(Join-Path $work 'postgres.private.log'),'-o',('-h 127.0.0.1 -p '+$port),'-w','start') 'start';$started=$true
 $configRoot=Join-Path $work 'factory-programdata\fusionpbx';New-Item -ItemType Directory -Path $configRoot|Out-Null
 [IO.File]::WriteAllText((Join-Path $configRoot 'config.conf'),("database.0.type = pgsql`ndatabase.0.host = 127.0.0.1`ndatabase.0.port = $port`ndatabase.0.name = postgres`ndatabase.0.username = postgres`ndatabase.0.password = `n"),[Text.UTF8Encoding]::new($false))
 $facts.phase='actual_native_php';foreach($mode in 'explicit_dsn','factory_config'){$facts.cases+=PhpCase $mode (Join-Path $phpRoot 'php.exe') $port}
 $facts.phase='database_isolation';$sql="select count(*) from pg_namespace where nspname like 'vm_defaults_%'; select count(*) from pg_tables where schemaname='public';"
 $counts=& (Join-Path $pg 'psql.exe') -h 127.0.0.1 -p $port -U postgres -d postgres -A -t -c $sql 2>>"$work\isolation.private.err"
 if($LASTEXITCODE -or @($counts).Count -ne 2 -or $counts[0] -cne '0' -or $counts[1] -cne '0'){throw 'The fixture did not preserve its owned isolated database.'}
 $facts.database_isolation=$true;$facts.state=if(@($facts.cases|Where-Object state -cne 'passed').Count){'failed'}else{'passed'}
}catch{$facts.state='failed';$facts.error_type=$_.Exception.GetType().Name;$facts.source_line=[int]$_.InvocationInfo.ScriptLineNumber}
finally{
 try{if($started){Run (Join-Path $pg 'pg_ctl.exe') @('-D',(Join-Path $work 'pg-data'),'-m','fast','-w','stop') 'stop';$started=$false};$facts.cleanup='owned private PostgreSQL stopped; no PBX, installed configuration or customer data modified'}catch{$facts.state='failed';$facts.cleanup='failed'}
 [IO.File]::WriteAllText((Join-Path $output 'qualification.json'),($facts|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
}
if($facts.state -cne 'passed'){throw 'Native voicemail fixture diagnostic failed; only closed facts are exported.'}
