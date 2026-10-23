# Real failure producers/consumers and temporary-file writes. No native task/API execution.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
. (Join-Path $SourceRoot 'tests/windows_phone_catalogue_proof.ps1')
$checks=0
function Check([bool]$Ok){if(!$Ok){throw ('Catalogue failure control '+($script:checks+1)+' refused.')};$script:checks++}
function Refuse([scriptblock]$Body){$denied=$false;try{&$Body|Out-Null}catch{$denied=$true};Check $denied}
$php=[ordered]@{schema=1;producer='windows_phone_catalogue_native.php';state='failed';source_basename='refresh.fixture.php';source_line=29;error_type='RuntimeException'}
function PhpCopy{return($php|ConvertTo-Json|ConvertFrom-Json)}
Check ((Read-WindowsPhoneCataloguePhpFailure (PhpCopy)).source_line -eq 29)
foreach($key in $php.Keys){$bad=PhpCopy;$bad.PSObject.Properties.Remove($key);Refuse {Read-WindowsPhoneCataloguePhpFailure $bad}}
foreach($field in 'schema','source_line'){foreach($value in @($true,'1',1.0,$null,-1,100001)){$bad=PhpCopy;$bad.$field=$value;Refuse {Read-WindowsPhoneCataloguePhpFailure $bad}}}
foreach($field in 'producer','state','source_basename','error_type'){foreach($value in @($true,$null,@('failed'),'PRIVATE-PATH-MESSAGE')){$bad=PhpCopy;$bad.$field=$value;Refuse {Read-WindowsPhoneCataloguePhpFailure $bad}}}
$bad=PhpCopy;$bad|Add-Member path 'PRIVATE-PATH';Refuse {Read-WindowsPhoneCataloguePhpFailure $bad}
$native=[ordered]@{schema=1;producer='windows_phone_catalogue_native.ps1';state='failed';phase='seed';source_basename='windows_phone_catalogue_native.ps1';source_line=30;error_type='System.InvalidOperationException';edition='Core';php_child_exit=4;php_failure=(PhpCopy);php_output=$null;child_processes_closed=$true;owned_task_removed=$true;original_vectors_preserved=$true;owned_scope_retained=$true;cleanup_required=$false;actual_native_qualified=$false}
function NativeCopy{return($native|ConvertTo-Json -Depth 5|ConvertFrom-Json)}
Check ((Read-WindowsPhoneCatalogueNativeFailure (NativeCopy) Core).php_child_exit -eq 4)
foreach($key in $native.Keys){$bad=NativeCopy;$bad.PSObject.Properties.Remove($key);Refuse {Read-WindowsPhoneCatalogueNativeFailure $bad Core}}
foreach($field in 'child_processes_closed','owned_task_removed','original_vectors_preserved','owned_scope_retained','cleanup_required','actual_native_qualified'){foreach($value in @($null,'true',1)){$bad=NativeCopy;$bad.$field=$value;Refuse {Read-WindowsPhoneCatalogueNativeFailure $bad Core}}}
foreach($field in 'phase','source_basename','error_type','edition'){$bad=NativeCopy;$bad.$field='PRIVATE-PATH-MESSAGE';Refuse {Read-WindowsPhoneCatalogueNativeFailure $bad Core}}
foreach($value in @($true,'1',1.5,2147483648)){$bad=NativeCopy;$bad.php_child_exit=$value;Refuse {Read-WindowsPhoneCatalogueNativeFailure $bad Core}}
$bad=NativeCopy;$bad.php_child_exit=0;Refuse {Read-WindowsPhoneCatalogueNativeFailure $bad Core}
$bad=NativeCopy;$bad.actual_native_qualified=$true;Refuse {Read-WindowsPhoneCatalogueNativeFailure $bad Core}
$bad=NativeCopy;$bad.owned_task_removed=$false;Refuse {Read-WindowsPhoneCatalogueNativeFailure $bad Core}
$bad=NativeCopy;$bad.php_failure|Add-Member secret 'PRIVATE';Refuse {Read-WindowsPhoneCatalogueNativeFailure $bad Core}
$bad=NativeCopy;$bad.php_output=Get-WindowsPhoneCatalogueChildOutput '--refresh' $false 'Warning: PRIVATE' ($php|ConvertTo-Json -Compress)
Check ((Read-WindowsPhoneCatalogueNativeFailure $bad Core).php_output.action -ceq '--refresh')
$bad.php_child_exit=$null;$bad.php_failure=$null;Refuse {Read-WindowsPhoneCatalogueNativeFailure $bad Core}
$bad=NativeCopy;$bad.php_output=@{action='PRIVATE'};Refuse {Read-WindowsPhoneCatalogueNativeFailure $bad Core}
$work=Join-Path ([IO.Path]::GetTempPath()) ('catalogue-failure-'+[Guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($work)
try{
 foreach($file in 'windows_phone_catalogue_native.ps1','windows-phone-catalogue-qualification.ps1'){
  $t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot ('tests/'+$file)),[ref]$t,[ref]$e);Check (!$e)
  $outer=@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]});Check ($outer.Count -eq 1 -and $outer[0].CatchClauses.Count -eq 1)
  $body=$outer[0].CatchClauses[0].Body.Extent.Text;$body=$body.Substring(1,$body.Length-2)
  foreach($collision in $false,$true){
   $reportOwned=$true;$ReportPath=Join-Path $work ([Guid]::NewGuid().ToString('N')+'.json');$phase='preparation';$source=('a'*40);$edition='Core';$childExit=$null;$childFailure=$null;$packageBound=$false;$stockExact=$false;$childEnded=$true;$childrenClosed=$true;$taskRemoved=$true;$vectorsExact=$false
   if($collision){[IO.File]::WriteAllText($ReportPath,'KEEP-ORIGINAL')}
   $original=[InvalidOperationException]::new('PRIVATE-PATH-MESSAGE-SECRET');$caught=$null
   try{&([scriptblock]::Create('try{throw $original}catch{'+$body+'}'))}catch{$caught=$_}
   Check ($null -ne $caught -and $caught.Exception -eq $original)
   if($collision){Check ([IO.File]::ReadAllText($ReportPath)-ceq 'KEEP-ORIGINAL');Check ($original.Data.Count -eq 1)}
   else{
    $raw=[IO.File]::ReadAllText($ReportPath);Check (!$raw.Contains('PRIVATE-PATH-MESSAGE-SECRET') -and !$raw.Contains($work))
    $value=$raw|ConvertFrom-Json;Check ($value.state-ceq 'failed' -and $value.phase-ceq 'preparation')
    if($file -ceq 'windows_phone_catalogue_native.ps1'){Check ((Read-WindowsPhoneCatalogueNativeFailure $value Core).cleanup_required)}
    else{Check ($value.child_exit -eq $null -and !$value.native_cleanup_verified -and !$value.production_release_published)}
   }
  }
 }
}finally{[IO.Directory]::Delete($work,$true)}
# Execute the actual native finally loop with explicit Process API adapters.
$t=$null;$e=$null;$nativeAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows_phone_catalogue_native.ps1'),[ref]$t,[ref]$e)
$loops=@($nativeAst.FindAll({param($n)$n -is [Management.Automation.Language.ForEachStatementAst] -and $n.Variable.VariablePath.UserPath -ceq 'child' -and $n.Condition.Extent.Text -ceq '$children'},$true));Check (!$e -and $loops.Count -eq 1)
$cleanup=[scriptblock]::Create($loops[0].Extent.Text)
function MockChild([string]$Kind){
 $time=[DateTime]::UtcNow;$process=[pscustomobject]@{HasExited=($Kind -ceq 'exited');StartTime=$time;MainModule=[pscustomobject]@{FileName='C:\fictional-owned.exe'};Kind=$Kind;Killed=$false;Disposed=$false}
 $process|Add-Member ScriptMethod Kill {$this.Killed=$true;if($this.Kind -ceq 'kill_error'){throw 'Fixture process kill refusal.'}}
 $process|Add-Member ScriptMethod WaitForExit {param($Milliseconds)if($Milliseconds -ne 10000){throw 'The original cleanup deadline changed.'};if($this.Kind -ceq 'wait_error'){throw 'Fixture process wait refusal.'};return $this.Kind -cne 'timeout'}
 $process|Add-Member ScriptMethod Dispose {$this.Disposed=$true}
 return [pscustomobject]@{Process=$process;Started=$time.ToUniversalTime().Ticks;Executable='C:\fictional-owned.exe'}
}
foreach($kind in 'success','exited','timeout','wait_error','kill_error'){
 $child=MockChild $kind;$children=@($child);$childrenClosed=$true;$original=[InvalidOperationException]::new('Original fixture primary');$primary=[Management.Automation.ErrorRecord]::new($original,'fixture',[Management.Automation.ErrorCategory]::NotSpecified,$null)
 . $cleanup
 $pass=$kind -cin 'success','exited';Check ($childrenClosed -eq $pass);Check $child.Process.Disposed
 Check ($original.Data.Contains('catalogue_fixture_child_cleanup_failed') -eq !$pass)
}
$children=@((MockChild 'timeout'),(MockChild 'success'));$childrenClosed=$true;$primary=[Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('Original fixture primary'),'fixture',[Management.Automation.ErrorCategory]::NotSpecified,$null)
. $cleanup;Check (!$childrenClosed -and $children[0].Process.Disposed -and $children[1].Process.Disposed)
$children=@((MockChild 'timeout'));$childrenClosed=$true;$primary=$null;$denied=$false;try{. $cleanup}catch{$denied=$true};Check $denied;Check (!$childrenClosed)
Write-Output ('PASS '+$checks+' actual closed catalogue failure/type/early-catch/primary-preservation controls; native primitives not executed')
