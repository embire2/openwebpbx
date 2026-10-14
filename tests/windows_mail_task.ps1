#Requires -Version 7.4
# SPDX-License-Identifier: AGPL-3.0-or-later
# Portable control-flow qualification. Actual task/NTFS/SMTP proof is separate.
$ErrorActionPreference='Stop'
$source=Split-Path $PSScriptRoot -Parent;$work=Join-Path ([IO.Path]::GetTempPath()) ('ow-mail-task-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work|Out-Null
$root=Join-Path $work 'program';$state=Join-Path $work 'state';$tools=Join-Path $work 'tools'
foreach($p in $root,$state,$tools,(Join-Path $state 'updates'),(Join-Path $state 'backup-restore')){New-Item -ItemType Directory -Force -Path $p|Out-Null}
$helper=Join-Path $tools 'Install-MailQueue.ps1'
$text=[IO.File]::ReadAllText((Join-Path $source 'packaging/windows/Install-MailQueue.ps1'))
$text=$text.Replace('#Requires -RunAsAdministrator','')
$text=$text.Replace("`$root='C:\OpenWebPBX';`$state=Join-Path `$env:ProgramData 'OpenWebPBX'",("`$root='"+$root+"';`$state='"+$state+"'"))
$text=$text.Replace("if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'Windows is required.'}",'')
$text=$text.Replace('& "$root\php\php.exe" (Join-Path $PSScriptRoot ''process-mail.php'') "$root\web"','Invoke-FixtureDispatch')
[IO.File]::WriteAllText($helper,$text,[Text.UTF8Encoding]::new($false));Copy-Item (Join-Path $source 'packaging/windows/Restore-Gates.ps1') $tools
$global:dispatches=0;$global:observedEnvironment=$null;$count=0
function Invoke-FixtureDispatch {$global:dispatches++;$global:observedEnvironment=$env:OPENSSL_CONF;$global:LASTEXITCODE=0;'{"configured":false,"attempts_consumed":0}'}
function Check([bool]$Value){if(!$Value){throw 'Mail task control fixture failed.'};$script:count++}
function Refused {try{& $helper -Tick|Out-Null;return $false}catch{return $true}}
$environmentBefore=$env:OPENSSL_CONF
try{
 Check (Refused)
 '{"Completed":false}'|Set-Content (Join-Path $state 'installation.json');Check (Refused)
 '{"Completed":true}'|Set-Content (Join-Path $state 'installation.json')
 $lock=[IO.File]::Open((Join-Path $state 'upgrade.lock'),'OpenOrCreate','ReadWrite','None')
 try{$result=& $helper -Tick|ConvertFrom-Json;Check ($result.deferred -and $result.reason -eq 'maintenance');Check ($global:dispatches -eq 0)}finally{$lock.Dispose()}
 foreach($name in 'calls','jobs','updates','backups'){
  $path=Join-Path $state ('backup-restore/hold-'+$name);[IO.File]::WriteAllText($path,'owned test')
  $result=& $helper -Tick|ConvertFrom-Json;Check ($result.deferred -and $result.reason -eq 'restore');Check ($global:dispatches -eq 0);Remove-Item $path
 }
 foreach($phase in 'prepared','quiescing','deploying','migrating','validating','recovery_required'){
  @{state=$phase}|ConvertTo-Json|Set-Content (Join-Path $state 'updates/install-journal.json');Check (Refused);Check ($global:dispatches -eq 0)
 }
 foreach($phase in 'completed','rolled_back'){
  @{state=$phase}|ConvertTo-Json|Set-Content (Join-Path $state 'updates/install-journal.json');$before=$global:dispatches
  $result=& $helper -Tick|ConvertFrom-Json;Check ($global:dispatches -eq $before+1 -and $result.attempts_consumed -eq 0)
  Check ($global:observedEnvironment -eq (Join-Path $root 'php/extras/ssl/openssl.cnf'));Check ($env:OPENSSL_CONF -eq $environmentBefore)
 }
 Check ([IO.File]::ReadAllText((Join-Path $source 'packaging/windows/Install-MailQueue.ps1')).Contains('Disable-ScheduledTask -TaskName $name'))
 Write-Host "PASS $count mail maintenance/completion/restore control checks; dispatcher/task/NTFS are mocked and native proof remains separate."
}finally{Remove-Item -LiteralPath $work -Recurse -Force;if($null -eq $environmentBefore){Remove-Item Env:\OPENSSL_CONF -ErrorAction SilentlyContinue}else{$env:OPENSSL_CONF=$environmentBefore}}
