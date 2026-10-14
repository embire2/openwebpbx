# Build only. No installation, service control, profile changes or PBX credentials.
[CmdletBinding()]
param(
 [Parameter(Mandatory)][string]$SourceRoot,
 [Parameter(Mandatory)][string]$SourceManifestSha256,
 [Parameter(Mandatory)][string]$DependencyLock,
 [Parameter(Mandatory)][string]$DependencyLockSha256,
 [Parameter(Mandatory)][string]$EngineRoot,
 [Parameter(Mandatory)][string]$ExpectedCoreSha256,
 [Parameter(Mandatory)][string]$BuildRoot,
 [Parameter(Mandatory)][string]$OutputRoot,
 [Parameter(Mandatory)][string]$CodecOutputRoot,
 [string]$PlatformToolset='v143',
 [string]$WindowsSdkVersion='10.0.26100.0',
 [string]$CMakeGenerator='Visual Studio 17 2022'
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
if(!$IsWindows -and $PSVersionTable.PSEdition -eq 'Core'){throw 'Use an x64 Windows developer terminal.'}
if(![Environment]::Is64BitProcess){throw 'An x64 Windows build process is required.'}
function Hash([string]$File){return (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash.ToLowerInvariant()}
function CheckHash([string]$File,[string]$Expected){
 if($Expected -notmatch '^[a-f0-9]{64}$' -or !(Test-Path -LiteralPath $File -PathType Leaf) -or ((Get-Item -LiteralPath $File).Attributes -band [IO.FileAttributes]::ReparsePoint) -or (Hash $File) -ne $Expected){throw 'A required pinned native build input did not verify.'}
}
function Run([string]$Command,[string[]]$Arguments){
 & $Command @Arguments
 if($LASTEXITCODE -ne 0){throw 'A native build command failed; no installed engine was changed.'}
}
function SafeChild([string]$Root,[string]$Relative){
 if($Relative -match '(^[\\/]|:|(^|[\\/])\.\.?([\\/]|$))'){throw 'A native input manifest contains an unsafe path.'}
 $prefix=[IO.Path]::GetFullPath($Root).TrimEnd('\')+'\'
 $file=[IO.Path]::GetFullPath((Join-Path $Root $Relative))
 if(!$file.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'A native input escaped its build directory.'}
 return $file
}
foreach($command in 'MSBuild.exe','cl.exe','cmake.exe','dumpbin.exe'){if(!(Get-Command $command -ErrorAction SilentlyContinue)){throw 'MSVC x64, Windows SDK, MSBuild and CMake are required in the developer terminal.'}}
$SourceRoot=[IO.Path]::GetFullPath($SourceRoot);$EngineRoot=[IO.Path]::GetFullPath($EngineRoot)
$BuildRoot=[IO.Path]::GetFullPath($BuildRoot);$OutputRoot=[IO.Path]::GetFullPath($OutputRoot)
$CodecOutputRoot=[IO.Path]::GetFullPath($CodecOutputRoot)
foreach($directory in $BuildRoot,$OutputRoot,$CodecOutputRoot){
 if((Test-Path -LiteralPath $directory) -or $directory.StartsWith($EngineRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or $directory -eq $EngineRoot){throw 'Use new dedicated build and output directories outside the installed engine.'}
}
$sourceManifest=Join-Path $SourceRoot 'source-manifest.json'
CheckHash $sourceManifest $SourceManifestSha256
CheckHash $DependencyLock $DependencyLockSha256
$source=Get-Content -LiteralPath $sourceManifest -Raw|ConvertFrom-Json
$dependencies=Get-Content -LiteralPath $DependencyLock -Raw|ConvertFrom-Json
$revision='ef32e205295e29f034f1453ad245ba5efb07b94a'
$patchHash='db4fa115b4323eb9c084ad0ffb946488a4a50ba5709886cd3fdc3812c0ad51f6'
$regHash='4dafe992533cbff6e57a5bb6870cb2b410fb552d781e657a55fefd9ad73f241d'
if($source.schema -ne 1 -or $source.upstream_commit -ne $revision -or $source.patch_sha256 -ne $patchHash -or $source.source_reg_sha256 -ne $regHash -or $source.sofia_commit -ne 'ad36ac8f755308e8b87f98a505e83d4e408e5cc3' -or $source.codec_module_commit -ne '4203247dee4719545005ec7ab9ea536fc83df1d8' -or $source.bcg729_debian_version -ne '1.1.1-3+deb13u1'){throw 'The build source pins differ from the reviewed recipe.'}
foreach($entry in $source.files.PSObject.Properties){CheckHash (SafeChild $SourceRoot $entry.Name) $entry.Value}
if($dependencies.schema -ne 1 -or $dependencies.core_sha256 -ne $ExpectedCoreSha256 -or !$dependencies.files){throw 'A reviewed dependency lock for this exact engine core is required.'}
foreach($entry in $dependencies.files.PSObject.Properties){CheckHash (SafeChild $SourceRoot $entry.Name) $entry.Value}
foreach($required in 'freeswitch/src/include/switch_version.h','freeswitch/libs/sofia-sip/win32/gawk.exe','freeswitch/libs/pthreads-w32-2-9-1/pthread.h','freeswitch/libs/openssl-3.4.3/include/openssl/ssl.h'){
 if(!$dependencies.files.$required){throw 'The dependency lock is missing a required generated header or Windows build input.'}
}
$fs=Join-Path $SourceRoot 'freeswitch'
$core=Join-Path $EngineRoot 'FreeSwitch.dll'
CheckHash $core $ExpectedCoreSha256
$coreVersion=(Get-Item -LiteralPath $core).VersionInfo.ProductVersion
if($coreVersion -notmatch '^1\.11\.3([-.+ ]|$)'){throw 'This recipe requires the pinned FreeSWITCH1.11.3 MSI core.'}
$coreLib=Join-Path $fs 'x64\Release\FreeSwitch.lib'
if(!$dependencies.files.'freeswitch/x64/Release/FreeSwitch.lib'){throw 'The dependency lock must include the matching core import library.'}
CheckHash (Join-Path $fs 'src\mod\endpoints\mod_sofia\sofia_reg.c') $regHash
CheckHash (Join-Path $SourceRoot 'mod_bcg729\mod_bcg729.c') 'c2731d5cf1ea076c4d0c274cb7ed85e66a06c1e401ee0e8c065c3bf90eeb8ecc'
New-Item -ItemType Directory $BuildRoot,$OutputRoot,(Join-Path $OutputRoot 'mod'),$CodecOutputRoot,(Join-Path $CodecOutputRoot 'mod')|Out-Null
# The upstream projects otherwise retrieve mutable or unhashed dependencies.
# All inputs must already be in the lock; suppress those download targets.
$blocked=New-Object 'Collections.Generic.HashSet[string]'
foreach($props in Get-ChildItem (Join-Path $fs 'w32') -Filter '*.props'){
 [xml]$xml=Get-Content -LiteralPath $props.FullName
 $ns=New-Object Xml.XmlNamespaceManager($xml.NameTable);$ns.AddNamespace('m','http://schemas.microsoft.com/developer/msbuild/2003')
 foreach($target in $xml.SelectNodes('//m:Target[m:DownloadPackageTask]',$ns)){[void]$blocked.Add([string]$target.Name)}
}
[void]$blocked.Add('7za')
$targets=Join-Path $BuildRoot 'locked-downloads.targets'
$targetXml='<Project xmlns="http://schemas.microsoft.com/developer/msbuild/2003">'
foreach($name in $blocked){$targetXml+='<Target Name="'+[Security.SecurityElement]::Escape($name)+'" />'}
$targetXml+='</Project>'
[IO.File]::WriteAllText($targets,$targetXml,(New-Object Text.UTF8Encoding($false)))
$props=@('/p:Configuration=Release','/p:Platform=x64',('/p:DefaultPlatformToolset='+$PlatformToolset),('/p:WindowsTargetPlatformVersion='+$WindowsSdkVersion),('/p:SolutionDir='+$fs.TrimEnd('\')+'\'),'/p:BuildProjectReferences=false',('/p:ForceImportAfterCppTargets='+$targets))
# Resolve only the MSI-derived core import library. Do not invoke the core
# project, its Git-version generator, or any core build target.
$moduleProject=Join-Path $fs 'src\mod\endpoints\mod_sofia\mod_sofia.2017.vcxproj'
Copy-Item $moduleProject (Join-Path $BuildRoot 'mod_sofia.upstream.vcxproj')
[xml]$moduleXml=Get-Content -LiteralPath $moduleProject
$moduleNs=New-Object Xml.XmlNamespaceManager($moduleXml.NameTable);$moduleNs.AddNamespace('m','http://schemas.microsoft.com/developer/msbuild/2003')
$references=@($moduleXml.SelectNodes('//m:ProjectReference',$moduleNs))
$expectedReferences=@('libs\win32\apr\libapr.2017.vcxproj','libs\win32\pthread\pthread.2017.vcxproj','libs\win32\sofia\libsofia_sip_ua_static.2017.vcxproj','w32\Library\FreeSwitchCore.2017.vcxproj')
if($references.Count -ne $expectedReferences.Count){throw 'The pinned module project references are unexpected.'}
foreach($expected in $expectedReferences){
 $matched=@($references|Where-Object {$_.Include.EndsWith($expected)})
 if($matched.Count -ne 1){throw 'The pinned module project reference differs from its reviewed dependency.'}
 [void]$matched[0].ParentNode.RemoveChild($matched[0])
}
$group=$moduleXml.CreateElement('ItemDefinitionGroup',$moduleXml.DocumentElement.NamespaceURI)
$link=$moduleXml.CreateElement('Link',$moduleXml.DocumentElement.NamespaceURI)
$additional=$moduleXml.CreateElement('AdditionalDependencies',$moduleXml.DocumentElement.NamespaceURI)
$privateLibs=@('x64\Release\libapr.lib','libs\win32\pthread\x64\Release\pthread.lib','libs\win32\sofia\x64\Release\libsofia_sip_ua_static.lib')|ForEach-Object {Join-Path $fs $_}
$additional.InnerText=(@($coreLib)+$privateLibs -join ';')+';%(AdditionalDependencies)'
[void]$link.AppendChild($additional);[void]$group.AppendChild($link)
$lastImport=$moduleXml.SelectSingleNode('//m:Import[contains(@Project,"Microsoft.Cpp.targets")]',$moduleNs)
if(!$lastImport){throw 'The pinned module target import is missing.'}
[void]$moduleXml.DocumentElement.InsertBefore($group,$lastImport)
$moduleXml.Save($moduleProject)
# Build the pinned private libraries without building/replacing FreeSwitch.dll.
foreach($project in 'libs\win32\apr\libapr.2017.vcxproj','libs\win32\pthread\pthread.2017.vcxproj','libs\win32\sofia\libsofia_sip_ua_static.2017.vcxproj'){
 Run 'MSBuild.exe' (@((Join-Path $fs $project),'/t:Build','/m:1','/nologo')+$props)
}
foreach($library in $privateLibs){if(!(Test-Path -LiteralPath $library -PathType Leaf)){throw 'A private pinned registrar dependency import/static library was not built.'}}
$moduleOutput=Join-Path $BuildRoot 'registrar-output'
Run 'MSBuild.exe' (@($moduleProject,'/t:Build','/m:1','/nologo',('/p:OutDir='+$moduleOutput.TrimEnd('\')+'\'),('/p:IntDir='+$BuildRoot.TrimEnd('\')+'\sofia-objects\'))+$props)
Copy-Item (Join-Path $moduleOutput 'mod_sofia.dll') (Join-Path $OutputRoot 'mod\mod_sofia.dll')
$bcgBuild=Join-Path $BuildRoot 'bcg729'
$bcgInstall=Join-Path $BuildRoot 'bcg729-install'
Run 'cmake.exe' @('-S',(Join-Path $SourceRoot 'bcg729'),'-B',$bcgBuild,'-G',$CMakeGenerator,'-A','x64',('-DCMAKE_INSTALL_PREFIX='+$bcgInstall),'-DBUILD_SHARED_LIBS=ON','-DENABLE_UNIT_TESTS=OFF','-DENABLE_STRICT=ON')
Run 'cmake.exe' @('--build',$bcgBuild,'--config','Release','--parallel','2')
Run 'cmake.exe' @('--install',$bcgBuild,'--config','Release')
$codecSource=Join-Path $SourceRoot 'mod_bcg729\mod_bcg729.c'
$bcgLib=Join-Path $bcgInstall 'lib\libbcg729.lib'
if(!(Test-Path -LiteralPath $bcgLib)){throw 'The native shared bcg729 import library is missing.'}
$compiler=@('/nologo','/O2','/MD','/W4','/std:c11','/DWIN32','/D_WINDOWS','/D_USRDLL','/DMOD_EXPORTS',('/I'+(Join-Path $fs 'src\include')),('/I'+(Join-Path $bcgInstall 'include')))
Push-Location $BuildRoot
try {
 Run 'cl.exe' ($compiler+@('/LD',$codecSource,('/Fe:'+(Join-Path $CodecOutputRoot 'mod\mod_bcg729.dll')),'/link',$coreLib,$bcgLib,'/MACHINE:X64','/DYNAMICBASE','/NXCOMPAT'))
 # The exact callback test exercises encode/decode/VAD/PLC and pre-write bounds.
 $test=Join-Path $BuildRoot 'codec-check.exe'
 $definition='/DOPENWEB_BCG729_SOURCE="'+$codecSource.Replace('\','/')+'"'
 Run 'cl.exe' ($compiler+@('/UNDEBUG',$definition,(Join-Path $SourceRoot 'codec-check.c'),('/Fe:'+$test),'/link',$coreLib,$bcgLib,'/MACHINE:X64'))
 Copy-Item (Join-Path $bcgInstall 'bin\libbcg729.dll') (Join-Path $CodecOutputRoot 'libbcg729.dll')
 $nativePriorPath=$env:PATH
 try{$env:PATH=$CodecOutputRoot+';'+$EngineRoot+';'+$env:PATH;Run $test @()}finally{$env:PATH=$nativePriorPath}
} finally {Pop-Location}
$hashes=@{};$runtimeDependencies=@{};$toolHashes=@{}
foreach($command in 'MSBuild.exe','cl.exe','cmake.exe','dumpbin.exe'){$toolHashes[$command]=Hash (Get-Command $command).Source}
foreach($name in @('mod/mod_sofia.dll')){
 $file=SafeChild $OutputRoot $name
 if(!(Test-Path -LiteralPath $file)){throw 'A native output is missing; stock modules are not a substitute.'}
 $headers=& dumpbin.exe /headers $file
 if($LASTEXITCODE -or !($headers -match '8664 machine \(x64\)')){throw 'A native output is not a valid x64 DLL.'}
 $hashes[$name]=Hash $file
 $imports=& dumpbin.exe /imports $file
 if($LASTEXITCODE){throw 'Native dependency inspection failed.'}
 $imports|Out-File (Join-Path $BuildRoot ((Split-Path $file -Leaf)+'.imports.txt')) -Encoding utf8
 foreach($line in $imports){
  if($line.Trim() -match '^[A-Za-z0-9_.-]+\.dll$'){
   $library=$line.Trim()
   $installed=Join-Path $EngineRoot $library
   if(Test-Path -LiteralPath $installed -PathType Leaf){$runtimeDependencies[$library]=Hash $installed}
   elseif(!(Test-Path -LiteralPath (Join-Path $OutputRoot $library) -PathType Leaf) -and !(Test-Path -LiteralPath (Join-Path "$env:SystemRoot\System32" $library) -PathType Leaf) -and $library -notmatch '^(api-ms-win-|ext-ms-win-)'){
    throw 'A native output depends on an unresolved DLL; inspect the private PE import report.'
   }
  }
 }
}
$manifest=@{schema=1;upstream_commit=$revision;patch_sha256=$patchHash;source_reg_sha256=$regHash;core_version='1.11.3';core_sha256=$ExpectedCoreSha256;source_msi_sha256='f5649e33ad46be2ebdb1d98019bd149c86519f0dca9f47fb881207045203a34d';files=$hashes;runtime_dependencies=$runtimeDependencies;source_manifest_sha256=$SourceManifestSha256;dependency_lock_sha256=$DependencyLockSha256;module_project_sha256=(Hash $moduleProject);toolset=$PlatformToolset;windows_sdk=$WindowsSdkVersion;build_tool_sha256=$toolHashes;native_runtime_qualified=$false;codec_not_in_release=$true}
[IO.File]::WriteAllText((Join-Path $OutputRoot 'native-manifest.json'),($manifest|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
$codec=@{schema=1;codec_distribution_status='local-source-build-only';callback_test='passed';files=@{'mod/mod_bcg729.dll'=(Hash (Join-Path $CodecOutputRoot 'mod\mod_bcg729.dll'));'libbcg729.dll'=(Hash (Join-Path $CodecOutputRoot 'libbcg729.dll'))};native_rtp_qualified=$false}
[IO.File]::WriteAllText((Join-Path $CodecOutputRoot 'local-codec-manifest.json'),($codec|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
Write-Host 'Native modules built from pinned sources. Windows SIP/media/ABI qualification and codec binary-distribution review remain required.'
