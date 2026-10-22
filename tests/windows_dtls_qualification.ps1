# Mandatory native DTLS precondition for current complete Windows candidates.
param([Parameter(Mandatory)][string]$SourceRoot,[Parameter(Mandatory)][string]$PackageRoot,[Parameter(Mandatory)][string]$ReportPath)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$stage='transactions';$work=Split-Path $ReportPath
try{
 $nativeReport=Join-Path $work 'dtls-transactions.json'
 & (Join-Path $SourceRoot 'tests\windows_dtls_native.ps1') -SourceRoot $SourceRoot -ReportPath $nativeReport *> (Join-Path $work 'dtls-transactions.private.log')
 if(!$?){throw 'Native DTLS transaction controls failed.'}
 $native=Get-Content -LiteralPath $nativeReport -Raw|ConvertFrom-Json
 foreach($field in 'actual_native_windows','actual_openssl','native_ntfs_transactions','service_adapter_double'){if($native.$field -isnot [bool] -or !$native.$field){throw 'Native DTLS transaction evidence is incomplete.'}}
 if($native.schema -ne 1 -or $native.state -cne 'passed' -or $native.producer -cne 'windows_dtls_native.ps1' -or $native.calling_engine_started -isnot [bool] -or $native.calling_engine_started -or $native.firewall_or_trust_modified -isnot [bool] -or $native.firewall_or_trust_modified -or $native.checks -lt 52 -or $native.crypto_checks -lt 12){throw 'Native DTLS transaction evidence is invalid.'}
 $stage='installed';$installedReport=Join-Path $work 'dtls-installed.json'
 & (Join-Path $SourceRoot 'tests\windows_dtls_installed.ps1') -PackageRoot $PackageRoot -ReportPath $installedReport *> (Join-Path $work 'dtls-installed.private.log')
 if(!$?){throw 'Installed DTLS identity controls failed.'}
 $installed=Get-Content -LiteralPath $installedReport -Raw|ConvertFrom-Json
 foreach($field in 'actual_native_windows','installed_certificate_valid','installed_private_acl','owned_transaction_verified','installed_engine_untouched'){if($installed.$field -isnot [bool] -or !$installed.$field){throw 'The actual installed private DTLS identity is unqualified.'}}
 if($installed.schema -ne 1 -or $installed.state -cne 'passed' -or $installed.producer -cne 'windows_dtls_installed.ps1' -or $installed.checks -lt 12){throw 'Installed DTLS evidence is incomplete.'}
 [ordered]@{schema=1;producer='windows_dtls_qualification.ps1';state='passed';actual_native_windows=$true;private_certificate_valid=$true;installed_engine_untouched=$true;native_ntfs_transactions=$true;transaction_service_adapter_double=$true;transaction_checks=[int]$native.checks;crypto_checks=[int]$native.crypto_checks;installed_checks=[int]$installed.checks}|ConvertTo-Json|Set-Content -LiteralPath $ReportPath -Encoding UTF8
}catch{
 [ordered]@{schema=1;producer='windows_dtls_qualification.ps1';state='failed';stage=$stage;source_basename='windows_dtls_qualification.ps1';source_line=[int]$_.InvocationInfo.ScriptLineNumber}|ConvertTo-Json|Set-Content -LiteralPath $ReportPath -Encoding UTF8
 throw
}
