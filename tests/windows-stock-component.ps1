# Diagnostic component only: no PBX, service, database, archive or media operation.
[CmdletBinding()]
param([string]$Hostname,[int]$Port,[string]$ReportPath,[switch]$DisposableHostedRunner,[switch]$ReadReport)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
function Need([bool]$Value){if(!$Value){throw 'The isolated stock component guard refused.'}}
Need ($env:GITHUB_ACTIONS -ceq 'true' -and $env:RUNNER_ENVIRONMENT -ceq 'github-hosted' -and $env:RUNNER_OS -ceq 'Windows' -and $env:GITHUB_REPOSITORY -ceq 'embire2/openwebpbx' -and $env:GITHUB_EVENT_NAME -ceq 'workflow_dispatch' -and $env:OPENWEB_STOCK_COMPONENT -ceq '1')
$report=[IO.Path]::GetFullPath($ReportPath);$root=[IO.Path]::GetFullPath(([IO.Path]::Combine($env:RUNNER_TEMP,'openwebpbx-stock-component')))
Need ($report.StartsWith($root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -and $report.Substring($root.TrimEnd('\').Length+1) -cmatch '^[a-f0-9]{24}\\(direct|owned)\.safe\.clixml$')
if($ReadReport){
 Need ($PSVersionTable.PSEdition -ceq 'Core' -and $PSVersionTable.PSVersion.Major -eq 7)
 $file=[IO.FileInfo]::new($report);Need ($file.Exists -and $file.Length -gt 0 -and $file.Length -le 131072 -and !($file.Attributes -band [IO.FileAttributes]::ReparsePoint))
 $text=[IO.File]::ReadAllText($report);Need (!$text.Contains('<!'))
 [Management.Automation.PSSerializer]::Deserialize($text)|ConvertTo-Json -Depth 14 -Compress
 exit 0
}
Need ($PSVersionTable.PSEdition -ceq 'Desktop' -and $PSVersionTable.PSVersion.Major -eq 5 -and ![IO.File]::Exists($report))
$source=[IO.Path]::Combine($PSScriptRoot,'windows-meet-wss-path.ps1');$bytes=[IO.File]::ReadAllBytes($source)
$hash=[Security.Cryptography.SHA256]::Create();try{$digest=([BitConverter]::ToString($hash.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()}finally{$hash.Dispose()}
Need ($digest -ceq '1af196ada3620ff909ed2d6d5759f688b351615ace70dffc4cf132688b323062')
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors);Need ($errors.Count -eq 0)
$names=@('Assert-MeetWssPathRunner','Assert-MeetWssPathTarget','Assert-MeetWssPathStockOrdinary','Get-MeetWssPathStockProvenance','Assert-MeetWssPathStockProvenance','Import-MeetWssPathDesktopModules')
foreach($name in $names){$nodes=@($ast.FindAll({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));Need ($nodes.Count -eq 1);. ([scriptblock]::Create($nodes[0].Extent.Text))}
# Execute the exact original target/native/runner admission before its bootstrap.
$try=@($ast.EndBlock.Statements|Where-Object {$_-is [Management.Automation.Language.TryStatementAst]});Need ($try.Count -eq 1)
$admission=@();foreach($statement in $try[0].Body.Statements){if($statement.Extent.Text -ceq 'Import-MeetWssPathDesktopModules'){break};$admission+=@($statement.Extent.Text)}
Need ($admission.Count -eq 6);. ([scriptblock]::Create(($admission -join "`n")))
$script:proofFields=@('command_type','command_name','module_name','module_path','module_base','module_version','module_guid','source_file','implementation')
$script:trace=[Collections.Generic.List[object]]::new();$script:continuation=$null;$script:observerErrors=0
function ClosedError($Record){$type=$Record.Exception.GetType().Name;if($type -cnotin @('RuntimeException','CommandNotFoundException','FileNotFoundException','IOException','UnauthorizedAccessException','PSInvalidOperationException','InvalidOperationException','CmdletInvocationException','TypeLoadException')){$type='other'};return @{error_type=$type;hresult=[int]$Record.Exception.HResult}}
function StockPath($Value,[string]$NativeHome,[string]$Windows){
 if($Value -isnot [string] -or !$Value.Length){return @{kind='unavailable';value=$null}}
 try{
  $full=[IO.Path]::GetFullPath($Value);if($full.Length -gt 320 -or $full -match '[\x00-\x1f\x7f]'){throw 'Path bound.'}
  if(!$full.StartsWith($Windows.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){return @{kind='outside_windows_redacted';value=$null}}
  $stock=$full -ieq $NativeHome -or $full.StartsWith($NativeHome.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($Windows.TrimEnd('\')+'\Microsoft.NET\assembly\GAC_',[StringComparison]::OrdinalIgnoreCase)
  if(!$stock){return @{kind='windows_other_redacted';value=$null}}
  Assert-MeetWssPathStockOrdinary $full;return @{kind='windows_stock';value=$full}
 }catch{return @{kind='unavailable';value=$null}}
}
function PublicMetadata($Command,[string]$NativeHome,[string]$Windows){
 $row=@{command_kind='other';module_kind='other';module_version=$null;module_guid=$null;implementation_type=$null;assembly_name=$null;assembly_version=$null;public_key_token=$null;module_path=@{kind='unavailable';value=$null};module_base=@{kind='unavailable';value=$null};assembly_location=@{kind='unavailable';value=$null}}
 if($Command -isnot [Management.Automation.CmdletInfo]){if($Command -is [Management.Automation.FunctionInfo]){$row.command_kind='function'}elseif($Command -is [Management.Automation.AliasInfo]){$row.command_kind='alias'};return $row}
 $row.command_kind='cmdlet';$module=$Command.Module;$type=$Command.ImplementingType;$assembly=$type.Assembly;$info=$assembly.GetName();$token=([BitConverter]::ToString($info.GetPublicKeyToken())).Replace('-','').ToLowerInvariant()
 $public=$null-ne $module -and $module.Name -cin @('Microsoft.PowerShell.Security','Microsoft.PowerShell.Utility') -and $info.Name -cin @('Microsoft.PowerShell.Security','Microsoft.PowerShell.Commands.Utility') -and $token -ceq '31bf3856ad364e35' -and $type.FullName -cmatch '^Microsoft\.PowerShell\.Commands\.[A-Za-z0-9_]{1,100}$'
 if(!$public){return $row}
 $row.module_kind=if($module.Name -ceq 'Microsoft.PowerShell.Security'){'Security'}else{'Utility'}
 foreach($name in 'module_version','assembly_version'){$version=if($name -ceq 'module_version'){[string]$module.Version}else{[string]$info.Version};if($version -cmatch '^\d{1,5}(\.\d{1,5}){1,3}$'){$row[$name]=$version}}
 $row.module_guid=$module.Guid.ToString('D');$row.implementation_type=$type.FullName;$row.assembly_name=$info.Name;$row.public_key_token=$token
 $row.module_path=StockPath $module.Path $NativeHome $Windows;$row.module_base=StockPath $module.ModuleBase $NativeHome $Windows;$row.assembly_location=StockPath $assembly.Location $NativeHome $Windows
 return $row
}
# Forward the exact getter without changing its object, predicate or exception.
$script:exactGetter=(Get-Command Get-MeetWssPathStockProvenance -CommandType Function).ScriptBlock
function Get-MeetWssPathStockProvenance($Command,[ValidateSet('Get-Acl','ConvertTo-Json','Add-Type')][string]$Name,[string]$NativeHome,[string]$WindowsRoot){
 $proof=& $script:exactGetter $Command $Name $NativeHome $WindowsRoot
 try{
  Need ($proof -is [Collections.IDictionary] -and $proof.Count -eq 9);$copy=@{};foreach($field in $script:proofFields){Need ($proof[$field] -is [bool]);$copy[$field]=$proof[$field]}
  $check=if($script:continuation){$script:continuation}elseif($MyInvocation.Line.Contains('$visible $name $nativeHome $windows')){'visible'}elseif($MyInvocation.Line.Contains('$command $name $nativeHome $windows')){'qualified'}else{'unknown'}
  $all=$true;foreach($field in $script:proofFields){if(!$copy[$field]){$all=$false}}
  $script:trace.Add(@{scope=$(if($script:continuation){'continuation'}else{'original_bootstrap'});command=$Name;check=$check;proof=$copy;all_original_fields_true=$all;metadata=(PublicMetadata $Command $NativeHome $WindowsRoot)})
 }catch{$script:observerErrors++}
 return $proof
}
$bootstrap=@{state='passed';error=$null}
try{Import-MeetWssPathDesktopModules}catch{$bootstrap.state='failed';$bootstrap.error=ClosedError $_}
# Continue only for diagnosis; never bypass an original qualification assertion.
$imports=@();$home=[IO.Path]::Combine([Environment]::SystemDirectory,'WindowsPowerShell','v1.0');$windows=[Environment]::GetFolderPath('Windows')
foreach($kind in 'Security','Utility'){
 $module='Microsoft.PowerShell.'+$kind;$manifest=[IO.Path]::Combine($home,'Modules',$module,$module+'.psd1');$import=@{module=$kind;state='passed';error=$null}
 try{Assert-MeetWssPathStockOrdinary $manifest;Import-Module -Name $manifest -Global -Force -ErrorAction Stop}catch{$import.state='failed';$import.error=ClosedError $_};$imports+=@($import)
 $required=if($kind -ceq 'Security'){@('Get-Acl')}else{@('ConvertTo-Json','Add-Type')}
 foreach($name in $required){foreach($check in 'qualified','visible'){
  $script:continuation=$check
  try{$lookup=if($check -ceq 'qualified'){$module+'\'+$name}else{$name};$commands=@(Get-Command -Name $lookup -All -ErrorAction Stop);Need ($commands.Count -eq 1);$null=Get-MeetWssPathStockProvenance $commands[0] $name $home $windows}catch{$script:trace.Add(@{scope='continuation';command=$name;check=$check;proof=$null;all_original_fields_true=$false;metadata=$null;lookup_error=(ClosedError $_)})}
 }}
}
$reportData=@{schema=1;state='observed';producer='windows-stock-component.ps1';bootstrap=$bootstrap;imports=$imports;commands=@($script:trace.ToArray());observer_errors=$script:observerErrors;original_helpers_source_sha256=$digest;diagnostic_only=$true;wss_eligible=$false;media_eligible=$false;restore_eligible=$false;release_eligible=$false;owner_eligible=$false}
$xml=[Management.Automation.PSSerializer]::Serialize($reportData,12);Need ([Text.Encoding]::UTF8.GetByteCount($xml) -le 131072);[IO.File]::WriteAllText($report,$xml,[Text.UTF8Encoding]::new($false))
