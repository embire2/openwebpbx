#Requires -RunAsAdministrator
param([Parameter(Mandatory)][string]$Context)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$p=Get-Content -LiteralPath $Context -Raw|ConvertFrom-Json
if($p.RootAuthorizedReadOnlyOriginalPublic21BaselineDiagnostic -ne $true){throw 'False diagnostic authority'}
if([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -cne 'S-1-5-18'){throw 'Actual SYSTEM runner required'}
if((Get-FileHash -LiteralPath $PSCommandPath).Hash.ToLowerInvariant() -cne $p.runnerSHA256){throw 'Pinned private runner changed'}
$script=Join-Path $PSScriptRoot 'readonly-preamble.py';if((Get-FileHash -LiteralPath $script).Hash.ToLowerInvariant() -cne $p.collectorSHA256){throw 'Pinned collector changed'}
$info=[Diagnostics.ProcessStartInfo]::new('C:\OpenWebPBX\backup-runtime\python.exe');$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.WorkingDirectory=$PSScriptRoot;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true;$info.Arguments='-I -B "'+$script+'" "'+$Context+'"'
$clock=[Diagnostics.Stopwatch]::StartNew();$child=[Diagnostics.Process]::new();$child.StartInfo=$info;if(!$child.Start()){throw 'Read-only Python process did not start'};$out=$child.StandardOutput.ReadToEndAsync();$err=$child.StandardError.ReadToEndAsync();$finished=$child.WaitForExit(80000)
if($finished){[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'diagnostic-python.stdout.PRIVATE.txt'),$out.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($false));[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'diagnostic-python.stderr.PRIVATE.txt'),$err.GetAwaiter().GetResult(),[Text.UTF8Encoding]::new($false))}
$result=@{observationChildFinished=$finished;nativeExitCode=$(if($finished){$child.ExitCode}else{$null});childPID=$child.Id;elapsedSeconds=$clock.Elapsed.TotalSeconds;noWorkerOrProductLifecycle=$true;noKillOrRetry=$true;childMayStillBeRunning=(!$finished)}
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'diagnostic-child-result.safe.json'),($result|ConvertTo-Json),[Text.UTF8Encoding]::new($false));if(!$finished){throw 'Read-only observation deadline; preserve actual child/task without replay'}
