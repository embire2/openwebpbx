#Requires -Version 7.4
param([switch]$RequireLinuxSshd)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'windows-sftp-diagnostics.ps1')
$script:checks=0
function Check([bool]$Condition,[string]$Case){if(!$Condition){throw ('SFTP diagnostic control failed: '+$Case)};$script:checks++}
$canary='PRIVATE_SFTP_CANARY_0f81';$root=Join-Path ([IO.Path]::GetTempPath()) ('owb-sftp-controls-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root|Out-Null
try {
 $fullControl=[int64][Security.AccessControl.FileSystemRights]::FullControl
 $systemRule=@{sid='S-1-5-18';rights=$fullControl;access='Allow';inherited=$false;inheritance=[int]0;propagation=[int]0}
 $adminRule=$systemRule.Clone();$adminRule.sid='S-1-5-32-544'
 $creatorRule=$systemRule.Clone();$creatorRule.sid='S-1-5-21-123-456-789-1001';$creatorRule.rights=[int64]([Security.AccessControl.FileSystemRights]::Read -bor [Security.AccessControl.FileSystemRights]::Write)
 $retainedCreator=@($systemRule,$adminRule,$creatorRule)
 Check (!(Test-OpenWebSftpHostKeySecurity 'S-1-5-18' $true $retainedCreator)) 'original grant replacement retains forbidden explicit creator ACE'
 $replacement=@($systemRule,$adminRule)
 Check (Test-OpenWebSftpHostKeySecurity 'S-1-5-18' $true $replacement) 'exact protected two-principal replacement accepted'
 Check (Test-OpenWebSftpHostKeySecurity 'S-1-5-18' $true @($adminRule,$systemRule)) 'equivalent ACE ordering accepted'
 foreach($owner in $creatorRule.sid,'S-1-5-32-544',$null){Check (!(Test-OpenWebSftpHostKeySecurity $owner $true $replacement)) 'non-SYSTEM hostkey owner refused'}
 foreach($protected in $false,'true',$null){Check (!(Test-OpenWebSftpHostKeySecurity 'S-1-5-18' $protected $replacement)) 'unprotected or untyped DACL refused'}
 foreach($change in @(@('sid',$creatorRule.sid),@('rights',[int64]1),@('rights','2032127'),@('access','Deny'),@('inherited',$true),@('inherited','false'),@('inheritance',[int]1),@('propagation',[int]1))){
  $modified=$adminRule.Clone();$modified[$change[0]]=$change[1]
  Check (!(Test-OpenWebSftpHostKeySecurity 'S-1-5-18' $true @($systemRule,$modified))) ('unsafe hostkey rule '+$change[0]+' refused')
 }
 Check (!(Test-OpenWebSftpHostKeySecurity 'S-1-5-18' $true @($systemRule,$systemRule.Clone()))) 'duplicate SYSTEM ACE cannot replace Administrators'
 Check ($adminRule.sid -ceq 'S-1-5-32-544' -and $adminRule.rights -eq $fullControl -and !$adminRule.inherited) 'mutated negative rules are independent copies'
 $privacy=Test-OpenWebSftpHostKeySecurity $creatorRule.sid $true $retainedCreator
 Check (($privacy -is [bool]) -and !(($privacy|ConvertTo-Json).Contains($creatorRule.sid))) 'key-security result exposes no creator identity'
 foreach($pair in @(@([int32]-2147024894,2147942402L),@([uint32]4294967295,4294967295L),@([int32]-1,4294967295L),@([int32]267009,267009L),@([int64]0,0L))){Check ((ConvertTo-OpenWebSftpTaskResult $pair[0]) -eq $pair[1]) 'signed task normalization'}
 foreach($value in @($null,$true,'1',[double]1.2,[int64]-2147483649,[uint64]4294967296)){Check ($null -eq (ConvertTo-OpenWebSftpTaskResult $value)) 'invalid task type/range refused'}
 $messages=@{
  missing_privilege_directory=('Missing privilege separation directory: '+$canary)
  configuration=('/private/'+$canary+': line 1: Bad configuration option: '+$canary)
  host_key_or_permissions=('Unable to load host key: '+$canary)
  bind=('Bind to port 43210 on 127.0.0.1 failed: '+$canary)
  unknown=('Arbitrary private error '+$canary)
 }
 foreach($entry in $messages.GetEnumerator()){Check ((Get-OpenWebSftpErrorClass $entry.Value) -ceq $entry.Key) ('fixed class '+$entry.Key)}
 Check ((Get-OpenWebSftpErrorClass ('prefix Missing privilege separation directory: '+$canary)) -ceq 'unknown') 'missing privilege directory prefix is exact'
 foreach($level in '','fatal: ','error: '){foreach($entry in $messages.GetEnumerator()){
  $formatted='321 2026-10-15 09:08:07.006 '+$level+$entry.Value
  Check ((Get-OpenWebSftpErrorClass $formatted) -ceq $entry.Key) ('strict Win32 formatter '+$level+$entry.Key)
 }}
 foreach($prefix in @('0321 2026-10-15 09:08:07.006 ','321 2026-02-31 09:08:07.006 ','321 2026-10-15 25:08:07.006 ','321 2026-10-15 09:08:07.06 ','321 2026-10-15T09:08:07.006 ','4294967296 2026-10-15 09:08:07.006 ','321 2026-10-15 09:08:07.006 private: ','foreign 321 2026-10-15 09:08:07.006 ')){
  Check ((Get-OpenWebSftpErrorClass ($prefix+$messages.missing_privilege_directory)) -ceq 'unknown') 'malformed/foreign Windows log prefix refused'
 }
 $winClass=Get-OpenWebSftpErrorClass ("321 2026-10-15 09:08:07.006 error: unrelated $canary`r`n321 2026-10-15 09:08:07.007 fatal: "+$messages.missing_privilege_directory+"`r`n")
 Check ($winClass -ceq 'missing_privilege_directory') 'multiline CRLF Win32 file formatter'
 Check (!(($winClass|ConvertTo-Json).Contains($canary))) 'Windows prefix and private message never returned'
 $exe='C:\Windows\System32\OpenSSH\sshd.exe';$args='-D -f "C:\private\sshd_config" -E "C:\private\sshd-private.log"'
 $process=@{pid=321;executable=$exe;command_line=('"'+$exe+'" '+$args);owner_sid='S-1-5-18'}
 $listener=@{pid=321;address='127.0.0.1'}
 $owned=Get-OpenWebSftpOwnership @($process) @($listener) $exe $args
 Check ($owned.process_ownership_confirmed -and $owned.listener_matches_owned_process -and $owned.owned_pid -eq 321) 'exact source/system/listener binding'
 foreach($key in 'executable','command_line','owner_sid'){
  $changed=$process.Clone();$changed[$key]=$canary
  $r=Get-OpenWebSftpOwnership @($changed) @($listener) $exe $args
  Check (!$r.process_ownership_confirmed -and !$r.listener_matches_owned_process -and !$r.ContainsKey('owned_pid')) ('foreign '+$key+' refused')
 }
 $r=Get-OpenWebSftpOwnership @($process,$process.Clone()) @($listener) $exe $args
 Check (!$r.process_ownership_confirmed -and !$r.listener_matches_owned_process) 'ambiguous processes refused'
 $r=Get-OpenWebSftpOwnership @($process) @(@{pid=322;address='127.0.0.1'}) $exe $args
 Check (!$r.listener_matches_owned_process -and $r.process_ownership_confirmed) 'foreign listening PID refused'
 $r=Get-OpenWebSftpOwnership @($process) @(@{pid=321;address='0.0.0.0'}) $exe $args
 Check (!$r.listener_matches_owned_process -and !$r.listeners_loopback_only) 'wildcard listener refused'
 $r=Get-OpenWebSftpOwnership @($process) @() $exe $args
 Check (!$r.listener_matches_owned_process -and $r.owned_pid -eq 321 -and $r.listener_count -eq 0) 'owned nonlistening PID retained'
 $changed=$process.Clone();$changed.pid='321';$r=Get-OpenWebSftpOwnership @($changed) @($listener) $exe $args
 Check (!$r.process_ownership_confirmed -and !$r.listener_matches_owned_process) 'untyped process PID refused'
 Check (!(($owned|ConvertTo-Json -Depth 8) -match [regex]::Escape($args))) 'ownership report excludes command'
 $log=Join-Path $root 'sshd-private.log'
 [IO.File]::WriteAllText($log,$messages.missing_privilege_directory)
 $r=Get-OpenWebSftpBoundedLog $log $root
 Check ($r.status -ceq 'read' -and $r.error_class -ceq 'missing_privilege_directory') 'actual private log classification'
 Check (!(($r|ConvertTo-Json) -match $canary)) 'private log marker never returned'
 [IO.File]::WriteAllText($log,('321 2026-10-15 09:08:07.006 fatal: '+$messages.missing_privilege_directory+"`r`n"))
 $r=Get-OpenWebSftpBoundedLog $log $root
 Check ($r.status -ceq 'read' -and $r.error_class -ceq 'missing_privilege_directory') 'actual bounded file with Windows formatter'
 Check (!(($r|ConvertTo-Json).Contains($canary))) 'bounded Windows formatted log remains private'
 $r=Get-OpenWebSftpBoundedLog $log (Join-Path $root 'other')
 Check ($r.status -ceq 'boundary_refused') 'foreign log parent refused'
 $r=Get-OpenWebSftpBoundedLog (Join-Path $root 'absent') $root
 Check ($r.status -ceq 'absent') 'absent private log explicit'
 [IO.File]::WriteAllText($log,('x'*1048577))
 Check ((Get-OpenWebSftpBoundedLog $log $root).status -ceq 'boundary_refused') 'oversized log refused'
 [IO.File]::WriteAllText($log,('x'*70000)+"`n"+$messages.bind)
 Check ((Get-OpenWebSftpBoundedLog $log $root).error_class -ceq 'bind') 'bounded tail retains actual final class'
 $link=Join-Path $root 'log-link';New-Item -ItemType SymbolicLink -Path $link -Target $log|Out-Null
 Check ((Get-OpenWebSftpBoundedLog $link $root).status -ceq 'boundary_refused') 'log reparse refused'
 $refused=Invoke-OpenWebSftpConfigCheck 'missing-executable' $log
 Check (!$refused.attempted -and !$refused.timed_out -and $null -eq $refused.exit_code) 'missing config checker refused'
 if($IsLinux -and (Test-Path -LiteralPath '/usr/sbin/sshd' -PathType Leaf)){
  $refused=Invoke-OpenWebSftpConfigCheck '/usr/sbin/sshd' $link
  Check (!$refused.attempted -and $null -eq $refused.exit_code) 'config-check reparse config refused'
  $exeLink=Join-Path $root 'sshd-link';New-Item -ItemType SymbolicLink -Path $exeLink -Target '/usr/sbin/sshd'|Out-Null
  $refused=Invoke-OpenWebSftpConfigCheck $exeLink $log
  Check (!$refused.attempted -and $null -eq $refused.exit_code) 'config-check reparse executable refused'
 }
 # Invoke the actual collector with isolated OS-query stubs. No real task,
 # process, listener, service, account or Windows configuration is accessed.
 $systemRootBefore=$env:SystemRoot;$configCheckBody=(Get-Command Invoke-OpenWebSftpConfigCheck).ScriptBlock
 try{
  $env:SystemRoot=Join-Path $root 'os';$inbox=Join-Path $env:SystemRoot 'System32/OpenSSH'
  New-Item -ItemType Directory -Path $inbox -Force|Out-Null
  $fixtureExe=Join-Path $inbox 'sshd.exe';[IO.File]::WriteAllText($fixtureExe,'owned test-only executable bytes')
  $fixtureConfig=Join-Path $root 'sshd_config';[IO.File]::WriteAllText($fixtureConfig,'owned test-only configuration')
  [IO.File]::WriteAllText($log,$messages.missing_privilege_directory)
  $fixtureArgs='-D -f "'+$fixtureConfig+'" -E "'+$log+'"';$script:taskQueryFails=$false;$script:collectorQueries=0
  function Test-Path {
   [CmdletBinding()]param([string]$LiteralPath,[string]$PathType)
   if($LiteralPath -ceq 'C:\ProgramData\ssh'){return $false}
   return Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath -PathType $PathType
  }
  function Get-ScheduledTask {
   [CmdletBinding()]param($TaskName)
   $script:collectorQueries++;if($script:taskQueryFails){throw 'private task diagnostic '+$canary}
   # Deliberately a singleton CIM-like action, rather than an array.
   return [pscustomobject]@{State='Ready';Actions=[pscustomobject]@{Execute=$fixtureExe;Arguments=$fixtureArgs};Principal=[pscustomobject]@{UserId='SYSTEM';LogonType='ServiceAccount';RunLevel='Highest'}}
  }
  function Get-ScheduledTaskInfo {[CmdletBinding()]param($TaskName);return [pscustomobject]@{LastTaskResult=[int32]-2147024894}}
  function Get-CimInstance {[CmdletBinding()]param($ClassName,$Filter);return [pscustomobject]@{ProcessId=321;ExecutablePath=$fixtureExe;CommandLine=('"'+$fixtureExe+'" '+$fixtureArgs)}}
  function Invoke-CimMethod {[CmdletBinding()]param($InputObject,$MethodName);return [pscustomobject]@{ReturnValue=0;Sid='S-1-5-18'}}
  function Get-NetTCPConnection {[CmdletBinding()]param($State,$LocalPort);return [pscustomobject]@{OwningProcess=321;LocalAddress='127.0.0.1'}}
  function Invoke-OpenWebSftpConfigCheck {param($Executable,$Config);return @{attempted=$true;timed_out=$false;exit_code=255;error_class='configuration';actor='current_administrator'}}
  $observed=Get-OpenWebSftpStartupFailure 'OpenWebPBX-SFTP-QA-aabbccddee' $fixtureExe $fixtureConfig $root 43210
  Check ($observed.complete -and $observed.task_observation_complete -and $observed.process_observation_complete -and $observed.task_action_matches -and $observed.task_system_principal) 'actual collector singleton action and fixed principal'
  Check ($observed.task_result -eq 2147942402L -and $observed.task_state -ceq 'Ready') 'actual collector task result normalization'
  Check ($observed.owned_pid -eq 321 -and $observed.listener_matches_owned_process) 'actual collector exact ownership'
  Check (!$observed.default_ssh_directory_exists -and $observed.error_class -ceq 'missing_privilege_directory') 'actual collector absent default directory and fixed log class'
  Check ($observed.config_check.exit_code -eq 255 -and $observed.executable_sha256 -cmatch '^[a-f0-9]{64}$') 'actual collector typed private config check and executable hash'
  $serialized=$observed|ConvertTo-Json -Depth 8
  Check (!$serialized.Contains($canary) -and !$serialized.Contains($root) -and !$serialized.Contains($fixtureArgs) -and !$serialized.Contains('OpenWebPBX-SFTP-QA-aabbccddee')) 'actual collector never returns fixture identity/private strings'
  $script:taskQueryFails=$true
  $observed=Get-OpenWebSftpStartupFailure 'OpenWebPBX-SFTP-QA-aabbccddee' $fixtureExe $fixtureConfig $root 43210
  Check ($observed.complete -and !$observed.task_observation_complete -and !$observed.task_exists -and $observed.error_class -ceq 'missing_privilege_directory') 'task observation failure does not suppress log class'
  Check (!(($observed|ConvertTo-Json -Depth 8).Contains($canary))) 'private query exception remains excluded'
  $queriesBefore=$script:collectorQueries
  foreach($case in @(@('foreign-task',$fixtureExe,$fixtureConfig,43210),@('OpenWebPBX-SFTP-QA-aabbccddee',($fixtureExe+'.foreign'),$fixtureConfig,43210),@('OpenWebPBX-SFTP-QA-aabbccddee',$fixtureExe,($fixtureConfig+'.foreign'),43210),@('OpenWebPBX-SFTP-QA-aabbccddee',$fixtureExe,$fixtureConfig,0))){
   $observed=Get-OpenWebSftpStartupFailure $case[0] $case[1] $case[2] $root $case[3]
   Check (!$observed.complete -and $script:collectorQueries -eq $queriesBefore) 'foreign collector binding refused before OS query'
  }
 }finally{
  $env:SystemRoot=$systemRootBefore
  foreach($name in 'Test-Path','Get-ScheduledTask','Get-ScheduledTaskInfo','Get-CimInstance','Invoke-CimMethod','Get-NetTCPConnection'){Remove-Item ('Function:'+ $name) -ErrorAction SilentlyContinue}
  Set-Item Function:Invoke-OpenWebSftpConfigCheck $configCheckBody
 }
 $suite=Join-Path $PSScriptRoot 'windows-suite.ps1';$tokens=$null;$errors=$null
 $ast=[Management.Automation.Language.Parser]::ParseFile($suite,[ref]$tokens,[ref]$errors)
 Check ($errors.Count -eq 0) 'suite parses'
 $loop=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'LoopbackSftp'},$true).Extent.Text
 Check (($loop|Select-String -Pattern 'Get-OpenWebSftpStartupFailure' -AllMatches).Matches.Count -eq 1) 'one failure observer site'
 Check ($loop.Contains("if(!`$connected){try{")) 'observer only on original failed readiness'
 Check ($loop.Contains("}catch{};throw 'The separate loopback SFTP server did not start.'}")) 'observer failure preserves original throw'
 Check ($loop.Contains('UtcNow.AddSeconds(30)') -and $loop.Contains("'-D -f ") -and $loop.Contains('-E "')) 'original startup command and deadline retained'
 Check ($loop.Contains("'StrictModes yes'")) 'OpenSSH strict key checks remain enabled'
 $keyCalls=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Set-OpenWebSftpHostKeySecurity'},$true))
 Check ($keyCalls.Count -eq 1 -and $keyCalls[0].CommandElements[1].Extent.Text -ceq '$hostkey' -and $keyCalls[0].CommandElements[2].Extent.Text -ceq '$work') 'exact hostkey-only preparation call'
 Check (!$loop.Contains("& icacls.exe `$hostkey /inheritance:r /grant:r")) 'incomplete hostkey grant operation removed'
 Check ($loop.Contains("& icacls.exe `$authorized /inheritance:r /grant:r")) 'authorized key policy unchanged'
 $helperTokens=$null;$helperErrors=$null
 $helperAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'windows-sftp-diagnostics.ps1'),[ref]$helperTokens,[ref]$helperErrors)
 $keyFunction=$helperAst.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Set-OpenWebSftpHostKeySecurity'},$true).Extent.Text
 Check ($helperErrors.Count -eq 0 -and $keyFunction.Contains("'D:P(A;;FA;;;SY)(A;;FA;;;BA)'")) 'exact fresh protected DACL source'
 Check ($keyFunction.Contains('[Security.AccessControl.AccessControlSections]::Access') -and $keyFunction.Contains('Set-Acl -LiteralPath $Path -AclObject $security')) 'entire owned DACL replaced without inherited creator ACE'
 Check ($keyFunction.Contains("/setowner '*S-1-5-18'") -and $keyFunction.Contains('Test-OpenWebSftpHostKeySecurity $ownerSid $actual.AreAccessRulesProtected $rules')) 'SYSTEM owner and exact ACL readback required'
 $realSshd=$false
 if($IsLinux -and (Test-Path -LiteralPath '/usr/sbin/sshd' -PathType Leaf)){
  $config=Join-Path $root 'sshd_config'
  [IO.File]::WriteAllText($config,($canary+' yes'+"`n"))
  $r=Invoke-OpenWebSftpConfigCheck '/usr/sbin/sshd' $config
  Check ($r.attempted -and !$r.timed_out -and $r.exit_code -ne 0 -and $r.error_class -ceq 'configuration') 'real sshd invalid configuration'
  Check (!(($r|ConvertTo-Json) -match $canary)) 'real invalid config marker remains private'
  [IO.File]::WriteAllText($config,('HostKey '+(Join-Path $root ($canary+'.key'))+"`n"))
  $r=Invoke-OpenWebSftpConfigCheck '/usr/sbin/sshd' $config
  Check ($r.attempted -and !$r.timed_out -and $r.exit_code -ne 0 -and $r.error_class -ceq 'host_key_or_permissions') 'real sshd missing host key'
  Check (!(($r|ConvertTo-Json) -match $canary)) 'real missing-key marker remains private'
  $realSshd=$true
 }
 if($RequireLinuxSshd -and !$realSshd){throw 'Actual Linux sshd controls were required.'}
 [ordered]@{state='passed';checks=$script:checks;real_linux_sshd=$realSshd;actual_windows_startup='unqualified'}|ConvertTo-Json -Compress
} finally {Remove-Item -LiteralPath $root -Recurse -Force}
