# Execute the actual versioned guards from both restore/updater entry points.
# No Windows installation, task, network request or signed package is simulated.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$script:checks=0
function Assert([bool]$Value){if(!$Value){throw ('Modern baseline control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
function Check([bool]$Value,[string]$Message){$script:guardCalls++;if(!$Value){throw 'EXACT_CURRENT_BASELINE_REFUSAL'}}
$modern=@('web_readiness','tenant_domains','meeting_transport','meeting_browser','phone_health','stun','native_clock','native_providers','native_call_me_back')
foreach($consumer in 'windows-updater-qualification.ps1','windows-restore-qualification.ps1'){
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot ('tests/'+$consumer)),[ref]$tokens,[ref]$errors);Assert ($errors.Count -eq 0)
 $nodes=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith('if([version]$BaseVersion -ge ') -and $node.Extent.Text.Contains("'web_readiness'")},$true));Assert ($nodes.Count -eq 1)
 $guard=[scriptblock]::Create($nodes[0].Extent.Text)
 foreach($version in '1.0.20','1.0.21'){
  $BaseVersion=$version;$values=@{};foreach($gate in $modern){$values[$gate]='passed'};$baseFacts=[pscustomobject]@{gates=[pscustomobject]$values}
  $script:guardCalls=0;& $guard;Assert ($script:guardCalls -eq 9)
  foreach($gate in $modern){
   $badValues=@($null,$true,$false,0,1,'Passed','passed ','partial','running','unqualified',@('passed'),@('passed','unqualified'),@{},[pscustomobject]@{state='passed'})
   foreach($bad in $badValues){
    $baseFacts.gates.$gate=$bad;$caught=$null;$script:guardCalls=0;try{& $guard}catch{$caught=$_.Exception.Message}
    Assert ($caught -ceq 'EXACT_CURRENT_BASELINE_REFUSAL' -and $script:guardCalls -ge 1 -and $script:guardCalls -le 9)
   }
   $baseFacts.gates.PSObject.Properties.Remove($gate);$caught=$null;try{& $guard}catch{$caught=$_.Exception.Message};Assert ($caught -ceq 'EXACT_CURRENT_BASELINE_REFUSAL')
   $baseFacts.gates|Add-Member -NotePropertyName $gate -NotePropertyValue 'passed'
  }
  $script:guardCalls=0;& $guard;Assert ($script:guardCalls -eq 9)
 }
 $BaseVersion='1.0.13';$baseFacts=[pscustomobject]@{gates=[pscustomobject]@{}};$script:guardCalls=0;& $guard;Assert ($script:guardCalls -eq 0)
}
Write-Output ('PASS '+$checks+' actual modern restore/updater baseline guard controls; current nine gates require exact string passed, historical13 branch unchanged')
