# Native component proof. All configuration and interruption fixtures are private;
# the candidate updater is invoked directly, without changing installed services.
param([Parameter(Mandatory)][string]$SourceRoot,[Parameter(Mandatory)][string]$PackageRoot,[Parameter(Mandatory)][string]$ReportPath)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if($PSVersionTable.PSEdition -ne 'Desktop'){throw 'Recovery qualification requires native Windows PowerShell.'}
function Read-UpgradeRecoveryQualificationOutput([object[]]$Output,[bool]$Succeeded,[string]$Kind,[string]$ExpectedVersion) {
 if(!$Succeeded -or $Output.Count -ne 1 -or $Output[0] -isnot [string]){throw 'The actual recovery component did not complete successfully.'}
 if($Kind -ceq 'integration'){
  if($Output[0] -cnotmatch '^PASS ([1-9][0-9]{0,5}) actual upgrade journal, active-runtime preservation, seal/publication/finalization order and conservative unknown-shape controls$'){throw 'The actual recovery integration controls are incomplete.'}
  $count=[int]$Matches[1];if($count -lt 64 -or $count -gt 100000){throw 'The recovery integration matrix is incomplete.'};return $count
 }
 if($Kind -cne 'native' -or $ExpectedVersion -cnotmatch '^\d+\.\d+\.\d+$'){throw 'An exact recovery component and candidate version are required.'}
 if($Output[0] -cnotmatch '^PASS ([1-9][0-9]{0,5}) actual native private recovery bundle/config/ACL/lock/tamper, original choice, complete dependency and before/after handoff interruption controls; actual configured \.NET boot=True; updater version=(\d+\.\d+\.\d+)$'){throw 'The actual native recovery controls are incomplete.'}
 $count=[int]$Matches[1];$version=$Matches[2]
 if($count -lt 202 -or $count -gt 100000 -or $version -cne $ExpectedVersion){throw 'The exact candidate recovery matrix is incomplete.'};return $count
}
$stage='integration';$work=Split-Path $ReportPath
try{
 & (Join-Path $SourceRoot 'tests\windows_upgrade_recovery_qualification.ps1') -SourceRoot $SourceRoot
 if(!$?){throw 'The closed recovery qualification evidence controls did not pass.'}
 & (Join-Path $SourceRoot 'tests\windows_updater_commit_proof.ps1') -SourceRoot $SourceRoot
 if(!$?){throw 'The closed commit-selection evidence controls did not pass.'}
 $integration=& (Join-Path $SourceRoot 'tests\windows_upgrade_recovery_integration.ps1') -SourceRoot $SourceRoot
 $integrationSucceeded=$?
 $integration=@($integration)
 $integration|Set-Content -LiteralPath (Join-Path $work 'upgrade-recovery-integration.private.out') -Encoding UTF8
 $integrationChecks=Read-UpgradeRecoveryQualificationOutput $integration $integrationSucceeded 'integration' ''
 $stage='native';$version=(Get-Content -LiteralPath (Join-Path $PackageRoot 'VERSION') -Raw).Trim()
 if($version -cnotmatch '^\d+\.\d+\.\d+$'){throw 'An exact candidate version is required.'}
 $native=& (Join-Path $SourceRoot 'tests\windows_upgrade_recovery.ps1') -SourceRoot $SourceRoot -UpdaterDirectory (Join-Path $PackageRoot 'updater') -ExpectedUpdaterVersion $version
 $nativeSucceeded=$?
 $native=@($native)
 $native|Set-Content -LiteralPath (Join-Path $work 'upgrade-recovery-native.private.out') -Encoding UTF8
 $nativeChecks=Read-UpgradeRecoveryQualificationOutput $native $nativeSucceeded 'native' $version
 $stage='commit_selection'
 $commitOutput=& (Join-Path $SourceRoot 'tests\windows_updater_commit_selection.ps1') -SourceRoot $SourceRoot
 $commitSucceeded=$?
 $commitOutput=@($commitOutput)
 if(!$commitSucceeded -or $commitOutput.Count -ne 1 -or $commitOutput[0] -isnot [string] -or $commitOutput[0].Length -gt 8192){throw 'The actual native updater commit-selection controls did not finish.'}
 $commitOutput|Set-Content -LiteralPath (Join-Path $work 'updater-commit-selection.private.out') -Encoding UTF8
 $commitRecord=$commitOutput[0]|ConvertFrom-Json
 [ordered]@{schema=1;producer='windows-upgrade-recovery-qualification.ps1';state='passed';actual_native_windows=$true;integration_checks=$integrationChecks;native_checks=$nativeChecks;actual_configured_updater_boot=$true;updater_version=$version;updater_scope='candidate_component';installed_server_changed=$false;native_commit_selection=$commitRecord}|ConvertTo-Json|Set-Content -LiteralPath $ReportPath -Encoding UTF8
}catch{
 [ordered]@{schema=1;producer='windows-upgrade-recovery-qualification.ps1';state='failed';stage=$stage;source_basename='windows-upgrade-recovery-qualification.ps1';source_line=[int]$_.InvocationInfo.ScriptLineNumber}|ConvertTo-Json|Set-Content -LiteralPath $ReportPath -Encoding UTF8
 throw
}
