param([Parameter(Mandatory)][string]$StateRoot)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
if($PSVersionTable.PSEdition -cne 'Core' -or [Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'Native Windows PowerShell7 is required for the exact C# source.'}
$full=[IO.Path]::GetFullPath($StateRoot);$fixture=[IO.Path]::GetDirectoryName($full);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
if([IO.Path]::GetFileName($full) -cne 'state' -or [IO.Path]::GetDirectoryName($fixture).TrimEnd('\') -ine $temp -or [IO.Path]::GetFileName($fixture) -cnotmatch '^OpenWebPBX-hash-sharing-[a-f0-9]{32}$'){throw 'Only the newly owned temporary fixture is allowed.'}
$pins=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'source-pins.json') -Raw|ConvertFrom-Json
$source=Join-Path $PSScriptRoot 'WindowsCallRecordLease.cs'
if((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -cne $pins.files.'WindowsCallRecordLease.cs'.sha256){throw 'The exact C# lease source changed.'}
# The same implicit using/nullable context as the existing native component;
# the actual namespace, class and lease body are never rewritten.
Add-Type -TypeDefinition ("#nullable enable`nusing System;`nusing System.IO;`n"+[IO.File]::ReadAllText($source)) -ErrorAction Stop
$lease=[OpenWebPbx.Server.WindowsCallRecordLease]::TryAcquire($full)
if($null -eq $lease){throw 'The actual C# read lease was not acquired.'}
try{[Console]::Out.WriteLine('{"state":"read_lease_held"}');$line=[Console]::In.ReadLine();if($null -ne $line -and $line -cne 'release'){throw 'Unexpected owned fixture command.'}}finally{$lease.Dispose()}
