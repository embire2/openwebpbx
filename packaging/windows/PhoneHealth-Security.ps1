# SPDX-License-Identifier: AGPL-3.0-or-later
function Get-OpenWebHealthPrivilegedSids {
 # Fresh initdb runs with a restricted token and installation explicitly
 # grants the named setup administrator access. That existing administrative
 # principal is valid; this helper does not rewrite or broaden its ACL.
 if($script:OpenWebHealthPrivilegedSids -and $script:OpenWebHealthPrivilegedUntil -gt [DateTime]::UtcNow){return ,$script:OpenWebHealthPrivilegedSids}
 $allowed=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
 foreach($sid in 'S-1-5-18','S-1-5-32-544','S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'){$null=$allowed.Add($sid)}
 # Windows Server2025 installs this under a versioned subdirectory. Import
 # only the trusted OS module root, never an unqualified PSModulePath name.
 $module=Join-Path $PSHOME 'Modules\Microsoft.PowerShell.LocalAccounts'
 Import-Module -Name $module -ErrorAction Stop
 $members=@(Microsoft.PowerShell.LocalAccounts\Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop)
 if($members.Count -gt 2000){throw 'Local administrator membership needs review.'}
 foreach($member in $members){$sid=[string]$member.SID;if($sid -notmatch '^S-1-[0-9-]+$'){throw 'Local administrator membership needs review.'};$null=$allowed.Add($sid)}
 $script:OpenWebHealthPrivilegedSids=$allowed;$script:OpenWebHealthPrivilegedUntil=[DateTime]::UtcNow.AddSeconds(30);return ,$allowed
}
function Assert-OpenWebHealthAcl($Acl,[string]$Current,[string]$Full,$Privileged){
 $owner=if($Acl.Owner -match '^S-1-'){$Acl.Owner}else{([Security.Principal.NTAccount]$Acl.Owner).Translate([Security.Principal.SecurityIdentifier]).Value}
 if(!$Privileged.Contains($owner)){throw 'Health helper ownership needs review.'}
 $write=[int][Security.AccessControl.FileSystemRights]::Delete -bor [int][Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor [int][Security.AccessControl.FileSystemRights]::ChangePermissions -bor [int][Security.AccessControl.FileSystemRights]::TakeOwnership
 $program='C:\OpenWebPBX';$state=Join-Path $env:ProgramData 'OpenWebPBX'
 if($Current.Equals($Full,[StringComparison]::OrdinalIgnoreCase) -or $Current.Equals($program,[StringComparison]::OrdinalIgnoreCase) -or $Current.StartsWith($program+'\',[StringComparison]::OrdinalIgnoreCase) -or $Current.Equals($state,[StringComparison]::OrdinalIgnoreCase) -or $Current.StartsWith($state+'\',[StringComparison]::OrdinalIgnoreCase)){$write=$write -bor [int][Security.AccessControl.FileSystemRights]::Write}
 foreach($rule in $Acl.Access){
  if($rule.AccessControlType -ne 'Allow' -or !([int]$rule.FileSystemRights -band $write)){continue}
  if($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly){continue}
  $sid=$rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
  if(!$Privileged.Contains($sid)){throw 'A non-administrator can replace a privileged health helper.'}
 }
}
function Assert-OpenWebHealthProtectedPath([string]$Path,[switch]$Directory){
 $full=[IO.Path]::GetFullPath($Path)
 if($full -notmatch '^[A-Za-z]:\\' -or $full.StartsWith('\\')){throw 'Local protected health storage is required.'}
 $item=Get-Item -LiteralPath $full -Force -ErrorAction Stop
 if([bool]$item.PSIsContainer -ne [bool]$Directory){throw 'The managed health helper is unavailable.'}
 $current=$full;$privileged=Get-OpenWebHealthPrivilegedSids
 while($current){
  $node=Get-Item -LiteralPath $current -Force -ErrorAction Stop
  if($node.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Health helper links or junctions are refused.'}
  $acl=Get-Acl -LiteralPath $current -ErrorAction Stop
  # Above the protected program root, creating an unrelated sibling cannot
  # replace this existing child. Delete-child/ACL ownership still matters.
  Assert-OpenWebHealthAcl $acl $current $full $privileged
  $parent=[IO.Path]::GetDirectoryName($current);if(!$parent -or $parent -eq $current){break};$current=$parent
 };return $full
}
function Assert-OpenWebHealthSystem {
 if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18'){throw 'The managed SYSTEM health task is required.'}
}
function Assert-OpenWebHealthTask($Task){
 if($null -eq $Task){return}
 $execute="$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe";$arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\OpenWebPBX\tools\Phone-Health.ps1"'
 if(@($Task).Count -ne 1 -or $Task.TaskName -cne 'OpenWebPBX-PhoneHealth' -or $Task.TaskPath -cne '\' -or $Task.Description -cne 'OpenWeb PBX owned phone health and Windows security observer' -or $Task.Principal.UserId -notin 'SYSTEM','S-1-5-18' -or [string]$Task.Principal.LogonType -notin 'ServiceAccount','5' -or [string]$Task.Principal.RunLevel -notin 'Highest','1' -or @($Task.Actions).Count -ne 1 -or $Task.Actions[0].Execute -ine $execute -or $Task.Actions[0].Arguments -cne $arguments -or $Task.Actions[0].WorkingDirectory -ine 'C:\OpenWebPBX\tools'){throw 'The health task belongs to another configuration.'}
}
function Stop-OpenWebHealthTask {
 param([Parameter(Mandatory)][IO.FileStream]$MaintenanceLock,[switch]$Disable)
 $path=Join-Path $env:ProgramData 'OpenWebPBX\upgrade.lock'
 if(!$MaintenanceLock.CanRead -or !$MaintenanceLock.CanWrite -or [IO.Path]::GetFullPath($MaintenanceLock.Name) -ine [IO.Path]::GetFullPath($path)){throw 'The owned maintenance lock is required before stopping health.'}
 $task=Get-ScheduledTask -TaskName 'OpenWebPBX-PhoneHealth' -ErrorAction SilentlyContinue
 Assert-OpenWebHealthTask $task
 if(!$task){return}
 if($Disable){Disable-ScheduledTask -TaskName 'OpenWebPBX-PhoneHealth' -TaskPath '\' -ErrorAction Stop|Out-Null}
 if($task.State -eq 'Running'){
  Stop-ScheduledTask -TaskName 'OpenWebPBX-PhoneHealth' -TaskPath '\' -ErrorAction Stop
  for($i=0;$i -lt 40;$i++){$current=Get-ScheduledTask -TaskName 'OpenWebPBX-PhoneHealth' -TaskPath '\' -ErrorAction Stop;Assert-OpenWebHealthTask $current;if($current.State -ne 'Running'){return};Start-Sleep -Milliseconds 250}
  throw 'The owned health task did not stop before replacing helpers.'
 }
}
