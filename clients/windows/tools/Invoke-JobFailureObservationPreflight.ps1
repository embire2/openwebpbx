# Prepared only: disposable hosted Windows, source-pinned Python,2-minute CI step.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PythonExecutable)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if(!$IsWindows -or $env:GITHUB_ACTIONS-cne 'true' -or $env:RUNNER_ENVIRONMENT-cne 'github-hosted' -or $env:GITHUB_REPOSITORY-cne 'embire2/openwebpbx'){throw 'Disposable hosted preflight required.'}
if((Test-Path 'C:\OpenWebPBX')-or(Test-Path(Join-Path $env:ProgramData 'OpenWebPBX'))){throw 'Existing PBX is outside the preflight.'}
$tools=Join-Path $env:GITHUB_WORKSPACE 'clients/windows/tools'
. (Join-Path $tools 'WavProducerPrimitives.ps1')
if(![IO.Path]::IsPathFullyQualified($PythonExecutable)-or[IO.Path]::GetExtension($PythonExecutable)-ine '.exe'-or$PythonExecutable-match '\\WindowsApps\\|\\py\.exe$'){throw 'Exact setup-python output required.'}
$item=Get-Item -LiteralPath $PythonExecutable -Force
if($item.PSIsContainer-or($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-or$item.Length-le 0){throw 'Ordinary explicit interpreter required.'}
$root=Join-Path $env:RUNNER_TEMP ('phone-wav-observer-preflight-'+[Guid]::NewGuid().ToString('N'))
PrivateDirectory $root
if(!(Test-Path -LiteralPath $env:GITHUB_OUTPUT -PathType Leaf)){throw 'Exact hosted step-output file required.'}
[IO.File]::AppendAllText($env:GITHUB_OUTPUT,('evidence_root='+$root+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
$baseline=SystemSnapshot
[IO.File]::WriteAllText((Join-Path $root 'system-before.json'),$baseline,[Text.UTF8Encoding]::new($false))
$failure=$null
try{
 & $PythonExecutable -I -B (Join-Path $env:GITHUB_WORKSPACE 'clients/windows/tests/wav-producer/JobFailureObservationPreflight.py') --root $root
 if($LASTEXITCODE-ne 0){throw 'Owned observation controls failed.'}
} catch {$failure=$_} finally{
 $after=SystemSnapshot
 [IO.File]::WriteAllText((Join-Path $root 'system-after.json'),$after,[Text.UTF8Encoding]::new($false))
 $preserved=$after-ceq $baseline
 [IO.File]::WriteAllText((Join-Path $root 'preservation.safe.json'),([ordered]@{schema=1;system_preserved=$preserved;calling_SDK_WAV_Store_qualified=$false}|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
}
if($failure){throw $failure}
if(!$preserved){throw 'Original complete service/certificate/firewall preservation refused.'}
