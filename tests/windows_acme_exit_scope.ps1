# Exact ACME launcher scope controls with harmless native cmd.exe emitters.
# No ACME client, network, installed helper, task, service or account is invoked.
[CmdletBinding()]
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent),[string]$WorkRoot='')
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue';$checks=0
function Verify([bool]$Value,[string]$Label){if(!$Value){throw ('ACME exit-scope control refused: '+$Label)};$script:checks++}
Verify ($PSVersionTable.PSEdition -ceq 'Desktop' -and $PSVersionTable.PSVersion.Major -eq 5) 'actual Windows PowerShell5 required'
$file=Join-Path $SourceRoot 'packaging/windows/PublicAccess.Common.ps1';$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$errors);Verify (@($errors).Count -eq 0) 'source parses'
$definitions=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))
foreach($name in @('Assert-OpenWebOrdinaryPath','Set-OpenWebPublicPrivateAcl','Invoke-OpenWebAcme')){$f=@($definitions|Where-Object Name -ceq $name);Verify ($f.Count -eq 1) ('one actual '+$name);. ([scriptblock]::Create($f[0].Extent.Text))}
$fn=@($definitions|Where-Object Name -ceq 'Invoke-OpenWebAcme')[0];$text=$fn.Extent.Text
Verify ($text.Contains("`$ErrorActionPreference='Continue';`$global:LASTEXITCODE=`$null") -and $text.Contains('$code=$global:LASTEXITCODE')) 'fresh global native status is initialized and read'
Verify (!$text.Contains(";`$LASTEXITCODE=`$null") -and !$text.Contains('$code=$LASTEXITCODE')) 'no local status shadows the native result'
Verify ($text.Contains('& $Executable @Arguments 2>&1 | Out-File -LiteralPath $log -Encoding UTF8') -and $text.Contains('} finally { $ErrorActionPreference=$previousPreference }')) 'native argv/logging and preference restoration stay exact'
Verify ($text.Contains("if(`$null -eq `$code -or `$code -ne 0) { throw 'Certificate issuance or renewal failed.")) 'null and nonzero must still refuse'
if(!$WorkRoot){$WorkRoot=Join-Path ([IO.Path]::GetTempPath()) ('OpenWeb-AcmeScope-'+[Guid]::NewGuid().ToString('N'))}
Verify (!(Test-Path -LiteralPath $WorkRoot)) 'distinct absent private context required';$null=New-Item -ItemType Directory -Path $WorkRoot;Set-OpenWebPublicPrivateAcl $WorkRoot
$cmd=Join-Path $env:windir 'System32/cmd.exe';Verify (Test-Path -LiteralPath $cmd -PathType Leaf) 'actual harmless native command required'
foreach($case in @(
 @{name='stderr_exit0';exit=0;initial=7;preference='Stop';warning=$true},
 @{name='stderr_exit7';exit=7;initial=0;preference='Stop';warning=$true},
 @{name='missing_executable_stale0';exit=$null;initial=0;preference='Stop';warning=$false},
 @{name='exit0_continue_preference';exit=0;initial=7;preference='Continue';warning=$false}
)){
 $directory=Join-Path $WorkRoot $case.name;$null=New-Item -ItemType Directory -Path $directory;$context=[pscustomobject]@{Directory=$directory}
 $executable=if($case.name -ceq 'missing_executable_stale0'){Join-Path $directory 'missing.exe'}else{$cmd}
 $command=if($case.warning){'echo OPENWEB_ACME_SCOPE_OUT & echo OPENWEB_ACME_SCOPE_WARNING 1>&2 & exit /b '+$case.exit}else{'echo OPENWEB_ACME_SCOPE_OUT & exit /b '+$case.exit}
 $global:LASTEXITCODE=$case.initial;$ErrorActionPreference=$case.preference;$caught=$null
 try{Invoke-OpenWebAcme -Context $context -Executable $executable -Arguments @('/d','/c',$command)}catch{$caught=$_}
 Verify ($ErrorActionPreference -ceq $case.preference) ('preference restored '+$case.name);$ErrorActionPreference='Stop'
 if($case.exit -eq 0 -and $null -ne $case.exit){Verify ($null -eq $caught -and $global:LASTEXITCODE -eq 0) ('actual native zero accepted '+$case.name)}
 else{Verify ($null -ne $caught) ('nonzero or missing refused '+$case.name);if($null -ne $case.exit){Verify ($global:LASTEXITCODE -eq $case.exit) 'actual nonzero remains visible'}else{Verify ($null -eq $global:LASTEXITCODE) 'missing command cannot reuse stale0'}}
 $logs=@(Get-ChildItem -LiteralPath (Join-Path $directory 'logs') -File)
 if($case.name -ceq 'missing_executable_stale0'){Verify ($logs.Count -le 1) 'command resolution failure may precede private log creation'}
 else{Verify ($logs.Count -eq 1) 'one private log retained per native attempt'}
 if($case.warning){$log=[IO.File]::ReadAllText($logs[0].FullName);Verify ($log.Contains('OPENWEB_ACME_SCOPE_OUT') -and $log.Contains('OPENWEB_ACME_SCOPE_WARNING')) 'native stdout and stderr remain private and complete'}
}
$ErrorActionPreference='Stop'
[ordered]@{passed=$true;checks=$checks;actualWindowsPowerShell5=$true;actualNativeCommands=$true;exactSourceFunction=$true;freshGlobalExit0AndNonzeroVerified=$true;missingCommandCannotReuseStale0=$true;preferenceRestored=$true;logsRetainedPrivately=$true;actualAcmeCalls=0;installedHelperOrProductChanges=0;sourceSHA256=(Get-FileHash $file -Algorithm SHA256).Hash.ToLowerInvariant()}|ConvertTo-Json -Compress
