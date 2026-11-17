[CmdletBinding()]
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
# Compile the exact IIS module with Windows .NET Framework/System.Web, without
# installing it, reading a body, modifying IIS or touching the PBX database.
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'Run the actual System.Web controls in Windows PowerShell 5.1.'}
if($PSVersionTable.PSEdition -eq 'Core'){throw 'Run this fixture with Windows PowerShell 5.1.'}
$source=Join-Path $SourceRoot 'packaging/windows/UploadAdmission.cs'
Add-Type -Path $source -ReferencedAssemblies 'System.dll','System.Web.dll'
$type=[OpenWebPbx.Windows.UploadAdmission]
$method=$type.GetMethod('IsBackupImportAlias',[Reflection.BindingFlags]'NonPublic,Static')
if(!$method){throw 'The actual module query classifier is missing.'}
$classifier=[Delegate]::CreateDelegate([Func[System.Web.HttpRequest,bool]],$method)
$checks=0
function Check([bool]$Allowed,[string]$Message){if(!$Allowed){throw $Message};$script:checks++}
$uuid='01234567-0123-0123-0123-012345678901'
$imports=@('/instance/backups/import',('/tenants/'+$uuid+'/backups/import'))
foreach($path in '/api/v2','/api/v2/','/api/v2/index.php','/API/V2/INDEX.PHP'){
 foreach($route in $imports){
  foreach($query in @(
   ('route='+$route),('route='+[Uri]::EscapeDataString($route)),
   ('route=/pbx/example/actions/audio-upload&route='+[Uri]::EscapeDataString($route)),
   ('route='+[Uri]::EscapeDataString($route)+'&route=/setup/import-review'),
   ('rout%65='+[Uri]::EscapeDataString($route))
  )){
   foreach($mime in 'application/octet-stream','application/octet-stream; charset=binary','multipart/form-data; boundary=owned-fixture','application/json',''){
    $request=New-Object System.Web.HttpRequest('',('https://owned.example'+$path+'?'+$query),$query)
    $request.ContentType=$mime
    Check ($classifier.Invoke($request)) ('Backup alias must refuse independently of MIME: '+$path)
   }
  }
 }
}
foreach($case in @(
 @{path='/api/v2/index.php';query='route=/pbx/example/actions/audio-upload'},
 @{path='/api/v2/';query='route=/setup/import-review'},
 @{path='/api/v2/index.php';query='route=/instance/backups'},
 @{path='/api/v2/index.php';query='route=/instance/backups/imported'},
 @{path='/api/v2/index.php';query='route=/instance/backups/import/'},
 @{path='/api/v2/index.php';query='route=%252Finstance%252Fbackups%252Fimport'},
 @{path='/api/v2/index.php';query='route%5B%5D=/instance/backups/import'},
 @{path='/api/v2/index.php';query='x=/instance/backups/import'},
 @{path='/api/v2/index.php';query=''},
 @{path='/api/v2/instance/backups/import';query='route=/instance/backups/import'},
 @{path='/api/v2/upload.php';query='route=/instance/backups/import'},
 @{path='/app/switch/resources/xml_handler.php';query='route=/instance/backups/import'},
 @{path='/app/pbx_setup/import.php';query='route=/instance/backups/import'}
)){
 $request=New-Object System.Web.HttpRequest('',('https://owned.example'+$case.path+'?'+$case.query),$case.query)
 $request.ContentType='multipart/form-data; boundary=ordinary-form'
 Check (-not $classifier.Invoke($request)) ('Ordinary/canonical route must keep its existing path: '+$case.path)
}
Write-Host "Actual Windows System.Web upload alias controls: $checks passed. No request body, IIS or database access."
