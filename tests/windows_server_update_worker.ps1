[CmdletBinding()]
param([Parameter(Mandatory)][string]$Output)
$ErrorActionPreference='Stop'
if($env:OS -cne 'Windows_NT' -or $env:GITHUB_ACTIONS -cne 'true'){throw 'Run only on an isolated Windows Actions runner.'}
$work=Join-Path $env:RUNNER_TEMP ('server-update-pg-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work|Out-Null
$started=$false;$oldConnection=$env:OPENWEB_TEST_DATABASE;$oldCallbackConnection=$env:OPENWEB_CMB_TEST_DATABASE
function Native([string]$program,[string[]]$arguments){& $program @arguments;if($LASTEXITCODE -ne 0){throw 'Owned PostgreSQL fixture command failed.'}}
try{
 $zip=Join-Path $work postgresql.zip
 Invoke-WebRequest -Uri 'https://get.enterprisedb.com/postgresql/postgresql-18.6-5-windows-x64-binaries.zip' -OutFile $zip
 if((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant() -cne 'e2246ba91d22345bc3d017586c09ede52d9df180b1eeb480f050445f1cad84e2'){throw 'PostgreSQL archive hash mismatch.'}
 Native tar.exe @('-xf',$zip,'-C',$work)
 $pg=Join-Path $work 'pgsql\bin';$data=Join-Path $work database
 $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0);$listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop()
 Native (Join-Path $pg initdb.exe) @('-D',$data,'-U','postgres','-A','trust','--encoding=UTF8','--locale=C')
 Native (Join-Path $pg pg_ctl.exe) @('-D',$data,'-l',(Join-Path $work 'postgres.log'),'-o',('-h 127.0.0.1 -p '+$port),'-w','start');$started=$true
 $env:OPENWEB_TEST_DATABASE='Host=127.0.0.1;Port='+$port+';Username=postgres;Database=postgres;Timeout=10;Command Timeout=20'
 & dotnet run --project platform/OpenWebPbx.Updater.Checks -c Release -- --windows-server-update-checks 2>&1|Tee-Object -FilePath $Output
 if($LASTEXITCODE -ne 0){throw 'Actual Windows server update worker checks failed.'}
 & dotnet run --project tests/greetings-worker -c Release 2>&1|Tee-Object -FilePath (Join-Path (Split-Path $Output) 'greetings-worker.log')
 if($LASTEXITCODE -ne 0){throw 'Windows greeting preparation/dispatch checks failed.'}
 $env:OPENWEB_CMB_TEST_DATABASE=$env:OPENWEB_TEST_DATABASE
 & dotnet run --project tests/call-me-back-worker -c Release 2>&1|Tee-Object -FilePath (Join-Path (Split-Path $Output) 'call-me-back-worker.log')
 if($LASTEXITCODE -ne 0){throw 'Windows callback preparation/immutable refresh/maintenance checks failed.'}
}finally{
 $env:OPENWEB_TEST_DATABASE=$oldConnection
 $env:OPENWEB_CMB_TEST_DATABASE=$oldCallbackConnection
 if($started){Native (Join-Path $pg pg_ctl.exe) @('-D',$data,'-m','fast','-w','stop')}
 Remove-Item -LiteralPath $work -Recurse -Force
}
