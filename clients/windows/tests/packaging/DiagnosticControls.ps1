# SPDX-License-Identifier: AGPL-3.0-or-later
#Requires -Version 7.4
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Diagnostics.ps1')
$checks=0;function Check([bool]$Value){if(!$Value){throw ('Package diagnostic control '+($script:checks+1)+' failed.')};$script:checks++}
$prefix='OPENWEBPBX_PACKAGE_CERTIFICATE_OBSERVATION '
$original=[Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('private-message-not-exported'),'Original',[Management.Automation.ErrorCategory]::InvalidOperation,$null)
$row=GetPackageCertificateFailure $original 'Create' 'native_module';Check ($row.reason-ceq 'external_exception');Check ($row.error_type-ceq 'InvalidOperationException');Check ($original.Exception.Message-ceq 'private-message-not-exported')
$serialized=$row|ConvertTo-Json -Compress;Check (!$serialized.Contains('private-message'));$valid=ReadPackageCertificateFailure ($prefix+$serialized) 'Create';Check ($valid.hresult-eq $original.Exception.HResult)
foreach($mutation in @(@{schema='1'},@{schema=2},@{producer='foreign'},@{mode='Remove'},@{stage='private/path'},@{source='C:\private'},@{line='12'},@{line=-1},@{error_type='C:\private'},@{hresult='1'},@{hresult=2147483648},@{inner_type='IOException';inner_hresult=$null},@{inner_type='IOException';inner_hresult='1'},@{reason='private-message'},@{unexpected='secret'})){
 $changed=$serialized|ConvertFrom-Json -AsHashtable;foreach($key in $mutation.Keys){$changed[$key]=$mutation[$key]};$refused=$false;try{ReadPackageCertificateFailure ($prefix+($changed|ConvertTo-Json -Compress)) 'Create'|Out-Null}catch{$refused=$true};Check $refused
}
foreach($inputText in @('',($prefix+$serialized+"`n"+$prefix+$serialized),($prefix+('x'*4097)),($prefix+'not-json'),($prefix+$serialized.Replace('"schema":1,','"schema":1,"schema":1,')))){$refused=$false;try{ReadPackageCertificateFailure $inputText 'Create'|Out-Null}catch{$refused=$true};Check $refused}
foreach($exit in @(-2147483648,-1,1,17,2147483647)){$observed=GetPackageChildFailure 'publish_app' $exit;Check ($observed.exit_code-eq $exit -and $observed.operation-ceq 'publish_app')}
foreach($inputValue in @(@{op='foreign';code=17},@{op='publish_app';code=0})){$refused=$false;try{GetPackageChildFailure $inputValue.op $inputValue.code|Out-Null}catch{$refused=$true};Check $refused}
$client=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent;$tool=Join-Path $client 'tools/Test-ClientPackage.ps1';$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($tool,[ref]$tokens,[ref]$errors);Check (!$errors)
$run=@($ast.FindAll({param($n)$n-is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name-ceq 'Run'},$true));Check ($run.Count-eq 1);. ([scriptblock]::Create($run[0].Extent.Text))
$root=Join-Path ([IO.Path]::GetTempPath()) ('phone-package-diagnostic-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root)
$dotnet=(Get-Process -Id $PID).Path # Explicit cwd adapter: execute real PowerShell child in the client directory.
$oldActions=$env:GITHUB_ACTIONS
try{
 $env:GITHUB_ACTIONS='false'
 foreach($mode in @('Create','Remove')){
  $result=[ordered]@{};$caught=$false
  try{Run $dotnet @('-NoLogo','-NoProfile','-File',(Join-Path $PSScriptRoot 'Certificate.ps1'),'-Mode',$mode,'-Nonce',('a'*32),'-Root',$root) 15 ('certificate_'+$mode.ToLowerInvariant())|Out-Null}catch{$caught=$_.Exception.Message-ceq 'An actual package child refused.'}
  Check $caught;Check ($result.child_failures.Count-eq 1 -and $result.child_failures[0].exit_code-eq 1);$detail=$result['certificate_'+$mode.ToLowerInvariant()+'_failure'];Check ($detail.mode-ceq $mode -and $detail.stage-ceq 'entry' -and $detail.reason-ceq 'host_guard' -and $detail.source-ceq 'Certificate.ps1' -and $detail.line-gt 0);Check (@(Get-ChildItem $root -Force).Count-eq 0)
 }
 $child=Join-Path $root 'actual-child.ps1';[IO.File]::WriteAllText($child,"exit 17`n");$result=[ordered]@{};$caught=$false
 try{Run $dotnet @('-NoProfile','-File',$child) 15 'publish_app'|Out-Null}catch{$caught=$_.Exception.Message-ceq 'An actual package child refused.'};Check $caught;Check ($result.child_failures[0].exit_code-eq 17 -and $result.child_failures[0].operation-ceq 'publish_app')
 [IO.File]::WriteAllText($child,"[Console]::Error.WriteLine('OPENWEBPBX_PACKAGE_CERTIFICATE_OBSERVATION invalid');exit 17`n");$result=[ordered]@{};$caught=$false
 try{Run $dotnet @('-NoProfile','-File',$child) 15 'certificate_create'|Out-Null}catch{$caught=$_.Exception.Message-ceq 'An actual package child refused.'};Check $caught;Check ($result.child_failures[0].exit_code-eq 17 -and $result.certificate_create_observation_refused-eq $true)
 [IO.File]::WriteAllText($child,"[Console]::Write('ordinary-result');exit 0`n");$result=[ordered]@{};$value=Run $dotnet @('-NoProfile','-File',$child) 15 'publish_app';Check ($value-ceq 'ordinary-result' -and !$result.Contains('child_failures'))
}finally{$env:GITHUB_ACTIONS=$oldActions;[IO.Directory]::Delete($root,$true)}
"PASS $checks actual producer/strict-consumer/off-host-child/exit controls; no Windows certificate or package mutation"

$removal=GetPackageCertificateRemoval 0 0 $false 0;$removalJson=$removal|ConvertTo-Json -Compress;$observed=ReadPackageCertificateRemoval $removalJson;Check (!$observed.private_key_exists -and $observed.private_certificates-eq 0 -and $observed.public_trust_certificates-eq 0)
foreach($mutation in @(@{schema='1'},@{schema=2},@{producer='foreign'},@{private_certificates=1},@{private_certificates='0'},@{public_trust_certificates=1},@{public_trust_certificates='0'},@{private_key_exists=$true},@{private_key_exists='false'},@{private_key_exists=0},@{path='private'},@{private_location='LocalMachine'},@{private_store='Root'},@{trust_location='CurrentUser'},@{trust_store='Root'},@{cached_public_certificates=1},@{cached_public_certificates='0'},@{cache_location='LocalMachine'},@{cache_store='Root'})){
 $changed=$removalJson|ConvertFrom-Json -AsHashtable;foreach($key in $mutation.Keys){$changed[$key]=$mutation[$key]};$refused=$false;try{ReadPackageCertificateRemoval ($changed|ConvertTo-Json -Compress)|Out-Null}catch{$refused=$true};Check $refused
}
foreach($text in @('',($removalJson.Replace('"schema":1,','"schema":1,"schema":1,')),('x'*1025))){$refused=$false;try{ReadPackageCertificateRemoval $text|Out-Null}catch{$refused=$true};Check $refused}
foreach($values in @(@(1,0,$false),@(0,1,$false),@(0,0,$true))){$refused=$false;try{GetPackageCertificateRemoval $values[0] $values[1] $values[2] 0|Out-Null}catch{$refused=$true};Check $refused}
$snapshot=[ordered]@{certificates=@([ordered]@{location='CurrentUser';store='My';thumbprint='private-thumbprint';bytes=('a'*64);private=$true;archived=$false;friendly='private-name'});packages=@([ordered]@{full_name='private-package'});registry=@([ordered]@{path='Software\Microsoft\Windows\CurrentVersion\Run';sddl='private-sddl';values=@('private-value')})}|ConvertTo-Json -Depth 14 -Compress
$comparison=GetPackageSnapshotComparison $snapshot $snapshot;Check ($comparison.certificates.matches -and $comparison.packages.matches -and $comparison.registry.matches -and $comparison.certificate_stores.CurrentUser_My.matches);Check (!(($comparison|ConvertTo-Json -Depth 5 -Compress).Contains('private-')))
foreach($category in @('certificates','packages','registry')){
 $changed=$snapshot|ConvertFrom-Json -AsHashtable;$changed[$category]=@();$comparison=GetPackageSnapshotComparison $snapshot ($changed|ConvertTo-Json -Depth 14 -Compress);Check (!$comparison[$category].matches -and $comparison[$category].before_count-eq 1 -and $comparison[$category].after_count-eq 0)
 foreach($other in @('certificates','packages','registry')|Where-Object {$_-cne $category}){Check $comparison[$other].matches}
}
$changed=$snapshot.Replace('private-name','changed-name');$comparison=GetPackageSnapshotComparison $snapshot $changed;Check (!$comparison.certificates.matches -and !$comparison.certificate_stores.CurrentUser_My.matches -and $comparison.certificate_stores.CurrentUser_Root.matches)
$text=[IO.File]::ReadAllText($tool);Check ($text.Contains('$result.preexisting_vectors_preserved=$afterSnapshot-ceq $before;if(!$result.preexisting_vectors_preserved){$cleanup=$false}'));Check ($text.Contains('$result.certificate_removal=ReadPackageCertificateRemoval $output'))
"PASS $checks total actual diagnostic/removal-consumer/vector-comparison controls; native certificate deletion and original preservation still require Windows execution"

$certificate=Join-Path $PSScriptRoot 'Certificate.ps1';$certificateAst=[Management.Automation.Language.Parser]::ParseFile($certificate,[ref]$tokens,[ref]$errors);Check (!$errors)
$intentGuard=@($certificateAst.FindAll({param($node)$node-is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith('if($proof.schema-ne 2')},$true));Check ($intentGuard.Count-eq 1)
& {
 param($Guard)
 $Nonce='a'*32;$subject='CN=FreePhone Development '+$Nonce;$container='OpenWebPBX-FreePhone-Development-'+$Nonce;$mine=@();$trusted=@();$cached=@()
 $valid=[pscustomobject]@{schema=2;nonce=$Nonce;subject=$subject;container=$container;private_location='CurrentUser';private_store='My';trust_location='LocalMachine';trust_store='TrustedPeople';cache_location='CurrentUser';cache_store='CA';cache_absent_before=$true};$proof=$valid;. $Guard;Check $true
 foreach($field in @('schema','nonce','subject','container','private_location','private_store','trust_location','trust_store','cache_location','cache_store','cache_absent_before')){$proof=$valid|ConvertTo-Json|ConvertFrom-Json;$proof.$field=if($field-ceq 'schema'){1}else{'foreign'};$refused=$false;try{. $Guard}catch{$refused=$true};Check $refused}
 foreach($changed in @($false,'false')){$proof=$valid|ConvertTo-Json|ConvertFrom-Json;$proof.cache_absent_before=$changed;$refused=$false;try{. $Guard}catch{$refused=$true};Check $refused}
 $proof=$valid;$cached=@(1,2);$refused=$false;try{. $Guard}catch{$refused=$true};Check $refused
} ([scriptblock]::Create($intentGuard[0].Extent.Text))
$bindingGuard=@($certificateAst.FindAll({param($node)$node-is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith('if($trusted.Count -and (!$mine.Count')},$true));Check ($bindingGuard.Count-eq 1)
& {
 param($Guard)
 function CertificateSha($Value){$Value.fake_sha}
 $receipt=[pscustomobject]@{public_sha256=('a'*64)};$mine=@([pscustomobject]@{Thumbprint=('b'*40)});$valid=[pscustomobject]@{Thumbprint=('b'*40);HasPrivateKey=$false;fake_sha=('a'*64)};$trusted=@($valid);. $Guard;Check $true
 foreach($field in @('Thumbprint','HasPrivateKey','fake_sha')){$candidate=$valid|ConvertTo-Json|ConvertFrom-Json;$candidate.$field=if($field-ceq 'HasPrivateKey'){$true}else{'foreign'};$trusted=@($candidate);$refused=$false;try{. $Guard}catch{$refused=$true};Check $refused}
 $mine=@();$trusted=@($valid);$refused=$false;try{. $Guard}catch{$refused=$true};Check $refused
} ([scriptblock]::Create($bindingGuard[0].Extent.Text))
$adminGuard=@($certificateAst.FindAll({param($node)$node-is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith('if(!$principal.IsInRole(')},$true));Check ($adminGuard.Count-eq 1)
& {param($Guard);foreach($allowed in @($true,$false)){$principal=[pscustomobject]@{allowed=$allowed};$principal|Add-Member ScriptMethod IsInRole {param($role)$this.allowed};$refused=$false;try{. $Guard}catch{$refused=$true};Check ($refused-eq !$allowed)}} ([scriptblock]::Create($adminGuard[0].Extent.Text))
$certificateText=[IO.File]::ReadAllText($certificate);Check ($certificateText.Contains("::new('My','CurrentUser')") -and $certificateText.Contains("::new('TrustedPeople','LocalMachine')") -and !$certificateText.Contains("::new('Root',"));Check ($certificateText.Contains("'certificate.json'),'CreateNew','Write','None'"));Check ($certificateText.IndexOf("'write_receipt'")-lt $certificateText.IndexOf("'add_trust'"))
$comparison=GetPackageSnapshotComparison $snapshot $snapshot ('a'*64);Check ($comparison.certificate_stores.CurrentUser_My.owned_byte_matches-eq 1 -and $comparison.certificate_stores.LocalMachine_TrustedPeople.owned_byte_matches-eq 0)
$changed=$snapshot.Replace('private-value','changed-value');$comparison=GetPackageSnapshotComparison $snapshot $changed;Check (!$comparison.registry_roots.startup_run.matches -and $comparison.registry_roots.startup_run.acl_matches -and $comparison.registry_roots.protocol.matches)
$changed=$snapshot.Replace('private-sddl','changed-sddl');$comparison=GetPackageSnapshotComparison $snapshot $changed;Check (!$comparison.registry_roots.startup_run.matches -and !$comparison.registry_roots.startup_run.acl_matches)
$observers=@($ast.FindAll({param($node)$node-is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name-ceq 'Observe'},$true));Check ($observers.Count-eq 1)
& {
 param($Definition,$Initial)
 . $Definition;$before=$Initial;$ownedCertificateSha=$null;$result=[ordered]@{};$script:vectorValue=$Initial;$script:vectorThrow=$false;$failure=[Management.Automation.ErrorRecord]::new([InvalidOperationException]::new('original-primary'),'Original',[Management.Automation.ErrorCategory]::InvalidOperation,$null);$saved=$failure
 function Snapshot{if($script:vectorThrow){throw 'private-observer-error'};$script:vectorValue}
 $seen=Observe 'baseline_probe';Check ($seen-ceq $before -and $result.vector_observations.Count-eq 1 -and $result.vector_observations[0].comparison.certificates.matches)
 $script:vectorValue=$Initial.Replace('private-sddl','changed-sddl');[void](Observe 'certificate_created');Check (!$result.vector_observations[1].comparison.registry.matches -and $before-ceq $Initial)
 $script:vectorThrow=$true;$observed=Observe 'after_failure';Check ($null-eq $observed -and $result.vector_observation_failed -and $result.vector_observation_failures[0].phase-ceq 'after_failure' -and [object]::ReferenceEquals($failure,$saved));Check (!(($result|ConvertTo-Json -Depth 10 -Compress).Contains('private-observer')))
 [void](Observe 'unknown-private-phase');Check ($result.vector_observation_failures[1].phase-ceq 'other')
} ([scriptblock]::Create($observers[0].Extent.Text)) $snapshot
"PASS $checks total scoped-trust/actual-guard/closed-observer controls; role/certificate/store snapshots are explicit adapters, not native LM trust acceptance"

# Execute the actual cached-certificate binding and re-read/removal branch with an
# explicit store adapter. Hashing uses the actual receipt producer over byte arrays.
$preflight=@($certificateAst.FindAll({param($node)$node-is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith('if($mine.Count -or $trusted.Count -or $cached.Count -or')},$true)|Where-Object {$_.Extent.Text.Contains('The development certificate or private container already exists.')});Check ($preflight.Count-eq 1)
& {param($Guard);$mine=@();$trusted=@();$cached=@([pscustomobject]@{Subject='preexisting'});$refused=$false;try{. $Guard}catch{$refused=$_.Exception.Message-ceq 'The development certificate or private container already exists.'};Check ($refused -and $cached.Count-eq 1 -and $cached[0].Subject-ceq 'preexisting')} ([scriptblock]::Create($preflight[0].Extent.Text))
$shaDefinition=@($certificateAst.FindAll({param($node)$node-is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name-ceq 'CertificateSha'},$true));Check ($shaDefinition.Count-eq 1)
$cacheBinding=@($certificateAst.FindAll({param($node)$node-is [Management.Automation.Language.ForEachStatementAst] -and $node.Variable.VariablePath.UserPath-ceq 'cachedCertificate'},$true));Check ($cacheBinding.Count-eq 1)
$cacheRemoval=@($certificateAst.FindAll({param($node)$node-is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith('if($cached.Count){')},$true));Check ($cacheRemoval.Count-eq 1)
& {
 param($Sha,$Binding,$Removal)
 . $Sha;$subject='CN=FreePhone Development '+('a'*32);$valid=[pscustomobject]@{Subject=$subject;Thumbprint=('b'*40);HasPrivateKey=$false;RawData=[byte[]](1,2,3,4)};$receipt=[pscustomobject]@{subject=$subject;thumbprint=$valid.Thumbprint;public_sha256=(CertificateSha $valid)};$cached=@($valid);. $Binding;Check $true
 $alternatives=@();foreach($field in @('Subject','Thumbprint','HasPrivateKey','RawData')){$changed=[pscustomobject]@{Subject=$valid.Subject;Thumbprint=$valid.Thumbprint;HasPrivateKey=$false;RawData=$valid.RawData};$changed.$field=switch($field){'HasPrivateKey'{$true};'RawData'{[byte[]](1,2,3,5)};default{'foreign'}};$alternatives+=,$changed}
 foreach($changed in $alternatives){$cached=@($changed);$refused=$false;try{. $Binding}catch{$refused=$true};Check $refused}
 foreach($entries in @(@($valid),@(),@($valid,$valid)) + @($alternatives|ForEach-Object {,@($_)})){
  $cached=@($valid);$cache=[pscustomobject]@{Certificates=@($entries);removed=[Collections.Generic.List[object]]::new();opens=[Collections.Generic.List[string]]::new()};$cache|Add-Member ScriptMethod Close {};$cache|Add-Member ScriptMethod Open {param($mode)$this.opens.Add($mode)};$cache|Add-Member ScriptMethod Remove {param($cert)$this.removed.Add($cert)}
  $refused=$false;try{. $Removal}catch{$refused=$true};$matches=$entries.Count-eq 1 -and [object]::ReferenceEquals($entries[0],$valid);Check ($refused-ne $matches);Check ($cache.removed.Count-eq [int]$matches);Check ($cache.opens.Count-eq 1 -and $cache.opens[0]-ceq 'ReadWrite')
 }
} ([scriptblock]::Create($shaDefinition[0].Extent.Text)) ([scriptblock]::Create($cacheBinding[0].Extent.Text)) ([scriptblock]::Create($cacheRemoval[0].Extent.Text))

$authority=[ordered]@{schema=1;producer='PackageFixtureAuthority';state='authorized';stage='package_identity';error_type=$null;hresult=$null};$authorityText=$authority|ConvertTo-Json -Compress;$accepted=ReadPackageAuthorityObservation $authorityText;Check ($accepted.state-ceq 'authorized')
foreach($mutation in @(@{schema='1'},@{producer='foreign'},@{path='private'},@{stage='context'},@{state='unknown'},@{error_type='Exception'},@{hresult=0},@{state='refused'},@{stage='private-stage'})){$changed=$authorityText|ConvertFrom-Json -AsHashtable;foreach($field in $mutation.Keys){$changed[$field]=$mutation[$field]};$refused=$false;try{ReadPackageAuthorityObservation ($changed|ConvertTo-Json -Compress)|Out-Null}catch{$refused=$true};Check $refused}
$authority.state='refused';$authority.stage='context';$authority.error_type='InvalidOperationException';$authority.hresult=-2146233079;$authorityText=$authority|ConvertTo-Json -Compress;Check ((ReadPackageAuthorityObservation $authorityText).state-ceq 'refused')
foreach($text in @($authorityText.Replace('"schema":1,','"schema":1,"schema":1,'),($authorityText.Replace('-2146233079','"-2146233079"')),('x'*2049))){$refused=$false;try{ReadPackageAuthorityObservation $text|Out-Null}catch{$refused=$true};Check $refused}
"PASS $checks total actual diagnostic/cache-guard/authority-observer controls; certificate stores remain explicit adapters"
