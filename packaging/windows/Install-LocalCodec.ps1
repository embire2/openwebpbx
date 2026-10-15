#Requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PackageRoot,[string]$EngineRoot='C:\Program Files\FreeSWITCH',[string]$StateRoot=(Join-Path $env:ProgramData 'OpenWebPBX'),[switch]$Check)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
. "$PSScriptRoot\Write-PrivateState.ps1"
$recipeRoot=Join-Path $PackageRoot 'codecs\bcg729'
$recipe=Get-Content (Join-Path $recipeRoot 'windows-recipe.json') -Raw | ConvertFrom-Json
if($recipe.schema -ne 1 -or $recipe.distribution -ne 'local-source-build-only' -or
 $recipe.core_sha256 -ne '8553d88348093d5067d93369aa9793b38fe9e3c9c9ca0c38216791700bd7f726' -or
 $recipe.apr_sha256 -ne 'bb3adfa1b6b7e3f699b037a0429fca49482e5a9e829ad1f01cc31d447a74a56d'){throw 'The supported Windows source codec recipe is missing.'}
function Verified([string]$Path,[string]$Hash){
 if($Hash -notmatch '^[a-f0-9]{64}$' -or !(Test-Path -LiteralPath $Path -PathType Leaf) -or ((Get-Item -LiteralPath $Path).Attributes -band [IO.FileAttributes]::ReparsePoint) -or (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Hash){throw 'A Windows source codec input failed verification.'}
}
Verified "$EngineRoot\FreeSwitch.dll" $recipe.core_sha256
Verified "$EngineRoot\libapr.dll" $recipe.apr_sha256
Verified "$PackageRoot\codec-source\source-manifest.json" $recipe.source_manifest_sha256
Verified "$recipeRoot\core-exports.py" $recipe.core_export_helper_sha256
Verified "$recipeRoot\build-windows-local.py" $recipe.build_helper_sha256
Verified "$recipeRoot\windows-compiler.json" $recipe.compiler_pin_sha256
Verified "$recipeRoot\windows-heap-check.c" $recipe.heap_check_sha256
if($Check){Write-Host 'The local Windows source codec recipe matches the installed call engine.';return}
if((Get-Service FreeSWITCH).Status -ne 'Stopped'){throw 'Stop the call engine before building its local audio codec.'}
$python=Join-Path $PackageRoot 'backup-runtime\python.exe'
$runtime=Get-Content "$PackageRoot\backup-runtime\runtime-manifest.json" -Raw|ConvertFrom-Json
if($runtime.schema -ne 1 -or !$runtime.files.'python.exe'){throw 'The isolated build interpreter is missing.'}
foreach($entry in $runtime.files.PSObject.Properties){
 if($entry.Name -match '(^/|\\|:|(^|/)\.\.?(/|$))'){throw 'The isolated interpreter inventory has an invalid path.'}
 Verified (Join-Path "$PackageRoot\backup-runtime" $entry.Name) $entry.Value
}
$oldPath=Join-Path $StateRoot 'local-codec.json'
if(Test-Path -LiteralPath $oldPath){
 $old=Get-Content -LiteralPath $oldPath -Raw|ConvertFrom-Json
 $same=$old.schema -eq 1 -and $old.source_manifest_sha256 -eq $recipe.source_manifest_sha256 -and $old.core_export_helper_sha256 -eq $recipe.core_export_helper_sha256 -and $old.build_helper_sha256 -eq $recipe.build_helper_sha256 -and $old.compiler_pin_sha256 -eq $recipe.compiler_pin_sha256 -and $old.heap_check_sha256 -eq $recipe.heap_check_sha256 -and $old.core_sha256 -eq $recipe.core_sha256 -and $old.apr_sha256 -eq $recipe.apr_sha256 -and $old.callbacks -eq 'passed' -and $old.data_imports_and_heap_ownership -eq 'passed'
 if($same){try{foreach($name in 'mod/mod_bcg729.dll','libbcg729.dll'){Verified (Join-Path $EngineRoot $name) $old.files.$name};Write-Host 'The verified local audio codec is already installed.';return}catch{}}
}
$work=Join-Path $StateRoot ('codec-build\'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $work|Out-Null
& icacls.exe $work /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F'|Out-Null
if($LASTEXITCODE){throw 'The local audio build directory could not be protected.'}
$output=Join-Path $work 'output'
Write-Host 'Preparing the local audio codec. The first installation downloads its verified compiler.'
& $python -I -B "$recipeRoot\build-windows-local.py" --source "$PackageRoot\codec-source" --source-manifest-sha256 $recipe.source_manifest_sha256 --engine-root $EngineRoot --core-sha256 $recipe.core_sha256 --apr-sha256 $recipe.apr_sha256 --core-export-helper "$recipeRoot\core-exports.py" --build "$work\build" --output $output --compiler-cache "$StateRoot\codec-compiler-cache"
if($LASTEXITCODE){throw 'The local audio codec did not build or pass its native ownership tests. Keep calling stopped.'}
$built=Get-Content "$output\local-codec-manifest.json" -Raw|ConvertFrom-Json
if($built.schema -ne 1 -or $built.codec_distribution_status -ne 'local-source-build-only' -or $built.callbacks -ne 'passed' -or $built.data_imports_and_heap_ownership -ne 'passed' -or $built.source_manifest_sha256 -ne $recipe.source_manifest_sha256 -or $built.core_sha256 -ne $recipe.core_sha256 -or $built.apr_sha256 -ne $recipe.apr_sha256){throw 'The local codec proof is incomplete.'}
if((Get-Service FreeSWITCH).Status -ne 'Stopped'){throw 'The call engine started during the local codec build. No codec was installed.'}
foreach($name in 'mod/mod_bcg729.dll','libbcg729.dll'){
 Verified (Join-Path $output $name) $built.files.$name
 Copy-Item -LiteralPath (Join-Path $output $name) -Destination (Join-Path $EngineRoot $name) -Force
 Verified (Join-Path $EngineRoot $name) $built.files.$name
}
foreach($name in 'build_helper_sha256','compiler_pin_sha256','heap_check_sha256'){$built|Add-Member -NotePropertyName $name -NotePropertyValue $recipe.$name -Force}
Write-OpenWebPrivateState -Path $oldPath -Value $built
Remove-Item -LiteralPath $work -Recurse -Force
Write-Host 'The local audio codec passed its native callback and memory ownership checks.'
