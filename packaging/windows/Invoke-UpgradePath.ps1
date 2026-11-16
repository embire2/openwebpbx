#Requires -RunAsAdministrator
[CmdletBinding()]
param(
 [Parameter(Mandatory)][string]$RepairRoot,
 [Parameter(Mandatory)][string]$RepairManifest,
 [Parameter(Mandatory)][string]$LatestFeed,
 [Parameter(Mandatory)][string]$UpgradeCatalogue,
 [Parameter(Mandatory)][string]$HistoricalFeeds,
 [Parameter(Mandatory)][string]$ArchiveDirectory,
 [switch]$Check
)
# One-time transition for installations whose original worker predates ordered
# upgrades. Every full release still uses its ordinary transaction and backup.
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if($PSVersionTable.PSEdition -eq 'Core'){throw 'Use Windows PowerShell as Administrator.'}
$private=Join-Path $env:ProgramData OpenWebPBX
$work=Join-Path $private 'upgrade-path-repair'
$statePath=Join-Path $private 'installation.json'
$utf8=New-Object Text.UTF8Encoding($false)
$adminOwners=@('S-1-5-18','S-1-5-32-544')
$adminOwners+=@(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop|ForEach-Object {$_.SID.Value})
$publicXml='<RSAKeyValue><Modulus>t4ND9llOyYICD0sL+McQANh5/ixJ6ATyXt9/zxsvqcJICnxKAN1Vd2GxlkHgGSdAmypAWRRmpIp6SETFYGwXQbB1RVRmlTamNQhCk827M2d8WY/Q6oFPjkH6tUppLw6GgbPaCH65FJLVgE4YRvOKv2w+guVT/mDrZwtkiDbrBn6u2Qqqa6OYEEN+OwnWoP68EZh3WdOh5ecAekFciehTMAgr5YQtl/m09ekb7mtbOGzkuc3kmhkQ4aVwulkkhMaivHiLg73oWlStSMV046kfNT59G1r+0iXsDSLoM+7M4xyWKJFNnjWdeuahEVsW8lRA6yRFl2kQSuHWVLZu1yZN4X1YQtV3CtUsy8anB0AwQDBi2bIBpeDruBpw1JvtC+PQsc0RTZktuthTRsuq5aqEYc0obhVCu8kLfAmc50/ob4UIbRcRNhilA8vw4Ct/HSZCwagiDesI3dVSj6aXxcJwLdHTtoABRIslAnXUPruFNBUV8KNuTTHahYV0gr3oeKKz</Modulus><Exponent>AQAB</Exponent></RSAKeyValue>'
function Hash([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Save([string]$Path,$Value){[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 16),$utf8)}
function Ordinary([string]$Path){
 $item=Get-Item -LiteralPath $Path -Force
 if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Linked repair paths are not allowed.'}
 $item
}
function Protected([string]$Path,[string]$Boundary){
 $full=[IO.Path]::GetFullPath($Path).TrimEnd('\');$base=[IO.Path]::GetFullPath($Boundary).TrimEnd('\')
 if($full -ine $base -and !$full.StartsWith($base+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Repair inputs must be inside their protected workspace.'}
 $current=$full
 while($true){
  $null=Ordinary $current
  $acl=Get-Acl -LiteralPath $current
  if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -cnotin $adminOwners){throw 'A repair path is owned by an account outside Administrators and SYSTEM.'}
  foreach($ace in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){
   if($ace.AccessControlType -eq 'Allow' -and ([int]$ace.FileSystemRights -band 852310) -and $ace.IdentityReference.Value -cnotin 'S-1-5-18','S-1-5-32-544'){throw 'A repair input allows writes by an account outside Administrators and SYSTEM.'}
  }
  if($current -ieq $base){break};$current=Split-Path $current -Parent
 }
}
function VerifyRepair {
 $null=Ordinary $RepairManifest
 if((Get-Item $RepairManifest).Length -gt 262144){throw 'Repair metadata is too large.'}
 $outer=Get-Content -LiteralPath $RepairManifest -Raw|ConvertFrom-Json
 if($outer.key_id -cne 'release-2026-a'){throw 'The repair signing key is not trusted.'}
 $bytes=[Convert]::FromBase64String($outer.payload);$signature=[Convert]::FromBase64String($outer.signature)
 $rsa=New-Object Security.Cryptography.RSACryptoServiceProvider
 try{$rsa.FromXmlString($publicXml);if(!$rsa.VerifyData($bytes,'SHA256',$signature)){throw 'The updater repair signature is invalid.'}}finally{$rsa.Dispose()}
 $m=$utf8.GetString($bytes)|ConvertFrom-Json
 if($m.schema -ne 1 -or $m.kind -cne 'windows-updater-repair' -or $m.product -cne 'openwebpbx' -or $m.repair_id -cne 'upgrade-path-1' -or $m.version -cne '1.0.23' -or [DateTimeOffset]$m.published_at -gt [DateTimeOffset]::UtcNow.AddMinutes(5) -or [DateTimeOffset]$m.expires_at -le [DateTimeOffset]::UtcNow){throw 'The signed updater repair is unsupported or expired.'}
 $v=(Get-Content $statePath -Raw|ConvertFrom-Json).Version
 if([version]$v -lt [version]$m.minimum_installed_version -or [version]$v -gt [version]$m.maximum_installed_version){throw 'This installed version is outside the signed repair range.'}
 $prefix=[IO.Path]::GetFullPath($RepairRoot).TrimEnd('\')+'\';$count=0
 foreach($entry in $m.files.PSObject.Properties){
  if($entry.Name -cmatch '(^/|\\|:|(^|/)\.\.?(/|$))' -or $entry.Value -cnotmatch '^[a-f0-9]{64}$'){throw 'The repair inventory contains an unsafe path or hash.'}
  $path=[IO.Path]::GetFullPath((Join-Path $RepairRoot $entry.Name))
  if(!$path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'A repair path escapes its directory.'}
  $null=Ordinary $path;if((Hash $path) -cne $entry.Value){throw 'An updater repair file is damaged.'};$count++
 }
 foreach($file in Get-ChildItem $RepairRoot -Recurse -Force){$null=Ordinary $file.FullName}
 if($count -ne @(Get-ChildItem $RepairRoot -Recurse -File -Force).Count -or !$m.files.PSObject.Properties['OpenWebPbx.Updater.exe']){throw 'The updater repair inventory is incomplete.'}
 $m
}
function Run([string]$Exe,[string[]]$Arguments){
 & $Exe @Arguments
 if($LASTEXITCODE -ne 0){throw ('The update helper refused the operation (exit '+$LASTEXITCODE+'). Its original log and recovery journal are retained.')}
}
function Plan {
 $json=& (Join-Path $RepairRoot 'OpenWebPbx.Updater.exe') --verify-windows-upgrade-path --latest-feed-envelope $LatestFeed --upgrade-catalogue $UpgradeCatalogue --historical-feeds $HistoricalFeeds
 if($LASTEXITCODE){throw 'The ordered release signatures or trust history could not be verified.'}
 $json|ConvertFrom-Json
}
function CheckArchives($Plan){
 foreach($step in $Plan.steps){
  if($step.asset.platform -cne 'windows-x64' -or $step.asset.name -cnotmatch '^openwebpbx-[0-9]+\.[0-9]+\.[0-9]+-windows-x64\.zip$'){throw 'The signed release is not a supported Windows archive.'}
  $path=Join-Path $ArchiveDirectory $step.asset.name;$null=Ordinary $path
  if((Get-Item $path).Length -ne $step.asset.bytes -or (Hash $path) -cne $step.asset.sha256){throw 'A complete signed release must be downloaded and verified before updating.'}
 }
}
function PatchUpdater {
 # Keep the existing numeric slot identity and its stock bytes. The normal
 # installer remains strict about immutable slots; this is an explicit repair.
 $m=VerifyRepair
 $maintenance=$null;$receipt=$null
 try{
  $maintenance=[IO.File]::Open("$private\upgrade.lock",'OpenOrCreate','ReadWrite','None')
 $state=Get-Content $statePath -Raw|ConvertFrom-Json
 $selection=Get-Content "$private\updater-install.json" -Raw|ConvertFrom-Json
 $expected='C:\OpenWebPBX\updater\slots\'+$state.Version+'\OpenWebPbx.Updater.exe'
 $service=Get-CimInstance Win32_Service -Filter "Name='OpenWebPBXUpdater'"
 if($selection.Version -cne $state.Version -or $selection.Executable -ine $expected -or $service.PathName.Trim('"') -ine $expected -or $service.StartName -cnotin 'LocalSystem','NT AUTHORITY\SYSTEM'){throw 'The selected updater does not belong to this installation.'}
 Stop-Service OpenWebPBXUpdater -ErrorAction Stop
 (Get-Service OpenWebPBXUpdater).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(90))
 $slot=Split-Path $expected -Parent
 Protected $slot 'C:\OpenWebPBX\updater'
 $original=Join-Path $work ('original-slots\'+$state.Version)
 $receipt=Join-Path $original 'slot-inventory.json'
 if(Test-Path $receipt){
  $old=Get-Content $receipt -Raw|ConvertFrom-Json
  foreach($entry in $old.files.PSObject.Properties){if((Hash (Join-Path "$original\files" $entry.Name)) -cne $entry.Value){throw 'An original updater rollback file changed.'}}
 }else{
  New-Item -ItemType Directory -Force "$original\files"|Out-Null
  $files=@{};foreach($file in Get-ChildItem $slot -Recurse -File -Force){$rel=$file.FullName.Substring($slot.Length+1);$files[$rel]=Hash $file.FullName}
  & robocopy.exe $slot "$original\files" /E /COPY:DAT /DCOPY:T /R:1 /W:1 /NFL /NDL /NJH /NJS /NP|Out-Null
  if($LASTEXITCODE -ge 8){throw 'The original updater could not be retained.'}
  foreach($entry in $files.GetEnumerator()){if((Hash (Join-Path "$original\files" $entry.Key)) -cne $entry.Value){throw 'The original updater copy did not verify.'}}
  Save $receipt @{schema=1;version=$state.Version;files=$files}
 }
  foreach($file in Get-ChildItem $slot -Recurse -Force){$null=Ordinary $file.FullName}
  & robocopy.exe $RepairRoot $slot /MIR /COPY:DAT /DCOPY:T /R:1 /W:1 /NFL /NDL /NJH /NJS /NP|Out-Null
  if($LASTEXITCODE -ge 8){throw 'The signed updater component could not be installed.'}
  foreach($entry in $m.files.PSObject.Properties){if((Hash (Join-Path $slot $entry.Name)) -cne $entry.Value){throw 'The installed updater repair did not verify.'}}
  Save (Join-Path $work 'installed-component.json') @{schema=1;repair_id=$m.repair_id;installed_version=$state.Version;manifest_sha256=(Hash $RepairManifest);original_slot=$original;installed_at=[DateTime]::UtcNow.ToString('o')}
 }catch{
  $failure=$_
  if($maintenance -and $receipt -and (Test-Path $receipt)){
   & robocopy.exe "$original\files" $slot /MIR /COPY:DAT /DCOPY:T /R:1 /W:1 /NFL /NDL /NJH /NJS /NP|Out-Null
   if($LASTEXITCODE -ge 8){throw 'Updater component recovery requires administrator review; original files remain retained.'}
  }
  throw $failure
 }finally{if($maintenance){$maintenance.Dispose()}}
}
New-Item -ItemType Directory -Force $work,"$work\logs"|Out-Null
$null=Ordinary $work
& icacls.exe $work /inheritance:r /grant '*S-1-5-32-544:(OI)(CI)F' /grant '*S-1-5-18:(OI)(CI)F'|Out-Null
if($LASTEXITCODE){throw 'The repair workspace could not be protected.'}
foreach($inputPath in $RepairRoot,$RepairManifest,$LatestFeed,$UpgradeCatalogue,$HistoricalFeeds,$ArchiveDirectory){Protected $inputPath $work}
foreach($item in Get-ChildItem $RepairRoot -Recurse -Force){Protected $item.FullName $work}
$single=[IO.File]::Open((Join-Path $work 'transition.lock'),'OpenOrCreate','ReadWrite','None')
$priorCatalogue=$env:OPENWEBPBX_UPGRADE_CATALOGUE;$priorLatest=$env:OPENWEBPBX_UPGRADE_LATEST
$ordinaryTrust="$private\updates\trust.json";$trustBefore=if(Test-Path $ordinaryTrust){Hash $ordinaryTrust}else{$null}
try{
 $null=VerifyRepair
 $downloadHelper=Join-Path $PSScriptRoot 'UpgradePath.Download.ps1'
 Protected $downloadHelper $work
 . $downloadHelper
 $plan=Plan
 foreach($step in @($plan.steps)){$null=Get-OpenWebUpgradePathArchive -Asset $step.asset -ArchiveDirectory $ArchiveDirectory}
 CheckArchives $plan
 Save (Join-Path $work 'verified-plan.json') $plan
 if($Check){Write-Host ('Signed Windows upgrade path: '+$plan.installed_version+' -> '+(($plan.steps|ForEach-Object version)-join ' -> '));return}
 $steps=@();$initial=$plan.installed_version
 foreach($offered in @($plan.steps)){
  $current=Plan
  if(!$current.steps -or $current.steps[0].version -cne $offered.version){throw 'The installed version or signed upgrade path changed.'}
  $null=VerifyRepair;CheckArchives $current
  # Preserve at least10GiB beyond a full expanded release and current app backup.
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $archive=Join-Path $ArchiveDirectory $offered.asset.name
  $zip=[IO.Compression.ZipFile]::OpenRead($archive)
  try{$expanded=($zip.Entries|Measure-Object Length -Sum).Sum}finally{$zip.Dispose()}
  $appBytes=(Get-ChildItem 'C:\OpenWebPBX' -Recurse -File -Force|Measure-Object Length -Sum).Sum
  if((Get-PSDrive C).Free -lt (10GB+$expanded+$appBytes)){throw 'Free disk space is too low to preserve the10GiB recovery reserve.'}
  PatchUpdater
  $stepFeed=Join-Path $work ('step-'+$offered.version+'.json')
  [IO.File]::WriteAllBytes($stepFeed,[Convert]::FromBase64String($offered.envelope))
  $env:OPENWEBPBX_UPGRADE_CATALOGUE=$UpgradeCatalogue;$env:OPENWEBPBX_UPGRADE_LATEST=$LatestFeed
  $arguments=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File','C:\OpenWebPBX\tools\Upgrade-OpenWebPBX.ps1','-Archive',$archive,'-FeedEnvelope',$stepFeed,'-TargetVersion',$offered.version)
  # The ordinary transaction performs its full signed preflight before stopping
  # services. Avoid a second extraction of the same large package here.
  Run 'powershell.exe' $arguments
  Stop-Service OpenWebPBXUpdater -ErrorAction Stop
  $installed=(Get-Content $statePath -Raw|ConvertFrom-Json).Version
  $journal=Get-Content "$private\updates\install-journal.json" -Raw|ConvertFrom-Json
  if($installed -cne $offered.version -or $journal.state -cne 'completed'){throw 'The normal release transaction has not completed; its recovery owns the installation.'}
  $steps+=@{version=$installed;completed_at=[DateTime]::UtcNow.ToString('o');archive_sha256=$offered.asset.sha256}
  Save (Join-Path $work 'transition-result.json') @{schema=1;from_version=$initial;target_version=$plan.latest_version;state='between_steps';steps=$steps}
 }
 PatchUpdater
 $trustNow=Get-Content $ordinaryTrust -Raw|ConvertFrom-Json
 if($trustNow.sequence -ne $plan.ordinary_trust_floor.sequence -or $trustNow.payload_sha256 -cne $plan.ordinary_trust_floor.payload_sha256){throw 'The verified latest release trust floor was not retained; review before starting updates.'}
 Start-Service OpenWebPBXUpdater
 (Get-Service OpenWebPBXUpdater).WaitForStatus('Running',[TimeSpan]::FromSeconds(90))
 Save (Join-Path $work 'transition-result.json') @{schema=1;from_version=$initial;target_version=$plan.latest_version;state='completed';steps=$steps;ordinary_trust_preserved=$true}
 Write-Host ('Windows updated in signed order to '+$plan.latest_version+'. The automatic updater is running.')
}finally{
 $env:OPENWEBPBX_UPGRADE_CATALOGUE=$priorCatalogue;$env:OPENWEBPBX_UPGRADE_LATEST=$priorLatest
 $single.Dispose()
}
