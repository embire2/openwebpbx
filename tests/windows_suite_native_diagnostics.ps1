param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$checks=0;$tokens=$null;$errors=$null
$path=Join-Path $SourceRoot 'tests/windows-suite.ps1';$text=[IO.File]::ReadAllText($path)
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
function Check([bool]$Value){if(!$Value){throw ('Native diagnostic guard/routing control failed at '+(@(Get-PSCallStack)[1].ScriptLineNumber))};$script:checks++}
Check ($errors.Count -eq 0)
$guards=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'AssertNativeDiagnosticsMode'},$true));Check ($guards.Count -eq 1)
. ([scriptblock]::Create($guards[0].Extent.Text))
$sha='a'*40;$ref='embire2/openwebpbx/.github/workflows/windows-suite.yml@refs/heads/customization'
AssertNativeDiagnosticsMode $true $false $false $false '' $ref $sha $sha;Check $true
AssertNativeDiagnosticsMode $false $true $true $true 'other-package' '' '' '';Check $true
foreach($case in @(
 @($true,$true,$false,$false,'',$ref,$sha,$sha),@($true,$false,$true,$false,'',$ref,$sha,$sha),
 @($true,$false,$false,$true,'',$ref,$sha,$sha),@($true,$false,$false,$false,'other-package',$ref,$sha,$sha),
 @($true,$false,$false,$false,'','embire2/openwebpbx/.github/workflows/windows-upgrade-diagnostics.yml@refs/heads/customization',$sha,$sha),
 @($true,$false,$false,$false,'','foreign/openwebpbx/.github/workflows/windows-suite.yml@refs/heads/customization',$sha,$sha),
 @($true,$false,$false,$false,'',$ref,('b'*40),$sha),@($true,$false,$false,$false,'',$ref,'',''),
 @($true,$false,$false,$false,'',$ref,$sha.ToUpperInvariant(),$sha.ToUpperInvariant())
)){$refused=$false;try{AssertNativeDiagnosticsMode @case}catch{$refused=$true};Check $refused}
$routingMatches=@([regex]::Matches($text,'(?ms)# BEGIN qualification-gate-routing\r?\n(.*?)\r?\n # END qualification-gate-routing'));Check ($routingMatches.Count -eq 1);$routing=$routingMatches[0].Groups[1].Value
$metadata=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith('if($UpgradeDiagnosticsOnly){$facts.mode=')},$true));Check ($metadata.Count -eq 1)
$work=Join-Path ([IO.Path]::GetTempPath()) ('openweb-native-routing-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory((Join-Path $work 'backup-qualification'))
$backupStub=Join-Path $work 'backups.ps1';[IO.File]::WriteAllText($backupStub,"param(`$PackageRoot,`$AdminEmail,`$AdminPassword,[switch]`$DisposableFactory,`$SftpConfig)`n`$trace.Add('backups')")
[IO.File]::WriteAllText((Join-Path $work 'backup-qualification/report.json'),'{"state":"passed","fully_qualified":true,"checks":[]}')
function Join-Path([string]$Path,[string]$ChildPath){if($ChildPath -ceq 'windows-backups.ps1'){return $backupStub};return [IO.Path]::Combine($Path,$ChildPath)}
function NativeAcceptanceHook {$trace.Add('native');if($nativeFailure){$facts.state='failed';return $null};return [pscustomobject]@{gates=[pscustomobject]@{meeting_browser='passed';native_clock='passed';native_providers='passed';native_call_me_back='passed'}}}
function Start-SuiteRecoveryPki {param($PackageRoot,$SourceRoot,$Work)$trace.Add('pki');return @{owned=$true}}
function AcceptanceHook {$trace.Add('upgrade');return [pscustomobject]@{gates=@{direct_113_helper_reapply='passed';direct_failure_rollback='passed';restore_gate_startup='passed'}}}
function LoopbackSftp {$trace.Add('sftp');return 'owned'}
function ResetCase {
 $script:trace=[Collections.Generic.List[string]]::new();$script:nativeFailure=$false
 $script:facts=[ordered]@{state='running';checks=@();gates=[ordered]@{fresh='passed';native_sip_audio='unqualified';meeting_browser='unqualified';native_clock='unqualified';native_providers='unqualified';native_call_me_back='unqualified';backups='pending';direct_113_helper_reapply='unqualified';direct_failure_rollback='unqualified';restore_gate_startup='unqualified';outside_acme='unqualified'}}
}
function RunCase([bool]$NativeOnly){
 $NativeDiagnosticsOnly=$NativeOnly;$UpgradeDiagnosticsOnly=$false;$BackupsDiagnosticsOnly=$false;$PackageRoot='owned';$source=$SourceRoot;$state=$work;$admin='fictional';$password='fictional'
 Invoke-Expression $metadata[0].Extent.Text;Invoke-Expression $routing
}
try{
 ResetCase;RunCase $true
 Check (($trace -join '|') -ceq 'native')
 Check ($facts.state -ceq 'partial' -and $facts.mode -ceq 'native_diagnostics_only')
 Check ($facts.release_eligible -is [bool] -and !$facts.release_eligible -and $facts.owner_transaction_eligible -is [bool] -and !$facts.owner_transaction_eligible)
 Check ($facts.gates.native_sip_audio -ceq 'passed' -and $facts.gates.meeting_browser -ceq 'passed')
 foreach($name in 'native_clock','native_providers','native_call_me_back'){Check ($facts.gates[$name] -ceq 'passed')}
 foreach($name in 'backups','direct_113_helper_reapply','direct_failure_rollback','restore_gate_startup'){Check ($facts.gates[$name] -ceq 'unqualified')}
 Check ($facts.unqualified -ccontains 'backups' -and $facts.unqualified -ccontains 'direct_failure_rollback')
 ResetCase;$nativeFailure=$true;RunCase $true
 Check ($facts.state -ceq 'failed' -and ($trace -join '|') -ceq 'native')
 Check ($facts.gates.native_sip_audio -ceq 'unqualified' -and $facts.gates.meeting_browser -ceq 'unqualified')
 ResetCase;RunCase $false
 Check (($trace -join '|') -ceq 'native|pki|upgrade|sftp|backups')
 Check (!$facts.Contains('mode') -and !$facts.Contains('release_eligible'))
 Check ($facts.gates.backups -ceq 'passed' -and $facts.gates.direct_failure_rollback -ceq 'passed')
 ResetCase;$nativeFailure=$true;RunCase $false
 Check ($facts.state -ceq 'failed' -and ($trace -join '|') -ceq 'native|pki|upgrade|sftp|backups')
 $workflow=[IO.File]::ReadAllText([IO.Path]::Combine($SourceRoot,'.github/workflows/windows-suite.yml'))
 Check ($workflow.Contains('native_diagnostics_only:') -and $workflow.Contains('NATIVE_DIAGNOSTICS_ONLY: ${{ inputs.native_diagnostics_only }}'))
 Check ($workflow.Contains("if(`$env:NATIVE_DIAGNOSTICS_ONLY -ceq 'true'){`$producerOptions.NativeDiagnosticsOnly=`$true}"))
 Check ($text.IndexOf('AssertNativeDiagnosticsMode $NativeDiagnosticsOnly') -lt $text.IndexOf('PrivateDirectory $work'))
}finally{[IO.Directory]::Delete($work,$true)}
Write-Host ("Native diagnostic guards and full/default routing controls passed: "+$checks)
