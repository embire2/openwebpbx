# SPDX-License-Identifier: AGPL-3.0-or-later
# Actual discovery consumer with real ApplicationInfo values and owned data-only
# executable fixtures. Discovery is doubled; fixture executables never execute.
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$tool=Join-Path $PSScriptRoot '../../tools/Test-ClientMedia.ps1';$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile([IO.Path]::GetFullPath($tool),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The actual media wrapper does not parse.'}
$found=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'ResolveMediaApplication'},$true))
if($found.Count -ne 1){throw 'Exactly one actual discovery helper is required.'};. ([scriptblock]::Create($found[0].Extent.Text))
$root=Join-Path ([IO.Path]::GetTempPath()) ('phone-media-applications-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root);$checks=0;$aliasName=$null
function Check([bool]$Value){if(!$Value){throw 'An actual application-discovery control failed.'};$script:checks++}
function Refuse([scriptblock]$Action){$refused=$false;try{$null=& $Action}catch{$refused=$true};Check $refused}
function ActualApplication([string]$Leaf){
 $path=Join-Path $root $Leaf;[IO.File]::WriteAllBytes($path,[byte[]]@(77,90,0,0))
 if(!$IsWindows){[IO.File]::SetUnixFileMode($path,[IO.UnixFileMode]493)}
 Microsoft.PowerShell.Core\Get-Command $path -CommandType Application -ErrorAction Stop
}
try{
 $first=ActualApplication 'first.exe';$second=ActualApplication 'second.exe';$otherExtension=ActualApplication 'not-native.cmd';$zero=ActualApplication 'empty.exe';[IO.File]::WriteAllBytes($zero.Source,[byte[]]@())
 $missing=ActualApplication 'missing.exe';[IO.File]::Delete($missing.Source)
 $aliasName='media-fixture-alias-'+[Guid]::NewGuid().ToString('N');Set-Alias -Name $aliasName -Value Get-Item -Scope Local;$alias=Microsoft.PowerShell.Core\Get-Command $aliasName -CommandType Alias
 $script:discovered=@();$script:lookups=0
 function Get-Command {
  [CmdletBinding()]param([string]$Name,[Management.Automation.CommandTypes]$CommandType)
  if($Name -cnotin @('dotnet','python') -or $CommandType -ne [Management.Automation.CommandTypes]::Application){throw 'The actual application-only discovery contract changed.'}
  $script:lookups++;$script:discovered
 }
 $script:discovered=@($first,$second);$selected=ResolveMediaApplication python;Check ($selected -is [string] -and $selected -ceq $first.Source);Check ($script:lookups -eq 1)
 $script:discovered=@($second,$first);Check ((ResolveMediaApplication dotnet) -ceq $second.Source)
 $script:discovered=@();Refuse {ResolveMediaApplication python}
 $script:discovered=@($alias);Refuse {ResolveMediaApplication python}
 $script:discovered=@([pscustomobject]@{Source=$first.Source;Path=$first.Source;CommandType=[Management.Automation.CommandTypes]::Application});Refuse {ResolveMediaApplication python}
 $script:discovered=@($zero);Refuse {ResolveMediaApplication python}
 $script:discovered=@($otherExtension);Refuse {ResolveMediaApplication python}
 $script:discovered=@($missing);Refuse {ResolveMediaApplication python}
 $script:discovered=@($zero,$second);Refuse {ResolveMediaApplication python}
 Refuse {ResolveMediaApplication git}
 $link=Join-Path $root 'linked.exe';[void][IO.File]::CreateSymbolicLink($link,$first.Source);$linked=Microsoft.PowerShell.Core\Get-Command $link -CommandType Application
 $script:discovered=@($linked);Refuse {ResolveMediaApplication python};[IO.File]::Delete($link)
 # ETS shadows leave the value's real ApplicationInfo class intact, allowing
 # direct refusal checks of source/path validation without invoking anything.
 foreach($value in @('relative.exe',($first.Source+"`n"+$second.Source),[IO.Path]::GetDirectoryName($first.Source))){
  $copy=ActualApplication ([Guid]::NewGuid().ToString('N')+'.exe');$copy|Add-Member -NotePropertyName Source -NotePropertyValue $value -Force
  $script:discovered=@($copy);Refuse {ResolveMediaApplication python}
 }
 [ordered]@{schema=1;state='passed_actual_application_discovery_consumer';checks=$checks;native_applicationinfo=$true;discovery_results_doubled=$true;fixture_executables_started=$false;actual_native_calling=$false}|ConvertTo-Json -Compress
}finally{
 Remove-Item Function:Get-Command -ErrorAction SilentlyContinue
 if($aliasName){Remove-Item ('Alias:'+ $aliasName) -ErrorAction SilentlyContinue}
 Remove-Item -LiteralPath $root -Recurse -Force
}
