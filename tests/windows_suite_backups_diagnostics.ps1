# Exercise actual source ASTs with fictional hook substitutes; never run the PBX caller.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$tokens=$null;$errors=$null
$sourcePath=[IO.Path]::Combine($SourceRoot,'tests/windows-suite.ps1');$text=[IO.File]::ReadAllText($sourcePath)
$ast=[Management.Automation.Language.Parser]::ParseFile($sourcePath,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Actual suite source must parse.'}
foreach($name in 'SuiteMusicWorkflow','AssertSuiteMode'){
 $nodes=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true))
 if($nodes.Count -ne 1){throw 'Actual mode functions must be unique.'}
 Invoke-Expression $nodes[0].Extent.Text
}
$initial=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$facts' -and $n.Right.Extent.Text.Contains("platform='Windows Server 2025 x64'")},$true))
$metadata=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.StartsWith('if($UpgradeDiagnosticsOnly){$facts.mode=')},$true))
$hostGuard=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.StartsWith('if(!$DisposableHostedRunner -or')},$true))
$final=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$facts.state' -and $n.Right.Extent.Text.Contains('elseif($missing.Count)')},$true))
$routingMatches=@([regex]::Matches($text,'(?ms)# BEGIN qualification-gate-routing\r?\n(.*?)\r?\n # END qualification-gate-routing'))
if($initial.Count -ne 1 -or $metadata.Count -ne 1 -or $hostGuard.Count -ne 1 -or $final.Count -ne 1 -or $routingMatches.Count -ne 1){throw 'Actual fact/host/routing expressions must be unique.'}
$routing=$routingMatches[0].Groups[1].Value
$script:count=0
function Check([bool]$Value){if(!$Value){throw ('Backup diagnostic control failed at '+(@(Get-PSCallStack)[1].ScriptLineNumber))};$script:count++}
function Expect-Refusal([scriptblock]$Code,[string]$Reason){$actual=$null;try{& $Code}catch{$actual=$_.Exception.Message};Check ($actual -ceq $Reason)}
$sha='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';$other='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
$backupRef='embire2/openwebpbx/.github/workflows/windows-backups-diagnostics.yml@refs/heads/customization'
$upgradeRef='embire2/openwebpbx/.github/workflows/windows-upgrade-diagnostics.yml@refs/heads/customization'
$fullRef='embire2/openwebpbx/.github/workflows/windows-suite.yml@refs/heads/customization'
AssertSuiteMode $false $backupRef $sha $sha '' $true;Check $true
AssertSuiteMode $true $upgradeRef $sha $sha '' $false;Check $true
AssertSuiteMode $false $fullRef $sha $sha 'provided-full-package' $false;Check $true
Check ((SuiteMusicWorkflow $false $true) -ceq '.github/workflows/windows-backups-diagnostics.yml')
Check ((SuiteMusicWorkflow $true $false) -ceq '.github/workflows/windows-upgrade-diagnostics.yml')
Check ((SuiteMusicWorkflow $false $false) -ceq '.github/workflows/windows-suite.yml')
Expect-Refusal {SuiteMusicWorkflow $true $true} 'Diagnostic modes are mutually exclusive.'
$badModes=@(
 @{upgrade=$true;backup=$true;ref=$backupRef;workflow=$sha;source=$sha;package='';reason='Diagnostic modes are mutually exclusive.'},
 @{upgrade=$false;backup=$false;ref=$backupRef;workflow=$sha;source=$sha;package='';reason='The diagnostic workflow requires its explicit diagnostic-only switch.'},
 @{upgrade=$false;backup=$false;ref=$upgradeRef;workflow=$sha;source=$sha;package='';reason='The diagnostic workflow requires its explicit diagnostic-only switch.'},
 @{upgrade=$false;backup=$true;ref=$backupRef;workflow=$other;source=$sha;package=''},
 @{upgrade=$false;backup=$true;ref=$backupRef;workflow=$sha;source=$other;package=''},
 @{upgrade=$false;backup=$true;ref=$backupRef;workflow=$sha.ToUpperInvariant();source=$sha.ToUpperInvariant();package=''},
 @{upgrade=$false;backup=$true;ref=$backupRef;workflow='';source='';package=''},
 @{upgrade=$false;backup=$true;ref=$backupRef;workflow=$sha;source=$sha;package='prebuilt-unbound-package'},
 @{upgrade=$false;backup=$true;ref=$fullRef;workflow=$sha;source=$sha;package=''},
 @{upgrade=$false;backup=$true;ref=$upgradeRef;workflow=$sha;source=$sha;package=''},
 @{upgrade=$true;backup=$false;ref=$backupRef;workflow=$sha;source=$sha;package=''},
 @{upgrade=$false;backup=$true;ref='foreign/openwebpbx/.github/workflows/windows-backups-diagnostics.yml@refs/heads/customization';workflow=$sha;source=$sha;package=''},
 @{upgrade=$false;backup=$true;ref='embire2/openwebpbx/.github/workflows/windows-backups-diagnostics.yml@refs/pull/1/merge';workflow=$sha;source=$sha;package=''},
 @{upgrade=$false;backup=$true;ref='embire2/openwebpbx/.github/workflows/windows-backups-diagnostics.yml@refs/heads/';workflow=$sha;source=$sha;package=''},
 @{upgrade=$false;backup=$true;ref='embire2/openwebpbx/.github/workflows/Windows-backups-diagnostics.yml@refs/heads/customization';workflow=$sha;source=$sha;package=''}
)
foreach($case in $badModes){
 $reason=$case.reason;if(!$reason){$reason='Diagnostic mode requires the exact diagnostic workflow/source and pinned build inputs.'}
 Expect-Refusal {AssertSuiteMode $case.upgrade $case.ref $case.workflow $case.source $case.package $case.backup} $reason
}
# Evaluate the actual disposable-host guard by itself, never the caller entry point.
$validHost=@{GITHUB_ACTIONS='true';RUNNER_ENVIRONMENT='github-hosted';RUNNER_OS='Windows';GITHUB_REPOSITORY='embire2/openwebpbx'};$savedHost=@{}
foreach($name in $validHost.Keys){$savedHost[$name]=[Environment]::GetEnvironmentVariable($name)}
try{
 foreach($name in $validHost.Keys){[Environment]::SetEnvironmentVariable($name,$validHost[$name])}
 $DisposableHostedRunner=$true;Invoke-Expression $hostGuard[0].Extent.Text;Check $true
 $DisposableHostedRunner=$false
 Expect-Refusal {Invoke-Expression $hostGuard[0].Extent.Text} 'Run only on the explicitly disposable Windows hosted runner of this repository.'
 $DisposableHostedRunner=$true
 foreach($name in $validHost.Keys){
  [Environment]::SetEnvironmentVariable($name,'foreign')
  Expect-Refusal {Invoke-Expression $hostGuard[0].Extent.Text} 'Run only on the explicitly disposable Windows hosted runner of this repository.'
  [Environment]::SetEnvironmentVariable($name,$validHost[$name])
 }
}finally{foreach($name in $savedHost.Keys){[Environment]::SetEnvironmentVariable($name,$savedHost[$name])}}
$work=[IO.Path]::Combine([IO.Path]::GetTempPath(),'openweb-backup-routing-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work);[void][IO.Directory]::CreateDirectory([IO.Path]::Combine($work,'backup-qualification'))
$backupStub=[IO.Path]::Combine($work,'backups.ps1');$backupReport=[IO.Path]::Combine($work,'backup-qualification/report.json')
[IO.File]::WriteAllText($backupStub,"param(`$PackageRoot,`$AdminEmail,`$AdminPassword,[switch]`$DisposableFactory,`$SftpConfig)`n`$trace.Add('backups');if(!`$DisposableFactory){throw 'owned factory guard'};if(`$failure -eq 'backups'){throw 'owned backup failure'}")
function Join-Path([string]$Path,[string]$ChildPath){if($ChildPath -ceq 'windows-backups.ps1'){return $backupStub};return [IO.Path]::Combine($Path,$ChildPath)}
function NativeAcceptanceHook {$trace.Add('native');return [pscustomobject]@{state='passed';gates=[pscustomobject]@{meeting_browser='passed'}}}
function Start-SuiteRecoveryPki {param($PackageRoot,$SourceRoot,$Work)$trace.Add('pki');if($failure -ceq 'pki'){throw 'owned PKI failure'};return @{owned=$true}}
function AcceptanceHook {
 $trace.Add('upgrade');if($failure -ceq 'upgrade'){throw 'owned upgrade failure'}
 return [pscustomobject]@{state='passed';gates=[pscustomobject]@{direct_113_helper_reapply='passed';direct_failure_rollback='passed';restore_gate_startup='passed';manager_reopen_success='passed';manager_reopen_rollback='passed';installed_upgrade='passed';failure_rollback='passed';legacy_106_upgrade='passed';native_sip_audio='passed';backups='passed'}}
}
function LoopbackSftp {$trace.Add('sftp');if($failure -ceq 'sftp'){throw 'owned SFTP failure'};return 'owned-loopback-fixture'}
function ResetDiagnosticCase {
 $script:facts=Invoke-Expression $initial[0].Right.Extent.Text;$script:facts.gates.fresh='passed'
 $script:trace=[Collections.Generic.List[string]]::new();$script:failure='';$script:routeFailed=$false;$script:failureMessage='';$script:failedPhase=''
 [IO.File]::WriteAllText($backupReport,'{"state":"passed","fully_qualified":true,"checks":[]}')
}
function InvokeActualGateRouting([bool]$BackupOnly,[bool]$UpgradeOnly=$false){
 $BackupsDiagnosticsOnly=$BackupOnly;$UpgradeDiagnosticsOnly=$UpgradeOnly;$PackageRoot='owned-package';$source=$SourceRoot;$state=$work;$admin='fictional-fixture';$password='fictional-fixture'
 Invoke-Expression $metadata[0].Extent.Text
 try{Invoke-Expression $routing}catch{$facts.state='failed';$script:routeFailed=$true;$script:failureMessage=$_.Exception.Message;$script:failedPhase=$phase}
}
try{
 ResetDiagnosticCase;InvokeActualGateRouting $true
 Check (($trace -join '|') -ceq 'pki|sftp|backups')
 Check ($facts.gates.fresh -ceq 'passed' -and $facts.gates.backups -ceq 'passed')
 foreach($name in $facts.gates.Keys|Where-Object {$_ -notin 'fresh','backups'}){Check ($facts.gates[$name] -ceq 'unqualified')}
 Check ($facts.mode -ceq 'backup_diagnostics_only' -and $facts.state -ceq 'partial')
 Check ($facts.release_eligible -is [bool] -and !$facts.release_eligible -and $facts.owner_transaction_eligible -is [bool] -and !$facts.owner_transaction_eligible)
 Check ($facts.unqualified -ccontains 'native_sip_audio' -and $facts.unqualified -ccontains 'direct_113_helper_reapply' -and $facts.unqualified -ccontains 'restore_gate_startup')
 foreach($where in 'pki','sftp','backups'){
  ResetDiagnosticCase;$failure=$where;InvokeActualGateRouting $true
  Check ($routeFailed -and $facts.state -ceq 'failed' -and $facts.gates.backups -ceq 'pending')
  Check ($failureMessage -ceq $(switch($where){pki{'owned PKI failure'};sftp{'owned SFTP failure'};backups{'owned backup failure'}}))
  Check ($failedPhase -ceq $(if($where -ceq 'pki'){'independent trusted recovery fixture'}else{'backup qualification'}))
  Check (!(($trace -join '|') -match 'native|upgrade') -and !$facts.release_eligible -and !$facts.owner_transaction_eligible)
 }
 foreach($report in '{"state":"passed","fully_qualified":false,"checks":[]}','{"state":"failed","fully_qualified":true,"checks":[]}'){
  ResetDiagnosticCase;[IO.File]::WriteAllText($backupReport,$report);InvokeActualGateRouting $true
  Check ($routeFailed -and $failureMessage -ceq 'Actual backup/SFTP qualification is incomplete.' -and $facts.gates.backups -ceq 'pending')
 }
 ResetDiagnosticCase;InvokeActualGateRouting $false
 Check (($trace -join '|') -ceq 'native|pki|upgrade|sftp|backups')
 Check ($facts.gates.native_sip_audio -ceq 'passed' -and $facts.gates.backups -ceq 'passed' -and !$facts.Contains('mode'))
 ResetDiagnosticCase;InvokeActualGateRouting $false $true
 Check (($trace -join '|') -ceq 'pki|upgrade' -and $facts.mode -ceq 'upgrade_diagnostics_only')
 Check ($facts.gates.native_sip_audio -ceq 'unqualified' -and $facts.gates.backups -ceq 'pending' -and $facts.state -ceq 'partial')
 ResetDiagnosticCase;$failure='upgrade';InvokeActualGateRouting $false
 Check ($routeFailed -and ($trace -join '|') -ceq 'native|pki|upgrade' -and $facts.gates.backups -ceq 'pending')
 ResetDiagnosticCase;$BackupsDiagnosticsOnly=$true;$UpgradeDiagnosticsOnly=$false;$missing=@();Invoke-Expression $metadata[0].Extent.Text
 $facts.state=Invoke-Expression $final[0].Right.Extent.Text
 Check ($facts.state -ceq 'partial' -and !$facts.release_eligible -and !$facts.owner_transaction_eligible)
 $facts.state='failed';$facts.state=Invoke-Expression $final[0].Right.Extent.Text;Check ($facts.state -ceq 'failed')
 ResetDiagnosticCase;$BackupsDiagnosticsOnly=$false;$UpgradeDiagnosticsOnly=$false;$missing=@();$facts.state=Invoke-Expression $final[0].Right.Extent.Text
 Check ($facts.state -ceq 'passed' -and !$facts.Contains('mode'))
 $backupCommand=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.Extent.Text.StartsWith("& (Join-Path `$PSScriptRoot 'windows-backups.ps1')")},$true))
 Check ($backupCommand.Count -eq 1 -and $backupCommand[0].Extent.Text -ceq '& (Join-Path $PSScriptRoot ''windows-backups.ps1'') -PackageRoot $PackageRoot -AdminEmail $admin -AdminPassword $password -DisposableFactory -SftpConfig $sftpConfig')
 $entry=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'AssertSuiteMode'},$true))
 Check ($entry.Count -eq 1 -and $entry[0].Extent.Text.EndsWith('$PackageRoot $BackupsDiagnosticsOnly'))
 $musicCall=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'SuiteMusicWorkflow'},$true))
 Check ($musicCall.Count -eq 1 -and $musicCall[0].Extent.Text -ceq 'SuiteMusicWorkflow $UpgradeDiagnosticsOnly $BackupsDiagnosticsOnly')
 Check ($text.IndexOf("`$phase='fresh installation'") -lt $text.IndexOf('# BEGIN qualification-gate-routing'))
 Check ($text.IndexOf("`$phase='original candidate export'") -lt $text.IndexOf('# BEGIN qualification-gate-routing'))
 $workflow=[IO.File]::ReadAllText([IO.Path]::Combine($SourceRoot,'.github/workflows/windows-backups-diagnostics.yml'))
 $full=[IO.File]::ReadAllText([IO.Path]::Combine($SourceRoot,'.github/workflows/windows-suite.yml'))
 Check ($workflow.Contains('-DisposableHostedRunner -BackupsDiagnosticsOnly') -and !$workflow.Contains('-UpgradeDiagnosticsOnly') -and !$full.Contains('-BackupsDiagnosticsOnly'))
 Check ($workflow.Contains('group: windows-backups-diagnostics-${{ github.ref }}-${{ github.sha }}'))
 Check ($workflow.Contains('contents: read') -and $workflow.Contains('actions: read') -and !$workflow.Contains('contents: write'))
 Check ($workflow.Contains('openwebpbx-windows-backups-diagnostic-facts-${{ github.run_id }}') -and !$workflow.Contains('openwebpbx-windows-suite-candidate-'))
 Check ($workflow.Contains('uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1') -and $workflow.Contains('uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9'))
 Check ($workflow.Contains('NATIVE_RUN_ID: ${{ inputs.native_run_id }}') -and $workflow.Contains('ENGINE_RUN_ID: ${{ inputs.engine_run_id }}') -and $workflow.Contains('runs-on: windows-2025'))
}finally{[IO.Directory]::Delete($work,$true)}
Write-Output ('PASS '+$count+' actual backup-mode/host/source/refusal/routing controls; no PBX invoked')
