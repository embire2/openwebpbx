# PowerShell binder/order controls; actual full installation is qualified separately.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$path=Join-Path $root 'packaging/windows/Install-OpenWebPBX.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The full installer does not parse.'}
$checks=1
function Check([bool]$Allowed,[string]$Message){if(!$Allowed){throw $Message};$script:checks++}
$statements=@($ast.EndBlock.Statements)
$help=@($statements|Where-Object {$_.Extent.Text.StartsWith('if($Help)')})
$checkOnly=@($statements|Where-Object {$_.Extent.Text -ceq 'if($Check){return}'})
$verify=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.Extent.Text -ceq "& (Join-Path `$PSScriptRoot 'Check-Installation.ps1') -PackageRoot `$PSScriptRoot"},$true))
$runtime=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.Extent.Text -ceq '& "$PSScriptRoot\Ensure-Runtime.ps1"'},$true))
$existing=@($statements|Where-Object {$_.Extent.Text.Contains('if($existingInstallation.Completed)')})
Check ($help.Count -eq 1 -and $checkOnly.Count -eq 1 -and $verify.Count -eq 1 -and $runtime.Count -eq 1 -and $existing.Count -eq 1) 'The full installer must have unique read-only/help/check/completed-state guards.'
Check ($help[0].Extent.EndOffset -lt $verify[0].Extent.StartOffset) 'Help must not load a checker or prepare prerequisites.'
Check ($verify[0].Extent.EndOffset -lt $checkOnly[0].Extent.StartOffset -and $checkOnly[0].Extent.EndOffset -lt $runtime[0].Extent.StartOffset) 'Package checking must finish before runtime installation.'
Check ($existing[0].Extent.EndOffset -lt $runtime[0].Extent.StartOffset) 'Completed existing PBX refusal must precede runtime installation.'
Check (-not ($ast.ScriptRequirements -and $ast.ScriptRequirements.IsElevationRequired)) 'Read-only Help/Check must not demand elevation.'
& $path -Help
Check $? 'The actual help path must finish without a full extracted package.'
foreach($arguments in @(@{Check=$true;AdminEmail='fixture@example.invalid'},@{Check=$true;LocalCertificate=$true})){
 $refused=$false
 try{& $path @arguments}catch{$refused=$_.Exception.Message -clike 'Use -Check on its own*'}
 Check $refused 'Combined check/install options must refuse before prerequisites or package inspection.'
}
foreach($name in 'Check-Installation.ps1','Ensure-Runtime.ps1','Install-Updater.ps1','Upgrade-OpenWebPBX.ps1'){
 $tokens=$null;$errors=$null
 $null=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root ('packaging/windows/'+$name)),[ref]$tokens,[ref]$errors)
 Check ($errors.Count -eq 0) ($name+' must parse without errors.')
}
Write-Host "Windows standalone installer: $checks controls passed."
