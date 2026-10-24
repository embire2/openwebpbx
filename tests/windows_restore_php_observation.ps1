# Actual AST metadata/caller controls; only owned temporary files and child adapters.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$checks=0
function Must([bool]$Value){if(!$Value){throw ('PHP observation control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-restore-qualification.ps1'),[ref]$tokens,[ref]$errors);Must (!$errors)
$names=@('SafeRestorePhpFailure','SafeRestoreFixtureFailure','SafeRestorePeerFailures','SafeRestoreSchemaFailure','SafeRestoreTableFailure','SafeRestoreMailboxFailure','SafeRestoreToneFailure','SafeRestoreCliFailure','NativeFixture')
$native=$null
foreach($name in $names){$nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));Must ($nodes.Count -eq 1);if($name -ceq 'NativeFixture'){$native=$nodes[0]}else{Invoke-Expression $nodes[0].Extent.Text}}
function Good {return [ordered]@{schema=1;action='snapshot';returncode=1;error_type='RuntimeException';source_basename='windows-restore-qualification.php';source_line=123}}
function Clone($Value){return ($Value|ConvertTo-Json -Depth 8|ConvertFrom-Json)}
$good=Good;$safe=SafeRestorePhpFailure $good;Must ($safe.Count -eq 6 -and $safe.action -ceq 'snapshot')
foreach($name in $good.Keys){
 $x=Clone $good;$x.PSObject.Properties.Remove($name);Must ($null -eq (SafeRestorePhpFailure $x))
 foreach($bad in $null,$true,@(),@{},'PRIVATE_SQL_password'){$x=Clone $good;$x.$name=$bad;Must ($null -eq (SafeRestorePhpFailure $x))}
}
$x=Clone $good;$x|Add-Member NoteProperty message 'PRIVATE';Must ($null -eq (SafeRestorePhpFailure $x))
foreach($bad in 0,-2147483649L,4294967296L,1.5){$x=Clone $good;$x.returncode=$bad;Must ($null -eq (SafeRestorePhpFailure $x))}
foreach($code in -2147483648L,-1,1,255,4294967295L){$x=Clone $good;$x.returncode=$code;Must ((SafeRestorePhpFailure $x).returncode -eq $code)}
foreach($action in 'baseline','discover','status','snapshot','seed-job','seed-health','job-status','cleanup'){$x=Clone $good;$x.action=$action;Must ((SafeRestorePhpFailure $x).action -ceq $action)}
foreach($type in 'RuntimeException','PDOException','JsonException','TypeError','ValueError','Error','Exception','external_error'){$x=Clone $good;$x.error_type=$type;Must ((SafeRestorePhpFailure $x).error_type -ceq $type)}
foreach($source in 'windows-restore-qualification.php','database.php','pbx_paths.php','pbx_meet_install.php','cache.php','event_socket.php','config.php','external_component'){$x=Clone $good;$x.source_basename=$source;Must ((SafeRestorePhpFailure $x).source_basename -ceq $source)}
foreach($line in 0,-1,1000000,'1',$true){$x=Clone $good;$x.source_line=$line;Must ($null -eq (SafeRestorePhpFailure $x))}
$unavailable=Clone $good;$unavailable.error_type='unavailable';$unavailable.source_basename='unavailable';$unavailable.source_line=0
Must ($null -ne (SafeRestorePhpFailure $unavailable))
foreach($change in @(@('error_type','Error'),@('source_basename','external_component'),@('source_line',1))){$x=Clone $unavailable;$x.($change[0])=$change[1];Must ($null -eq (SafeRestorePhpFailure $x))}
$work=Join-Path ([IO.Path]::GetTempPath()) ('restore-php-observer-'+[guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory $work
$python='fictional-python';$source='fictional-source';$inputFile='fictional-input';$script:primary=[InvalidOperationException]::new('PRIVATE primary');$script:mode='valid';$script:childCalls=0
function CheckedProcess($Exe,$Arguments,$Label,$Directory,$Timeout){
 $script:childCalls++;Must ($Exe -ceq $python -and $Directory -ceq $source -and $Timeout -eq 1200000)
 Must (($Arguments -join '|') -ceq ('-I|-B|'+(Join-Path $work 'windows-restore-qualification.py')+'|--input|'+$inputFile+'|--action|restore'))
 $out=Join-Path $work ($Label+'.out');$r=[ordered]@{state='failed';error_type='RuntimeError';source_basename='windows-restore-qualification.py';source_line=612;php_failure=(Good)}
 if(Test-Path $out){Remove-Item $out -Recurse -Force}
 if($script:mode -eq 'success'){return}
 if($script:mode -eq 'missing'){$r.Remove('php_failure')}
 if($script:mode -eq 'extra'){$r.php_failure.message='PRIVATE'}
 if($script:mode -eq 'wrong_type'){$r.error_type='ValueError'}
 if($script:mode -eq 'wrong_source'){$r.source_basename='PRIVATE.py'}
 if($script:mode -eq 'unavailable'){$r.php_failure=$unavailable}
 if($script:mode -eq 'directory'){$null=New-Item -ItemType Directory $out}
 elseif($script:mode -eq 'malformed'){[IO.File]::WriteAllText($out,'{')}
 elseif($script:mode -eq 'oversized'){[IO.File]::WriteAllText($out,(($r|ConvertTo-Json -Depth 8 -Compress)+(' '*1048577)))}
 elseif($script:mode -eq 'linked'){$foreign=Join-Path $work 'owned-linked-source.json';[IO.File]::WriteAllText($foreign,($r|ConvertTo-Json -Depth 8 -Compress));$null=New-Item -ItemType SymbolicLink -Path $out -Target $foreign}
 else{[IO.File]::WriteAllText($out,($r|ConvertTo-Json -Depth 8 -Compress))}
 throw $script:primary
}
try{
 $definition=Join-Path $work 'actual.ps1';[IO.File]::WriteAllText($definition,$native.Extent.Text);. $definition
 foreach($mode in 'valid','unavailable','missing','extra','wrong_type','wrong_source','malformed','oversized','directory','linked','metadata_throws','validator_throws','success'){
  $script:mode=$mode;$script:childCalls=0;$facts=@{gates=@{restore='unqualified'}}
  if($mode -eq 'metadata_throws'){function Get-Item {throw 'PRIVATE observer failure'}}
  $validator=${function:SafeRestorePhpFailure}
  if($mode -eq 'validator_throws'){function SafeRestorePhpFailure {throw 'PRIVATE validator failure'}}
  $caught=$null;try{NativeFixture 'restore'}catch{$caught=$_}
  if($mode -eq 'metadata_throws'){Remove-Item Function:\Get-Item}
  if($mode -eq 'validator_throws'){Set-Item Function:\SafeRestorePhpFailure $validator}
  Must ($script:childCalls -eq 1)
  if($mode -eq 'success'){Must ($null -eq $caught -and !$facts.ContainsKey('native_failure'))}
  else{Must ($null -ne $caught -and [object]::ReferenceEquals($caught.Exception,$script:primary));Must (($null -ne $facts.native_failure.php_failure) -eq ($mode -cin 'valid','unavailable'))}
  Must ($facts.gates.restore -ceq 'unqualified')
  if($mode -cne 'wrong_source'){Must (($facts|ConvertTo-Json -Depth 12 -Compress) -cnotmatch 'PRIVATE|password|C:/customer')}
 }
}finally{Remove-Item -LiteralPath $work -Recurse -Force}
Write-Output ('PASS '+$checks+' actual closed PHP metadata/primary/once-only/unchanged-arguments/privacy controls; no installed child or native restore')
