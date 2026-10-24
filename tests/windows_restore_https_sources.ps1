#Requires -Version 7.4
[CmdletBinding()]param()
# Execute only the actual installer string assignment and public-config writer,
# against fictional values and a private file. No installer/ACME work is run.
$ErrorActionPreference='Stop'
$source=Split-Path $PSScriptRoot -Parent
function Parse([string]$Path){
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
 if(@($errors).Count){throw 'Actual source parsing failed.'};return $ast
}
$installer=Parse (Join-Path $source 'packaging/windows/Install-OpenWebPBX.ps1')
$assignment=@($installer.FindAll({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$config' -and $n.Right.Extent.Text.Contains('openweb.public_url = https://${DomainName}:$HttpsPort')},$true))
if($assignment.Count -ne 1){throw 'The actual installer configuration assignment is not unique.'}
$public=Parse (Join-Path $source 'packaging/windows/PublicAccess.Common.ps1')
$writer=@($public.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Set-OpenWebPublicConfiguration'},$true))
if($writer.Count -ne 1){throw 'The actual public configuration writer is not unique.'}
. ([scriptblock]::Create($writer[0].Extent.Text))
function Installed([int]$HttpsPort){
 $DomainName='pbx.fixture.invalid';$PublicAddress='192.0.2.10';$state=@{DatabasePassword='fictional-database';SwitchPassword='fictional-switch'}
 $sf='C:/Program Files/FreeSWITCH';$rf='C:/OpenWebPBX';$pf='C:/ProgramData/OpenWebPBX'
 . ([scriptblock]::Create($assignment[0].Extent.Text));return $config
}
function Address([string]$Configuration){
 $matchesFound=[regex]::Matches($Configuration,'(?m)^openweb\.public_url = ([^\r\n]+)')
 if($matchesFound.Count -ne 1){throw 'The actual generated URL is not unique.'};return $matchesFound[0].Groups[1].Value
}
$directory=Join-Path ([IO.Path]::GetTempPath()) ('openweb-restore-url-'+[guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Path $directory
try{
 $config443=Installed 443;$config8443=Installed 8443;$path=Join-Path $directory 'config.conf';[IO.File]::WriteAllText($path,$config443)
 $ignored=Set-OpenWebPublicConfiguration $path 'pbx.fixture.invalid' '192.0.2.20'
 @{installer443=(Address $config443);installer8443=(Address $config8443);automatic443=(Address ([IO.File]::ReadAllText($path)))}|ConvertTo-Json -Compress
}finally{Remove-Item -LiteralPath $directory -Recurse -Force}
