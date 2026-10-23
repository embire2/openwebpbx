# Actual runner source/provenance/path checks; native Windows module facts remain separate.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$checks=0
function Check([bool]$Ok){if(!$Ok){throw ('Catalogue runner stock module control '+($script:checks+1)+' refused.')};$script:checks++}
function Refuse([scriptblock]$Body){$denied=$false;try{&$Body|Out-Null}catch{$denied=$true};Check $denied}
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'packaging/windows/WindowsPhoneCatalogue.ps1'),[ref]$t,[ref]$e);Check (!$e)
foreach($name in 'Assert-OpenWebCatalogueStockOrdinary','Get-OpenWebCatalogueStockProvenance','Assert-OpenWebCatalogueStockProvenance','Import-OpenWebCatalogueDesktopModules'){
 $nodes=@($ast.FindAll({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-ceq $name},$true));Check ($nodes.Count-eq 1);.([scriptblock]::Create($nodes[0].Extent.Text))
}
$good=[ordered]@{command_type=$true;command_name=$true;module_name=$true;module_path=$true;module_base=$true;module_version=$true;module_guid=$true;source_file=$true;implementation=$true}
Assert-OpenWebCatalogueStockProvenance $good;Check $true
foreach($field in @($good.Keys)){
 foreach($value in @($false,$null,1,'true')){$bad=[ordered]@{};foreach($key in $good.Keys){$bad[$key]=$good[$key]};$bad[$field]=$value;Refuse {Assert-OpenWebCatalogueStockProvenance $bad}}
 $bad=[ordered]@{};foreach($key in $good.Keys){if($key-cne $field){$bad[$key]=$good[$key]}};Refuse {Assert-OpenWebCatalogueStockProvenance $bad}
}
$bad=[ordered]@{};foreach($key in $good.Keys){$bad[$key]=$good[$key]};$bad.extra=$true;Refuse {Assert-OpenWebCatalogueStockProvenance $bad};Refuse {Assert-OpenWebCatalogueStockProvenance ([pscustomobject]$good)}
$proxy=[pscustomobject]@{Name='Get-Acl';ModuleName='Microsoft.PowerShell.Security'};$proof=Get-OpenWebCatalogueStockProvenance $proxy 'Get-Acl' 'C:\Windows\System32\WindowsPowerShell\v1.0' 'C:\Windows';Check (!$proof.command_type);Refuse {Assert-OpenWebCatalogueStockProvenance $proof}
$actual=Get-Command Get-Date -CommandType Cmdlet;$proof=Get-OpenWebCatalogueStockProvenance $actual 'Get-Acl' 'C:\Windows\System32\WindowsPowerShell\v1.0' 'C:\Windows';Check ($proof.command_type -and !$proof.command_name -and !$proof.implementation);Refuse {Assert-OpenWebCatalogueStockProvenance $proof}
foreach($name in 'ConvertFrom-Json','Add-Type'){$proof=Get-OpenWebCatalogueStockProvenance $proxy $name 'C:\Windows\System32\WindowsPowerShell\v1.0' 'C:\Windows';Check (!$proof.command_type);Refuse {Assert-OpenWebCatalogueStockProvenance $proof};$proof=Get-OpenWebCatalogueStockProvenance $actual $name 'C:\Windows\System32\WindowsPowerShell\v1.0' 'C:\Windows';Check ($proof.command_type -and !$proof.command_name -and !$proof.implementation);Refuse {Assert-OpenWebCatalogueStockProvenance $proof}}
Refuse {Get-OpenWebCatalogueStockProvenance $actual 'Get-FileHash' 'C:\Windows' 'C:\Windows'}
$work=Join-Path ([IO.Path]::GetTempPath()) ('catalogue-runner-security-'+[Guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($work);$module=$null
try{
 $moduleFile=Join-Path $work 'Microsoft.PowerShell.Security.psm1';[IO.File]::WriteAllText($moduleFile,"function Get-Acl { 'Foreign fixture, never a security primitive' }")
 $module=Import-Module -Name $moduleFile -PassThru -Force;$command=$module.ExportedFunctions['Get-Acl'];Check ($command-is [Management.Automation.FunctionInfo]);$proof=Get-OpenWebCatalogueStockProvenance $command Get-Acl $work $work;Check (!$proof.command_type);Refuse {Assert-OpenWebCatalogueStockProvenance $proof}
 Assert-OpenWebCatalogueStockOrdinary $moduleFile;Assert-OpenWebCatalogueStockOrdinary $work;Check $true
 Refuse {Assert-OpenWebCatalogueStockOrdinary (Join-Path $work 'absent')};Refuse {Assert-OpenWebCatalogueStockOrdinary 'relative'}
 if([Environment]::OSVersion.Platform-ne [PlatformID]::Win32NT){$link=Join-Path $work 'link';$null=New-Item -ItemType SymbolicLink -Path $link -Target $work;Refuse {Assert-OpenWebCatalogueStockOrdinary $link};Refuse {Assert-OpenWebCatalogueStockOrdinary (Join-Path $link 'Microsoft.PowerShell.Security.psm1')}}
}finally{if($module){Remove-Module -ModuleInfo $module -Force};[IO.Directory]::Delete($work,$true)}
if([Environment]::OSVersion.Platform-ne [PlatformID]::Win32NT -or $PSVersionTable.PSEdition-cne 'Desktop'){Refuse {Import-OpenWebCatalogueDesktopModules}}
$calls=@($ast.FindAll({param($n)$n-is [Management.Automation.Language.CommandAst] -and $n.GetCommandName()-ceq 'Import-OpenWebCatalogueDesktopModules'},$true));Check ($calls.Count-eq 1)
$guard=$calls[0].Parent;while($guard -and $guard-isnot [Management.Automation.Language.IfStatementAst]){$guard=$guard.Parent};Check ($guard.Clauses[0].Item1.Extent.Text-ceq "`$PSVersionTable.PSEdition-ceq 'Desktop'")
$common=@($ast.FindAll({param($n)$n-is [Management.Automation.Language.CommandAst] -and $n.Extent.Text-ceq ". (Join-Path `$PSScriptRoot 'WindowsPhoneCatalogue.Common.ps1')"},$true));Check ($common.Count-eq 1 -and $calls[0].Extent.StartOffset-lt $common[0].Extent.StartOffset)
$imports=@($ast.FindAll({param($n)$n-is [Management.Automation.Language.CommandAst] -and $n.GetCommandName()-ceq 'Import-Module'},$true));Check ($imports.Count-eq 1 -and $imports[0].Extent.Text-ceq 'Import-Module -Name $manifest -Global -Force -ErrorAction Stop')
$envWrites=@($ast.FindAll({param($n)$n-is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text-match 'env:PSModulePath'},$true));Check ($envWrites.Count-eq 0)
Write-Output ('PASS '+$checks+' actual runner stock module source/type/path/proxy controls; native bootstrap acceptance separate')
