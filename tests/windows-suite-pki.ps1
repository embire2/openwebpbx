# SPDX-License-Identifier: AGPL-3.0-or-later.
# Parent-owned disposable CA lifetime for the upgrade and backup consumers.
# The calling matrix owns and removes its separate CA before this starts.
function Set-SuiteFixtureBinding([byte[]]$Hash,[string]$Store,[switch]$Read) {
 Add-Type -Path "$env:SystemRoot\System32\inetsrv\Microsoft.Web.Administration.dll"
 $manager=[Microsoft.Web.Administration.ServerManager]::new()
 try {
  $site=$manager.Sites['OpenWebPBX'];if(!$site){throw 'The owned suite website is missing.'}
  $bindings=@($site.Bindings|Where-Object {$_.Protocol -eq 'https' -and $_.BindingInformation -eq '*:8443:windowsqa.example.invalid'})
  if($bindings.Count -ne 1){throw 'The exact owned suite binding is required.'}
  $binding=$bindings[0]
  if($Read){return @{hash=[byte[]]$binding.CertificateHash;store=$binding.CertificateStoreName}}
  $binding.CertificateHash=$Hash;$binding.CertificateStoreName=$Store;$manager.CommitChanges()
 } finally {$manager.Dispose()}
}
function Start-SuiteRecoveryPki([string]$PackageRoot,[string]$SourceRoot,[string]$Work) {
 if($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:GITHUB_REPOSITORY -ne 'embire2/openwebpbx'){throw 'Only the explicitly disposable suite may create this CA.'}
 $installation=Get-Content 'C:\ProgramData\OpenWebPBX\installation.json' -Raw|ConvertFrom-Json
 if(!$installation.Completed -or !$installation.RestoreServer -or $installation.DomainName -ne 'windowsqa.example.invalid' -or $installation.Version -ne '1.0.13'){throw 'The exact completed disposable replacement factory is required.'}
 $directory=Join-Path $Work 'recovery-pki';PrivateDirectory $directory
 $inputFile=Join-Path $directory 'input.json';$evidence=Join-Path $directory 'evidence';PrivateDirectory $evidence
 [IO.File]::WriteAllText($inputFile,(@{scope=[Guid]::NewGuid().ToString('N').Substring(0,24);source_root=$SourceRoot;evidence_directory=$evidence}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
 $context=@{root=$null;leaf=$null;binding=$null;process=$null;out=$null;err=$null;directory=$directory}
 $python=Join-Path $PackageRoot 'backup-runtime\python.exe';$script=Join-Path $SourceRoot 'tests\windows-native-acceptance.py';$prior=$env:OPENWEB_WINDOWS_NATIVE_TEST
 try {
  $env:OPENWEB_WINDOWS_NATIVE_TEST='1'
  & $python -I $script --input $inputFile --phase prepare-pki 1>"$directory\prepare-private.out" 2>"$directory\prepare-private.err"
  if($LASTEXITCODE){throw 'The independent recovery CA preparation failed.'}
  # Use the extracted interpreter: upgrades must be free to replace the
  # installed backup runtime without a laboratory DLL lock.
  $start=[Diagnostics.ProcessStartInfo]::new($python);$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
  foreach($argument in @('-I',$script,'--input',$inputFile,'--phase','pki-server')){$start.ArgumentList.Add($argument)}
  $context.process=[Diagnostics.Process]::Start($start);$context.out=$context.process.StandardOutput.ReadToEndAsync();$context.err=$context.process.StandardError.ReadToEndAsync()
  for($i=0;$i -lt 50 -and !(Test-Path "$evidence\pki-ready.json") -and !$context.process.HasExited;$i++){Start-Sleep -Milliseconds 100}
  if($context.process.HasExited -or !(Test-Path "$evidence\pki-ready.json")){throw 'The owned recovery CRL listener failed to start.'}
  $pki=Get-Content "$evidence\pki-private.json" -Raw|ConvertFrom-Json
  $context.root=Import-Certificate -FilePath "$evidence\fixture-root.cer" -CertStoreLocation Cert:\LocalMachine\Root
  $context.leaf=Import-PfxCertificate -FilePath "$evidence\fixture.pfx" -CertStoreLocation Cert:\LocalMachine\My -Password (ConvertTo-SecureString $pki.password -AsPlainText -Force) -Exportable
  if($context.root.Thumbprint.ToLowerInvariant() -ne $pki.root_thumbprint -or $context.leaf.Thumbprint.ToLowerInvariant() -ne $pki.leaf_thumbprint){throw 'The exact independent recovery CA and leaf were not imported.'}
  $context.binding=Set-SuiteFixtureBinding -Read
  Set-SuiteFixtureBinding -Hash ([Convert]::FromHexString($context.leaf.Thumbprint)) -Store 'My'
  return $context
 } catch {Stop-SuiteRecoveryPki $context;throw}
 finally {if($null -eq $prior){Remove-Item Env:\OPENWEB_WINDOWS_NATIVE_TEST -ErrorAction SilentlyContinue}else{$env:OPENWEB_WINDOWS_NATIVE_TEST=$prior}}
}
function Stop-SuiteRecoveryPki($Context) {
 if(!$Context){return}
 if($Context.binding){Set-SuiteFixtureBinding -Hash $Context.binding.hash -Store $Context.binding.store;$Context.binding=$null}
 foreach($entry in @(@{item=$Context.leaf;store='My'},@{item=$Context.root;store='Root'})) {
  if($entry.item){$path='Cert:\LocalMachine\'+$entry.store+'\'+$entry.item.Thumbprint;if((Get-Item -LiteralPath $path).Thumbprint -ne $entry.item.Thumbprint){throw 'Certificate cleanup refused a foreign object.'};Remove-Item -LiteralPath $path -Force}
 }
 if($Context.process){
  if(!$Context.process.HasExited){$Context.process.Kill()}
  if(!$Context.process.WaitForExit(5000)){throw 'The owned recovery CRL listener did not stop.'}
  [IO.File]::WriteAllText((Join-Path $Context.directory 'server-private.out'),$Context.out.GetAwaiter().GetResult());[IO.File]::WriteAllText((Join-Path $Context.directory 'server-private.err'),$Context.err.GetAwaiter().GetResult());$Context.process.Dispose();$Context.process=$null
 }
}
