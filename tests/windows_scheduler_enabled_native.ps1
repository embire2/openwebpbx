#Requires -RunAsAdministrator
[CmdletBinding()]
param([Parameter(Mandatory)][string]$SourceRoot,[Parameter(Mandatory)][string]$OwnedRoot)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if($PSVersionTable.PSEdition-cne 'Desktop'-or $PSVersionTable.PSVersion.Major-ne 5-or $PSVersionTable.PSVersion.Minor-ne 1-or [IntPtr]::Size-ne 8-or $env:GITHUB_ACTIONS-cne 'true'-or $env:RUNNER_ENVIRONMENT-cne 'github-hosted'-or $env:GITHUB_REPOSITORY-cne 'embire2/openwebpbx'){throw 'Exact native owned Scheduler component context required.'}
$env:PSModulePath=$PSHOME+'\Modules;'+[Environment]::GetFolderPath('ProgramFiles')+'\WindowsPowerShell\Modules'
$os=Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
if($os.Caption-notmatch 'Windows Server 2025'-or $os.ProductType-eq 1){throw 'Actual Windows Server2025 required.'}
$scope=Get-Item -LiteralPath $OwnedRoot -Force
if(!$scope.PSIsContainer-or @(Get-ChildItem -LiteralPath $scope.FullName -Force).Count){throw 'Fresh owned scope required.'}
for($node=$scope;$node;$node=$node.Parent){if($node.Attributes-band[IO.FileAttributes]::ReparsePoint){throw 'Ordinary owned scope required.'}}
$backup=Join-Path $SourceRoot 'tests/windows-backup-updater-quiescence.ps1'
$installer=Join-Path $SourceRoot 'packaging/windows/Install-Updater.ps1'
$health=Join-Path $SourceRoot 'tests/windows-health-updater-quiescence.ps1'
$sourcePins=@{$backup='3b27c75c1c47989c99b3f551689fa9895810f5e22e40f0a296057a6d8dd17c6d';$installer='02b2ef281e28e7b005eb1468822af5b3ed5ca48211abeaca2264a5721ceb0992';$health='c9bce34d1c158a146cbca8885edc05339b989483be8e3ed8af92fbfd4447b459';$PSCommandPath=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()}
function Assert-OwnedSource {
 foreach($path in $sourcePins.Keys){$item=Get-Item -LiteralPath $path -Force;if($item.PSIsContainer-or($item.Attributes-band[IO.FileAttributes]::ReparsePoint)-or(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()-cne $sourcePins[$path]){throw 'Exact source ownership changed.'}}
}
Assert-OwnedSource
$tokens=$null;$parseErrors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($backup,[ref]$tokens,[ref]$parseErrors)
$functions=@($ast.FindAll({param($n) $n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq 'Assert-BackupUpdaterTaskDefinition'},$true))
if($parseErrors.Count-or$functions.Count-ne 1){throw 'One exact original XML comparer required.'}
$originalComparer=$functions[0].Extent.Text
# Explicit owned-name/identity adapter. Every original XML comparison and throw remains byte-exact.
$oldName="'OpenWebPBX-Updater-Restart'";$oldIdentity='Assert-HealthUpdaterRestartTask $task'
if([regex]::Matches($originalComparer,[regex]::Escape($oldName)).Count-ne 2-or[regex]::Matches($originalComparer,[regex]::Escape($oldIdentity)).Count-ne 1){throw 'Exact original adapter sites required.'}
$adapted=$originalComparer.Replace($oldName,'$script:ownedTaskName').Replace($oldIdentity,'Assert-OwnedSchedulerTask $task')
if($adapted.Replace('$script:ownedTaskName',$oldName).Replace('Assert-OwnedSchedulerTask $task',$oldIdentity)-cne$originalComparer){throw 'Original comparer inverse refused.'}
. ([scriptblock]::Create($adapted))
$nonce=[Guid]::NewGuid().ToString('N');$script:ownedTaskName='OpenWebSchedulerProbe_'+$nonce
$description='OpenWeb owned Scheduler default probe '+$nonce
$stock=Join-Path $env:SystemRoot 'System32/where.exe';$stockItem=Get-Item -LiteralPath $stock -Force
if($stockItem.PSIsContainer-or($stockItem.Attributes-band[IO.FileAttributes]::ReparsePoint)){throw 'Ordinary stock action required.'}
$stockHash=(Get-FileHash -LiteralPath $stock -Algorithm SHA256).Hash
$created=$false;$expectedXml=$null;$expectedHash=$null;$primary=$null;$baselineRunTicks=$null
$report=[ordered]@{schema=1;state='failed';scope='owned_never_started_Scheduler_default_enabled_only';phase='absence';error_type='none';cleanup_error_type='none';native_powershell='5.1';absence_before=$false;creation_nonce_bound=$false;source_owned=$false;settings_match_installer=$false;no_triggers=$false;never_run_observed=$false;original_enabled=$null;original_count='unavailable';original_literal='unavailable';disabled_enabled=$null;disabled_count='unavailable';disabled_literal='unavailable';original_comparer_result='unavailable';owned_name_identity_adapter=$true;original_xml_comparisons_unchanged=$true;default_omission_reproduced=$false;cleanup_definition_hash_rechecked=$false;owned_task_absent_after=$false;stock_image_unchanged=$false;source_unchanged=$false;historical_failed_XML_or_backup_qualified=$false}
function HashText([string]$Text){$hash=[Security.Cryptography.SHA256]::Create();try{return ([BitConverter]::ToString($hash.ComputeHash([Text.UTF8Encoding]::new($false).GetBytes($Text)))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}}
function Assert-OwnedSchedulerTask($Task) {
 if($script:ownedTaskName-cnotmatch '^OpenWebSchedulerProbe_[a-f0-9]{32}$'-or @($Task).Count-ne 1-or $Task.TaskName-cne$script:ownedTaskName-or $Task.TaskPath-cne'\'-or $Task.Description-cne$description-or @($Task.Actions).Count-ne 1-or $Task.Actions[0].Execute-ine$stock-or $Task.Actions[0].Arguments-cne'/?'-or ![string]::IsNullOrEmpty($Task.Actions[0].WorkingDirectory)-or $Task.Principal.UserId-cnotin'SYSTEM','S-1-5-18'-or [string]$Task.Principal.RunLevel-cnotin'Highest','1'-or [string]$Task.Principal.LogonType-cnotin'ServiceAccount','5'-or @($Task.Triggers|Where-Object {$null-ne$_}).Count-ne 0-or $Task.Settings.ExecutionTimeLimit-cne'PT3M'-or $Task.Settings.Enabled-isnot[bool]-or [string]$Task.State-cne$(if($Task.Settings.Enabled){'Ready'}else{'Disabled'})){throw 'Exact owned nonrunning task identity required.'}
}
function Read-OwnedTask {
 Assert-OwnedSource
 if((Get-FileHash -LiteralPath $stock -Algorithm SHA256).Hash-cne$stockHash){throw 'Stock action changed.'}
 $task=Get-ScheduledTask -TaskName $script:ownedTaskName -TaskPath '\' -ErrorAction Stop;Assert-OwnedSchedulerTask $task
 $info=Get-ScheduledTaskInfo -TaskName $script:ownedTaskName -TaskPath '\' -ErrorAction Stop
 if([uint32]$info.LastTaskResult-ne 267011-or $info.NumberOfMissedRuns-ne 0-or ($null-ne$baselineRunTicks-and[long]$info.LastRunTime.Ticks-ne$baselineRunTicks)){throw 'Owned task has not retained its never-run state.'}
 $xml=Export-ScheduledTask -TaskName $script:ownedTaskName -TaskPath '\' -ErrorAction Stop
 if($xml-isnot[string]-or!$xml-or$xml.Length-gt1048576){throw 'Bounded original export required.'}
 return @{Task=$task;Xml=$xml;Hash=(HashText $xml);RunTicks=[long]$info.LastRunTime.Ticks}
}
function EnabledShape([string]$Xml) {
 $doc=[xml]$Xml;$nodes=@($doc.SelectNodes('/*[local-name()="Task"]/*[local-name()="Settings"]/*[local-name()="Enabled"]'))
 $literal=if($nodes.Count-eq 0){'absent'}elseif($nodes.Count-ne 1){'multiple'}elseif($nodes[0].InnerText-ceq'true'){'true'}elseif($nodes[0].InnerText-ceq'false'){'false'}else{'other'}
 return @{count=$(if($nodes.Count-eq0){'none'}elseif($nodes.Count-eq1){'single'}else{'multiple'});literal=$literal}
}
try{
 Assert-OwnedSource
 if(@(Get-ScheduledTask -TaskPath '\' -ErrorAction Stop|Where-Object {$_.TaskName-ceq$script:ownedTaskName}).Count){throw 'Owned task collision; nothing may be adopted.'}
 $report.absence_before=$true;$report.source_owned=$true;$report.phase='register'
 $action=New-ScheduledTaskAction -Execute $stock -Argument '/?'
 $principal=New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
 Register-ScheduledTask -TaskName $script:ownedTaskName -TaskPath '\' -Description $description -Action $action -Principal $principal -Settings (New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 3)) -ErrorAction Stop|Out-Null
 $created=$true;$report.phase='original_export'
 $original=Read-OwnedTask;$baselineRunTicks=$original.RunTicks;$expectedXml=$original.Xml;$expectedHash=$original.Hash
 if(!$original.Task.Settings.Enabled){throw 'A fresh enabled default required.'}
 $report.creation_nonce_bound=$true;$report.settings_match_installer=$true;$report.no_triggers=$true
 $shape=EnabledShape $original.Xml;$report.original_enabled=[bool]$original.Task.Settings.Enabled;$report.original_count=$shape.count;$report.original_literal=$shape.literal
 $report.phase='disable';$before=Read-OwnedTask
 if($before.Xml-cne$expectedXml-or$before.Hash-cne$expectedHash){throw 'Owned original definition changed before disable.'}
 Disable-ScheduledTask -TaskName $script:ownedTaskName -TaskPath '\' -ErrorAction Stop|Out-Null
 $report.phase='disabled_export';$disabled=Read-OwnedTask;$expectedXml=$disabled.Xml;$expectedHash=$disabled.Hash
 if($disabled.Task.Settings.Enabled){throw 'Owned task did not disable.'}
 $shape=EnabledShape $disabled.Xml;$report.disabled_enabled=[bool]$disabled.Task.Settings.Enabled;$report.disabled_count=$shape.count;$report.disabled_literal=$shape.literal
 $report.phase='original_comparer'
 try{Assert-BackupUpdaterTaskDefinition @{TaskXml=$original.Xml;TaskEnabled=[bool]$original.Task.Settings.Enabled};$report.original_comparer_result='accepted'}catch{
  switch -CaseSensitive ($_.Exception.Message){
   'The original restart task definition is unavailable.'{$report.original_comparer_result='enabled_node_guard_refused'}
   'The originally disabled restart task was re-enabled by another operation.'{$report.original_comparer_result='disabled_reenabled_guard_refused'}
   'The restart task changed beyond the owned enabled choice.'{$report.original_comparer_result='definition_guard_refused'}
   default{throw}
  }
 }
 $report.default_omission_reproduced=($report.original_enabled-and$report.original_count-ceq'none'-and$report.original_literal-ceq'absent'-and$report.disabled_count-ceq'single'-and$report.disabled_literal-ceq'false'-and$report.original_comparer_result-ceq'enabled_node_guard_refused')
 $report.phase='cleanup'
}catch{$primary=$_;$report.error_type=$_.Exception.GetType().Name}
finally{
 try{
  if($created){
   if(!$expectedXml-or!$expectedHash){throw 'Stored owned definition required for deletion.'}
   $last=Read-OwnedTask
   if($last.Xml-cne$expectedXml-or$last.Hash-cne$expectedHash){throw 'Exact owned definition hash changed before deletion.'}
   $report.cleanup_definition_hash_rechecked=$true;$report.never_run_observed=$true
   Unregister-ScheduledTask -TaskName $script:ownedTaskName -TaskPath '\' -Confirm:$false -ErrorAction Stop
   if(@(Get-ScheduledTask -TaskPath '\' -ErrorAction Stop|Where-Object {$_.TaskName-ceq$script:ownedTaskName}).Count){throw 'Owned task absence unproved.'}
   $report.owned_task_absent_after=$true
  }
  $report.stock_image_unchanged=(Get-FileHash -LiteralPath $stock -Algorithm SHA256).Hash-ceq$stockHash
  Assert-OwnedSource;$report.source_unchanged=$true
 }catch{$report.cleanup_error_type=$_.Exception.GetType().Name;if($null-eq$primary){$primary=$_;$report.error_type=$_.Exception.GetType().Name}else{$primary.Exception.Data['owned_scheduler_cleanup_refused']=$true}}
 if($null-eq$primary-and$created-and$report.owned_task_absent_after-and$report.stock_image_unchanged-and$report.source_unchanged){$report.state='passed';$report.phase='complete'}
 try{$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($report|ConvertTo-Json -Depth 3 -Compress));if($bytes.Length-gt8192){throw 'Bounded native report required.'};$file=[IO.File]::Open((Join-Path $scope.FullName 'native.safe.json'),'CreateNew','Write','None');try{$file.Write($bytes,0,$bytes.Length);$file.Flush($true)}finally{$file.Dispose()}}catch{if($null-eq$primary){throw}}
}
if($null-ne$primary){throw $primary}
if($report.state-cne'passed'){throw 'No Scheduler default component result qualified.'}
