param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$Run,[Parameter(Mandatory)][string]$Output)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$public=Join-Path $PSScriptRoot 'windows_did_diagnostic_public.pem'
if((Get-FileHash -LiteralPath $public -Algorithm SHA256).Hash.ToLowerInvariant() -cne '1b26bb05b12379982b68d00e92178159049af959ba04cc483a06d1b0a49e7307'){throw 'Exact diagnostic public recipient required.'}
if(!(Test-Path -LiteralPath ([IO.Path]::GetDirectoryName($Output)) -PathType Container) -or (Test-Path -LiteralPath $Output)){throw 'New private diagnostic destination required.'}
Add-Type -Path (Join-Path $PSScriptRoot 'windows_did_seal.cs')
$inputStream=[Console]::OpenStandardInput();$memory=[IO.MemoryStream]::new();$buffer=New-Object byte[] 8192
try{
 while(($read=$inputStream.Read($buffer,0,$buffer.Length)) -gt 0){if($memory.Length+$read -gt 2097152){throw 'Bounded diagnostic input required.'};$memory.Write($buffer,0,$read)}
 $raw=$memory.ToArray();$pem=[IO.File]::ReadAllText($public,[Text.Encoding]::UTF8)
 $sealed=[OpenWebPbx.DidDiagnostics.NativeFailureSeal]::Seal($raw,$Source,$Run,'windows_did_initdb_failure',$pem)
 $file=[IO.File]::Open($Output,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);try{$file.Write($sealed,0,$sealed.Length);$file.Flush($true)}finally{$file.Dispose()}
 [ordered]@{schema=1;sealed=$true;stage='windows_did_initdb_failure';bytes=$sealed.Length;sha256=(Get-FileHash -LiteralPath $Output -Algorithm SHA256).Hash.ToLowerInvariant()}|ConvertTo-Json -Compress
}finally{$memory.Dispose();$inputStream.Dispose()}
