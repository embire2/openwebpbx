# Actual parent wrapper, controlled failures only; no installed service is accessed.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$checks=0
function Check([bool]$Value){if(!$Value){throw ('Welcome quiescence control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
$tokens=$null;$errors=$null;$path=Join-Path $SourceRoot 'tests/windows-native-acceptance.ps1'
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors);Check ($errors.Count -eq 0)
$text=[IO.File]::ReadAllText($path)
Check ($text.Contains(". (Join-Path `$PSScriptRoot 'windows-health-updater-quiescence.ps1')"))
$nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.TryStatementAst] -and $n.Body.Statements.Count -eq 2 -and $n.Body.Statements[0].Extent.Text -ceq 'Suspend-HealthQualificationUpdater ([ref]$welcomeUpdaterOriginal)'},$true));Check ($nodes.Count -eq 1)
$wrapper=$nodes[0];Check ($wrapper.CatchClauses.Count -eq 0)
Check ($wrapper.Body.Statements.Count -eq 2 -and $wrapper.Finally.Statements.Count -eq 1)
Check ($wrapper.Body.Statements[0].Extent.Text -ceq 'Suspend-HealthQualificationUpdater ([ref]$welcomeUpdaterOriginal)')
Check ($wrapper.Body.Statements[1].Extent.Text -ceq "Python 'acceptance'")
Check ($wrapper.Finally.Statements[0].Extent.Text -ceq 'Resume-HealthQualificationUpdater $welcomeUpdaterOriginal')
Check ($text.Contains("`$phase='normal HTTPS and native calling';`$welcomeUpdaterOriginal=`$null"))
Check (((Get-FileHash -LiteralPath (Join-Path $SourceRoot 'tests/windows-health-updater-quiescence.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()) -ceq '3d18a0ca0c6731ea4e7115196fbf5961db1e1bfb5d37ce8732e70ff9c60fc257')
$php=[IO.File]::ReadAllText((Join-Path $SourceRoot 'tests/windows_welcome_native.php'))
$start=$php.IndexOf('function welcome_public_fingerprint(PDO $db):string{');$end=$php.IndexOf("`nif(`$action==='prepare'){",$start)
Check ($start -ge 0 -and $end -gt $start)
$raw=[Text.UTF8Encoding]::new($false).GetBytes($php.Substring($start,$end-$start));$hash=[Security.Cryptography.SHA256]::HashData($raw)
Check (([Convert]::ToHexString($hash).ToLowerInvariant()) -ceq 'fef2517942e0e0770be7fc37f43f7d7afb72de01568ff867f6211befe58b1761')
$actual=[scriptblock]::Create($wrapper.Extent.Text)
function Suspend-HealthQualificationUpdater([ref]$Original){
 $script:events.Add('suspend')
 if($script:failure -ceq 'before_suspend'){throw 'before_suspend'}
 $Original.Value=$script:original;$script:current=@{Running=$false;TaskEnabled=$false;TaskXml=$script:original.TaskXml;StartMode=$script:original.StartMode}
 if($script:failure -ceq 'partial_suspend'){throw 'partial_suspend'}
}
function Python([string]$Phase){
 Check ($Phase -ceq 'acceptance');Check (!$script:current.Running -and !$script:current.TaskEnabled);$script:events.Add('child')
 if($script:failure -cin 'child','cleanup','child_and_restore'){throw $script:failure}
}
function Resume-HealthQualificationUpdater($Original){
 $script:events.Add('resume')
 if($null -eq $Original){Check ($script:failure -ceq 'before_suspend');return}
 Check ([object]::ReferenceEquals($Original,$script:original))
 if($script:failure -cin 'restore','child_and_restore'){throw 'restore_refusal'}
 $script:current=@{};foreach($key in $Original.Keys){$script:current[$key]=$Original[$key]}
}
foreach($mode in 'normal','native_diagnostics','hold_diagnostics','threecx_import'){
 $NativeDiagnosticsOnly=$mode -ne 'normal';$HoldDiagnosticsOnly=$mode -ceq 'hold_diagnostics';$ThreecxImportOnly=$mode -ceq 'threecx_import'
 foreach($running in $true,$false){foreach($enabled in $true,$false){foreach($failure in 'none','before_suspend','partial_suspend','child','cleanup','restore','child_and_restore'){
  $script:failure=$failure;$script:events=[Collections.Generic.List[string]]::new();$script:original=@{Running=$running;TaskEnabled=$enabled;TaskXml='exact_original_xml';StartMode='Manual'};$script:current=@{};foreach($key in $original.Keys){$current[$key]=$original[$key]}
  $welcomeUpdaterOriginal=$null;$errorName=$null
  try{. $actual}catch{$errorName=$_.Exception.Message}
  Check ($events[0] -ceq 'suspend' -and $events[$events.Count-1] -ceq 'resume')
  Check (@($events|Where-Object {$_ -ceq 'child'}).Count -eq $(if($failure -cin 'before_suspend','partial_suspend'){0}else{1}))
  if($failure -ceq 'none'){Check ($null -eq $errorName)}elseif($failure -cin 'restore','child_and_restore'){Check ($errorName -ceq 'restore_refusal')}else{Check ($errorName -ceq $failure)}
  if($failure -cnotin 'restore','child_and_restore'){foreach($key in $original.Keys){Check ($current[$key] -ceq $original[$key])}}
 }}}
}
Write-Output ('PASS '+$checks+' actual-parent welcome quiescence/failure/restoration controls; OS service APIs are adapters only')
