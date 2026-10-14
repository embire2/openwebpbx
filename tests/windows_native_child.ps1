# SPDX-License-Identifier: AGPL-3.0-or-later
# Execute the exact fixture launcher against an independent real Python child.
param([string]$Python='python3')
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'windows-native-acceptance.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Native hook did not parse.'}
$definition=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'StartFixturePkiServer'},$true)
if(!$definition){throw 'Exact native fixture launcher missing.'}
Invoke-Expression $definition.Extent.Text
$directory=Join-Path ([IO.Path]::GetTempPath()) ('native child '+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $directory|Out-Null
$python=(Get-Command $Python -CommandType Application).Source
$script=Join-Path $directory 'independent argument observer.py'
$privateInput='C:\ProgramData\OpenWebPBX\native qualification\fictional\input.json'
$process=$null
try{
 [IO.File]::WriteAllText($script,'import json,sys; print(json.dumps(sys.argv[1:]))',[Text.UTF8Encoding]::new($false))
 $process=StartFixturePkiServer
 if(!$process.WaitForExit(15000)){throw 'Real native fixture child did not complete.'}
 if($process.ExitCode){throw 'Real native fixture child failed.'}
 $arguments=$pkiOutput.GetAwaiter().GetResult()|ConvertFrom-Json
 if($arguments.Count -ne 4 -or $arguments[0] -ne '--input' -or $arguments[1] -cne $privateInput -or $arguments[2] -ne '--phase' -or $arguments[3] -ne 'pki-server'){throw 'Native fixture argument boundaries were changed.'}
 if($pkiErrors.GetAwaiter().GetResult()){throw 'Native fixture child produced an unexpected error.'}
 Write-Host 'PASS real native child launcher: spaced script/input paths remain single arguments; no Windows PBX qualification implied.'
}finally{
 if($process){if(!$process.HasExited){$process.Kill($true)};$process.Dispose()}
 Remove-Item -LiteralPath $directory -Recurse -Force
}
