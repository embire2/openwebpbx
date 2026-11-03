# QA only: run the unchanged operator wrapper from a real independent SYSTEM task.
param([Parameter(Mandatory)][string]$Context,[switch]$Child,[switch]$ProbePayload)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
function Need([bool]$Value,[string]$Message){if(!$Value){throw $Message}}
function Hash([string]$Path){return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()}
function AssertOperatorTask($Task,[string]$Name,[string]$Executable,[string]$Arguments,[string]$Directory){
 $d=$Task.Definition;Need ($d.Actions.Count-eq 1) 'The independent operator requires exactly one action.';$a=$d.Actions.Item(1)
 Need ($Task.Name-ceq $Name-and $d.Principal.UserId-cin 'SYSTEM','S-1-5-18'-and [int]$d.Principal.LogonType-eq 5-and [int]$d.Principal.RunLevel-eq 1-and $d.Triggers.Count-eq 0-and [int]$a.Type-eq 0-and $a.Path-ceq $Executable-and $a.Arguments-ceq $Arguments-and $a.WorkingDirectory-ceq $Directory-and $d.Settings.Enabled-is [bool]-and $d.Settings.Enabled-and [int]$d.Settings.MultipleInstances-eq 2-and $d.Settings.ExecutionTimeLimit-ceq 'PT0S'-and [int]$d.Settings.RestartCount-eq 0) 'The independent operator task differs from its exact owned action.'
}
function AssertOperatorTaskSecurity([string]$Value){Need ($Value-cmatch '^O:BAG:BAD:P(?:AI)?(?:\(A;;FA;;;SY\)\(A;;FA;;;BA\)|\(A;;FA;;;BA\)\(A;;FA;;;SY\))$') 'The owned BA-owner, protected two-Full-Allow SYSTEM/Admin task security differs.'}
function WriteNew([string]$Path,$Value){
 $bytes=[Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 8 -Compress));$f=[IO.File]::Open($Path,'CreateNew','Write','None');try{$f.Write($bytes,0,$bytes.Length);$f.Flush($true)}finally{$f.Dispose()}
}
function ForwardOperatorTaskEvidence {
 foreach($entry in @(@($nativeOut,$false),@($nativeErr,$true))){if(Test-Path -LiteralPath $entry[0]){if($entry[1]){[Console]::Error.Write([IO.File]::ReadAllText($entry[0]))}else{[Console]::Out.Write([IO.File]::ReadAllText($entry[0]))}}}
 if($p.actor_mode-ceq 'operator'-and (Test-Path -LiteralPath $result)-and (Get-Item -LiteralPath $result).Length-le 16384){[Console]::Out.WriteLine('OPERATOR_TASK_RESULT_PRIVATE='+[IO.File]::ReadAllText($result))}
}
function TestNativeOperatorAncestry([string]$SourcePath,[string]$SourceHash,[string]$Output){
 Need ((Hash $SourcePath)-ceq $SourceHash) 'The exact unchanged product ancestry source is required.'
 $raw=[IO.File]::ReadAllText($SourcePath);$first='$ancestor=[uint32]$PID;';$last="if(!`$ended){throw 'The rollback process ancestry exceeds its safe bound.'}"
 $begin=$raw.IndexOf($first,[StringComparison]::Ordinal);$end=$raw.IndexOf($last,[StringComparison]::Ordinal);Need ($begin-ge 0-and $end-gt $begin-and $raw.IndexOf($first,$begin+1,[StringComparison]::Ordinal)-lt 0) 'The single unchanged32-hop product guard is required.'
 $guard=$raw.Substring($begin,$end+$last.Length-$begin);$nativeCim=Get-Command Get-CimInstance -CommandType Cmdlet;$rows=[Collections.Generic.List[object]]::new()
 function Get-CimInstance {
  [CmdletBinding()]param([string]$ClassName,[string]$Filter)
  $actual=@(& $nativeCim @PSBoundParameters)
  foreach($row in $actual){$rows.Add(@{pid=[uint32]$row.ProcessId;parent_pid=[uint32]$row.ParentProcessId;created_utc=if($row.CreationDate){$row.CreationDate.ToUniversalTime().ToString('o')}else{$null}})}
  return $actual
 }
 # No installed updater exists in this benign probe; the impossible PID is only
 # the unchanged guard's comparison operand. No SCM or product helper is called.
 $servicePid=[uint32]::MaxValue;$state='failed'
 try{. ([scriptblock]::Create($guard));$state='passed'}finally{WriteNew $Output @{schema=1;scope='benign-native-ancestry-only';state=$state;guard_sha256=([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($guard))|ForEach-Object ToString x2)-join '';rows=$rows.ToArray()}}
}
$item=Get-Item -LiteralPath $Context -Force
Need (!$item.PSIsContainer-and !($item.Attributes-band [IO.FileAttributes]::ReparsePoint)-and $item.Length-gt 0-and $item.Length-le 16384) 'An ordinary bounded operator context is required.'
$p=Get-Content -LiteralPath $Context -Raw|ConvertFrom-Json;$dir=Split-Path $Context -Parent;$id=[Guid]::Empty
Need ([Guid]::TryParseExact($p.operation_uuid,'D',[ref]$id)-and $id.ToString()-ceq $p.operation_uuid-and $p.schema-eq 1) 'The exact one-use operator identity is required.'
$full=[IO.Path]::GetFullPath($dir);$temp=[IO.Path]::GetFullPath([string]$p.runner_temp).TrimEnd([char[]]@('\','/'));$rootItem=Get-Item -LiteralPath $full -Force;$acl=Get-Acl -LiteralPath $full
Need ([IO.Path]::GetDirectoryName($full).Equals($temp,[StringComparison]::OrdinalIgnoreCase)-and (Split-Path $full -Leaf)-cmatch '^openwebpbx-updater-[a-f0-9]{32}$'-and (Split-Path $Context -Leaf)-ceq 'operator-restore-context.private.json'-and $rootItem.PSIsContainer-and !($rootItem.Attributes-band [IO.FileAttributes]::ReparsePoint)-and $acl.AreAccessRulesProtected) 'The original protected qualification work directory is required.'
$rules=@($acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]));Need ($rules.Count-eq 2-and $rules[0].IdentityReference.Value-cne $rules[1].IdentityReference.Value) 'The operator work ACL differs.'
foreach($r in $rules){Need ($r.IdentityReference.Value-cin 'S-1-5-18','S-1-5-32-544'-and $r.AccessControlType-eq 'Allow'-and $r.FileSystemRights-eq [Security.AccessControl.FileSystemRights]::FullControl) 'The operator work directory grants foreign access.'}
$script:operatorPrivateValidated=$true
trap{if($Child-and $script:operatorPrivateValidated){try{$file=Join-Path $full 'operator-task-native.err';if(!(Test-Path -LiteralPath $file)){$text=($_.ToString()+"`n"+$_.ScriptStackTrace);if($text.Length-gt 16384){$text=$text.Substring(0,16384)};[IO.File]::WriteAllText($file,$text,[Text.UTF8Encoding]::new($false))}}catch{}};break}
$ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe';$wrapper=Join-Path $PSScriptRoot 'windows-operator-restore-diagnostic.ps1'
Need ($p.actor_mode-cin 'operator','native_preflight'-and $p.run_id-cmatch '^[0-9]+$'-and $p.source_commit-cmatch '^[a-f0-9]{40}$'-and $p.wrapper_path-ceq $wrapper-and $p.failure_output-ceq (Join-Path $full 'operator-restore-error.safe.json')-and (Hash $PSCommandPath)-ceq $p.task_launcher_sha256-and (Hash $wrapper)-ceq $p.wrapper_sha256) 'The reviewed task launcher and wrapper are required.'
if($p.actor_mode-ceq 'operator'){Need ($p.helper_path-ceq 'C:\OpenWebPBX\tools\Upgrade-OpenWebPBX.ps1'-and (Hash $p.helper_path)-ceq $p.helper_sha256-and $p.backup_path) 'The exact installed operator helper and sealed backup are required.'}else{Need (!$p.helper_path-and !$p.helper_sha256-and !$p.backup_path) 'The benign native preflight cannot select a product helper or backup.'}
$budget=if($p.actor_mode-ceq 'operator'){1200}else{60};$issued=[DateTimeOffset]$p.operator_started_utc;$deadline=[DateTimeOffset]$p.operator_deadline_utc;Need ($issued-le [DateTimeOffset]::UtcNow-and $deadline-eq $issued.AddSeconds($budget)-and $deadline-gt [DateTimeOffset]::UtcNow) 'The original absolute operator/probe fence has expired or changed.'
$os=Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 3
Need ($p.computer_name-ceq $env:COMPUTERNAME-and $p.boot_utc-ceq $os.LastBootUpTime.ToUniversalTime().ToString('o')-and $os.ProductType-ne 1-and $os.Caption-match 'Windows Server 2025'-and [Environment]::OSVersion.Version.Build-ge 26100) 'The exact disposable Windows host generation is required.'
$result=Join-Path $full 'operator-task-result.private.json';$nativeOut=Join-Path $full 'operator-task-native.out';$nativeErr=Join-Path $full 'operator-task-native.err'
if($ProbePayload){Need (!$Child-and $p.actor_mode-ceq 'native_preflight'-and [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem-and $env:GITHUB_ACTIONS-ceq 'true'-and $env:RUNNER_ENVIRONMENT-ceq 'github-hosted'-and $env:GITHUB_REPOSITORY-ceq 'embire2/openwebpbx'-and $env:GITHUB_RUN_ID-ceq $p.run_id) 'Only the benign independent native probe may enter this branch.';TestNativeOperatorAncestry (Join-Path (Split-Path $PSScriptRoot -Parent) 'packaging/windows/UpgradeRecovery.Common.ps1') $p.ancestry_source_sha256 (Join-Path $full 'operator-ancestry.private.json');Write-Output 'NATIVE_INDEPENDENT_OPERATOR_TASK_PROBE';exit 0}
if($Child){
 Need ([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) 'The independent operator must actually run as SYSTEM.'
 # Only these four non-secret CI bindings cross the protected task boundary.
 $env:GITHUB_ACTIONS='true';$env:RUNNER_ENVIRONMENT='github-hosted';$env:GITHUB_REPOSITORY='embire2/openwebpbx';$env:GITHUB_RUN_ID=[string]$p.run_id
 $env:PSModulePath=$PSHOME+'\Modules;'+[Environment]::GetFolderPath('ProgramFiles')+'\WindowsPowerShell\Modules'
 Need (!(Test-Path $result)-and !(Test-Path $nativeOut)-and !(Test-Path $nativeErr)) 'The one-use operator child outputs are occupied.'
 $arguments=if($p.actor_mode-ceq 'operator'){'-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$wrapper+'" -Context "'+$Context+'"'}else{'-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Context "'+$Context+'" -ProbePayload'}
 $start=[Diagnostics.ProcessStartInfo]::new($ps,$arguments);$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.WorkingDirectory=$full
 Need ([DateTimeOffset]::UtcNow-lt $deadline) 'The original fence expired before the single native invocation.';$process=[Diagnostics.Process]::Start($start);$birth=$process.StartTime.ToUniversalTime().ToString('o');$out=$process.StandardOutput.ReadToEndAsync();$err=$process.StandardError.ReadToEndAsync()
 $remaining=[int][Math]::Max(0,[Math]::Min(1200000,($deadline-[DateTimeOffset]::UtcNow).TotalMilliseconds));$finished=$process.WaitForExit($remaining)
 if(!$finished){WriteNew (Join-Path $full 'operator-task-deadline.private.json') @{state='deadline';transaction_not_killed=$true;native_pid=$process.Id};while(!$process.WaitForExit(1000)){}}
 [IO.File]::WriteAllText($nativeOut,$out.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText($nativeErr,$err.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($false))
 $code=$process.ExitCode;WriteNew $result @{schema=1;operation_uuid=$p.operation_uuid;run_id=$p.run_id;source_commit=$p.source_commit;host=$p.computer_name;actor='independent-system-scheduler';native_pid=$process.Id;native_created_utc=$birth;native_finished_utc=[DateTimeOffset]::UtcNow.ToString('o');exit_code=$code;completed_inside_original_fence=($finished-and [DateTimeOffset]::UtcNow-lt $deadline)};$process.Dispose();exit $code
}
Need ($env:GITHUB_ACTIONS-ceq 'true'-and $env:RUNNER_ENVIRONMENT-ceq 'github-hosted'-and $env:GITHUB_REPOSITORY-ceq 'embire2/openwebpbx'-and $env:GITHUB_RUN_ID-ceq $p.run_id-and $env:GITHUB_SHA-ceq $p.source_commit-and $env:RUNNER_TEMP-ceq $p.runner_temp) 'Only the parent-authenticated current hosted qualification may create the operator task.'
function InvokeOperatorTaskController {
$name='OpenWebPBX-QA-IndependentOperator-'+$id.ToString('N');$scheduler=New-Object -ComObject Schedule.Service;$scheduler.Connect();$folder=$scheduler.GetFolder('\')
Need (!(Get-ScheduledTask -TaskName $name -TaskPath '\' -ErrorAction SilentlyContinue)-and !(Test-Path $result)) 'The one-use independent operator task is occupied.'
$definition=$scheduler.NewTask(0);$definition.Principal.UserId='SYSTEM';$definition.Principal.LogonType=5;$definition.Principal.RunLevel=1;$definition.Settings.Enabled=$true;$definition.Settings.MultipleInstances=2;$definition.Settings.ExecutionTimeLimit='PT0S';$definition.Settings.RestartCount=0
$arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Context "'+$Context+'" -Child';$action=$definition.Actions.Create(0);$action.Path=$ps;$action.Arguments=$arguments;$action.WorkingDirectory=$full
$retained=Join-Path $full 'operator-task-unfinished.private.json';WriteNew $retained @{schema=1;operation_uuid=$p.operation_uuid;task_name=$name;original_deadline_utc=$p.operator_deadline_utc;one_run=$true;no_kill_or_replay=$true}
Need ([DateTimeOffset]::UtcNow-lt $deadline) 'The original fence expired before task registration.'
$null=$folder.RegisterTaskDefinition($name,$definition,18,'SYSTEM',$null,5,'O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)');$task=$folder.GetTask($name);AssertOperatorTask $task $name $ps $arguments $full;$xml=$task.Xml;$security=$task.GetSecurityDescriptor(7);AssertOperatorTaskSecurity $security;$priorLastRun=[DateTime]$task.LastRunTime
WriteNew (Join-Path $full 'operator-task-intent.private.json') @{schema=1;operation_uuid=$p.operation_uuid;task_name=$name;original_deadline_utc=$p.operator_deadline_utc;one_run=$true;no_kill_or_replay=$true};Need ([DateTimeOffset]::UtcNow-lt $deadline) 'The original fence expired before the single task Run.';$null=$task.Run($null)
do{
 Need ([DateTimeOffset]::UtcNow-lt $deadline) 'Original operator20-minute fence expired; retain unfinished task and transaction without kill or replay.'
 $task=$folder.GetTask($name);AssertOperatorTask $task $name $ps $arguments $full
 Need ($task.Xml-ceq $xml-and $task.GetSecurityDescriptor(7)-ceq $security) 'The owned operator task changed; do not remove or restart it.'
 if([int]$task.State-eq 3-and [DateTime]$task.LastRunTime-gt $priorLastRun-and ((Test-Path $result)-or $task.LastTaskResult-ne 0)){break};Start-Sleep -Milliseconds 200
}while($true)
Need ([DateTimeOffset]::UtcNow-lt $deadline) 'Original operator fence expired before task acceptance.'
ForwardOperatorTaskEvidence
Need (Test-Path -LiteralPath $result) 'The independent task finished without a native completion receipt; retain task and fixture.'
$r=Get-Content -LiteralPath $result -Raw|ConvertFrom-Json
Need ($r.schema-eq 1-and $r.operation_uuid-ceq $p.operation_uuid-and $r.run_id-ceq $p.run_id-and $r.source_commit-ceq $p.source_commit-and $r.host-ceq $p.computer_name-and $r.actor-ceq 'independent-system-scheduler') 'The independent operator result identity differs.'
Need (($r.exit_code-is [int]-or $r.exit_code-is [long])-and $r.exit_code-ge 0-and $r.exit_code-le [int]::MaxValue-and [int]$task.LastTaskResult-eq $r.exit_code-and [DateTime]$task.LastRunTime-gt $priorLastRun) 'The exact terminal native/Scheduler exit or advanced LastRunTime is missing.'
Need ($r.completed_inside_original_fence-is [bool]-and $r.completed_inside_original_fence-and [DateTimeOffset]$r.native_created_utc-ge $issued-and [DateTimeOffset]$r.native_finished_utc-ge [DateTimeOffset]$r.native_created_utc-and [DateTimeOffset]$r.native_finished_utc-lt $deadline) 'The native operator completion is outside its original absolute fence.'
$task=$folder.GetTask($name);AssertOperatorTask $task $name $ps $arguments $full;Need ([int]$task.State-eq 3-and $task.Xml-ceq $xml-and $task.GetSecurityDescriptor(7)-ceq $security-and [DateTimeOffset]::UtcNow-lt $deadline) 'Only the same finished owned task may be removed.'
$folder.DeleteTask($name,0);Need (!(Get-ScheduledTask -TaskName $name -TaskPath '\' -ErrorAction SilentlyContinue)) 'The finished owned operator task was not removed.'
[IO.File]::Delete($retained);Need ([DateTimeOffset]::UtcNow-lt $deadline) 'The original operator fence expired before returning its exact child result.';return [int]$r.exit_code
}
exit (InvokeOperatorTaskController)
