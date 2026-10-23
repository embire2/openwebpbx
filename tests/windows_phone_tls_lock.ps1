# Actual Windows sharing/deadline/permission controls; only a private Temp tree.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if($env:OS -cne 'Windows_NT'){throw 'Native Windows is required.'}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'packaging/windows/Enable-PhoneTLS.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The production phone TLS helper must parse.'}
$nodes=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Open-OpenWebPhoneTlsMaintenance'},$true))
if($nodes.Count -ne 1){throw 'The actual maintenance function must be unique.'};Invoke-Expression $nodes[0].Extent.Text
$stunTokens=$null;$stunErrors=$null;$stunAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-stun-native.ps1'),[ref]$stunTokens,[ref]$stunErrors)
if($stunErrors.Count){throw 'The native STUN gate must parse.'}
$stunLocks=@($stunAst.FindAll({param($node)$node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$lock' -and $node.Right.Extent.Text -match '^Open-OpenWebPhoneTlsMaintenance '},$true))
if($stunLocks.Count -ne 1){throw 'The native STUN gate must use the uniquely pinned bounded acquisition.'}
$stunAcquire=[scriptblock]::Create($stunLocks[0].Extent.Text)
function InvokeStunLock([string]$StateRoot){$state=$StateRoot;$lock=$null;. $stunAcquire;return $lock}
$checks=0
function Check([bool]$Value){if(!$Value){throw ('Native phone TLS lock control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
function Refuses([scriptblock]$Body,[bool]$Busy=$false){$failed=$false;try{& $Body}catch{$failed=$true;Check ($_.Exception.Data.Contains('OpenWebPhoneTLSBusy') -eq $Busy)};Check $failed}
$work=Join-Path $env:TEMP ('openweb-phone-tls-lock-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($work)
& icacls.exe $work /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F'|Out-Null;if($LASTEXITCODE){throw 'Private test permissions failed.'}
$held=$null;$child=$null;$aclOriginal=$null;$denyPath=$null
try{
 $path=Join-Path $work 'upgrade.lock';$stream=Open-OpenWebPhoneTlsMaintenance $path;Check ($stream.CanRead -and $stream.CanWrite);$stream.Dispose()
 $held=[IO.File]::Open($path,'Open','ReadWrite','None');$borrowed=Open-OpenWebPhoneTlsMaintenance -Path $path -Borrowed $held;Check ([object]::ReferenceEquals($borrowed,$held));Check ($held.CanRead)
 $clock=[Diagnostics.Stopwatch]::StartNew();Refuses {Open-OpenWebPhoneTlsMaintenance -Path $path -WaitMilliseconds 200} $true;Check ($clock.ElapsedMilliseconds -ge 150 -and $clock.ElapsedMilliseconds -lt 2500);Check $held.CanRead;$held.Dispose();$held=$null
 $foreign=Join-Path $work 'foreign.lock';$held=[IO.File]::Open($foreign,'OpenOrCreate','ReadWrite','None');Refuses {Open-OpenWebPhoneTlsMaintenance -Path $path -Borrowed $held};Check $held.CanRead;$held.Dispose();$held=$null
 $held=[IO.File]::Open($path,'Open','Read','ReadWrite');Refuses {Open-OpenWebPhoneTlsMaintenance -Path $path -Borrowed $held};Check $held.CanRead;$held.Dispose();$held=$null
 $held=[IO.File]::Open($path,'Open','ReadWrite','ReadWrite');Refuses {Open-OpenWebPhoneTlsMaintenance -Path $path -Borrowed $held};Check $held.CanRead;$held.Dispose();$held=$null
 $closed=[IO.File]::Open($path,'Open','ReadWrite','None');$closed.Dispose();Refuses {Open-OpenWebPhoneTlsMaintenance -Path $path -Borrowed $closed}
 # Exact old one-shot acquisition fails while another native process holds the
 # brief reader lock. The production bounded acquisition waits for its release.
 $ready=Join-Path $work 'ready';$code="`$ErrorActionPreference='Stop';`$s=[IO.File]::Open('"+$path.Replace("'","''")+"','Open','ReadWrite','ReadWrite');try{[IO.File]::WriteAllText('"+$ready.Replace("'","''")+"','ready');Start-Sleep -Milliseconds 1500}finally{`$s.Dispose()}"
 $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'));$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.Arguments='-NoProfile -NonInteractive -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code));$child=[Diagnostics.Process]::Start($start)
 $deadline=[DateTime]::UtcNow.AddSeconds(15);while(!(Test-Path -LiteralPath $ready)){if($child.HasExited -or [DateTime]::UtcNow -ge $deadline){throw 'The owned native holder did not become ready.'};Start-Sleep -Milliseconds 25}
 $oldFailed=$false;try{$old=[IO.File]::Open($path,'OpenOrCreate','ReadWrite','None');$old.Dispose()}catch [IO.IOException]{$fault=$_.Exception;while($fault.InnerException){$fault=$fault.InnerException};$oldFailed=([long]$fault.HResult -band 4294967295L) -eq 2147942432L};Check $oldFailed
 $clock=[Diagnostics.Stopwatch]::StartNew();$stream=InvokeStunLock $work;Check ($stream.CanRead -and $clock.ElapsedMilliseconds -ge 250 -and $clock.ElapsedMilliseconds -lt 5000);$stream.Dispose();Check ($child.WaitForExit(5000) -and $child.ExitCode -eq 0);$child.Dispose();$child=$null
 # Execute the actual STUN statement with its unchanged thirty-second budget,
 # including a holder that never releases during the permitted wait.
 $held=[IO.File]::Open($path,'Open','ReadWrite','None');$clock=[Diagnostics.Stopwatch]::StartNew();Refuses {InvokeStunLock $work} $true;Check ($clock.ElapsedMilliseconds -ge 29500 -and $clock.ElapsedMilliseconds -lt 35000);Check $held.CanRead;$held.Dispose();$held=$null
 $clock=[Diagnostics.Stopwatch]::StartNew();Refuses {Open-OpenWebPhoneTlsMaintenance -Path $work -WaitMilliseconds 1000};Check ($clock.ElapsedMilliseconds -lt 1000)
 $clock=[Diagnostics.Stopwatch]::StartNew();Refuses {InvokeStunLock (Join-Path $work 'absent')};Check ($clock.ElapsedMilliseconds -lt 1000)
 $denyRoot=Join-Path $work 'denied';[void][IO.Directory]::CreateDirectory($denyRoot);$denyPath=Join-Path $denyRoot 'upgrade.lock';[IO.File]::WriteAllText($denyPath,'original');$aclOriginal=Get-Acl -LiteralPath $denyPath;$acl=Get-Acl -LiteralPath $denyPath;$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User;$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'WriteData','Deny'));Set-Acl -LiteralPath $denyPath -AclObject $acl
 $clock=[Diagnostics.Stopwatch]::StartNew();Refuses {InvokeStunLock $denyRoot};Check ($clock.ElapsedMilliseconds -lt 1000);Set-Acl -LiteralPath $denyPath -AclObject $aclOriginal;Check ([IO.File]::ReadAllText($denyPath) -ceq 'original');$aclOriginal=$null
 $target=Join-Path $work 'target';[void][IO.Directory]::CreateDirectory($target);$junction=Join-Path $work 'junction';New-Item -ItemType Junction -Path $junction -Target $target|Out-Null
 Refuses {InvokeStunLock $junction};Check (!(Test-Path -LiteralPath (Join-Path $target 'upgrade.lock')));[IO.Directory]::Delete($junction)
 [ordered]@{schema=1;state='passed';checks=$checks;actual_native_windows=$true;actual_cross_process_sharing=$true;old_one_shot_refused=$true;bounded_release_success=$true;actual_stun_gate_acquisition=$true;deadline_refused=$true;acl_and_path_refused=$true;borrowed_lock_preserved=$true;pbx_or_service_mutations=$false}|ConvertTo-Json -Compress
}finally{
 if($held){$held.Dispose()};if($child){if(!$child.HasExited){$child.Kill();$child.WaitForExit()};$child.Dispose()};if($aclOriginal){Set-Acl -LiteralPath $denyPath -AclObject $aclOriginal};if(Test-Path -LiteralPath $work){Remove-Item -LiteralPath $work -Recurse -Force}
}
