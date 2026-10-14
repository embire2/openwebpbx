# SPDX-License-Identifier: AGPL-3.0-or-later
# Execute the exact fixture launcher against an independent real Python child.
param([string]$Python='python3')
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'windows-native-acceptance.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Native hook did not parse.'}
$definition=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'StartFixturePkiServer'},$true)
if(!$definition){throw 'Exact native fixture launcher missing.'}
Invoke-Expression $definition.Extent.Text
$directory=Join-Path ([IO.Path]::GetTempPath()) ('native child '+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $directory|Out-Null
$python=(Get-Command $Python -CommandType Application|Select-Object -First 1).Source
$script=Join-Path $directory 'independent argument observer.py'
$privateInput='C:\ProgramData\OpenWebPBX\native qualification\fictional\input.json'
$process=$null
try{
 [IO.File]::WriteAllText($script,'import json,sys; print(json.dumps(sys.argv[1:]))',[Text.UTF8Encoding]::new($false))
 $process=StartFixturePkiServer
 if(!$process.WaitForExit(15000)){throw 'Real native fixture child did not complete.'}
 if($process.ExitCode){throw 'Real native fixture child failed.'}
 $arguments=$pkiOutput.GetAwaiter().GetResult()|ConvertFrom-Json
 if($arguments.Count -ne 4 -or $arguments[0] -ne '--input' -or $arguments[1] -cne $privateInput -or $arguments[2] -ne '--phase' -or $arguments[3] -ne 'pki-server'){throw 'Native fixture argument boundaries were changed.'}
 if($pkiErrors.GetAwaiter().GetResult()){throw 'Native fixture child produced an unexpected error.'}
 Write-Host 'PASS real native child launcher: spaced script/input paths remain single arguments; no Windows PBX qualification implied.'
 $diagnostic=$ast.Find({param($node)$node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.Contains('$record.helper') -and $node.Value.Contains('phone_tls_chain_validation')},$true)
 if(!$diagnostic){throw 'Exact TLS child diagnostic wrapper missing.'}
 $helper=Join-Path $directory 'Enable-PhoneTLS.ps1';$launcher=Join-Path $directory 'private TLS launcher.ps1';$inputFile=Join-Path $directory 'private input.json';$failure=Join-Path $directory 'failure.json'
 [IO.File]::WriteAllText($helper,"param([string]`$CertificateThumbprint,[string]`$FullChainPath)`nthrow 'Windows could not verify the phone certificate chain. unit-private-value'",[Text.UTF8Encoding]::new($false))
 [IO.File]::WriteAllText($launcher,$diagnostic.Value,[Text.UTF8Encoding]::new($false))
 [IO.File]::WriteAllText($inputFile,(@{helper=$helper;thumbprint='fictional';chain='fictional';failure=$failure}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
 $start=[Diagnostics.ProcessStartInfo]::new([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
 $start.UseShellExecute=$false;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 foreach($argument in @('-NoProfile','-NonInteractive','-File',$launcher,'-InputPath',$inputFile)){$start.ArgumentList.Add($argument)}
 $child=[Diagnostics.Process]::Start($start)
 try{
  $output=$child.StandardOutput.ReadToEndAsync();$errors=$child.StandardError.ReadToEndAsync()
  if(!$child.WaitForExit(15000) -or $child.ExitCode -ne 1){throw 'Independent TLS diagnostic fixture did not fail as expected.'}
  $serialized=[IO.File]::ReadAllText($failure);$result=$serialized|ConvertFrom-Json
  if($result.active_case -ne 'phone_tls_chain_validation' -or $result.source_basename -ne 'Enable-PhoneTLS.ps1' -or $result.source_line -ne 2 -or $result.error_type -ne 'RuntimeException'){throw 'Typed TLS diagnostic did not identify the actual helper failure.'}
  if(($serialized+$output.GetAwaiter().GetResult()+$errors.GetAwaiter().GetResult()).Contains('unit-private-value')){throw 'Private exception content escaped the safe diagnostic.'}
  Write-Host 'PASS actual typed TLS diagnostic child: helper location/stage retained, private exception marker withheld.'
 }finally{if(!$child.HasExited){$child.Kill($true)};$child.Dispose()}
 [IO.File]::WriteAllText($helper,@'
param([string]$CertificateThumbprint,[string]$FullChainPath)
$error=[InvalidOperationException]::new('Secure phone setup failed. unit-private-value')
$error.Data['OpenWebPhoneTLSPhpFailure']=[pscustomobject]@{schema=1;error_type='PDOException';source_basename='phone-tls.php';source_line=32;stage='idle'}
throw $error
'@,[Text.UTF8Encoding]::new($false))
 $child=[Diagnostics.Process]::Start($start)
 try{
  $output=$child.StandardOutput.ReadToEndAsync();$errors=$child.StandardError.ReadToEndAsync()
  if(!$child.WaitForExit(15000) -or $child.ExitCode -ne 1){throw 'Independent PHP diagnostic fixture did not fail as expected.'}
  $serialized=[IO.File]::ReadAllText($failure);$result=$serialized|ConvertFrom-Json
  if($result.active_case -ne 'phone_tls_php_idle' -or $result.source_basename -ne 'phone-tls.php' -or $result.source_line -ne 32 -or $result.error_type -ne 'PDOException'){throw 'Typed inner PHP diagnostic was not forwarded.'}
  if(($serialized+$output.GetAwaiter().GetResult()+$errors.GetAwaiter().GetResult()).Contains('unit-private-value')){throw 'Private PHP exception content escaped the safe diagnostic.'}
  Write-Host 'PASS actual PHP-to-TLS-wrapper diagnostic child: allowlisted PHP location/stage retained, private values withheld.'
 }finally{if(!$child.HasExited){$child.Kill($true)};$child.Dispose()}
}finally{
 if($process){if(!$process.HasExited){$process.Kill($true)};$process.Dispose()}
 Remove-Item -LiteralPath $directory -Recurse -Force
}
