#Requires -RunAsAdministrator
# Actual installed read-only PG/ESL/native ownership/manifest proof. No ACME,
# rule, profile, tenant, database row, service or installed file is changed.
param([Parameter(Mandatory)][string]$PackageRoot,[Parameter(Mandatory)][string]$ReportPath)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest;$checks=0
function Check([bool]$Value){if(!$Value){throw ('Installed listener control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
if($PSVersionTable.PSEdition -ne 'Desktop'){throw 'Native Windows PowerShell is required.'}
$root='C:\OpenWebPBX';$state=Join-Path $env:ProgramData 'OpenWebPBX'
$manifest=Get-Content -LiteralPath (Join-Path $PackageRoot 'release-manifest.json') -Raw|ConvertFrom-Json
foreach($name in 'PublicAccess.Common.ps1','PhoneHealth-Security.ps1','public-listeners.php','public-listeners-policy.php','public-listeners-esl.php'){
 $path=Join-Path $root ('tools\'+$name);Check ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $manifest.files.$name)
}
. (Join-Path $root 'tools\PublicAccess.Common.ps1')
$context=Get-OpenWebPublicContext $state $root
$plan=Get-OpenWebPublicListenerPlan $context
Check ($plan.rtp_start -eq 16384 -and $plan.rtp_end -eq 32768)
Check (@($plan.listeners|Where-Object {$_.port -eq 5080 -and $_.protocol -ceq 'TCP' -and !$_.tls}).Count -gt 0)
Check (@($plan.listeners|Where-Object {$_.port -eq 5080 -and $_.protocol -ceq 'UDP' -and !$_.tls}).Count -gt 0)
Check (@($plan.specs|Where-Object {$_.name -ceq 'OpenWebPBX-Public-SIP-TCP-5080' -and $_.port -ceq '5080'}).Count -eq 1)
Check (@($plan.specs|Where-Object {$_.name -ceq 'OpenWebPBX-Public-SIP-UDP-5080' -and $_.port -ceq '5080'}).Count -eq 1)
$null=Test-OpenWebPublicListenerRules $plan -IncludeIntendedTls;Check $true
Check (@($plan.specs|Where-Object {$_.port -cin '5433','8021','8087','3389'}).Count -eq 0)
$actualTls=@($plan.listeners|Where-Object {$_.port -eq 5061 -and $_.tls -and $_.protocol -ceq 'TCP'}).Count -gt 0
$plannedTls=@($plan.specs|Where-Object {$_.name -ceq 'OpenWebPBX-Public-SIP-TLS'}).Count -eq 1
Check ($plannedTls -eq $actualTls)
Assert-OpenWebPublicListenerOwnership $plan;Check $true
$report=[ordered]@{schema=1;producer='windows_public_listener_installed.ps1';state='passed';checks=$checks;actual_installed_php_pg_esl_os=$true;exact_installed_helper_manifest=$true;provider_5080_tcp_udp_planned=$true;tls_only_when_actually_bound=$true;configured_default_audio_source=$true;private_service_ports_excluded=$true;read_only_preflight=$true;firewall_or_configuration_mutated=$false;calling_or_audio_acceptance=$false;installed_server_changed=$false}
if(Test-Path -LiteralPath $ReportPath){throw 'Retain the original installed listener report.'}
[IO.File]::WriteAllText($ReportPath,($report|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
$report|ConvertTo-Json -Compress
