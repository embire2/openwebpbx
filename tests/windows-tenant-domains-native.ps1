#Requires -RunAsAdministrator
#Requires -Version 5.1
# SPDX-License-Identifier: AGPL-3.0-or-later
[CmdletBinding()]
param([Parameter(Mandatory)][string]$PackageRoot,[Parameter(Mandatory)][string]$ReportPath,[switch]$DisposableHostedRunner)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if(!$DisposableHostedRunner -or $env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:RUNNER_OS -ne 'Windows' -or $env:GITHUB_REPOSITORY -ne 'embire2/openwebpbx' -or [Environment]::OSVersion.Version.Build -lt 26100){throw 'Explicit disposable Windows Server 2025 runner required.'}
$root='C:\OpenWebPBX';$state=Join-Path $env:ProgramData 'OpenWebPBX';$source=Split-Path $PSScriptRoot -Parent;$taskName='OpenWebPBX-TenantDomains'
$installed=Get-Content (Join-Path $state 'installation.json') -Raw|ConvertFrom-Json
if(!$installed.Completed -or !$installed.RestoreServer){throw 'A completed empty restore-server factory is required.'}
. (Join-Path "$root\tools" 'PublicAccess.Common.ps1')
Add-Type -Path "$env:windir\System32\inetsrv\Microsoft.Web.Administration.dll"
$scope=[Guid]::NewGuid().ToString('N');$alias='qa-'+$scope+'.openwebpbx.com';$work=Join-Path $state ('tenant-domain-qualification\'+$scope);$fixtureInputPath=Join-Path $work 'input.json';$tenantState=Join-Path $state 'tenant-domains';$key=Join-Path $env:ProgramData 'fusionpbx\tenant-domains-instance-key.pem';$holdRoot=Join-Path $state 'backup-restore';$hold=Join-Path $holdRoot 'hold-updates'
New-Item -ItemType Directory -Path $work -Force|Out-Null;Set-OpenWebPublicPrivateAcl $work
$checks=[Collections.Generic.List[string]]::new();$phase='initialization';$lock=$null;$pki=$null;$rootCert=$null;$leaf=$null;$dbPrepared=$false;$holdOwned=$false;$holdRootCreated=$false;$foreign=$null;$firewall=$null;$saved=$null;$keyBefore=$null;$iisBefore=$null;$taskEnabled=$false;$taskXml=$null;$snapshotComplete=$false;$vdirSnapshotTaken=$false;$primaryFailure=$null;$cleanupFailure=$null;$failurePhase='initialization';$sessionIds=[Collections.Generic.List[string]]::new()
$facts=[ordered]@{schema=1;state='running';case='native_windows_tenant_alias_worker_iis_https';checks=0;system_task=$false;private_acl=$false;static_proof_https=$false;alias_https=$false;foreign_binding_refused=$false;cleanup_exact=$false;actual_acme='unqualified';real_registry_dns_mutations=$false;phase='initialization'}
function Check([bool]$Value,[string]$Name){
 if(!$Value){
  $failure=[InvalidOperationException]::new("Native tenant-domain control failed: $Name")
  $caller=@(Get-PSCallStack)[1]
  if($caller -and $caller.ScriptLineNumber -ge 1 -and $caller.ScriptLineNumber -le 99999){$failure.Data['OpenWebTenantCheckSourceLine']=[int]$caller.ScriptLineNumber}
  throw $failure
 }
 $checks.Add($Name)
}
function CheckSourceLine($Failure){
 $depth=0
 for($exception=$Failure.Exception;$exception -and $depth -lt 4;$exception=$exception.InnerException){
  $line=$exception.Data['OpenWebTenantCheckSourceLine'];$depth++
  if(($line -is [int] -or $line -is [long]) -and $line -ge 1 -and $line -le 99999){return [int]$line}
 }
 return [Math]::Max(1,[Math]::Min(99999,[int]$Failure.InvocationInfo.ScriptLineNumber))
}
function Refuses([scriptblock]$Action,[string]$Name){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Check $failed $Name}
function SaveFile([string]$Path){if(!(Test-Path -LiteralPath $Path)){return @{exists=$false}};$null=Assert-OpenWebOrdinaryPath $Path;return @{exists=$true;bytes=[Convert]::ToBase64String([IO.File]::ReadAllBytes($Path));sddl=(Get-Acl -LiteralPath $Path).Sddl}}
function RestoreFile([string]$Path,$Before){if($Before.exists){[IO.File]::WriteAllBytes($Path,[Convert]::FromBase64String($Before.bytes));$acl=[Security.AccessControl.FileSecurity]::new();$acl.SetSecurityDescriptorSddlForm($Before.sddl);Set-Acl -LiteralPath $Path -AclObject $acl}else{if(Test-Path -LiteralPath $Path){$null=Assert-OpenWebOrdinaryPath $Path;Remove-Item -LiteralPath $Path -Force}}}
function SnapshotTree([string]$Path){
 if(!(Test-Path -LiteralPath $Path)){return @{exists=$false;files=@{};directories=@{}}}
 $null=Assert-OpenWebOrdinaryPath $Path $true;$record=@{exists=$true;files=@{};directories=@{''=(Get-Acl -LiteralPath $Path).Sddl}}
 foreach($item in Get-ChildItem -LiteralPath $Path -Recurse -Force){$null=Assert-OpenWebOrdinaryPath $item.FullName $item.PSIsContainer;$rel=$item.FullName.Substring($Path.Length).TrimStart('\');if($item.PSIsContainer){$record.directories[$rel]=(Get-Acl -LiteralPath $item.FullName).Sddl}else{$record.files[$rel]=SaveFile $item.FullName}}
 return $record
}
function RestoreTree([string]$Path,$Before){
 if(Test-Path -LiteralPath $Path){foreach($item in Get-ChildItem -LiteralPath $Path -Recurse -Force){$null=Assert-OpenWebOrdinaryPath $item.FullName $item.PSIsContainer};Remove-Item -LiteralPath $Path -Recurse -Force}
 if(!$Before.exists){return}
 foreach($rel in @($Before.directories.Keys|Sort-Object Length)){New-Item -ItemType Directory -Path $(if($rel){Join-Path $Path $rel}else{$Path}) -Force|Out-Null}
 foreach($rel in $Before.files.Keys){RestoreFile (Join-Path $Path $rel) $Before.files[$rel]}
 foreach($rel in @($Before.directories.Keys|Sort-Object Length -Descending)){$target=if($rel){Join-Path $Path $rel}else{$Path};$acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetSecurityDescriptorSddlForm($Before.directories[$rel]);Set-Acl -LiteralPath $target -AclObject $acl}
}
function SameTree($A,$B){if($A.exists -ne $B.exists -or $A.files.Count -ne $B.files.Count -or $A.directories.Count -ne $B.directories.Count){return $false};foreach($k in $A.files.Keys){if(!$B.files.ContainsKey($k) -or $A.files[$k].bytes -cne $B.files[$k].bytes -or $A.files[$k].sddl -cne $B.files[$k].sddl){return $false}};foreach($k in $A.directories.Keys){if(!$B.directories.ContainsKey($k) -or $A.directories[$k] -cne $B.directories[$k]){return $false}};return $true}
function Php([string]$Action){$raw=& "$root\php\php.exe" (Join-Path $PSScriptRoot 'windows-tenant-domains-native.php') $Action $fixtureInputPath 2>>"$work\php.private.log";if($LASTEXITCODE){throw 'The owned tenant-domain database fixture failed.'};return (($raw -join "`n")|ConvertFrom-Json)}
function Python([string]$Action){$raw=& "$root\backup-runtime\python.exe" -I (Join-Path $PSScriptRoot 'windows-tenant-domains-native.py') $Action $fixtureInputPath 2>>"$work\python.private.log";if($LASTEXITCODE){throw 'The installed tenant-worker primitive failed.'};return (($raw -join "`n")|ConvertFrom-Json)}
function Operation([string]$Name,[string]$Thumb='',[string]$InputPath=''){
 $arguments=@('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',"$root\tools\Tenant-Domains.ps1",'-Operation',$Name)
 if($Thumb){$arguments+=@('-CertificateThumbprint',$Thumb)}
 if($InputPath){$arguments+=@('-InputFile',$InputPath)}
 $raw=& "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" @arguments 2>>"$work\operation.private.log"
 if($LASTEXITCODE){throw 'The packaged tenant-domain operation refused.'};return (($raw -join "`n")|ConvertFrom-Json)
}
function PrivateAcl([string]$Path,[bool]$Public){
 $acl=Get-Acl -LiteralPath $Path;$allowed=@('S-1-5-18','S-1-5-32-544');if($Public){$allowed+=@('S-1-5-32-568','S-1-5-17')}
 Check ($acl.AreAccessRulesProtected -and $acl.Access.Count -eq $allowed.Count -and $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ceq 'S-1-5-32-544') 'Actual protected ACL has only expected principals'
 foreach($rule in $acl.Access){$sid=$rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value;Check ($sid -in $allowed -and $rule.AccessControlType -eq 'Allow') 'Actual ACL principal and access type';if($sid -in 'S-1-5-32-568','S-1-5-17'){Check (([int]$rule.FileSystemRights -band [int][Security.AccessControl.FileSystemRights]::Write) -eq 0) 'IIS can read but cannot write public proof state'}}
}
function Https([string]$HostName,[string]$Path,[string]$Method='GET'){
 $client=[Net.Sockets.TcpClient]::new();$stream=$null
 try{
  if(!$client.ConnectAsync('127.0.0.1',443).Wait(10000)){throw 'The owned HTTPS listener timed out.'}
  $stream=[Net.Security.SslStream]::new($client.GetStream(),$false);$stream.ReadTimeout=10000;$stream.WriteTimeout=10000;$stream.AuthenticateAsClient($HostName)
  if(!$stream.IsEncrypted -or !$stream.IsAuthenticated){throw 'Trusted tenant HTTPS is required.'}
  $wire=[Text.Encoding]::ASCII.GetBytes("$Method $Path HTTP/1.1`r`nHost: $HostName`r`nConnection: close`r`nContent-Length: 0`r`n`r`n");$stream.Write($wire,0,$wire.Length);$stream.Flush()
  $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8);$text=$reader.ReadToEnd();if($text.Length -gt 262144){throw 'Bounded owned HTTPS response required.'}
  foreach($match in [regex]::Matches($text,'(?im)^Set-Cookie:\s*PHPSESSID=([a-zA-Z0-9,-]{16,128})[;\r]')){$sessionIds.Add($match.Groups[1].Value)}
  return $text
 }finally{if($stream){$stream.Dispose()};$client.Dispose()}
}
function XmlShape([byte[]]$Bytes){$settings=[Xml.XmlReaderSettings]::new();$settings.DtdProcessing='Prohibit';$settings.XmlResolver=$null;$memory=[IO.MemoryStream]::new($Bytes);$reader=[Xml.XmlReader]::Create($memory,$settings);$xml=[xml]::new();$xml.XmlResolver=$null;try{$xml.Load($reader);return $xml.OuterXml}finally{$reader.Dispose();$memory.Dispose()}}
try{
 $phase='packaged_task';$manifest=Get-Content (Join-Path $PackageRoot 'release-manifest.json') -Raw|ConvertFrom-Json
 foreach($name in 'tenant-domains.py','tenant-domains.php','Tenant-Domains.ps1','Install-TenantDomains.ps1','PublicAccess.Common.ps1'){
  $path=Join-Path "$root\tools" $name;Check ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $manifest.files.$name) 'Installed helper matches the actual packaged release'
 }
 $task=Get-ScheduledTask -TaskName $taskName;$taskEnabled=[bool]$task.Settings.Enabled;$taskXml=Export-ScheduledTask -TaskName $taskName
 Check ($task.Description -ceq 'OpenWeb PBX owned tenant HTTPS lease worker') 'Actual task has its owned description'
 Check ($task.Principal.UserId -in 'SYSTEM','S-1-5-18') 'Actual task runs as SYSTEM'
 Check ($task.Principal.RunLevel -eq 'Highest') 'Actual task runs at the required privilege level'
 Check (@($task.Actions).Count -eq 1) 'Actual task contains only one owned action'
 Check ($task.Actions[0].Execute -ceq "$root\backup-runtime\python.exe") 'Actual task executes the installed isolated Python'
 Check ($task.Actions[0].Arguments -ceq '-I "C:\OpenWebPBX\tools\tenant-domains.py"') 'Actual task uses the exact isolated worker arguments'
 Check ($task.Actions[0].WorkingDirectory -ceq "$root\tools") 'Actual task uses the installed tools directory'
 $deadline=[DateTime]::UtcNow.AddSeconds(30);while((Get-ScheduledTask -TaskName $taskName).State -eq 'Running'){if([DateTime]::UtcNow -gt $deadline){throw 'A previous tenant worker did not finish.'};Start-Sleep -Milliseconds 200}
 $saved=SnapshotTree $tenantState;$keyBefore=SaveFile $key;$snapshotComplete=$true
 if(!(Test-Path -LiteralPath $holdRoot)){New-Item -ItemType Directory -Path $holdRoot|Out-Null;$holdRootCreated=$true}
 $holdStream=[IO.File]::Open($hold,'CreateNew','Write','None');try{$bytes=[Text.Encoding]::ASCII.GetBytes($scope);$holdStream.Write($bytes,0,$bytes.Length)}finally{$holdStream.Dispose()};$holdOwned=$true
 $last=(Get-ScheduledTaskInfo -TaskName $taskName).LastRunTime;Start-Sleep -Milliseconds 1100;Enable-ScheduledTask -TaskName $taskName|Out-Null;Start-ScheduledTask -TaskName $taskName
 $deadline=[DateTime]::UtcNow.AddSeconds(45)
 do{Start-Sleep -Milliseconds 250;$run=Get-ScheduledTaskInfo -TaskName $taskName;$running=(Get-ScheduledTask -TaskName $taskName).State -eq 'Running';if([DateTime]::UtcNow -gt $deadline){throw 'The actual SYSTEM task did not complete under maintenance hold.'}}while($running -or $run.LastRunTime -le $last)
 Check ($run.LastTaskResult -eq 0) 'Actual SYSTEM worker honors the maintenance hold without registry traffic';$facts.system_task=$true
 $heldOutput=& "$root\backup-runtime\python.exe" -I "$root\tools\tenant-domains.py" 2>>"$work\worker.private.log";if($LASTEXITCODE){throw 'The held installed worker failed.'};$heldResult=($heldOutput -join "`n")|ConvertFrom-Json;Check ($heldResult.state -ceq 'deferred' -and $heldResult.reason -ceq 'maintenance_or_restore_hold') 'Actual worker returns the closed maintenance result without contacting the registry'
 Disable-ScheduledTask -TaskName $taskName|Out-Null
 $lock=[IO.File]::Open((Join-Path $state 'upgrade.lock'),'Open','ReadWrite','None')
 $appHost=Join-Path $env:windir 'System32\inetsrv\config\applicationHost.config';$iisBefore=SaveFile $appHost;$hosts=Join-Path $env:windir 'System32\drivers\etc\hosts';$hostsBefore=SaveFile $hosts;$rootsBefore=@(Get-ChildItem Cert:\LocalMachine\Root|ForEach-Object Thumbprint|Sort-Object);$myBefore=@(Get-ChildItem Cert:\LocalMachine\My|ForEach-Object Thumbprint|Sort-Object)
 $bindingBefore=Get-OpenWebPublicBindingState $alias;$httpSysBefore=& netsh.exe http show sslcert ('hostnameport='+$alias+':443') 2>$null;Check (!(($httpSysBefore -join "`n").Contains($alias+':443'))) 'Fictional alias starts without an HTTP.sys TLS mapping';Check (!$bindingBefore.present) 'Fictional alias starts without an owned binding'
 $manager=[Microsoft.Web.Administration.ServerManager]::new();try{$vdir=$manager.Sites['OpenWebPBX'].Applications['/'].VirtualDirectories['/.well-known/openwebpbx-instance'];$vdirBefore=if($vdir){$vdir.PhysicalPath}else{$null};$vdirSnapshotTaken=$true}finally{$manager.Dispose()}
 $settings=@{schema=1;alias=$alias;pfx_password=([Guid]::NewGuid().ToString('N'))};[IO.File]::WriteAllText($fixtureInputPath,($settings|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
 $phase='worker_identity';$identity=Python 'identity';$settings.key_hash=$identity.key_hash;try{$prepared=Php 'prepare'}finally{$currentInput=Get-Content -LiteralPath $fixtureInputPath -Raw|ConvertFrom-Json;$dbPrepared=$currentInput.domain -cmatch '^[a-f0-9-]{36}$'}
 $settings=Get-Content -LiteralPath $fixtureInputPath -Raw|ConvertFrom-Json;$settings|Add-Member -NotePropertyName key_hash -NotePropertyValue $identity.key_hash -Force;[IO.File]::WriteAllText($fixtureInputPath,($settings|ConvertTo-Json -Depth 16),[Text.UTF8Encoding]::new($false))
 PrivateAcl $key $false;PrivateAcl (Join-Path $tenantState 'private') $false;$facts.private_acl=$true
 $proof=Python 'proofs';$phase='proof_prepare';$result=Operation 'Prepare';Check ($result.prepared -eq $true) 'Actual packaged Prepare installs the owned proof virtual directory'
 $manager=[Microsoft.Web.Administration.ServerManager]::new();try{$vdir=$manager.Sites['OpenWebPBX'].Applications['/'].VirtualDirectories['/.well-known/openwebpbx-instance'];Check ($vdir -and [IO.Path]::GetFullPath($vdir.PhysicalPath) -ceq (Join-Path $tenantState 'proofs\.well-known\openwebpbx-instance')) 'Actual IIS virtual directory targets owned public proof files'}finally{$manager.Dispose()}
 PrivateAcl (Join-Path $tenantState 'proofs\.well-known\openwebpbx-instance\web.config') $true
 $phase='fixture_certificate';$pki=Start-Process "$root\backup-runtime\python.exe" -ArgumentList @('-I',('"'+(Join-Path $PSScriptRoot 'windows-tenant-domains-native.py')+'"'),'pki',('"'+$fixtureInputPath+'"')) -PassThru -RedirectStandardOutput "$work\pki.private.log" -RedirectStandardError "$work\pki-errors.private.log"
 $deadline=[DateTime]::UtcNow.AddSeconds(30);while(!(Test-Path "$work\pki.json")){if($pki.HasExited -or [DateTime]::UtcNow -gt $deadline){throw 'The private fixture certificate server did not start.'};Start-Sleep -Milliseconds 100}
 $pkiInfo=Get-Content "$work\pki.json" -Raw|ConvertFrom-Json
 $rootCert=Import-Certificate -FilePath "$work\root.cer" -CertStoreLocation Cert:\LocalMachine\Root
 $leaf=Import-PfxCertificate -FilePath "$work\leaf.pfx" -CertStoreLocation Cert:\LocalMachine\My -Password (ConvertTo-SecureString $settings.pfx_password -AsPlainText -Force)
 Check ($rootCert.Thumbprint -ceq $pkiInfo.root_thumbprint -and $leaf.Thumbprint -ceq $pkiInfo.leaf_thumbprint) 'Only the own fixture CA and leaf were imported'
 $null=Get-OpenWebPublicCertificate $leaf.Thumbprint $alias;Check $true 'Actual certificate validator builds the trusted name and online-revocation chain'
 Refuses {Get-OpenWebPublicCertificate $leaf.Thumbprint ('foreign-'+$alias)} 'Actual certificate validator refuses an unmatched alias'
 $firewall='OpenWebPBX-QA-NoAcme-'+$scope;New-NetFirewallRule -Name $firewall -DisplayName $firewall -Direction Outbound -Action Block -Program "$root\acme\wacs.exe"|Out-Null
 $certificateRequest=@{names=@($alias);key_hash=$settings.key_hash;contact='operator@example.invalid'};$requestPath=Join-Path $tenantState 'private\certificate-input.json';[IO.File]::WriteAllText($requestPath,($certificateRequest|ConvertTo-Json),[Text.UTF8Encoding]::new($false));$null=Operation 'FilePrivate' '' $requestPath
 $phase='alias_certify';$recorded=Operation 'Record' $leaf.Thumbprint;Check ($recorded.recorded -eq $true) 'Actual certificate callback records the owned SAN certificate'
 $cachePath=Join-Path $tenantState 'private\certificate.json';[IO.File]::WriteAllBytes($cachePath,[IO.File]::ReadAllBytes((Join-Path $tenantState 'private\pending-certificate.json')));$null=Operation 'FilePrivate' '' $cachePath
 $acmeBefore=SaveFile "$root\acme\settings.json"
 $certified=Operation 'Certify';Check ([DateTimeOffset]::Parse($certified.not_after).UtcDateTime -gt [DateTime]::UtcNow.AddDays(30)) 'Actual Certify reuses the trusted current cache without ACME'
 $acmeAfter=SaveFile "$root\acme\settings.json";Check ($acmeBefore.exists -eq $acmeAfter.exists -and (!$acmeBefore.exists -or ($acmeBefore.bytes -ceq $acmeAfter.bytes -and $acmeBefore.sddl -ceq $acmeAfter.sddl))) 'ACME settings were never changed or invoked'
 $binding=Get-OpenWebPublicBindingState $alias;Check ($binding.present -and $binding.information -ceq ('*:443:'+$alias) -and [BitConverter]::ToString($binding.hash).Replace('-','') -ceq $leaf.Thumbprint -and $binding.store -ceq 'My' -and [int]$binding.flags -eq 1) 'Actual owned alias has the exact SNI certificate binding'
 $null=Operation 'Certify';$repeat=Get-OpenWebPublicBindingState $alias;Check ($repeat.present -and $repeat.information -ceq $binding.information -and [BitConverter]::ToString($repeat.hash).Replace('-','') -ceq $leaf.Thumbprint) 'Repeated Certify preserves one exact owned alias binding'
 Test-OpenWebPublicHttps $alias $leaf.Thumbprint;Check $true 'Actual strict helper verifies the alias certificate over IIS'
 $phase='static_proof_https'
 # Recreate only the original nonce-file ACL, without changing IIS identity or
 # any parent policy. A real denied anonymous read must precede the fix.
 $noncePath=Join-Path $tenantState ('proofs\.well-known\openwebpbx-instance\'+$proof.nonce)
 $null=Assert-OpenWebOrdinaryPath $noncePath
 $manager=[Microsoft.Web.Administration.ServerManager]::new()
 try{$anonymous=$manager.GetApplicationHostConfiguration().GetSection('system.webServer/security/authentication/anonymousAuthentication','OpenWebPBX/.well-known/openwebpbx-instance');Check ([bool]$anonymous['enabled'] -and [string]$anonymous['userName'] -ceq 'IUSR') 'Fresh proof URL uses the actual default IUSR anonymous identity'}finally{$manager.Dispose()}
 try{
  $legacy=Get-Acl -LiteralPath $noncePath
  foreach($rule in @($legacy.Access|Where-Object {$_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -ceq 'S-1-5-17'})){$null=$legacy.RemoveAccessRuleSpecific($rule)}
  Set-Acl -LiteralPath $noncePath -AclObject $legacy
  $denied=Https $alias ('/.well-known/openwebpbx-instance/'+$proof.nonce)
  $status=[regex]::Match($denied,'^HTTP/1\.[01] ([1-5][0-9]{2}) ')
  if($status.Success){$facts.legacy_acl_status=[int]$status.Groups[1].Value}
  Check ($status.Success -and $facts.legacy_acl_status -eq 401 -and !$denied.Contains($proof.body)) 'Actual legacy public ACL denies the anonymous nonce read'
 }finally{$null=Operation 'FilePublic' '' $noncePath}
 PrivateAcl $noncePath $true
 $response=Https $alias ('/.well-known/openwebpbx-instance/'+$proof.nonce)
 $status=[regex]::Match($response,'^HTTP/1\.[01] ([1-5][0-9]{2}) ')
 if($status.Success){$facts.proof_response=@{status=[int]$status.Groups[1].Value;plain_text=[bool]($response -match '(?im)^Content-Type:\s*text/plain');exact_nonce_body=[bool]$response.Contains($proof.body)}}
 Check ($response -match '^HTTP/1\.[01] 200 ' -and $response -match '(?im)^Content-Type:\s*text/plain' -and $response.Contains($proof.body)) 'Actual alias HTTPS serves the precise worker nonce as static text'
 $literal='<?php echo "THIS_MUST_NOT_EXECUTE"; ?>';$response=Https $alias ('/.well-known/openwebpbx-instance/'+$proof.nonce+'-static');Check ($response -match '^HTTP/1\.[01] 200 ' -and $response.Contains($literal)) 'Extensionless PHP-shaped proof content is never executed'
 $response=Https $alias ('/.well-known/openwebpbx-instance/'+$proof.nonce) 'POST';Check ($response -match '^HTTP/1\.[01] (?:403|404|405) ') 'Proof mapping refuses a write-style HTTP method'
 $facts.static_proof_https=$true
 $settings|Add-Member -NotePropertyName not_after -NotePropertyValue $certified.not_after -Force;[IO.File]::WriteAllText($fixtureInputPath,($settings|ConvertTo-Json -Depth 16),[Text.UTF8Encoding]::new($false))
 $null=Python 'ready';PrivateAcl (Join-Path $tenantState 'ready.json') $true;$bound=Php 'ready';Check ($bound.bound -eq $true) 'Actual lease record and transport marker bind only the fictional tenant'
 $phase='alias_guard';$response=Https $alias '/admin/';Check ($response -match '^HTTP/1\.[01] 302 ' -and $response -match '(?im)^Location:\s*/tenantadmin/') 'Actual trusted tenant alias enters the PHP admin route'
 $checked=Php 'verify';Check ($checked.checks -eq 8 -and $checked.owner_and_revision_refusals) 'Actual PHP custody rejects stale and foreign ownership and preserves SIP realm'
 $null=Php 'pending';$response=Https $alias '/admin/';Check ($response -match '^HTTP/1\.[01] 403 ') 'Actual HTTPS refuses a pending tenant transport';$null=Php 'ready'
 Refuses {Https ('foreign-'+$alias) '/admin/'} 'Actual TLS refuses an unlisted tenant hostname'
 $facts.alias_https=$true
 $phase='foreign_binding';$foreign='OpenWebPBX-QA-Foreign-'+$scope;$foreignRoot=Join-Path $work 'foreign-web';New-Item -ItemType Directory -Path $foreignRoot|Out-Null
 $manager=[Microsoft.Web.Administration.ServerManager]::new();try{$site=$manager.Sites.Add($foreign,'http',('*:8097:'+$alias),$foreignRoot);$site.ServerAutoStart=$false;$manager.CommitChanges()}finally{$manager.Dispose()}
 Refuses {Operation 'Certify'} 'Actual Certify refuses a hostname claimed by another IIS site'
 $same=Get-OpenWebPublicBindingState $alias;Check ($same.information -ceq $binding.information -and [BitConverter]::ToString($same.hash).Replace('-','') -ceq $leaf.Thumbprint) 'Foreign binding refusal preserves the original alias binding'
 $manager=[Microsoft.Web.Administration.ServerManager]::new();try{$manager.Sites.Remove($manager.Sites[$foreign]);$manager.CommitChanges();$foreign=$null}finally{$manager.Dispose()}
 $proofPath=Join-Path $tenantState 'proofs\.well-known\openwebpbx-instance'
 $manager=[Microsoft.Web.Administration.ServerManager]::new();try{$manager.Sites['OpenWebPBX'].Applications['/'].VirtualDirectories['/.well-known/openwebpbx-instance'].PhysicalPath=$foreignRoot;$manager.CommitChanges()}finally{$manager.Dispose()}
 try{Refuses {Operation 'Prepare'} 'Actual Prepare refuses a foreign virtual-directory target'}finally{$manager=[Microsoft.Web.Administration.ServerManager]::new();try{$v=$manager.Sites['OpenWebPBX'].Applications['/'].VirtualDirectories['/.well-known/openwebpbx-instance'];if($v.PhysicalPath -cne $foreignRoot){throw 'The owned refusal fixture changed unexpectedly.'};$v.PhysicalPath=$proofPath;$manager.CommitChanges()}finally{$manager.Dispose()}}
 $facts.foreign_binding_refused=$true
}catch{
 $failurePhase=$phase;$primaryFailure=$_;[IO.File]::WriteAllText((Join-Path $work 'failure.private.log'),$_.Exception.ToString())
}finally{
 try{
  $phase='cleanup'
  if($foreign){$manager=[Microsoft.Web.Administration.ServerManager]::new();try{$site=$manager.Sites[$foreign];if($site){if([IO.Path]::GetFullPath($site.Applications['/'].VirtualDirectories['/'].PhysicalPath) -cne $foreignRoot){throw 'The own foreign-site fixture changed.'};$manager.Sites.Remove($site);$manager.CommitChanges()}}finally{$manager.Dispose()}}
  if($iisBefore){
   $current=Get-OpenWebPublicBindingState $alias
   if($current.present){if(!$leaf -or [BitConverter]::ToString($current.hash).Replace('-','') -cne $leaf.Thumbprint -or $current.information -cne ('*:443:'+$alias)){throw 'The own alias binding changed during cleanup.'};Restore-OpenWebPublicBinding $alias $bindingBefore}
   $httpSysAfter=& netsh.exe http show sslcert ('hostnameport='+$alias+':443') 2>$null
   if(($httpSysAfter -join "`n").Contains($alias+':443')){if(!$leaf -or ($httpSysAfter -join '').Replace(' ','') -notmatch [regex]::Escape($leaf.Thumbprint)){throw 'The own HTTP.sys certificate mapping changed.'};$null=& netsh.exe http delete sslcert ('hostnameport='+$alias+':443');if($LASTEXITCODE){throw 'The own HTTP.sys certificate mapping could not be removed.'}}
   if($vdirSnapshotTaken){$manager=[Microsoft.Web.Administration.ServerManager]::new();try{$v=$manager.Sites['OpenWebPBX'].Applications['/'].VirtualDirectories['/.well-known/openwebpbx-instance'];if($v){if($v.PhysicalPath -cne (Join-Path $tenantState 'proofs\.well-known\openwebpbx-instance')){throw 'The own proof virtual directory changed during cleanup.'};if($null -eq $vdirBefore){$manager.Sites['OpenWebPBX'].Applications['/'].VirtualDirectories.Remove($v)}else{$v.PhysicalPath=$vdirBefore};$manager.CommitChanges()}}finally{$manager.Dispose()}}
   # Normalize only to prove that all original IIS semantics/comments survived;
   # restore formatting bytes only when that exact comparison already passed.
   $currentBytes=[IO.File]::ReadAllBytes($appHost);$beforeBytes=[Convert]::FromBase64String($iisBefore.bytes)
   Check ((XmlShape $currentBytes) -ceq (XmlShape $beforeBytes)) 'All original IIS settings and comments are exact after removing own bindings'
   if([Convert]::ToBase64String($currentBytes) -cne $iisBefore.bytes){[IO.File]::WriteAllBytes($appHost,$beforeBytes)}
   Check ((Get-Acl -LiteralPath $appHost).Sddl -ceq $iisBefore.sddl -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($appHost)) -ceq $iisBefore.bytes) 'Original applicationHost bytes and ACL are exact'
  }
  if($dbPrepared){$clean=Php 'cleanup';Check ($clean.original_database_exact -eq $true) 'Original factory database rows are exact'}
  foreach($id in @($sessionIds|Sort-Object -Unique)){$session=Join-Path $state ('sessions\sess_'+$id);if(Test-Path -LiteralPath $session){$null=Assert-OpenWebOrdinaryPath $session;Remove-Item -LiteralPath $session -Force}}
  if($snapshotComplete){RestoreTree $tenantState $saved;RestoreFile $key $keyBefore;Check (SameTree $saved (SnapshotTree $tenantState)) 'Original tenant-worker state files and ACLs are exact';$restored=SaveFile $key;Check ($restored.exists -eq $keyBefore.exists -and (!$restored.exists -or ($restored.bytes -ceq $keyBefore.bytes -and $restored.sddl -ceq $keyBefore.sddl))) 'Original instance key bytes and ACL are exact'}
  if($leaf -and (Test-Path ('Cert:\LocalMachine\My\'+$leaf.Thumbprint))){Remove-Item -LiteralPath ('Cert:\LocalMachine\My\'+$leaf.Thumbprint) -DeleteKey -Force}
  if($rootCert -and (Test-Path ('Cert:\LocalMachine\Root\'+$rootCert.Thumbprint))){Remove-Item -LiteralPath ('Cert:\LocalMachine\Root\'+$rootCert.Thumbprint) -Force}
  if($pkiInfo){& certutil.exe -urlcache $pkiInfo.crl_url delete 1>"$work\crl-cache-cleanup.private.log" 2>&1}
  if($pki){[IO.File]::WriteAllText((Join-Path $work 'stop-pki'),'stop');if(!$pki.WaitForExit(10000)){Stop-Process -Id $pki.Id -Force};$pki.Dispose()}
  if($firewall){$rule=Get-NetFirewallRule -Name $firewall -ErrorAction SilentlyContinue;if($rule){if($rule.DisplayName -cne $firewall -or $rule.Action -ne 'Block' -or $rule.Direction -ne 'Outbound'){throw 'The own ACME safety rule changed.'};Remove-NetFirewallRule -Name $firewall}}
  if($iisBefore){Check ((SaveFile $hosts).bytes -ceq $hostsBefore.bytes -and (SaveFile $hosts).sddl -ceq $hostsBefore.sddl) 'Hosts bytes and ACL were untouched';Check ((@(Get-ChildItem Cert:\LocalMachine\Root|ForEach-Object Thumbprint|Sort-Object) -join ',') -ceq ($rootsBefore -join ',') -and (@(Get-ChildItem Cert:\LocalMachine\My|ForEach-Object Thumbprint|Sort-Object) -join ',') -ceq ($myBefore -join ',')) 'Both original certificate stores are exact'}
  if($holdOwned){if([IO.File]::ReadAllText($hold) -cne $scope){throw 'The own maintenance hold changed.'};Remove-Item -LiteralPath $hold -Force}
  if($holdRootCreated -and (Get-ChildItem -LiteralPath $holdRoot -Force|Measure-Object).Count -eq 0){Remove-Item -LiteralPath $holdRoot}
  if($lock){$lock.Dispose();$lock=$null}
  if($taskXml){if($taskEnabled){Enable-ScheduledTask -TaskName $taskName|Out-Null}else{Disable-ScheduledTask -TaskName $taskName|Out-Null};Check ((Export-ScheduledTask -TaskName $taskName) -ceq $taskXml) 'Original SYSTEM task definition and enabled choice are exact'}
  $facts.cleanup_exact=$true
 }catch{$cleanupFailure=$_;[IO.File]::WriteAllText((Join-Path $work 'cleanup-failure.private.log'),$_.Exception.ToString())}
 if($lock){$lock.Dispose()}
 $facts.checks=$checks.Count;$facts.phase=$phase
 if(!$primaryFailure -and !$cleanupFailure){$facts.state='passed';$facts.phase='complete'}else{$facts.state='failed';$facts.phase=if($cleanupFailure){'cleanup'}else{$failurePhase};$failure=if($cleanupFailure){$cleanupFailure}else{$primaryFailure};$facts.source_line=CheckSourceLine $failure;$facts.exception_type=$failure.Exception.GetType().Name;$basename=if($failure.InvocationInfo.ScriptName){Split-Path -Leaf $failure.InvocationInfo.ScriptName}else{'external_component'};$facts.source_basename=if($basename -cin @('windows-tenant-domains-native.ps1','PublicAccess.Common.ps1','Tenant-Domains.ps1')){$basename}else{'external_component'}}
 [IO.File]::WriteAllText($ReportPath,($facts|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
}
if($facts.state -ne 'passed'){throw 'The actual native tenant-domain gate failed; its bounded report and private recovery evidence were retained.'}
$facts|ConvertTo-Json -Depth 5
