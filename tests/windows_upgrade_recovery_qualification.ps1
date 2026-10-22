# Execute the real evidence validators and child-status capture; no services run.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$checks=0
function Check([bool]$Value){if(!$Value){throw ('Recovery qualification evidence control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
function Refuses([scriptblock]$Action){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Check $failed}
function Parse([string]$Path){$tokens=$null;$errors=$null;$value=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors);Check ($errors.Count -eq 0);return $value}
$wrapper=Parse (Join-Path $SourceRoot 'tests/windows-upgrade-recovery-qualification.ps1');$suite=Parse (Join-Path $SourceRoot 'tests/windows-suite.ps1')
foreach($pair in @(@($wrapper,'Read-UpgradeRecoveryQualificationOutput'),@($suite,'Read-UpgradeRecoveryQualificationReport'))){$functions=@($pair[0].FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $pair[1]},$true));Check ($functions.Count -eq 1);Invoke-Expression $functions[0].Extent.Text}
$integration='PASS 64 actual upgrade journal, active-runtime preservation, seal/publication/finalization order and conservative unknown-shape controls'
$native='PASS 202 actual native private recovery bundle/config/ACL/lock/tamper, original choice, complete dependency and before/after handoff interruption controls; actual configured .NET boot=True; updater version=1.0.20'
Check ((Read-UpgradeRecoveryQualificationOutput @($integration) $true 'integration' '') -eq 64)
Check ((Read-UpgradeRecoveryQualificationOutput @($native) $true 'native' '1.0.20') -eq 202)
foreach($pair in @(@('integration',$integration),@('native',$native))){
 $kind=$pair[0];$output=$pair[1]
 Refuses {Read-UpgradeRecoveryQualificationOutput @($output) $false $kind '1.0.20'}
 foreach($bad in @(@(),@($output,$output),@($null),@(17),@($output+"`nPRIVATE"),@('PRIVATE'))){Refuses {Read-UpgradeRecoveryQualificationOutput $bad $true $kind '1.0.20'}}
 foreach($count in '0','-1','1','100001','999999','1.0','true'){$bad=$output -replace '^PASS [0-9]+ ',('PASS '+$count+' ');Refuses {Read-UpgradeRecoveryQualificationOutput @($bad) $true $kind '1.0.20'}}
}
foreach($boot in 'False','true','1',''){$bad=$native.Replace('boot=True',('boot='+$boot));Refuses {Read-UpgradeRecoveryQualificationOutput @($bad) $true 'native' '1.0.20'}}
foreach($version in '1.0.6','1.0.20.0','1.0.21','PRIVATE',''){$bad=$native.Replace('version=1.0.20',('version='+$version));Refuses {Read-UpgradeRecoveryQualificationOutput @($bad) $true 'native' '1.0.20'}}
function Report {return [pscustomobject]@{schema=1;producer='windows-upgrade-recovery-qualification.ps1';state='passed';actual_native_windows=$true;actual_configured_updater_boot=$true;integration_checks=64;native_checks=202;updater_version='1.0.20';updater_scope='candidate_component';installed_server_changed=$false;private='PRIVATE'}}
$safe=Read-UpgradeRecoveryQualificationReport (Report) '1.0.20';Check ($safe.Count -eq 8 -and $safe.actual_configured_updater_boot -and $safe.updater_scope -ceq 'candidate_component' -and !$safe.installed_server_changed);Check (($safe|ConvertTo-Json -Compress) -cnotmatch 'PRIVATE|producer|schema')
foreach($field in 'producer','state','updater_version','updater_scope'){
 foreach($bad in $null,@((Report).$field),@{},1,$true,'PRIVATE'){$row=Report;$row.$field=$bad;Refuses {Read-UpgradeRecoveryQualificationReport $row '1.0.20'}}
}
foreach($bad in $null,'1',$true,1.0,@(1),@{},0,2){$row=Report;$row.schema=$bad;Refuses {Read-UpgradeRecoveryQualificationReport $row '1.0.20'}}
foreach($field in 'actual_native_windows','actual_configured_updater_boot','installed_server_changed'){
 foreach($bad in $null,'true',1,@($true),@{}){$row=Report;$row.$field=$bad;Refuses {Read-UpgradeRecoveryQualificationReport $row '1.0.20'}}
 $row=Report;$row.$field=if($field -ceq 'installed_server_changed'){$true}else{$false};Refuses {Read-UpgradeRecoveryQualificationReport $row '1.0.20'}
}
foreach($pair in @(@('integration_checks',64),@('native_checks',202))){foreach($bad in $null,'202',$true,1.5,@(202),@{},0,($pair[1]-1),100001){$row=Report;$row.($pair[0])=$bad;Refuses {Read-UpgradeRecoveryQualificationReport $row '1.0.20'}}}
foreach($bad in $null,@(),@((Report),(Report)),'PRIVATE'){Refuses {Read-UpgradeRecoveryQualificationReport $bad '1.0.20'}}
Refuses {Read-UpgradeRecoveryQualificationReport (Report) '1.0.21'}
Refuses {Read-UpgradeRecoveryQualificationReport (Report) 'PRIVATE'}
$work=Join-Path ([IO.Path]::GetTempPath()) ('openweb-recovery-evidence-'+[Guid]::NewGuid().ToString('N'));$originalSourceRoot=$SourceRoot
try{
 New-Item -ItemType Directory -Path (Join-Path $work 'tests') -Force|Out-Null
 $SourceRoot=$work;$PackageRoot=Join-Path $work 'candidate';$version='1.0.20'
 $body=@($wrapper.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})[0].Body.Statements
 foreach($kind in 'integration','native'){
  $first=@($body|Where-Object {$_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -ceq ('$'+$kind) -and $_.Right.Extent.Text.StartsWith('& ')})
  $capture=@($body|Where-Object {$_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -ceq ('$'+$kind+'Succeeded')})
  Check ($first.Count -eq 1 -and $capture.Count -eq 1 -and $capture[0].Right.Extent.Text -ceq '$?')
  Check (($body.IndexOf($capture[0])) -eq ($body.IndexOf($first[0])+1))
  $line=if($kind -ceq 'native'){$native}else{$integration}
  foreach($exit in 0,1){
   $name=if($kind -ceq 'native'){'windows_upgrade_recovery.ps1'}else{'windows_upgrade_recovery_integration.ps1'}
   $scriptPath=Join-Path $work ('tests/'+$name)
   [IO.File]::WriteAllText($scriptPath,('param([string]$SourceRoot,[string]$UpdaterDirectory,[string]$ExpectedUpdaterVersion)'+"`n"+"Write-Output '"+$line+"'`nexit "+$exit))
   Invoke-Expression ($first[0].Extent.Text+"`n"+$capture[0].Extent.Text)
   $ok=Get-Variable -Name ($kind+'Succeeded') -ValueOnly;$output=Get-Variable -Name $kind -ValueOnly
   Check ($ok -eq ($exit -eq 0))
   if($exit -eq 0){Check ((Read-UpgradeRecoveryQualificationOutput @($output) $ok $kind '1.0.20') -ge 64)}else{Refuses {Read-UpgradeRecoveryQualificationOutput @($output) $ok $kind '1.0.20'}}
  }
 }
 # The previous wrapper's log write replaces a failed child's status with true.
 $old=@(& $scriptPath);$old|Set-Content -LiteralPath (Join-Path $work 'old.private.out');$overwritten=$?;Check $overwritten
}finally{$SourceRoot=$originalSourceRoot;Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue}
Write-Output ('PASS '+$checks+' actual recovery wrapper/report/child-exit controls; no installed server changed')
