# Read-only bootstrap for the complete package; no installed PBX or system Python.
[CmdletBinding()]
param([string]$PackageRoot=$PSScriptRoot)
$ErrorActionPreference='Stop'
$directory=Get-Item -LiteralPath $PackageRoot -Force -ErrorAction Stop
if(!$directory.PSIsContainer){throw 'Extract the complete Windows installer into an ordinary folder.'}
$ancestor=$directory
while($ancestor){
 if($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'The installation path contains a link or junction.'}
 $parent=[IO.Path]::GetDirectoryName($ancestor.FullName)
 if(!$parent -or $parent -eq $ancestor.FullName){break}
 $ancestor=Get-Item -LiteralPath $parent -Force -ErrorAction Stop
}
$manifestPath=Join-Path $directory.FullName 'release-manifest.json'
$manifestItem=Get-Item -LiteralPath $manifestPath -Force -ErrorAction Stop
if($manifestItem.PSIsContainer -or ($manifestItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $manifestItem.Length -gt 8388608){throw 'The complete installation manifest is missing or invalid.'}
$manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8|ConvertFrom-Json -ErrorAction Stop
if($manifest.version -isnot [string] -or $manifest.version -cnotmatch '^\d+\.\d+\.\d+$' -or !$manifest.files){throw 'The complete installation manifest is invalid.'}
$hashes=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach($entry in $manifest.files.PSObject.Properties){
 if($entry.Name -cmatch '[\\:\x00-\x1f<>"|?*]' -or $entry.Name.StartsWith('/') -or $entry.Name -match '(^|/)(\.{1,2}|[^/]*[ .])(/|$)' -or $entry.Value -isnot [string] -or $entry.Value -cnotmatch '^[a-f0-9]{64}$'){throw 'The installation manifest contains an invalid path or checksum.'}
 $hashes.Add($entry.Name,$entry.Value)
}
# Verify the included interpreter and its entire isolated standard-library tree
# before running the strict JSON/full-package validator. No product or installed
# helper is imported and -I -B prevents environment imports and bytecode writes.
$runtime=Join-Path $directory.FullName 'backup-runtime'
$pending=[Collections.Generic.Stack[string]]::new();$pending.Push($runtime)
$bootstrap=@('Windows-InstallationCheck.py','release_contract.py')
while($pending.Count){
 $item=Get-Item -LiteralPath $pending.Pop() -Force -ErrorAction Stop
 if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'The included installation interpreter contains a link.'}
 if($item.PSIsContainer){foreach($child in Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction Stop){$pending.Push($child.FullName)}}
 else{$bootstrap+=$item.FullName.Substring($directory.FullName.TrimEnd('\').Length+1).Replace('\','/')}
}
foreach($name in $bootstrap){
 $path=Join-Path $directory.FullName $name
 $item=Get-Item -LiteralPath $path -Force -ErrorAction Stop
 if($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or !$hashes.ContainsKey($name) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $hashes[$name]){throw 'The included installation checker failed integrity verification.'}
}
if(!$hashes.ContainsKey('backup-runtime/python.exe')){throw 'The full installer must include its isolated interpreter.'}
& (Join-Path $runtime 'python.exe') -I -B (Join-Path $directory.FullName 'Windows-InstallationCheck.py') $directory.FullName
if($LASTEXITCODE -ne 0){throw 'The complete installation package did not pass its read-only check.'}
