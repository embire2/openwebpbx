# SPDX-License-Identifier: AGPL-3.0-or-later
# Execute the actual SDK selection block. Only the executable name is adapted.
param([Parameter(Mandatory)][string]$DotNet,[string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$checks=0
function Assert([bool]$Value){if(!$Value){throw 'Canary SDK control refused.'};$script:checks++}
function Check([bool]$Value,[string]$Message){if(!$Value){throw $Message}}
$DotNet=[IO.Path]::GetFullPath($DotNet)
Assert ([IO.File]::Exists($DotNet) -and !([IO.File]::GetAttributes($DotNet)-band [IO.FileAttributes]::ReparsePoint))
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-updater-qualification.ps1'),[ref]$tokens,[ref]$errors)
Assert (!$errors)
$function=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name-ceq 'PrepareCanary'},$true));Assert ($function.Count-eq 1)
$probe=@($function[0].FindAll({param($node)$node -is [Management.Automation.Language.TryStatementAst] -and $node.Body.Extent.Text.Contains("'The pinned .NET SDK is required.'")},$true));Assert ($probe.Count-eq 1)
$push=@($function[0].FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName()-ceq 'Push-Location'},$true));Assert ($push.Count-eq 1 -and $push[0].Extent.Text-ceq 'Push-Location $overlay')
$original="Check ((& dotnet.exe --version).Trim() -eq '10.0.401') 'The pinned .NET SDK is required.'"
Assert ($probe[0].Body.Statements.Count-eq 1 -and $probe[0].Body.Statements[0].Extent.Text-ceq $original -and $probe[0].Finally.Statements.Count-eq 1 -and $probe[0].Finally.Statements[0].Extent.Text-ceq 'Pop-Location')
$block=[scriptblock]::Create($push[0].Extent.Text+"`n"+$probe[0].Extent.Text)
$root=Join-Path ([IO.Path]::GetTempPath()) ('openweb-canary-sdk-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root)
$overlay=Join-Path $root 'overlay';[void][IO.Directory]::CreateDirectory($overlay)
$missing='{"sdk":{"version":"999.0.999","rollForward":"disable"}}';$exact='{"sdk":{"version":"10.0.401","rollForward":"disable"}}'
$errorFile=Join-Path $root 'native.private.stderr'
function dotnet.exe { & $DotNet @args 2>$errorFile }
$before=(Get-Location).Path
try{
 [IO.File]::WriteAllText((Join-Path $root 'global.json'),$missing);[IO.File]::WriteAllText((Join-Path $overlay 'global.json'),$exact)
 Push-Location $root
 try{
  $refused=$false;try{& ([scriptblock]::Create($original))}catch{$refused=$true};Assert $refused
  Assert ((Get-Location).Path-ceq $root)
  & $block;Assert ((Get-Location).Path-ceq $root)
  Assert ([IO.File]::ReadAllText((Join-Path $root 'global.json'))-ceq $missing -and [IO.File]::ReadAllText((Join-Path $overlay 'global.json'))-ceq $exact)
  [IO.File]::WriteAllText((Join-Path $overlay 'global.json'),$missing)
  $refused=$false;try{& $block}catch{$refused=$true};Assert ($refused -and (Get-Location).Path-ceq $root)
  $primary=[InvalidOperationException]::new('Expected owned SDK invocation failure')
  function dotnet.exe { throw $primary }
  $caught=$null;try{& $block}catch{$caught=$_};Assert ($null-ne $caught -and [object]::ReferenceEquals($caught.Exception,$primary) -and (Get-Location).Path-ceq $root)
 }finally{Pop-Location}
 Assert ((Get-Location).Path-ceq $before)
}finally{[IO.Directory]::Delete($root,$true)}
"PASS $checks actual SDK/global.json/source/location/primary controls; native executable-name adapter explicit"
