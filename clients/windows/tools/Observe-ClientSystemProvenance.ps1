# SPDX-License-Identifier: AGPL-3.0-or-later
# This optional diagnostic runs only after an already-failed original client step.
[CmdletBinding()]param([Parameter(Mandatory)][string]$SourceCommit,[Parameter(Mandatory)][string]$PythonExecutable)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or $env:GITHUB_REPOSITORY -cne 'embire2/openwebpbx' -or $SourceCommit -cnotmatch '^[a-f0-9]{40}$' -or $env:GITHUB_RUN_ATTEMPT -cne '1' -or $SourceCommit -cne $env:PHONE_SOURCE_REF -or $env:GITHUB_REF_NAME -cne 'qualification/windows-phone100-core-media-20261026'){throw 'Exact disposable source/run required.'}
$python=[IO.Path]::GetFullPath($PythonExecutable);$item=Get-Item -LiteralPath $python -Force -ErrorAction Stop
if($item -isnot [IO.FileInfo] -or $item.Extension -ine '.exe' -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $python -cne $PythonExecutable){throw 'Exact ordinary selected interpreter required.'}
$tool=Join-Path $PSScriptRoot 'Test-ClientMedia.ps1';$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($tool,[ref]$tokens,[ref]$errors);if($errors.Count){throw 'Existing private-scope helper parse refused.'}
$definitions=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'PrivateDirectory'},$true));if($definitions.Count -ne 1){throw 'One original private-scope helper required.'}
. ([scriptblock]::Create($definitions[0].Extent.Text))
$evidence=Join-Path $env:RUNNER_TEMP 'phone-system-provenance-evidence';PrivateDirectory $evidence
if($env:GITHUB_OUTPUT){[IO.File]::AppendAllText($env:GITHUB_OUTPUT,"evidence_root=$evidence`n",[Text.UTF8Encoding]::new($false))}
& $python -B (Join-Path $PSScriptRoot 'Collect-ClientSystemProvenance.py') --source $SourceCommit --evidence $evidence
if($LASTEXITCODE -ne 0){throw 'Optional post-failure provenance remained unavailable or unverified.'}
