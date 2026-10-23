[CmdletBinding()]
param([Parameter(Mandatory)][string]$Output)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows' -or $env:GITHUB_REPOSITORY -cne 'embire2/openwebpbx'){throw 'Only the disposable hosted Windows toolchain may run this probe.'}
New-Item -ItemType Directory -Path $Output|Out-Null
$report=[ordered]@{schema=1;source_commit=(git rev-parse HEAD);component='windows-free-phone';version='1.0.0';state='running';actual_calling_tested=$false;store_accepted=$false}
try{
 $report.sdk=(dotnet --version).Trim();if($report.sdk -cne '10.0.401'){throw 'The selected .NET SDK differs.'}
 $bootstrap=Join-Path $PSScriptRoot 'bootstrap';Push-Location $bootstrap
 try{
  if(Get-Command winget.exe -ErrorAction SilentlyContinue){
   & winget configure -f config.yaml --accept-configuration-agreements --disable-interactivity *> (Join-Path $Output 'bootstrap.log')
   $report.bootstrap_exit=$LASTEXITCODE;$report.bootstrap=if($LASTEXITCODE -eq 0){'passed'}else{'partial_failure'}
  }else{$report.bootstrap='winget_unavailable'}
 }finally{Pop-Location}
 # The official CLI template provides a buildable reference even when the
 # preinstalled hosted toolchain makes the optional WinGet bootstrap partial.
 & dotnet new install Microsoft.WindowsAppSDK.WinUI.CSharp.Templates *> (Join-Path $Output 'template-install.log')
 if($LASTEXITCODE){throw 'The official WinUI template install failed.'}
 & dotnet new list winui *> (Join-Path $Output 'templates.log');if($LASTEXITCODE){throw 'The WinUI template is unavailable.'}
 $project=Join-Path $env:RUNNER_TEMP ('phone-template-'+[Guid]::NewGuid().ToString('N'))
 & dotnet new winui -o $project -f net10.0 --unpackaged false *> (Join-Path $Output 'scaffold.log');if($LASTEXITCODE){throw 'The official packaged scaffold failed.'}
 $projects=@(Get-ChildItem -LiteralPath $project -Filter '*.csproj' -Recurse);if($projects.Count -ne 1){throw 'The official scaffold project is ambiguous.'}
 & dotnet build $projects[0].FullName -c Release *> (Join-Path $Output 'scaffold-build.log');if($LASTEXITCODE){throw 'The official scaffold does not build on this toolchain.'}
 $sample=Join-Path $Output 'template-source';New-Item -ItemType Directory $sample|Out-Null
 $sourceFiles=@(Get-ChildItem -LiteralPath $project -File -Recurse -Force|Where-Object {
  $relative=[IO.Path]::GetRelativePath($project,$_.FullName).Replace('\','/');$segments=$relative.Split('/')
  'bin' -notin $segments -and 'obj' -notin $segments
 })
 if($sourceFiles.Count -lt 4 -or $sourceFiles.Count -gt 200 -or ($sourceFiles|Measure-Object Length -Sum).Sum -gt 4MB){throw 'The scaffold source inventory exceeds its bound.'}
 foreach($file in $sourceFiles){
  if($file.Length -gt 1MB -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'A scaffold source file is too large or linked.'}
  $relative=[IO.Path]::GetRelativePath($project,$file.FullName);$target=Join-Path $sample $relative;New-Item -ItemType Directory -Force (Split-Path $target)|Out-Null;Copy-Item -LiteralPath $file.FullName -Destination $target
 }
 $report.template_source_files=$sourceFiles.Count;$report.template_source_bytes=($sourceFiles|Measure-Object Length -Sum).Sum
 $report.template_built=$true;$report.template_launch='pending_app_activation_probe'
 $sdkUrl='https://download.linphone.org/releases/windows/sdk/linphone-sdk-win64-5.5.23.zip'
 $archive=Join-Path $env:RUNNER_TEMP 'openweb-phone-linphone-5.5.23.zip'
 Invoke-WebRequest -Uri $sdkUrl -OutFile $archive
 $file=Get-Item $archive;if($file.Length -ne 315960147){throw 'The pinned official SDK size differs.'}
 $report.native_sdk=[ordered]@{version='5.5.23';url=$sdkUrl;bytes=$file.Length;sha256=(Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()}
 Add-Type -AssemblyName System.IO.Compression.FileSystem;$zip=[IO.Compression.ZipFile]::OpenRead($archive)
 try{
  $report.native_sdk.members=$zip.Entries.Count
  $licenses=@($zip.Entries|Where-Object {$_.FullName -ceq 'linphone-sdk/win64/share/doc/linphone-sdk/LICENSE.md'})
  if($licenses.Count -ne 1 -or $licenses[0].Length -lt 100 -or $licenses[0].Length -gt 32768){throw 'The exact SDK license is missing or oversized.'}
  $license=Join-Path $Output 'linphone-sdk-LICENSE.md';[IO.Compression.ZipFileExtensions]::ExtractToFile($licenses[0],$license,$false)
  if(!(Test-Path -LiteralPath $license) -or (Get-Item $license).Length -ne $licenses[0].Length){throw 'The SDK license was not retained.'}
  $report.native_sdk.license_sha256=(Get-FileHash $license -Algorithm SHA256).Hash.ToLowerInvariant()
  $binding=$zip.GetEntry('linphone-sdk/win64/share/linphonecs/LinphoneWrapper.cs');if(!$binding -or $binding.Length -gt 3MB){throw 'The official C# binding is unavailable or changed.'}
  $stream=$binding.Open();$memory=[IO.MemoryStream]::new();try{$stream.CopyTo($memory);$bindingBytes=$memory.ToArray()}finally{$memory.Dispose();$stream.Dispose()};$text=[Text.Encoding]::UTF8.GetString($bindingBytes)
  $report.native_sdk.binding_bytes=$binding.Length
  $report.native_sdk.binding_sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bindingBytes)).ToLowerInvariant()
  $lines=$text -split "`n";$surface=@()
  for($i=0;$i -lt $lines.Count;$i++){if($lines[$i] -match 'namespace Linphone|CreateCore|CreateAuthInfo|NativeVideoWindowId|NativePreviewWindowId|OnCallStateChanged|OnAccountRegistrationStateChanged|OnTransferStateChanged|VideoDevice|RootCa|VerifyServer|Conference|public class CoreListener'){$surface+=$lines[([Math]::Max(0,$i-1))..([Math]::Min($lines.Count-1,$i+2))]}}
  $surface|Set-Content (Join-Path $Output 'linphone-binding-surface.txt') -Encoding utf8
  @($zip.Entries|Where-Object {$_.FullName -match '\.(dll|lib)$'}|ForEach-Object{[ordered]@{path=$_.FullName;bytes=$_.Length}})|ConvertTo-Json -Depth 4|Set-Content (Join-Path $Output 'linphone-native-members.json') -Encoding utf8
 }finally{$zip.Dispose()}
 $report.state='passed_component_inventory';$report.limitation='Template build and SDK inventory only; visible application launch, native calls, hardware and Store approval remain unqualified.'
}finally{$report|ConvertTo-Json -Depth 8|Set-Content (Join-Path $Output 'qualification.json') -Encoding utf8}
