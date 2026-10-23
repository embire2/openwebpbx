# Actual redirected child/stream limits; no PG/ESL/server, service or firewall.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest;$checks=0
. (Join-Path $SourceRoot 'packaging/windows/PublicAccess.Common.ps1')
$executable=(Get-Process -Id $PID).Path
foreach($case in 'normal','stdout_limit','stderr_limit','stall','failed'){
 $body=switch($case){'normal'{"[Console]::Out.Write('bounded');[Console]::Error.Write('diagnostic');exit 0"};'stdout_limit'{"[Console]::Out.Write(('x'*65537));Start-Sleep -Seconds 10"};'stderr_limit'{"[Console]::Error.Write(('x'*4097));Start-Sleep -Seconds 10"};'stall'{"Start-Sleep -Seconds 10"};'failed'{"[Console]::Out.Write('refused');exit 7"}}
 $p=[Diagnostics.Process]::new();$p.StartInfo.FileName=$executable;$p.StartInfo.Arguments='-NoProfile -NonInteractive -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body));$p.StartInfo.UseShellExecute=$false;$p.StartInfo.CreateNoWindow=$true;$p.StartInfo.RedirectStandardOutput=$true;$p.StartInfo.RedirectStandardError=$true
 try{
  $null=$p.Start();$failed=$false;$r=$null;try{$r=Read-OpenWebPublicInventoryProcess $p -WaitMilliseconds $(if($case -ceq 'stall'){500}else{5000})}catch{$failed=$true}
  if($case -cin 'normal','failed'){if($failed -or !$p.HasExited -or $r.exit_code -ne $(if($case -ceq 'failed'){7}else{0}) -or $r.stdout -cne $(if($case -ceq 'failed'){'refused'}else{'bounded'})){throw 'A bounded child result was lost.'}}
  elseif(!$failed -or !$p.HasExited){throw 'A streaming overflow/stall did not refuse and stop only its owned child.'}
  $checks++
 }finally{if(!$p.HasExited){$p.Kill();$null=$p.WaitForExit(3000)};$p.Dispose()}
}
[ordered]@{schema=1;state='passed';checks=$checks;actual_process_and_stream_limits=$true;server_or_firewall_mutation=$false}|ConvertTo-Json -Compress
