# Test-only key preparation and failure observations for the loopback SFTP receiver.
# Never return command lines, account names, configuration, key material or logs.
function Test-OpenWebSftpHostKeySecurity($OwnerSid,$Protected,[object[]]$Rules) {
 if($OwnerSid -cne 'S-1-5-18' -or $Protected -isnot [bool] -or !$Protected -or @($Rules).Count -ne 2){return $false}
 $seen=@{}
 foreach($rule in @($Rules)){
  if($rule.sid -cnotin @('S-1-5-18','S-1-5-32-544') -or $seen.ContainsKey($rule.sid)){return $false}
  if($rule.access -cne 'Allow' -or $rule.inherited -isnot [bool] -or $rule.inherited -or $rule.inheritance -isnot [int] -or $rule.inheritance -ne 0 -or $rule.propagation -isnot [int] -or $rule.propagation -ne 0){return $false}
  if($rule.rights -isnot [int64] -or $rule.rights -ne [int64][Security.AccessControl.FileSystemRights]::FullControl){return $false}
  $seen[$rule.sid]=$true
 }
 return ($seen.ContainsKey('S-1-5-18') -and $seen.ContainsKey('S-1-5-32-544'))
}
function Set-OpenWebSftpHostKeySecurity([string]$Path,[string]$OwnedDirectory) {
 if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'The fixture host key requires native Windows file security.'}
 if([IO.Path]::GetFullPath($Path) -cne [IO.Path]::GetFullPath((Join-Path $OwnedDirectory 'hostkey'))){throw 'The fixture host key has an unexpected boundary.'}
 $directory=Get-Item -LiteralPath $OwnedDirectory -Force -ErrorAction Stop;$file=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
 if(!$directory.PSIsContainer -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $file.PSIsContainer -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'The fixture host key must be an owned ordinary file.'}
 # ssh-keygen mode0600 creates an explicit creator ACE. /grant:r does not
 # remove it; SYSTEM's private-key check correctly rejects that foreign ACE.
 # Replace the owned key's entire DACL, retaining OpenSSH StrictModes checks.
 $security=[Security.AccessControl.FileSecurity]::new()
 $security.SetSecurityDescriptorSddlForm('D:P(A;;FA;;;SY)(A;;FA;;;BA)',[Security.AccessControl.AccessControlSections]::Access)
 Set-Acl -LiteralPath $Path -AclObject $security -ErrorAction Stop
 & icacls.exe $Path /setowner '*S-1-5-18' 2>&1|Out-Null
 if($LASTEXITCODE){throw 'The fixture host key owner could not be secured.'}
 $actual=Get-Acl -LiteralPath $Path -ErrorAction Stop
 $rules=@($actual.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])|ForEach-Object {@{sid=$_.IdentityReference.Value;rights=[int64]$_.FileSystemRights;access=[string]$_.AccessControlType;inherited=[bool]$_.IsInherited;inheritance=[int]$_.InheritanceFlags;propagation=[int]$_.PropagationFlags}})
 $ownerSid=$actual.GetOwner([Security.Principal.SecurityIdentifier]).Value
 if(!(Test-OpenWebSftpHostKeySecurity $ownerSid $actual.AreAccessRulesProtected $rules)){throw 'The fixture host key security did not match its exact private policy.'}
}
function ConvertTo-OpenWebSftpTaskResult($Value) {
 if($null -eq $Value){return $null}
 try {
  if($Value -isnot [sbyte] -and $Value -isnot [byte] -and $Value -isnot [int16] -and $Value -isnot [uint16] -and $Value -isnot [int32] -and $Value -isnot [uint32] -and $Value -isnot [int64] -and $Value -isnot [uint64]){return $null}
  $number=[Convert]::ToInt64($Value)
  if($number -lt -2147483648L -or $number -gt 4294967295L){return $null}
  if($number -lt 0){$number+=4294967296L}
  return $number
 } catch {return $null}
}
function Get-OpenWebSftpErrorClass([string]$Text) {
 if(!$Text){return 'unknown'}
 # Win32 w32log.c::syslog_file uses "%d %04d-%02d-%02d %02d:%02d:%02d.%03d %s".
 # Keep direct -E/stderr lines working too; strip only that exact valid prefix.
 # Source: PowerShell/openssh-portable 59aba65cf2e2f423c09d12ad825c3b32a11f408f,
 # contrib/win32/win32compat/w32log.c:170-173 (v9.5.0.0).
 $Text=[regex]::Replace($Text,'(?m)^([1-9][0-9]{0,9}) ([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}) (?:(?:fatal|error): )?',{
  param($match)
  $processIdValue=[uint32]0;$localTimestamp=[datetime]::MinValue
  if([uint32]::TryParse($match.Groups[1].Value,[ref]$processIdValue) -and [datetime]::TryParseExact($match.Groups[2].Value,'yyyy-MM-dd HH:mm:ss.fff',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$localTimestamp)){return ''}
  return $match.Value
 })
 # Fixed upstream sshd diagnostics only. The matching line is never returned.
 if($Text -cmatch '(?m)^(?:fatal: )?Missing privilege separation directory: '){return 'missing_privilege_directory'}
 if($Text -match '(?m)^(?:[^\r\n]*?: line \d+: )?(?:Bad configuration option:|Missing argument\.|Unsupported option |Badly formatted port number\.|bad port number)'){return 'configuration'}
 if($Text -match '(?m)^(?:fatal: )?(?:Unable to load host key:|Unable to load host key |sshd: no hostkeys available|No supported key exchange algorithms|Bad owner or permissions on |Permissions .* are too open\.)'){return 'host_key_or_permissions'}
 if($Text -match '(?m)^(?:error: |fatal: )?(?:Bind to port \d+ on [^\r\n]+ failed:|Cannot bind any address\.)'){return 'bind'}
 return 'unknown'
}
function Get-OpenWebSftpBoundedLog([string]$Path,[string]$OwnedDirectory) {
 $result=@{status='unavailable';error_class='unknown'}
 try {
  if([IO.Path]::GetFullPath([IO.Path]::GetDirectoryName($Path)) -cne [IO.Path]::GetFullPath($OwnedDirectory)){ $result.status='boundary_refused';return $result }
  $parent=Get-Item -LiteralPath $OwnedDirectory -Force -ErrorAction Stop
  if(!$parent.PSIsContainer -or ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint)){ $result.status='boundary_refused';return $result }
  if(!(Test-Path -LiteralPath $Path -PathType Leaf)){ $result.status='absent';return $result }
  $file=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
  if(($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $file.Length -gt 1048576){ $result.status='boundary_refused';return $result }
  $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
  try {
   $count=[int][Math]::Min(65536L,$stream.Length);[void]$stream.Seek(-$count,[IO.SeekOrigin]::End)
   $bytes=New-Object byte[] $count;$read=$stream.Read($bytes,0,$count)
   $result.error_class=Get-OpenWebSftpErrorClass ([Text.Encoding]::UTF8.GetString($bytes,0,$read));$result.status='read'
  } finally {$stream.Dispose()}
 } catch {$result.status='unavailable'}
 return $result
}
function Get-OpenWebSftpOwnership([object[]]$Processes,[object[]]$Listeners,[string]$Executable,[string]$Arguments) {
 $result=@{owned_process_count=0;process_ownership_confirmed=$false;listener_count=@($Listeners).Count;listeners_loopback_only=$true;listener_matches_owned_process=$false}
 $owned=@()
 foreach($process in @($Processes)) {
  if($process.executable -isnot [string] -or $process.command_line -isnot [string] -or $process.owner_sid -cne 'S-1-5-18'){continue}
  if(![string]::Equals($process.executable,$Executable,[StringComparison]::OrdinalIgnoreCase)){continue}
  $pattern='^\s*(?:"'+[regex]::Escape($Executable)+'"|'+[regex]::Escape($Executable)+')\s+'+[regex]::Escape($Arguments)+'\s*$'
  if(![regex]::IsMatch($process.command_line,$pattern,[Text.RegularExpressions.RegexOptions]::IgnoreCase)){continue}
  if($process.pid -isnot [int] -or $process.pid -le 0){continue}
  $owned+=,$process
 }
 $result.owned_process_count=$owned.Count;$result.process_ownership_confirmed=($owned.Count -eq 1)
 if($owned.Count -eq 1){$result.owned_pid=$owned[0].pid}
 foreach($listener in @($Listeners)){if($listener.address -cnotin @('127.0.0.1','::1')){$result.listeners_loopback_only=$false}}
 if($owned.Count -eq 1 -and @($Listeners).Count -gt 0 -and $result.listeners_loopback_only){
  $result.listener_matches_owned_process=@($Listeners|Where-Object {$_.pid -ne $owned[0].pid}).Count -eq 0
 }
 return $result
}
function Invoke-OpenWebSftpConfigCheck([string]$Executable,[string]$Config) {
 $result=@{attempted=$false;timed_out=$false;exit_code=$null;error_class='unknown';actor='current_administrator'}
 $child=$null
 try {
  if(!$Executable -or !$Config -or $Executable.Contains('"') -or $Config.Contains('"') -or $Config -match '[\r\n]'){return $result}
  if(!(Test-Path -LiteralPath $Executable -PathType Leaf) -or !(Test-Path -LiteralPath $Config -PathType Leaf)){return $result}
  foreach($path in $Executable,$Config){if((Get-Item -LiteralPath $path -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint){return $result}}
  $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$Executable;$start.Arguments='-t -f "'+$Config+'"'
  $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
  $child=[Diagnostics.Process]::new();$child.StartInfo=$start
  if(!$child.Start()){return $result};$result.attempted=$true
  $readers=@($child.StandardError,$child.StandardOutput);$buffers=@((New-Object char[] 4096),(New-Object char[] 4096))
  $pending=@($readers[0].ReadAsync($buffers[0],0,4096),$readers[1].ReadAsync($buffers[1],0,4096));$finished=@($false,$false)
  $captured=[Text.StringBuilder]::new();$overflow=$false;$timer=[Diagnostics.Stopwatch]::StartNew()
  while(!$child.HasExited -or !$finished[0] -or !$finished[1]){
   if($timer.ElapsedMilliseconds -ge 10000){$result.timed_out=$true;return $result}
   for($i=0;$i -lt 2;$i++){
    if(!$finished[$i] -and $pending[$i].IsCompleted){
     $read=$pending[$i].GetAwaiter().GetResult()
     if($read -eq 0){$finished[$i]=$true;[void]$captured.Append("`n")}
     else{
      if($captured.Length+$read -le 65536){[void]$captured.Append($buffers[$i],0,$read)}else{$overflow=$true}
      $pending[$i]=$readers[$i].ReadAsync($buffers[$i],0,4096)
     }
    }
   }
   Start-Sleep -Milliseconds 10
  }
  $result.exit_code=[int]$child.ExitCode
  if(!$overflow){$result.error_class=Get-OpenWebSftpErrorClass $captured.ToString()}
 } catch {} finally {if($child){try{if(!$child.HasExited){$child.Kill();[void]$child.WaitForExit(1000)}}catch{};$child.Dispose()}}
 return $result
}
function Get-OpenWebSftpStartupFailure([string]$TaskName,[string]$Executable,[string]$Config,[string]$OwnedDirectory,[int]$Port) {
 $safe=@{schema=1;observation='failure_only';complete=$false;port=$Port;default_ssh_directory_exists=$false;task_exists=$false;task_observation_complete=$false;process_observation_complete=$false;task_state='Unknown';task_result=$null;task_action_matches=$false;task_system_principal=$false;log_status='unavailable';error_class='unknown'}
 try {
  if($Port -lt 1 -or $Port -gt 65535 -or $TaskName -cnotmatch '^OpenWebPBX-SFTP-QA-[a-f0-9]{10}$'){return $safe}
  if(![string]::Equals([IO.Path]::GetFullPath($Executable),[IO.Path]::GetFullPath((Join-Path $env:SystemRoot 'System32/OpenSSH/sshd.exe')),[StringComparison]::OrdinalIgnoreCase)){return $safe}
  if([IO.Path]::GetFullPath($Config) -cne [IO.Path]::GetFullPath((Join-Path $OwnedDirectory 'sshd_config'))){return $safe}
  $directory=Get-Item -LiteralPath $OwnedDirectory -Force -ErrorAction Stop
  if(!$directory.PSIsContainer -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)){return $safe}
  $configuration=Get-Item -LiteralPath $Config -Force -ErrorAction Stop
  if($configuration.PSIsContainer -or ($configuration.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $configuration.Length -gt 1048576){return $safe}
  $log=Join-Path $OwnedDirectory 'sshd-private.log';$arguments='-D -f "'+$Config+'" -E "'+$log+'"'
  $safe.default_ssh_directory_exists=Test-Path -LiteralPath 'C:\ProgramData\ssh' -PathType Container
  try{
   $task=Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop;$safe.task_exists=$true
   if([string]$task.State -cin @('Unknown','Disabled','Queued','Ready','Running')){$safe.task_state=[string]$task.State}
   $info=Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop;$safe.task_result=ConvertTo-OpenWebSftpTaskResult $info.LastTaskResult
   $actions=@($task.Actions)
   $safe.task_action_matches=($actions.Count -eq 1 -and [string]::Equals([string]$actions[0].Execute,$Executable,[StringComparison]::OrdinalIgnoreCase) -and [string]$actions[0].Arguments -ceq $arguments)
   $safe.task_system_principal=([string]$task.Principal.UserId -cin @('SYSTEM','S-1-5-18','NT AUTHORITY\SYSTEM') -and [string]$task.Principal.LogonType -ceq 'ServiceAccount' -and [string]$task.Principal.RunLevel -ceq 'Highest')
   $safe.task_observation_complete=$true
  }catch{}
  $exe=Get-Item -LiteralPath $Executable -Force -ErrorAction Stop
  if(!($exe.Attributes -band [IO.FileAttributes]::ReparsePoint)){
   $safe.executable_sha256=(Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash.ToLowerInvariant()
   $version=[string]$exe.VersionInfo.FileVersion;if($version -cmatch '^\d+(?:\.\d+){1,3}$'){$safe.executable_version=$version}
  }
  try{
   $rows=@(Get-CimInstance -ClassName Win32_Process -Filter "Name='sshd.exe'" -ErrorAction Stop);$processes=@()
   if($rows.Count -gt 64){throw 'Bounded process observation refused.'}
   foreach($row in $rows){$owner=Invoke-CimMethod -InputObject $row -MethodName GetOwnerSid -ErrorAction Stop;if($owner.ReturnValue -eq 0){$processes+=@{pid=[int]$row.ProcessId;executable=[string]$row.ExecutablePath;command_line=[string]$row.CommandLine;owner_sid=[string]$owner.Sid}}}
   $listeners=@(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue|ForEach-Object {@{pid=[int]$_.OwningProcess;address=[string]$_.LocalAddress}})
   $ownership=Get-OpenWebSftpOwnership $processes $listeners $Executable $arguments
   foreach($key in $ownership.Keys){$safe[$key]=$ownership[$key]}
   $safe.process_observation_complete=$true
  }catch{}
  $read=Get-OpenWebSftpBoundedLog $log $OwnedDirectory;$safe.log_status=$read.status;$safe.error_class=$read.error_class
  $safe.config_check=Invoke-OpenWebSftpConfigCheck $Executable $Config
  $safe.complete=$true
 } catch {}
 return $safe
}
