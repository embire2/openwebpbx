#Requires -RunAsAdministrator
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
# Fixed, protected installation metadata; no archive, URL or command supplied by the desktop user.
$path=Join-Path $env:ProgramData 'OpenWebPBX\updater-install.json'
$file=Get-Item -LiteralPath $path -Force
if($file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $file.Length -gt 65536){throw 'Updater installation metadata is invalid.'}
$state=[IO.File]::ReadAllText($path)|ConvertFrom-Json
if($state.Version -isnot [string] -or $state.Version -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'){throw 'Updater installation version is invalid.'}
$expected='C:\OpenWebPBX\updater\slots\'+$state.Version+'\OpenWebPbx.Updater.exe'
if($state.Executable -cne $expected -or !(Test-Path -LiteralPath $expected -PathType Leaf)){throw 'The installed updater executable is unavailable.'}
& $expected --request-install
if($LASTEXITCODE -ne 0){throw 'The update request was not accepted. Check the Updates page.'}
