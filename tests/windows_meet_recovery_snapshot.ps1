# Actual recovery-body controls. -NativeMwa edits only private fixture configs;
# the default explicitly doubles MWA and still uses real XML/file/hash helpers.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent),[switch]$NativeMwa)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest;$script:checks=0
function Check([bool]$Value){if(!$Value){throw ('Meeting snapshot control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
function Refuses([scriptblock]$Action){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Check $failed}
$helper=Join-Path $SourceRoot 'packaging/windows/Meet-Proxy.ps1';. $helper
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($helper,[ref]$tokens,[ref]$errors);Check ($errors.Count -eq 0)
$restore=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Restore-OpenWebMeetSystem'},$true));Check ($restore.Count -eq 1)
$bodies=@($restore[0].FindAll({param($n)$n -is [Management.Automation.Language.TryStatementAst] -and $n.Body.Extent.Text.Contains("`$section=`$manager.GetApplicationHostConfiguration().GetSection('system.webServer/proxy')")},$true));Check ($bodies.Count -eq 1)
$text=$bodies[0].Body.Extent.Text;$currentAction=[scriptblock]::Create($text.Substring(1,$text.Length-2))
$oldAction=[scriptblock]::Create([IO.File]::ReadAllText((Join-Path $SourceRoot 'tests/fixtures/windows-meet-proxy-before-snapshot.ps1')))
$script:originalXml=${function:Get-OpenWebMeetProxyXmlState}
function Get-OpenWebMeetProxyXmlState {& $script:originalXml $script:fixture}
function New-Snapshot([bool]$Enabled,[string]$Xml,[bool]$Present,[switch]$Historical){
 $r=[pscustomobject]@{Proxy=[pscustomobject]@{Exists=$true;Enabled=$Enabled;PreserveHostHeader=$false}}
 if(!$Historical){$r|Add-Member NoteProperty ProxyXml $Xml;$r|Add-Member NoteProperty ProxyEnabledPresent $Present};return $r
}
function Write-Fixture([string]$Xml){[IO.File]::WriteAllText($script:fixture,('<configuration><configSections><sectionGroup name="system.webServer"><section name="proxy" allowDefinition="AppHostOnly" overrideModeDefault="Deny" /></sectionGroup></configSections><system.webServer>'+$Xml+'</system.webServer></configuration>'))}
function New-FixtureManager {
 if($NativeMwa){return [Microsoft.Web.Administration.ServerManager]::new($script:fixture)}
 $proxy=Read-OpenWebMeetProxyXmlChoice (Get-OpenWebMeetProxyXmlState).Xml
 $script:section=@{enabled=$proxy.Enabled;preserveHostHeader=$false;__present=$proxy.EnabledPresent;__revert=$false}
 $attribute=[pscustomobject]@{};$attribute|Add-Member ScriptMethod Delete {$script:section.__present=$false}
 $script:section.Attributes=@{enabled=$attribute}
 $script:section|Add-Member ScriptMethod GetSection {param($Name) return $this}
 $script:section|Add-Member ScriptMethod RevertToParent {$script:section.__revert=$true}
 $manager=[pscustomobject]@{}
 $manager|Add-Member ScriptMethod GetApplicationHostConfiguration {return $script:section}
 $manager|Add-Member ScriptMethod CommitChanges {
  $script:commits++;$xml=[xml][IO.File]::ReadAllText($script:fixture);$node=$xml.configuration.'system.webServer'.proxy
  if($script:section.__revert){$null=$node.ParentNode.RemoveChild($node)}
  elseif(!$script:section.__present){$node.RemoveAttribute('enabled')}
  else{$node.SetAttribute('enabled',([string]$script:section.enabled).ToLowerInvariant())}
  $xml.Save($script:fixture)
 }
 return $manager
}
$directory=Join-Path ([IO.Path]::GetTempPath()) ('openweb-meet-snapshot-'+[Guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($directory)
if($NativeMwa){
 if($PSVersionTable.PSEdition -ne 'Desktop'){throw 'Actual MWA requires native Windows PowerShell.'}
 & icacls.exe $directory /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F'|Out-Null;if($LASTEXITCODE){throw 'Private fixture permissions refused.'}
 Add-Type -Path "$env:windir\System32\inetsrv\Microsoft.Web.Administration.dll"
}
$script:fixture=Join-Path $directory 'applicationHost.config'
$falseXml='<proxy enabled="false" timeout="00:01:30"><cache enabled="false" /></proxy>';$trueXml=$falseXml.Replace('enabled="false" timeout','enabled="true" timeout');$absentAttribute='<proxy timeout="00:01:30"><cache enabled="false" /></proxy>'
try{
 # The exact original body disables an already installed proxy after upgrade
 # rollback. The new body preserves it using both modern and historical inputs.
 foreach($mode in 'old','current-new','current-historical'){
  Write-Fixture $trueXml;$current=Get-OpenWebMeetProxyXmlState;$manager=New-FixtureManager;$script:commits=0
  $before=New-Snapshot $true $trueXml $true -Historical:($mode -ceq 'current-historical')
  $ledger=[pscustomobject]@{ProxyBeforeXml=$falseXml;ProxyAfterXml=$trueXml;ProxyEnabledBeforePresent=$true;ProxyEnabledBefore=$false}
  try{if($mode -ceq 'old'){. $oldAction}else{. $currentAction}}finally{if($NativeMwa){$manager.Dispose()}}
  Check ((Get-OpenWebMeetProxyXmlState).Enabled -eq ($mode -cne 'old'))
  Check ((Get-OpenWebMeetProxyXmlState).Xml -ceq $(if($mode -ceq 'old'){$falseXml}else{$trueXml}))
 }
 foreach($row in @(@('disabled',$falseXml,$true),@('absent-attribute',$absentAttribute,$false),@('absent-section','',$false))){
  foreach($historical in $false,$true){
   $original=[string]$row[1];$planned=if($original){Get-OpenWebMeetEnabledProxyXml (Read-OpenWebMeetProxyXmlChoice $original)}else{'<proxy enabled="true" />'}
   Write-Fixture $planned;$current=Get-OpenWebMeetProxyXmlState;$manager=New-FixtureManager
   $before=New-Snapshot $false $original ([bool]$row[2]) -Historical:$historical
   $ledger=[pscustomobject]@{ProxyBeforeXml=$original;ProxyAfterXml=$planned;ProxyEnabledBeforePresent=[bool]$row[2];ProxyEnabledBefore=$false}
   try{. $currentAction}finally{if($NativeMwa){$manager.Dispose()}}
   Check ((Get-OpenWebMeetProxyXmlState).Xml -ceq $original)
  }
 }
 foreach($case in 'foreign-current','foreign-snapshot','full-config-race','historical-ambiguous'){
  Write-Fixture $trueXml;$current=Get-OpenWebMeetProxyXmlState
  $before=New-Snapshot $true $trueXml $true;$ledger=[pscustomobject]@{ProxyBeforeXml=$falseXml;ProxyAfterXml=$trueXml;ProxyEnabledBeforePresent=$true;ProxyEnabledBefore=$false}
  if($case -ceq 'foreign-current'){Write-Fixture ($trueXml.Replace('00:01:30','00:02:30'));$current=Get-OpenWebMeetProxyXmlState}
  if($case -ceq 'foreign-snapshot'){$before.ProxyXml=$trueXml.Replace('00:01:30','00:02:30')}
  if($case -ceq 'historical-ambiguous'){$before=New-Snapshot $false '' $false -Historical;$ledger.ProxyAfterXml=$falseXml.Replace('00:01:30','00:02:30');Write-Fixture $ledger.ProxyAfterXml;$current=Get-OpenWebMeetProxyXmlState}
  if($case -ceq 'full-config-race'){$before=New-Snapshot $false $falseXml $true;[IO.File]::AppendAllText($script:fixture,'<!-- concurrent unrelated configuration -->')}
  $beforeHash=(Get-FileHash -LiteralPath $script:fixture).Hash;$beforeWriteTime=(Get-Item -LiteralPath $script:fixture).LastWriteTimeUtc.Ticks;$manager=New-FixtureManager;$script:commits=0
  try{Refuses {. $currentAction}}finally{if($NativeMwa){$manager.Dispose()}}
  Check ((Get-FileHash -LiteralPath $script:fixture).Hash -ceq $beforeHash)
  Check ((Get-Item -LiteralPath $script:fixture).LastWriteTimeUtc.Ticks -eq $beforeWriteTime -and ($NativeMwa -or $script:commits -eq 0))
 }
 $ledger=[pscustomobject]@{ProxyBeforeXml=$falseXml;ProxyAfterXml=$trueXml}
 foreach($field in 'ProxyXml','ProxyEnabledPresent'){
  foreach($bad in $null,1,@{},@('true')){$before=New-Snapshot $true $trueXml $true;$before.$field=$bad;Refuses {Get-OpenWebMeetRecoveryProxyChoice $before $ledger}}
 }
 $before=New-Snapshot $false $trueXml $true;Refuses {Get-OpenWebMeetRecoveryProxyChoice $before $ledger}
 foreach($xml in '<proxy enabled="unknown" />','<proxy enabled="true"/>','<foreign />','<!DOCTYPE proxy [<!ENTITY x "x">]><proxy>&x;</proxy>',('<proxy extra="'+('a'*1048576)+'" />')){Refuses {Read-OpenWebMeetProxyXmlChoice $xml}}
 foreach($field in 'ProxyBeforeXml','ProxyAfterXml'){foreach($bad in $null,$true,1,@{},@($trueXml)){$badLedger=[pscustomobject]@{ProxyBeforeXml=$falseXml;ProxyAfterXml=$trueXml};$badLedger.$field=$bad;Refuses {Get-OpenWebMeetRecoveryProxyChoice (New-Snapshot $true $trueXml $true) $badLedger}}}
 # Execute the actual Save assignment: unsupported oversized XML refuses before
 # Write-PrivateState, closing the save-accepted/recovery-refused bound mismatch.
 $save=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Save-OpenWebMeetSystem'},$true))[0]
 $assignment=@($save.FindAll({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$proxySnapshot'},$true));Check ($assignment.Count -eq 1)
 Write-Fixture ('<proxy extra="'+('a'*1048576)+'" />');Refuses {Invoke-Expression $assignment[0].Extent.Text}
 [ordered]@{schema=1;state='passed';checks=$checks;actual_source_restore_body=$true;old_enabled_to_disabled_proven=$true;new_snapshot_and_historical_preserved=$true;initial_install_undo=$true;foreign_xml_and_full_config_refused=$true;native_mwa=[bool]$NativeMwa;mwa_adapter_double=(!$NativeMwa);installed_iis_changed=$false}|ConvertTo-Json -Compress
}finally{Remove-Item -LiteralPath $directory -Recurse -Force}
