#Requires -Version 5.1
# Read-only native IIS configuration diagnostics for the disposable QA server.
param([Parameter(Mandatory)][string]$ReportPath)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:RUNNER_OS -ne 'Windows' -or $env:GITHUB_REPOSITORY -ne 'embire2/openwebpbx'){throw 'Disposable hosted IIS diagnostics required.'}
$full=[IO.Path]::GetFullPath($ReportPath);$parent=[IO.Path]::GetDirectoryName($full)
if([IO.Path]::GetFileName($full) -cne 'iis-native-health.json' -or [IO.Path]::GetFileName($parent) -cnotmatch '^openwebpbx-suite-[a-f0-9]{32}$' -or ![IO.Path]::GetDirectoryName($parent).Equals([IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase)){throw 'An exact owned private report path is required.'}
$result=[ordered]@{schema=1;state='error';stage='assembly';error_type='unknown';hresult=0};$manager=$null
try{
 Add-Type -Path "$env:windir\System32\inetsrv\Microsoft.Web.Administration.dll"
 $result.stage='site';$manager=[Microsoft.Web.Administration.ServerManager]::new();$site=$manager.Sites['OpenWebPBX']
 if(!$site -or [IO.Path]::GetFullPath($site.Applications['/'].VirtualDirectories['/'].PhysicalPath).TrimEnd('\') -ine 'C:\OpenWebPBX\web'){throw 'The owned site is required.'}
 $configuration=$manager.GetWebConfiguration('OpenWebPBX')
 foreach($entry in @(@('handlers','system.webServer/handlers'),@('rewrite','system.webServer/rewrite/rules'),@('websocket','system.webServer/webSocket'),@('default_document','system.webServer/defaultDocument'))){
  $result.stage=$entry[0];$section=$configuration.GetSection($entry[1]);$null=$section.Attributes.Count
  if($entry[0] -in 'handlers','rewrite'){$null=$section.GetCollection().Count}
 }
 $result.state='read';$result.stage='complete';$result.error_type='none'
}catch{
 $types=@('RuntimeException','MethodInvocationException','InvalidOperationException','COMException','FileLoadException','FileNotFoundException','DirectoryNotFoundException','UnauthorizedAccessException','ConfigurationErrorsException','ArgumentException','Exception')
 $nativeException=$_.Exception
 for($depth=0;$nativeException.InnerException -and $depth -lt 4;$depth++){$nativeException=$nativeException.InnerException}
 $name=$nativeException.GetType().Name;$result.error_type=if($name -cin $types){$name}else{'unknown'};$result.hresult=[int]$nativeException.HResult
}finally{if($manager){$manager.Dispose()}}
[IO.File]::WriteAllText($full,($result|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
