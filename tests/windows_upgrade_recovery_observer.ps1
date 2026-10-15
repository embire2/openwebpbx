# Actual AST and child-process controls; no installed PBX is invoked.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop'
$root=Join-Path ([IO.Path]::GetTempPath()) ("openweb recovery's controls "+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root|Out-Null
$checks=0
function AssertControl([bool]$Value){if(!$Value){throw ('Recovery observer control failed at line '+(@(Get-PSCallStack)[1].ScriptLineNumber))};$script:checks++}
function LoadFunctions([string]$Path,[string[]]$Names){
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
 AssertControl ($errors.Count -eq 0)
 foreach($name in $Names){
  $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))
  AssertControl ($nodes.Count -eq 1);Invoke-Expression ($nodes[0].Extent.Text -replace ('^function '+$name+'\b'),('function global:'+$name))
 }
}
try{
 LoadFunctions (Join-Path $SourceRoot 'tests/windows-upgrade-acceptance.ps1') @('HelperFailure','HelperLauncher')
 LoadFunctions (Join-Path $SourceRoot 'tests/windows-suite.ps1') @('SafeFailureFields','SafeQueueFailureFields','SafeVoicemailFailureFields','SafeMailboxFailureFields','SafeHotelFailureFields','SafeNativeCleanupFields')
 $frame=[pscustomobject]@{source_basename='Support-Recovery.ps1';source_line=[long]101;error_type='System.IO.IOException';command_basename='pg_restore.exe';command_exit=[long]9;caller_basename='Upgrade-OpenWebPBX.ps1';caller_line=[long]240;message='PRIVATE_NEVER_EXPORT';path='PRIVATE_NEVER_EXPORT'}
 $record=[pscustomobject]@{recovery_observations_schema=[long]1;recovery_observations_only=$true;recovery_journal_state='recovery_required';recovery_preexisting_error_count=[long]1;recovery_error_observations=@($frame);password='PRIVATE_NEVER_EXPORT'}
 foreach($filter in 'HelperFailure','SafeFailureFields'){
  $safe=& $filter $record
  AssertControl ($safe.recovery_observations_schema -eq 1 -and $safe.recovery_observations_only -is [bool] -and $safe.recovery_observations_only -and $safe.recovery_journal_state -ceq 'recovery_required' -and $safe.recovery_preexisting_error_count -eq 1)
  AssertControl (@($safe.recovery_error_observations).Count -eq 1 -and $safe.recovery_error_observations[0].Count -eq 7)
  AssertControl (!(($safe|ConvertTo-Json -Depth 8) -match 'PRIVATE_|message|password|path'))
  foreach($bad in @(@('recovery_observations_schema','1'),@('recovery_observations_schema',$true),@('recovery_observations_schema',2),@('recovery_observations_only','true'),@('recovery_observations_only',1),@('recovery_observations_only',$false))){
   $copy=$record.PSObject.Copy();$copy.($bad[0])=$bad[1];$value=& $filter $copy
   AssertControl (@($value.Keys|Where-Object {$_ -like 'recovery_*'}).Count -eq 0)
  }
  foreach($bad in 'RECOVERY_REQUIRED','recovery_required PRIVATE_NEVER_EXPORT',1,$true,@('recovery_required')){
   $copy=$record.PSObject.Copy();$copy.recovery_journal_state=$bad;AssertControl (!(& $filter $copy).ContainsKey('recovery_journal_state'))
  }
  foreach($bad in '1',$true,-1,257,1.5,[double]::NaN,[double]::PositiveInfinity){
   $copy=$record.PSObject.Copy();$copy.recovery_preexisting_error_count=$bad;AssertControl (!(& $filter $copy).ContainsKey('recovery_preexisting_error_count'))
  }
  foreach($bad in @(@('source_basename','private.ps1'),@('source_basename','C:/private/Support-Recovery.ps1'),@('source_basename','support-recovery.ps1'),@('source_line',0),@('source_line',100000),@('source_line','101'),@('source_line',$true),@('error_type','System.PRIVATE_NEVER_EXPORT'),@('error_type','System.IO.IOException PRIVATE_NEVER_EXPORT'))){
   $badFrame=$frame.PSObject.Copy();$badFrame.($bad[0])=$bad[1];$copy=$record.PSObject.Copy();$copy.recovery_error_observations=@($badFrame)
   AssertControl (@((& $filter $copy).recovery_error_observations).Count -eq 0)
  }
  foreach($bad in @(@('command_basename','private.exe'),@('command_exit','9'),@('command_exit',$true),@('command_exit',2147483648),@('caller_basename','private.ps1'),@('caller_line','240'),@('caller_line',$true),@('caller_line',100000))){
   $badFrame=$frame.PSObject.Copy();$badFrame.($bad[0])=$bad[1];$copy=$record.PSObject.Copy();$copy.recovery_error_observations=@($badFrame)
   $safe=& $filter $copy;AssertControl (@($safe.recovery_error_observations).Count -eq 1 -and !$safe.recovery_error_observations[0].ContainsKey($bad[0]))
  }
  $copy=$record.PSObject.Copy();$copy.recovery_error_observations=@($frame)*9
  AssertControl (@((& $filter $copy).recovery_error_observations).Count -eq 0)
  foreach($count in 0,256){$copy=$record.PSObject.Copy();$copy.recovery_preexisting_error_count=$count;AssertControl ((& $filter $copy).recovery_preexisting_error_count -eq $count)}
 }
 $directory=Join-Path $root "helper's original location";New-Item -ItemType Directory -Path $directory|Out-Null
 $helper=Join-Path $directory 'Upgrade-OpenWebPBX.ps1';$support=Join-Path $directory 'Support-Recovery.ps1';$prior=Join-Path $directory 'Restore-Gates.ps1'
 [IO.File]::WriteAllText($prior,"throw [IO.IOException]::new('PRIVATE_PRECALL_NEVER_EXPORT')")
 [IO.File]::WriteAllText($support,@'
param([string]$Mode)
if($Mode -eq 'many'){for($i=0;$i -lt 40;$i++){try{throw [IO.IOException]::new('PRIVATE_INNER_NEVER_EXPORT')}catch{}}}
$failure=[IO.IOException]::new('PRIVATE_INNER_NEVER_EXPORT')
$failure.Data['command_basename']='pg_restore.exe';$failure.Data['command_exit']=9
$failure.Data['caller_basename']='Support-Recovery.ps1';$failure.Data['caller_line']=101
$failure.Data['password']='PRIVATE_INNER_NEVER_EXPORT'
throw $failure
'@)
 [IO.File]::WriteAllText($helper,@'
param([string]$TargetVersion,[string]$Archive,[switch]$Recover)
[IO.File]::WriteAllText($env:OW_RECOVERY_IDENTITY,(@{path=$PSCommandPath;root=$PSScriptRoot;archive=$Archive;recover=[bool]$Recover}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
if($TargetVersion -eq 'success'){if($env:OS -eq 'Windows_NT'){& "$env:SystemRoot\System32\cmd.exe" /d /c 'exit 19'}else{& /bin/sh -c 'exit 19'};return}
if($TargetVersion -eq 'exit75'){exit 75}
if($TargetVersion -eq 'exit2'){exit 2}
try{
 $failure=[InvalidOperationException]::new('PRIVATE_PRIMARY_NEVER_EXPORT')
 $failure.Data['command_basename']='php.exe';$failure.Data['command_exit']=73
 throw $failure
}catch{
 $first=$_
 try{& (Join-Path $PSScriptRoot 'Support-Recovery.ps1') $TargetVersion}catch{}
 try{throw [ArgumentException]::new('PRIVATE_BENIGN_CAUGHT_NEVER_EXPORT')}catch{}
 throw $first
}
'@)
 $privateData=Join-Path $root 'private program data';$journal=Join-Path $privateData 'OpenWebPBX/updates/install-journal.json'
 New-Item -ItemType Directory -Path (Split-Path $journal -Parent) -Force|Out-Null
 $exe=if($PSVersionTable.PSEdition -eq 'Core'){Join-Path $PSHOME 'pwsh'}else{Join-Path $PSHOME 'powershell.exe'}
 foreach($mode in 'throw','many','success','exit75','exit2','invalid-journal','oversized-journal','linked-journal','missing-journal'){
  $failure=Join-Path $root ($mode+'-failure.json');$launcher=Join-Path $root ($mode+'-launcher.ps1');$identity=Join-Path $root ($mode+'-identity.json')
  if($mode -eq 'invalid-journal'){[IO.File]::WriteAllText($journal,'{"schema":1,"state":"PRIVATE_STATE_NEVER_EXPORT"}')}
  elseif($mode -eq 'oversized-journal'){[IO.File]::WriteAllText($journal,('PRIVATE_JOURNAL_NEVER_EXPORT'*1000))}
  elseif($mode -eq 'linked-journal'){
   Remove-Item -LiteralPath $journal -Force
   $linkTarget=Join-Path $root 'private-journal-target.json';[IO.File]::WriteAllText($linkTarget,'{"schema":1,"state":"completed","password":"PRIVATE_LINK_NEVER_EXPORT"}')
   New-Item -ItemType SymbolicLink -Path $journal -Target $linkTarget|Out-Null
  }
  elseif($mode -eq 'missing-journal'){Remove-Item -LiteralPath $journal -Force}
  else{[IO.File]::WriteAllText($journal,'{"schema":1,"state":"recovery_required","backup_path":"PRIVATE_PATH_NEVER_EXPORT"}')}
  $prefix="try { & '"+$prior.Replace("'","''")+"' } catch { }"+[Environment]::NewLine
  $argument="fictional original's argument with spaces"
  [IO.File]::WriteAllText($launcher,$prefix+(HelperLauncher $helper @('-TargetVersion',$mode,'-Archive',$argument,'-Recover') $failure),[Text.UTF8Encoding]::new($false))
  $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$exe;$start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
  $start.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$launcher+'"'
  $start.EnvironmentVariables['ProgramData']=$privateData;$start.EnvironmentVariables['OW_RECOVERY_IDENTITY']=$identity
  $child=[Diagnostics.Process]::Start($start);$out=$child.StandardOutput.ReadToEndAsync();$err=$child.StandardError.ReadToEndAsync()
  if(!$child.WaitForExit(20000)){$child.Kill();throw 'An owned fake child timed out.'}
  $stdout=$out.GetAwaiter().GetResult();$stderr=$err.GetAwaiter().GetResult();$code=$child.ExitCode;$child.Dispose()
  AssertControl ($code -eq $(if($mode -eq 'success'){0}elseif($mode -eq 'exit75'){75}elseif($mode -eq 'exit2'){2}else{1}))
  $observed=Get-Content -LiteralPath $identity -Raw|ConvertFrom-Json
  AssertControl ($observed.path -ceq $helper -and $observed.root -ceq $directory -and $observed.archive -ceq $argument -and $observed.recover -eq $true)
  if($mode -in 'success','exit75','exit2'){AssertControl (!(Test-Path -LiteralPath $failure));continue}
  $raw=Get-Content -LiteralPath $failure -Raw;$value=$raw|ConvertFrom-Json
  AssertControl ($value.error_type -ceq 'System.InvalidOperationException' -and $value.command_basename -ceq 'php.exe' -and $value.command_exit -eq 73)
  AssertControl ($value.recovery_observations_only -eq $true -and $value.recovery_observations_schema -eq 1 -and $value.recovery_preexisting_error_count -ge 1)
  AssertControl ($raw -notmatch 'PRIVATE_|backup_path|message|password' -and $stderr -match 'PRIVATE_PRIMARY_NEVER_EXPORT')
  $frames=@($value.recovery_error_observations)
  AssertControl ($frames.Count -ge 1 -and $frames.Count -le 8)
  AssertControl (@($frames|Where-Object {$_.source_basename -ceq 'Restore-Gates.ps1' -or $_.error_type -ceq 'System.InvalidOperationException'}).Count -eq 0)
  AssertControl (@($frames|Where-Object {$_.source_basename -ceq 'Support-Recovery.ps1' -and $_.error_type -ceq 'System.IO.IOException' -and $_.command_exit -eq 9}).Count -eq 1)
  # A benign caught record remains an observation, not a selected cause.
  AssertControl (@($frames|Where-Object {$_.error_type -ceq 'System.ArgumentException'}).Count -eq 1)
  if($mode -in 'invalid-journal','oversized-journal','missing-journal','linked-journal'){AssertControl (!$value.PSObject.Properties['recovery_journal_state'])}else{AssertControl ($value.recovery_journal_state -ceq 'recovery_required')}
  if($mode -eq 'linked-journal'){AssertControl ([IO.File]::ReadAllText($linkTarget) -ceq '{"schema":1,"state":"completed","password":"PRIVATE_LINK_NEVER_EXPORT"}')}
  $projected=SafeFailureFields $value
  AssertControl ($projected.error_type -ceq $value.error_type -and $projected.command_exit -eq 73 -and @($projected.recovery_error_observations).Count -eq $frames.Count)
  AssertControl (($projected|ConvertTo-Json -Depth 8) -notmatch 'PRIVATE_|backup_path|message|password')
 }
 Write-Output ('PASS '+$checks+' actual recovery-observation AST/privacy/real-child controls')
}finally{Remove-Item -LiteralPath $root -Recurse -Force}
