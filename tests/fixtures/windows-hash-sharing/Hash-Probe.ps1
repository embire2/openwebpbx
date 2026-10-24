param([Parameter(Mandatory)][string]$Fixture,[Parameter(Mandatory)][ValidateSet('upgrade','worker')][string]$Target)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
if($PSVersionTable.PSEdition -cne 'Core' -or [Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'Native Windows PowerShell7 is required.'}
$full=[IO.Path]::GetFullPath($Fixture);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
if([IO.Path]::GetDirectoryName($full).TrimEnd('\') -ine $temp -or [IO.Path]::GetFileName($full) -cnotmatch '^OpenWebPBX-hash-sharing-[a-f0-9]{32}$'){throw 'Only the newly owned temporary fixture is allowed.'}
$pins=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'source-pins.json') -Raw|ConvertFrom-Json
$source=Join-Path $PSScriptRoot 'windows-upgrade-acceptance.ps1'
if((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -cne $pins.files.'windows-upgrade-acceptance.ps1'.sha256){throw 'The exact original Hash source changed.'}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
$nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Hash'},$true))
if($errors.Count -or $nodes.Count -ne 1){throw 'One exact original Hash function is required.'}
. ([scriptblock]::Create($nodes[0].Extent.Text))
$path=Join-Path $full $(if($Target -ceq 'upgrade'){'state/upgrade.lock'}else{'state/automatic-backups/worker.lock'})
$candidate=$path
while($candidate){if((Get-Item -LiteralPath $candidate -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'The owned fixture contains a link.'};if($candidate -ieq $temp){break};$candidate=Split-Path $candidate -Parent}
function HashExceptionFields([Exception]$Exception){
 $unavailable=@{error_type='unavailable';hresult=$null;win32_code=$null}
 if($null -eq $Exception){return $unavailable}
 $actual=$Exception
 for($depth=0;$depth -lt 7 -and $actual.InnerException;$depth++){$actual=$actual.InnerException}
 if($actual.InnerException){return $unavailable}
 $name=$actual.GetType().Name
 if($name -cnotin @('IOException','UnauthorizedAccessException','FileNotFoundException','DirectoryNotFoundException','Win32Exception')){$name='other'}
 $hr=[int]$actual.HResult;$code=$null
 if($actual -is [ComponentModel.Win32Exception]){
  if($actual.NativeErrorCode -ge 0 -and $actual.NativeErrorCode -le 65535){$code=[int]$actual.NativeErrorCode}
 }elseif(([int64]$hr -band 4294901760) -eq 2147942400){$code=[int]([int64]$hr -band 65535)}
 return @{error_type=$name;hresult=$hr;win32_code=$code}
}
try{
 $digest=Hash $path
 [Console]::Out.WriteLine((@{schema=1;state='hashed';sha256=$digest}|ConvertTo-Json -Compress))
}catch{
 $failure=HashExceptionFields $_.Exception
 [Console]::Out.WriteLine(((@{schema=1;state='refused'}+$failure)|ConvertTo-Json -Compress))
}
