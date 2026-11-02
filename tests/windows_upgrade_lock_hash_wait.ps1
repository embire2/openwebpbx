#Requires -Version 7.4
$ErrorActionPreference='Stop';$checks=0
function Assert([bool]$ok){if(!$ok){throw ('Exact lock hash control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'windows-upgrade-acceptance.ps1'),[ref]$tokens,[ref]$errors);Assert (!$errors.Count)
$definition=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Hash'},$true));Assert ($definition.Count -eq 1);$hashSource=$definition[0].Extent.Text
Assert ($hashSource.Contains('$sharingWait.ElapsedMilliseconds -lt 30000'))
# Only this private exhaustion control shortens the declared real 30s bound.
# Successful hashes always execute the actual unchanged native cmdlet.
$fast=$hashSource.Replace('$sharingWait.ElapsedMilliseconds -lt 30000','$sharingWait.ElapsedMilliseconds -lt 120');Assert ($fast -cne $hashSource)
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('exact-lock-hash-'+[Guid]::NewGuid().ToString('N'));New-Item -ItemType Directory $fixture|Out-Null
$state=$fixture;$root=$fixture;$configuration=$fixture;$switch=$fixture;$work=$fixture;$PackageRoot=$fixture
$path=Join-Path $state 'upgrade.lock';$other=Join-Path $state 'unrelated.bin';[IO.File]::WriteAllBytes($path,[byte[]](4,2));[IO.File]::WriteAllBytes($other,[byte[]](4,2))
. (Join-Path $PSScriptRoot 'windows-upgrade-hash-observer.ps1')
function Get-FileHash {param([string]$LiteralPath,[string]$Algorithm)$script:calls++;if($script:remaining -ne 0){if($script:remaining -gt 0){$script:remaining--};throw $script:injected};return Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $LiteralPath -Algorithm $Algorithm}
try{
 Invoke-Expression $hashSource
 $script:injected=[IO.IOException]::new('private-sharing',[int]-2147024864);$script:calls=0;$script:remaining=2;$expected=(Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant();$actual=Hash $path
 Assert ($actual -ceq $expected -and $script:calls -eq 3 -and $script:remaining -eq 0)
 Assert ((Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $expected)
 foreach($case in @(@($other,[IO.IOException]::new('other-path',[int]-2147024864)),@($path,[IO.IOException]::new('other-IO',[int]-2147024891)),@($path,[IO.IOException]::new('unproved-lock33',[int]-2147024863)),@($path,[InvalidOperationException]::new('other-type',[int]-2147024864)))){
  $script:injected=$case[1];$script:calls=0;$script:remaining=-1;$caught=$null;try{Hash $case[0]|Out-Null}catch{$caught=$_};Assert ($null -ne $caught);Assert ([object]::ReferenceEquals($caught.Exception,$script:injected));Assert ($script:calls -eq 1)
 }
 # Identical basename outside the exact declared state root cannot retry.
 $neighbor=Join-Path $fixture 'neighbor';New-Item -ItemType Directory $neighbor|Out-Null;$foreign=Join-Path $neighbor 'upgrade.lock';[IO.File]::WriteAllBytes($foreign,[byte[]](4,2));$script:injected=[IO.IOException]::new('foreign',[int]-2147024864);$script:calls=0;$script:remaining=-1;$caught=$null;try{Hash $foreign|Out-Null}catch{$caught=$_};Assert ($null -ne $caught -and $script:calls -eq 1)
 Invoke-Expression $fast
 $script:injected=[IO.IOException]::new('exhaustion',[int]-2147024864);$script:calls=0;$script:remaining=-1;$watch=[Diagnostics.Stopwatch]::StartNew();$caught=$null;try{Hash $path|Out-Null}catch{$caught=$_};$watch.Stop()
 Assert ($null -ne $caught -and [object]::ReferenceEquals($caught.Exception,$script:injected));Assert ($script:calls -gt 1 -and $watch.ElapsedMilliseconds -ge 120 -and $watch.ElapsedMilliseconds -lt 1500)
 Invoke-Expression $hashSource
 # No cached/expected hash is substituted: changed bytes remain visibly changed.
 [IO.File]::WriteAllBytes($path,[byte[]](4,3));$script:remaining=1;$script:calls=0;$actual=Hash $path;Assert ($actual -cne $expected -and $script:calls -eq 2);Assert ($actual -ceq (Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant())
}finally{Remove-Item -LiteralPath $fixture -Recurse -Force}
Assert (!(Test-Path -LiteralPath $fixture))
[ordered]@{passed=$true;controls=$checks;source='actual AST Hash';successReads='actual native Get-FileHash';sharingAndOtherErrors='explicit original Exception adapters';privateExhaustionBoundMilliseconds=120;observationBoundMilliseconds=30000;noInstalledHostActions=$true}|ConvertTo-Json -Compress
