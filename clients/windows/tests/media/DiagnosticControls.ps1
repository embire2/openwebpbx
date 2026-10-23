# SPDX-License-Identifier: AGPL-3.0-or-later
# Actual source diagnostic/capture/diff functions. MSI/process payloads and OS
# snapshots are explicit fixtures; no installed code, service or MSI is invoked.
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$tool=Join-Path $PSScriptRoot '../../tools/Test-ClientMedia.ps1';$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile([IO.Path]::GetFullPath($tool),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The actual media wrapper does not parse.'}
foreach($name in @('ClosedKeys','JsonShape','ReadMsiFailure','MediaSnapshotRowCounts','MediaServiceChanges','MediaSnapshotDiffCounts','RunChild')){$found=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true));if($found.Count -ne 1){throw 'One actual diagnostic function required.'};. ([scriptblock]::Create($found[0].Extent.Text))}
$definitions=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Add-Type' -and $node.Extent.Text.Contains('public static class MediaChildDrain')},$true));if($definitions.Count -ne 1){throw 'One actual bounded stream implementation required.'};. ([scriptblock]::Create($definitions[0].Extent.Text))
$checks=0;$root=Join-Path ([IO.Path]::GetTempPath()) ('phone-media-diagnostics-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root)
function Check([bool]$Value){if(!$Value){throw 'An actual closed diagnostic control failed.'};$script:checks++}
function Refuse([scriptblock]$Action){$refused=$false;try{$null=& $Action}catch{$refused=$true};Check $refused}
function FailureModel{[ordered]@{schema=1;producer='extract_media_engine.py';state='failed';operation='read_only_msi_media_extract';substage='select_media_modules';exception_type='MediaModuleSelectionError';missing_module='mod_vpx.dll';source_basename='extract_media_engine.py';source_line=40}}
function SnapshotModel{
 $rules=[ordered]@{};foreach($store in @('ActiveStore','PersistentStore')){foreach($command in @('Get-NetFirewallRule','Get-NetFirewallProfile','Get-NetFirewallAddressFilter','Get-NetFirewallPortFilter','Get-NetFirewallApplicationFilter','Get-NetFirewallServiceFilter','Get-NetFirewallInterfaceFilter','Get-NetFirewallInterfaceTypeFilter','Get-NetFirewallSecurityFilter')){$rules[$store+'/'+$command]=@([ordered]@{InstanceID='PRIVATE_DO_NOT_EXPORT';value='unchanged'})}}
 [ordered]@{services=@([ordered]@{name='W32Time';state='Running';mode='Manual';path='PRIVATE_DO_NOT_EXPORT';account='PRIVATE_DO_NOT_EXPORT'});root_certificates=@('PRIVATE_DO_NOT_EXPORT');firewall=$rules}
}
function Json($Value){ConvertTo-Json -InputObject $Value -Depth 16 -Compress}
function ServiceDiff([object[]]$Left,[object[]]$Right){$l=ConvertTo-Json -InputObject $Left -Depth 8 -Compress|ConvertFrom-Json -NoEnumerate;$r=ConvertTo-Json -InputObject $Right -Depth 8 -Compress|ConvertFrom-Json -NoEnumerate;MediaServiceChanges $l $r}
try{
 $valid=Json (FailureModel);$r=ReadMsiFailure $valid;Check ($r.missing_module -ceq 'mod_vpx.dll')
 foreach($change in @('extra','type','module','substage','source','line','schema','scope')){
  $model=FailureModel;switch($change){extra{$model['raw_message']='PRIVATE_DO_NOT_EXPORT'}type{$model.exception_type='PRIVATE_DO_NOT_EXPORT'}module{$model.missing_module='PRIVATE_DO_NOT_EXPORT'}substage{$model.substage='PRIVATE_DO_NOT_EXPORT'}source{$model.source_basename='C:/PRIVATE_DO_NOT_EXPORT'}line{$model.source_line='40'}schema{$model.schema=$true}scope{$model.substage='msi_tables'}};$raw=Json $model;Refuse {ReadMsiFailure $raw}
 }
 Refuse {ReadMsiFailure ($valid.Replace('"schema":1','"schema":1,"schema":1'))}
 Refuse {ReadMsiFailure ($valid.Replace('"source_line":40','"source_line":1e309'))}
 Refuse {ReadMsiFailure ($valid+"`n"+$valid)}
 Refuse {ReadMsiFailure ('x'*8193)}
 $memory=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes(('x'*9000)));$reader=[IO.StreamReader]::new($memory)
 try{$capture=[MediaChildDrain]::Capture($reader,8192).GetAwaiter().GetResult();Check ($capture.Truncated -and $capture.Characters -eq 9000 -and $capture.Text.Length -eq 8192)}finally{$reader.Dispose();$memory.Dispose()}
 $pythonName=if($IsWindows){'python'}else{'python3'};$python=[string](Microsoft.PowerShell.Core\Get-Command $pythonName -CommandType Application -ErrorAction Stop|Select-Object -First 1).Source
 $child=Join-Path $root 'child.py';$count=Join-Path $root 'count';$payload=Join-Path $root 'payload.json'
 [IO.File]::WriteAllText($child,"import pathlib,sys`nwith pathlib.Path(sys.argv[1]).open('a') as f:f.write('1')`nsys.stderr.write(pathlib.Path(sys.argv[2]).read_text())`nsys.exit(17)`n")
 [IO.File]::WriteAllText($payload,$valid);$exit=RunChild $python @($child,$count,$payload) $root 10 -MsiDiagnostic;Check ($exit -eq 17 -and $script:msiChildExit -eq 17 -and $script:msiFailure.missing_module -ceq 'mod_vpx.dll' -and !$script:msiObservationRefused);Check ((Get-Content -LiteralPath $count -Raw) -ceq '1')
 [IO.File]::WriteAllText($payload,'PRIVATE_DO_NOT_EXPORT');$exit=RunChild $python @($child,$count,$payload) $root 10 -MsiDiagnostic;Check ($exit -eq 17 -and $script:msiChildExit -eq 17 -and $null -eq $script:msiFailure -and $script:msiObservationRefused);Check ((Get-Content -LiteralPath $count -Raw) -ceq '11')
 $before=SnapshotModel;$after=SnapshotModel;$same=MediaSnapshotDiffCounts (Json $before) (Json $after);Check (!$same.exact_snapshot_changed -and $same.services.removed_row_values -eq 0)
 $after.services[0].state='Stopped';$after.root_certificates=@('ANOTHER_PRIVATE_VALUE');$after.firewall.'ActiveStore/Get-NetFirewallRule'+=@([ordered]@{InstanceID='ANOTHER_PRIVATE_VALUE';value='new'})
 $diff=MediaSnapshotDiffCounts (Json $before) (Json $after);Check ($diff.exact_snapshot_changed -and $diff.services.removed_row_values -eq 1 -and $diff.services.added_row_values -eq 1);Check ($diff.root_certificates.removed_row_values -eq 1 -and $diff.root_certificates.added_row_values -eq 1);Check ($diff.firewall.rules.added_row_values -eq 1 -and $diff.firewall.rules.before_rows -eq 2 -and $diff.firewall.rules.after_rows -eq 3);Check ((Json $diff) -notmatch 'PRIVATE')
 Check ($diff.before_stage -ceq 'before_sdk_extract' -and $diff.after_stage -ceq 'after_owned_process_cleanup' -and $diff.service_changes.changed_services -eq 1 -and !$diff.service_changes.truncated)
 Check ($diff.service_changes.rows[0].name -ceq 'W32Time' -and $diff.service_changes.rows[0].before_state -ceq 'Running' -and $diff.service_changes.rows[0].after_state -ceq 'Stopped' -and ($diff.service_changes.rows[0].changed_properties -join '|') -ceq 'state')
 $left=SnapshotModel;$right=SnapshotModel;$right.services[0].path='ANOTHER_PRIVATE_PATH';$right.services[0].account='ANOTHER_PRIVATE_ACCOUNT';$privateDiff=ServiceDiff $left.services $right.services
 Check (($privateDiff.rows[0].changed_properties -join '|') -ceq 'path|account' -and (Json $privateDiff) -notmatch 'PRIVATE')
 $added=ServiceDiff @() $left.services;Check (!$added.rows[0].before_present -and $added.rows[0].after_present -and $null -eq $added.rows[0].before_state)
 $deleted=ServiceDiff $left.services @();Check ($deleted.rows[0].before_present -and !$deleted.rows[0].after_present -and $null -eq $deleted.rows[0].after_mode)
 $many=@(1..17|ForEach-Object {[ordered]@{name='StockFixture'+$_;state='Stopped';mode='Manual';path=$null;account=$null}});$bounded=ServiceDiff @() $many;Check ($bounded.truncated -and $bounded.changed_services -eq 17 -and $bounded.rows.Count -eq 16)
 Refuse {ServiceDiff ($left.services+$left.services) @()}
 foreach($field in @('state','mode','name')){$bad=SnapshotModel;$bad.services[0][$field]='bad / private';Refuse {ServiceDiff $bad.services @()}}
 $after=SnapshotModel;$after['private']='refuse';Refuse {MediaSnapshotDiffCounts (Json $before) (Json $after)}
 $after=SnapshotModel;$after.services=$true;Refuse {MediaSnapshotDiffCounts (Json $before) (Json $after)}
 $after=SnapshotModel;$after.firewall.Remove('ActiveStore/Get-NetFirewallRule');Refuse {MediaSnapshotDiffCounts (Json $before) (Json $after)}
 [ordered]@{schema=1;state='passed_actual_closed_media_diagnostics';checks=$checks;modelled_snapshots_and_msi_payloads=$true;actual_owned_child_exit_observed=$true;installed_msi_or_engine_invoked=$false;actual_native_calling=$false}|ConvertTo-Json -Compress
}finally{Remove-Item -LiteralPath $root -Recurse -Force}
