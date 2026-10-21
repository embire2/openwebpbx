# Portable source/C# compilation checks only. No server, listener or trust write.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$checks=0
function Assert([bool]$Value){if(!$Value){throw ('Native readiness contract failed at line '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
$path=Join-Path $SourceRoot 'tests/windows_web_readiness_native.ps1';$source=[IO.File]::ReadAllText($path);$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors);Assert (!$errors.Count)
foreach($guard in @('$DisposableHostedRunner',"`$PSVersionTable.PSEdition -eq 'Core'","`$env:GITHUB_ACTIONS -ne 'true'","`$env:RUNNER_ENVIRONMENT -ne 'github-hosted'","`$env:GITHUB_REPOSITORY -ne 'embire2/openwebpbx'",'OSVersion.Version.Build -lt 26100')){Assert ($source.Contains($guard))}
foreach($fact in 'native_windows_readiness_tls_boolean','manifest_helper_hash','scalar_boolean','trusted_tls','actual_iis','cleanup_exact','source_line'){Assert ($source.Contains($fact))}
Assert ($source.Contains("`$manifest.files.'Web-Readiness.ps1'") -and $source.Contains('Get-FileHash -LiteralPath $helper -Algorithm SHA256'))
Assert ($source.Contains('. $helper') -and $source.IndexOf('. $helper') -gt $source.IndexOf("`$phase='helper'"))
Assert ($source.Contains('$actual.Count -eq 1 -and $actual[0] -is [bool]'))
Assert ($source.Contains("Test-OpenWebTrustedLogin 'windowsqa.example.invalid' 8443"))
foreach($case in 'valid','server_error','invalid_status','truncated_length','duplicate_length','ambiguous_framing','wrong_san'){Assert ($source.Contains("Name='$case'"))}
foreach($fence in 'IPAddress.Loopback,0','accept.Wait(5000)','auth.Wait(5000)','thread.Join(15000)','count++<16384','listener.Stop()','finally{$fixture.Dispose()}','$fixture.Finished -and !$fixture.Alive') {Assert ($source.Contains($fence))}
Assert ($source -cnotmatch 'RemoteCertificateValidationCallback|ServerCertificateValidationCallback|SkipCertificateCheck|Import-Certificate|Export-PfxCertificate|New-SelfSignedCertificate|Set-WebConfiguration|CommitChanges')
Assert ($source.Contains('$reportAllowed -and !(Test-Path -LiteralPath $report)'))
Assert ($source.Contains("$([char]36)case.Expected") -and $source.Contains("$([char]36)facts.scalar_boolean=$([char]36)true"))
# Compile the actual bounded server fixture without constructing it.
$match=[regex]::Match($source,"(?s)Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@")
Assert $match.Success
Add-Type -TypeDefinition $match.Groups[1].Value
Assert ($null -ne ('OpenWebReadinessTlsFixture' -as [type]))
Write-Output ('PASS '+$checks+' native readiness source/fence/actual C# compilation controls; no server invoked')
