# Actual receipt consumer / source boundary controls. No native driver invocation.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
. (Join-Path $SourceRoot 'tests/windows_phone_catalogue_proof.ps1')
$checks=0
function Check([bool]$Ok){if(!$Ok){throw ('Catalogue evidence control '+($script:checks+1)+' refused.')};$script:checks++}
function Deny($Value,[string]$Edition='Core',[string]$SourceSha=('a'*64),[string]$PhpSha=('b'*64)){$refused=$false;try{$null=Read-WindowsPhoneCatalogueQualificationRecord $Value $Edition $SourceSha $PhpSha}catch{$refused=$true};Check $refused}
$caseNames=@(Get-WindowsPhoneCatalogueNativeCases);Check ($caseNames.Count -eq 30)
$positive=@('actual_ntfs','actual_php_flock','actual_powershell_exclusive','actual_movefileex','actual_scheduler','actual_system_worker','actual_activation_child_kills','real_primitive_checkpoint_wrappers','path_fetch_clock_taskname_adapters','reader_sid_adapter','whole_source_runtime_exact','original_services_files_tasks_exact')
$negative=@('private_key_persisted','installed_server_changed','iis_or_database_or_firewall_changed','actual_iis_reader_tested','full_upgrade_restore_qualified','production_release_published')
$valid=[ordered]@{schema=1;producer='windows_phone_catalogue_native.ps1';state='passed';edition='Core';source_manifest_sha256=('a'*64);php_executable_sha256=('b'*64);checks=30;cases=$caseNames;ephemeral_rsa_bits=3072}
foreach($name in $positive){$valid[$name]=$true};foreach($name in $negative){$valid[$name]=$false}
function CopyRecord {return ($valid|ConvertTo-Json -Depth 6|ConvertFrom-Json)}
$r=Read-WindowsPhoneCatalogueQualificationRecord (CopyRecord) Core ('a'*64) ('b'*64);Check ($r.checks -eq 30 -and !$r.full_upgrade_restore_qualified)
foreach($name in $valid.Keys){$bad=CopyRecord;$bad.PSObject.Properties.Remove($name);Deny $bad}
foreach($name in $positive+$negative){foreach($value in @('true',1,@($true),$null)){$bad=CopyRecord;$bad.$name=$value;Deny $bad};$bad=CopyRecord;$bad.$name=!$bad.$name;Deny $bad}
foreach($field in 'schema','checks','ephemeral_rsa_bits'){foreach($value in @($true,1.0,'1',$null,0,100001)){$bad=CopyRecord;$bad.$field=$value;Deny $bad}}
foreach($field in 'producer','state','edition','source_manifest_sha256','php_executable_sha256'){foreach($value in @($true,@('passed'),'foreign',$null)){$bad=CopyRecord;$bad.$field=$value;Deny $bad}}
Deny (CopyRecord) Desktop;Deny (CopyRecord) Core ('c'*64) ('b'*64);Deny (CopyRecord) Core ('a'*64) ('c'*64)
$bad=CopyRecord;$bad|Add-Member extra 'private fixture path';Deny $bad
$bad=CopyRecord;$bad.cases[1]=$bad.cases[0];Deny $bad
$bad=CopyRecord;$bad.cases[0]='invented_case';Deny $bad
$bad=CopyRecord;$bad.cases=@($bad.cases[1..29]);Deny $bad
$bad=CopyRecord;$bad.cases[0]=1;Deny $bad
foreach($file in 'tests/windows_phone_catalogue_native.ps1','tests/windows-phone-catalogue-qualification.ps1'){
 $path=Join-Path $SourceRoot $file;$errors=$null;$tokens=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors);Check (!$errors.Count)
 $guards=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.Contains('github-hosted') -and $n.Extent.Text.Contains('embire2/openwebpbx') -and $n.Extent.Text.Contains('GITHUB_ACTIONS')},$true));Check ($guards.Count -eq 1)
 $scriptText=[IO.File]::ReadAllText($path);Check ($scriptText.IndexOf('github-hosted') -lt $scriptText.IndexOf('New-Item'))
}
Write-Output ('PASS '+$checks+' actual catalogue receipt/type/source guard controls; no native primitive or full release qualification')
