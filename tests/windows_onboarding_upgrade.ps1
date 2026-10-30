# Actual migration functions with private files and an in-memory Task Scheduler.
# No installed task, service, IIS, account, policy or runtime is changed.
[CmdletBinding()]
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent),[Parameter(Mandatory)][string]$Public21PackageRoot)
$ErrorActionPreference='Stop';$checks=0
function Check([bool]$Value,[string]$Name){if(!$Value){throw $Name};$script:checks++}
function Refuses([scriptblock]$Body,[string]$Name){$failed=$false;try{& $Body|Out-Null}catch{$failed=$true};Check $failed $Name}
. (Join-Path $SourceRoot 'packaging/windows/Onboarding-Upgrade.Common.ps1')
$actualCreate=(Get-Item function:New-OpenWebCommittedOnboardingTask).ScriptBlock
$actualSnapshot=(Get-Item function:Get-OpenWebOnboardingTaskSnapshot).ScriptBlock
$actualSecurity=(Get-Item function:Assert-OpenWebOnboardingTaskSecurity).ScriptBlock
$security='O:SYG:SYD:(A;;FA;;;SY)(A;;FA;;;BA)'
$native=[Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
if($native){& $actualSecurity @($security,$security);Check $true 'Native descriptor positive';foreach($bad in 'O:WDG:SYD:(A;;FA;;;SY)','O:SYG:SYD:(A;;FA;;;WD)','not-sddl'){Refuses {& $actualSecurity @($security,$bad)} 'Native foreign-owner/write/malformed descriptor refused'}}
else{function Assert-OpenWebOnboardingTaskSecurity([string[]]$Descriptors){Check ($Descriptors.Count -eq 2 -and $Descriptors[0] -ceq $script:security -and $Descriptors[1] -ceq $script:security) 'Portable descriptor adapter only'}}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('openweb-onboarding-upgrade-'+[Guid]::NewGuid().ToString('N'));New-Item -ItemType Directory $temp|Out-Null
$root=Join-Path $temp 'app';$state=Join-Path $temp 'state';$engine=Join-Path $temp 'engine';$bundle=Join-Path (Join-Path $state 'updates/recovery-entry') ('a'*32);$backup=Join-Path $state 'backups/original21'
foreach($p in $root,$state,$engine,$bundle,$backup,(Join-Path $root 'tools'),(Join-Path $backup 'tools')){New-Item -ItemType Directory -Path $p -Force|Out-Null}
function WriteBytes([string]$Path,[byte[]]$Bytes){[IO.File]::WriteAllBytes($Path,$Bytes)}
function WriteJson([string]$Path,$Value){WriteBytes $Path ([Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 20 -Compress)))}
function Get-OpenWebRecoveryHash([byte[]]$Bytes){$s=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($s.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant()}finally{$s.Dispose()}}
function Read-OpenWebRecoveryBytes([string]$Path,[int]$Maximum=16777216){$f=Get-Item -LiteralPath $Path;Check (!$f.PSIsContainer -and !($f.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $f.Length -le $Maximum) 'Private ordinary fixture bytes';return ,[IO.File]::ReadAllBytes($Path)}
function Assert-OpenWebRecoveryProtected([string]$Path,[switch]$Directory,[switch]$Private){$f=Get-Item -LiteralPath $Path;Check ([bool]$f.PSIsContainer -eq [bool]$Directory -and !($f.Attributes -band [IO.FileAttributes]::ReparsePoint)) 'Ordinary fixture protection adapter'}
function Assert-OpenWebRecoveryLock([IO.FileStream]$MaintenanceLock,[string]$StateRoot){Check ($MaintenanceLock.CanRead -and $MaintenanceLock.CanWrite -and $MaintenanceLock.Name -ceq (Join-Path $StateRoot 'upgrade.lock')) 'Actual private fixture lock'}
function Get-OpenWebRestoreGate([string]$StateRoot){return @{Blocked=$script:held}}
function Get-OpenWebUpgradeRecoveryMetadata($Entry,[string]$Root,[string]$StateRoot,[string]$EngineRoot,[switch]$AllowCompleted){Check ($AllowCompleted -and $Entry.metadata_sha256 -ceq $script:entry.metadata_sha256) 'Existing recovery verifier is called with exact sealed entry';return $script:metadata}
$runtime=Join-Path $state 'runtime.json';WriteJson $runtime @{Onboarding=@{Required=$false};fixture='unchanged'}
if($native){$runtimeSddl=(Get-Acl -LiteralPath $runtime).Sddl}else{$runtimeSddl='portable-fixture-acl';function Get-Acl([string]$LiteralPath){Check ($LiteralPath -ceq $script:runtime) 'Only runtime ACL adapter';return @{Sddl=$script:runtimeSddl}}}
$runtimeBefore=[IO.File]::ReadAllBytes($runtime)
WriteJson (Join-Path $backup 'support-state.json') @{schema=1;Tasks=@{'OpenWebPBX-TenantDomains'=@{Exists=$true;Enabled=$true}}}
foreach($n in 'Upgrade-OpenWebPBX.ps1','Support-Recovery.ps1'){WriteBytes (Join-Path $backup ('tools/'+$n)) ([IO.File]::ReadAllBytes((Join-Path $Public21PackageRoot $n)))}
$oldHash=Get-OpenWebRecoveryHash ([IO.File]::ReadAllBytes((Join-Path $backup 'tools/Upgrade-OpenWebPBX.ps1')))
Check ($oldHash -ceq 'b54d22c469ca2cbd8747787835c0056a562162cc3e5682b25106bd805826d4e2') 'Actual immutable public21 helper bytes'
$backupFiles=@{};foreach($n in 'support-state.json','tools/Upgrade-OpenWebPBX.ps1','tools/Support-Recovery.ps1'){$backupFiles[$n]=Get-OpenWebRecoveryHash ([IO.File]::ReadAllBytes((Join-Path $backup $n)))}
WriteJson (Join-Path $backup 'backup-manifest.json') @{schema=1;files=$backupFiles};$backupManifestHash=Get-OpenWebRecoveryHash ([IO.File]::ReadAllBytes((Join-Path $backup 'backup-manifest.json')))
WriteJson (Join-Path $backup 'complete.json') @{version='1.0.21';integrity_sha256=$backupManifestHash}
$manifestFiles=@{};foreach($n in 'Install-Onboarding.ps1','Ensure-OnboardingUpgrade.ps1','Onboarding-Upgrade.Common.ps1','onboarding.py','onboarding.php','webhotel-onboarding.py','tenant-domains.py'){$source=Join-Path $SourceRoot ($(if($n.EndsWith('.py') -or $n -ceq 'onboarding.php'){'packaging/debian/'}else{'packaging/windows/'})+$n);$bytes=[IO.File]::ReadAllBytes($source);WriteBytes (Join-Path $root ('tools/'+$n)) $bytes;$manifestFiles[$n]=Get-OpenWebRecoveryHash $bytes}
WriteJson (Join-Path $bundle 'release-manifest.json') @{version='1.0.22';files=$manifestFiles};WriteBytes (Join-Path $bundle 'VERSION') ([Text.Encoding]::UTF8.GetBytes('1.0.22'));WriteBytes (Join-Path $bundle 'runtime.before.json') $runtimeBefore;WriteBytes (Join-Path $bundle 'runtime.after.json') $runtimeBefore
$sealedFiles=@{};foreach($n in 'release-manifest.json','VERSION','runtime.before.json','runtime.after.json'){$sealedFiles[$n]=Get-OpenWebRecoveryHash ([IO.File]::ReadAllBytes((Join-Path $bundle $n)))}
$metadata=[ordered]@{schema=1;computer=[Environment]::MachineName;root=[IO.Path]::GetFullPath($root);state_root=[IO.Path]::GetFullPath($state);engine_root=[IO.Path]::GetFullPath($engine);bundle_path=[IO.Path]::GetFullPath($bundle);backup_path=[IO.Path]::GetFullPath($backup);previous_version='1.0.21';version='1.0.22';files=$sealedFiles;source_manifest_sha256=$sealedFiles['release-manifest.json'];backup_manifest_sha256=$backupManifestHash;backup_complete_sha256=(Get-OpenWebRecoveryHash ([IO.File]::ReadAllBytes((Join-Path $backup 'complete.json'))));original_helper_sha256=$oldHash;runtime_before_sha256=(Get-OpenWebRecoveryHash $runtimeBefore);runtime_sddl=$runtimeSddl;runtime_attributes=[int](Get-Item $runtime).Attributes}
WriteJson (Join-Path $bundle 'entry.json') $metadata;WriteBytes (Join-Path $bundle 'recovery-launcher.ps1') ([Text.Encoding]::UTF8.GetBytes('# sealed test launcher'))
$entry=[pscustomobject]@{schema=1;bundle_path=$bundle;metadata_sha256=(Get-OpenWebRecoveryHash ([IO.File]::ReadAllBytes((Join-Path $bundle 'entry.json'))));launcher_sha256=(Get-OpenWebRecoveryHash ([IO.File]::ReadAllBytes((Join-Path $bundle 'recovery-launcher.ps1'))))}
function Journal([string]$Phase='complete',[bool]$Failed=$false){WriteJson (Join-Path $state 'updates/install-journal.json') @{state='completed';version='1.0.22';previous_version='1.0.21';backup_path=$backup;recovery_entry=$entry;operator_rollback=$false;finalization=@{phase=$Phase;failed=$Failed}}}
WriteJson (Join-Path $state 'installation.json') @{Version='1.0.22';Completed=$true};Journal
$script:task=$null;$script:registrations=0;$script:deletions=0;$script:held=$false;$script:crash=$false
function Get-OpenWebOnboardingTaskSnapshot {return $script:task}
function Snapshot([string]$Source,[bool]$Enabled=$true){$en=if($Enabled){'true'}else{'false'};return @{enabled=$Enabled;security=$script:security;fileAcl=$script:security;xml=('<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><RegistrationInfo><Description>OpenWeb PBX owned installation registration and activation worker</Description><Source>'+[Security.SecurityElement]::Escape($Source)+'</Source></RegistrationInfo><Principals><Principal><UserId>SYSTEM</UserId><LogonType>ServiceAccount</LogonType><RunLevel>HighestAvailable</RunLevel></Principal></Principals><Triggers><BootTrigger/><TimeTrigger><StartBoundary>2026-01-01T00:00:00</StartBoundary><Repetition><Interval>PT1M</Interval></Repetition></TimeTrigger></Triggers><Settings><Enabled>'+$en+'</Enabled><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><ExecutionTimeLimit>PT20M</ExecutionTimeLimit><StartWhenAvailable>true</StartWhenAvailable></Settings><Actions><Exec><Command>'+[Security.SecurityElement]::Escape((Join-Path $root 'backup-runtime/python.exe'))+'</Command><Arguments>-I -B &quot;'+[Security.SecurityElement]::Escape((Join-Path $root 'tools/onboarding.py'))+'&quot; --tick</Arguments><WorkingDirectory>'+[Security.SecurityElement]::Escape((Join-Path $root 'tools'))+'</WorkingDirectory></Exec></Actions></Task>')}}
function New-OpenWebCommittedOnboardingTask([string]$Root,[string]$Source){Check (!$script:task -and $Source -cmatch '^openwebpbx-onboarding-v1:[a-f0-9]{32}:[a-f0-9]{64}:[a-f0-9]{64}$') 'Provenance is part of first atomic creation';$script:task=Snapshot $Source;$script:registrations++;if($script:crash){throw 'Owned crash immediately after atomic registration'}}
function Unregister-ScheduledTask([string]$TaskName,[string]$TaskPath,[switch]$Confirm){Check ($TaskName -ceq 'OpenWebPBX-Onboarding' -and $TaskPath -ceq '\') 'Only owned root task can be removed';$script:deletions++;$script:task=$null}
$lock=[IO.File]::Open((Join-Path $state 'upgrade.lock'),'CreateNew','ReadWrite','None')
try{
 $origin=Get-OpenWebOnboardingUpgradeOrigin $entry $root $state $engine $backup;Check ($origin.previous_version -ceq '1.0.21') 'Real sealed provenance positive'
 foreach($phase in 'service_selection','background_tasks','manager_resume'){Journal $phase;$result=Ensure-OpenWebCommittedOnboardingTask $root $state $engine $lock;Check ($result.state -ceq 'deferred' -and $registrations -eq 0) 'No task before full finalization'}
 Journal 'complete' $true;Check ((Ensure-OpenWebCommittedOnboardingTask $root $state $engine $lock).state -ceq 'deferred') 'Failed finalization defers';Journal
 $held=$true;Check ((Ensure-OpenWebCommittedOnboardingTask $root $state $engine $lock).state -ceq 'deferred' -and !$task) 'Restore hold defers without task';$held=$false
 $completePath=Join-Path $backup 'complete.json';$saved=[IO.File]::ReadAllBytes($completePath);WriteJson $completePath @{version='1.0.20'};Refuses {Ensure-OpenWebCommittedOnboardingTask $root $state $engine $lock} 'Stale backup seal refused';WriteBytes $completePath $saved
 $result=Ensure-OpenWebCommittedOnboardingTask $root $state $engine $lock;Check ($result.state -ceq 'created' -and $registrations -eq 1) 'Postcommit creates once';$tag=Assert-OpenWebOnboardingTaskSnapshot $task $root
 Check ($task.Count -eq 4 -and !$task.ContainsKey('source') -and $actualSnapshot.ToString().Contains('return @{xml=')) 'Model uses the actual getter four-field shape, never an invented source property'
 foreach($change in @(
  @('<BootTrigger/>','<BootTrigger><Enabled>false</Enabled></BootTrigger>'),
  @('<TimeTrigger>','<TimeTrigger><Enabled>false</Enabled>'),
  @('<TimeTrigger>','<TimeTrigger><EndBoundary>2030-01-01T00:00:00</EndBoundary>'),
  @('<BootTrigger/>','<BootTrigger><EndBoundary>2030-01-01T00:00:00</EndBoundary></BootTrigger>'),
  @('<Interval>PT1M</Interval>','<Interval>PT1M</Interval><Duration>PT5M</Duration>'),
  @('<Interval>PT1M</Interval>','<Interval>PT1M</Interval><StopAtDurationEnd>true</StopAtDurationEnd>'),
  @('<TimeTrigger>','<TimeTrigger><RandomDelay>PT1M</RandomDelay>'),
  @('<BootTrigger/>','<BootTrigger><Delay>PT1M</Delay></BootTrigger>'),
  @('<TimeTrigger>','<TimeTrigger><ExecutionTimeLimit>PT1H</ExecutionTimeLimit>'),
  @('<LogonType>ServiceAccount</LogonType>','<LogonType>InteractiveToken</LogonType>'),
  @('<RunLevel>HighestAvailable</RunLevel>','<RunLevel>LeastPrivilege</RunLevel>'),
  @('</Actions>','<Exec><Command>foreign.exe</Command></Exec></Actions>')
 )){$bad=Snapshot $tag;$bad.xml=$bad.xml.Replace($change[0],$change[1]);Refuses {Assert-OpenWebOnboardingTaskSnapshot $bad $root} 'Disabled/finite/foreign full task shape refused'}
 Check ((Ensure-OpenWebCommittedOnboardingTask $root $state $engine $lock).state -ceq 'existing' -and $registrations -eq 1) 'Idempotent no second registration'
 $task=Snapshot '' $false;Check ((Ensure-OpenWebCommittedOnboardingTask $root $state $engine $lock).enabled -eq $false -and $registrations -eq 1 -and !(Assert-OpenWebOnboardingTaskSnapshot $task $root)) 'Preexisting disabled choice and source untouched'
 $task.xml=$task.xml.Replace('<Interval>PT1M</Interval>','<Interval>PT1M</Interval><StopAtDurationEnd>true</StopAtDurationEnd>');$nativeDefault=$task.xml;Check ((Ensure-OpenWebCommittedOnboardingTask $root $state $engine $lock).enabled -eq $false -and $task.xml -ceq $nativeDefault -and $registrations -eq 1) 'Existing untagged native indefinite default stays disabled and byte-exact'
 $task.xml=$task.xml.Replace('onboarding.py','foreign.py');Refuses {Ensure-OpenWebCommittedOnboardingTask $root $state $engine $lock} 'Foreign action refused';Check ($registrations -eq 1 -and $deletions -eq 0) 'Foreign task unmodified'
 $task=$null;$crash=$true;Refuses {Ensure-OpenWebCommittedOnboardingTask $root $state $engine $lock} 'Crash after atomic create retained';$crash=$false;Check ((Ensure-OpenWebCommittedOnboardingTask $root $state $engine $lock).state -ceq 'existing' -and $registrations -eq 2) 'Crash retry sees tagged existing task'
 $record=Get-Content (Join-Path $backup 'support-state.json') -Raw|ConvertFrom-Json
 Refuses {Remove-OpenWebLegacyOnboardingTask (Join-Path $state 'backups/other') $record $root $state $engine $lock} 'Different rollback backup refused';Check ($deletions -eq 0) 'Wrong backup cannot delete'
 $task=Snapshot '' $false;$untaggedBefore=$task.xml;Remove-OpenWebLegacyOnboardingTask $backup $record $root $state $engine $lock;Check ($deletions -eq 0 -and $task.xml -ceq $untaggedBefore -and !$task.enabled) 'Untagged preexisting task preserved without blocking legacy rollback'
 $task=Snapshot $tag;$task.xml=$task.xml.Replace('onboarding.py','foreign.py');Refuses {Remove-OpenWebLegacyOnboardingTask $backup $record $root $state $engine $lock} 'Foreign tagged action cannot be deleted'
 $task=Snapshot $tag $false;Remove-OpenWebLegacyOnboardingTask $backup $record $root $state $engine $lock;Check ($deletions -eq 1 -and !$task) 'Exact tracked postcommit task removed on original21 rollback'
 # Candidate22's manual helper takes a NEW support inventory with an explicit
 # absent entry. Its original generic restore loop owns/removes the untagged
 # precommit task; the legacy compatibility path must not intercept that case.
 $explicit=[pscustomobject]@{schema=1;Tasks=[pscustomobject]@{'OpenWebPBX-Onboarding'=[pscustomobject]@{Exists=$false;Enabled=$false}}}
 $task=Snapshot '';$beforeDelete=$deletions;Remove-OpenWebLegacyOnboardingTask $backup $explicit $root $state $engine $lock;Check ($task -and $deletions -eq $beforeDelete) 'Explicit current backup uses original generic restore path'
 $st=$null;$se=$null;$supportAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'packaging/windows/Support-Recovery.ps1'),[ref]$st,[ref]$se);Check (!$se.Count) 'Actual support source parses'
 $loops=@($supportAst.FindAll({param($n)$n -is [Management.Automation.Language.ForEachStatementAst] -and $n.Extent.Text.StartsWith('foreach($entry in $record.Tasks.PSObject.Properties)')},$true));Check ($loops.Count -eq 1) 'One original support task restore loop'
 & ([scriptblock]::Create('param($record)'+"`n"+$loops[0].Extent.Text)) $explicit
 Check (!$task -and $deletions -eq $beforeDelete+1) 'Actual generic rollback removes only the explicitly absent root task'
 Check ((Get-OpenWebRecoveryHash ([IO.File]::ReadAllBytes($runtime))) -ceq (Get-OpenWebRecoveryHash $runtimeBefore)) 'No runtime/policy mutation'
 # A same-name foreign nested-folder task is outside every actual get/export/
 # remove command; the migration model's create/delete cannot change it.
 $nested=Snapshot 'foreign nested task' $false;$nestedBefore=$nested|ConvertTo-Json -Depth 5 -Compress
 $source=[IO.File]::ReadAllText((Join-Path $SourceRoot 'packaging/windows/Onboarding-Upgrade.Common.ps1'))
 foreach($verb in 'Get-ScheduledTask','Export-ScheduledTask','Unregister-ScheduledTask'){$lines=@($source.Split("`n")|Where-Object{$_ -match ('(?<![A-Za-z-])'+[regex]::Escape($verb)+' ')});Check ($lines.Count -ge 1 -and @($lines|Where-Object{!$_.Contains("-TaskPath '\'")}).Count -eq 0) 'Actual task APIs use only root folder'}
 Check (($nested|ConvertTo-Json -Depth 5 -Compress) -ceq $nestedBefore) 'Nested foreign same-name task untouched'
 # Execute the actual catch boundary with real HRESULT exceptions. Only the
 # two native lock-sharing conflicts may become a no-mutation deferral.
 $tok=$null;$err=$null;$wrapper=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'packaging/windows/Ensure-OnboardingUpgrade.ps1'),[ref]$tok,[ref]$err);Check (!$err.Count) 'Actual native wrapper parses'
 $busy=@($wrapper.FindAll({param($n)$n -is [Management.Automation.Language.CatchClauseAst] -and $n.Extent.Text.Contains('maintenance_busy')},$true));Check ($busy.Count -eq 1) 'Exact native busy catch required'
 $catch=[scriptblock]::Create('param($Failure) try {throw $Failure} '+$busy[0].Extent.Text)
 foreach($h in -2147024864,-2147024863){$reply=(& $catch ([IO.IOException]::new('Owned lock conflict',$h)))|ConvertFrom-Json;Check ($reply.state -ceq 'deferred' -and $reply.reason -ceq 'maintenance_busy') 'Only native32/33 lock conflict defers'}
 foreach($h in -2147024891,-2147024894){Refuses {& $catch ([IO.IOException]::new('Owned nonbusy refusal',$h))} 'Permission/missing path cannot become deferral'}
 Refuses {& $catch ([ArgumentException]::new('Owned nonIO refusal'))} 'NonIO cannot become deferral'
 # The actual factory carries provenance in its single CREATE transaction,
 # before registration. Native creation itself belongs to disposable CI.
 $assignments=@($actualCreate.Ast.FindAll({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$definition.RegistrationInfo.Source'},$true))
 $register=@($actualCreate.Ast.FindAll({param($n)$n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Value -ceq 'RegisterTaskDefinition'},$true))
 Check ($assignments.Count -eq 1 -and $register.Count -eq 1 -and $assignments[0].Extent.EndOffset -lt $register[0].Extent.StartOffset -and $register[0].Arguments.Count -eq 7 -and $register[0].Arguments[2].Value -eq 2 -and $register[0].Arguments[0].Value -ceq 'OpenWebPBX-Onboarding') 'Atomic Source plus Task Scheduler CREATE only, no replace/retag gap'
 Write-Output ("PASS $checks actual sealed-file/transition/rollback controls; native descriptor checks="+$native+'; Task Scheduler is an in-memory adapter, not native execution.')
}finally{$lock.Dispose();Remove-Item -LiteralPath $temp -Recurse -Force}
