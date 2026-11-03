param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$script:checks=0
function Verify([bool]$Value){if(!$Value){throw ('Independent operator task control refused at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
$path=Join-Path $SourceRoot 'tests/windows-operator-restore-task.ps1';$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors);Verify (!$errors.Count)
foreach($name in 'Need','WriteNew','ForwardOperatorTaskEvidence','AssertOperatorTask','AssertOperatorTaskSecurity','InvokeOperatorTaskController'){
 $node=@($ast.FindAll({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst]-and $n.Name-ceq $name},$true));Verify ($node.Count-eq 1);. ([scriptblock]::Create($node[0].Extent.Text))
}
function Refuses([scriptblock]$Body){$caught=$null;try{& $Body|Out-Null}catch{$caught=$_};if($null-eq $caught){throw ('Expected controlled refusal missing: '+$script:mode)};Verify ($null-ne $caught)}
function FreshDefinition {
 $actions=[pscustomobject]@{Count=0;Entry=$null}
 $actions|Add-Member ScriptMethod Create {param($kind);Verify ($kind-eq 0);$this.Count=1;$this.Entry=[pscustomobject]@{Type=0;Path='';Arguments='';WorkingDirectory=''};return $this.Entry}
 $actions|Add-Member ScriptMethod Item {param($index);Verify ($index-eq 1);return $this.Entry}
 return [pscustomobject]@{Principal=[pscustomobject]@{UserId='';LogonType=0;RunLevel=0};Triggers=[pscustomobject]@{Count=0};Actions=$actions;Settings=[pscustomobject]@{Enabled=$false;MultipleInstances=0;ExecutionTimeLimit='';RestartCount=0}}
}
function Reset([string]$Mode='success'){
 $script:mode=$Mode;$script:runs=0;$script:registered=0;$script:deleted=0;$script:reads=0;$script:exists=($Mode-ceq 'preexisting');$script:id=[guid]::NewGuid();$script:full=Join-Path $temporary $id.ToString('N');$null=[IO.Directory]::CreateDirectory($full)
 $script:Context=Join-Path $full 'operator-restore-context.private.json';$script:PSCommandPath=$path;$script:ps='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe';$script:issued=[DateTimeOffset]::UtcNow.AddMilliseconds(-100);$script:deadline=$issued.AddSeconds(1200)
 $script:result=Join-Path $full 'operator-task-result.private.json';$script:nativeOut=Join-Path $full 'operator-task-native.out';$script:nativeErr=Join-Path $full 'operator-task-native.err';$script:p=@{operation_uuid=$id.ToString();run_id='123456';source_commit=('a'*40);computer_name='OWNED';operator_deadline_utc=$deadline.ToString('o')}
 $script:task=[pscustomobject]@{Name=('OpenWebPBX-QA-IndependentOperator-'+$id.ToString('N'));Definition=$null;Xml='<owned-nonce-task/>';Security='O:SYG:SYD:P(A;;FA;;;SY)(A;;FA;;;BA)';State=3;LastRunTime=[DateTime]'1899-12-30';LastTaskResult=0}
 $task|Add-Member ScriptMethod GetSecurityDescriptor {param($section);Verify ($section-eq 7);return $this.Security}
 $task|Add-Member ScriptMethod Run {
  param($arguments);Verify ($null-eq $arguments);$script:runs++
  if($script:mode-ceq 'run_ambiguous'){throw 'Owned Run ambiguity'}
  if($script:mode-ceq 'queued_deadline'){$this.State=2;$script:deadline=[DateTimeOffset]::UtcNow.AddMilliseconds(-1);return}
  if($script:mode-cne 'stale_last_run'){$this.LastRunTime=[DateTime]::UtcNow.AddSeconds(-1)} # actual Scheduler second precision may precede issued microseconds
  $code=if($script:mode-ceq 'native_nonzero'){1}else{0};$this.LastTaskResult=$code
  if($script:mode-ceq 'bootstrap_failure'){$this.LastTaskResult=1;[IO.File]::WriteAllText($script:nativeOut,'PRIVATE_NATIVE_OUT');[IO.File]::WriteAllText($script:nativeErr,'PRIVATE_NATIVE_ERR');return}
  $r=@{schema=1;operation_uuid=$script:p.operation_uuid;run_id=$script:p.run_id;source_commit=$script:p.source_commit;host=$script:p.computer_name;actor='independent-system-scheduler';native_pid=1234;native_created_utc=$script:issued.AddMilliseconds(1).ToString('o');native_finished_utc=[DateTimeOffset]::UtcNow.ToString('o');exit_code=$code;completed_inside_original_fence=$true}
  switch($script:mode){wrong_nonce{$r.operation_uuid=[guid]::NewGuid().ToString()}wrong_source{$r.source_commit='b'*40}wrong_run{$r.run_id='999'}wrong_host{$r.host='FOREIGN'}late_result{$r.completed_inside_original_fence=$false}missing_exit{$r.exit_code=$null}}
  [IO.File]::WriteAllText($script:nativeOut,$(if($script:p.actor_mode-ceq 'operator'){'PRIVATE_NATIVE_OUT'}else{''}));[IO.File]::WriteAllText($script:nativeErr,$(if($script:p.actor_mode-ceq 'operator'){'PRIVATE_NATIVE_ERR'}else{''}));WriteNew $script:result $r
 }
 $script:folder=[pscustomobject]@{}
 $folder|Add-Member ScriptMethod RegisterTaskDefinition {
  param($name,$definition,$flags,$user,$password,$logon,$security)
  Verify ($name-ceq $script:task.Name-and $flags-eq 2-and $user-ceq 'SYSTEM'-and $null-eq $password-and $logon-eq 5-and $security-ceq $script:task.Security);$script:registered++
  if($script:mode-ceq 'registration_ambiguous'){throw 'Owned registration ambiguity'}
  $script:task.Definition=$definition;$script:exists=$true
  if($script:mode-ceq 'foreign_initial_security'){$script:task.Security='D:(A;;FA;;;WD)'}
 }
 $folder|Add-Member ScriptMethod GetTask {
  param($name);Verify ($name-ceq $script:task.Name);$script:reads++
  if($script:reads-eq 2){switch($script:mode){changed_xml{$script:task.Xml+='<foreign/>'}changed_security{$script:task.Security='D:(A;;FA;;;WD)'}changed_action{$script:task.Definition.Actions.Entry.Arguments+=' -Foreign'}}}
  return $script:task
 }
 $folder|Add-Member ScriptMethod DeleteTask {param($name,$flags);Verify ($name-ceq $script:task.Name-and $flags-eq 0-and $script:task.State-eq 3);$script:deleted++;$script:exists=$false}
 $script:scheduler=[pscustomobject]@{}
 $scheduler|Add-Member ScriptMethod Connect {}
 $scheduler|Add-Member ScriptMethod GetFolder {param($name);Verify ($name-ceq '\');return $script:folder}
 $scheduler|Add-Member ScriptMethod NewTask {param($flags);Verify ($flags-eq 0);return FreshDefinition}
}
function New-Object {param([string]$ComObject);Verify ($ComObject-ceq 'Schedule.Service');return $script:scheduler}
function Get-ScheduledTask {[CmdletBinding()]param([string]$TaskName,[string]$TaskPath);Verify ($TaskName-ceq $script:task.Name-and $TaskPath-ceq '\');if($script:exists){return $script:task}}
function Start-Sleep {param([int]$Milliseconds);Verify ($Milliseconds-eq 200);throw 'An unexpected repeated scheduler poll occurred in this controlled sample'}
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('operator-task-controls-'+[guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($temporary)
try{
 foreach($mode in 'success','native_nonzero'){
  Reset $mode;$exit=InvokeOperatorTaskController
  Verify ($exit-eq $(if($mode-ceq 'success'){0}else{1})-and $runs-eq 1-and $registered-eq 1-and $deleted-eq 1-and !(Test-Path (Join-Path $full 'operator-task-unfinished.private.json')))
  Verify ([DateTime]$task.LastRunTime-lt $issued.UtcDateTime) # floor-to-second is supported, never compared with issued microseconds
 }
 foreach($mode in 'queued_deadline','run_ambiguous','registration_ambiguous','foreign_initial_security','changed_xml','changed_security','changed_action','stale_last_run','wrong_nonce','wrong_source','wrong_run','wrong_host','late_result','missing_exit'){
  Reset $mode;Refuses {InvokeOperatorTaskController};Verify ($deleted-eq 0-and (Test-Path (Join-Path $full 'operator-task-unfinished.private.json'))-and $runs-le 1)
 }
 Reset preexisting;Refuses {InvokeOperatorTaskController};Verify ($runs-eq 0-and $registered-eq 0-and $deleted-eq 0)
 foreach($mode in 'wrong_nonce','bootstrap_failure'){
  Reset $mode;$p.actor_mode='operator';$savedOut=[Console]::Out;$savedErr=[Console]::Error;$capturedOut=[IO.StringWriter]::new();$capturedErr=[IO.StringWriter]::new()
  try{[Console]::SetOut($capturedOut);[Console]::SetError($capturedErr);Refuses {InvokeOperatorTaskController}}finally{[Console]::SetOut($savedOut);[Console]::SetError($savedErr)}
  Verify ($capturedOut.ToString().Contains('PRIVATE_NATIVE_OUT')-and $capturedErr.ToString().Contains('PRIVATE_NATIVE_ERR')-and $deleted-eq 0-and (Test-Path (Join-Path $full 'operator-task-unfinished.private.json')))
  if($mode-ceq 'wrong_nonce'){Verify ($capturedOut.ToString().Contains('OPERATOR_TASK_RESULT_PRIVATE='))};$capturedOut.Dispose();$capturedErr.Dispose()
 }
 foreach($sddl in 'O:SYG:SYD:P(A;;FA;;;SY)(A;;FA;;;BA)','O:SYG:SYD:P(A;;FA;;;BA)(A;;FA;;;SY)'){AssertOperatorTaskSecurity $sddl;Verify $true}
 foreach($sddl in 'D:(A;;FA;;;WD)','O:SYG:SYD:(A;;FA;;;SY)(A;;FA;;;BA)','O:SYG:SYD:P(A;;FR;;;SY)(A;;FA;;;BA)'){Refuses {AssertOperatorTaskSecurity $sddl}}
 $raw=[IO.File]::ReadAllText($path);Verify ($raw.Contains("ExecutionTimeLimit='PT0S'")-and !$raw.Contains('Stop-ScheduledTask')-and !$raw.Contains('.Kill(')-and !$raw.Contains('PT20M'))
 Verify (([regex]::Matches($raw,'\$task\.Run\(\$null\)')).Count-eq 1-and $raw.Contains('RegisterTaskDefinition($name,$definition,2,'))
 Verify (!$raw.Contains('$env:GH_TOKEN=')-and !$raw.Contains('$env:WINDOWS_UPDATER_SIGNED_PACKETS_B64='))
 $main=[IO.File]::ReadAllText((Join-Path $SourceRoot 'tests/windows-updater-qualification.ps1'));Verify ($main.Contains("'operator-rollback-native' -Timeout 1200000")-and $main.IndexOf('operator-task-unfinished.private.json',$main.IndexOf('}finally{') )-lt $main.LastIndexOf('OpenQualificationCleanupLock'))
 $wrapper=[IO.File]::ReadAllText((Join-Path $SourceRoot 'tests/windows-operator-restore-diagnostic.ps1'));Verify (([regex]::Matches($wrapper,[regex]::Escape('& $helper -RestoreBackup $backup'))).Count-eq 1)
 $product=[IO.File]::ReadAllText((Join-Path $SourceRoot 'packaging/windows/UpgradeRecovery.Common.ps1'));$first='$ancestor=[uint32]$PID;';$last="if(!`$ended){throw 'The rollback process ancestry exceeds its safe bound.'}";$a=$product.IndexOf($first);$b=$product.IndexOf($last);$guard=$product.Substring($a,$b+$last.Length-$a)
 Verify ($guard.Contains('$i -lt 32')-and $guard.Contains('$seen.Add($ancestor)')-and $raw.Contains('$guard=$raw.Substring($begin,$end+$last.Length-$begin)'))
 $preflight=[IO.File]::ReadAllText((Join-Path $SourceRoot 'tests/windows_updater_runtime_controls.ps1'));Verify ($preflight.IndexOf("actor_mode='native_preflight'")-lt $preflight.IndexOf('$defs=Definitions')-and $preflight.Contains("helper_path='';helper_sha256='';backup_path=''")-and $preflight.Contains('Seal-WindowsUpdaterFailureSnapshot'))
 Write-Output ('PASS '+$checks+' actual task-controller/closed COM source controls; no native Scheduler, product, host or network action')
}finally{Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue}
