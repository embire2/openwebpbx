# Actual source functions/types/filesystem; Windows module facts are explicit adapters.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$checks=0
function Check([bool]$Ok){if(!$Ok){throw ('Catalogue stock control '+($script:checks+1)+' refused.')};$script:checks++}
function Refuse([scriptblock]$Body){$denied=$false;try{&$Body|Out-Null}catch{$denied=$true};Check $denied}
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows_phone_catalogue_native.ps1'),[ref]$t,[ref]$e);Check (!$e)
foreach($name in 'Assert-CatalogueStockOrdinary','Get-CatalogueStockProvenance','Assert-CatalogueStockProvenance','Import-CatalogueDesktopStockModules'){
 $definitions=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));Check ($definitions.Count -eq 1);.([scriptblock]::Create($definitions[0].Extent.Text))
}
$good=[ordered]@{command_type=$true;command_name=$true;module_name=$true;module_path=$true;module_base=$true;module_version=$true;module_guid=$true;source_file=$true;implementation=$true}
Assert-CatalogueStockProvenance $good;Check $true
foreach($key in @($good.Keys)){
 foreach($value in @($false,$null,1,'true')){$copy=[ordered]@{};foreach($k in $good.Keys){$copy[$k]=$good[$k]};$copy[$key]=$value;Refuse {Assert-CatalogueStockProvenance $copy}}
 $copy=[ordered]@{};foreach($k in $good.Keys){if($k -cne $key){$copy[$k]=$good[$k]}};Refuse {Assert-CatalogueStockProvenance $copy}
}
$copy=[ordered]@{};foreach($k in $good.Keys){$copy[$k]=$good[$k]};$copy.extra=$true;Refuse {Assert-CatalogueStockProvenance $copy}
Refuse {Assert-CatalogueStockProvenance ([pscustomobject]$good)}
# Untyped proxy objects cannot manufacture the native command type.
foreach($kind in 'Utility','Security'){$proof=Get-CatalogueStockProvenance ([pscustomobject]@{Name='Get-Acl';ModuleName='Microsoft.PowerShell.Security'}) $kind 'C:\Windows\System32\WindowsPowerShell\v1.0' 'C:\Windows';Check (!$proof.command_type);Refuse {Assert-CatalogueStockProvenance $proof}}
$work=Join-Path ([IO.Path]::GetTempPath()) ('catalogue-stock-'+[Guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($work)
$module=$null;$actualDate=Get-Command Get-Date -CommandType Cmdlet
try{
 $folder=Join-Path $work 'Modules/Microsoft.PowerShell.Utility';$null=[IO.Directory]::CreateDirectory($folder);$file=Join-Path $folder 'Microsoft.PowerShell.Utility.psm1'
 [IO.File]::WriteAllText($file,"function Get-FileHash { 'Fixture, never a hash primitive' }",[Text.UTF8Encoding]::new($false))
 # A real FunctionInfo from a wrong module base is refused despite matching file names.
 $module=Import-Module -Name $file -PassThru -Force;$command=$module.ExportedFunctions['Get-FileHash']
 $proof=Get-CatalogueStockProvenance $command Utility $work $work
 Check ($command -is [Management.Automation.FunctionInfo]);Check ($proof.command_type -and $proof.command_name -and $proof.module_name -and $proof.module_path -and $proof.source_file -and $proof.implementation);Check (!$proof.module_base);Refuse {Assert-CatalogueStockProvenance $proof}
 $wrong=Get-CatalogueStockProvenance $command Utility (Join-Path $work 'sibling') $work;Check (!$wrong.module_path -and !$wrong.source_file -and !$wrong.implementation)
 $wrong=Get-CatalogueStockProvenance $actualDate Utility $work $work;Check (!$wrong.command_type)
 $wrong=Get-CatalogueStockProvenance $actualDate Security $work $work;Check ($wrong.command_type -and !$wrong.command_name -and !$wrong.implementation);Refuse {Assert-CatalogueStockProvenance $wrong}
 # Exercise the real manifest-export FunctionInfo as well as its nested form.
 Remove-Module -ModuleInfo $module -Force;$module=$null
 $manifest=Join-Path $folder 'Microsoft.PowerShell.Utility.psd1'
 foreach($case in 'good','version','guid'){
  $version=if($case -ceq 'version'){'3.2.0.0'}else{'3.1.0.0'};$guid=if($case -ceq 'guid'){'11111111-1111-1111-1111-111111111111'}else{'1da87e53-152b-403e-98dc-74d7b4d63d59'}
  [IO.File]::WriteAllText($manifest,("@{ModuleVersion='"+$version+"';GUID='"+$guid+"';NestedModules=@('Microsoft.PowerShell.Utility.psm1');FunctionsToExport=@('Get-FileHash')}"))
  $module=Import-Module -Name $manifest -PassThru -Force;$visible=Get-Command Get-FileHash
  $proof=Get-CatalogueStockProvenance $visible Utility $work $work
  Check ($proof.command_type -and $proof.module_path -and $proof.source_file -and $proof.implementation)
  Check ($proof.module_version -eq ($case -cne 'version'));Check ($proof.module_guid -eq ($case -cne 'guid'))
  # The actual fixture module base remains outside the stock home, always refused.
  Check (!$proof.module_base);Refuse {Assert-CatalogueStockProvenance $proof}
  Remove-Module -ModuleInfo $module -Force;$module=$null
 }
 Assert-CatalogueStockOrdinary $file;Assert-CatalogueStockOrdinary $folder;Check $true
 Refuse {Assert-CatalogueStockOrdinary (Join-Path $work 'missing')}
 if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){
  $link=Join-Path $work 'linked';$null=New-Item -ItemType SymbolicLink -Path $link -Target $folder;Refuse {Assert-CatalogueStockOrdinary $link};Refuse {Assert-CatalogueStockOrdinary (Join-Path $link 'Microsoft.PowerShell.Utility.psm1')}
  Refuse {Import-CatalogueDesktopStockModules}
 }
}finally{if($module){Remove-Module -ModuleInfo $module -Force};[IO.Directory]::Delete($work,$true)}
# Require the bootstrap before the exact first manifest hash and only for Desktop.
$calls=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Import-CatalogueDesktopStockModules'},$true));Check ($calls.Count -eq 1)
$guard=$calls[0].Parent;while($guard -and $guard -isnot [Management.Automation.Language.IfStatementAst]){$guard=$guard.Parent};Check ($guard.Clauses[0].Item1.Extent.Text -ceq "`$PSVersionTable.PSEdition -ceq 'Desktop'")
$hashes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Get-FileHash'},$true));Check ($calls[0].Extent.StartOffset -lt $hashes[0].Extent.StartOffset)
$imports=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Import-Module'},$true));Check ($imports.Count -eq 1 -and $imports[0].Extent.Text -ceq 'Import-Module -Name $manifest -Global -Force -ErrorAction Stop')
$assignments=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -match 'env:PSModulePath'},$true));Check ($assignments.Count -eq 0)
Write-Output ('PASS '+$checks+' actual stock bootstrap type/path/source controls; native Windows module primitives remain separate')
