# Read-only native module/membership proof with exact-source provenance refusals.
# No PBX configuration, service, task, account or group is changed.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest;$script:checks=0
if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or ![Environment]::Is64BitProcess){throw 'Run this read-only proof in64-bit Windows PowerShell or PowerShell7.'}
function Check([bool]$Value){if(!$Value){throw ('Recovery module control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
function Refuses([scriptblock]$Action){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Check $failed}
$path=Join-Path $SourceRoot 'packaging/windows/UpgradeRecovery.Common.ps1'
. $path
Remove-Variable -Scope Script -Name OpenWebRecoveryPrivilegedSids,OpenWebRecoveryPrivilegedUntil -ErrorAction SilentlyContinue
$allowed=Get-OpenWebRecoveryPrivilegedSids
Check ($allowed -is [Collections.Generic.HashSet[string]] -and $allowed.Contains('S-1-5-18') -and $allowed.Contains('S-1-5-32-544'))
$stock=Get-Command -Name 'Microsoft.PowerShell.LocalAccounts\Get-LocalGroupMember' -CommandType Cmdlet -ErrorAction Stop
$module=Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\Modules\Microsoft.PowerShell.LocalAccounts'
Check ($stock -is [Management.Automation.CmdletInfo] -and $stock.Module.ModuleBase.StartsWith($module+'\',[StringComparison]::OrdinalIgnoreCase))
$members=@(& $stock -SID 'S-1-5-32-544' -ErrorAction Stop)
foreach($member in $members){Check ($allowed.Contains([string]$member.SID))}
$cached=Get-OpenWebRecoveryPrivilegedSids;Check ([object]::ReferenceEquals($allowed,$cached))
# Execute the actual validation block with explicit command/root inputs. The
# positive command is the real OS CmdletInfo; negative objects never execute.
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors);Check ($errors.Count -eq 0)
$functions=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Get-OpenWebRecoveryPrivilegedSids'},$true));Check ($functions.Count -eq 1)
$statements=@($functions[0].Body.EndBlock.Statements)
$first=@($statements|Where-Object {$_ -is [Management.Automation.Language.IfStatementAst] -and $_.Clauses[0].Item1.Extent.Text.StartsWith('$commands.Count -ne')})
$last=@($statements|Where-Object {$_ -is [Management.Automation.Language.ForEachStatementAst] -and $_.Variable.VariablePath.UserPath -ceq 'member'});Check ($first.Count -eq 1 -and $last.Count -eq 1)
$parts=@($statements|Where-Object {$_.Extent.StartOffset -ge $first[0].Extent.StartOffset -and $_.Extent.EndOffset -lt $last[0].Extent.StartOffset});Check ($parts.Count -eq 6)
$block=[scriptblock]::Create(($parts|ForEach-Object {$_.Extent.Text}) -join "`n")
$commands=@($stock);. $block;Check ([object]::ReferenceEquals($stock,$command))
function ForeignProxy {throw 'A proxy command must never run.'}
$proxy=Get-Command ForeignProxy -CommandType Function
$foreign=Get-Command Microsoft.PowerShell.Management\Get-Item -CommandType Cmdlet
foreach($objects in @(@(),@($stock,$stock),@($proxy),@($foreign),@([pscustomobject]@{ModuleName='Microsoft.PowerShell.LocalAccounts'}))){$commands=@($objects);Refuses {. $block}}
$commands=@($stock);$originalRoot=$module
foreach($wrong in $originalRoot.Substring(0,$originalRoot.Length-1),($originalRoot+'-other'),($originalRoot+'\unrelated')){$module=$wrong;Refuses {. $block}}
$module=$originalRoot;$commands=@($stock);. $block;Check ([object]::ReferenceEquals($stock,$command))
[ordered]@{schema=1;state='passed';checks=$checks;edition=$PSVersionTable.PSEdition;version=$PSVersionTable.PSVersion.ToString();actual_stock_cmdlet=$true;actual_local_membership=$true;cache_identity_retained=$true;actual_command_with_explicit_provenance_inputs=$true;proxy_foreign_duplicate_and_sibling_roots_refused=$true;installed_server_changed=$false}|ConvertTo-Json -Compress
