# Actual source/CLR file observation and closed-field controls; no PBX accessed.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$count=0
function Check([bool]$Value){if(!$Value){throw ('Lock observer control failed at '+(@(Get-PSCallStack)[1].ScriptLineNumber))};$script:count++}
. (Join-Path $SourceRoot 'tests/windows-upgrade-lock-observer.ps1')
Initialize-OpenWebLockObserverNative
if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){
 $argv=@(Get-OpenWebLockArguments '"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -File "C:\OpenWebPBX\tools\Upgrade-OpenWebPBX.ps1" -Recover "PRIVATE spaced argument"')
 Check ($argv.Count -eq 5 -and $argv[2] -ceq 'C:\OpenWebPBX\tools\Upgrade-OpenWebPBX.ps1' -and $argv[3] -ceq '-Recover' -and $argv[4] -ceq 'PRIVATE spaced argument')
}
$nativeSource=Get-Content (Join-Path $SourceRoot 'tests/windows-upgrade-lock-observer.ps1') -Raw
Check ($nativeSource.Contains('RmGetList(session,out needed,ref count,apps,ref reasons)') -and $nativeSource.Contains('new ProcessInfo[32]'))
Check (!$nativeSource.Contains('RmShutdown') -and !$nativeSource.Contains('RmRestart') -and $nativeSource.Contains("::Open(`$Path,'Open','ReadWrite','None')") -and !$nativeSource.Contains("::Open(`$Path,'OpenOrCreate'"))
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('openweb-lock-observer-'+[Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $testRoot)
$priorProgramData=$env:ProgramData;$priorSystemRoot=$env:SystemRoot
try{
 $env:ProgramData=$testRoot;$env:SystemRoot=Join-Path $testRoot 'Windows'
 $state=Join-Path $testRoot 'OpenWebPBX';$evidence=Join-Path $testRoot 'private'
 [void](New-Item -ItemType Directory -Path (Join-Path $state 'updates'),$evidence)
 $lockPath=Join-Path $state 'upgrade.lock';$initial=[byte[]]@(19,81,7,255)
 [IO.File]::WriteAllBytes($lockPath,$initial)
 $observed=Read-OpenWebLockProbe $lockPath
 Check ($observed.lock_probe_result -ceq 'available' -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($lockPath)) -ceq [Convert]::ToBase64String($initial))
 $held=[IO.File]::Open($lockPath,'Open','ReadWrite','None')
 try{$sharing=Read-OpenWebLockProbe $lockPath;Check ($sharing.lock_probe_result -cne 'available' -and $sharing.lock_probe_hresult -cmatch '^[0-9a-f]{8}$');if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT){Check ($sharing.lock_probe_result -ceq 'sharing_violation' -and $sharing.lock_probe_hresult -ceq '80070020')}}finally{$held.Dispose()}
 Check ((Read-OpenWebLockProbe $lockPath).lock_probe_result -ceq 'available')
 $missing=Join-Path $state 'missing.lock';$observed=Read-OpenWebLockProbe $missing
 Check (!(Test-Path -LiteralPath $missing) -and $observed.lock_probe_result -cne 'available')
 foreach($entry in @(@(32,'sharing_violation'),@(33,'lock_violation'),@(2,'missing'),@(3,'missing'),@(5,'access_denied'),@(87,'other_io'))){
  $failure=[IO.IOException]::new('PRIVATE_PATH_PASSWORD',[int]([long]-2147024896+$entry[0]))
  $observed=Get-OpenWebLockError $failure
  Check ($observed.lock_probe_result -ceq $entry[1] -and $observed.lock_probe_hresult -cmatch '^[0-9a-f]{8}$')
  Check (($observed|ConvertTo-Json) -notmatch 'PRIVATE_')
 }
 $script:service=[pscustomobject]@{State='Running';ProcessId=1234}
 $script:started=[DateTime]::UtcNow.AddMinutes(-1).ToFileTimeUtc();$script:holders=@();$script:rmCode=0;$script:overLimit=$false;$script:rmCalls=0
 $script:processes=@{};$script:tokens=@();$script:queryCount=0
 function Get-CimInstance([string]$ClassName,[string]$Filter){
  if($ClassName -ceq 'Win32_Service' -and $Filter -ceq "Name='OpenWebPBXUpdater'"){return $script:service}
  if($ClassName -ceq 'Win32_Process' -and $Filter -cmatch '^ProcessId=([0-9]+)$'){$script:queryCount++;return $script:processes[[int]$Matches[1]]}
  throw 'A foreign CIM query is forbidden.'
 }
 function Get-Process([int]$Id){if($Id -eq 1234){return [pscustomobject]@{StartTime=[DateTime]::FromFileTimeUtc($script:started)}};$item=$script:processes[$Id];if(!$item){throw 'No controlled process.'};return [pscustomobject]@{StartTime=[DateTime]::FromFileTimeUtc($item.ObservedStarted)}}
 function Get-OpenWebLockHolders([string]$Path){if($Path -cne $lockPath){throw 'A foreign resource must never reach Restart Manager.'};$script:rmCalls++;return [pscustomobject]@{Code=$script:rmCode;OverLimit=$script:overLimit;Holders=$script:holders}}
 function Get-OpenWebLockArguments([string]$Command){if($Command -cne 'PRIVATE_COMMAND'){throw 'Only the controlled argument vector may be decoded.'};return $script:tokens}
 $generation=Get-OpenWebUpdaterGeneration $null
 Check ($generation.observed -and $generation.id -eq 1234 -and $generation.started -eq $script:started -and !$generation.stopped)
 $generation.stopped=$true;$generation.stopped_at=[DateTime]::UtcNow.ToFileTimeUtc();$script:service=[pscustomobject]@{State='Stopped';ProcessId=0}
 Check ([object]::ReferenceEquals((Get-OpenWebUpdaterGeneration $generation),$generation))
 $journal=Join-Path $state 'updates/install-journal.json'
 [IO.File]::WriteAllText($journal,'{"state":"completed","PRIVATE_KEY":"PRIVATE_VALUE"}')
 $worker=Join-Path $state 'updates/worker-journal.json'
 [IO.File]::WriteAllText($worker,'{"state":"PRIVATE_SECRET_STATE"}')
 $safe=Get-OpenWebUpgradeLockObservation $state $evidence $generation
 Check ($safe.lock_restart_manager -ceq 'observed' -and $safe.lock_holder_count -eq 0 -and $safe.lock_updater_state -ceq 'Stopped')
 Check ($safe.lock_install_journal_state -ceq 'completed' -and $safe.lock_worker_journal_state -ceq 'other')
 Check (($safe|ConvertTo-Json -Depth 10) -notmatch 'PRIVATE_|1234|ProcessId|CommandLine')
 $childStarted=$script:started+10000L;$powershell=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
 $process=[pscustomobject]@{ProcessId=4321;ParentProcessId=1234;ExecutablePath=$powershell;CommandLine='PRIVATE_COMMAND';ObservedStarted=$childStarted;CreationDate='PRIVATE_CREATED'}
 $script:tokens=@($powershell,'-NoProfile','-File','C:\OpenWebPBX\tools\Upgrade-OpenWebPBX.ps1','-Recover')
 $script:processes[4321]=$process;$script:holders=@([pscustomobject]@{Id=4321;Started=$childStarted})
 $safe=Get-OpenWebUpgradeLockObservation $state $evidence $generation
 Check ($safe.lock_holder_count -eq 1 -and $safe.lock_holder_identity_verified_count -eq 1 -and $safe.lock_holder_updater_child_count -eq 1)
 Check (($safe.lock_holder_kinds -join '|') -ceq 'powershell' -and ($safe.lock_holder_actions -join '|') -ceq 'recover')
 Check (($safe|ConvertTo-Json -Depth 10) -notmatch 'PRIVATE_|4321|1234|C:|CommandLine|ProcessId')
 foreach($parameters in @(@('-Check'),@('-Archive','PRIVATE_ARCHIVE'),@())){
  $script:tokens=@($powershell,'-File','C:\OpenWebPBX\tools\Upgrade-OpenWebPBX.ps1')+$parameters
  $observed=Get-OpenWebLockProcessFacts $process $true $generation $childStarted $evidence
  $expected=if($parameters -contains '-Check'){'check'}elseif($parameters -contains '-Archive'){'signed_install'}else{'direct_reapply'}
  Check ($observed.action -ceq $expected)
 }
 $script:tokens=@($powershell,'-File','C:\PRIVATE\Upgrade-OpenWebPBX.ps1','-Recover')
 Check ((Get-OpenWebLockProcessFacts $process $true $generation $childStarted $evidence).action -ceq 'other')
 $script:tokens=@($powershell,'-File','C:\OpenWebPBX\tools\Upgrade-OpenWebPBX.ps1','PRIVATE_-Recover')
 Check ((Get-OpenWebLockProcessFacts $process $true $generation $childStarted $evidence).action -ceq 'direct_reapply')
 $process.ObservedStarted++
 $safe=Get-OpenWebUpgradeLockObservation $state $evidence $generation
 Check ($safe.lock_holder_identity_verified_count -eq 0 -and $safe.lock_holder_updater_child_count -eq 0 -and ($safe.lock_holder_kinds -join '|') -ceq 'other')
 $process.ObservedStarted=$childStarted;$process.ParentProcessId=9999
 Check (!(Get-OpenWebLockProcessFacts $process $true $generation $childStarted $evidence).parent_matches_stopped_updater)
 $process.ParentProcessId=1234
 Check (!(Get-OpenWebLockProcessFacts $process $true $generation ($generation.stopped_at+1) $evidence).parent_matches_stopped_updater)
 $script:overLimit=$true;$script:holders=@();$beforeQueries=$script:queryCount
 $safe=Get-OpenWebUpgradeLockObservation $state $evidence $generation
 Check ($safe.lock_restart_manager -ceq 'more_than_32' -and $script:queryCount -eq $beforeQueries -and !$safe.ContainsKey('lock_holder_count'))
 $script:overLimit=$false;$script:rmCode=234
 $safe=Get-OpenWebUpgradeLockObservation $state $evidence $generation
 Check ($safe.lock_restart_manager -ceq 'failed' -and !$safe.ContainsKey('lock_holder_count'))
 $beforeCalls=$script:rmCalls
 $safe=Get-OpenWebUpgradeLockObservation (Join-Path $state 'foreign') $evidence $generation
 Check ($safe.lock_observer_failed -and $script:rmCalls -eq $beforeCalls)
 $good=[pscustomobject]@{lock_observer_schema=[long]1;lock_probe_result='sharing_violation';lock_probe_hresult='80070020';lock_restart_manager='observed';lock_holder_count=[long]1;lock_holder_identity_verified_count=1;lock_holder_updater_child_count=1;lock_holder_kinds=@('powershell');lock_holder_actions=@('recover');lock_updater_state='Stopped';lock_updater_generation_captured=$true;lock_updater_stopped_generation=$true;lock_install_journal_state='absent';lock_worker_journal_state='checking';raw='PRIVATE_PASSWORD';id=1234}
 $safe=SafeOpenWebUpgradeLockFields $good
 Check ($safe.lock_holder_count -eq 1 -and ($safe.lock_holder_actions -join '|') -ceq 'recover' -and (($safe|ConvertTo-Json -Depth 10) -notmatch 'PRIVATE_|1234|"id"'))
 foreach($field in 'lock_probe_result','lock_restart_manager','lock_updater_state','lock_install_journal_state','lock_worker_journal_state'){$copy=$good.PSObject.Copy();$copy.$field='PRIVATE_SECRET';Check (!(SafeOpenWebUpgradeLockFields $copy).ContainsKey($field))}
 foreach($field in 'lock_holder_count','lock_holder_identity_verified_count','lock_holder_updater_child_count'){
  foreach($bad in -1,33,'1',$true,1.5,[double]::NaN){$copy=$good.PSObject.Copy();$copy.$field=$bad;Check (!(SafeOpenWebUpgradeLockFields $copy).ContainsKey($field))}
 }
 foreach($field in 'lock_updater_generation_captured','lock_updater_stopped_generation','lock_observer_failed'){$copy=$good.PSObject.Copy();$copy|Add-Member -Force NoteProperty $field 'PRIVATE_SECRET';Check (!(SafeOpenWebUpgradeLockFields $copy).ContainsKey($field))}
 foreach($bad in 'PRIVATE_SECRET','80070020 PRIVATE_SECRET','C:/secret','8007002','800700200'){$copy=$good.PSObject.Copy();$copy.lock_probe_hresult=$bad;Check (!(SafeOpenWebUpgradeLockFields $copy).ContainsKey('lock_probe_hresult'))}
 foreach($field in 'lock_holder_kinds','lock_holder_actions'){$copy=$good.PSObject.Copy();$copy.$field=@('PRIVATE_SECRET','PRIVATE_SECRET');Check (@((SafeOpenWebUpgradeLockFields $copy)[$field]).Count -eq 0)}
 foreach($bad in '1',$true,0,2){$copy=$good.PSObject.Copy();$copy.lock_observer_schema=$bad;Check ((SafeOpenWebUpgradeLockFields $copy).Count -eq 0)}
 $tokens=$null;$errors=$null;$suite=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-suite.ps1'),[ref]$tokens,[ref]$errors)
 Check ($errors.Count -eq 0)
 foreach($node in $suite.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -like 'Safe*'},$true)){Invoke-Expression $node.Extent.Text}
 $safe=SafeFailureFields $good
 Check ($safe.lock_probe_result -ceq 'sharing_violation' -and $safe.lock_holder_count -eq 1 -and (($safe|ConvertTo-Json -Depth 10) -notmatch 'PRIVATE_|1234'))
 $hook=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-upgrade-acceptance.ps1'),[ref]$tokens,[ref]$errors)
 Check ($errors.Count -eq 0)
 $stop=@($hook.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'StopUpdater'},$true))
 Check ($stop.Count -eq 1 -and $stop[0].Extent.Text.IndexOf('Get-OpenWebUpdaterGeneration') -lt $stop[0].Extent.Text.IndexOf('Stop-Service'))
 $failure=@($hook.FindAll({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.StartsWith("if(`$checkFailure.active_case -ceq 'direct_reapply_preflight'){")},$true))
 Check ($failure.Count -eq 1 -and $failure[0].Extent.Text.Contains('Get-OpenWebUpgradeLockObservation'))
 Check ($suite.Extent.Text.Contains("throw 'An owned transaction is still running; cleanup must not interrupt it.'"))
 Check ([Convert]::ToBase64String([IO.File]::ReadAllBytes($lockPath)) -ceq [Convert]::ToBase64String($initial))
 Check (@(Get-ChildItem -LiteralPath $evidence -Filter 'lock-observer-*-private.json').Count -gt 0)
}finally{
 $env:ProgramData=$priorProgramData;$env:SystemRoot=$priorSystemRoot
 Remove-Item -LiteralPath $testRoot -Recurse -Force
}
Write-Output ('PASS '+$count+' actual source/CLR noncreating-file/closed-field/controlled-OS-boundary lock observer checks; no PBX accessed')
