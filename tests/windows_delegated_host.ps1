[CmdletBinding()]
param([string]$SourceRoot='', [string]$Receipt='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'Run on actual Windows PowerShell.'}
if(!$SourceRoot){$SourceRoot=Split-Path $PSScriptRoot -Parent}
$common=Join-Path $SourceRoot 'packaging/windows/PhpRuntime.Common.ps1'
. $common
$checks=0;$results=@();$shell=(Get-Process -Id $PID).Path
function Check([bool]$Value,[string]$Message){if(!$Value){throw $Message};$script:checks++}
function Quote([string]$Value){"'"+$Value.Replace("'","''")+"'"}
function Native([string[]]$Arguments){
 $prior=$ErrorActionPreference
 try{$ErrorActionPreference='Continue';$global:LASTEXITCODE=$null;$null=& $shell @Arguments 2>&1;$code=$global:LASTEXITCODE}
 finally{$ErrorActionPreference=$prior}
 if($null -eq $code){throw 'Native process did not report an exit code.'};return [int]$code
}
$work=Join-Path ([IO.Path]::GetTempPath()) ('openweb-host-exit-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work|Out-Null
try{
 foreach($code in 0,1,2,75){
  foreach($kind in 'original','terminal'){
   $leaf=Join-Path $work ($kind+'-'+$code);New-Item -ItemType Directory -Path $leaf|Out-Null
   $parent=Join-Path $leaf 'caller.ps1';$child=Join-Path $leaf 'common.ps1'
   $body=Join-Path $leaf 'caller-body.txt';$final=Join-Path $leaf 'caller-finally.txt';$accepted=Join-Path $leaf 'dedicated-host.txt'
   [IO.File]::WriteAllText($parent,('$ErrorActionPreference=''Stop'';try{. '+(Quote $child)+';[IO.File]::WriteAllText('+(Quote $body)+',''unexpected'')}finally{[IO.File]::WriteAllText('+(Quote $final)+',''finally'')}'))
   if($kind -ceq 'original'){[IO.File]::WriteAllText($child,('exit '+$code))}
   else{[IO.File]::WriteAllText($child,('. '+(Quote $common)+';Assert-OpenWebDedicatedUpgradeHost -CallerPath '+(Quote $parent)+';[IO.File]::WriteAllText('+(Quote $accepted)+',''verified'');Stop-OpenWebDedicatedUpgradeHost -ExitCode '+$code))}
   $actual=Native -Arguments @('-NoProfile','-NonInteractive','-Mta','-File',$parent)
   if($kind -ceq 'original'){
    Check (Test-Path -LiteralPath $body) 'The original dot-sourced exit must reproduce continuation of its caller.'
    Check (Test-Path -LiteralPath $final) 'Original continuation reaches the caller finally block.'
   }else{
    Check ($actual -eq $code) ('Dedicated host must preserve native exit '+$code)
    Check ((Test-Path -LiteralPath $accepted) -and !(Test-Path -LiteralPath $body) -and !(Test-Path -LiteralPath $final)) 'No legacy transaction or implicit finally may run after terminal handoff.'
   }
   $results+=@{mode=$kind;child_exit=$code;native_exit=$actual;caller_body_ran=[bool](Test-Path -LiteralPath $body)}
  }
 }
 $expected=Join-Path $work 'interactive-caller.ps1';$shim=Join-Path $work 'interactive-common.ps1';$continued=Join-Path $work 'console-continues.txt';$entered=Join-Path $work 'unexpected-terminal.txt'
 [IO.File]::WriteAllText($expected,('. '+(Quote $shim)))
 [IO.File]::WriteAllText($shim,('. '+(Quote $common)+';Assert-OpenWebDedicatedUpgradeHost -CallerPath '+(Quote $expected)+';[IO.File]::WriteAllText('+(Quote $entered)+',''bad'');Stop-OpenWebDedicatedUpgradeHost -ExitCode 75'))
 $command='try{& '+(Quote $expected)+'}catch{};[IO.File]::WriteAllText('+(Quote $continued)+',''console survives'')'
 $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
 $actual=Native -Arguments @('-NoProfile','-NonInteractive','-Mta','-EncodedCommand',$encoded)
 Check ($actual -eq 0 -and (Test-Path -LiteralPath $continued) -and !(Test-Path -LiteralPath $entered)) 'An interactive-style host must refuse before delegation without terminating its console.'
 foreach($arguments in @(@('powershell.exe','-File',$expected),@('powershell.exe','-file',$expected))){Assert-OpenWebDedicatedUpgradeHost -CallerPath $expected -HostArguments $arguments;$checks++}
 foreach($arguments in @(@('powershell.exe','-Command','anything'),@('powershell.exe','-File'),@('powershell.exe','-File','C:\foreign.ps1'),@('powershell.exe','-File',$expected,'-File',$expected))){
  $refused=$false;try{Assert-OpenWebDedicatedUpgradeHost -CallerPath $expected -HostArguments $arguments}catch{$refused=$true};Check $refused 'Unknown, incomplete, foreign or repeated host entry must refuse.'
 }
 $result=@{passed=$true;checks=$checks;actual_ps_version=$PSVersionTable.PSVersion.ToString();original_scope_fault_reproduced=$true;native_exit_codes=@(0,1,2,75);caller_body_never_runs_after_terminal_handoff=$true;interactive_host_preserved=$true;product_services_or_data_written=$false;source_common_sha256=(Get-FileHash -LiteralPath $common -Algorithm SHA256).Hash.ToLowerInvariant();outcomes=$results}
 if($Receipt){[IO.File]::WriteAllText($Receipt,($result|ConvertTo-Json -Depth 8))}
 Write-Host ('Windows delegated host: '+$checks+' controls passed.')
}finally{Remove-Item -LiteralPath $work -Recurse -Force}
