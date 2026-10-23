# Actual activation function and real private files. Native ACL/lock and Scheduler
# bindings are explicit adapters; actual Windows filesystem/account proof is separate.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest;$script:checks=0
function Check([bool]$ok){if(!$ok){throw ('Catalogue activation control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
$t=$null;$e=$null;$tree=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'packaging/windows/WindowsPhoneCatalogue.Common.ps1'),[ref]$t,[ref]$e);Check ($e.Count -eq 0)
$node=@($tree.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Complete-OpenWebWindowsPhoneCatalogueActivation'},$true));Check ($node.Count -eq 1);Invoke-Expression $node[0].Extent.Text
$base=Join-Path ([IO.Path]::GetTempPath()) ('openweb-catalogue-activation-'+[Guid]::NewGuid().ToString('N'));$root=Join-Path $base 'root';$state=Join-Path $base 'state';$directory=Join-Path $state 'windows-phone-catalogue';$script:WindowsPhoneCatalogueTask='OpenWebPBX-WindowsPhoneCatalogue'
foreach($p in $root,(Join-Path $root 'web'),$state,$directory,(Join-Path $state 'updates')){$null=[IO.Directory]::CreateDirectory($p)}
$script:activation=Join-Path $directory 'activation.json';$script:enabled=$false;$script:events=[Collections.Generic.List[string]]::new();$script:fault='';$script:hold=$false;$script:foreignTask=$false
function NativePath([string]$p){return $p.Replace('\',[string][IO.Path]::DirectorySeparatorChar)}
function Get-OpenWebWindowsPhoneCataloguePaths([string]$Root,[string]$StateRoot){return [pscustomobject]@{Directory=$directory}}
function Assert-OpenWebRecoveryLock {param($MaintenanceLock,$StateRoot)$script:events.Add('lock')}
function Assert-OpenWebRecoveryProtected([string]$Path){return $Path}
function Assert-OpenWebUpgradeAllowed {param($StateRoot)if($script:hold){throw 'Explicit fixture restore hold'};$script:events.Add('no-holds')}
function Assert-OpenWebWindowsPhoneCatalogueTask {param($Task,$Paths)if($script:foreignTask){throw 'Explicit fixture foreign task'};$script:events.Add('owned-task')}
function Get-ScheduledTask {param($TaskName)return [pscustomobject]@{Settings=[pscustomobject]@{Enabled=$script:enabled}}}
function Enable-ScheduledTask {param($TaskName)$script:events.Add('enable');if($script:fault -ceq 'before-enable'){throw 'Fixture interrupted before enable'};$script:enabled=$true;if($script:fault -ceq 'after-enable'){throw 'Fixture interrupted after enable'}}
function Disable-ScheduledTask {param($TaskName)$script:events.Add('disable');$script:enabled=$false}
function Write-OpenWebWindowsPhoneCatalogueState {param($Path,$Value)$script:events.Add('write-complete');if($script:fault -ceq 'before-complete'){throw 'Fixture interrupted before complete write'};[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false));if($script:fault -ceq 'after-complete'){throw 'Fixture interrupted after complete write'}}
function Seed([string]$Owner='install',[bool]$Wanted=$true){
 $script:enabled=$false;$script:events.Clear();$script:fault='';$script:hold=$false;$script:foreignTask=$false
 $script:intent=[ordered]@{schema=1;component='windows-free-phone';owner=$Owner;version='1.0.0';task_before_exists=$true;enable_on_commit=$Wanted;phase='prepared';task_definition_sha256=('a'*64)}
 [IO.File]::WriteAllText($script:activation,($script:intent|ConvertTo-Json),[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText((Join-Path $state 'installation.json'),'{"Completed":true,"Version":"1.0.0"}');[IO.File]::WriteAllText((Join-Path $root 'web/VERSION'),'1.0.0');[IO.File]::WriteAllText((Join-Path $directory 'task.json'),('{"definition_sha256":"'+('a'*64)+'"}'))
 $journal=Join-Path $state 'updates/install-journal.json';if(Test-Path $journal){Remove-Item $journal};if($Owner -ceq 'upgrade'){[IO.File]::WriteAllText($journal,'{"state":"completed","version":"1.0.0"}')}
}
function Run([string]$Owner='install'){
 # Only Windows path-separator construction is adapted on Linux. The executing
 # activation decisions, native JSON primitive types and order are unchanged.
 if([IO.Path]::DirectorySeparatorChar -eq '/'){
  $actual=$node[0].Extent.Text.Replace("'web\VERSION'","'web/VERSION'").Replace("'updates\install-journal.json'","'updates/install-journal.json'");Invoke-Expression $actual
 }
 Complete-OpenWebWindowsPhoneCatalogueActivation -Owner $Owner -Root $root -StateRoot $state -MaintenanceLock $null
}
function Denied([string]$Owner='install'){$caught=$false;try{Run $Owner}catch{$caught=$true};Check $caught}
try{
 foreach($owner in 'install','upgrade'){
  foreach($position in 'before-enable','after-enable','before-complete','after-complete'){
   Seed $owner;$script:fault=$position;Denied $owner
   $observed=Microsoft.PowerShell.Management\Get-Content -LiteralPath $script:activation -Raw|ConvertFrom-Json
   Check ($observed.phase -ceq $(if($position -ceq 'after-complete'){'complete'}else{'prepared'}))
   Check ($script:enabled -ceq ($position -cne 'before-enable'))
   $script:fault='';$script:events.Clear();Run $owner;Check $script:enabled
   $observed=Microsoft.PowerShell.Management\Get-Content -LiteralPath $script:activation -Raw|ConvertFrom-Json;Check ($observed.phase -ceq 'complete')
   if($position -cne 'after-complete'){Check ($script:events.IndexOf('enable') -lt $script:events.IndexOf('write-complete'))}else{Check ($script:events.Count -eq 1)}
  }
 }
 Seed install $false;Run;Check (!$script:enabled -and ($script:events -join '|').Contains('disable|write-complete'))
 Seed;Run;$script:enabled=$false;$before=[IO.File]::ReadAllText($script:activation);$script:events.Clear();Run;Check (!$script:enabled -and $script:events.Count -eq 1 -and [IO.File]::ReadAllText($script:activation) -ceq $before)
 foreach($kind in 'foreign-owner','foreign-component','version','incomplete','hold','foreign-task','wrong-hash','schema','choice','extra'){
  Seed;$before=[IO.File]::ReadAllText($script:activation)
  switch($kind){'foreign-owner'{$script:intent.owner='restore'}'foreign-component'{$script:intent.component='android'}version{$script:intent.version='9.0.0'}incomplete{[IO.File]::WriteAllText((Join-Path $state 'installation.json'),'{"Completed":false,"Version":"1.0.0"}')}hold{$script:hold=$true}'foreign-task'{$script:foreignTask=$true}'wrong-hash'{$script:intent.task_definition_sha256='b'*64}schema{$script:intent.schema=$true}choice{$script:intent.enable_on_commit='true'}extra{$script:intent.extra='UNPUBLISHED_FIXTURE_VALUE'}}
  if($kind -notin 'incomplete','hold','foreign-task'){[IO.File]::WriteAllText($script:activation,($script:intent|ConvertTo-Json));$before=[IO.File]::ReadAllText($script:activation)}
  Denied;Check (!$script:enabled -and !$script:events.Contains('enable') -and !$script:events.Contains('disable') -and !$script:events.Contains('write-complete') -and [IO.File]::ReadAllText($script:activation) -ceq $before)
 }
 Seed;[IO.File]::WriteAllText((Join-Path $state 'updates/install-journal.json'),'{"state":"completed","version":"1.0.0"}');Denied;Check (!$script:enabled -and !$script:events.Contains('enable'))
 Seed upgrade;[IO.File]::WriteAllText((Join-Path $state 'updates/install-journal.json'),'{"state":"validating","version":"1.0.0"}');Denied upgrade;Check (!$script:enabled -and !$script:events.Contains('enable'))
 Write-Output ('PASS '+$script:checks+' actual catalogue activation interruption/retry/refusal controls; Scheduler/ACL/lock adapters explicit, owned temporary files only')
}finally{Remove-Item -LiteralPath $base -Recurse -Force}
