# SPDX-License-Identifier: AGPL-3.0-or-later
# QA-only native fixture metadata; no compiler execution or persistent settings.
Add-Type -TypeDefinition @'
using System;using System.IO;using System.Text;using System.Collections.Generic;
public sealed class OpenWebWavPeInfo {public int Machine;public string[] Imports=Array.Empty<string>();}
public static class OpenWebWavPe {
 static void Need(bool value){if(!value)throw new InvalidDataException("Bounded AMD64 PE structure required.");}
 public static OpenWebWavPeInfo Read(string path,bool imports){
  using var f=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read);using var r=new BinaryReader(f,Encoding.ASCII,true);
  Need(f.Length>=64);Need(r.ReadUInt16()==0x5a4d);f.Position=60;uint pe=r.ReadUInt32();Need(pe>=64&&pe<=1048576&&(long)pe+24<=f.Length);
  f.Position=pe;Need(r.ReadUInt32()==0x4550);int machine=r.ReadUInt16(),count=r.ReadUInt16();Need(machine==0x8664&&count>0&&count<=96);f.Position=pe+20;int optional=r.ReadUInt16();r.ReadUInt16();long start=pe+24;Need(optional>=240&&optional<=4096&&start+optional+40L*count<=f.Length);Need(r.ReadUInt16()==0x20b);
  var result=new OpenWebWavPeInfo{Machine=machine};if(!imports)return result;
  f.Position=start+108;uint directories=r.ReadUInt32();Need(directories>=14);f.Position=start+120;uint importRva=r.ReadUInt32(),importSize=r.ReadUInt32();f.Position=start+112+13*8;Need(r.ReadUInt32()==0&&r.ReadUInt32()==0);
  var sections=new List<(uint va,uint size,uint raw,uint pointer)>();f.Position=start+optional;
  for(int i=0;i<count;i++){long row=f.Position;f.Position=row+8;uint size=r.ReadUInt32(),va=r.ReadUInt32(),raw=r.ReadUInt32(),pointer=r.ReadUInt32();Need((long)pointer+raw<=f.Length);sections.Add((va,size,raw,pointer));f.Position=row+40;}
  long Offset(uint address,int bytes){foreach(var s in sections){if(address>=s.va&&(ulong)address+((uint)bytes)<=(ulong)s.va+s.raw){long pos=(long)s.pointer+address-s.va;Need(pos>=0&&pos+bytes<=f.Length);return pos;}}throw new InvalidDataException("Import RVA is outside file-backed sections.");}
  var names=new SortedSet<string>(StringComparer.OrdinalIgnoreCase);if(importRva==0){Need(importSize==0);return result;}Need(importSize>=20&&importSize<=1048576);bool end=false;
  for(int i=0;i<256;i++){Need((long)(i+1)*20<=importSize);f.Position=Offset(checked(importRva+(uint)i*20),20);uint a=r.ReadUInt32(),b=r.ReadUInt32(),c=r.ReadUInt32(),name=r.ReadUInt32(),d=r.ReadUInt32();if((a|b|c|name|d)==0){end=true;break;}Need(name!=0);long off=Offset(name,1);f.Position=off;var text=new StringBuilder();bool zero=false;for(int j=0;j<260;j++){f.Position=Offset(checked(name+(uint)j),1);byte value=r.ReadByte();if(value==0){zero=true;break;}Need((value>=65&&value<=90)||(value>=97&&value<=122)||(value>=48&&value<=57)||value==45||value==46||value==95);text.Append((char)value);}Need(zero&&text.Length>4&&text.ToString().EndsWith(".dll",StringComparison.OrdinalIgnoreCase));Need(names.Add(text.ToString().ToLowerInvariant()));}
  Need(end);result.Imports=new List<string>(names).ToArray();return result;
 }
}
'@
function WavOrdinary([string]$Path,[switch]$Directory){
 $item=Get-Item -LiteralPath $Path -Force
 if(($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-or($Directory-and!$item.PSIsContainer)-or(!$Directory-and($item.PSIsContainer-or$item.Length-le 0))){throw 'Ordinary existing toolchain path required.'}
 $parent=if($item.PSIsContainer){$item.Parent}else{$item.Directory};while($null-ne $parent){if($parent.Attributes-band[IO.FileAttributes]::ReparsePoint){throw 'Ordinary toolchain ancestry required.'};$parent=$parent.Parent}
 return [string]$item.FullName
}
function WavTool([string]$Path,[string]$Leaf){
 $full=WavOrdinary $Path
 if([IO.Path]::GetFileName($full)-ine $Leaf-or[IO.Path]::GetExtension($full)-ine '.exe'){throw 'Exact real tool basename required.'}
 $pe=[OpenWebWavPe]::Read($full,$false);$item=Get-Item -LiteralPath $full -Force;$meta=[Diagnostics.FileVersionInfo]::GetVersionInfo($full);if(([string]$meta.ProductName)-match '(?i)shim|chocolatey'){throw 'Command shim is not the actual tool binary.'}
 return [ordered]@{path=$full;sha256=(Hash $full);bytes=[long]$item.Length;machine=[int]$pe.Machine;file_version=[string]$meta.FileVersion;product_name=[string]$meta.ProductName;version='';provenance='preinstalled_hosted_fixed_package_root_no_signature_claim'}
}
function WavHighestDirectory([string]$Root,[int]$Limit){
 [void](WavOrdinary $Root -Directory);$rows=@(Get-ChildItem -LiteralPath $Root -Directory -Force)
 if(!$rows.Count-or$rows.Count-gt $Limit){throw 'Bounded SDK/toolset directory inventory required.'}
 $valid=@($rows|Where-Object{$_.Name-cmatch '^\d+\.\d+\.\d+(?:\.\d+)?$'}|ForEach-Object{[pscustomobject]@{Path=$_.FullName;Version=[version]$_.Name}}|Sort-Object Version -Descending)
 if(!$valid.Count-or($valid.Count-gt 1-and$valid[0].Version-eq$valid[1].Version)){throw 'Unique current SDK/toolset version required.'}
 return [ordered]@{root=(WavOrdinary $valid[0].Path -Directory);version=[string]$valid[0].Version}
}
function WavFileIdentity([string]$Path){$full=WavOrdinary $Path;return [ordered]@{path=$full;bytes=[long](Get-Item -LiteralPath $full).Length;sha256=(Hash $full)}}
function NewWavToolchain {
 if(!$IsWindows-or$env:GITHUB_ACTIONS-cne 'true'-or$env:RUNNER_ENVIRONMENT-cne 'github-hosted'){throw 'Only hosted Windows toolchain metadata is allowed.'}
 $llvmRoot=Join-Path $env:ProgramFiles 'LLVM\bin';[void](WavOrdinary $llvmRoot -Directory)
 $clang=WavTool (Join-Path $llvmRoot 'clang-cl.exe') 'clang-cl.exe';$lld=WavTool (Join-Path $llvmRoot 'lld-link.exe') 'lld-link.exe'
 # Resolve the real package binary, never Chocolatey's command shim.
 $ninja=WavTool (Join-Path $env:ProgramData 'chocolatey\lib\ninja\tools\ninja.exe') 'ninja.exe'
 $vc=WavHighestDirectory (Join-Path $env:ProgramFiles 'Microsoft Visual Studio\18\Enterprise\VC\Tools\MSVC') 16
 $kitRoot=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10';$sdk=WavHighestDirectory (Join-Path $kitRoot 'Include') 24
 $sdkVersion=$sdk.version;$includes=@((Join-Path $vc.root 'include'),(Join-Path $sdk.root 'ucrt'),(Join-Path $sdk.root 'shared'),(Join-Path $sdk.root 'um'))
 $libs=@((Join-Path $vc.root 'lib\x64'),(Join-Path $kitRoot ('Lib\'+$sdkVersion+'\ucrt\x64')),(Join-Path $kitRoot ('Lib\'+$sdkVersion+'\um\x64')))
 foreach($dir in @($includes)+@($libs)){[void](WavOrdinary $dir -Directory)}
 $referenceFiles=@((Join-Path $includes[0] 'stdint.h'),(Join-Path $includes[0] 'vcruntime.h'),(Join-Path $includes[1] 'stdio.h'),(Join-Path $includes[3] 'Windows.h'),(Join-Path $libs[0] 'msvcrt.lib'),(Join-Path $libs[0] 'vcruntime.lib'),(Join-Path $libs[1] 'ucrt.lib'),(Join-Path $libs[2] 'kernel32.lib'))
 $roots=[ordered]@{msvc_root=$vc.root;msvc_version=$vc.version;sdk_root=$kitRoot;sdk_version=$sdkVersion;include=@($includes);lib=@($libs);reference_files=@($referenceFiles|ForEach-Object{WavFileIdentity $_})}
 return [ordered]@{schema=1;kind='fixture_only_clangcl_ninja_lld';tools=[ordered]@{clang=$clang;lld=$lld;ninja=$ninja};roots=$roots;environment=[ordered]@{INCLUDE=($includes-join ';');LIB=($libs-join ';')};target='';runtime='default_unforced_requires_native_proof';generator='Ninja Multi-Config';helper_sha256=(Hash $script:WavToolchainHelperPath);image_version=[string]$env:ImageVersion;image_os=[string]$env:ImageOS;metadata_alone_qualifies_abi=$false}
}
function AssertWavToolchainUnchanged($Toolchain){
 foreach($tool in $Toolchain.tools.Values){if((Hash $tool.path)-cne $tool.sha256-or(Get-Item -LiteralPath $tool.path).Length-ne $tool.bytes-or[OpenWebWavPe]::Read($tool.path,$false).Machine-ne 0x8664){throw 'Actual toolchain bytes changed.'}}
 foreach($file in $Toolchain.roots.reference_files){if((Hash $file.path)-cne $file.sha256-or(Get-Item -LiteralPath $file.path).Length-ne$file.bytes){throw 'Actual SDK/CRT reference bytes changed.'}}
}
function ReadWavCacheValue([string]$Text,[string]$Name){
 $matches=@([regex]::Matches($Text,'(?m)^'+[regex]::Escape($Name)+':(?:FILEPATH|STRING|INTERNAL|UNINITIALIZED)=(.*)\r?$'))
 if($matches.Count-ne 1){throw 'Unique actual CMake cache value required.'};return $matches[0].Groups[1].Value.TrimEnd("`r")
}
function AssertWavConfigured([string]$Build,$Toolchain){
 $cache=ReadContractBounded (Join-Path $Build 'CMakeCache.txt') 1048576
 foreach($pair in @(@('CMAKE_C_COMPILER',$Toolchain.tools.clang.path),@('CMAKE_MAKE_PROGRAM',$Toolchain.tools.ninja.path),@('CMAKE_LINKER_LLD',$Toolchain.tools.lld.path),@('CMAKE_LINKER',$Toolchain.tools.lld.path))){if(!(WavSamePath (ReadWavCacheValue $cache $pair[0]) $pair[1])){throw 'CMake selected a different recorded tool.'}}
 foreach($pair in @(@('CMAKE_GENERATOR','Ninja Multi-Config'),@('CMAKE_LINKER_TYPE','LLD'),@('CMAKE_C_COMPILER_ID_FLAGS_ALWAYS',(WavCompilerIdFlags $Toolchain)))){if((ReadWavCacheValue $cache $pair[0])-cne $pair[1]){throw 'CMake ABI/generator/linker configuration differs.'}}
 $compiler=ReadContractBounded (Join-Path $Build 'CMakeFiles\4.4.4\CMakeCCompiler.cmake') 262144
 foreach($pair in @(@('CMAKE_C_COMPILER_ID','Clang'),@('CMAKE_C_SIMULATE_ID','MSVC'),@('CMAKE_C_COMPILER_FRONTEND_VARIANT','MSVC'),@('CMAKE_C_SIZEOF_DATA_PTR','8'))){if(![regex]::IsMatch($compiler,'(?m)^set\('+[regex]::Escape($pair[0])+' "'+[regex]::Escape($pair[1])+'"\)\r?$')){throw 'Actual compiler ABI probe differs.'}}
 return $cache
}
function WavSamePath([string]$Left,[string]$Right){return [string]::Equals([IO.Path]::GetFullPath($Left).Replace('/','\'),[IO.Path]::GetFullPath($Right).Replace('/','\'),[StringComparison]::OrdinalIgnoreCase)}
function GetWavBuildCommands([string]$Build,[string]$Output,$Toolchain){
 $normalized=$Output.Replace('/','\').ToLowerInvariant();$clangPath=$Toolchain.tools.clang.path.Replace('/','\').ToLowerInvariant();$lldPath=$Toolchain.tools.lld.path.Replace('/','\').ToLowerInvariant()
 if(!$normalized.Contains($clangPath)-or!$normalized.Contains($lldPath)-or[regex]::IsMatch($Output,'(?i)(?<![A-Za-z0-9_-])(?:cl|link|msbuild)\.exe')){throw 'Executed build commands must use only the recorded ClangCL/LLD toolchain.'}
 if(![regex]::IsMatch($Output,'(?m)(?:^|\s)[-/]MD(?:\s|$)')-or[regex]::IsMatch($Output,'(?m)(?:^|\s)[-/](?:MTd?|MDd)(?:\s|$)')){throw 'Actual default dynamic CRT compile evidence required; static/debug CRT refused.'}
 $generated=@();foreach($relative in @('CMakeFiles\rules.ninja','CMakeFiles\impl-Release.ninja','build-Release.ninja')){$path=Join-Path $Build $relative;$text=ReadContractBounded $path 2097152;$generated+=[ordered]@{relative_path=$relative.Replace('\','/');sha256=(Hash $path);bytes=[long](Get-Item -LiteralPath $path).Length;content=$text}}
 return [ordered]@{schema=1;generator=$Toolchain.generator;clang_path=$Toolchain.tools.clang.path;lld_path=$Toolchain.tools.lld.path;ninja_path=$Toolchain.tools.ninja.path;build_stdout_sha256=(Hash (Join-Path $evidence 'native_build.stdout.txt'));generated=$generated;recorded_compiler_and_linker_seen=$true;forbidden_msvc_command_seen=$false;default_dynamic_crt_seen=$true}
}
function GetWavDependencies([string]$Build,[string]$Sdk,$SdkRows,$Toolchain){
 $bin=Join-Path $Build 'Release';$outputs=@();$resolved=[ordered]@{};$sdkNames=@{}
 foreach($row in $SdkRows){if($row.path.Replace('\','/')-match '(?i)^bin/[^/]+\.dll$'){$sdkNames[[IO.Path]::GetFileName($row.path).ToLowerInvariant()]=$row}}
 foreach($leaf in @('libmsopenwebwav.dll','wav_contract.exe')){
  $path=WavOrdinary (Join-Path $bin $leaf);$pe=[OpenWebWavPe]::Read($path,$true);$outputs+=[ordered]@{name=$leaf;sha256=(Hash $path);machine=[int]$pe.Machine;imports=@($pe.Imports)}
  foreach($name in $pe.Imports){if($resolved.Contains($name)){continue};$kind='';$target='';$digest=''
   if($name-ceq 'libmsopenwebwav.dll'){$kind='owned_fixture';$target=Join-Path $bin $name}
   elseif($sdkNames.ContainsKey($name)){$kind='original_sdk_5.5.23';$row=$sdkNames[$name];$target=Join-Path $Sdk $row.path;if((Hash $target)-cne $row.sha256){throw 'Original SDK dependency changed.'}}
   elseif($name-cmatch '^(?:api-ms-win-|ext-ms-win-)[A-Za-z0-9_.-]+\.dll$'){$kind='windows_api_set_loader_contract'}
   else{if($name-cnotin @('kernel32.dll','ntdll.dll','msvcrt.dll','ucrtbase.dll','vcruntime140.dll','vcruntime140_1.dll','msvcp140.dll','advapi32.dll','user32.dll','gdi32.dll','shell32.dll','ole32.dll','oleaut32.dll','ws2_32.dll','rpcrt4.dll','crypt32.dll','secur32.dll','version.dll','winmm.dll','comdlg32.dll')){throw 'Unrecorded or additional compiler runtime dependency refused.'};$kind='windows_system32';$target=Join-Path $env:SystemRoot ('System32\'+$name);[void](WavOrdinary $target);[void][OpenWebWavPe]::Read($target,$false)}
   if($target){[void][OpenWebWavPe]::Read($target,$false);$digest=Hash $target};$resolved[$name]=[ordered]@{name=$name;kind=$kind;path=$target;sha256=$digest}
  }
 }
 if(!@($resolved.Keys|Where-Object{$_-ceq'ucrtbase.dll'-or$_-cmatch'^api-ms-win-crt-'}).Count){throw 'Actual dynamic UCRT import evidence required.'}
 AssertWavToolchainUnchanged $Toolchain
 return [ordered]@{schema=1;target=$Toolchain.target;runtime='dynamic_ucrt_observed';outputs=$outputs;resolved_dependencies=@($resolved.Values);original_sdk_runtime_preserved=$true;new_llvm_runtime_dependency=$false;native_loader_and_factory_proof_required=$true}
}

function WavCompilerIdFlags($Toolchain){return '-v;-fuse-ld='+$Toolchain.tools.lld.path.Replace('\','/')}
function SaveWavConfigureFailureTrace([string]$Build,[string]$Evidence){
 $inputStream=$null;$outputStream=$null;$created=$false;$target=$null
 try {
  $root=Get-Item -LiteralPath $Build -Force;$dest=Get-Item -LiteralPath $Evidence -Force
  foreach($directory in @($root,$dest)){
   if(!$directory.PSIsContainer){throw 'Owned ordinary trace directories required.'}
   $parent=$directory;$depth=0
   while($null-ne$parent){if($depth++-gt32-or($parent.Attributes-band[IO.FileAttributes]::ReparsePoint)){throw 'Ordinary bounded trace ancestry required.'};$parent=$parent.Parent}
  }
  $source=Get-Item -LiteralPath (Join-Path $root.FullName 'CMakeFiles/CMakeConfigureLog.yaml') -Force
  if($source.PSIsContainer-or($source.Attributes-band[IO.FileAttributes]::ReparsePoint)-or$source.Length-le0-or$source.Length-gt2097152){throw 'Bounded ordinary configure failure trace required.'}
  $parent=$source.Directory;$depth=0
  while($parent.FullName-ine$root.FullName){if($depth++-gt32-or($parent.Attributes-band[IO.FileAttributes]::ReparsePoint)-or$null-eq$parent.Parent){throw 'Trace must remain inside the owned build.'};$parent=$parent.Parent}
  $inputStream=[IO.File]::Open($source.FullName,'Open','Read','Read');if($inputStream.Length-ne$source.Length){throw 'Trace changed before its read lease.'}
  $buffer=[byte[]]::new(2097153);$offset=0
  while($offset-lt$buffer.Length){$n=$inputStream.Read($buffer,$offset,$buffer.Length-$offset);if(!$n){break};$offset+=$n}
  if($offset-ne$inputStream.Length-or$offset-le0-or$offset-gt2097152){throw 'Complete bounded trace required; no truncation.'}
  $target=Join-Path $dest.FullName 'configure-failure-log.private.yaml';$outputStream=[IO.File]::Open($target,'CreateNew','Write','None');$created=$true;$outputStream.Write($buffer,0,$offset);$outputStream.Flush($true);$outputStream.Dispose();$outputStream=$null
  return $true
 }catch{
  if($null-ne$outputStream){try{$outputStream.Dispose()}catch{};$outputStream=$null}
  if($created-and$target){try{[IO.File]::Delete($target)}catch{}}
  return $false
 }finally{if($null-ne$inputStream){$inputStream.Dispose()}}
}
