#Requires -Version 5.1
[CmdletBinding()]param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';$checks=0;$nativeIdentityChecks=0
function Verify([bool]$Value){$script:checks++;if(!$Value){throw ('Owned process control failed at caller line '+(Get-PSCallStack)[1].ScriptLineNumber)}}
function LoadAst([string]$Path){$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$t,[ref]$e);Verify (@($e).Count -eq 0);return $ast}
function Check([bool]$Value,[string]$Message){if(!$Value){throw $Message}}
$source=Join-Path $SourceRoot 'tests/windows-upgrade-acceptance.ps1';$ast=LoadAst $source
foreach($name in 'WriteJson','GetManagerOriginalExitProof','CurrentManagerPid','AssertManagerReopened'){
 $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));Verify ($nodes.Count -eq 1);. ([ScriptBlock]::Create($nodes[0].Extent.Text))
}
$full=[IO.File]::ReadAllText($source)
Verify (([regex]::Matches($full,'\$oldManager=CurrentManagerPid;\$managerInvocation=\[DateTime\]::UtcNow')).Count -eq 2)
Verify (([regex]::Matches($full,'AssertManagerReopened \$oldManager \$managerInvocation')).Count -eq 2)
Verify ($full.Contains('finally{foreach($heldProcess in $managerHeldHandles){$heldProcess.Dispose()}}'))
$wait=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'WaitManager'},$true).Extent.Text
foreach($text in '$process.Id -ne $PreviousPid','$process.StartTime.ToUniversalTime() -ge $NotBefore','$process.MainWindowHandle -ne [IntPtr]::Zero','$process.Responding','$process.MainWindowTitle -eq $title','(ManagerTaskValid)'){Verify ($wait.Contains($text))}
$assertBody=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'AssertManagerReopened'},$true).Extent.Text
Verify ($assertBody.Contains('Check (@((Journal).manager_tasks) -contains $managerName)'))
Verify ($assertBody.Contains('$visible=WaitManager $PreviousPid $NotBefore'))
Verify (!$assertBody.Contains('Get-Process -Id'))
$suite=LoadAst (Join-Path $SourceRoot 'tests/windows-suite.ps1')
foreach($node in @($suite.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -clike 'Safe*'},$true))){. ([ScriptBlock]::Create($node.Extent.Text))}

$temporary=Join-Path ([IO.Path]::GetTempPath()) ('openweb-held-process-'+[Guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $temporary|Out-Null
$childScript=Join-Path $temporary 'owned-sleeper.ps1';[IO.File]::WriteAllText($childScript,'Start-Sleep -Seconds 120',[Text.UTF8Encoding]::new($false))
$launched=[Collections.Generic.List[Diagnostics.Process]]::new();$managerHeldHandles=[Collections.Generic.List[Diagnostics.Process]]::new();$managerHeldProcess=$null;$managerClosureFailure=$null
$managerExe=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName;$managerAvailable=$true;$managerName='Owned-Fictional-Manager';$managerSession=[Diagnostics.Process]::GetCurrentProcess().SessionId;$managerStarted=[DateTime]::UtcNow;$work=$temporary
$report=@{gates=@{}};$script:lookupCalls=0;$script:waitCalls=0
# Only the UI/journal boundaries are fictional. The handle, lifetime and (on
# Windows) CIM owner/path/session checks use the actual owned child processes.
function WaitManager([int]$PreviousPid=0,[DateTime]$NotBefore=[DateTime]::MinValue){$script:waitCalls++;return $script:fixtureVisible}
function OwnedManagerProcesses {return @($script:fixtureVisible)}
function Journal {return @{manager_tasks=@($managerName)}}
function Get-Process {$script:lookupCalls++;return $script:foreign}
function StartOwnedChild {
 $info=[Diagnostics.ProcessStartInfo]::new($managerExe);$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.Arguments='-NoProfile -NonInteractive -File "'+$childScript+'"';$info.WorkingDirectory=$temporary
 $process=[Diagnostics.Process]::Start($info);$launched.Add($process);return $process
}
function RefusesClosure([int]$OriginalPid){
 $refused=$false;try{AssertManagerReopened $OriginalPid $managerStarted 'fictional'}catch{$refused=$_.Exception.Message -ceq 'The helper did not close the original owned desktop manager.'};Verify $refused;Verify (!$report.gates.ContainsKey('fictional'))
}
try{
 $original=StartOwnedChild;$foreign=StartOwnedChild;$script:foreign=$foreign;$script:fixtureVisible=[Diagnostics.Process]::GetProcessById($original.Id)
 if($env:OS -ceq 'Windows_NT'){
  $managerSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $originalPid=CurrentManagerPid;Verify ($originalPid -eq $original.Id);Verify ($managerHeldHandles.Count -eq 1);Verify ((Get-Content (Join-Path $work 'manager-held-1.json') -Raw|ConvertFrom-Json).handle_pinned);$nativeIdentityChecks++
  $saved=$managerHeldProcess
  foreach($mismatch in 'path','sid','session','start'){
   $oldPath=$managerExe;$oldSid=$managerSid;$oldSession=$managerSession;$oldStart=$managerStarted
   switch($mismatch){'path'{$managerExe=$childScript};'sid'{$managerSid='S-1-0-0'};'session'{$managerSession++};'start'{$managerStarted=[DateTime]::UtcNow.AddMinutes(5)}}
   $script:fixtureVisible=[Diagnostics.Process]::GetProcessById($original.Id);$rejected=$false
   try{$null=CurrentManagerPid}catch{$rejected=$_.Exception.Message -ceq 'The original owned responsive manager is unavailable before the helper runs.'}
   Verify $rejected;Verify ($managerHeldHandles.Count -eq 1);$nativeIdentityChecks++
   $managerExe=$oldPath;$managerSid=$oldSid;$managerSession=$oldSession;$managerStarted=$oldStart
  }
  $managerHeldProcess=$saved
 }else{
  # Portable lifetime controls do not claim Windows CIM ownership coverage.
  $p=$script:fixtureVisible;$handle=$p.Handle;$managerHeldHandles.Add($p);$originalPid=$p.Id
  $managerHeldProcess=@{process=$p;handle=$handle;pid=[int]$p.Id;start_ticks=[long]$p.StartTime.ToUniversalTime().Ticks;identity_verified=$true}
 }
 $live=GetManagerOriginalExitProof $managerHeldProcess $originalPid
 Verify $live.manager_original_handle_pinned;Verify $live.manager_original_identity_verified;Verify $live.manager_original_exit_observed;Verify (!$live.manager_original_has_exited);Verify ($live.manager_original_process_class -ceq 'live_original')
 RefusesClosure $originalPid;Verify ($managerClosureFailure.manager_original_process_class -ceq 'live_original');Verify ($lookupCalls -eq 0)
 foreach($bad in $null,@{},@{process=$foreign},'not-held'){
  $proof=GetManagerOriginalExitProof $bad $originalPid;Verify (!$proof.manager_original_exit_observed);Verify ($proof.manager_original_process_class -ceq 'unavailable')
 }
 foreach($key in 'handle','pid','start_ticks','identity_verified'){
  $bad=$managerHeldProcess.Clone();$bad[$key]=switch($key){'handle'{[IntPtr]::Zero};'pid'{$originalPid+1};'start_ticks'{[long]0};'identity_verified'{$false}}
  $proof=GetManagerOriginalExitProof $bad $originalPid;Verify (!$proof.manager_original_exit_observed)
 }
 $original.Kill();Verify ($original.WaitForExit(10000));Verify (!$foreign.HasExited)
 $exited=GetManagerOriginalExitProof $managerHeldProcess $originalPid
 Verify $exited.manager_original_handle_pinned;Verify $exited.manager_original_identity_verified;Verify $exited.manager_original_exit_observed;Verify $exited.manager_original_has_exited;Verify ($exited.manager_original_process_class -ceq 'exited_original')
 $script:fixtureVisible=$foreign;AssertManagerReopened $originalPid $managerStarted 'fictional';Verify ($report.gates.fictional -ceq 'passed');Verify ($lookupCalls -eq 0)
 $managerHeldProcess.process.Dispose();$disposed=GetManagerOriginalExitProof $managerHeldProcess $originalPid;Verify (!$disposed.manager_original_exit_observed);Verify ($disposed.manager_original_process_class -ceq 'unavailable')

 $marker='PRIVATE_MANAGER_CONTEXT_MUST_NOT_ESCAPE';$record=@{active_case='manager_original_closed';manager_original_handle_pinned=$true;manager_original_identity_verified=$true;manager_original_exit_observed=$true;manager_original_has_exited=$false;manager_original_process_class='live_original';private_path=$temporary;private_identity=$marker}
 $safe=SafeFailureFields ([pscustomobject]$record);Verify ($safe.Count -eq 6);Verify (!(ConvertTo-Json -InputObject $safe -Compress).Contains($marker));Verify (!(ConvertTo-Json -InputObject $safe -Compress).Contains($temporary))
 foreach($key in 'manager_original_handle_pinned','manager_original_identity_verified','manager_original_exit_observed','manager_original_has_exited'){
  foreach($bad in 'true',1,@($true,$marker),$null){$copy=$record.Clone();$copy[$key]=$bad;$safe=SafeFailureFields ([pscustomobject]$copy);Verify (!$safe.ContainsKey($key));Verify (!(ConvertTo-Json -InputObject $safe -Compress).Contains($marker))}
 }
 foreach($bad in $marker,$true,@('live_original',$marker),'LIVE_ORIGINAL',$null){$copy=$record.Clone();$copy.manager_original_process_class=$bad;$safe=SafeFailureFields ([pscustomobject]$copy);Verify (!$safe.ContainsKey('manager_original_process_class'));Verify (!(ConvertTo-Json -InputObject $safe -Compress).Contains($marker))}
 foreach($bad in 'manager_reopened',$true,@('manager_original_closed',$marker),$null){$copy=$record.Clone();$copy.active_case=$bad;$safe=SafeFailureFields ([pscustomobject]$copy);Verify (@($safe.Keys|Where-Object {$_ -clike 'manager_original_*'}).Count -eq 0)}
 $roundtrip=$record|ConvertTo-Json|ConvertFrom-Json;$safe=SafeFailureFields $roundtrip;Verify ($safe.manager_original_has_exited -is [bool] -and !$safe.manager_original_has_exited)
}finally{
 foreach($held in $managerHeldHandles){$held.Dispose()}
 foreach($child in $launched){try{if(!$child.HasExited){$child.Kill();$null=$child.WaitForExit(10000)}}finally{$child.Dispose()}}
 Remove-Item -LiteralPath $temporary -Recurse -Force
}
Verify (!(Test-Path -LiteralPath $temporary))
@{schema=1;state='passed';actual_process_and_projection_controls=$checks;native_windows_identity_controls=$nativeIdentityChecks;owned_children_and_files_removed=$true;actual_manager_ui_qualification=$false}|ConvertTo-Json -Compress
