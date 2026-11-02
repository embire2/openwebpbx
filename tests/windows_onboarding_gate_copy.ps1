# Exact payload hook / immutable21 script rollback component; private fixtures only.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent),[Parameter(Mandatory)][string]$LegacyUpgradeSource,[string]$WorkRoot)
$ErrorActionPreference='Stop';$checks=0;$native=[Environment]::OSVersion.Platform-eq [PlatformID]::Win32NT
function Verify([bool]$v){if(!$v){throw ('Call-gate copy control '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
function Hash([string]$p){(Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()}
function ImportFunction([string]$Path,[string]$Name){
 $t=$null;$e=$null;$a=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$t,[ref]$e);Verify (!$e.Count)
 $n=@($a.FindAll({param($x)$x-is [Management.Automation.Language.FunctionDefinitionAst] -and $x.Name-ceq $Name},$true));Verify ($n.Count-eq 1);return $n[0].Extent.Text
}
Invoke-Expression (ImportFunction (Join-Path $SourceRoot 'packaging/windows/PublicAccess.Common.ps1') 'Assert-OpenWebOrdinaryPath')
Invoke-Expression (ImportFunction (Join-Path $SourceRoot 'packaging/windows/Install-TenantDomains.ps1') 'Install-OpenWebOnboardingCallGate')
Verify ((Hash $LegacyUpgradeSource)-ceq 'b54d22c469ca2cbd8747787835c0056a562162cc3e5682b25106bd805826d4e2')
$legacy=[IO.File]::ReadAllText($LegacyUpgradeSource)
$backupLine='CopyTree "$switch\scripts" "$backup\switch-scripts"';$hookLine='& "$payload\Install-TenantDomains.ps1" -PackageRoot $payload -DeferStart -MaintenanceLock $lock'
Verify ($legacy.IndexOf($backupLine)-ge 0 -and $legacy.IndexOf($hookLine)-gt $legacy.IndexOf($backupLine))
Verify ($legacy.Contains('CopyTree "$Backup\switch-scripts" "$switch\scripts" -Mirror'))
Invoke-Expression (ImportFunction $LegacyUpgradeSource 'CopyTree')
$fresh=[IO.File]::ReadAllText((Join-Path $SourceRoot 'packaging/windows/Install-OpenWebPBX.ps1'))
$upgrade=[IO.File]::ReadAllText((Join-Path $SourceRoot 'packaging/windows/Upgrade-OpenWebPBX.ps1'))
Verify ($fresh.Contains('Copy-Item "$root\web\app\pbx_setup\resources\switch\scripts\app\pbx_onboarding\gate.lua" "$switch\scripts\app\pbx_onboarding\gate.lua" -Force'))
Verify (($upgrade.Split([string[]]@('CopyTree "$root\web\app\pbx_setup\resources\switch\scripts\app\pbx_onboarding" "$switch\scripts\app\pbx_onboarding"'),[StringSplitOptions]::None).Count-1)-eq 2)
$hook=[IO.File]::ReadAllText((Join-Path $SourceRoot 'packaging/windows/Install-TenantDomains.ps1'))
Verify ($hook.Contains("Install-OpenWebOnboardingCallGate -PackageRoot `$PackageRoot -EngineRoot 'C:\Program Files\FreeSWITCH' -Manifest `$manifest"))
Verify ($hook.IndexOf('if(!$lock.CanRead')-lt $hook.LastIndexOf(' Install-OpenWebOnboardingCallGate '))
if(!$WorkRoot){$WorkRoot=Join-Path ([IO.Path]::GetTempPath()) ('openweb-callgate-'+[guid]::NewGuid().ToString('N'))}
Verify (!(Test-Path -LiteralPath $WorkRoot));New-Item -ItemType Directory -Path $WorkRoot|Out-Null
$relative='web/app/pbx_setup/resources/switch/scripts/app/pbx_onboarding/gate.lua'
function Fixture {
 $d=Join-Path $WorkRoot ([guid]::NewGuid().ToString('N'));$package=Join-Path $d 'payload';$engine=Join-Path $d 'engine';$source=Join-Path $package $relative
 New-Item -ItemType Directory -Force (Split-Path $source -Parent),(Join-Path $engine 'scripts/app/customer')|Out-Null
 Copy-Item -LiteralPath (Join-Path $SourceRoot 'app/pbx_setup/resources/switch/scripts/app/pbx_onboarding/gate.lua') -Destination $source
 $custom=Join-Path $engine 'scripts/app/customer/custom.lua';[IO.File]::WriteAllText($custom,'original customer script',[Text.UTF8Encoding]::new($false))
 $private=Join-Path $d 'private-key-sentinel';[IO.File]::WriteAllText($private,'unrelated private fixture',[Text.UTF8Encoding]::new($false))
 return @{directory=$d;package=$package;engine=$engine;source=$source;custom=$custom;private=$private;manifest=@{files=@{$relative=(Hash $source)}};gate=(Join-Path $engine 'scripts/app/pbx_onboarding/gate.lua')}
}
function Inventory($Path){
 $map=@{};foreach($f in @(Get-Item -LiteralPath $Path -Force)+@(Get-ChildItem -LiteralPath $Path -Recurse -Force)){
  $name=$f.FullName.Substring([IO.Path]::GetFullPath($Path).Length);$record=if($f.PSIsContainer){'directory'}else{Hash $f.FullName}
  if($native){$record+='|'+(Get-Acl -LiteralPath $f.FullName).Sddl};$map[$name]=$record
 };return $map
}
function Exact($A,$B){Verify ($A.Count-eq $B.Count);foreach($p in $A.Keys){Verify ($B.ContainsKey($p) -and $A[$p]-ceq $B[$p])}}
function Refuse([scriptblock]$Change){$f=Fixture;& $Change $f;$failed=$false;try{Install-OpenWebOnboardingCallGate $f.package $f.engine $f.manifest}catch{$failed=$true};Verify $failed;Verify (!(Test-Path -LiteralPath $f.gate))}
try{
 foreach($preexisting in $false,$true){
  $f=Fixture
  if($preexisting){$sibling=Join-Path (Split-Path $f.gate -Parent) 'custom.lua';New-Item -ItemType Directory (Split-Path $sibling -Parent)|Out-Null;[IO.File]::WriteAllText($sibling,'pre-existing sibling',[Text.UTF8Encoding]::new($false))}
  $before=Inventory (Join-Path $f.engine 'scripts');$customHash=Hash $f.custom;$privateHash=Hash $f.private;$backup=Join-Path $f.directory 'sealed-switch-scripts'
  if($native){CopyTree (Join-Path $f.engine 'scripts') $backup}else{Copy-Item -LiteralPath (Join-Path $f.engine 'scripts') -Destination $backup -Recurse}
  Install-OpenWebOnboardingCallGate $f.package $f.engine $f.manifest
  Verify ((Hash $f.gate)-ceq $f.manifest.files.$relative);Verify ((Hash $f.custom)-ceq $customHash -and (Hash $f.private)-ceq $privateHash)
  $after=Inventory (Join-Path $f.engine 'scripts');foreach($p in $before.Keys){Verify ($after[$p]-ceq $before[$p])}
  $first=Hash $f.gate;Install-OpenWebOnboardingCallGate $f.package $f.engine $f.manifest;Verify ((Hash $f.gate)-ceq $first)
  if($native){CopyTree $backup (Join-Path $f.engine 'scripts') -Mirror;Verify (!(Test-Path -LiteralPath $f.gate));Exact $before (Inventory (Join-Path $f.engine 'scripts'));Verify ((Hash $f.private)-ceq $privateHash)}
 }
 Refuse {param($f)$f.manifest.files[$relative]='f'*64}
 Refuse {param($f)$f.manifest.files.Remove($relative)}
 Refuse {param($f)Remove-Item -LiteralPath $f.source}
 Refuse {param($f)$d=Split-Path $f.gate -Parent;[IO.File]::WriteAllText($d,'directory is a file')}
 # Link refusal exercises the real path guard on ordinary external fixtures.
 $f=Fixture;$foreign=Join-Path $f.directory 'foreign';New-Item -ItemType Directory $foreign|Out-Null
 $link=Split-Path $f.gate -Parent;$linkType=if($native){'Junction'}else{'SymbolicLink'};New-Item -ItemType $linkType -Path $link -Target $foreign|Out-Null
 $failed=$false;try{Install-OpenWebOnboardingCallGate $f.package $f.engine $f.manifest}catch{$failed=$true};Verify $failed;Verify (@(Get-ChildItem -LiteralPath $foreign).Count-eq 0)
 @{state='passed';checks=$checks;actual_native_immutable21_robocopy_mirror=$native;ordinary_real_files=$true;product_tasks_services_locks_ports_touched=$false;workRoot=$WorkRoot}|ConvertTo-Json -Compress
}finally{Remove-Item -LiteralPath $WorkRoot -Recurse -Force}
