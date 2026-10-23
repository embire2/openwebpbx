# Definitions only: exact credential-free projection of a one-invocation QA observation.
function NewBackupControlObservationDirectory([string]$Parent){
 $parentItem=Get-Item -LiteralPath $Parent -Force -ErrorAction Stop
 if(!$parentItem.PSIsContainer -or ($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'An ordinary existing QA evidence parent is required.'}
 $path=Join-Path $parentItem.FullName ('backup-control-observation-'+[Guid]::NewGuid().ToString('N'))
 New-Item -ItemType Directory -Path $path -ErrorAction Stop|Out-Null
 $icacls=Join-Path $env:SystemRoot 'System32\icacls.exe'
 & $icacls $path /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F'|Out-Null
 if($LASTEXITCODE){throw 'The new QA diagnostic directory ACL was refused.'}
 & $icacls $path /setowner '*S-1-5-32-544'|Out-Null
 if($LASTEXITCODE){throw 'The new QA diagnostic directory owner was refused.'}
 $acl=Get-Acl -LiteralPath $path -ErrorAction Stop
 if(!$acl.AreAccessRulesProtected -or $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cne 'S-1-5-32-544'){throw 'The new QA diagnostic directory is not protected and BA-owned.'}
 $seen=@{};foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){$sid=$rule.IdentityReference.Value;if($rule.AccessControlType -ne 'Allow' -or $sid -cnotin 'S-1-5-32-544','S-1-5-18' -or $seen.ContainsKey($sid) -or $rule.IsInherited -or $rule.FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl){throw 'The new QA diagnostic directory grants unexpected access.'};$seen[$sid]=$true}
 if($seen.Count -ne 2){throw 'The new QA diagnostic directory must have exactly its two owned grants.'}
 return $path
}
function BackupControlObservationFields($Record){
 if($null -eq $Record -or $Record -is [array]){return $null}
 $keys=@('schema','producer','operation','phase','exit_code','source_pins_verified','invocations','original_error_observed','error_type','inner_error_type','hresult','source_basename','source_line','caller_basename','caller_line')
 $actual=if($Record -is [Collections.IDictionary]){@($Record.Keys)}else{@($Record.PSObject.Properties.Name)}
 if($actual.Count -ne $keys.Count -or @($actual|Where-Object {$_ -cnotin $keys}).Count){return $null}
 if(($Record.schema -isnot [int] -and $Record.schema -isnot [long]) -or $Record.schema -ne 1 -or $Record.producer -isnot [string] -or $Record.producer -cne 'windows-backup-control-observer.ps1' -or $Record.operation -isnot [string] -or $Record.operation -cnotin 'plan','hold','recover-startup','resume-factory' -or $Record.phase -isnot [string] -or $Record.phase -cnotin 'bootstrap','operation','observer_preflight'){return $null}
 foreach($name in 'source_pins_verified','original_error_observed'){if($Record.$name -isnot [bool]){return $null}}
 foreach($limit in @(@('exit_code',-2147483648L,2147483647L),@('hresult',0L,4294967295L),@('source_line',0,999999),@('caller_line',0,999999),@('invocations',0,1))){$value=$Record.($limit[0]);if(($value -isnot [int] -and $value -isnot [long]) -or $value -lt $limit[1] -or $value -gt $limit[2]){return $null}}
 if($Record.exit_code -eq 0){return $null}
 $types=@('System.Exception','System.IO.IOException','System.IO.FileNotFoundException','System.IO.DirectoryNotFoundException','System.UnauthorizedAccessException','System.ArgumentException','System.ArgumentNullException','System.InvalidOperationException','System.FormatException','System.ComponentModel.Win32Exception','System.Security.SecurityException','System.DllNotFoundException','System.EntryPointNotFoundException','System.Management.Automation.RuntimeException','System.Management.Automation.MethodInvocationException','System.Management.Automation.ActionPreferenceStopException','System.Management.Automation.CommandNotFoundException','System.Management.Automation.ParameterBindingException','System.Management.Automation.ParameterBindingValidationException','System.Management.Automation.ItemNotFoundException','System.Management.Automation.ProviderInvocationException','Microsoft.PowerShell.Commands.ServiceCommandException','other','unavailable')
 $sources=@('Backup-Control.ps1','CallRecords.Common.ps1','UpgradeRecovery.Common.ps1','Write-PrivateState.ps1','File-Security.ps1','windows-backup-control-observer.ps1','external_component')
 if($Record.error_type -isnot [string] -or $Record.error_type -cnotin $types -or $Record.inner_error_type -isnot [string] -or $Record.inner_error_type -cnotin $types -or $Record.source_basename -isnot [string] -or $Record.source_basename -cnotin $sources -or $Record.caller_basename -isnot [string] -or $Record.caller_basename -cnotin $sources){return $null}
 if($Record.phase -ceq 'observer_preflight'){if($Record.invocations -ne 0 -or $Record.source_pins_verified -or $Record.original_error_observed){return $null}}
 elseif($Record.invocations -ne 1 -or !$Record.source_pins_verified){return $null}
 $out=@{};foreach($name in $keys){$out[$name]=$Record.$name};return $out
}
