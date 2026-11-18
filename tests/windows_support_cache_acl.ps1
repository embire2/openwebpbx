# Legacy sealed ACL inventories may name cache children cleared by the update.
[CmdletBinding()]
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent),[string]$FixtureParent=$env:TEMP,[string]$Output)
$ErrorActionPreference='Stop';$checks=0;$junctions=@()
function Check([bool]$Value){if(!$Value){throw 'Generated cache recovery control failed.'};$script:checks++}
function Refuse([scriptblock]$Action){try{& $Action|Out-Null}catch{$script:checks++;return};throw 'An unsafe generated cache recovery path was accepted.'}
$source=Join-Path $SourceRoot 'packaging\windows\Support-Recovery.ps1';$sourceHash=(Get-FileHash $source -Algorithm SHA256).Hash.ToLowerInvariant()
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors);Check ($errors.Count -eq 0)
. (Join-Path $SourceRoot 'packaging\windows\UpgradeRecovery.Common.ps1')
$found=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Test-OpenWebMissingGeneratedCacheAcl'},$true));Check ($found.Count -eq 1)
. ([scriptblock]::Create($found[0].Extent.Text))
$restore=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Restore-OpenWebSupport'},$true)
$aclLoop=@($restore.FindAll({param($n)$n -is [Management.Automation.Language.ForEachStatementAst] -and $n.Condition.Extent.Text -ceq '$record.Acls.PSObject.Properties'},$true));Check ($aclLoop.Count -eq 1)
$inspectAcl=[scriptblock]::Create($aclLoop[0].Extent.Text)
# Run the actual ACL admission loop, before the separate security writer loop.
# The outer path allowlist is covered independently; this fixture returns its
# already owned absolute path and never applies a descriptor.
function Check-SupportPath([string]$Path){return [IO.Path]::GetFullPath($Path)}
function Inspect([string]$Path,$Value){
 $entries=@{};$entries[$Path]=$Value;$record=[pscustomobject]@{Acls=[pscustomobject]$entries};$permissions=New-Object 'Collections.Generic.List[object]';$StateRoot=$script:state
 & $script:inspectAcl
 return $permissions.Count
}
$fixture=Join-Path $FixtureParent ('openweb-cache-acl-'+[guid]::NewGuid().ToString('N'));$state=Join-Path $fixture 'state';$cache=Join-Path $state 'cache';$outside=Join-Path $fixture 'outside'
try{
 $null=New-Item -ItemType Directory -Path $cache,$outside
 Check (Test-OpenWebMissingGeneratedCacheAcl -Path (Join-Path $cache 'dialplan.mode') -StateRoot $state)
 Check (Test-OpenWebMissingGeneratedCacheAcl -Path (Join-Path $cache 'missing-parent\generated') -StateRoot $state)
 Check (!(Test-OpenWebMissingGeneratedCacheAcl -Path $cache -StateRoot $state))
 $file=Join-Path $cache 'existing';[IO.File]::WriteAllText($file,'owned cache fixture')
 Check (!(Test-OpenWebMissingGeneratedCacheAcl -Path $file -StateRoot $state))
 $nested=Join-Path $cache 'existing-directory';$null=New-Item -ItemType Directory $nested
 Check (!(Test-OpenWebMissingGeneratedCacheAcl -Path $nested -StateRoot $state))
 $sddl=(Get-Acl $file).Sddl;$missing=Join-Path $cache 'dialplan.mode'
 Check ((Inspect -Path $missing -Value $sddl) -eq 0)
 Check ((Inspect -Path $file -Value $sddl) -eq 1)
 foreach($bad in @('',42,('x'*131073),'not-sddl','D:(A;;FA;;;SY)','O:BAG:SY')){Refuse {Inspect -Path $missing -Value $bad}}
 Refuse {Inspect -Path (Join-Path $state 'config\missing') -Value $sddl}
 foreach($name in 'sessions','config','storage','tenant-backups','protection','cache-other'){
  Check (!(Test-OpenWebMissingGeneratedCacheAcl -Path (Join-Path $state ($name+'\missing')) -StateRoot $state))
 }
 Check (!(Test-OpenWebMissingGeneratedCacheAcl -Path (Join-Path $outside 'missing') -StateRoot $state))
 Check (!(Test-OpenWebMissingGeneratedCacheAcl -Path ($cache+'\..\config\missing') -StateRoot $state))
 Check (!(Test-OpenWebMissingGeneratedCacheAcl -Path ($cache+'\existing-directory\..\missing') -StateRoot $state))
 Refuse {Test-OpenWebMissingGeneratedCacheAcl -Path ($cache+'\missing:stream') -StateRoot $state}
 foreach($name in 'wild*card','wild?card'){
  Refuse {Test-OpenWebMissingGeneratedCacheAcl -Path ($cache+'\'+$name) -StateRoot $state}
 }
 Refuse {Test-OpenWebMissingGeneratedCacheAcl -Path ($file+'\missing') -StateRoot $state}
 Refuse {Test-OpenWebMissingGeneratedCacheAcl -Path ($cache+'\missing'+[char]0) -StateRoot $state}
 $link=Join-Path $cache 'junction';$null=New-Item -ItemType Junction -Path $link -Target $outside;$junctions+=$link
 Refuse {Test-OpenWebMissingGeneratedCacheAcl -Path (Join-Path $link 'missing') -StateRoot $state}
 Refuse {Test-OpenWebMissingGeneratedCacheAcl -Path $link -StateRoot $state}
 Refuse {Inspect -Path $link -Value $sddl}
 $broken=Join-Path $cache 'broken-junction';$null=New-Item -ItemType Junction -Path $broken -Target $outside;$junctions+=$broken
 [IO.Directory]::Delete($outside,$false)
 Refuse {Test-OpenWebMissingGeneratedCacheAcl -Path (Join-Path $broken 'missing') -StateRoot $state}
 foreach($j in $junctions){[IO.Directory]::Delete($j,$false)};$junctions=@()
 $saved=Join-Path $state 'cache-before';Move-Item -LiteralPath $cache -Destination $saved
 Refuse {Test-OpenWebMissingGeneratedCacheAcl -Path (Join-Path $cache 'missing') -StateRoot $state}
 $null=New-Item -ItemType Junction -Path $cache -Target $saved;$junctions+=$cache
 Refuse {Test-OpenWebMissingGeneratedCacheAcl -Path (Join-Path $cache 'missing') -StateRoot $state}
 [IO.Directory]::Delete($cache,$false);$junctions=@();Move-Item -LiteralPath $saved -Destination $cache
 $stateLink=Join-Path $fixture 'state-link';$null=New-Item -ItemType Junction -Path $stateLink -Target $state;$junctions+=$stateLink
 Refuse {Test-OpenWebMissingGeneratedCacheAcl -Path (Join-Path $stateLink 'cache\missing') -StateRoot $stateLink}
 Check ((Get-FileHash $source -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $sourceHash)
 $result=[ordered]@{passed=$true;controls=$checks;source_sha256=$sourceHash;scope='missing generated cache descendants only';outside_cache_missing_targets_refuse=$true;cache_root_and_ancestors_required_ordinary=$true;junctions_refused=$true;product_or_recovery_writers_called=$false;actual_ps_version=$PSVersionTable.PSVersion.ToString()}
 if($Output){[IO.File]::WriteAllText($Output,($result|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))}
 $result|ConvertTo-Json -Compress
}finally{
 foreach($j in $junctions){if(Get-Item -LiteralPath $j -Force -ErrorAction SilentlyContinue){[IO.Directory]::Delete($j,$false)}}
 if(Test-Path -LiteralPath $fixture){Remove-Item -LiteralPath $fixture -Recurse -Force}
}
