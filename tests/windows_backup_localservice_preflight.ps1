# Native QA component only; no PBX/database/provider calls or service changes.
[CmdletBinding()]param([Parameter(Mandatory)][string]$PythonExecutable,[Parameter(Mandatory)][string]$EvidenceDirectory)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
if($PSVersionTable.PSEdition-cne 'Desktop'-or$PSVersionTable.PSVersion.Major-ne 5-or[IntPtr]::Size-ne 8){throw 'Native64bitDesktopPS5 required.'}
$env:PSModulePath=$PSHOME+'\Modules;'+[Environment]::GetFolderPath('ProgramFiles')+'\WindowsPowerShell\Modules'
if($env:GITHUB_ACTIONS-cne 'true'-or$env:RUNNER_ENVIRONMENT-cne 'github-hosted'-or$env:GITHUB_REPOSITORY-cne 'embire2/openwebpbx'-or$env:OPENWEB_WINDOWS_BACKUP_TEST-cne '1'){throw 'Owned disposable hosted component required.'}
$principal=[Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent();if(!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Elevated hosted component required.'}
$helper=Join-Path $PSScriptRoot 'windows-backup-localservice-task.ps1';$helperPin='5f57ff3e6c735500f32d1775e3d4c14f16ebbff5c9e71cd521169be4bea0dd95'
if((Get-FileHash -LiteralPath $helper -Algorithm SHA256).Hash.ToLowerInvariant()-cne$helperPin){throw 'Pinned helper required.'}
$tokens=$null;$errors=$null;$tree=[Management.Automation.Language.Parser]::ParseFile($helper,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Exact helper syntax required.'}
$functions=@($tree.EndBlock.Statements|Where-Object{$_-is[Management.Automation.Language.FunctionDefinitionAst]})
$names=@('Refuse-OwnedProbe','Require-OwnedProbe','Hash-OwnedProbeText','Assert-OwnedProbeOrdinary','Expected-OwnedProbe','Resolve-OwnedProbeSid','Assert-OwnedProbeModel','Read-OwnedProbeTask','Assert-OwnedProbeReceipt','Read-RegisteredOwnedProbe','Wait-OwnedProbeCompletion','Find-OwnedProbeTasks','Invoke-OwnedProbeOperation')
if(@(Compare-Object @($functions.Name|Sort-Object) @($names|Sort-Object)).Count){throw 'Closed helper functions required.'}
. ([scriptblock]::Create(($functions|ForEach-Object{$_.Extent.Text})-join[Environment]::NewLine))
Assert-OwnedProbeOrdinary $PythonExecutable;Require-OwnedProbe ([IO.Path]::IsPathRooted($PythonExecutable)-and[IO.Path]::GetExtension($PythonExecutable)-ieq '.exe') 'scope_refused'
$evidence=[IO.Path]::GetFullPath($EvidenceDirectory);Assert-OwnedProbeOrdinary $evidence
Require-OwnedProbe ($evidence.StartsWith([IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)-and@(Get-ChildItem -LiteralPath $evidence -Force).Count-eq 0) 'scope_refused'
$root=Join-Path $env:RUNNER_TEMP ('OpenWebPBX-BackupPublication-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root|Out-Null
function Set-ComponentAcl([string]$Path,[bool]$LocalService){
 $acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetAccessRuleProtection($true,$false)
 foreach($sid in @('S-1-5-18','S-1-5-32-544')){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
 if($LocalService){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-19'),'Modify','ContainerInherit,ObjectInherit','None','Allow'))}
 Set-Acl -LiteralPath $Path -AclObject $acl
}
Set-ComponentAcl $root $false;$media=Join-Path $root 'localservice';New-Item -ItemType Directory -Path $media|Out-Null;Set-ComponentAcl $media $true
$utf8=[Text.UTF8Encoding]::new($false);$expectedData='{"schema":1,"synthetic":true}'
$readProbe=Join-Path $PSScriptRoot 'windows_backup_localservice_read_probe.py'
$publisher=Join-Path $media 'read.ps1';$resultFile=Join-Path $media 'result.json';$release=Join-Path $media 'release';$visible=Join-Path $media 'visible'
$owned=@();$stage='baseline';$failure=$null;$checks=[ordered]@{positive=$false;held_writer=$false;nonzero=$false;collision=$false;replacement=$false;task_metadata_native=$false;single_read_after_completion=$false;owned_cleanup=$false;system_preserved=$false;task_definitions_preserved=$false;fixture_acl_preserved=$false}
$summary=[ordered]@{schema=1;state='failed';scope='native_localservice_task_publication_only';ps_version=$PSVersionTable.PSVersion.ToString();ps_edition=$PSVersionTable.PSEdition;helper_sha256=$helperPin;checks=$checks;old_presence_read_state='not_observed';old_presence_winerror_category='none';calling_backup_restore_release_qualified=$false}
function System-ComponentSnapshot{
 $services=@(Get-CimInstance Win32_Service|Sort-Object Name|ForEach-Object{[ordered]@{name=$_.Name;state=$_.State;mode=$_.StartMode;path=$_.PathName;account=$_.StartName}})
 $certs=@(Get-ChildItem Cert:\LocalMachine\Root,Cert:\CurrentUser\Root|ForEach-Object{$_.Thumbprint}|Sort-Object)
 $rules=[ordered]@{}
 foreach($store in @('ActiveStore','PersistentStore')){foreach($command in @('Get-NetFirewallRule','Get-NetFirewallProfile','Get-NetFirewallAddressFilter','Get-NetFirewallPortFilter','Get-NetFirewallApplicationFilter','Get-NetFirewallServiceFilter','Get-NetFirewallInterfaceFilter','Get-NetFirewallInterfaceTypeFilter','Get-NetFirewallSecurityFilter')){$rules[$store+'/'+$command]=@(& $command -PolicyStore $store|Sort-Object InstanceID,Name|ForEach-Object{$v=[ordered]@{};foreach($f in @($_.CimInstanceProperties|Sort-Object Name)){$v[$f.Name]=$f.Value};$v})}}
 return ([ordered]@{services=$services;root_certificates=$certs;firewall=$rules}|ConvertTo-Json -Depth 8 -Compress)
}
function Task-ComponentSnapshot{
 return (@(Get-ScheduledTask|Sort-Object TaskPath,TaskName|ForEach-Object{[ordered]@{path=$_.TaskPath;name=$_.TaskName;sha256=(Hash-OwnedProbeText (Export-ScheduledTask -TaskPath $_.TaskPath -TaskName $_.TaskName))}})|ConvertTo-Json -Depth 4 -Compress)
}
function New-ComponentRequest([string]$Name=''){
 if(!$Name){$Name='OpenWebPBX-Backup-LocalService-'+[guid]::NewGuid().ToString('N')}
 return [pscustomobject]@{schema=1;task_name=$Name;nonce=[guid]::NewGuid().ToString('N');root=$root;script_sha256=(Get-FileHash -LiteralPath $publisher -Algorithm SHA256).Hash.ToLowerInvariant();receipt=$null}
}
function Register-ComponentRequest($Value){$Value.receipt=Invoke-OwnedProbeOperation 'register' $Value;$script:owned+=,$Value;return $Value}
function Read-ComponentResult{
 $raw=@(& $PythonExecutable -I -B $readProbe $resultFile);if($LASTEXITCODE-ne 0-or$raw.Count-ne 1-or$raw[0].Length-gt 2048){throw 'Bounded exact Python read observation required.'}
 return($raw[0]|ConvertFrom-Json)
}
function Write-ComponentPublisher([int]$ExitCode,[bool]$Hold){
 foreach($file in @($resultFile,$release,$visible)){if(Test-Path -LiteralPath $file){Remove-Item -LiteralPath $file}}
 $holdCode=if($Hold){"[IO.File]::WriteAllText('"+$visible.Replace("'","''")+"','visible');`$limit=[Diagnostics.Stopwatch]::StartNew();while(!(Test-Path -LiteralPath '"+$release.Replace("'","''")+"')-and`$limit.Elapsed.TotalSeconds-lt 10){Start-Sleep -Milliseconds 50};if(!(Test-Path -LiteralPath '"+$release.Replace("'","''")+"')){throw 'Owned publisher release deadline.'}"}else{''}
 $text="`$ErrorActionPreference='Stop';& { '"+$expectedData+"';"+$holdCode+" } | Set-Content -LiteralPath '"+$resultFile.Replace("'","''")+"' -Encoding UTF8;exit "+$ExitCode
 [IO.File]::WriteAllText($publisher,$text,$utf8)
}
try{
 $before=System-ComponentSnapshot;$tasksBefore=Task-ComponentSnapshot;$aclBefore=(Get-Acl -LiteralPath $root).Sddl+'|'+(Get-Acl -LiteralPath $media).Sddl
 [IO.File]::WriteAllText((Join-Path $root 'system-before.private.json'),$before,$utf8)
 $stage='positive';Write-ComponentPublisher 0 $false;$one=Register-ComponentRequest (New-ComponentRequest)
 $done=Invoke-OwnedProbeOperation 'start-wait' $one;Require-OwnedProbe ($done.state-ceq 'completed'-and$done.last_run_advanced-and$done.last_task_result-eq 0) 'completion_refused'
 $data=Read-ComponentResult;Require-OwnedProbe ($data.state-ceq 'read_ok'-and$data.exact_synthetic_json) 'completion_refused';$checks.positive=$true;$checks.single_read_after_completion=$true;$checks.task_metadata_native=$true
 $gone=Invoke-OwnedProbeOperation 'cleanup' $one;Require-OwnedProbe $gone.owned_registration_removed 'cleanup_refused';$owned=@()
 $stage='held_writer';Write-ComponentPublisher 0 $true;$held=Register-ComponentRequest (New-ComponentRequest);$expected=Expected-OwnedProbe $held;[void](Read-RegisteredOwnedProbe $held.receipt $expected)
 $baseline=(Get-ScheduledTaskInfo -TaskPath '\' -TaskName $held.task_name).LastRunTime.ToUniversalTime().Ticks
 Start-ScheduledTask -TaskPath '\' -TaskName $held.task_name;$watch=[Diagnostics.Stopwatch]::StartNew()
 while(!(Test-Path -LiteralPath $visible)-and$watch.Elapsed.TotalSeconds-lt 8){Start-Sleep -Milliseconds 50}
 Require-OwnedProbe ((Test-Path -LiteralPath $visible)-and(Test-Path -LiteralPath $resultFile)-and[string](Read-RegisteredOwnedProbe $held.receipt $expected).Task.State-ceq 'Running') 'state_refused'
 $early=Read-ComponentResult;$summary.old_presence_read_state=$early.state;$summary.old_presence_winerror_category=$early.winerror_category
 [IO.File]::WriteAllText($release,'release',$utf8)
 $done=Wait-OwnedProbeCompletion $held $expected $baseline $watch;$data=Read-ComponentResult
 Require-OwnedProbe ($done.state-ceq 'completed'-and$data.state-ceq 'read_ok'-and$data.exact_synthetic_json) 'completion_refused';$checks.held_writer=$true
 [void](Invoke-OwnedProbeOperation 'cleanup' $held);$owned=@()
 $stage='nonzero';Write-ComponentPublisher 7 $false;$bad=Register-ComponentRequest (New-ComponentRequest);$refused=$false
 try{[void](Invoke-OwnedProbeOperation 'start-wait' $bad)}catch{$refused=$_.Exception.Data['OpenWebProbeReason']-ceq 'task_failed'}
 Require-OwnedProbe $refused 'completion_refused';$checks.nonzero=$true;[void](Invoke-OwnedProbeOperation 'cleanup' $bad);$owned=@()
 $stage='collision';Write-ComponentPublisher 0 $false;$foreign=Register-ComponentRequest (New-ComponentRequest);$claim=New-ComponentRequest $foreign.task_name;$refused=$false
 try{[void](Invoke-OwnedProbeOperation 'register' $claim)}catch{$refused=$_.Exception.Data['OpenWebProbeReason']-ceq 'collision'}
 Require-OwnedProbe $refused 'identity_changed';[void](Read-RegisteredOwnedProbe $foreign.receipt (Expected-OwnedProbe $foreign));$checks.collision=$true;[void](Invoke-OwnedProbeOperation 'cleanup' $foreign);$owned=@()
 $stage='replacement';$old=Register-ComponentRequest (New-ComponentRequest);[void](Invoke-OwnedProbeOperation 'cleanup' $old);$owned=@();$replacement=Register-ComponentRequest (New-ComponentRequest $old.task_name);$refused=$false
 try{[void](Invoke-OwnedProbeOperation 'cleanup' $old)}catch{$refused=$_.Exception.Data['OpenWebProbeReason']-ceq 'identity_changed'}
 Require-OwnedProbe $refused 'identity_changed';[void](Read-RegisteredOwnedProbe $replacement.receipt (Expected-OwnedProbe $replacement));$checks.replacement=$true;[void](Invoke-OwnedProbeOperation 'cleanup' $replacement);$owned=@()
}catch{$failure=$_;$summary.failed_stage=$stage;$code=$_.Exception.Data['OpenWebProbeReason'];$summary.failure_reason=if($code-is[string]-and$code-cin @('scope_refused','request_refused','path_refused','script_changed','identity_changed','receipt_refused','collision','state_refused','completion_refused','task_failed','deadline','cleanup_refused')){$code}else{'unclassified'}}
finally{
 if(Test-Path -LiteralPath $media){[IO.File]::WriteAllText($release,'release',$utf8)}
 $cleanupComplete=$true
 foreach($value in @($owned)){
  try{[void](Invoke-OwnedProbeOperation 'cleanup' $value)}catch{$cleanupComplete=$false}
 }
 $checks.owned_cleanup=$cleanupComplete
 try{$after=System-ComponentSnapshot;$checks.system_preserved=$after-ceq$before;[IO.File]::WriteAllText((Join-Path $root 'system-after.private.json'),$after,$utf8);$checks.task_definitions_preserved=(Task-ComponentSnapshot)-ceq$tasksBefore;$checks.fixture_acl_preserved=((Get-Acl -LiteralPath $root).Sddl+'|'+(Get-Acl -LiteralPath $media).Sddl)-ceq$aclBefore}catch{$checks.system_preserved=$false}
 if(!$failure-and@($checks.Values|Where-Object{$_-cne$true}).Count-eq 0){$summary.state='passed_native_localservice_publication_controls_only'}
 [IO.File]::WriteAllText((Join-Path $evidence 'preflight.safe.json'),($summary|ConvertTo-Json -Depth 5),$utf8)
}
if($summary.state-cne 'passed_native_localservice_publication_controls_only'){throw 'Native LocalService publication component refused; no acceptance.'}
