# Portable actual-AST ordering controls. Metadata/filesystem operations are
# deliberately fictional here; native filesystem coverage is a separate test.
[CmdletBinding()]
param([string]$SourceRoot,[string]$BaselineRoot)
$ErrorActionPreference='Stop';$checks=0
function Check([bool]$Value){if(!$Value){throw 'The recovery ordering control failed.'};$script:checks++}
if(!$SourceRoot){$SourceRoot=Join-Path (Split-Path $PSScriptRoot -Parent) 'packaging/windows'}
if(!$BaselineRoot){throw 'Supply the immutable accepted baseline source directory.'}
function Prefix([string]$Directory){$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Directory 'Upgrade-OpenWebPBX.ps1'),[ref]$tokens,[ref]$errors);Check ($errors.Count -eq 0);$n=@($ast.FindAll({param($x)$x -is [Management.Automation.Language.FunctionDefinitionAst] -and $x.Name -ceq 'RestorePbx'},$true));Check ($n.Count -eq 1);$s=@($n[0].Body.EndBlock.Statements);$end=@(0..($s.Count-1)|Where-Object {$s[$_].Extent.Text.StartsWith('if(Test-Path "$Backup\tools")')});Check ($end.Count -eq 1);return [ScriptBlock]::Create(($s[0..($end[0]-1)]|ForEach-Object {$_.Extent.Text}) -join "`n")}
$new=Prefix $SourceRoot;$old=Prefix $BaselineRoot
$temp=Join-Path ([IO.Path]::GetTempPath()) ('ow-qa-order-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory((Join-Path $temp 'program/tools'))
$root=Join-Path $temp 'program';$private=Join-Path $temp 'state';$Backup=Join-Path $temp 'backup';$switch=Join-Path $temp 'engine';$config=Join-Path $temp 'config'
[IO.File]::WriteAllText((Join-Path $root 'tools/Remove-Updater.ps1'),'$global:UpdaterOrderRemoval++')
function Test-Path([string]$Path){if($Path -ceq "$root\tools\Remove-Updater.ps1"){return $true};return $script:rows.ContainsKey($Path)}
function VerifyBackup([string]$Path){Check ($Path -ceq $Backup)}
function CopyTree{}
function Copy-Item([string]$Path,[string]$Destination,[switch]$Force){Check ($script:rows.ContainsKey($Path));$owner=if($script:rows.ContainsKey($Destination)){$script:rows[$Destination].owner}else{'SYSTEM'};$script:rows[$Destination]=@{text=$script:rows[$Path].text;owner=$owner}}
function Get-Content([string]$Path,[switch]$Raw){Check ($script:rows.ContainsKey($Path));return $script:rows[$Path].text}
function WriteState([string]$Path,$Value){$script:rows[$Path]=@{text=($Value|ConvertTo-Json -Compress);owner='SYSTEM'}}
function Restore-OpenWebSupport{if($script:failSupport){throw 'Fictional support failure.'};if($script:backupExists){$script:rows["$private\updater-install.json"]=@{text=$script:original;owner='ORIGINAL'}}else{$script:rows.Remove("$private\updater-install.json")}}
function sc.exe{Check ($args[0] -ceq 'config' -and $args[1] -ceq 'OpenWebPBXUpdater');$script:scm++}
function RunCase($Code,[bool]$BackupExists,[bool]$CurrentExists,[bool]$Failure=$false){
 $script:backupExists=$BackupExists;$script:failSupport=$Failure;$script:scm=0;$global:UpdaterOrderRemoval=0;$script:original="{`n `"Version`" : `"1.0.13`", `"Executable`" : `"fictional.exe`"`n}";$script:rows=@{}
 foreach($n in 'complete.json','installation.json','runtime.json'){$script:rows["$Backup\$n"]=@{text='{}';owner='BACKUP'}}
 if($BackupExists){$script:rows["$Backup\updater-install.json"]=@{text=$script:original;owner='BACKUP'}}
 if($CurrentExists){$script:rows["$private\updater-install.json"]=@{text='{}';owner='SYSTEM'}}
 $threw=$false;try{. $Code}catch{if(!$Failure){throw};$threw=$true}
 if($Failure){Check ($threw -and $script:scm -eq 0 -and $global:UpdaterOrderRemoval -eq 0);return}
 if($BackupExists){return ($script:rows["$private\updater-install.json"].owner -ceq 'ORIGINAL' -and $script:rows["$private\updater-install.json"].text -ceq $script:original -and $script:scm -eq 1)}
 return (!$script:rows.ContainsKey("$private\updater-install.json") -and $global:UpdaterOrderRemoval -eq [int]$CurrentExists -and $script:scm -eq 0)
}
try{
 Check (!(RunCase $old $true $true));Check (RunCase $new $true $true)
 Check (!(RunCase $old $false $true));Check (RunCase $new $false $true)
 Check (RunCase $new $false $false);RunCase $new $true $true $true
}finally{Remove-Item -LiteralPath $temp -Recurse -Force;Remove-Variable UpdaterOrderRemoval -Scope Global -ErrorAction SilentlyContinue}
[ordered]@{schema=1;state='passed';checks=$checks;old_order_negative=$true;actual_current_restore_statements=$true;native_filesystem_executed=$false;scope='portable_fictional_metadata_ordering'}|ConvertTo-Json -Compress
