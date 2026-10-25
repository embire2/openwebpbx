# Reuse reviewed Windows phone stock-module bootstrap controls; no installed service/network.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest;$checks=0
function Check([bool]$Ok){if(!$Ok){throw ('WSS stock module control '+($script:checks+1)+' refused.')};$script:checks++}
function Refuse([scriptblock]$Body){$denied=$false;try{&$Body|Out-Null}catch{$denied=$true};Check $denied}
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-meet-wss-path.ps1'),[ref]$t,[ref]$e);Check (!$e)
foreach($name in 'Assert-MeetWssPathStockOrdinary','Get-MeetWssPathStockProvenance','Assert-MeetWssPathStockProvenance','Import-MeetWssPathDesktopModules'){
 $nodes=@($ast.FindAll({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-ceq $name},$true));Check ($nodes.Count-eq 1);.([scriptblock]::Create($nodes[0].Extent.Text))
}
$good=[ordered]@{command_type=$true;command_name=$true;module_name=$true;module_path=$true;module_base=$true;module_version=$true;module_guid=$true;source_file=$true;implementation=$true}
Assert-MeetWssPathStockProvenance $good;Check $true
foreach($field in @($good.Keys)){
 foreach($value in @($false,$null,1,'true')){$bad=[ordered]@{};foreach($key in $good.Keys){$bad[$key]=$good[$key]};$bad[$field]=$value;Refuse {Assert-MeetWssPathStockProvenance $bad}}
 $bad=[ordered]@{};foreach($key in $good.Keys){if($key-cne $field){$bad[$key]=$good[$key]}};Refuse {Assert-MeetWssPathStockProvenance $bad}
}
$bad=[ordered]@{};foreach($key in $good.Keys){$bad[$key]=$good[$key]};$bad.extra=$true;Refuse {Assert-MeetWssPathStockProvenance $bad};Refuse {Assert-MeetWssPathStockProvenance ([pscustomobject]$good)}
$proxy=[pscustomobject]@{Name='Get-Acl';ModuleName='Microsoft.PowerShell.Security'};$proof=Get-MeetWssPathStockProvenance $proxy 'Get-Acl' 'C:\Windows\System32\WindowsPowerShell\v1.0' 'C:\Windows';Check (!$proof.command_type);Refuse {Assert-MeetWssPathStockProvenance $proof}
$actual=Get-Command Get-Date -CommandType Cmdlet;$proof=Get-MeetWssPathStockProvenance $actual 'Get-Acl' 'C:\Windows\System32\WindowsPowerShell\v1.0' 'C:\Windows';Check ($proof.command_type -and !$proof.command_name -and !$proof.implementation);Refuse {Assert-MeetWssPathStockProvenance $proof}
foreach($name in 'ConvertTo-Json','Add-Type'){$proof=Get-MeetWssPathStockProvenance $proxy $name 'C:\Windows\System32\WindowsPowerShell\v1.0' 'C:\Windows';Check (!$proof.command_type);Refuse {Assert-MeetWssPathStockProvenance $proof};$proof=Get-MeetWssPathStockProvenance $actual $name 'C:\Windows\System32\WindowsPowerShell\v1.0' 'C:\Windows';Check ($proof.command_type -and !$proof.command_name -and !$proof.implementation);Refuse {Assert-MeetWssPathStockProvenance $proof}}
Refuse {Get-MeetWssPathStockProvenance $actual 'Get-FileHash' 'C:\Windows' 'C:\Windows'}
$work=Join-Path ([IO.Path]::GetTempPath()) ('catalogue-runner-security-'+[Guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($work);$module=$null
try{
 $moduleFile=Join-Path $work 'Microsoft.PowerShell.Security.psm1';[IO.File]::WriteAllText($moduleFile,"function Get-Acl { 'Foreign fixture, never a security primitive' }")
 $module=Import-Module -Name $moduleFile -PassThru -Force;$command=$module.ExportedFunctions['Get-Acl'];Check ($command-is [Management.Automation.FunctionInfo]);$proof=Get-MeetWssPathStockProvenance $command Get-Acl $work $work;Check (!$proof.command_type);Refuse {Assert-MeetWssPathStockProvenance $proof}
 Assert-MeetWssPathStockOrdinary $moduleFile;Assert-MeetWssPathStockOrdinary $work;Check $true
 Refuse {Assert-MeetWssPathStockOrdinary (Join-Path $work 'absent')};Refuse {Assert-MeetWssPathStockOrdinary 'relative'}
 if([Environment]::OSVersion.Platform-ne [PlatformID]::Win32NT){$link=Join-Path $work 'link';$null=New-Item -ItemType SymbolicLink -Path $link -Target $work;Refuse {Assert-MeetWssPathStockOrdinary $link};Refuse {Assert-MeetWssPathStockOrdinary (Join-Path $link 'Microsoft.PowerShell.Security.psm1')}}
}finally{if($module){Remove-Module -ModuleInfo $module -Force};[IO.Directory]::Delete($work,$true)}
if([Environment]::OSVersion.Platform-ne [PlatformID]::Win32NT -or $PSVersionTable.PSEdition-cne 'Desktop'){Refuse {Import-MeetWssPathDesktopModules}}
$calls=@($ast.FindAll({param($n)$n-is [Management.Automation.Language.CommandAst] -and $n.GetCommandName()-ceq 'Import-MeetWssPathDesktopModules'},$true));Check ($calls.Count-eq 1)
$target=@($ast.FindAll({param($n)$n-is [Management.Automation.Language.CommandAst] -and $n.GetCommandName()-ceq 'Assert-MeetWssPathTarget'},$true));$runner=@($ast.FindAll({param($n)$n-is [Management.Automation.Language.CommandAst] -and $n.GetCommandName()-ceq 'Assert-MeetWssPathRunner'},$true));$private=@($ast.FindAll({param($n)$n-is [Management.Automation.Language.CommandAst] -and $n.GetCommandName()-ceq 'Assert-MeetWssPathPrivate'},$true))
Check ($target.Count-eq 1 -and $runner.Count-eq 1 -and $private.Count-eq 1 -and $target[0].Extent.StartOffset-lt $calls[0].Extent.StartOffset -and $runner[0].Extent.StartOffset-lt $calls[0].Extent.StartOffset -and $calls[0].Extent.StartOffset-lt $private[0].Extent.StartOffset)
$imports=@($ast.FindAll({param($n)$n-is [Management.Automation.Language.CommandAst] -and $n.GetCommandName()-ceq 'Import-Module' -and $n.Extent.Text-ceq 'Import-Module -Name $manifest -Global -Force -ErrorAction Stop'},$true));Check ($imports.Count-eq 1)
$bootstrap=@($ast.FindAll({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-ceq 'Import-MeetWssPathDesktopModules'},$true))[0].Extent.Text
Check ($bootstrap.Contains("[IO.Path]::GetFullPath(`$PSHOME) -ine `$nativeHome"))
foreach($name in 'Add-Type','ConvertTo-Json'){$uses=@($ast.FindAll({param($n)$n-is [Management.Automation.Language.CommandAst] -and $n.GetCommandName()-ceq $name},$true));Check ($uses.Count-ge 1)}
$envWrites=@($ast.FindAll({param($n)$n-is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text-match 'env:PSModulePath'},$true));Check ($envWrites.Count-eq 0)
Write-Output ('PASS '+$checks+' exact reviewed stock bootstrap provenance/path/proxy controls; native module acceptance separate')
