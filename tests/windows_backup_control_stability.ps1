#Requires -Version 5.1
# Actual AST snapshot/guard controls; only owned temporary files and ACL mocks.
[CmdletBinding()]
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$script:checks=0
function Assert([bool]$Value){if(!$Value){throw ('A backup-control stability control failed at test line '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
function Check([bool]$Value,[string]$Message){if(!$Value){throw 'An actual snapshot precondition refused its owned fixture.'}}
$source=Join-Path $SourceRoot 'tests/windows-upgrade-acceptance.ps1';$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors);Assert ($errors.Count -eq 0)
$nodes=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'FilesSnapshot'},$true));Assert ($nodes.Count -eq 1)
$snapshotNode=$nodes[0];Invoke-Expression $snapshotNode.Extent.Text
$script:actualSnapshot=${function:FilesSnapshot}
Assert ($snapshotNode.Parameters.Count -eq 1 -and $snapshotNode.Parameters[0].Name.VariablePath.UserPath -ceq 'BackupControlOnly' -and $snapshotNode.Parameters[0].StaticType -eq [Management.Automation.SwitchParameter])
function Fingerprint($Map){
 $rows=@(foreach($key in ($Map.Keys|Sort-Object -CaseSensitive)){
  $values=@(foreach($field in ($Map[$key].Keys|Sort-Object -CaseSensitive)){[ordered]@{name=$field;value=$Map[$key][$field]}})
  [ordered]@{name=$key;values=$values}
 });return ($rows|ConvertTo-Json -Depth 8 -Compress)
}
function Copy-Map($Map){$copy=@{};foreach($key in $Map.Keys){$row=@{};foreach($field in $Map[$key].Keys){$row[$field]=$Map[$key][$field]};$copy[$key]=$row};return $copy}
function Get-Acl {param([string]$LiteralPath) return [pscustomobject]@{Sddl='FICTIONAL_OWNED_ACL'}}
function Hash([string]$Path){return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Native-Path([string]$Path){return $Path.Replace('\',[string][IO.Path]::DirectorySeparatorChar)}
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('openweb-backup-stability-'+[Guid]::NewGuid().ToString('N'))
try{
 $root=Join-Path $temporary 'root';$state=Join-Path $temporary 'state';$switch=Join-Path $temporary 'engine';$configuration=Join-Path $temporary 'configuration'
 # Execute the actual initial scope declarations and compare with the frozen
 # full-snapshot scope. The new switch must not narrow ordinary qualification.
 $assignments=@($snapshotNode.Body.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.AssignmentStatementAst]})
 foreach($name in 'directories','parents','fixed'){
  $declaration=@($assignments|Where-Object {$_.Left.Extent.Text -ceq ('$'+$name)});Assert ($declaration.Count -eq 1);Invoke-Expression $declaration[0].Extent.Text
 }
 $expectedDirectories=@("$root\web","$root\server","$root\desktop","$root\tools","$root\php","$root\backup-runtime","$root\acme","$root\updater\slots",$configuration,"$switch\conf","$switch\scripts","$switch\mod","$switch\sounds","$state\storage","$state\mobile-notifications","$state\phone-tls","$state\public-access","$state\automatic-backups","$state\backup-restore","$state\backup-control","$state\backup-downloads","$state\codec-compiler-cache","$state\codec-build","$state\phone-health-runtime","$state\stun-setup","$state\dtls-setup")
 $expectedParents=@($root,"$root\updater",$state,$switch,"$switch\cert")
 $expectedFixed=@("$state\installation.json","$state\runtime.json","$state\phone-tls.json","$state\phone-health-instance.json","$state\stun.json","$switch\cert\dtls-srtp.pem","$state\native-engine.json","$state\local-codec.json","$state\updater-install.json","$root\php\php.ini","$root\php\extras\ssl\openssl.cnf","$root\php\extras\ssl\cacert.pem")
 Assert (($directories -join '|') -ceq ($expectedDirectories -join '|'))
 Assert (($parents -join '|') -ceq ($expectedParents -join '|'))
 Assert (($fixed -join '|') -ceq ($expectedFixed -join '|'))
 foreach($directory in $expectedDirectories+$expectedParents){$null=[IO.Directory]::CreateDirectory((Native-Path $directory))}
 foreach($directory in $expectedDirectories){[IO.File]::WriteAllText((Join-Path (Native-Path $directory) 'owned.bin'),'FICTIONAL_'+$directory)}
 foreach($path in $expectedFixed){$native=Native-Path $path;$null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($native));[IO.File]::WriteAllText($native,'FICTIONAL_FIXED')}
 $control=Native-Path "$state\backup-control";$nested=Join-Path $control 'nested';$null=[IO.Directory]::CreateDirectory($nested)
 $request=Join-Path $nested 'request.json';[IO.File]::WriteAllText($request,'FICTIONAL_REQUEST')
 $foreign=Native-Path "$state\backup-control-foreign";$null=[IO.Directory]::CreateDirectory($foreign);[IO.File]::WriteAllText((Join-Path $foreign 'foreign.json'),'FICTIONAL_FOREIGN')
 $normal=FilesSnapshot;$normalBefore=Fingerprint $normal;$limited=FilesSnapshot -BackupControlOnly
 foreach($directory in $expectedDirectories){Assert ($normal.ContainsKey((Native-Path $directory)) -and $normal.ContainsKey((Join-Path (Native-Path $directory) 'owned.bin')))}
 foreach($parent in $expectedParents){Assert ($normal.ContainsKey($parent) -and $normal[$parent].directory -eq $true)}
 foreach($path in $expectedFixed){Assert ($normal.ContainsKey($path) -and $normal[$path].directory -eq $false)}
 Assert ($limited.Count -eq 4 -and $limited.ContainsKey($control) -and $limited.ContainsKey($nested) -and $limited.ContainsKey($request) -and $limited.ContainsKey((Join-Path $control 'owned.bin')))
 Assert (@($limited.Keys|Where-Object {$_ -cne $control -and !$_.StartsWith($control+[IO.Path]::DirectorySeparatorChar,[StringComparison]::Ordinal)}).Count -eq 0)
 foreach($path in $expectedParents+$expectedFixed){Assert (!$limited.ContainsKey($path))}
 Assert (!$normal.ContainsKey($foreign) -and !$limited.ContainsKey($foreign))
 $limitedBefore=Fingerprint $limited;[IO.File]::WriteAllText((Join-Path $foreign 'foreign.json'),'CHANGED_FOREIGN')
 Assert ((Fingerprint (FilesSnapshot -BackupControlOnly)) -ceq $limitedBefore)
 Assert ((Fingerprint $normal) -ceq $normalBefore)
 [IO.File]::WriteAllText($request,'CHANGED_REQUEST');$changed=FilesSnapshot -BackupControlOnly
 Assert ($changed[$request].sha256 -cne $limited[$request].sha256 -and (Fingerprint $limited) -ceq $limitedBefore)
 $added=Join-Path $control 'new.json';[IO.File]::WriteAllText($added,'NEW_OWNED')
 Assert ((FilesSnapshot -BackupControlOnly).ContainsKey($added))
 [IO.File]::Delete($request);Assert (!(FilesSnapshot -BackupControlOnly).ContainsKey($request))
 $link=Join-Path $control 'redirect';$null=New-Item -ItemType SymbolicLink -Path $link -Target $foreign
 $refused=$false;try{FilesSnapshot -BackupControlOnly|Out-Null}catch{$refused=$true};Assert $refused
 Remove-Item -LiteralPath $link -Force
}finally{Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue}

# Execute the exact pre-fault block using Windows keys. The full source retains
# its own real comparator; this local mock compares every original key/value.
$starts=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$controlBaseline' -and $node.Right.Extent.Text -ceq '@{}'},$true));Assert ($starts.Count -eq 1)
$start=$starts[0].Extent.StartOffset
$ends=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$phase' -and $node.Right.Extent.Text -ceq "'actual direct post-deploy rollback'" -and $node.Extent.StartOffset -gt $start},$true));Assert ($ends.Count -eq 1)
$end=$ends[0].Extent.EndOffset;$text=[IO.File]::ReadAllText($source);$guard=[scriptblock]::Create($text.Substring($start,$end-$start))
$guardAst=[Management.Automation.Language.Parser]::ParseInput($guard.ToString(),[ref]$tokens,[ref]$errors);Assert ($errors.Count -eq 0)
Assert (@($guardAst.FindAll({param($node)$node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$files'},$true)).Count -eq 0)
$fileAssignment=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$files' -and $node.Right.Extent.Text -ceq 'FilesSnapshot' -and $node.Extent.StartOffset -lt $start},$true)|Sort-Object {$_.Extent.StartOffset} -Descending|Select-Object -First 1);Assert ($fileAssignment.Count -eq 1)
$taskAssignment=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$tasks' -and $node.Right.Extent.Text -ceq 'TaskSnapshot' -and $node.Extent.StartOffset -lt $start},$true)|Sort-Object {$_.Extent.StartOffset} -Descending|Select-Object -First 1);Assert ($taskAssignment.Count -eq 1)
$dbAssignment=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$database' -and $node.Right.Extent.Text -ceq "DatabaseSnapshot 'before-failure'"},$true));Assert ($dbAssignment.Count -eq 1)
$commands=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst]},$true))
$sealed=@($commands|Where-Object {$_.GetCommandName() -ceq 'WriteJson' -and $_.Extent.Text.Contains("'before-files.json'")});Assert ($sealed.Count -eq 1)
$forced=@($commands|Where-Object {$_.GetCommandName() -ceq 'InvokeHelper' -and $_.Extent.Text.Contains("'forced-direct'")});Assert ($forced.Count -eq 1)
$fullEqual=@($commands|Where-Object {$_.GetCommandName() -ceq 'Equal' -and $_.Extent.Text.StartsWith('Equal $files (FilesSnapshot) ') -and $_.Extent.StartOffset -gt $forced[0].Extent.EndOffset});Assert ($fullEqual.Count -eq 1)
Assert ($fileAssignment[0].Extent.StartOffset -lt $taskAssignment[0].Extent.StartOffset -and $taskAssignment[0].Extent.StartOffset -lt $dbAssignment[0].Extent.StartOffset -and $dbAssignment[0].Extent.EndOffset -lt $sealed[0].Extent.StartOffset -and $sealed[0].Extent.EndOffset -lt $start -and $end -lt $forced[0].Extent.StartOffset -and $forced[0].Extent.EndOffset -lt $fullEqual[0].Extent.StartOffset)
$state='C:\ProgramData\OpenWebPBX';$controlRoot=$state+'\backup-control'
$original=@{
 ($state)=@{directory=$true;acl='PARENT'}
 ($controlRoot)=@{directory=$true;acl='ROOT'}
 ($controlRoot+'\nested')=@{directory=$true;acl='CHILD'}
 ($controlRoot+'\request.json')=@{directory=$false;acl='FILE';bytes=17;sha256='hash-one'}
 ($controlRoot+'\nested\owner.json')=@{directory=$false;acl='NESTED';bytes=19;sha256='hash-two'}
 ($controlRoot.ToUpperInvariant()+'\UPPER.json')=@{directory=$false;acl='UPPER';bytes=23;sha256='hash-three'}
 ($controlRoot+'-foreign\foreign.json')=@{directory=$false;acl='FOREIGN';bytes=29;sha256='foreign'}
}
$expected=@{};foreach($key in $original.Keys){if($key.Equals($controlRoot,[StringComparison]::OrdinalIgnoreCase) -or $key.StartsWith($controlRoot+'\',[StringComparison]::OrdinalIgnoreCase)){$expected[$key]=$original[$key]}}
function FilesSnapshot([switch]$BackupControlOnly){Assert ([bool]$BackupControlOnly);$script:snapshotCalls++;return $script:observedControl}
function Equal($Before,$After,[string]$Message){$script:equalCalls++;Assert ($Message -ceq 'Backup control changed before any injected rollback fault; retain the original baseline.');if((Fingerprint $Before) -cne (Fingerprint $After)){throw 'FICTIONAL_CONTROL_INEQUALITY'}}
function InvokeHelper {$script:faultCalls++}
$scenarios=@(@{kind='same';key=''},@{kind='new_file';key=''},@{kind='foreign_observed';key=''},@{kind='extra_field';key=''},@{kind='wrong_type';key=''})
foreach($key in $expected.Keys){$scenarios+=@{kind='missing';key=$key};$scenarios+=@{kind='acl';key=$key};$scenarios+=@{kind='directory';key=$key};if(!$expected[$key].directory){$scenarios+=@{kind='hash';key=$key};$scenarios+=@{kind='bytes';key=$key}}}
foreach($scenario in $scenarios){
 $files=Copy-Map $original;$reference=$files;$before=Fingerprint $files;$script:observedControl=Copy-Map $expected
 switch($scenario.kind){
  'missing'{$null=$script:observedControl.Remove($scenario.key)}
  'acl'{$script:observedControl[$scenario.key].acl='CHANGED'}
  'directory'{$script:observedControl[$scenario.key].directory=!$script:observedControl[$scenario.key].directory}
  'hash'{$script:observedControl[$scenario.key].sha256='CHANGED'}
  'bytes'{$script:observedControl[$scenario.key].bytes++}
  'new_file'{$script:observedControl[$controlRoot+'\new.json']=@{directory=$false;acl='NEW';bytes=31;sha256='new'}}
  'foreign_observed'{$script:observedControl[$state]=@{directory=$true;acl='PARENT'}}
  'extra_field'{$script:observedControl[$controlRoot].extra='CHANGED'}
  'wrong_type'{$script:observedControl[$controlRoot+'\request.json'].bytes='17'}
 }
 $script:faultCalls=0;$script:equalCalls=0;$script:snapshotCalls=0;$caught=$false
 try{. $guard;InvokeHelper}catch{$caught=$true}
 Assert ($script:equalCalls -eq 1 -and $script:snapshotCalls -eq 1)
 Assert ([object]::ReferenceEquals($reference,$files) -and (Fingerprint $files) -ceq $before)
 Assert ((Fingerprint $controlBaseline) -ceq (Fingerprint $expected))
 if($scenario.kind -ceq 'same'){Assert (!$caught -and $script:faultCalls -eq 1 -and $phase -ceq 'actual direct post-deploy rollback')}
 else{Assert ($caught -and $script:faultCalls -eq 0 -and $phase -ceq 'pre-fault backup control stability')}
}
Write-Output "PASS $script:checks actual AST backup-control scope/original-baseline/pre-fault refusal/order controls; no installed service or network invoked"
