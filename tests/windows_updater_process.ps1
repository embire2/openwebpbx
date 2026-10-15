#Requires -Version 5.1
[CmdletBinding()]param([string]$SourceRoot)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';$checks=0;$nativeIdentityChecks=0
if(!$SourceRoot){$SourceRoot=Split-Path $PSScriptRoot -Parent}
if($env:OS -ceq 'Windows_NT'){$env:PSModulePath=(Join-Path $PSHOME 'Modules')+';'+(Join-Path $env:ProgramFiles 'WindowsPowerShell/Modules')}
function Verify([bool]$Value){$script:checks++;if(!$Value){throw ('Updater process control failed at caller line '+(Get-PSCallStack)[1].ScriptLineNumber)}}
function Check([bool]$Value,[string]$Message){if(!$Value){throw $Message}}
function ReadAst([string]$Path){$tokens=$null;$errors=$null;$value=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors);Verify (@($errors).Count -eq 0);return $value}
$source=Join-Path $SourceRoot 'tests/windows-updater-qualification.ps1';$ast=ReadAst $source
foreach($name in 'OriginalProcessProofSource','RetainQualificationProcess','AssertOriginalProcessState','ManagerReopened'){
 $nodes=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true));Verify ($nodes.Count -eq 1);. ([ScriptBlock]::Create($nodes[0].Extent.Text))
}
$proofPath=Join-Path $SourceRoot 'tests/windows-upgrade-acceptance.ps1';$proofAst=ReadAst $proofPath
$definition=$proofAst.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'GetManagerOriginalExitProof'},$true)
$import=OriginalProcessProofSource $proofPath;Verify ($import.ToString() -ceq $definition.Extent.Text);. $import
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('openweb-updater-process-'+[Guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $temporary|Out-Null
$retainedProcesses=[Collections.Generic.List[Diagnostics.Process]]::new();$children=[Collections.Generic.List[Diagnostics.Process]]::new()
$executable=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName;$session=[Diagnostics.Process]::GetCurrentProcess().SessionId;$started=[DateTime]::UtcNow
$state=$temporary;$managerName='Owned-Fictional-Manager';$work=$temporary;$script:lookups=0;$script:waitCalls=0;$marker='PRIVATE_PROCESS_IDENTITY_MUST_NOT_ESCAPE'
$sleeper=Join-Path $temporary 'sleeper.ps1';[IO.File]::WriteAllText($sleeper,'Start-Sleep -Seconds 120',[Text.UTF8Encoding]::new($false))
function StartOwnedChild {
 $start=[Diagnostics.ProcessStartInfo]::new($executable);$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.WorkingDirectory=$temporary;$start.Arguments='-NoProfile -NonInteractive -File "'+$sleeper+'"'
 $child=[Diagnostics.Process]::Start($start);$children.Add($child);return $child
}
function Get-Process {$script:lookups++;return $script:unrelated}
function WaitManager([string]$Version,[int]$PreviousPid,[DateTime]$NotBefore){$script:waitCalls++;$script:lastWait=@{version=$Version;pid=$PreviousPid;not_before=$NotBefore};return $script:nextManager}
if($env:OS -ceq 'Windows_NT'){$ownerSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value}else{
 # Portable controls use real child handles/path/session/lifetime. CIM SID is
 # fictional only here; the Windows run uses actual CIM/GetOwnerSid unchanged.
 $ownerSid='portable-fixture-owner'
 function Get-CimInstance([string]$ClassName,[string]$Filter){if($ClassName -cne 'Win32_Process' -or $Filter -cnotmatch '^ProcessId=([0-9]+)$'){throw 'Unexpected fictional CIM boundary'};$child=[Diagnostics.Process]::GetProcessById([int]$Matches[1]);try{return [pscustomobject]@{ExecutablePath=$child.Path;SessionId=$child.SessionId}}finally{$child.Dispose()}}
 function Invoke-CimMethod($InputObject,[string]$MethodName){if($MethodName -cne 'GetOwnerSid'){throw 'Unexpected fictional owner query'};return [pscustomobject]@{ReturnValue=0;Sid=$ownerSid}}
}
function RefusesState($Held,[int]$ExpectedPid,[bool]$Exited){$refused=$false;try{AssertOriginalProcessState $Held $ExpectedPid $Exited 'Closed fixed failure'}catch{$refused=$_.Exception.Message -ceq 'Closed fixed failure'};Verify $refused}
try{
 # Actual AST loader refuses malformed/ambiguous input and never runs top level.
 $fake=Join-Path $temporary 'proof-input.ps1'
 [IO.File]::WriteAllText($fake,$definition.Extent.Text+"`nthrow 'TOP_LEVEL_MUST_NOT_RUN'");$isolated=OriginalProcessProofSource $fake;Verify ($isolated.ToString() -ceq $definition.Extent.Text)
 foreach($text in 'throw "no proof"',($definition.Extent.Text+"`n"+$definition.Extent.Text),'function {'){
  [IO.File]::WriteAllText($fake,$text);$refused=$false;try{$null=OriginalProcessProofSource $fake}catch{$refused=$true};Verify $refused
 }
 $worker=StartOwnedChild;$manager=StartOwnedChild;$replacement=StartOwnedChild;$script:unrelated=$replacement;$script:nextManager=$replacement
 $heldWorker=RetainQualificationProcess ([Diagnostics.Process]::GetProcessById($worker.Id)) ([int]$worker.Id) $executable $ownerSid $session $started
 $heldManager=RetainQualificationProcess ([Diagnostics.Process]::GetProcessById($manager.Id)) ([int]$manager.Id) $executable $ownerSid $session $started
 Verify ($heldWorker.pid -is [int] -and $heldWorker.start_ticks -is [long] -and $heldWorker.handle -is [IntPtr] -and $heldWorker.identity_verified -is [bool])
 Verify ($retainedProcesses.Count -eq 2)
 if($env:OS -ceq 'Windows_NT'){$nativeIdentityChecks+=2}
 AssertOriginalProcessState $heldWorker ([int]$worker.Id) $false 'Original worker must remain live';Verify $true
 RefusesState $heldWorker ([int]$worker.Id) $true
 foreach($bad in $null,@{},@{process=$replacement},$marker){RefusesState $bad ([int]$worker.Id) $false;RefusesState $bad ([int]$worker.Id) $true}
 foreach($key in 'handle','pid','start_ticks','identity_verified'){
  $bad=$heldWorker.Clone();$bad[$key]=switch($key){'handle'{[IntPtr]::Zero};'pid'{[int]$worker.Id+1};'start_ticks'{[long]0};'identity_verified'{$false}}
  RefusesState $bad ([int]$worker.Id) $false;RefusesState $bad ([int]$worker.Id) $true
 }
 foreach($mismatch in 'path','sid','session','start','pid'){
  $expectedPath=$executable;$expectedSid=$ownerSid;$expectedSession=$session;$expectedStart=$started;$expectedPid=[int]$replacement.Id
  switch($mismatch){'path'{$expectedPath=$marker};'sid'{$expectedSid='S-1-0-0'};'session'{$expectedSession++};'start'{$expectedStart=[DateTime]::UtcNow.AddMinutes(5)};'pid'{$expectedPid=[int]$worker.Id}}
  $refused=$false;try{$null=RetainQualificationProcess ([Diagnostics.Process]::GetProcessById($replacement.Id)) $expectedPid $expectedPath $expectedSid $expectedSession $expectedStart}catch{$refused=$_.Exception.Message -ceq 'The original qualification process identity is unavailable before the request.'}
  Verify $refused;Verify ($retainedProcesses.Count -eq 2);if($env:OS -ceq 'Windows_NT'){$nativeIdentityChecks++}
 }
 New-Item -ItemType Directory -Path (Join-Path $state 'updates')|Out-Null;$journal=Join-Path $state 'updates/install-journal.json'
 [IO.File]::WriteAllText($journal,'{"manager_tasks":["Owned-Fictional-Manager"]}')
 $refused=$false;try{$null=ManagerReopened '1.0.13' $heldManager $started}catch{$refused=$_.Exception.Message -ceq 'The updater did not close the original owned installed manager.'};Verify $refused;Verify ($waitCalls -eq 0)
 $manager.Kill();Verify ($manager.WaitForExit(10000))
 [IO.File]::WriteAllText($journal,'{"manager_tasks":["foreign"]}');$refused=$false;try{$null=ManagerReopened '1.0.13' $heldManager $started}catch{$refused=$_.Exception.Message -ceq 'The genuine product transaction must record the actual interactive restart task.'};Verify $refused;Verify ($waitCalls -eq 0)
 [IO.File]::WriteAllText($journal,'{"manager_tasks":["Owned-Fictional-Manager"]}')
 $result=ManagerReopened '1.0.13' $heldManager $started;Verify ([object]::ReferenceEquals($result,$replacement));Verify ($lastWait.version -ceq '1.0.13' -and $lastWait.pid -eq $manager.Id -and $lastWait.not_before -eq $started)
 $heldReplacement=RetainQualificationProcess ([Diagnostics.Process]::GetProcessById($replacement.Id)) ([int]$replacement.Id) $executable $ownerSid $session $started
 AssertOriginalProcessState $heldWorker ([int]$worker.Id) $false 'Same original worker after rollback';Verify $true
 $worker.Kill();Verify ($worker.WaitForExit(10000));AssertOriginalProcessState $heldWorker ([int]$worker.Id) $true 'Old worker naturally exited';Verify $true
 RefusesState $heldWorker ([int]$worker.Id) $false
 $normalStarted=[DateTime]::UtcNow;$next=StartOwnedChild;$script:nextManager=$next
 $replacement.Kill();Verify ($replacement.WaitForExit(10000))
 $result=ManagerReopened '1.0.14' $heldReplacement $normalStarted;Verify ([object]::ReferenceEquals($result,$next));Verify ($lastWait.version -ceq '1.0.14' -and $lastWait.pid -eq $replacement.Id -and $lastWait.not_before -eq $normalStarted)
 $proof=GetManagerOriginalExitProof $heldWorker ([int]$worker.Id)
 Verify (@($proof.Keys|Where-Object {$_ -cnotin 'manager_original_handle_pinned','manager_original_identity_verified','manager_original_exit_observed','manager_original_process_class','manager_original_has_exited'}).Count -eq 0)
 $serialized=$proof|ConvertTo-Json -Compress;Verify (!$serialized.Contains($marker) -and !$serialized.Contains($temporary) -and !$serialized.Contains($ownerSid))
 Verify ($lookups -eq 0)
 $heldWorker.process.Dispose();RefusesState $heldWorker ([int]$worker.Id) $true
}finally{
 foreach($held in $retainedProcesses){$held.Dispose()}
 foreach($child in $children){try{if(!$child.HasExited){$child.Kill();$null=$child.WaitForExit(10000)}}finally{$child.Dispose()}}
 Remove-Item -LiteralPath $temporary -Recurse -Force
}
Verify (!(Test-Path -LiteralPath $temporary))
@{schema=1;state='passed';actual_owned_process_controls=$checks;native_windows_identity_controls=$nativeIdentityChecks;owned_children_and_files_removed=$true;actual_service_or_manager_ui_qualification=$false}|ConvertTo-Json -Compress
