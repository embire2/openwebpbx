#Requires -RunAsAdministrator
# Called before the tenant worker takes its own upgrade.lock; no nested lock.
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$root='C:\OpenWebPBX';$state=Join-Path $env:ProgramData 'OpenWebPBX';$lock=$null
try{
 if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'Windows is required.'}
 try{$lock=[IO.File]::Open((Join-Path $state 'upgrade.lock'),'Open','ReadWrite','None')}catch{
  $native=$_.Exception.GetBaseException()
  if($native -is [IO.IOException] -and ($native.HResult -band 65535) -in 32,33){@{state='deferred';reason='maintenance_busy'}|ConvertTo-Json -Compress;return};throw
 }
 . (Join-Path $PSScriptRoot 'UpgradeRecovery.Common.ps1');. (Join-Path $PSScriptRoot 'Restore-Gates.ps1');. (Join-Path $PSScriptRoot 'Onboarding-Upgrade.Common.ps1')
 Ensure-OpenWebCommittedOnboardingTask -Root $root -StateRoot $state -EngineRoot 'C:\Program Files\FreeSWITCH' -MaintenanceLock $lock|ConvertTo-Json -Compress
}finally{if($lock){$lock.Dispose()}}
