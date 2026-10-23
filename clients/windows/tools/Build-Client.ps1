[CmdletBinding()]
param([Parameter(Mandatory)][string]$Output)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows' -or $env:GITHUB_REPOSITORY -cne 'embire2/openwebpbx'){throw 'Build only on the disposable hosted Windows runner.'}
$client=Split-Path $PSScriptRoot -Parent;$evidence=Join-Path $Output 'evidence';New-Item -ItemType Directory -Path $evidence -Force|Out-Null
$report=[ordered]@{schema=1;component='windows-free-phone';version='1.0.0';source_commit=(git rev-parse HEAD);state='running';actual_calling_tested=$false;physical_audio_video_tested=$false;store_accepted=$false}
$process=$null;Push-Location $client
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
 foreach($resource in @('linphone','sounds','images')){if(Test-Path (Join-Path $native ('share\'+$resource))){Copy-Item (Join-Path $native ('share\'+$resource)) $share -Recurse}}
 $report.direct_build=$true
 $exe=Join-Path $app 'OpenWebPbx.Phone.App.exe';$receipt=Join-Path $env:RUNNER_TEMP ('phone-ui-'+[Guid]::NewGuid().ToString('N')+'.json')
 $process=Start-Process -FilePath $exe -WorkingDirectory ([Environment]::SystemDirectory) -ArgumentList @('--component-receipt',('"'+$receipt+'"')) -PassThru
 $end=[DateTime]::UtcNow.AddSeconds(60)
 do{Start-Sleep -Milliseconds 250;$process.Refresh();if($process.HasExited){throw 'The native client exited before its visible window.'}}while([DateTime]::UtcNow -lt $end -and (!(Test-Path $receipt) -or $process.MainWindowHandle -eq 0 -or !$process.Responding))
 if(!(Test-Path $receipt) -or $process.MainWindowHandle -eq 0 -or !$process.Responding -or $process.MainWindowTitle -cne 'OpenWebPBX Free Phone'){throw 'A responsive native client window was not proven.'}
 $ui=Get-Content -LiteralPath $receipt -Raw|ConvertFrom-Json
 if($ui.schema -ne 1 -or $ui.version -cne '1.0.0' -or $ui.native_core_started -ne $true -or $ui.credentials_persisted -ne $false -or $ui.tls_ca_and_hostname -ne $true -or $ui.mandatory_srtp -ne $true -or $ui.calls_placed -ne $false){throw 'Native client startup policy differs.'}
 Copy-Item $receipt (Join-Path $evidence 'native-startup.json');$report.responsive_native_window=$true;$report.native_core_startup=$true
 $report.state='passed_build_startup';$report.limitation='Native client build and visible startup only; calling, hardware, packaging and Store acceptance remain separate gates.'
}catch{$report.state='failed';$report.error_type=$_.Exception.GetType().Name;$report.source_line=$_.InvocationInfo.ScriptLineNumber;throw}
finally{
 if($process -and !$process.HasExited){Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue;Wait-Process -Id $process.Id -Timeout 10 -ErrorAction SilentlyContinue}
 $report|ConvertTo-Json -Depth 8|Set-Content (Join-Path $evidence 'qualification.json') -Encoding utf8;Pop-Location
}
