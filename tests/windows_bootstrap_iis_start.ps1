# Source-only ORIGINAL IIS closure reproduction; never invokes BootstrapProof body.
[CmdletBinding()]
param([string]$SourceRoot=(Split-Path -Parent $PSScriptRoot),[Parameter(Mandatory)][string]$OriginalSource,[switch]$NativeIIS,[string]$OutputRoot,[string]$Receipt)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$SourceFile=$OriginalSource;$currentFile=Join-Path $SourceRoot 'packaging\windows\Install-BootstrapProof.ps1'
$old=[IO.File]::ReadAllText($OriginalSource);$current=[IO.File]::ReadAllText($currentFile)
if((Get-FileHash $OriginalSource -Algorithm SHA256).Hash.ToLowerInvariant()-cne'bb968a68addf9a040bd6c5e58182247858c86fe3d69a618cd32bfbfe48f99f0b'){throw 'Exact retained original setup proof source is required'}
$addition=@'
 # Newly committed objects need runtime handles from a fresh configuration.
 $manager.Dispose();$manager=[Microsoft.Web.Administration.ServerManager]::new()
 $pool=$manager.ApplicationPools[$name];$site=$manager.Sites[$name]
 if(!$pool -or !$site){throw 'The committed setup proof IIS objects are unavailable.'}
'@
$addition=$addition+"`n"
if(!$current.Contains($addition)-or$current.Replace($addition,'')-cne$old){throw 'The lifecycle fix must preserve every original ownership, path, binding, ACL, firewall and authentication byte'}
foreach($file in $OriginalSource,$currentFile){$tokens=$null;$errors=$null;$null=[Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$errors);if($errors.Count){throw 'Actual original/current source must parse'}}
function Test-ReceiptParameterWrite($Node) {
 if($Node-isnot[Management.Automation.Language.AssignmentStatementAst]){return $false}
 if($Node.Left-is[Management.Automation.Language.VariableExpressionAst]){return $Node.Left.VariablePath.UserPath-ieq'Receipt'}
 return @($Node.Left.FindAll({param($left)$left-is[Management.Automation.Language.VariableExpressionAst]-and$left.VariablePath.UserPath-ieq'Receipt'},$true)).Count-gt0
}
$selfTokens=$null;$selfErrors=$null;$self=[Management.Automation.Language.Parser]::ParseFile($PSCommandPath,[ref]$selfTokens,[ref]$selfErrors)
$receiptWrites=@($self.FindAll({param($node)Test-ReceiptParameterWrite $node},$true))
$negativeTokens=$null;$negativeErrors=$null;$negative=[Management.Automation.Language.Parser]::ParseInput('param([string]$Receipt);$receipt=@{}',[ref]$negativeTokens,[ref]$negativeErrors)
$negativeWrites=@($negative.FindAll({param($node)Test-ReceiptParameterWrite $node},$true))
if($selfErrors.Count-or$receiptWrites.Count-or$negativeErrors.Count-or$negativeWrites.Count-ne1){throw 'The CLI Receipt path is immutable; case data must use a separate variable, and the collision negative control must refuse'}
$portable=@{passed=$true;portable_controls=5;scope='actual source parses and all original setup-authority bytes remain exact outside the tested post-commit runtime-handle fix';original_source_sha256=(Get-FileHash $OriginalSource -Algorithm SHA256).Hash.ToLowerInvariant();current_source_sha256=(Get-FileHash $currentFile -Algorithm SHA256).Hash.ToLowerInvariant();native_iis_execution=[bool]$NativeIIS}
if(!$NativeIIS){if($Receipt){[IO.File]::WriteAllText($Receipt,($portable|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))};$portable|ConvertTo-Json -Compress;return}
if([Threading.Thread]::CurrentThread.GetApartmentState()-ne'MTA'){throw 'Use native Windows PowerShell MTA'}
if(!$OutputRoot-or(Split-Path -Leaf $OutputRoot)-cnotmatch'^bootstrap-iis-repro-[a-f0-9]{12}$'-or(Test-Path $OutputRoot)){throw 'NEW owned fixture root required'}
$parent=[IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($OutputRoot));$qa=[IO.Path]::GetFullPath((Join-Path $env:ProgramData 'WebHotel\OpenWebPBX127QA'));$tmp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
if(!$parent.StartsWith($qa+'\',[StringComparison]::OrdinalIgnoreCase)-and!$parent.Equals($tmp,[StringComparison]::OrdinalIgnoreCase)){throw 'Use only the owned QA tree or a new private temporary fixture root'}
$source=[IO.File]::ReadAllText($SourceFile);$sourceHash=(Get-FileHash $SourceFile -Algorithm SHA256).Hash.ToLowerInvariant()
if($sourceHash-cne'bb968a68addf9a040bd6c5e58182247858c86fe3d69a618cd32bfbfe48f99f0b'){throw 'Frozen original source hash mismatch'}
$start=$source.IndexOf('Add-Type -Path');$end=$source.IndexOf('$ruleName=', $start)
if($start-lt0-or$end-le$start){throw 'Exact original IIS block required'}
$firstLine=($source.Substring(0,$start).Split("`n")).Count
$original=$source.Substring($start,$end-$start)
$declaration='$name=''OpenWebPBX-SetupProof'';$binding=''*:80:''+$PublicAddress'
if(!$original.Contains($declaration)-or!$original.Contains('$manager.CommitChanges()')-or!$original.Contains('$pool.Start()')-or!$original.Contains('$site.Start()')){throw 'Original creation/commit/cached-start closure differs'}
$adapted=$original.Replace($declaration,'$name=$FixtureName;$binding=$FixtureBinding')
$commit='$site.ServerAutoStart=$true;$pool.AutoStart=$true;$manager.CommitChanges()'
if(!$adapted.Contains($commit)){throw 'Exact original commit boundary required'}
$currentStart=$current.IndexOf('Add-Type -Path');$currentEnd=$current.IndexOf('$ruleName=', $currentStart);if($currentStart-lt0-or$currentEnd-le$currentStart){throw 'Current native closure required'}
$currentFirstLine=($current.Substring(0,$currentStart).Split("`n")).Count
$fresh=$current.Substring($currentStart,$currentEnd-$currentStart).Replace($declaration,'$name=$FixtureName;$binding=$FixtureBinding')
[IO.Directory]::CreateDirectory($OutputRoot)|Out-Null
[IO.File]::WriteAllText((Join-Path $OutputRoot 'fixture-owner.json'),(@{scope='source-only-owned-IIS-creation';source_sha256=$sourceHash}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
Add-Type -Path (Join-Path $env:windir 'System32\inetsrv\Microsoft.Web.Administration.dll')
$appHost=Join-Path $env:windir 'System32\inetsrv\config\applicationHost.config'
$beforeBytes=[IO.File]::ReadAllBytes($appHost);[IO.File]::WriteAllBytes((Join-Path $OutputRoot 'applicationHost-before.private.xml'),$beforeBytes)
$beforeHash=(Get-FileHash $appHost -Algorithm SHA256).Hash
function OriginalServices { $values=@();foreach($name in 'OpenWebPBX','OpenWebPBXUpdater','OpenWebPBX-Database','FreeSWITCH'){$service=Get-CimInstance Win32_Service -Filter "Name='$name'" -OperationTimeoutSec 10;$values+=@{name=$name;exists=[bool]$service;state=$service.State;start_mode=$service.StartMode;pid=$service.ProcessId}};return $values }
function OriginalIISState { $m=[Microsoft.Web.Administration.ServerManager]::new();try{return @{sites=@($m.Sites|Sort-Object Name|ForEach-Object{[ordered]@{name=$_.Name;id=$_.Id;state=[string]$_.State;auto_start=$_.ServerAutoStart;bindings=@($_.Bindings|ForEach-Object{[ordered]@{protocol=$_.Protocol;information=$_.BindingInformation}})}});pools=@($m.ApplicationPools|Sort-Object Name|ForEach-Object{[ordered]@{name=$_.Name;state=[string]$_.State;auto_start=$_.AutoStart;runtime=$_.ManagedRuntimeVersion}})}}finally{$m.Dispose()} }
$beforeServices=OriginalServices;$beforeIIS=OriginalIISState
$result=@{portable=$portable;current_source_sha256=$portable.current_source_sha256;started_at=[DateTime]::UtcNow.ToString('o');source_sha256=$sourceHash;original_source_start_line=$firstLine;source_block_translation='ONLY unique owned site/pool name and loopback binding; original control flow retained';product_body_or_default_paths_invoked=$false;cases=@()}
$tag='OWPBX127QA-Bootstrap-'+[Guid]::NewGuid().ToString('N').Substring(0,12)
$created=@()
try{
 foreach($variant in 'original','current_product'){
  $case=Join-Path $OutputRoot $variant;$physical=Join-Path $case 'web';$proof=Join-Path $case 'proof';[IO.Directory]::CreateDirectory($physical)|Out-Null;[IO.Directory]::CreateDirectory($proof)|Out-Null
  # Readable static leaves are NEW fixture paths only; no original ACL changes.
  foreach($path in $physical,$proof){$acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetOwner([Security.Principal.SecurityIdentifier]'S-1-5-32-544');$acl.SetAccessRuleProtection($true,$false);foreach($sid in 'S-1-5-18','S-1-5-32-544'){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]$sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))};foreach($sid in 'S-1-5-32-568','S-1-5-17','S-1-5-19'){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]$sid,'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow'))};Set-Acl -LiteralPath $path -AclObject $acl}
  [IO.File]::WriteAllText((Join-Path $physical 'web.config'),'<configuration><system.webServer><handlers><clear/><add name="OwnedFixtureStatic" path="*" verb="GET,HEAD" modules="StaticFileModule" resourceType="File" requireAccess="Read"/></handlers><staticContent><remove fileExtension="."/><mimeMap fileExtension="." mimeType="text/plain"/></staticContent></system.webServer></configuration>',[Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText((Join-Path $proof 'probe'),'owned-source-only-static-proof',[Text.UTF8Encoding]::new($false))
  $FixtureName=$tag+'-'+$variant;$port=if($variant-eq'original'){18731}else{18732};$FixtureBinding='127.0.0.1:'+$port+':';$PublicAddress='127.0.0.1'
  $manager=[Microsoft.Web.Administration.ServerManager]::new();try{if($manager.Sites[$FixtureName]-or$manager.ApplicationPools[$FixtureName]){throw 'Owned fixture name collision'};foreach($site in $manager.Sites){foreach($binding in $site.Bindings){if($binding.EndPoint.Port-eq$port){throw 'Owned loopback port is already used'}}}}finally{$manager.Dispose()}
  $created+=@{name=$FixtureName;physical=$physical;binding=$FixtureBinding}
  $file=Join-Path $case ($variant+'.source-closure.private.ps1');$block=if($variant-eq'original'){$adapted}else{$fresh};[IO.File]::WriteAllText($file,("`n"*($(if($variant-eq'original'){$firstLine}else{$currentFirstLine})-1))+$block,[Text.UTF8Encoding]::new($false))
  $caseReceipt=@{variant=$variant;name=$FixtureName;binding=$FixtureBinding;started_at=[DateTime]::UtcNow.ToString('o');script_sha256=(Get-FileHash $file -Algorithm SHA256).Hash.ToLowerInvariant();passed=$false}
  try{& $file;$caseReceipt.passed=$true}catch{$errorRecord=$_;$caseReceipt.error=@{type=$_.Exception.GetType().FullName;base_type=$_.Exception.GetBaseException().GetType().FullName;message=$_.Exception.Message;base_message=$_.Exception.GetBaseException().Message;hresult=$_.Exception.GetBaseException().HResult;hresult_hex=('0x{0:X8}'-f$_.Exception.GetBaseException().HResult);script_stack=$_.ScriptStackTrace;script_name=$_.InvocationInfo.ScriptName;script_line=$_.InvocationInfo.ScriptLineNumber;position=$_.InvocationInfo.PositionMessage}}
  $manager=[Microsoft.Web.Administration.ServerManager]::new();try{$site=$manager.Sites[$FixtureName];$pool=$manager.ApplicationPools[$FixtureName];$caseReceipt.after=@{site_exists=[bool]$site;pool_exists=[bool]$pool;site_state=if($site){[string]$site.State}else{$null};pool_state=if($pool){[string]$pool.State}else{$null};site_id=if($site){$site.Id}else{$null};binding=if($site){$site.Bindings[0].BindingInformation}else{$null};physical=if($site){$site.Applications['/'].VirtualDirectories['/'].PhysicalPath}else{$null}}}finally{$manager.Dispose()}
  if($caseReceipt.passed){try{$response=Invoke-WebRequest -UseBasicParsing -Uri ('http://127.0.0.1:'+$port+'/.well-known/openwebpbx-instance/probe') -TimeoutSec 10 -MaximumRedirection 0;$caseReceipt.http=@{status=[int]$response.StatusCode;exact_body=$response.Content-ceq'owned-source-only-static-proof'}}catch{$caseReceipt.http=@{error_type=$_.Exception.GetType().Name}}}
  $caseReceipt.finished_at=[DateTime]::UtcNow.ToString('o');$result.cases+=$caseReceipt
 }
}finally{
 foreach($entry in $created){$manager=[Microsoft.Web.Administration.ServerManager]::new();try{$site=$manager.Sites[$entry.name];if($site){if($site.Applications['/'].VirtualDirectories['/'].PhysicalPath-cne$entry.physical-or$site.Bindings[0].BindingInformation-cne$entry.binding){throw 'Refuse cleanup of changed fixture site'};$manager.Sites.Remove($site)};$pool=$manager.ApplicationPools[$entry.name];if($pool){foreach($other in $manager.Sites){foreach($app in $other.Applications){if($app.ApplicationPoolName-ceq$entry.name){throw 'Refuse removal of pool used by another site'}}};$manager.ApplicationPools.Remove($pool)};$config=$manager.GetApplicationHostConfiguration();foreach($location in @($config.GetLocationPaths())){if($location-ceq$entry.name-or$location.StartsWith($entry.name+'/',[StringComparison]::Ordinal)){$config.RemoveLocationPath($location)}};$manager.CommitChanges()}finally{$manager.Dispose()}}
 $afterBytes=[IO.File]::ReadAllBytes($appHost);[IO.File]::WriteAllBytes((Join-Path $OutputRoot 'applicationHost-after.private.xml'),$afterBytes);$afterServices=OriginalServices;$afterIIS=OriginalIISState
 $result.cleanup=@{only_owned_fixture_names_removed=$true;application_host_sha_before=$beforeHash;application_host_sha_after=(Get-FileHash $appHost -Algorithm SHA256).Hash;application_host_bytes_exact=[Convert]::ToBase64String($beforeBytes)-ceq[Convert]::ToBase64String($afterBytes);original_iis_runtime_exact=($beforeIIS|ConvertTo-Json -Depth 7 -Compress)-ceq($afterIIS|ConvertTo-Json -Depth 7 -Compress);original_iis_before=$beforeIIS;original_iis_after=$afterIIS;original_services_exact=($beforeServices|ConvertTo-Json -Depth 4 -Compress)-ceq($afterServices|ConvertTo-Json -Depth 4 -Compress);original_services_before=$beforeServices;original_services_after=$afterServices}
 $result.passed=($result.cases.Count-eq2-and$result.cases[1].passed-and$result.cases[1].http.status-eq200-and$result.cases[1].http.exact_body-and$result.cleanup.application_host_bytes_exact-and$result.cleanup.original_iis_runtime_exact-and$result.cleanup.original_services_exact);$result.original_failure_reproduced=($result.cases.Count-ge1-and!$result.cases[0].passed-and$result.cases[0].error.hresult_hex-ceq'0x800710D8');if($Receipt){[IO.File]::WriteAllText($Receipt,($result|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))};$result.finished_at=[DateTime]::UtcNow.ToString('o');[IO.File]::WriteAllText((Join-Path $OutputRoot 'result.private.json'),($result|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
}
$result|ConvertTo-Json -Depth 10 -Compress
if(!$result.passed){exit 1}
