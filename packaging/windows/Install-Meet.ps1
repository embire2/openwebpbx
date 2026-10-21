#Requires -RunAsAdministrator
# SPDX-License-Identifier: AGPL-3.0-or-later
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PackageRoot,[IO.FileStream]$MaintenanceLock,[switch]$RebindRestoredTransport,[switch]$MaintenanceLockHeld)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$root='C:\OpenWebPBX';$state=Join-Path $env:ProgramData 'OpenWebPBX'
. (Join-Path $PSScriptRoot 'Meet-Proxy.ps1')
. (Join-Path $PSScriptRoot 'Write-PrivateState.ps1')
if($MaintenanceLockHeld){
 if(!$RebindRestoredTransport -or $MaintenanceLock){throw 'An external maintenance lock is supported only for a closed restore transport refresh.'}
 $restore=Join-Path $state 'backup-restore';$journal=Join-Path $restore 'journal.json';$null=Assert-OpenWebMeetOrdinary $journal
 if(!(Test-Path -LiteralPath $journal) -or (Get-Content -LiteralPath $journal -Raw|ConvertFrom-Json).state -notin 'prepared','restoring','recovery_required'){throw 'The protected restore transaction must be running.'}
 foreach($name in 'calls','jobs','updates'){$hold=Join-Path $restore ('hold-'+$name);$null=Assert-OpenWebMeetOrdinary $hold;if(!(Test-Path -LiteralPath $hold -PathType Leaf)){throw 'Restore must hold calling and background work before rebinding meetings.'}}
 foreach($name in 'FreeSWITCH','OpenWebPBX'){if((Get-Service -Name $name).Status -ne 'Stopped'){throw 'Restore must stop calling before rebinding meetings.'}}
 Add-Type -Path "$env:windir\System32\inetsrv\Microsoft.Web.Administration.dll"
 $manager=[Microsoft.Web.Administration.ServerManager]::new();try{if(!$manager.Sites['OpenWebPBX'] -or $manager.Sites['OpenWebPBX'].State -ne 'Stopped'){throw 'Restore must stop the PBX website before rebinding meetings.'}}finally{$manager.Dispose()}
 $held=$false;try{$probe=[IO.File]::Open((Join-Path $state 'upgrade.lock'),'Open','ReadWrite','None');$probe.Dispose()}catch [IO.IOException]{$held=$true};if(!$held){throw 'The parent restore must retain its exclusive maintenance lock.'}
}elseif(!$MaintenanceLock -or !$MaintenanceLock.CanRead -or !$MaintenanceLock.CanWrite -or [IO.Path]::GetFullPath($MaintenanceLock.Name) -ne [IO.Path]::GetFullPath((Join-Path $state 'upgrade.lock'))){throw 'The owned PBX maintenance lock is required to install meetings.'}
foreach($path in $PackageRoot,$root,$state,(Join-Path $state 'meet-ca.pem'),(Join-Path $root 'web\web.config')){$null=Assert-OpenWebMeetOrdinary $path}
$directory=Join-Path $state 'meet-proxy';$null=Assert-OpenWebMeetOrdinary $directory
if(!(Test-Path -LiteralPath $directory)){New-Item -ItemType Directory -Path $directory|Out-Null}
& icacls.exe $directory /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F'|Out-Null
if($LASTEXITCODE){throw 'Private meeting installation storage could not be protected.'}
$snapshot=Join-Path $directory 'before.json';$ledgerPath=Join-Path $state 'meet-proxy.json';$web=Join-Path $root 'web\web.config'
# Every successful repeat validates the installed rule before returning.
$old=if(Test-Path -LiteralPath $ledgerPath){Get-Content -LiteralPath $ledgerPath -Raw|ConvertFrom-Json}else{$null}
if($old -and ($old.Schema -ne 1 -or $old.Thumbprint -cnotmatch '^[A-F0-9]{40}$')){throw 'The installed meeting ownership ledger needs review.'}
if($old -and !$old.Complete){throw 'An interrupted meeting installation needs recovery from its retained private snapshot before continuing.'}
& "$root\php\php.exe" (Join-Path $PackageRoot 'check-meet.php') "$root\web"
if($LASTEXITCODE){throw 'The private meeting certificate and endpoint did not validate.'}
$certificate=Get-OpenWebMeetCertificate (Join-Path $state 'meet-ca.pem')
foreach($trusted in Get-ChildItem Cert:\LocalMachine\Root){
 if($trusted.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName,$false) -ceq 'openweb-meet.internal' -and $trusted.Thumbprint -cne $certificate.Thumbprint -and (!$old -or !$old.OwnedTrust -or $trusted.Thumbprint -cne $old.Thumbprint -or [Convert]::ToBase64String($trusted.RawData) -cne $old.Certificate)){throw 'The private meeting hostname has an unowned trust certificate; review it before continuing.'}
}
if($old -and $old.Complete -and $old.Thumbprint -ceq $certificate.Thumbprint -and (Get-FileHash -LiteralPath $web -Algorithm SHA256).Hash -ceq $old.WebConfigHash){
 $proxy=Get-OpenWebMeetProxyState;$flags=Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\IIS Extensions\Application Request Routing\Parameters' -Name SecureConnectionIgnoreFlags
 if(!$proxy.Enabled -or $proxy.PreserveHostHeader -or $flags.SecureConnectionIgnoreFlags -ne 0 -or !(Test-Path ('Cert:\LocalMachine\Root\'+$certificate.Thumbprint)) -or (Get-OpenWebMeetHostsPlan ([IO.File]::ReadAllBytes((Join-Path $env:windir 'System32\drivers\etc\hosts')))).Changed){throw 'The installed meeting transport needs administrator review.'}
 Assert-OpenWebMeetWebSocket
 Write-Host 'The private meeting WebSocket transport is already installed.';return
}
if($RebindRestoredTransport -and (!$old -or !$old.Complete -or (Get-FileHash -LiteralPath $web -Algorithm SHA256).Hash -cne $old.WebConfigHash)){throw 'Restore rebind requires the unchanged owned target meeting proxy.'}
Save-OpenWebMeetSystem -Destination $snapshot -StateRoot $state
$webBefore=[IO.File]::ReadAllBytes($web);$ledgerBefore=if(Test-Path -LiteralPath $ledgerPath){[IO.File]::ReadAllBytes($ledgerPath)}else{$null}
$proposed=Join-Path $directory 'web.proposed.config';[IO.File]::WriteAllBytes($proposed,$webBefore)
if(!$RebindRestoredTransport){Set-OpenWebMeetWebConfig $proposed}
$webAfter=[IO.File]::ReadAllBytes($proposed);$webBeforeHash=(Get-FileHash -LiteralPath $web -Algorithm SHA256).Hash;$webAfterHash=(Get-FileHash -LiteralPath $proposed -Algorithm SHA256).Hash
$hosts=Join-Path $env:windir 'System32\drivers\etc\hosts';$plan=Get-OpenWebMeetHostsPlan ([IO.File]::ReadAllBytes($hosts))
$snapshotRecord=Get-Content -LiteralPath $snapshot -Raw|ConvertFrom-Json
$ledger=[ordered]@{Schema=1;Complete=$false;Thumbprint=$certificate.Thumbprint;Certificate=[Convert]::ToBase64String($certificate.RawData);OwnedTrust=($certificate.Thumbprint -notin @($snapshotRecord.RootThumbprints) -or ($old -and $old.OwnedTrust -and $old.Thumbprint -ceq $certificate.Thumbprint));HostsLine=$plan.AddedLine;Products=@();WebConfigBeforeHash=$webBeforeHash;WebConfigHash=$webAfterHash}
Write-OpenWebPrivateState -Path $ledgerPath -Value $ledger
$meetingPhase='websockets';$meetingCommandExit=$null
try{
 $feature=Install-WindowsFeature Web-WebSockets
 if(!$feature.Success -or $feature.RestartNeeded -eq 'Yes'){throw 'Restart Windows to finish enabling meeting WebSockets, then repeat installation.'}
 $packages=@(
  @{Kind='Rewrite';Order=1;Path="$env:windir\System32\inetsrv\rewrite.dll";Name='rewrite_amd64_en-US.msi';Url='https://download.microsoft.com/download/1/2/8/128E2E22-C1B9-44A4-BE2A-5859ED1D4592/rewrite_amd64_en-US.msi';Sha='37342ff2f585f263f34f48e9de59eb1051d61015a8e967dbde4075716230a32a'},
  @{Kind='Arr';Order=2;Path="$env:ProgramFiles\IIS\Application Request Routing\requestRouter.dll";Name='requestRouter_amd64.msi';Url='https://download.microsoft.com/download/E/9/8/E9849D6A-020E-47E4-9FD0-A023E99B54EB/requestRouter_amd64.msi';Sha='fb61fdb7101795a34d5129cb37eee43ab675c7ed76ba3a3b23b039d8c90c2a4b'}
 )
 foreach($package in $packages){
  if(Test-Path -LiteralPath $package.Path){$signature=Get-AuthenticodeSignature -LiteralPath $package.Path;if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)'){throw 'An existing IIS extension needs administrator review.'};continue}
  $meetingPhase=$package.Kind.ToLowerInvariant()+'_download';$meetingCommandExit=$null
  $file=Join-Path $directory $package.Name;$null=Assert-OpenWebMeetOrdinary $file
  if(!(Test-Path -LiteralPath $file)){Invoke-WebRequest -UseBasicParsing -Uri $package.Url -OutFile $file}
  if((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -cne $package.Sha){throw 'A Microsoft meeting prerequisite failed exact download verification.'}
  $meetingPhase=$package.Kind.ToLowerInvariant()+'_signature'
  $signature=Get-AuthenticodeSignature -LiteralPath $file
  if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)'){throw 'A Microsoft meeting prerequisite failed signature verification.'}
  $meetingPhase=$package.Kind.ToLowerInvariant()+'_identity'
  $installer=New-Object -ComObject WindowsInstaller.Installer;$database=$installer.OpenDatabase($file,0);$view=$database.OpenView('SELECT `Value` FROM `Property` WHERE `Property`=''ProductCode''');$view.Execute();$product=$view.Fetch().StringData(1);$view.Close()
  if($product -cnotmatch '^\{[A-F0-9-]{36}\}$'){throw 'The meeting prerequisite has an invalid product identity.'}
  $ledger.Products+=@{Kind=$package.Kind;Order=$package.Order;Introduced=$true;ProductCode=$product};Write-OpenWebPrivateState -Path $ledgerPath -Value $ledger
  $meetingPhase=$package.Kind.ToLowerInvariant()+'_install'
  $process=Start-Process msiexec.exe -ArgumentList @('/i',$file,'/qn','/norestart') -Wait -PassThru;$meetingCommandExit=[int]$process.ExitCode
  if($process.ExitCode -ne 0 -or !(Test-Path -LiteralPath $package.Path)){throw 'The Microsoft meeting prerequisite could not be installed without restarting Windows.'}
 }
 $meetingPhase='trust';$meetingCommandExit=$null
 $store=[Security.Cryptography.X509Certificates.X509Store]::new('Root','LocalMachine');$store.Open('ReadWrite');try{if(!($store.Certificates|Where-Object Thumbprint -ceq $certificate.Thumbprint)){$store.Add($certificate)}}finally{$store.Close()}
 $meetingPhase='hosts'
 if($plan.Changed){if([Convert]::ToBase64String([IO.File]::ReadAllBytes($hosts)) -cne $snapshotRecord.Hosts){throw 'The hosts file changed during meeting installation.'};[IO.File]::WriteAllBytes($hosts,$plan.Bytes)}
 $meetingPhase='strict_flags'
 $reg='HKLM:\SOFTWARE\Microsoft\IIS Extensions\Application Request Routing\Parameters';New-Item -Path $reg -Force|Out-Null;New-ItemProperty -Path $reg -Name SecureConnectionIgnoreFlags -Value 0 -PropertyType DWord -Force|Out-Null
 $meetingPhase='proxy'
 $proxyState=Get-OpenWebMeetProxyXmlState
 $manager=[Microsoft.Web.Administration.ServerManager]::new()
 try{
  $site=$manager.Sites['OpenWebPBX'];if(!$site -or [IO.Path]::GetFullPath($site.Applications['/'].VirtualDirectories['/'].PhysicalPath).TrimEnd('\') -cne "$root\web"){throw 'The owned PBX IIS site is required.'}
  $proxy=$manager.GetApplicationHostConfiguration().GetSection('system.webServer/proxy');if([bool]$proxy['preserveHostHeader']){throw 'The IIS backend host policy changed during installation.'}
  $ledger.ProxyBeforeXml=$proxyState.Xml;$ledger.ProxyEnabledBeforePresent=$proxyState.EnabledPresent;$ledger.ProxyEnabledBefore=$proxyState.Enabled;$ledger.ProxyAfterXml=Get-OpenWebMeetEnabledProxyXml $proxyState
  Write-OpenWebPrivateState -Path $ledgerPath -Value $ledger
  if((Get-OpenWebMeetProxyXmlState).ConfigurationSha256 -cne $proxyState.ConfigurationSha256){throw 'The IIS configuration changed before enabling meetings.'}
  $proxy['enabled']=$true;$manager.CommitChanges()
  if((Get-OpenWebMeetProxyXmlState).Xml -cne $ledger.ProxyAfterXml){throw 'The IIS proxy section changed while enabling meetings.'}
  $pool=$manager.ApplicationPools['OpenWebPBX'];if($pool -and $pool.State -eq 'Started'){$null=$pool.Recycle()}
 }finally{$manager.Dispose()}
 $meetingPhase='web_config'
 if((Get-FileHash -LiteralPath $web -Algorithm SHA256).Hash -cne $webBeforeHash){throw 'The PBX IIS configuration changed during meeting installation.'}
 if(!$RebindRestoredTransport){[IO.File]::WriteAllBytes($web,$webAfter)}
 Assert-OpenWebMeetWebSocket
 $meetingPhase='complete_ledger'
 $ledger.WebConfigHash=(Get-FileHash -LiteralPath $web -Algorithm SHA256).Hash;$ledger.Complete=$true;Write-OpenWebPrivateState -Path $ledgerPath -Value $ledger
 $meetingPhase='helper_copy'
 New-Item -ItemType Directory -Path "$root\tools" -Force|Out-Null
 foreach($name in 'Meet-Proxy.ps1','Install-Meet.ps1','Write-PrivateState.ps1','check-meet.php'){$source=Join-Path $PackageRoot $name;$target=Join-Path "$root\tools" $name;if([IO.Path]::GetFullPath($source) -ine [IO.Path]::GetFullPath($target)){Copy-Item -LiteralPath $source -Destination $target -Force}}
 $meetingPhase='previous_trust'
 if($RebindRestoredTransport -and $old.OwnedTrust -and $old.Thumbprint -cne $certificate.Thumbprint){
  $oldPath='Cert:\LocalMachine\Root\'+$old.Thumbprint
  if(Test-Path -LiteralPath $oldPath){$oldCertificate=Get-Item -LiteralPath $oldPath;if([Convert]::ToBase64String($oldCertificate.RawData) -cne $old.Certificate){throw 'The previous owned meeting trust changed during restore.'};Remove-Item -LiteralPath $oldPath -Force}
 }
 Write-Host 'The encrypted private meeting WebSocket transport is installed.'
}catch{
 $failure=$_
 $diagnostic=Get-OpenWebMeetFailure $failure $meetingPhase $meetingCommandExit
 $script:OpenWebMeetRecoveryPhase='recovery_web_config'
 try{
  $currentHash=(Get-FileHash -LiteralPath $web -Algorithm SHA256).Hash
  if($currentHash -cne $webBeforeHash -and $currentHash -cne $webAfterHash){throw 'The PBX IIS configuration changed before recovery.'}
  if($currentHash -ceq $webAfterHash){[IO.File]::WriteAllBytes($web,$webBefore)}
  Restore-OpenWebMeetSystem -Snapshot $snapshot -StateRoot $state
  $script:OpenWebMeetRecoveryPhase='recovery_ledger'
  if($null -eq $ledgerBefore){Remove-Item -LiteralPath $ledgerPath -Force}else{[IO.File]::WriteAllBytes($ledgerPath,$ledgerBefore)}
 }catch{
  $exception=[InvalidOperationException]::new('Meeting installation failed and needs administrator recovery; its private recovery snapshot was retained.')
  $exception.Data['meeting_failure']=$diagnostic;$exception.Data['meeting_recovery_failure']=Get-OpenWebMeetFailure $_ $script:OpenWebMeetRecoveryPhase
  throw $exception
 }
 $failure.Exception.Data['meeting_failure']=$diagnostic
 throw $failure
}
