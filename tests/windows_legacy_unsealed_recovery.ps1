[CmdletBinding()]
param([string]$SourceRoot='', [string]$Receipt='')
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
if(!$SourceRoot){$SourceRoot=Split-Path $PSScriptRoot -Parent}
. (Join-Path $SourceRoot 'packaging/windows/CallRecords.Common.ps1')
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'packaging/windows/Upgrade-OpenWebPBX.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The product recovery helper does not parse.'}
$functions=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Test-OpenWebLegacyUnsealedRecovery'},$true))
if($functions.Count -ne 1){throw 'Expected one exact product admission function.'}
. ([scriptblock]::Create($functions[0].Extent.Text))
$checks=0
function Check([bool]$Value,[string]$Message){if(!$Value){throw $Message};$script:checks++}
function Context {
 [pscustomobject]@{
  Journal=[pscustomobject]@{schema=1;state='recovery_required';version='1.0.27';previous_version='1.0.23';operator_rollback=$false;backup_path='C:\ProgramData\OpenWebPBX\backups\20261118-201042-f8162fe4';call_records_hold=[pscustomobject]@{schema=1;owner='upgrade';transaction=('a'*32)}}
  Installed=[pscustomobject]@{Version='1.0.23';Completed=$true}
  HelperSha256='527e17a9349fd5e9f3b1d048fd2f4526495e2cdc5e28f836fe79d8fd17ff1eec'
  BackupRoot='C:\ProgramData\OpenWebPBX\backups';BackupComplete=$false;BackupManifest=$false;DatabaseDump=$false;HoldPresent=$false;OrdinaryRuntime=$true;ClearRestoreGates=$true
 }
}
function Refused($Context,[string]$Message){$denied=$false;try{$denied=!(Test-OpenWebLegacyUnsealedRecovery $Context)}catch{$denied=$true};Check $denied $Message}
Check (Test-OpenWebLegacyUnsealedRecovery (Context)) 'Exact old23 pre-backup retry can resume its already healthy previous version.'
foreach($field in 'BackupComplete','BackupManifest','DatabaseDump','HoldPresent'){$c=Context;$c.$field=$true;Refused $c ('Never ignore existing '+$field)}
foreach($field in 'OrdinaryRuntime','ClearRestoreGates'){$c=Context;$c.$field=$false;Refused $c ('Never bypass '+$field)}
foreach($field in 'BackupComplete','BackupManifest','DatabaseDump','HoldPresent','OrdinaryRuntime','ClearRestoreGates'){$c=Context;$c.$field='false';Refused $c ('Reject string coercion for '+$field)}
foreach($state in 'prepared','quiescing','deploying','migrating','rolling_back','completed','rolled_back'){$c=Context;$c.Journal.state=$state;Refused $c 'This compatibility admission cannot reinterpret another journal phase.'}
foreach($field in 'version','previous_version'){$c=Context;$c.Journal.$field='1.0.28';Refused $c 'Unknown installed/target pairs require their own recovery.'}
$c=Context;$c.Journal.operator_rollback=$true;Refused $c 'Explicit operator restore cannot become a pre-backup retry.'
$c=Context;$c.Journal.operator_rollback='false';Refused $c 'Operator intent cannot be string-coerced.'
$c=Context;$c.Journal|Add-Member recovery_entry $null;Refused $c 'Even a null recovery-entry field is not an unsealed legacy retry.'
$c=Context;$c.Journal|Add-Member recovery_entry ([pscustomobject]@{schema=1});Refused $c 'A published or interrupted sealed recovery never takes this path.'
$c=Context;$c.Installed.Version='1.0.27';Refused $c 'Already deployed new files are not a previous-version retry.'
$c=Context;$c.Installed.Completed=$false;Refused $c 'Incomplete installed state requires its ordinary recovery.'
$c=Context;$c.Installed.Completed='true';Refused $c 'Completed cannot be string-coerced.'
$c=Context;$c.HelperSha256=('b'*64);Refused $c 'Unknown original helper source refuses.'
$c=Context;$c.Journal.schema='1';Refused $c 'Journal schema cannot be string-coerced.'
$c=Context;$c.Journal.schema=2;Refused $c 'Unknown journal schemas refuse.'
foreach($path in 'C:\foreign\20261118-201042-f8162fe4','C:\ProgramData\OpenWebPBX\backups\nested\20261118-201042-f8162fe4','C:\ProgramData\OpenWebPBX\backups\unknown','C:\ProgramData\OpenWebPBX\backups\20261118-201042-f8162fe4\extra'){$c=Context;$c.Journal.backup_path=$path;Refused $c 'Partial backup must be one exact ordinary child leaf.'}
$c=Context;$c.Journal.call_records_hold.owner='restore';Refused $c 'Another restore owner cannot be released.'
$c=Context;$c.Journal.call_records_hold.transaction='invalid';Refused $c 'Malformed transaction identity refuses.'
Check (@($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Test-OpenWebLegacyUnsealedRecovery'},$true)).Count -eq 1) 'The admission is wired once into the product recovery path.'
$result=@{passed=$true;checks=$checks;actual_ps_version=$PSVersionTable.PSVersion.ToString();product_admission_executed=$true;existing_authority_or_data_written=$false;source_upgrade_sha256=(Get-FileHash -LiteralPath (Join-Path $SourceRoot 'packaging/windows/Upgrade-OpenWebPBX.ps1') -Algorithm SHA256).Hash.ToLowerInvariant()}
if($Receipt){[IO.File]::WriteAllText($Receipt,($result|ConvertTo-Json -Depth 5))}
Write-Host ('Windows legacy unsealed recovery: '+$checks+' controls passed.')
