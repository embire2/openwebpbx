#Requires -RunAsAdministrator
# SPDX-License-Identifier: AGPL-3.0-or-later
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$PackageRoot,[switch]$DeferStart,[IO.FileStream]$MaintenanceLock)
$ErrorActionPreference='Stop';$root='C:\OpenWebPBX';$state=Join-Path $env:ProgramData 'OpenWebPBX';$lockPath=Join-Path $state 'upgrade.lock'
$owned=$null -eq $MaintenanceLock;$lock=$MaintenanceLock
if($owned){$lock=[IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite','None')}
try{
 if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or !$lock.CanRead -or !$lock.CanWrite -or [IO.Path]::GetFullPath($lock.Name) -ne [IO.Path]::GetFullPath($lockPath)){throw 'The owned Windows maintenance lock is required.'}
 . (Join-Path $PSScriptRoot 'PublicAccess.Common.ps1')
 $null=Assert-OpenWebOrdinaryPath (Join-Path $root 'tools') $true
 $manifest=Get-Content -LiteralPath (Join-Path $PackageRoot 'release-manifest.json') -Raw|ConvertFrom-Json
 foreach($name in 'onboarding.py','onboarding.php','webhotel-onboarding.py','Install-Onboarding.ps1','Ensure-OnboardingUpgrade.ps1','Onboarding-Upgrade.Common.ps1'){
  $source=Join-Path $PackageRoot $name;$null=Assert-OpenWebOrdinaryPath $source
  if((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -cne $manifest.files.$name){throw 'An onboarding helper differs from the verified Windows release.'}
  $target=Join-Path "$root\tools" $name;if(Test-Path -LiteralPath $target){$null=Assert-OpenWebOrdinaryPath $target}
  Copy-Item -LiteralPath $source -Destination $target -Force
 }
 $name='OpenWebPBX-Onboarding';$description='OpenWeb PBX owned installation registration and activation worker'
 $execute="$root\backup-runtime\python.exe";$arguments='-I -B "C:\OpenWebPBX\tools\onboarding.py" --tick'
 $existing=Get-ScheduledTask -TaskName $name -TaskPath '\' -ErrorAction SilentlyContinue
 if($existing -and ($existing.Description -cne $description -or $existing.Principal.UserId -notin 'SYSTEM','S-1-5-18' -or $existing.Principal.LogonType -ne 'ServiceAccount' -or @($existing.Actions).Count -ne 1 -or $existing.Actions[0].Execute -cne $execute -or $existing.Actions[0].Arguments -cne $arguments -or $existing.Actions[0].WorkingDirectory -cne "$root\tools")){throw 'The onboarding task belongs to another configuration.'}
 $action=New-ScheduledTaskAction -Execute $execute -Argument $arguments -WorkingDirectory "$root\tools"
 $triggers=@((New-ScheduledTaskTrigger -AtStartup),(New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval ([TimeSpan]::FromMinutes(1))))
 $triggers[1].Repetition.StopAtDurationEnd=$false
 $principal=New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
 $settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::FromMinutes(20))
 $preserved=$null
 if($existing){
  [xml]$xml=Export-ScheduledTask -TaskName $name -TaskPath '\';$ns=[Xml.XmlNamespaceManager]::new($xml.NameTable);$ns.AddNamespace('t','http://schemas.microsoft.com/windows/2004/02/mit/task');$source=$xml.SelectSingleNode('/t:Task/t:RegistrationInfo/t:Source',$ns)
  if($source -and $source.InnerText.StartsWith('openwebpbx-onboarding-v1:',[StringComparison]::Ordinal)){
   . (Join-Path $PSScriptRoot 'Onboarding-Upgrade.Common.ps1')
   $null=Assert-OpenWebOnboardingTaskSnapshot (Get-OpenWebOnboardingTaskSnapshot) $root
   $boundary=$xml.SelectSingleNode('/t:Task/t:Triggers/t:TimeTrigger/t:StartBoundary',$ns);$boundary.InnerText=(Get-Date).AddMinutes(1).ToString("yyyy-MM-dd'T'HH:mm:ss",[Globalization.CultureInfo]::InvariantCulture);$preserved=$xml.OuterXml
  }
 }
 if($preserved){Register-ScheduledTask -TaskName $name -TaskPath '\' -Xml $preserved -Force|Out-Null}
 else{Register-ScheduledTask -TaskName $name -TaskPath '\' -Description $description -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Force|Out-Null}
 if($DeferStart -or ($existing -and !$existing.Settings.Enabled)){Disable-ScheduledTask -TaskName $name -TaskPath '\'|Out-Null}
 # Installers enable the owned task after committing and releasing the lock.
 # The worker independently checks upgrade/restore holds before local changes.
}finally{if($owned -and $lock){$lock.Dispose()}}
