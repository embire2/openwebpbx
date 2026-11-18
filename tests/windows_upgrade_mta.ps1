# The actual early product guard, in owned fake scripts with no PBX writers.
#Requires -Version 5.1
[CmdletBinding()]
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent),[string]$Output)
$ErrorActionPreference='Stop';$checks=0;$children=@();$work=$null;$previous=[Environment]::GetEnvironmentVariable('OPENWEBPBX_OWNED_MTA_GUARD_OUTPUT','Process')
function Check([bool]$Value){if(!$Value){throw 'A Windows MTA entry control failed.'};$script:checks++}
function WriteText([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($true))}
if($PSVersionTable.PSEdition -ne 'Desktop' -or [Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'Run these controls in native Windows PowerShell.'}
$source=Join-Path $SourceRoot 'packaging/windows/Upgrade-OpenWebPBX.ps1';$sourceHash=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors);Check ($errors.Count -eq 0)
$guards=@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.IfStatementAst] -and $_.Extent.Text.StartsWith('if([Threading.Thread]::CurrentThread.GetApartmentState()')});Check ($guards.Count -eq 1)
$guard=$guards[0]
# Guard placement is part of the failure contract: it must precede every dot
# sourced helper and the real main transaction, not merely refuse after writes.
$dots=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Dot},$true))
Check ($dots.Count -gt 0 -and @($dots|Where-Object {$_.Extent.StartOffset -lt $guard.Extent.EndOffset}).Count -eq 0)
$imports=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Import-Module'},$true));Check (@($imports|Where-Object {$_.Extent.StartOffset -lt $guard.Extent.EndOffset}).Count -eq 0)
try{
 $work=Join-Path ([IO.Path]::GetTempPath()) ('OpenWeb MTA '+[guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Path $work
 $fixture=Join-Path $work 'owned-entry.ps1';$driver=Join-Path $work 'owned-driver.ps1';$inputFile=Join-Path $work 'case.json';$marker=Join-Path $work 'after-guard.json';$env:OPENWEBPBX_OWNED_MTA_GUARD_OUTPUT=$marker
 $body='[CmdletBinding()]param([string]$RestoreBackup,[switch]$Check,[string]$Archive,[string]$FeedEnvelope,[string]$TargetVersion,[switch]$Recover,[switch]$Automatic)' + "`n"+'$ErrorActionPreference=''Stop''' + "`n"+$guard.Extent.Text+"`n"+@'
$values=@{};foreach($name in $PSBoundParameters.Keys){$value=$PSBoundParameters[$name];$values[$name]=if($value -is [Management.Automation.SwitchParameter]){[bool]$value}else{$value}}
[IO.File]::WriteAllText($env:OPENWEBPBX_OWNED_MTA_GUARD_OUTPUT,(@{apartment=[Threading.Thread]::CurrentThread.GetApartmentState().ToString();parameters=$values;bound_names=@($PSBoundParameters.Keys)}|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
exit 75
'@
 WriteText $fixture $body
 WriteText $driver @'
$ErrorActionPreference='Stop';$data=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'case.json'))|ConvertFrom-Json;$parameters=@{}
foreach($entry in $data.PSObject.Properties){$parameters[$entry.Name]=if($entry.Name -cin 'Check','Recover','Automatic'){[Management.Automation.SwitchParameter]::new([bool]$entry.Value)}else{[string]$entry.Value}}
$global:LASTEXITCODE=0;& (Join-Path $PSScriptRoot 'owned-entry.ps1') @parameters;exit $global:LASTEXITCODE
'@
 $fixtureHash=(Get-FileHash $fixture -Algorithm SHA256).Hash.ToLowerInvariant()
 $literal="C:\Owned space ' Ω ; `$() & folder\"
 $cases=@(
  @{Archive=$literal+'full.zip';FeedEnvelope=$literal+'feed.json';TargetVersion='1.0.27';Check=$false;Recover=$false;Automatic=$false},
  @{Archive=$literal+'next.zip';FeedEnvelope=$literal+'next.json';TargetVersion='1.0.28';Automatic=$true},
  @{Archive=$literal+'full.zip';FeedEnvelope=$literal+'feed.json';TargetVersion='1.0.27';Check=$true;Automatic=$false},
  @{RestoreBackup=$literal;Recover=$false},
  @{Recover=$true}
 )
 foreach($apartment in 'Sta','Mta'){
  foreach($parameters in $cases){
   WriteText $inputFile ($parameters|ConvertTo-Json -Compress);Remove-Item -LiteralPath $marker -ErrorAction SilentlyContinue
   $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell/v1.0/powershell.exe';$start.Arguments='-NoProfile -NonInteractive -'+$apartment+' -ExecutionPolicy Bypass -File "'+$driver+'"';$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
   $process=[Diagnostics.Process]::Start($start);$children+=$process;$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
   if(!$process.WaitForExit(30000)){$process.Kill();throw 'The owned no-writer MTA guard fixture exceeded its30-second bound.'}
   $null=$stdout.GetAwaiter().GetResult();$errorText=$stderr.GetAwaiter().GetResult()
   if($apartment -ceq 'Sta'){
    Check ($process.ExitCode -ne 0);Check (!(Test-Path -LiteralPath $marker));Check ($errorText.Contains('-Mta'))
   }else{
    Check ($process.ExitCode -eq 75);$record=[IO.File]::ReadAllText($marker)|ConvertFrom-Json;Check ($record.apartment -ceq 'MTA');Check (@($record.bound_names).Count -eq $parameters.Count)
    foreach($name in $parameters.Keys){Check ($record.parameters.PSObject.Properties[$name].Value -ceq $parameters[$name])}
   }
   Check ((Get-FileHash $fixture -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $fixtureHash)
  }
 }
 Check ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $sourceHash)
 $result=[ordered]@{passed=$true;controls=$checks;source_sha256=$sourceHash;actual_ps_version=$PSVersionTable.PSVersion.ToString();entry_modes=5;sta_refuses_before_writer=$true;mta_preserves_parameters_and_exit=$true;product_or_recovery_writers_called=$false}
 if($Output){[IO.File]::WriteAllText($Output,($result|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))};$result|ConvertTo-Json -Compress
}finally{
 [Environment]::SetEnvironmentVariable('OPENWEBPBX_OWNED_MTA_GUARD_OUTPUT',$previous,'Process');foreach($child in $children){$child.Dispose()}
 if($work -and (Test-Path -LiteralPath $work)){Remove-Item -LiteralPath $work -Recurse -Force}
}
