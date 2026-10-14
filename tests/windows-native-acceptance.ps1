#Requires -RunAsAdministrator
#Requires -Version 7.4
# SPDX-License-Identifier: AGPL-3.0-or-later
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PackageRoot,[switch]$DisposableHostedRunner,[Parameter(Mandatory)][string]$InputPath,[Parameter(Mandatory)][string]$ReportPath)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if(!$DisposableHostedRunner -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:RUNNER_OS -ne 'Windows' -or $env:GITHUB_REPOSITORY -ne 'embire2/openwebpbx') { throw 'Explicit disposable Windows hosted runner required.' }
if([Environment]::OSVersion.Version.Build -lt 26100){throw 'Windows Server 2025 is required.'}
$inputData=Get-Content -LiteralPath $InputPath -Raw|ConvertFrom-Json -AsHashtable
$root='C:\OpenWebPBX';$state=Join-Path $env:ProgramData 'OpenWebPBX';$source=Split-Path $PSScriptRoot -Parent
if($inputData.schema -ne 1 -or !$inputData.restore_server -or [IO.Path]::GetFullPath($inputData.private_state_root) -ne [IO.Path]::GetFullPath($state) -or [IO.Path]::GetFullPath($inputData.source_root) -ne [IO.Path]::GetFullPath($source) -or $inputData.public_url -ne 'https://windowsqa.example.invalid:8443' -or $inputData.run_id -ne $env:GITHUB_RUN_ID){throw 'The private disposable factory contract is invalid.'}
$installation=Get-Content -LiteralPath "$state\installation.json" -Raw|ConvertFrom-Json
if(!$installation.Completed -or !$installation.RestoreServer -or $installation.AdminEmail -ne $inputData.admin_email){throw 'A completed empty restore-server installation is required.'}
$python=[IO.Path]::GetFullPath($inputData.python)
if($python -ne "$root\backup-runtime\python.exe" -or !(Test-Path -LiteralPath $python)){throw 'Use the isolated bundled Python runtime.'}
$nativeEngine=Get-Content -LiteralPath "$state\native-engine.json" -Raw|ConvertFrom-Json
if($nativeEngine.schema -ne 1){throw 'The verified guarded registrar is required.'}
$scope=[Guid]::NewGuid().ToString('N').Substring(0,24)
$work=Join-Path $state "native-qualification\$scope";$evidence=Join-Path $work 'evidence';$privateInput=Join-Path $work 'input.json';$saved=Join-Path $work 'original'
function PrivateDirectory([string]$Path){New-Item -ItemType Directory -Force -Path $Path|Out-Null;& icacls.exe $Path /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F'|Out-Null;if($LASTEXITCODE){throw 'Private native evidence permissions failed.'}}
PrivateDirectory $work;PrivateDirectory $evidence;PrivateDirectory $saved
$inputData.scope=$scope;$inputData.company_name='Fictional Windows '+$scope;$inputData.service_name='Fictional Native '+$scope;$inputData.evidence_directory=$evidence
[IO.File]::WriteAllText($privateInput,($inputData|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
$envBefore=$env:OPENWEB_WINDOWS_NATIVE_TEST;$opensslBefore=$env:OPENSSL_CONF;$env:OPENWEB_WINDOWS_NATIVE_TEST='1';$env:OPENSSL_CONF="$root\php\extras\ssl\openssl.cnf"
$script="$source\tests\windows-native-acceptance.py";$fixture="$source\tests\windows-native-fixture.php";$pkiProcess=$null;$leaf=$null;$rootCertificate=$null;$binding=$null;$originalBinding=$null;$baseline=$false;$nativePassed=$false;$cleanupPassed=$false;$phase='factory inventory';$errorType=$null
$facts=[ordered]@{schema=1;state='running';platform='Windows Server 2025 x64';scope='fictional disposable hosted runner';checks=@();gates=[ordered]@{native_sip_audio='pending';smtp='pending';notification_store='pending';cleanup='pending';public_acme='unqualified';physical_devices='unqualified';carrier='unqualified';android_hardware='unqualified'}}
function Php([string]$Action){$output=& "$root\php\php.exe" $fixture $Action $privateInput 2>>"$evidence\private-php-errors.log";if($LASTEXITCODE){throw 'Private native fixture operation failed.'};return ($output -join "`n")}
function Python([string]$Phase){& $python -I $script --input $privateInput --phase $Phase 1>>"$evidence\private-python.log" 2>>"$evidence\private-python-errors.log";if($LASTEXITCODE){throw 'Actual native qualification did not pass.'}}
$paths=@('fusion-config.conf','phone-tls.json','phone-tls','mobile-notifications-config','mobile-notifications-lock','php-cacert')
$originalFiles=@{ 'fusion-config.conf'=(Join-Path $env:ProgramData 'fusionpbx\config.conf');'phone-tls.json'="$state\phone-tls.json";'phone-tls'="$state\phone-tls";'mobile-notifications-config'="$state\mobile-notifications\config.json";'mobile-notifications-lock'="$state\mobile-notifications\config.json.lock";'php-cacert'="$root\php\extras\ssl\cacert.pem" }
$originalPresent=@{};$originalAcl=@{};$parentAcl=(Get-Acl -LiteralPath $state).Sddl
$notificationTask='OpenWebPBX Native Notification Read '+$scope
try{
 $result=Php 'baseline'|ConvertFrom-Json;if(!$result.factory_empty){throw 'Native qualification requires an empty factory.'};$baseline=$true
 foreach($name in $paths){$path=$originalFiles[$name];$present=Test-Path -LiteralPath $path;$originalPresent[$name]=$present;if($present){$originalAcl[$name]=(Get-Acl -LiteralPath $path).Sddl;Copy-Item -LiteralPath $path -Destination (Join-Path $saved $name) -Recurse}}
 $phase='generated fictional local PKI';Python 'prepare-pki'
 $pkiProcess=Start-Process -FilePath $python -ArgumentList @('-I','"'+$script+'"','--input','"'+$privateInput+'"','--phase','pki-server') -PassThru -WindowStyle Hidden -RedirectStandardOutput "$evidence\pki-stdout.log" -RedirectStandardError "$evidence\pki-stderr.log"
 for($i=0;$i -lt 50 -and !(Test-Path "$evidence\pki-ready.json");$i++){Start-Sleep -Milliseconds 100}
 if(!(Test-Path "$evidence\pki-ready.json")){throw 'Owned loopback certificate-revocation fixture did not start.'}
 [IO.File]::AppendAllText("$root\php\extras\ssl\cacert.pem","`r`n"+[IO.File]::ReadAllText("$evidence\fixture-root.pem"),[Text.UTF8Encoding]::new($false))
 $privatePki=Get-Content "$evidence\pki-private.json" -Raw|ConvertFrom-Json
 $rootCertificate=Import-Certificate -FilePath "$evidence\fixture-root.cer" -CertStoreLocation Cert:\LocalMachine\Root
 $leaf=Import-PfxCertificate -FilePath "$evidence\fixture.pfx" -CertStoreLocation Cert:\LocalMachine\My -Password (ConvertTo-SecureString $privatePki.password -AsPlainText -Force) -Exportable
 Import-Module WebAdministration
 $binding=Get-WebBinding -Name 'OpenWebPBX' -Protocol https|Where-Object {$_.bindingInformation -eq '*:8443:windowsqa.example.invalid'}
 if(@($binding).Count -ne 1){throw 'The original local test HTTPS binding is unavailable.'}
 $originalBinding=@{hash=if($binding.certificateHash -is [byte[]]){[Convert]::ToHexString($binding.certificateHash)}else{[string]$binding.certificateHash};store=$binding.certificateStoreName}
 $binding.AddSslCertificate($leaf.Thumbprint,'My')
 & (Join-Path $PackageRoot 'Enable-PhoneTLS.ps1') -CertificateThumbprint $leaf.Thumbprint -FullChainPath "$evidence\fixture-chain.pem" 1>>"$evidence\phone-tls-private.log" 2>>"$evidence\phone-tls-private-errors.log"
 if(!$?){throw 'Actual trusted fictional phone TLS setup did not pass.'}
 $facts.checks+='Generated local-PKI chain, Windows trust and real HTTPS/SIP TLS listeners; no public ACME claim'
 $phase='normal HTTPS and native calling';Python 'acceptance'
 $native=Get-Content "$evidence\software-native-report.json" -Raw|ConvertFrom-Json
 if($native.state -ne 'passed'){throw 'Actual software native matrix failed.'}
 $facts.checks=@($native.checks);$facts.gates.native_sip_audio='passed';$facts.gates.smtp='passed'
 # Execute the exact production reader's sharing/access pattern under LOCAL SERVICE.
 # No endpoint/device is enrolled, so this probe sends no notification.
 $config="$state\mobile-notifications\config.json";$probe="$work\read-notification.ps1";$probeResult="$work\read-notification-result.json"
 [IO.File]::WriteAllText($probe,@"
`$ErrorActionPreference='Stop'
try {
 `$stream=[IO.File]::Open('$config','Open','Read',[IO.FileShare]'ReadWrite,Delete')
 try {`$reader=[IO.StreamReader]::new(`$stream);`$value=`$reader.ReadToEnd()|ConvertFrom-Json;if(!`$value.enabled -or !`$value.vapid_private_key){throw 'Native keys unavailable'}} finally {`$stream.Dispose()}
 `$parentWriteDenied=`$false
 try{[IO.File]::WriteAllText('$state\unexpected-localservice-$scope','invalid')}catch [UnauthorizedAccessException]{`$parentWriteDenied=`$true}
 if(!`$parentWriteDenied){throw 'Containing state directory became writable'}
 [IO.File]::WriteAllText('$probeResult','{"passed":true,"actual_identity":"LOCAL SERVICE","parent_write_denied":true}')
}catch{exit 1}
"@,[Text.UTF8Encoding]::new($false))
 & icacls.exe $work /grant '*S-1-5-19:(RX)'|Out-Null;& icacls.exe $probe /grant '*S-1-5-19:(R)'|Out-Null
 # Result lives in a dedicated writable child, never the containing state directory.
 $readChild=Join-Path $work 'reader';New-Item -ItemType Directory -Path $readChild|Out-Null;& icacls.exe $readChild /grant '*S-1-5-19:(OI)(CI)M'|Out-Null
 $probeResult=Join-Path $readChild 'result.json';$text=[IO.File]::ReadAllText($probe).Replace("$work\read-notification-result.json",$probeResult);[IO.File]::WriteAllText($probe,$text,[Text.UTF8Encoding]::new($false))
 $taskAction=New-ScheduledTaskAction -Execute "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument ('-NoProfile -NonInteractive -File "'+$probe+'"')
 $principal=New-ScheduledTaskPrincipal -UserId 'S-1-5-19' -LogonType ServiceAccount
 Register-ScheduledTask -TaskName $notificationTask -Action $taskAction -Principal $principal|Out-Null;Start-ScheduledTask -TaskName $notificationTask
 for($i=0;$i -lt 100 -and !(Test-Path $probeResult);$i++){Start-Sleep -Milliseconds 100}
 if(!(Test-Path $probeResult) -or !(Get-Content $probeResult -Raw|ConvertFrom-Json).passed){throw 'Actual LOCAL SERVICE cannot read normal IIS-generated notification identity.'}
 if((Get-Acl -LiteralPath $state).Sddl -ne $parentAcl){throw 'Containing private-state ACL changed.'}
 $service=Get-CimInstance Win32_Service -Filter "Name='OpenWebPBX'";if($service.StartName -notin 'NT AUTHORITY\LocalService','NT AUTHORITY\LOCAL SERVICE'){throw 'Native background service uses an unexpected identity.'}
 $facts.checks+='Actual LOCAL SERVICE reads IIS-generated stable keys with parent write denied; production C# reader source tested separately; no delivery sent'
 $facts.gates.notification_store='passed';$nativePassed=$true
}catch{$errorType=$_.Exception.GetType().Name;$facts.state='failed';$facts.failed_phase=$phase;$facts.error_type=$errorType}
finally{
 $phase='exact scoped cleanup'
 try{
  Stop-ScheduledTask -TaskName $notificationTask -ErrorAction SilentlyContinue;Unregister-ScheduledTask -TaskName $notificationTask -Confirm:$false -ErrorAction SilentlyContinue
  if($baseline){$clean=Php 'cleanup'|ConvertFrom-Json;if(!$clean.factory_empty -or $clean.owned_rows -ne 0 -or $clean.owned_contacts -ne 0){throw 'Native fixture cleanup is incomplete.'}}
  if($binding -and $originalBinding){$binding.AddSslCertificate($originalBinding.hash,$originalBinding.store)}
  foreach($name in $paths){$path=$originalFiles[$name];if($originalPresent.ContainsKey($name)){if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse -Force};if($originalPresent[$name]){Copy-Item -LiteralPath (Join-Path $saved $name) -Destination $path -Recurse;$acl=Get-Acl -LiteralPath $path;$acl.SetSecurityDescriptorSddlForm($originalAcl[$name]);Set-Acl -LiteralPath $path -AclObject $acl}}}
  if($baseline){Restart-Service FreeSWITCH;for($i=0;$i -lt 50 -and (Get-Service FreeSWITCH).Status -ne 'Running';$i++){Start-Sleep -Milliseconds 100};if((Get-Service FreeSWITCH).Status -ne 'Running'){throw 'Original factory call engine did not resume.'}}
  if($leaf){Remove-Item -LiteralPath ('Cert:\LocalMachine\My\'+$leaf.Thumbprint) -Force}
  if($rootCertificate){Remove-Item -LiteralPath ('Cert:\LocalMachine\Root\'+$rootCertificate.Thumbprint) -Force}
  if($pkiProcess -and !$pkiProcess.HasExited){Stop-Process -Id $pkiProcess.Id -Force}
  if(Test-Path "$state\unexpected-localservice-$scope"){Remove-Item "$state\unexpected-localservice-$scope" -Force;throw 'LOCAL SERVICE incorrectly wrote containing state.'}
  $cleanupPassed=$true;$facts.gates.cleanup='passed';$facts.cleanup='Original factory rows/contacts/identity/profile/config/certificate binding restored; owned CA/leaf and private probe task removed'
 }catch{$cleanupPassed=$false;$facts.state='failed';$facts.cleanup='failed';$facts.cleanup_error_type=$_.Exception.GetType().Name}
 if($null -eq $envBefore){Remove-Item Env:\OPENWEB_WINDOWS_NATIVE_TEST -ErrorAction SilentlyContinue}else{$env:OPENWEB_WINDOWS_NATIVE_TEST=$envBefore}
 if($null -eq $opensslBefore){Remove-Item Env:\OPENSSL_CONF -ErrorAction SilentlyContinue}else{$env:OPENSSL_CONF=$opensslBefore}
 if($nativePassed -and $cleanupPassed){$facts.state='passed'}
 [IO.File]::WriteAllText($ReportPath,($facts|ConvertTo-Json -Depth 14),[Text.UTF8Encoding]::new($false))
}
if($facts.state -ne 'passed'){throw 'Windows native acceptance did not pass. Review private evidence; factory cleanup must pass before backups.'}
Write-Host 'Actual fictional Windows native calling, SMTP, notification storage and factory cleanup passed.'
