# Actual IIS/FastCGI regression; credentials and response bodies stay private.
# Uses an isolated loopback HTTPS site with a read-only real application copy.
# Only the candidate API location and explicit module preconditions replace
# copied runtime configuration. See IIS managedHandler/preCondition semantics:
# https://learn.microsoft.com/en-us/iis/get-started/introduction-to-iis/iis-modules-overview
# https://learn.microsoft.com/en-us/iis/application-frameworks/building-and-running-aspnet-applications/wildcard-script-mapping-and-iis-integrated-pipeline
[CmdletBinding()]
param(
 [Parameter(Mandatory=$true)][string]$WebRoot,
 [Parameter(Mandatory=$true)][string]$PreviousConfigFile,
 [Parameter(Mandatory=$true)][string]$CredentialFile,
 [Parameter(Mandatory=$true)][string]$OutputRoot,
 [switch]$UploadOnly,
 [string]$ExistingCopyRoot,
 [string]$CandidateConfigFile=(Join-Path $PSScriptRoot '..\packaging\windows\web.config')
)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if([Environment]::OSVersion.Platform-ne'Win32NT'){throw 'Actual Windows IIS required'}
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if(!([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Administrator required for isolated IIS site'}
$credential=[IO.File]::ReadAllText($CredentialFile)|ConvertFrom-Json
$hostName=[string]$credential.host;$domain=[string]$credential.domain_uuid
if($hostName-cnotmatch '^[a-z0-9-]+[.]openwebpbx[.]com$'-or$domain-cnotmatch '^[a-f0-9-]{36}$'){throw 'Exact registered target required'}
foreach($key in @($credential.admin,$credential.readonly)){if($key-cnotmatch '^owpbx_[a-f0-9]{32}_[a-f0-9]{64}$'){throw 'Existing scoped API keys required'}}
foreach($file in @($PreviousConfigFile,$CandidateConfigFile,(Join-Path $WebRoot 'api\v2\index.php'),(Join-Path $WebRoot 'bin\OpenWebPbx.UploadAdmission.dll'))){if(!(Test-Path -LiteralPath $file -PathType Leaf)){throw 'Required real application input missing'}}
if(Test-Path -LiteralPath $OutputRoot){throw 'Preserve previous evidence'}
[IO.Directory]::CreateDirectory($OutputRoot)|Out-Null
$privateAcl=[Security.AccessControl.DirectorySecurity]::new();$privateAcl.SetAccessRuleProtection($true,$false)
foreach($sid in 'S-1-5-18','S-1-5-32-544'){$privateAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]$sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
Set-Acl -LiteralPath $OutputRoot -AclObject $privateAcl
$tag='OpenWebPBX-IIS-QA-'+[Guid]::NewGuid().ToString('N');$copy=if($UploadOnly){[IO.Path]::GetFullPath($ExistingCopyRoot)}else{Join-Path (Split-Path $WebRoot -Parent) $tag};$checks=[Collections.Generic.List[object]]::new();$created=$false;$sslAdded=$false;$contact=$null;$completed=$false
if($UploadOnly-and(!$ExistingCopyRoot-or(Split-Path $copy -Parent)-cne(Split-Path ([IO.Path]::GetFullPath($WebRoot)) -Parent)-or(Split-Path $copy -Leaf)-cnotmatch'^OpenWebPBX-IIS-QA-[a-f0-9]{32}$'-or!(Test-Path -LiteralPath $copy -PathType Container))){throw 'Explicit existing owned source copy required for upload-only controls'}
foreach($path in @($WebRoot,$copy)){if((Test-Path -LiteralPath $path)-and((Get-Item -LiteralPath $path -Force).Attributes-band[IO.FileAttributes]::ReparsePoint)){throw 'Linked application roots refused'}}
[xml]$installed=[IO.File]::ReadAllText((Join-Path $WebRoot 'web.config'))
if($installed.SelectSingleNode('/configuration/location[@path="api/v2"]/system.webServer/modules/remove[@name="FileAuthorization"]')){throw 'Previous installed hosting behavior required for regression'}
[xml]$candidate=[IO.File]::ReadAllText($CandidateConfigFile);[xml]$previous=[IO.File]::ReadAllText($PreviousConfigFile)
$candidateLocation=$candidate.SelectSingleNode('/configuration/location[@path="api/v2"]').CloneNode($true)
$candidateModules=$candidate.SelectSingleNode('/configuration/system.webServer/modules')
$admission=$candidateModules.SelectSingleNode('add[@name="OpenWebPBX-UploadAdmission"]')
if($candidateModules.GetAttribute('runAllManagedModulesForAllRequests')-cne'false'-or!$admission.HasAttribute('preCondition')-or$admission.GetAttribute('preCondition')-cne''){throw 'Explicit intended managed-handler boundary required'}
$candidateModules.SetAttribute('runAllManagedModulesForAllRequests','true');$admission.RemoveAttribute('preCondition')
foreach($xml in @($candidate,$previous)){
 [void]$xml.DocumentElement.RemoveChild($xml.SelectSingleNode('/configuration/location[@path="api/v2"]'))
 foreach($comment in @($xml.SelectNodes('//comment()'))){[void]$comment.ParentNode.RemoveChild($comment)}
}
if($candidate.OuterXml-cne$previous.OuterXml){throw 'Candidate changes outside the API and intended module boundary are refused'}
function Assert-Control([bool]$condition,[string]$name){$checks.Add(@{name=$name;passed=$condition});if(!$condition){throw ('IIS API control failed: '+$name)}}
Add-Type -Path "$env:SystemRoot\System32\inetsrv\Microsoft.Web.Administration.dll"
function Configuration-Fingerprint {
 [xml]$applicationHost=[IO.File]::ReadAllText("$env:SystemRoot\System32\inetsrv\config\applicationHost.config")
 $result=@();foreach($section in 'sites','applicationPools'){
  $element=$applicationHost.SelectSingleNode('/configuration/system.applicationHost/'+$section).CloneNode($true)
  foreach($child in @($element.ChildNodes)){if($child.NodeType-eq[Xml.XmlNodeType]::Element-and$child.Attributes['name']-and$child.Attributes['name'].Value-ceq$tag){[void]$element.RemoveChild($child)}}
  $result+=$element.OuterXml
 };foreach($location in $applicationHost.SelectNodes('/configuration/location')){if($location.path-cne$tag-and!$location.path.StartsWith($tag+'/',[StringComparison]::Ordinal)){$result+=$location.OuterXml}};return ($result-join "`n")
}
$before=Configuration-Fingerprint;$originalAcl=(Get-Acl -LiteralPath $WebRoot).Sddl;$originalConfig=(Get-FileHash (Join-Path $WebRoot 'web.config') -Algorithm SHA256).Hash
try {
 if(!$UploadOnly){
 if(Test-Path -LiteralPath $copy){throw 'Preserve previous isolated application'}
 $copyProcess=Start-Process -FilePath "$env:SystemRoot\System32\robocopy.exe" -ArgumentList @(('"'+$WebRoot+'"'),('"'+$copy+'"'),'/E','/COPY:DAT','/DCOPY:DAT','/XJ','/R:0','/W:0','/NFL','/NDL','/NJH','/NJS') -Wait -PassThru -RedirectStandardOutput (Join-Path $OutputRoot 'copy.stdout.private.log') -RedirectStandardError (Join-Path $OutputRoot 'copy.stderr.private.log')
 if($copyProcess.ExitCode-ge8){throw 'Real application copy failed'}
 }
 $readAcl=[Security.AccessControl.DirectorySecurity]::new();$readAcl.SetAccessRuleProtection($true,$false)
 foreach($sid in 'S-1-5-18','S-1-5-32-544'){$readAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]$sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
 foreach($sid in 'S-1-5-17','S-1-5-32-568'){$readAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]$sid,'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow'))}
 Set-Acl -LiteralPath $copy -AclObject $readAcl;$readAclBefore=(Get-Acl -LiteralPath $copy).Sddl
 $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop()
 $manager=[Microsoft.Web.Administration.ServerManager]::new()
 try {
  $sourceBindings=@($manager.Sites|ForEach-Object{$_.Bindings}|Where-Object{$_.Protocol-ceq'https'-and$_.Host-ceq$hostName})
  if($sourceBindings.Count-ne1-or!$sourceBindings[0].CertificateHash){throw 'One existing trusted canonical certificate required'}
  $hash=$sourceBindings[0].CertificateHash;$store=$sourceBindings[0].CertificateStoreName
  # Reuse the installed pool's existing private-config authority without granting
  # a new SID access to product configuration or changing the pool itself.
  if(!$manager.ApplicationPools['OpenWebPBX']){throw 'Existing product pool required'}
  $site=$manager.Sites.Add($tag,'https',('127.0.0.1:'+ $port +':'+$hostName),$copy);$site.Applications['/'].ApplicationPoolName='OpenWebPBX'
  # Keep the application's configured PROJECT_ROOT and require_once paths exact.
  # The owned root supplies hosting configuration; PHP entrypoints use the
  # original read-only folders, avoiding a second framework bootstrap.
  foreach($directory in 'api','app'){$null=$site.Applications['/'].VirtualDirectories.Add(('/'+$directory),(Join-Path $WebRoot $directory))}
  # Match Install-Reseller's site-scoped delegation; new sites inherit locked
  # defaults and otherwise fail before the real application can be exercised.
  foreach($section in 'handlers','modules','serverRuntime'){$manager.GetApplicationHostConfiguration().GetSection(('system.webServer/'+$section),$tag).OverrideMode=[Microsoft.Web.Administration.OverrideMode]::Allow}
  $binding=$site.Bindings[0];$binding.CertificateHash=$hash;$binding.CertificateStoreName=$store;$binding.SslFlags=[Microsoft.Web.Administration.SslFlags]::Sni
  $manager.CommitChanges();$created=$true;$sslAdded=$true
 }finally{$manager.Dispose()}
 function Request-Api([string]$method,[string]$route,[string]$key,[object]$body=$null,[string]$label='request',[hashtable]$extraHeaders=@{}) {
  $number=$checks.Count.ToString('D3')+'-'+$label;$bodyPath=Join-Path $OutputRoot ($number+'.body.private.json');$headPath=Join-Path $OutputRoot ($number+'.headers.private.txt');$stderr=Join-Path $OutputRoot ($number+'.stderr.private.log');$statusPath=Join-Path $OutputRoot ($number+'.status.private.txt')
  $headerFile=Join-Path $OutputRoot ($number+'.curl.private.conf')
  $headers=@(('Host: '+$hostName),('Authorization: Bearer '+$key),('Content-Type: '+$(if($extraHeaders.ContainsKey('Content-Type')){$extraHeaders['Content-Type']}else{'application/json'})))
  foreach($name in $extraHeaders.Keys){if($name-cne'Content-Type'){$headers+=($name+': '+$extraHeaders[$name])}}
  [IO.File]::WriteAllLines($headerFile,@($headers|ForEach-Object{'header = "'+$_.Replace('\','\\').Replace('"','\"')+'"'}),[Text.UTF8Encoding]::new($false))
  $arguments=@('--silent','--show-error','--noproxy','*','--connect-timeout','10','--max-time','30','--resolve',($hostName+':'+$port+':127.0.0.1'),'-X',$method,'--config',$headerFile,'--dump-header',$headPath,'--output',$bodyPath,'--write-out','%{http_code}')
  if($method-ceq'HEAD'){$arguments+='--head'}
  if($null-ne$body){$inputFile=Join-Path $OutputRoot ($number+'.input.private.json');[IO.File]::WriteAllText($inputFile,($body|ConvertTo-Json -Depth 8 -Compress),[Text.UTF8Encoding]::new($false));$arguments+=@('--data-binary',('@'+$inputFile))}
  $arguments+=('https://'+$hostName+':'+$port+$route)
  # Native curl stderr is not a PowerShell error stream. TLS verification stays on.
  $quoted=[string]::Join(' ',@($arguments|ForEach-Object{'"'+$_.Replace('"','\"')+'"'}))
  $requestClock=[Diagnostics.Stopwatch]::StartNew()
  $process=Start-Process -FilePath "$env:SystemRoot\System32\curl.exe" -ArgumentList $quoted -Wait -PassThru -RedirectStandardOutput $statusPath -RedirectStandardError $stderr
  $process.WaitForExit();$process.Refresh()
  if($process.ExitCode-ne0){throw 'Ordinary trusted loopback HTTPS request failed'}
  $status=[int][IO.File]::ReadAllText($statusPath);$raw=[IO.File]::ReadAllText($bodyPath);$value=$null;try{$value=$raw|ConvertFrom-Json}catch{}
  return @{status=$status;json=$value;raw=$raw;elapsed=$requestClock.Elapsed.TotalSeconds;headers=[IO.File]::ReadAllText($headPath)}
 }
 if(!$UploadOnly){
 $root=Request-Api 'GET' '/api/v2/' $credential.admin $null 'old-get';Assert-Control ($root.status-eq200-and$root.json.data.key.domain_uuid-ceq$domain) 'previous_real_app_bound_get'
 $old=Request-Api 'DELETE' ('/api/v2/pbx/'+$domain+'/contacts/'+[Guid]::NewGuid().ToString()) $credential.admin @{confirm_delete=$true} 'old-delete'
 Assert-Control ($old.status-eq401-and$null-eq$old.json) 'previous_delete_refused_before_php'
 $baselineUi=Request-Api 'GET' '/app/pbx_setup/?view=users' $credential.admin $null 'old-ui'
 Assert-Control ($baselineUi.status-eq200-and$baselineUi.raw-match'<title>Login.*OpenWeb PBX</title>'-and$baselineUi.raw-match'name=["'']username["'']'-and$baselineUi.raw-match'name=["'']password["'']') 'previous_browser_session_required'
 [xml]$runtimeCopy=[IO.File]::ReadAllText((Join-Path $copy 'web.config'))
 $oldLocation=$runtimeCopy.SelectSingleNode('/configuration/location[@path="api/v2"]')
 [void]$runtimeCopy.DocumentElement.ReplaceChild($runtimeCopy.ImportNode($candidateLocation,$true),$oldLocation)
 $runtimeCopy.SelectSingleNode('/configuration/system.webServer/modules').SetAttribute('runAllManagedModulesForAllRequests','false')
 $runtimeCopy.SelectSingleNode('/configuration/system.webServer/modules/add[@name="OpenWebPBX-UploadAdmission"]').SetAttribute('preCondition','')
 $runtimeCopy.Save((Join-Path $copy 'web.config'))
 # Only this isolated application's configuration changed.
 }else{
  [xml]$runtimeCopy=[IO.File]::ReadAllText((Join-Path $copy 'web.config'));if($runtimeCopy.SelectSingleNode('/configuration/location[@path="api/v2"]').OuterXml-cne$candidateLocation.OuterXml-or$runtimeCopy.SelectSingleNode('/configuration/system.webServer/modules').GetAttribute('runAllManagedModulesForAllRequests')-cne'false'-or$runtimeCopy.SelectSingleNode('/configuration/system.webServer/modules/add[@name="OpenWebPBX-UploadAdmission"]').GetAttribute('preCondition')-cne''){throw 'Existing copy is not the exact candidate hosting configuration'}
 }
 $current=Request-Api 'GET' '/api/v2/' $credential.admin $null 'fixed-get';Assert-Control ($current.status-eq200-and$current.json.data.key.domain_uuid-ceq$domain) 'candidate_real_app_bound_get'
 if(!$UploadOnly){
 foreach($method in 'GET','POST','DELETE'){
  $bad=Request-Api $method '/api/v2/' ('owpbx_'+('0'*32)+'_'+('0'*64)) $(if($method-ceq'GET'){$null}else{@{}}) ('badkey-'+$method)
  Assert-Control ($bad.status-in401,403-and$null-ne$bad.json.error) ('bad_key_'+$method)
  $foreign=Request-Api $method ('/api/v2/pbx/'+[Guid]::NewGuid().ToString()+'/contacts') $credential.admin $(if($method-ceq'GET'){$null}else{@{}}) ('foreign-'+$method)
  Assert-Control ($foreign.status-eq403-and$foreign.json.error.code-ceq'access_denied') ('foreign_scope_'+$method)
 }
 foreach($method in 'PUT','PATCH','OPTIONS','HEAD'){
  $response=Request-Api $method '/api/v2/' $credential.admin $(if($method-ceq'HEAD'){$null}else{@{}}) ('method-'+$method)
  Assert-Control ($response.status-eq405-and($method-ceq'HEAD'-or$response.json.error.code-ceq'method_not_allowed')) ('application_method_refusal_'+$method)
 }
 $create=Request-Api 'POST' ('/api/v2/pbx/'+$domain+'/contacts') $credential.admin @{first_name='Owned IIS verb regression';last_name=$tag;company='Windows27 QA';phone='101';email='';owner=''} 'contact-create'
 Assert-Control ($create.status-eq200-and$create.json.data.id) 'authorized_contact_post';$contact=[string]$create.json.data.id
 $readOnly=Request-Api 'DELETE' ('/api/v2/pbx/'+$domain+'/contacts/'+$contact) $credential.readonly @{confirm_delete=$true} 'readonly-delete'
 Assert-Control ($readOnly.status-eq403-and$readOnly.json.error.code-ceq'access_denied') 'readonly_key_delete_refused'
 $delete=Request-Api 'DELETE' ('/api/v2/pbx/'+$domain+'/contacts/'+$contact) $credential.admin @{confirm_delete=$true} 'authorized-delete'
 Assert-Control ($delete.status-eq200-and$delete.json.data.deleted-eq$true) 'authorized_contact_delete';$contact=$null
 foreach($method in 'GET','DELETE'){$outside=Request-Api $method '/app/pbx_setup/?view=users' $credential.admin $(if($method-ceq'GET'){$null}else{@{}}) ('outside-api-'+$method);Assert-Control ($outside.status-eq$baselineUi.status-and$outside.raw-match'<title>Login.*OpenWeb PBX</title>'-and$outside.raw-match'name=["'']username["'']'-and$outside.raw-match'name=["'']password["'']') ('non_api_browser_session_required_'+$method)}
 }
 $inbox=Join-Path $env:ProgramData 'OpenWebPBX\protection-inbox';$inboxBefore=@([IO.Directory]::GetFiles($inbox,'*',[IO.SearchOption]::AllDirectories)|Sort-Object)
 $upload=Request-Api 'POST' '/api/v2/upload.php' $credential.admin @{} 'upload-direct'
 Assert-Control ($upload.status-eq404-and$upload.json.error.code-ceq'upload_refused') 'api_direct_upload_admission_retained'
 $directGate=Request-Api 'POST' '/app/pbx_protection/upload_gate.php' $credential.admin @{} 'full-direct-gate';Assert-Control ($directGate.status-eq404-and$directGate.json.error.code-ceq'upload_refused') 'full_direct_gate_refused'
 foreach($route in '/app/pbx_protection/upload.php','/api/v2/instance/backups/import'){
  $label=if($route.StartsWith('/api/')){'api'}else{'full'}
  $refused=Request-Api 'POST' $route $credential.admin @{} ('upload-'+$label);Assert-Control ($refused.status-in401,403-and$refused.json.error.code-ceq'upload_refused') ($label+'_upload_authority_admission_retained')
  $large=Request-Api 'POST' $route $credential.admin $null ('large-upload-'+$label) @{'Content-Type'='application/octet-stream';'Content-Length'='2147483649';'Expect'='100-continue'}
  Assert-Control (($large.status-in400,413-or($large.status-in401,403-and$large.json.error.code-ceq'upload_refused'))-and$large.elapsed-lt10) ($label+'_large_upload_refused_without_body')
 }
 $inboxAfter=@([IO.Directory]::GetFiles($inbox,'*',[IO.SearchOption]::AllDirectories)|Sort-Object);Assert-Control ([string]::Join("`n",$inboxBefore)-ceq[string]::Join("`n",$inboxAfter)) 'refused_uploads_created_no_inbox_files'
 $manager=[Microsoft.Web.Administration.ServerManager]::new();try{
  $web=$manager.GetWebConfiguration($tag);$filter=$web.GetSection('system.webServer/security/requestFiltering');$extensions=$filter.GetChildElement('fileExtensions').GetCollection();$deniedConf=@($extensions|Where-Object{$_.GetAttributeValue('fileExtension')-ceq'.conf'});Assert-Control ($deniedConf.Count-eq1-and!$deniedConf[0].GetAttributeValue('allowed')) 'effective_native_private_extension_filter_retained'
  $moduleSection=$web.GetSection('system.webServer/modules');$list=$moduleSection.GetCollection();$fileAuthorization=@($list|Where-Object{$_.GetAttributeValue('name')-ceq'FileAuthorization'});$uploadModule=@($list|Where-Object{$_.GetAttributeValue('name')-ceq'OpenWebPBX-UploadAdmission'})
  Assert-Control (!$moduleSection.GetAttributeValue('runAllManagedModulesForAllRequests')-and$fileAuthorization.Count-eq1-and$fileAuthorization[0].GetAttributeValue('preCondition')-ceq'managedHandler'-and$uploadModule.Count-eq1-and$uploadModule[0].GetAttributeValue('preCondition')-ceq'') 'effective_module_preconditions_preserved'
  $handlers=$web.GetSection('system.webServer/handlers','api/v2/upload.php').GetCollection();$stream=@($handlers|Where-Object{$_.GetAttributeValue('name')-ceq'OpenWeb-APIBackupStream'});$front=@($handlers|Where-Object{$_.GetAttributeValue('name')-ceq'OpenWeb-APIPHP'})
  Assert-Control ($stream.Count-eq1-and$stream[0].GetAttributeValue('path')-ceq'api/v2/upload.php'-and$stream[0].GetAttributeValue('scriptProcessor')-match'upload-admission\\php[.]ini'-and$front.Count-eq1-and$front[0].GetAttributeValue('path')-ceq'index.php') 'dedicated_api_stream_handler_retained'
  $fullHandlers=$web.GetSection('system.webServer/handlers','app/pbx_protection/upload.php').GetCollection();$fullStream=@($fullHandlers|Where-Object{$_.GetAttributeValue('name')-ceq'OpenWeb-BackupStream'})
  Assert-Control ($fullStream.Count-eq1-and$fullStream[0].GetAttributeValue('path')-ceq'app/pbx_protection/upload.php'-and$fullStream[0].GetAttributeValue('scriptProcessor')-match'upload-admission\\php[.]ini') 'dedicated_full_stream_handler_retained'
 }finally{$manager.Dispose()}
 Assert-Control ((Get-Acl -LiteralPath $WebRoot).Sddl-ceq$originalAcl-and(Get-FileHash (Join-Path $WebRoot 'web.config') -Algorithm SHA256).Hash-ceq$originalConfig) 'installed_config_and_acl_unchanged'
 Assert-Control ((Get-Acl -LiteralPath $copy).Sddl-ceq$readAclBefore) 'isolated_webroot_stays_readonly'
 $completed=$true
} finally {
 if($contact){@{cleanup_required=$true;contact_id=$contact}|ConvertTo-Json -Compress|Set-Content -LiteralPath (Join-Path $OutputRoot 'owned-contact-cleanup.private.json') -Encoding UTF8}
 if($created){$manager=[Microsoft.Web.Administration.ServerManager]::new();try{$site=$manager.Sites[$tag];if($site-and$site.Applications['/'].VirtualDirectories['/'].PhysicalPath-ceq$copy){$manager.Sites.Remove($site);$configuration=$manager.GetApplicationHostConfiguration();foreach($location in @($configuration.GetLocationPaths())){if($location-ceq$tag-or$location.StartsWith($tag+'/',[StringComparison]::Ordinal)){$configuration.RemoveLocationPath($location)}};$manager.CommitChanges()}else{throw 'Owned site identity changed; cleanup refused'}}finally{$manager.Dispose()}}
 $after=Configuration-Fingerprint;Assert-Control ($after-ceq$before) 'existing_sites_and_pools_preserved'
 if(Test-Path -LiteralPath $copy){Set-Acl -LiteralPath $copy -AclObject $privateAcl}
 @{passed=($completed-and@($checks|Where-Object{!$_.passed}).Count-eq0);checks=@($checks);actual_iis=$true;actual_php_api=$true;upload_only=[bool]$UploadOnly;loopback_only=$true;installed_config_unchanged=$true;utc=[DateTime]::UtcNow.ToString('o')}|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $OutputRoot 'result.safe.json') -Encoding UTF8
}
