[CmdletBinding()]
param([Parameter(Mandatory)][string]$Output)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows' -or $env:GITHUB_REPOSITORY -cne 'embire2/openwebpbx'){throw 'Build only on the disposable hosted Windows runner.'}
$client=Split-Path $PSScriptRoot -Parent;$evidence=Join-Path $Output 'evidence';New-Item -ItemType Directory -Path $evidence -Force|Out-Null
$report=[ordered]@{schema=1;component='windows-free-phone';version='1.0.0';source_commit=(git rev-parse HEAD);state='running';actual_calling_tested=$false;physical_audio_video_tested=$false;store_accepted=$false}
$process=$null;$receipt=$null;$launchStarted=$null;$nativeReceipt=$null;Push-Location $client
try{
 if((dotnet --version).Trim() -cne '10.0.401'){throw 'The exact .NET SDK is required.'}
 $archive=Join-Path $env:RUNNER_TEMP 'windows-phone-linphone-5.5.23.zip'
 Invoke-WebRequest -Uri 'https://download.linphone.org/releases/windows/sdk/linphone-sdk-win64-5.5.23.zip' -OutFile $archive
 if((Get-Item $archive).Length -ne 315960147 -or (Get-FileHash $archive -Algorithm SHA256).Hash -cne '9CC84037333DACA88AF24804E20B9D1F5E41DDD901578484B57DCC6720A8D297'){throw 'The pinned native SDK differs.'}
 $sdk=Join-Path $env:RUNNER_TEMP ('windows-phone-sdk-'+[Guid]::NewGuid().ToString('N'));Expand-Archive -LiteralPath $archive -DestinationPath $sdk
 $native=Join-Path $sdk 'linphone-sdk\win64';$binding=Join-Path $native 'share\linphonecs\LinphoneWrapper.cs'
 if((Get-FileHash $binding -Algorithm SHA256).Hash -cne 'A99C5197BE469D58812AFC33A2ADB104505134B9A03AC7654D11E4E4341D3A15'){throw 'The official native binding differs.'}
 $report.native_sdk='5.5.23';$report.native_sdk_sha256='9cc84037333daca88af24804e20b9d1f5e41ddd901578484b57dcc6720a8d297';$report.binding_sha256='a99c5197be469d58812afc33a2adb104505134b9a03ac7654d11e4e4341d3a15'
 & dotnet run --project (Join-Path $client 'tests\OpenWebPbx.Phone.Checks') -c Release *> (Join-Path $evidence 'core-checks.log');if($LASTEXITCODE){throw 'Client core checks failed.'}
 $app=Join-Path $Output 'app';$project=Join-Path $client 'src\OpenWebPbx.Phone.App\OpenWebPbx.Phone.App.csproj'
 & dotnet publish $project -c Release -r win-x64 --self-contained true '-p:PhoneDistribution=direct' "-p:LinphoneBinding=$binding" -o $app *> (Join-Path $evidence 'build.log');if($LASTEXITCODE){throw 'The native client build failed.'}
 $dlls=@(Get-ChildItem (Join-Path $native 'bin') -Filter '*.dll'|Where-Object {$_.Name -notmatch 'tester|bcunit'})
 foreach($dll in $dlls){if(Test-Path (Join-Path $app $dll.Name)){throw 'A native dependency collides.'};Copy-Item $dll.FullName (Join-Path $app $dll.Name)}
 $plugins=Join-Path $app 'native\plugins';New-Item -ItemType Directory $plugins -Force|Out-Null;Copy-Item (Join-Path $native 'lib\mediastreamer\plugins\*.dll') $plugins
 $share=Join-Path $app 'native\share';New-Item -ItemType Directory $share -Force|Out-Null
 foreach($resource in @('belr','linphone','sounds','images')){if(Test-Path (Join-Path $native ('share\'+$resource))){Copy-Item (Join-Path $native ('share\'+$resource)) $share -Recurse}}
 $assets=Join-Path $client 'src\OpenWebPbx.Phone.App\Assets'
 $targetAssets=Join-Path $app 'Assets';New-Item -ItemType Directory -Path $targetAssets -Force|Out-Null;Get-ChildItem -LiteralPath $assets -File|Copy-Item -Destination $targetAssets -Force
 if(!(Test-Path (Join-Path $app 'Assets\AppIcon.ico'))){throw 'The native app icon is missing.'}
 @('OpenWebPbx.Phone.App.exe','Microsoft.UI.Xaml.dll','Microsoft.WindowsAppRuntime.Bootstrap.dll','liblinphone.dll','Assets/AppIcon.ico')|ForEach-Object{[ordered]@{name=$_;present=(Test-Path (Join-Path $app $_))}}|ConvertTo-Json|Set-Content (Join-Path $evidence 'startup-files.json')
 $grammarManifest=Get-Content (Join-Path $client 'native\runtime-resources.json') -Raw|ConvertFrom-Json
 if($grammarManifest.files.Count -ne 8){throw 'Runtime grammar manifest differs.'}
 foreach($entry in $grammarManifest.files){
  $sourceGrammar=Join-Path (Join-Path $native 'share') $entry.path;$targetGrammar=Join-Path $share $entry.path
  if((Get-Item $sourceGrammar).Length -ne $entry.bytes -or (Get-FileHash $sourceGrammar -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.sha256 -or (Get-FileHash $targetGrammar -Algorithm SHA256).Hash.ToLowerInvariant() -cne $entry.sha256){throw 'A pinned runtime grammar differs.'}
 }
 $report.pinned_runtime_grammars=$grammarManifest.files.Count
 $checks=Join-Path $Output 'native-checks' 
 & dotnet publish (Join-Path $client 'tests\OpenWebPbx.Phone.NativeChecks') -c Release -r win-x64 --self-contained true "-p:LinphoneBinding=$binding" -o $checks *> (Join-Path $evidence 'native-check-build.log');if($LASTEXITCODE){throw 'Native checks do not build.'}
 foreach($dll in $dlls){Copy-Item $dll.FullName (Join-Path $checks $dll.Name) -Force};Copy-Item (Join-Path $app 'native') (Join-Path $checks 'native') -Recurse
 $nativeReceipt=Join-Path $env:RUNNER_TEMP ('phone-native-result-'+[Guid]::NewGuid().ToString('N')+'.json')
 Push-Location ([Environment]::SystemDirectory)
 try{& (Join-Path $checks 'OpenWebPbx.Phone.NativeChecks.exe') $nativeReceipt *> (Join-Path $evidence 'native-checks.log');$report.native_child_exit_code=[int]$LASTEXITCODE;if($LASTEXITCODE){throw 'Native protected storage or core checks failed.'}}finally{Pop-Location}
 $nativeResult=Get-Content -LiteralPath $nativeReceipt -Raw|ConvertFrom-Json
 if($nativeResult.schema -ne 1 -or $nativeResult.producer -cne 'OpenWebPbx.Phone.NativeChecks' -or $nativeResult.state -cne 'passed' -or $nativeResult.checks -lt 17 -or $nativeResult.checks -gt 64){throw 'Native component proof differs.'}
 foreach($flag in @('actual_native_windows','actual_current_user_dpapi','actual_native_core')){if($nativeResult.$flag -isnot [bool] -or !$nativeResult.$flag){throw 'Native component proof is incomplete.'}}
 foreach($flag in @('calls_placed','hardware_media_tested')){if($nativeResult.$flag -isnot [bool] -or $nativeResult.$flag){throw 'Native component scope differs.'}}
 Copy-Item -LiteralPath $nativeReceipt -Destination (Join-Path $evidence 'native-checks.json')
 $report.native_dpapi_and_core_checks=$true
 $report.direct_build=$true
 $exe=Join-Path $app 'OpenWebPbx.Phone.App.exe';$receipt=Join-Path $env:RUNNER_TEMP ('phone-ui-'+[Guid]::NewGuid().ToString('N')+'.json')
 $launchStarted=Get-Date
 $process=Start-Process -FilePath $exe -WorkingDirectory ([Environment]::SystemDirectory) -ArgumentList @('--component-receipt',('"'+$receipt+'"')) -PassThru
 $end=[DateTime]::UtcNow.AddSeconds(60)
 do{Start-Sleep -Milliseconds 250;$process.Refresh();if($process.HasExited){$report.process_exit_code=[int]$process.ExitCode;throw 'The native client exited before its visible window.'}}while([DateTime]::UtcNow -lt $end -and (!(Test-Path $receipt) -or $process.MainWindowHandle -eq 0 -or !$process.Responding))
 if(!(Test-Path $receipt) -or $process.MainWindowHandle -eq 0 -or !$process.Responding -or $process.MainWindowTitle -cne 'OpenWebPBX Free Phone'){throw 'A responsive native client window was not proven.'}
 $ui=Get-Content -LiteralPath $receipt -Raw|ConvertFrom-Json
 if($ui.schema -ne 1 -or $ui.version -cne '1.0.0' -or $ui.native_core_started -ne $true -or $ui.credentials_persisted -ne $false -or $ui.tls_ca_and_hostname -ne $true -or $ui.mandatory_srtp -ne $true -or $ui.calls_placed -ne $false){throw 'Native client startup policy differs.'}
 Copy-Item $receipt (Join-Path $evidence 'native-startup.json');$report.responsive_native_window=$true;$report.native_core_startup=$true
 Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public static class PhoneWindowCapture{[StructLayout(LayoutKind.Sequential)]public struct Rect{public int Left,Top,Right,Bottom;}[DllImport("user32.dll")]public static extern bool GetWindowRect(IntPtr h,out Rect r);[DllImport("user32.dll")]public static extern bool SetForegroundWindow(IntPtr h);}'
 Add-Type -AssemblyName System.Drawing
 [PhoneWindowCapture]::SetForegroundWindow($process.MainWindowHandle)|Out-Null;Start-Sleep -Milliseconds 500
 $rect=[PhoneWindowCapture+Rect]::new();if(![PhoneWindowCapture]::GetWindowRect($process.MainWindowHandle,[ref]$rect)){throw 'Native window bounds are unavailable.'}
 $width=$rect.Right-$rect.Left;$height=$rect.Bottom-$rect.Top;if($width -lt 320 -or $height -lt 320 -or $width -gt 4000 -or $height -gt 3000){throw 'Native window bounds differ.'}
 $bitmap=[Drawing.Bitmap]::new($width,$height);$graphics=[Drawing.Graphics]::FromImage($bitmap)
 try{$graphics.CopyFromScreen($rect.Left,$rect.Top,0,0,$bitmap.Size);$bitmap.Save((Join-Path $evidence 'client-window.png'),[Drawing.Imaging.ImageFormat]::Png)}finally{$graphics.Dispose();$bitmap.Dispose()}
 $report.native_window_screenshot=$true
 $uiReport=Join-Path $evidence 'interface-controls.json'
 & (Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe') -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Test-ClientInterface.ps1') -ProcessId $process.Id -Executable $exe -Report $uiReport *> (Join-Path $evidence 'interface-controls.log')
 if($LASTEXITCODE){throw 'The native account/settings interface checks failed.'}
 $interface=Get-Content -LiteralPath $uiReport -Raw|ConvertFrom-Json
 if($interface.producer -cne 'Test-ClientInterface.ps1' -or $interface.state -cne 'passed' -or $interface.checks -lt 20 -or $interface.actual_native_uia -ne $true -or $interface.logged_out_accounts_settings_keypad -ne $true -or $interface.network_sign_in_tested -ne $false -or $interface.calls_placed -ne $false){throw 'Native interface proof differs.'}
 $report.native_interface_checks=[int]$interface.checks
 $report.state='passed_build_startup';$report.limitation='Native client build and visible startup only; calling, hardware, packaging and Store acceptance remain separate gates.'
}catch{$report.state='failed';$report.error_type=$_.Exception.GetType().Name;$report.source_line=$_.InvocationInfo.ScriptLineNumber;throw}
finally{
 if($nativeReceipt -and (Test-Path $nativeReceipt)){Copy-Item -LiteralPath $nativeReceipt -Destination (Join-Path $evidence 'native-checks.json') -Force}
 if($process -and $process.HasExited){$report.process_exit_code=[int]$process.ExitCode}
 if($launchStarted){
  try{
   $events=@(Get-WinEvent -FilterHashtable @{LogName='Application';StartTime=$launchStarted;Level=2} -MaxEvents 20 -ErrorAction Stop|Where-Object {$_.Message -match 'OpenWebPbx\.Phone\.App(?:\.exe)?'})
   $report.startup_events=@($events|ForEach-Object {$message=$_.Message;$types=@([regex]::Matches($message,'System\.(?:[A-Za-z0-9]+\.)*[A-Za-z0-9]+Exception')|ForEach-Object {$_.Value}|Select-Object -Unique -First 4);[ordered]@{event_id=[int]$_.Id;managed_error_types=$types}})
  }catch{$report.startup_events_observation='unavailable'}
 }
 if($receipt -and (Test-Path ($receipt+'.failure.json'))){Copy-Item ($receipt+'.failure.json') (Join-Path $evidence 'startup-failure.json')}
 if($process -and !$process.HasExited){Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue;Wait-Process -Id $process.Id -Timeout 10 -ErrorAction SilentlyContinue}
 $evidenceFiles=@(Get-ChildItem -LiteralPath $evidence -File -Recurse -Force)
 $report.evidence_bounded=$true
 foreach($item in $evidenceFiles){
  if($item.DirectoryName -cne $evidence -or $item.Name -notin 'core-checks.log','native-check-build.log','native-checks.log','native-checks.json','build.log','native-startup.json','startup-failure.json','startup-files.json','client-window.png','client-accounts.png','client-settings.png','interface-controls.json','interface-controls.log','qualification.json' -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){Remove-Item -LiteralPath $item.FullName -Force;$report.evidence_bounded=$false;continue}
  if($item.Length -gt 8MB){$buffer=[byte[]]::new(8MB);$input=[IO.File]::OpenRead($item.FullName);try{$count=$input.Read($buffer,0,$buffer.Length)}finally{$input.Dispose()};$output=[IO.File]::Create($item.FullName);try{$output.Write($buffer,0,$count)}finally{$output.Dispose()};$report.evidence_bounded=$false}
 }
 if($evidenceFiles.Count -gt 16 -or (Get-ChildItem -LiteralPath $evidence -File|Measure-Object Length -Sum).Sum -gt 32MB){foreach($item in Get-ChildItem -LiteralPath $evidence -File){Remove-Item -LiteralPath $item.FullName -Force};$report.evidence_bounded=$false}
 if(!$report.evidence_bounded){$report.state='failed';$report.evidence_failure='size_or_file_scope'}
 $report|ConvertTo-Json -Depth 8|Set-Content (Join-Path $evidence 'qualification.json') -Encoding utf8;Pop-Location
}
