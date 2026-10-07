param([switch]$StartManager)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
try {
 $runtime=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64' -ErrorAction SilentlyContinue
 if (!$runtime -or !$runtime.Installed -or [Version]$runtime.Version.TrimStart('v') -lt [Version]'14.50.0.0') {
  Write-Host 'Installing the required Microsoft runtime...'
  $directory=Join-Path $env:TEMP ('OpenWebPBX-runtime-'+[Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory $directory|Out-Null
  try {
   $file=Join-Path $directory 'vc_redist.x64.exe'
   Invoke-WebRequest 'https://aka.ms/vc14/vc_redist.x64.exe' -OutFile $file -UseBasicParsing
   $signature=Get-AuthenticodeSignature $file
   if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)') {throw 'Microsoft runtime signature verification failed.'}
   $process=Start-Process $file -ArgumentList '/install','/passive','/norestart' -Verb RunAs -Wait -PassThru
   if ($process.ExitCode -notin 0,1638,3010) {throw 'The Microsoft runtime installation did not complete.'}
   if ($process.ExitCode -eq 3010) {throw 'Restart Windows, then open OpenWeb PBX again to finish setup.'}
  } finally {Remove-Item $directory -Recurse -Force -ErrorAction SilentlyContinue}
 }
 if ($StartManager) {Start-Process "$PSScriptRoot\desktop\OpenWebPbx.Desktop.exe" -WorkingDirectory "$PSScriptRoot\desktop"}
} catch {Write-Error -Message $_.Exception.Message -ErrorAction Continue;exit 1}
exit 0
