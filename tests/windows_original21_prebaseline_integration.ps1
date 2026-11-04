# Source-extracted main caller only. Service, Tenant/Scheduler and backup APIs
# are fixed adapters; no product, native process, task, network or host action.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$checks=0
function Verify([bool]$Value){if(!$Value){throw ('Prebaseline caller control '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-updater-qualification.ps1'),[ref]$tokens,[ref]$errors);Verify (!$errors.Count);$source=$ast.Extent.Text
$node=@($ast.FindAll({param($n)$n-is [Management.Automation.Language.TryStatementAst]-and @($n.Body.FindAll({param($c)$c-is [Management.Automation.Language.CommandAst]-and $c.GetCommandName()-ceq 'Suspend-Original21PrebaselineCore'},$true)).Count-eq 1-and $n.Finally-and @($n.Finally.FindAll({param($c)$c-is [Management.Automation.Language.CommandAst]-and $c.GetCommandName()-ceq 'Resume-Original21PrebaselineCore'},$true)).Count-eq 1},$true));Verify ($node.Count-eq 1)
$body=$node[0].Body.Extent.Text
$owner=$node[0].Parent;while($owner-and $owner-isnot [Management.Automation.Language.IfStatementAst]){$owner=$owner.Parent};Verify ($owner.Clauses[0].Item1.Extent.Text-ceq '$actualCandidate')
Verify (@($owner.ElseClause.FindAll({param($c)$c-is [Management.Automation.Language.CommandAst]-and $c.GetCommandName()-cin 'Suspend-Original21PrebaselineCore','Resume-Original21PrebaselineCore'},$true)).Count-eq 0)
foreach($name in 'Suspend-Original21PrebaselineCore','InitializeQualificationBackupWorker'){Verify (@($node[0].Body.FindAll({param($c)$c-is [Management.Automation.Language.CommandAst]-and $c.GetCommandName()-ceq $name},$true)).Count-eq 1)}
Verify (@($node[0].Body.FindAll({param($c)$c-is [Management.Automation.Language.CommandAst]-and $c.GetCommandName()-ceq 'WaitActualTenantIdle'},$true)).Count-eq 1)
$actualBody=$owner.Clauses[0].Item2.Extent.Text
Verify ($actualBody.IndexOf('WaitOriginal21UpdaterStartup')-lt $actualBody.IndexOf('Suspend-Original21PrebaselineCore')-and $actualBody.IndexOf('Suspend-Original21PrebaselineCore')-lt $actualBody.IndexOf('WaitActualTenantIdle')-and $actualBody.IndexOf('WaitActualTenantIdle')-lt $actualBody.IndexOf('InitializeQualificationBackupWorker'))
Verify ($node[0].Extent.StartOffset-gt $source.IndexOf('Suspend-OpenWebQualificationHealth ([ref]$qualificationHealthOriginal)'))
foreach($marker in "`$phase='laboratory HTTPS trust import'","`$phase='laboratory HTTPS worker environment'","`$phase='laboratory HTTPS endpoint startup'",'$originalWorker=RetainQualificationProcess','$heldOriginalManager=RetainQualificationProcess',"`$beforeDb=DatabaseSnapshot 'before-fault'"){
 Verify ($node[0].Extent.EndOffset-lt $source.IndexOf($marker))
}
Verify ($body-cnotmatch 'Invoke-Original21PrebaselineCoreQuiet|&\s*\$Body|-Body\s*\{')
$temp=Join-Path ([IO.Path]::GetTempPath()) ('prebaseline-main-'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory $temp|Out-Null
$caller=Join-Path $temp 'caller.ps1';[IO.File]::WriteAllText($caller,$actualBody.Substring(1,$actualBody.Length-2))
$package='SOURCE_ONLY_ORIGINAL21';$root='SOURCE_ONLY_ROOT';$state='SOURCE_ONLY_STATE'
function Suspend-Original21PrebaselineCore {param($PackageRoot)
 Verify ($PackageRoot-ceq $package);Verify $script:startupCompleted;$script:events+='suspend'
 if($mode-ceq 'suspend_failure'){throw $script:primary}
 Verify $script:coreRunning;$script:coreRunning=$false
 return $script:token
}
function Resume-Original21PrebaselineCore {param($Token)
 Verify ([object]::ReferenceEquals($Token,$script:token));$script:events+='resume'
 if($mode-cin 'resume_failure','both'){throw $script:secondary}
 $script:coreRunning=$true
}
function WaitOriginal21UpdaterStartup {param([DateTime]$DeadlineUtc)Verify $script:coreRunning;# Immutable21 Recover calls StartPbx before first Tick; model that native dependency explicitly.
 $script:coreRunning=$true;$script:startupCompleted=$true;$script:sharedDeadline=$DeadlineUtc;$script:events+='startup';if($mode-ceq 'startup_failure'){throw $script:primary}}
function WaitActualTenantIdle {param([DateTime]$DeadlineUtc)Verify (!$script:coreRunning-and $script:startupCompleted-and $DeadlineUtc-eq $script:sharedDeadline);$script:events+='tenant';if($mode-ceq 'tenant_failure'){throw $script:primary}}
function Suspend-OpenWebQualificationTenant {param([ref]$Context)Verify (!$script:coreRunning-and $script:startupCompleted);$script:events+='tenant-suspend';$Context.Value=@{Enabled=$true}}
function InitializeQualificationBackupWorker {param($Root,$StateRoot,$PackageRoot)
 Verify ($Root-ceq 'SOURCE_ONLY_ROOT'-and $StateRoot-ceq 'SOURCE_ONLY_STATE'-and $PackageRoot-ceq $package);$script:events+='warmup'
 Verify (!$script:coreRunning)
 if($mode-cin 'warmup_failure','both'){throw $script:primary}
}
function InvokeQualificationOriginal21Preamble {param($Primary,$PackageRoot)Verify ([object]::ReferenceEquals($Primary.Exception,$script:primary.Exception));return $null}
try{
 foreach($script:mode in 'success','startup_failure','tenant_failure','warmup_failure','resume_failure','both','suspend_failure','disabled'){
  $actualCandidate=$mode-cne 'canary';$OriginalTenantDomainsDisabled=$mode-ceq 'disabled';$qualificationTenantOriginal=$null
  $script:primary=[Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('PRIVATE_PRIMARY'),'primary',[Management.Automation.ErrorCategory]::NotSpecified,$null)
  $script:secondary=[Management.Automation.ErrorRecord]::new([IO.IOException]::new('PRIVATE_SECONDARY'),'secondary',[Management.Automation.ErrorCategory]::NotSpecified,$null)
  $script:events=@();$script:coreRunning=$true;$script:startupCompleted=$false;$script:token=@{fixture='private-token'};$facts=@{checks=@()};$phase='original-phase';$prebaselineCore=$null;$prebaselinePrimary=$null;$caught=$null
  $script:qualificationFailedChild=@{original='child'};$script:qualificationComparisonFailure=@{original='comparison'};$script:qualificationFailedHash=@{original='hash'}
  $output=@();try{$output=@(. $caller)}catch{$caught=$_}
  Verify ($output.Count-eq 0)
  if($mode-cin 'success','disabled','canary'){
   Verify ($null-eq $caught-and !$facts.prebaseline_core_restore_failed)
   Verify (($events-join ',')-ceq $(if($mode-ceq 'success'){'startup,suspend,tenant,warmup,resume'}else{'startup,suspend,tenant-suspend,warmup,resume'}))
   Verify ($facts.checks.Count-eq 2)
   if($mode-ceq 'disabled'){Verify (!$qualificationTenantOriginal.Enabled)}
  }else{
   Verify ($null-ne $caught)
   Verify ([object]::ReferenceEquals($caught.Exception,$(if($mode-ceq 'resume_failure'){$secondary.Exception}else{$primary.Exception})))
   Verify ((@($events|Where-Object {$_-ceq 'resume'})).Count-eq $(if($mode-cin 'startup_failure','suspend_failure'){0}else{1}))
   Verify ([bool]$facts.prebaseline_core_restore_failed-eq ($mode-cin 'resume_failure','both'))
   Verify ($phase-ceq $(if($mode-ceq 'resume_failure'){'exact original21 Core restoration before signed fixture exposure'}elseif($mode-ceq 'suspend_failure'){'exact original21 Core quiescence for tenant and backup initialization'}elseif($mode-ceq 'startup_failure'){'ordinary original21 updater startup before Core quiescence'}elseif($mode-ceq 'tenant_failure'){'natural original tenant initialization before preservation baselines'}else{'ordinary SYSTEM backup worker baseline initialization'}))
  }
 }
 # Both prior source orders must fail these executable recovery/quiet requirements.
 $goodCaller=$actualBody.Substring(1,$actualBody.Length-2)
 $startupLine='  WaitOriginal21UpdaterStartup -DeadlineUtc $initializationDeadline'
 $suspendLine='   $prebaselineCore=Suspend-Original21PrebaselineCore -PackageRoot $package'
 $tenantBlock=@'
  if(!$actualCandidate){Suspend-OpenWebQualificationTenant ([ref]$qualificationTenantOriginal)}
  elseif($OriginalTenantDomainsDisabled){Suspend-OpenWebQualificationTenant ([ref]$qualificationTenantOriginal);$qualificationTenantOriginal.Enabled=$false}
  else{$phase='natural original tenant initialization before preservation baselines';WaitActualTenantIdle -DeadlineUtc $initializationDeadline}
'@
 Verify ($goodCaller.Contains($startupLine)-and $goodCaller.Contains($suspendLine)-and $goodCaller.Contains($tenantBlock))
 $badOrders=@($goodCaller.Replace($startupLine,'').Replace($suspendLine,$suspendLine+"`n"+$startupLine),$goodCaller.Replace($tenantBlock,'').Replace($suspendLine,$tenantBlock+"`n"+$suspendLine))
 foreach($badCaller in $badOrders){
  [IO.File]::WriteAllText($caller,$badCaller);$script:mode='success';$OriginalTenantDomainsDisabled=$false;$script:events=@();$script:coreRunning=$true;$script:startupCompleted=$false;$facts=@{checks=@()};$prebaselineCore=$null;$prebaselinePrimary=$null;$denied=$null
  try{. $caller}catch{$denied=$_}
  Verify ($null-ne $denied);Verify ('warmup'-notin $events)
 }
 @{schema=1;state='passed';checks=$checks;actual_source_main_try=$true;fixture_apis_only=$true;direct_caller_scope_preserved=$true;immutable_recovery_core_start_modeled=$true;prior_unsafe_orders_refused=2;original_error_preserved=$true;product_or_host_actions=$false}|ConvertTo-Json -Compress
}finally{Remove-Item -LiteralPath $temp -Recurse -Force}
