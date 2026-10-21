# QA only: exact owned lock holders and readiness after an original restore error.
param([Parameter(Mandatory)][string]$PrivateDirectory,[switch]$DisposableHostedRunner)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if(!$DisposableHostedRunner -or $env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:RUNNER_OS -cne 'Windows' -or $env:GITHUB_REPOSITORY -cne 'embire2/openwebpbx'){throw 'Explicit disposable hosted Windows observer required.'}
$state=Join-Path $env:ProgramData 'OpenWebPBX'
if([IO.Path]::GetFullPath($PrivateDirectory) -ine [IO.Path]::GetFullPath((Join-Path $state 'backup-qualification'))){throw 'Only the exact existing private backup evidence is observable.'}
foreach($path in $PrivateDirectory,$state){$item=Get-Item -LiteralPath $path -Force;if(!$item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Ordinary private observer directories required.'}}
. (Join-Path $PSScriptRoot 'windows-upgrade-lock-observer.ps1')
$safe=[ordered]@{observed=$true;health_observed=$false;local_running=$false;version_matches=$false;iis_login_ready=$false;known_recover_holder=$false;holder_count=0;verified_holder_count=0;updater_state='unknown'}
try{
 $lock=Get-OpenWebUpgradeLockObservation $state $PrivateDirectory $null
 if($lock.lock_updater_state -is [string] -and $lock.lock_updater_state -cin 'unknown','Stopped','Running','Start Pending','Stop Pending','Paused','Continue Pending','Pause Pending'){$safe.updater_state=$lock.lock_updater_state}
 if(($lock.lock_holder_count -is [int] -or $lock.lock_holder_count -is [long]) -and $lock.lock_holder_count -ge 0 -and $lock.lock_holder_count -le 32){$safe.holder_count=[int]$lock.lock_holder_count}
 if(($lock.lock_holder_identity_verified_count -is [int] -or $lock.lock_holder_identity_verified_count -is [long]) -and $lock.lock_holder_identity_verified_count -ge 0 -and $lock.lock_holder_identity_verified_count -le $safe.holder_count){$safe.verified_holder_count=[int]$lock.lock_holder_identity_verified_count}
 $safe.known_recover_holder=$safe.verified_holder_count -gt 0 -and @($lock.lock_holder_actions) -ccontains 'recover'
}catch{}
try{
 $installation=Get-Content -LiteralPath (Join-Path $state 'installation.json') -Raw|ConvertFrom-Json
 if($installation.DomainName -cne 'windowsqa.example.invalid' -or $installation.HttpsPort -ne 8443 -or $installation.Version -cnotmatch '^1\.0\.[0-9]+$'){throw 'The owned factory installation identity is required.'}
 $health=Invoke-RestMethod -Uri 'http://127.0.0.1:8087/health' -TimeoutSec 3 -MaximumRedirection 0
 $safe.health_observed=$health.state -is [string] -and $health.version -is [string]
 $safe.local_running=$health.state -is [string] -and $health.state -ceq 'Running'
 $safe.version_matches=$health.version -is [string] -and $health.version -ceq $installation.Version
 . 'C:\OpenWebPBX\tools\Web-Readiness.ps1'
 $answer=@(Test-OpenWebTrustedLogin $installation.DomainName $installation.HttpsPort)
 $safe.iis_login_ready=$answer.Count -eq 1 -and $answer[0] -is [bool] -and $answer[0]
}catch{}
$safe|ConvertTo-Json -Depth 5 -Compress
