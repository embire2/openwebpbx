# Source-only preventive ordering contract; never executes a fixture or worker.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$checks=0
function Verify([bool]$v){if(!$v){throw ('Natural init ordering control '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
$path=Join-Path $SourceRoot 'tests/windows-updater-qualification.ps1';$text=[IO.File]::ReadAllText($path);$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors);Verify (!$errors.Count)
function Offset([string]$needle){$first=$text.IndexOf($needle,[StringComparison]::Ordinal);Verify ($first-ge 0-and $text.IndexOf($needle,$first+1,[StringComparison]::Ordinal)-lt 0);return $first}
$pki=Offset "`$phase='laboratory HTTPS PKI preparation'";$audit=Offset "(Join-Path `$qa 'audit.key')"
$health=Offset 'Suspend-OpenWebQualificationHealth ([ref]$qualificationHealthOriginal)'
$tenant=Offset "else{`$phase='natural original tenant initialization before preservation baselines';WaitActualTenantIdle}"
$trust=Offset "`$phase='laboratory HTTPS trust import'";$hosts=Offset '[IO.File]::AppendAllText($hosts,"127.0.0.1 github.com $marker'
$environment=Offset "`$phase='laboratory HTTPS worker environment'";$endpoint=Offset "`$phase='laboratory HTTPS endpoint startup'";$restart=Offset "`$phase='initial installed13 worker startup'"
$prefetch=Offset 'WaitQualificationFaultPrefetch $verified.fault $initialPid $originalWorker';$warmup=Offset "`$phase='ordinary SYSTEM backup worker baseline initialization'";$baseline=Offset "`$beforeDb=DatabaseSnapshot 'before-fault'"
Verify ($pki-lt $audit-and $audit-lt $health-and $health-lt $tenant)
foreach($later in $trust,$hosts,$environment,$endpoint,$restart,$prefetch){Verify ($tenant-lt $later)}
Verify ($prefetch-lt $warmup-and $warmup-lt $baseline)
$branch=@($ast.FindAll({param($n)$n-is [Management.Automation.Language.IfStatementAst]-and $n.Extent.Text.StartsWith('if(!$actualCandidate){Suspend-OpenWebQualificationTenant')},$true));Verify ($branch.Count-eq 1)
Verify ($branch[0].Clauses.Count-eq 2-and $branch[0].Clauses[0].Item1.Extent.Text-ceq '!$actualCandidate'-and $branch[0].Clauses[1].Item1.Extent.Text-ceq '$OriginalTenantDomainsDisabled')
Verify ($branch[0].Clauses[0].Item2.Extent.Text.Contains('Suspend-OpenWebQualificationTenant ([ref]$qualificationTenantOriginal)')-and $branch[0].Clauses[1].Item2.Extent.Text.Contains('$qualificationTenantOriginal.Enabled=$false')-and $branch[0].ElseClause.Extent.Text.Contains('WaitActualTenantIdle'))
$wait=@($ast.FindAll({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst]-and $n.Name-ceq 'WaitActualTenantIdle'},$true));Verify ($wait.Count-eq 1)
foreach($literal in '[DateTime]::UtcNow.AddSeconds(600)','Start-Sleep -Milliseconds 250','Get-WindowsEmptyTenantPaths','Assert-OpenWebQualificationTenantTask $tenant','$info.LastTaskResult-eq 0','$info.LastRunTime-gt [DateTime]::MinValue','!$initialized.Count'){Verify ($wait[0].Extent.Text.Contains($literal))}
$span=$text.Substring($health,$tenant-$health+120);foreach($forbidden in 'Start-ScheduledTask','Start-Process','Initialize','--tick','New-Item'){Verify (!$span.Contains($forbidden))}
@{state='passed';checks=$checks;source_only=$true;natural600_gate_retained=$true;no_worker_or_fixture_or_network_invocation=$true;historical_cause_still_unknown=$true}|ConvertTo-Json -Compress
