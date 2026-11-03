# Exact source-component controls with a private synthetic helper/journal.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$checks=0
function Verify([bool]$v){if(!$v){throw ('Operator diagnostic control '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
function Clone($value){return $value|ConvertTo-Json -Depth 10|ConvertFrom-Json -AsHashtable}
$work=Join-Path ([IO.Path]::GetTempPath()) ('operator-error-controls-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory $work|Out-Null
try{
 $tokens=$null;$errors=$null;$wrapper=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-operator-restore-diagnostic.ps1'),[ref]$tokens,[ref]$errors);Verify (!$errors.Count)
 $main=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-updater-qualification.ps1'),[ref]$tokens,[ref]$errors);Verify (!$errors.Count)
 $definitions=@();foreach($name in 'Get-QualificationOperatorRestoreError','Get-QualificationOperatorJournal'){$node=@($wrapper.FindAll({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst]-and $n.Name-ceq $name},$true));Verify ($node.Count-eq 1);$definitions+=$node[0].Extent.Text}
 $node=@($main.FindAll({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst]-and $n.Name-ceq 'ReadQualificationOperatorRestoreError'},$true));Verify ($node.Count-eq 1);$definitions+=$node[0].Extent.Text
 $functions=Join-Path $work 'functions.ps1';[IO.File]::WriteAllText($functions,($definitions-join "`n"));. $functions
 $calls=@($wrapper.FindAll({param($n)$n-is [Management.Automation.Language.TryStatementAst]-and $n.Body.Statements.Count-eq 1-and $n.Body.Statements[0].Extent.Text-ceq '& $helper -RestoreBackup $backup'},$true));Verify ($calls.Count-eq 1)
 $call=Join-Path $work 'wrapper-call.ps1';[IO.File]::WriteAllText($call,$calls[0].Extent.Text)
 $helper=Join-Path $work 'Upgrade-OpenWebPBX.ps1';$backup=Join-Path $work 'sealed-private-before-image'
 [IO.File]::WriteAllText($helper,@'
param([string]$RestoreBackup)
$global:qaOperatorCalls++;$global:qaOperatorHelperRoot=$PSScriptRoot;$global:qaOperatorBackup=$RestoreBackup
try{
 switch($global:qaOperatorMode){
  success{return}
  io{throw [IO.IOException]::new('PRIVATE_EXCEPTION_MARKER',[int]0x80070020)}
  denied{throw [UnauthorizedAccessException]::new('PRIVATE_EXCEPTION_MARKER')}
  native{throw [ComponentModel.Win32Exception]::new(5,'PRIVATE_EXCEPTION_MARKER')}
  nested{throw [InvalidOperationException]::new('PRIVATE_EXCEPTION_MARKER',[IO.IOException]::new('PRIVATE_INNER_MARKER',[int]0x80070021))}
 }
}catch{$global:qaOperatorOriginal=$_;throw}
'@)
 $script:journalWire=@{state='recovery_required';version='1.0.22';operator_rollback=$true;backup_path='PRIVATE_BACKUP_PATH';finalization=@{phase='background_tasks'}}|ConvertTo-Json
 function Get-Item {param([string]$LiteralPath,[switch]$Force)if($LiteralPath-ceq 'C:\ProgramData\OpenWebPBX\updates\install-journal.json'){return @{PSIsContainer=$false;Attributes=0;Length=256}};return Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath -Force:$Force}
 function Get-Content {param([string]$LiteralPath,[switch]$Raw)if($LiteralPath-ceq 'C:\ProgramData\OpenWebPBX\updates\install-journal.json'){return $script:journalWire};return Microsoft.PowerShell.Management\Get-Content -LiteralPath $LiteralPath -Raw:$Raw}
 $valid=$null
 foreach($global:qaOperatorMode in 'success','io','denied','native','nested'){
  $output=Join-Path $work ($qaOperatorMode+'.json');$global:qaOperatorCalls=0;$global:qaOperatorOriginal=$null;$caught=$null
  try{$null=. $call}catch{$caught=$_}
  Verify ($qaOperatorCalls-eq 1-and $qaOperatorHelperRoot-ceq $work-and $qaOperatorBackup-ceq $backup)
  if($qaOperatorMode-ceq 'success'){Verify ($null-eq $caught-and !(Test-Path -LiteralPath $output));continue}
  Verify ($null-ne $caught-and [object]::ReferenceEquals($caught.Exception,$qaOperatorOriginal.Exception))
  $record=Microsoft.PowerShell.Management\Get-Content -LiteralPath $output -Raw|ConvertFrom-Json -AsHashtable;$safe=ReadQualificationOperatorRestoreError $record
  Verify ($null-ne $safe-and $safe.source_basename-ceq 'Upgrade-OpenWebPBX.ps1'-and $safe.source_line-gt 0-and $safe.journal.state-ceq 'recovery_required'-and $safe.journal.phase-ceq 'background_tasks')
  Verify (($safe|ConvertTo-Json -Depth 8 -Compress)-cnotmatch 'PRIVATE_EXCEPTION_MARKER|PRIVATE_INNER_MARKER|PRIVATE_BACKUP_PATH')
  switch($qaOperatorMode){io{Verify ($safe.win32_code-eq 32);$valid=$record}native{Verify ($safe.win32_code-eq 5)}nested{Verify ($safe.win32_code-eq 33)}}
 }
 # A failed diagnostic write never replaces the original operation failure.
 $global:qaOperatorMode='io';$output=Join-Path $work 'occupied.json';[IO.File]::WriteAllText($output,'original-owned-output');$caught=$null;try{$null=. $call}catch{$caught=$_}
 Verify ([object]::ReferenceEquals($caught.Exception,$qaOperatorOriginal.Exception)-and [IO.File]::ReadAllText($output)-ceq 'original-owned-output')
 foreach($record in $valid,($valid|ConvertTo-Json -Depth 8|ConvertFrom-Json)){Verify ($null-ne (ReadQualificationOperatorRestoreError $record))}
 foreach($case in 'extra','schema','producer','state','exception','hresult','native','source','line','journal_extra','journal_state','journal_version','journal_flag','journal_phase'){
  $bad=Clone $valid;switch($case){extra{$bad.PRIVATE_FIELD='PRIVATE_VALUE'}schema{$bad.schema=$true}producer{$bad.producer=@('windows-operator-restore-error')}state{$bad.state='passed'}exception{$bad.exception_type='PRIVATE_EXCEPTION'}hresult{$bad.hresult=$true}native{$bad.win32_code=65536}source{$bad.source_basename='C:\PRIVATE_PATH'}line{$bad.source_line=-1}journal_extra{$bad.journal.PRIVATE_FIELD='PRIVATE_VALUE'}journal_state{$bad.journal.state=@('recovery_required')}journal_version{$bad.journal.version='PRIVATE_VERSION'}journal_flag{$bad.journal.operator_rollback='true'}journal_phase{$bad.journal.phase='PRIVATE_PHASE'}}
  Verify ($null-eq (ReadQualificationOperatorRestoreError $bad))
 }
 # Source binding: stock native PS5, fixed label and original20-minute wait.
 $operator=@($main.FindAll({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst]-and $n.Name-ceq 'ActualOperatorRollback'},$true))[0].Extent.Text
 Verify ($operator.Contains('System32/WindowsPowerShell/v1.0/powershell.exe')-and $operator.Contains("'operator-rollback-native' -Timeout 1200000")-and $operator.Contains('helper_path=$helper;helper_sha256=$helperSha')-and $operator.Contains('backup_path=$j.backup_path'))
 $invocations=@($wrapper.FindAll({param($n)$n-is [Management.Automation.Language.CommandAst]-and $n.Extent.Text-ceq '& $helper -RestoreBackup $backup'},$true));Verify ($invocations.Count-eq 1)
 # Exercise real local PowerShell exit semantics with the same extracted try;
 # only its helper and journal are synthetic. This is not native Windows proof.
 $loader=Join-Path $work 'child.ps1';$prefix='param([string]$Mode)'+"`n"+'$ErrorActionPreference="Stop"'+"`n"+'. "'+$functions+'"'+"`n"+'function Get-QualificationOperatorJournal{return $null}'+"`n"+'$global:qaOperatorMode=$Mode; $helper="'+$helper+'"; $backup="'+$backup+'"; $output="'+(Join-Path $work 'child-error.json')+'"'+"`n"
 [IO.File]::WriteAllText($loader,$prefix+$calls[0].Extent.Text)
 foreach($mode in 'success','io'){
  $start=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path);$start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.Arguments='-NoProfile -File "'+$loader+'" -Mode '+$mode
  $process=[Diagnostics.Process]::Start($start);$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync();Verify ($process.WaitForExit(15000));$null=$stdout.GetAwaiter().GetResult();$privateError=$stderr.GetAwaiter().GetResult();Verify ($process.ExitCode-eq $(if($mode-ceq 'success'){0}else{1}));$process.Dispose()
 }
 @{state='passed';checks=$checks;actual_windows=$false;private_synthetic_helper_and_journal=$true;one_call_primary_exception_preserved=$true;no_product_or_network_action=$true}|ConvertTo-Json -Compress
}finally{foreach($name in 'qaOperatorMode','qaOperatorCalls','qaOperatorHelperRoot','qaOperatorBackup','qaOperatorOriginal'){Remove-Variable -Name $name -Scope Global -ErrorAction SilentlyContinue};Remove-Item -LiteralPath $work -Recurse -Force}
