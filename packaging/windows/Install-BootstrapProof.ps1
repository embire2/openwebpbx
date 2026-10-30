#Requires -RunAsAdministrator
# SPDX-License-Identifier: AGPL-3.0-or-later
[CmdletBinding()]
param([string]$PublicAddress='')
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT){throw 'Windows is required.'}
. (Join-Path $PSScriptRoot 'PublicAccess.Common.ps1')
if(!$PublicAddress){
 $PublicAddress=([string](Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 10 -MaximumRedirection 0)).Trim()
}
$PublicAddress=Assert-OpenWebPublicAddress $PublicAddress
$state=Join-Path $env:ProgramData 'OpenWebPBX\tenant-domains'
$physical=Join-Path $state 'bootstrap-http';$proof=Join-Path $state 'proofs\.well-known\openwebpbx-instance'
if(Test-Path -LiteralPath $physical){
 $null=Assert-OpenWebOrdinaryPath $physical $true
 if(@(Get-ChildItem -LiteralPath $physical -Force|Where-Object {$_.Name -cne 'web.config'}).Count){throw 'The setup proof directory contains files from another installation.'}
}
function Set-OpenWebSetupPublicDirectory([string]$Path){
 if(!(Test-Path -LiteralPath $Path)){New-Item -ItemType Directory -Path $Path|Out-Null}
 $null=Assert-OpenWebOrdinaryPath $Path $true
 $acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetAccessRuleProtection($true,$false);$acl.SetOwner([Security.Principal.SecurityIdentifier]'S-1-5-32-544')
 foreach($sid in 'S-1-5-18','S-1-5-32-544'){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]$sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
 foreach($sid in 'S-1-5-32-568','S-1-5-17','S-1-5-19'){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]$sid,'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow'))}
 Set-Acl -LiteralPath $Path -AclObject $acl
}
foreach($folder in @($state,(Join-Path $state 'proofs'),(Join-Path $state 'proofs\.well-known'),$proof,$physical)){Set-OpenWebSetupPublicDirectory $folder}
$config=Join-Path $physical 'web.config'
$bytes=[Text.UTF8Encoding]::new($false).GetBytes('<configuration><system.webServer><handlers><clear/><add name="OpenWebSetupProofStatic" path="*" verb="GET,HEAD" modules="StaticFileModule" resourceType="File" requireAccess="Read"/></handlers><directoryBrowse enabled="false"/><defaultDocument enabled="false"/><staticContent><remove fileExtension="."/><mimeMap fileExtension="." mimeType="text/plain"/></staticContent><security><requestFiltering><verbs allowUnlisted="false"><clear/><add verb="GET" allowed="true"/><add verb="HEAD" allowed="true"/></verbs><fileExtensions allowUnlisted="false"><clear/><add fileExtension="." allowed="true"/></fileExtensions></requestFiltering></security><httpProtocol><customHeaders><remove name="Cache-Control"/><add name="Cache-Control" value="no-store"/></customHeaders></httpProtocol></system.webServer></configuration>')
if(Test-Path -LiteralPath $config){
 $null=Assert-OpenWebOrdinaryPath $config
 if([Convert]::ToBase64String([IO.File]::ReadAllBytes($config)) -cne [Convert]::ToBase64String($bytes)){throw 'The setup proof configuration belongs to another installation.'}
}else{
 $stream=[IO.FileStream]::new($config,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
 try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
}
Add-Type -Path (Join-Path $env:windir 'System32\inetsrv\Microsoft.Web.Administration.dll')
$manager=[Microsoft.Web.Administration.ServerManager]::new();$name='OpenWebPBX-SetupProof';$binding='*:80:'+$PublicAddress
try{
 foreach($other in $manager.Sites){foreach($entry in $other.Bindings){if($entry.Protocol -eq 'http' -and $entry.EndPoint.Port -eq 80 -and $entry.Host -ceq $PublicAddress -and $other.Name -cne $name){throw 'Another IIS site already owns this public IPv4 setup address. Preserve it and choose a dedicated server.'}}}
 $pool=$manager.ApplicationPools[$name]
 if($pool){foreach($other in $manager.Sites){foreach($application in $other.Applications){if($application.ApplicationPoolName -ceq $name -and $other.Name -cne $name){throw 'Another IIS site uses the setup proof application pool.'}}}}
 if($pool -and $pool.ManagedRuntimeVersion -ne ''){throw 'The setup proof application pool belongs to another configuration.'}
 if(!$pool){$pool=$manager.ApplicationPools.Add($name);$pool.ManagedRuntimeVersion=''}
 $site=$manager.Sites[$name]
 if($site){
  $app=$site.Applications['/']
  if($site.Applications.Count -ne 1 -or !$app -or $app.ApplicationPoolName -cne $name -or $app.VirtualDirectories.Count -ne 2 -or [IO.Path]::GetFullPath($app.VirtualDirectories['/'].PhysicalPath) -cne $physical -or !$app.VirtualDirectories['/.well-known/openwebpbx-instance'] -or [IO.Path]::GetFullPath($app.VirtualDirectories['/.well-known/openwebpbx-instance'].PhysicalPath) -cne $proof -or $site.Bindings.Count -ne 1 -or $site.Bindings[0].Protocol -cne 'http' -or $site.Bindings[0].BindingInformation -cne $binding){throw 'The setup proof site belongs to another configuration.'}
 }else{
  $site=$manager.Sites.Add($name,'http',$binding,$physical);$site.Applications['/'].ApplicationPoolName=$name
  $null=$site.Applications['/'].VirtualDirectories.Add('/.well-known/openwebpbx-instance',$proof)
 }
 $section=$manager.GetApplicationHostConfiguration().GetSection('system.webServer/handlers',$name)
 $section.OverrideMode=[Microsoft.Web.Administration.OverrideMode]::Allow
 $site.ServerAutoStart=$true;$pool.AutoStart=$true;$manager.CommitChanges()
 if($pool.State -ne 'Started'){$null=$pool.Start()};if($site.State -ne 'Started'){$null=$site.Start()}
}finally{$manager.Dispose()}
$ruleName='OpenWebPBX-SetupProof-HTTP80';$description='OpenWeb PBX owned static installation proof over HTTP'
$rule=Get-NetFirewallRule -PolicyStore PersistentStore -Name $ruleName -ErrorAction SilentlyContinue
if($rule){
 $ports=$rule|Get-NetFirewallPortFilter;$program=$rule|Get-NetFirewallApplicationFilter;$addresses=$rule|Get-NetFirewallAddressFilter
 if(@($rule).Count -ne 1 -or $rule.Description -cne $description -or $rule.Direction -ne 'Inbound' -or $rule.Action -ne 'Allow' -or $rule.Enabled -ne 'True' -or $rule.Profile -ne 'Any' -or $ports.Protocol -notin 'TCP','6' -or $ports.LocalPort -ne '80' -or $ports.RemotePort -ne 'Any' -or $program.Program -cne 'System' -or $addresses.LocalAddress -ne 'Any' -or $addresses.RemoteAddress -ne 'Any'){throw 'The setup proof firewall rule belongs to another configuration.'}
}else{
 New-NetFirewallRule -PolicyStore PersistentStore -Name $ruleName -DisplayName 'OpenWeb PBX installation proof (HTTP)' -Description $description -Direction Inbound -Action Allow -Protocol TCP -LocalPort 80 -Program System -Profile Any -Enabled True|Out-Null
}
[pscustomobject]@{PublicAddress=$PublicAddress;ProofUrl='http://'+$PublicAddress+'/.well-known/openwebpbx-instance/'}
