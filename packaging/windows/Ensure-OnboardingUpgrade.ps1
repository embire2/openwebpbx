#Requires -RunAsAdministrator
# Called before the tenant worker takes its own upgrade.lock; no nested lock.
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$root='C:\OpenWebPBX';$state=Join-Path $env:ProgramData 'OpenWebPBX';$lock=$null
try{
 if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'Windows is required.'}
 # Match the registration workers' bounded acquisition wait. Only genuine
 # native sharing/byte-lock conflicts retry; no guarded work is retried.
 $acquisitionClock=[Diagnostics.Stopwatch]::StartNew();$contended=$false
 while($null -eq $lock){
  if($contended -and $acquisitionClock.Elapsed.TotalSeconds -ge 5){@{state='deferred';reason='maintenance_busy'}|ConvertTo-Json -Compress;return}
  try{$lock=[IO.File]::Open((Join-Path $state 'upgrade.lock'),'Open','ReadWrite','None')}catch{
   $native=$_.Exception.GetBaseException()
   if($native -is [IO.IOException] -and ($native.HResult -band 65535) -in 32,33){
    $contended=$true;$remaining=5000-$acquisitionClock.Elapsed.TotalMilliseconds
    if($remaining -le 0){@{state='deferred';reason='maintenance_busy'}|ConvertTo-Json -Compress;return}
    Start-Sleep -Milliseconds ([int][Math]::Floor([Math]::Min(50,$remaining)))
   }else{throw}
  }
 }
 if($contended -and $acquisitionClock.Elapsed.TotalSeconds -ge 5){$lock.Dispose();$lock=$null;@{state='deferred';reason='maintenance_busy'}|ConvertTo-Json -Compress;return}
 $acquisitionClock.Stop()
 . (Join-Path $PSScriptRoot 'UpgradeRecovery.Common.ps1');. (Join-Path $PSScriptRoot 'Restore-Gates.ps1');. (Join-Path $PSScriptRoot 'Onboarding-Upgrade.Common.ps1')
 Ensure-OpenWebCommittedOnboardingTask -Root $root -StateRoot $state -EngineRoot 'C:\Program Files\FreeSWITCH' -MaintenanceLock $lock|ConvertTo-Json -Compress
}finally{if($lock){$lock.Dispose()}}
