#Requires -Version 7.4
[CmdletBinding()]param([string]$SourceRoot)
# Actual read-only source functions and sealed fictional files; no PBX/services/tasks.
$ErrorActionPreference='Stop';$checks=0
if(!$SourceRoot){$SourceRoot=Split-Path $PSScriptRoot -Parent}
function Verify([bool]$Value){$script:checks++;if(!$Value){throw ('File capture control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)}}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-updater-qualification.ps1'),[ref]$tokens,[ref]$errors)
Verify (@($errors).Count -eq 0)
foreach($name in 'QualificationFileCaptureFields','QualificationFileCapture'){
 $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))
 Verify ($nodes.Count -eq 1);Invoke-Expression $nodes[0].Extent.Text
}
$private='PRIVATE_SENTINEL_password_SDDL_S-1-5-21_customer_row'
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('OpenWebFileCapture-'+$private+'-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory $temporary
function JsonCopy($Value){return $Value|ConvertTo-Json -Depth 32|ConvertFrom-Json -AsHashtable}
function WriteFixture([string]$Path,$Value){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 32),[Text.UTF8Encoding]::new($false))}
try{
 $state=Join-Path $temporary 'state';$config=Join-Path $temporary 'configuration'
 $backup=Join-Path $state 'backups/20261015-202020-abcdef12';$null=New-Item -ItemType Directory -Force $backup,(Join-Path $state 'updates'),$config
 $worker=Join-Path $state 'automatic-backups/worker.lock';$directory=Join-Path $state 'automatic-backups'
 $before=@{};$before[$directory]=@{directory=$true;acl=$private};$after=JsonCopy $before;$after[$worker]=@{directory=$false;acl=$private;sha256=$private;bytes=0}
 $script:qualificationFailedChild=@{caller='CheckedProcess';label='compare-fault-files';exit_code=1;completion='exit'};$originalChild=$script:qualificationFailedChild
 function SealFixture {
  $script:record=@{schema=1;Files=@{};Acls=@{};Directories=@{}}
  $script:record.Acls[$directory]=$private
  $script:record.Directories['automatic-backups']=@{Path=$directory;Exists=$true}
  $script:record.Files[(Join-Path $state 'installation.json')]=@{Exists=$true;Copy='support-files/1'}
  $script:journal=@{schema=1;state='rolled_back';version='1.0.14';previous_version='1.0.13';operator_rollback=$false;backup_path=$backup}
  WriteFixture (Join-Path $state 'updates/install-journal.json') $script:journal
  Reseal
 }
 function Reseal {
  WriteFixture (Join-Path $backup 'support-state.json') $script:record
  WriteFixture (Join-Path $backup 'backup-manifest.json') @{schema=1;files=@{'support-state.json'=(Get-FileHash (Join-Path $backup 'support-state.json')).Hash.ToLowerInvariant()}}
  WriteFixture (Join-Path $backup 'complete.json') @{version='1.0.13';integrity_sha256=(Get-FileHash (Join-Path $backup 'backup-manifest.json')).Hash.ToLowerInvariant()}
 }
 function Capture {
  $inputBefore=$before|ConvertTo-Json -Depth 32;$inputAfter=$after|ConvertTo-Json -Depth 32
  $originalFiles=@{};foreach($file in Get-ChildItem -LiteralPath $state -Recurse -File){$originalFiles[$file.FullName]=(Get-FileHash $file.FullName).Hash}
  $result=QualificationFileCapture $before $after $state $config
  Verify ([object]::ReferenceEquals($originalChild,$script:qualificationFailedChild))
  Verify (($before|ConvertTo-Json -Depth 32) -ceq $inputBefore -and ($after|ConvertTo-Json -Depth 32) -ceq $inputAfter)
  Verify (@(Get-ChildItem -LiteralPath $state -Recurse -File).Count -eq $originalFiles.Count)
  foreach($file in $originalFiles.Keys){Verify ((Get-FileHash $file).Hash -ceq $originalFiles[$file])}
  $text=$result|ConvertTo-Json -Depth 32 -Compress
  Verify (!$text.Contains($private) -and !$text.Contains($temporary) -and !$text.Contains('worker.lock'))
  Verify ($null -ne (QualificationFileCaptureFields $result))
  return $result
 }
 SealFixture
 $result=Capture
 Verify ($result.state -ceq 'verified' -and $result.paths.Count -eq 18)
 Verify (!$result.paths.automatic_backups_worker_lock.before_present -and $result.paths.automatic_backups_worker_lock.after_present -and $result.paths.automatic_backups_worker_lock.support_capture -ceq 'absent')
 Verify ($result.paths.automatic_backups_root.support_capture -ceq 'present' -and $result.paths.installation.support_capture -ceq 'present')
 Verify ($result.paths.fusionpbx_config.support_capture -ceq 'unobserved' -and $result.paths.runtime.support_capture -ceq 'unobserved')
 $script:record.Acls[$worker]=$private;Reseal;$present=Capture
 Verify ($present.paths.automatic_backups_worker_lock.support_capture -ceq 'present')
 $script:record.Directories['automatic-backups'].Exists=$false;$script:record.Acls.Clear();Reseal;$absent=Capture
 Verify ($absent.paths.automatic_backups_root.support_capture -ceq 'absent' -and $absent.paths.automatic_backups_worker_lock.support_capture -ceq 'absent')
 foreach($case in 'outside_backup','wrong_backup_name','wrong_state','wrong_version','wrong_previous','operator','schema_boolean','missing_support','support_hash','manifest_hash','directory_path','directory_type','file_type','acl_type','oversized_journal','oversized_support','private_json','missing_marker'){
  SealFixture
  switch($case){
   'outside_backup'{$script:journal.backup_path=$temporary;WriteFixture (Join-Path $state 'updates/install-journal.json') $script:journal}
   'wrong_backup_name'{$script:journal.backup_path=(Join-Path $state 'backups/PRIVATE');WriteFixture (Join-Path $state 'updates/install-journal.json') $script:journal}
   'wrong_state'{$script:journal.state='completed';WriteFixture (Join-Path $state 'updates/install-journal.json') $script:journal}
   'wrong_version'{$script:journal.version='1.0.15';WriteFixture (Join-Path $state 'updates/install-journal.json') $script:journal}
   'wrong_previous'{$script:journal.previous_version='1.0.12';WriteFixture (Join-Path $state 'updates/install-journal.json') $script:journal}
   'operator'{$script:journal.operator_rollback=$true;WriteFixture (Join-Path $state 'updates/install-journal.json') $script:journal}
   'schema_boolean'{$script:journal.schema=$true;WriteFixture (Join-Path $state 'updates/install-journal.json') $script:journal}
   'missing_support'{Remove-Item (Join-Path $backup 'support-state.json')}
   'support_hash'{[IO.File]::AppendAllText((Join-Path $backup 'support-state.json'),' ')}
   'manifest_hash'{[IO.File]::AppendAllText((Join-Path $backup 'backup-manifest.json'),' ')}
   'directory_path'{$script:record.Directories['automatic-backups'].Path=$temporary;Reseal}
   'directory_type'{$script:record.Directories['automatic-backups'].Exists='true';Reseal}
   'file_type'{$script:record.Files[(Join-Path $state 'installation.json')].Exists='true';Reseal}
   'acl_type'{$script:record.Acls=$private;Reseal}
   'oversized_journal'{[IO.File]::WriteAllText((Join-Path $state 'updates/install-journal.json'),(' '*65537))}
   'oversized_support'{[IO.File]::WriteAllText((Join-Path $backup 'support-state.json'),(' '*16777217))}
   'private_json'{[IO.File]::WriteAllText((Join-Path $backup 'support-state.json'),$private)}
   'missing_marker'{Remove-Item (Join-Path $backup 'complete.json')}
  }
  $result=Capture;Verify ($result.state -ceq 'unavailable' -and $result.paths.Count -eq 0)
 }
 SealFixture;$valid=Capture
 foreach($case in 'unknown_label','extra_row','missing_row','private_state','private_capture','string_bool','extra_field','extra_top','unavailable_with_rows'){
  $invalid=JsonCopy $valid
  switch($case){
   'unknown_label'{$invalid.paths[$private]=$invalid.paths.installation;$invalid.paths.Remove('installation')}
   'extra_row'{$invalid.paths[$private]=$invalid.paths.installation}
   'missing_row'{$invalid.paths.Remove('installation')}
   'private_state'{$invalid.state=$private}
   'private_capture'{$invalid.paths.installation.support_capture=$private}
   'string_bool'{$invalid.paths.installation.before_present='false'}
   'extra_field'{$invalid.paths.installation.private=$private}
   'extra_top'{$invalid.private=$private}
   'unavailable_with_rows'{$invalid.state='unavailable'}
  }
  Verify ($null -eq (QualificationFileCaptureFields $invalid))
 }
 Write-Output ('Qualification sealed file-capture controls passed: '+$checks)
}finally{Remove-Item -LiteralPath $temporary -Recurse -Force}
