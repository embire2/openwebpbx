# Actual AST/mode/workflow routing controls; all external hooks are owned mocks.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$tokens=$null;$errors=$null
$path=[IO.Path]::Combine($SourceRoot,'tests/windows-suite.ps1');$text=[IO.File]::ReadAllText($path)
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The actual suite must parse.'}
foreach($name in 'SuiteMusicWorkflow','AssertSuiteMode'){
 $nodes=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true))
 if($nodes.Count -ne 1){throw 'Actual mode functions must be unique.'};Invoke-Expression $nodes[0].Extent.Text
}
$markers=@([regex]::Matches($text,'(?ms)# BEGIN qualification-gate-routing\r?\n(.*?)\r?\n # END qualification-gate-routing'))
if($markers.Count -ne 1){throw 'The actual gate routing must be uniquely bounded.'}
$routing=$markers[0].Groups[1].Value
$scope=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith('if($UpgradeDiagnosticsOnly){$facts.mode=')},$true))
if($scope.Count -ne 1){throw 'Actual diagnostic metadata must be unique.'}
$final=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$facts.state' -and $node.Right.Extent.Text.Contains('elseif($missing.Count)')},$true))
if($final.Count -ne 1){throw 'Actual final-state routing must be unique.'}
$script:count=0
function Check([bool]$Value){if(!$Value){throw ('Diagnostic mode control failed at '+(@(Get-PSCallStack)[1].ScriptLineNumber))};$script:count++}
$sha='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';$diagnosticRef='embire2/openwebpbx/.github/workflows/windows-upgrade-diagnostics.yml@refs/heads/customization'
AssertSuiteMode $true $diagnosticRef $sha $sha ''
Check ((SuiteMusicWorkflow $true) -ceq '.github/workflows/windows-upgrade-diagnostics.yml')
Check ((SuiteMusicWorkflow $false) -ceq '.github/workflows/windows-suite.yml')
AssertSuiteMode $false '' '' '' 'provided-package'
Check $true
foreach($case in @(
 @($true,$diagnosticRef,'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',$sha,''),
 @($true,$diagnosticRef,$sha,'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',''),
 @($true,$diagnosticRef,'','', ''),
 @($true,$diagnosticRef,$sha.ToUpperInvariant(),$sha.ToUpperInvariant(),''),
 @($true,'embire2/openwebpbx/.github/workflows/windows-suite.yml@refs/heads/customization',$sha,$sha,''),
 @($true,'foreign/openwebpbx/.github/workflows/windows-upgrade-diagnostics.yml@refs/heads/customization',$sha,$sha,''),
 @($true,'embire2/openwebpbx/.github/workflows/windows-upgrade-diagnostics.yml@refs/pull/1/merge',$sha,$sha,''),
 @($true,'',$sha,$sha,''),
 @($true,$diagnosticRef,$sha,$sha,'provided-package'),
 @($false,$diagnosticRef,$sha,$sha,''))){
 $refused=$false;try{AssertSuiteMode @case}catch{$refused=$true};Check $refused
}
$work=[IO.Path]::Combine([IO.Path]::GetTempPath(),'openweb-upgrade-routing-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work);[void][IO.Directory]::CreateDirectory([IO.Path]::Combine($work,'backup-qualification'))
$backupStub=[IO.Path]::Combine($work,'backups.ps1')
[IO.File]::WriteAllText($backupStub,"param(`$PackageRoot,`$AdminEmail,`$AdminPassword,[switch]`$DisposableFactory,`$SftpConfig)`n`$trace.Add('backups');if(`$failure -eq 'backups'){throw 'owned failure'}")
[IO.File]::WriteAllText([IO.Path]::Combine($work,'backup-qualification/report.json'),' {"state":"passed","fully_qualified":true,"checks":[]} ')
function Join-Path([string]$Path,[string]$ChildPath){if($ChildPath -ceq 'windows-backups.ps1'){return $backupStub};return [IO.Path]::Combine($Path,$ChildPath)}
function NativeAcceptanceHook {
 $trace.Add('native');if($failure -eq 'native'){throw 'owned native failure'}
 if($nativeContinuation){$facts.state='failed';return $null};return [pscustomobject]@{state='passed'}
}
function Start-SuiteRecoveryPki {param($PackageRoot,$SourceRoot,$Work)$trace.Add('pki');if($failure -eq 'pki'){throw 'owned PKI failure'};return @{owned=$true}}
function AcceptanceHook {
 $trace.Add('upgrade');if($failure -eq 'upgrade'){throw 'owned upgrade failure'}
 return [pscustomobject]@{state='passed';gates=[pscustomobject]@{direct_113_helper_reapply='passed';direct_failure_rollback='passed';restore_gate_startup='passed';manager_reopen_success='passed';manager_reopen_rollback='passed';installed_upgrade='passed';failure_rollback='passed';legacy_106_upgrade='passed';native_sip_audio='passed';backups='passed'}}
}
function LoopbackSftp {$trace.Add('sftp');return 'owned-mock'}
function ResetCase {
 $script:facts=[ordered]@{state='running';checks=@();gates=[ordered]@{fresh='passed';native_sip_audio='unqualified';backups='pending';direct_113_helper_reapply='unqualified';direct_failure_rollback='unqualified';restore_gate_startup='unqualified';manager_reopen_success='unqualified';manager_reopen_rollback='unqualified';installed_upgrade='unqualified';failure_rollback='unqualified';legacy_106_upgrade='unqualified';outside_acme='unqualified'}}
 $script:trace=[Collections.Generic.List[string]]::new();$script:failure='';$script:nativeContinuation=$false;$script:lastPhase='';$script:failed=$false
}
function RunCase([bool]$Diagnostic){
 $UpgradeDiagnosticsOnly=$Diagnostic;$PackageRoot='owned-package';$source=$SourceRoot;$state=$work;$admin='owned-fixture';$password='owned-fixture'
 Invoke-Expression $scope[0].Extent.Text
 try{Invoke-Expression $routing}catch{$facts.state='failed';$script:failed=$true;$script:lastPhase=$phase}
}
try{
 ResetCase;RunCase $false
 Check (($trace -join '|') -ceq 'native|pki|upgrade|sftp|backups')
 Check ($facts.gates.native_sip_audio -ceq 'passed' -and $facts.gates.backups -ceq 'passed')
 Check ($facts.state -ceq 'partial' -and !$facts.Contains('mode'))
 ResetCase;RunCase $true
 Check (($trace -join '|') -ceq 'pki|upgrade')
 Check ($facts.gates.native_sip_audio -ceq 'unqualified' -and $facts.gates.backups -ceq 'pending')
 Check ($facts.gates.direct_113_helper_reapply -ceq 'passed' -and $facts.gates.direct_failure_rollback -ceq 'passed' -and $facts.gates.restore_gate_startup -ceq 'passed')
 Check ($facts.state -ceq 'partial' -and $facts.mode -ceq 'upgrade_diagnostics_only' -and $facts.qualification_scope.Contains('Post-native state is not reproduced'))
 Check ($facts.unqualified -ccontains 'native_sip_audio' -and $facts.unqualified -ccontains 'backups')
 foreach($where in 'pki','upgrade'){
  ResetCase;$failure=$where;RunCase $true
  Check ($failed -and $facts.state -ceq 'failed' -and $facts.gates.native_sip_audio -ceq 'unqualified' -and $facts.gates.backups -ceq 'pending')
  Check ($lastPhase -ceq $(if($where -eq 'pki'){'independent trusted recovery fixture'}else{'upgrade acceptance hook'}))
  Check (!(($trace -join '|') -match 'native|sftp|backups'))
 }
 ResetCase;$failure='native';RunCase $false
 Check ($failed -and ($trace -join '|') -ceq 'native')
 ResetCase;$nativeContinuation=$true;RunCase $false
 Check ($facts.state -ceq 'failed' -and ($trace -join '|') -ceq 'native|pki|upgrade|sftp|backups')
 Check ($facts.gates.native_sip_audio -ceq 'unqualified')
 ResetCase;$failure='upgrade';RunCase $false
 Check ($failed -and ($trace -join '|') -ceq 'native|pki|upgrade')
 ResetCase;$failure='backups';RunCase $false
 Check ($failed -and $facts.gates.backups -ceq 'pending' -and $facts.state -ceq 'failed')
 ResetCase;$UpgradeDiagnosticsOnly=$true;$missing=@();$facts.state=Invoke-Expression $final[0].Right.Extent.Text
 Check ($facts.state -ceq 'partial')
 $UpgradeDiagnosticsOnly=$false;$facts.state=Invoke-Expression $final[0].Right.Extent.Text;Check ($facts.state -ceq 'passed')
 $facts.state='failed';$UpgradeDiagnosticsOnly=$true;$facts.state=Invoke-Expression $final[0].Right.Extent.Text;Check ($facts.state -ceq 'failed')
 Check ($text.IndexOf("`$phase='fresh installation'") -lt $text.IndexOf('# BEGIN qualification-gate-routing'))
 Check ($text.IndexOf("`$phase='original candidate export'") -lt $text.IndexOf('# BEGIN qualification-gate-routing'))
 $workflow=[IO.File]::ReadAllText([IO.Path]::Combine($SourceRoot,'.github/workflows/windows-upgrade-diagnostics.yml'))
 $full=[IO.File]::ReadAllText([IO.Path]::Combine($SourceRoot,'.github/workflows/windows-suite.yml'))
 Check ($workflow.Contains('-DisposableHostedRunner -UpgradeDiagnosticsOnly') -and !$full.Contains('-UpgradeDiagnosticsOnly'))
 Check ($workflow.Contains('group: windows-upgrade-diagnostics-${{ github.ref }}'))
 Check ($workflow.Contains('contents: read') -and $workflow.Contains('actions: read') -and !$workflow.Contains('contents: write'))
 Check ($workflow.Contains('openwebpbx-windows-suite-facts-${{ github.run_id }}') -and !$workflow.Contains('openwebpbx-windows-suite-candidate-'))
 Check ($workflow.Contains('uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1'))
 Check ($workflow.Contains('uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9'))
 Check ($workflow.Contains('NATIVE_RUN_ID: ${{ inputs.native_run_id }}') -and $workflow.Contains('ENGINE_RUN_ID: ${{ inputs.engine_run_id }}'))
}finally{[IO.Directory]::Delete($work,$true)}
Write-Output ('PASS '+$count+' actual AST/mode/refusal/workflow-routing controls; no PBX invoked')
