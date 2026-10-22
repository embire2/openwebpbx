# Native NTFS/OpenSSL controls in an isolated administrator-owned temporary tree.
# The service identity adapter is explicit; no real service is started or stopped.
param([Parameter(Mandatory)][string]$SourceRoot,[string]$PhpRoot='C:\OpenWebPBX',[string]$ReportPath,[string]$LegacyCommon)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
if($env:OS -cne 'Windows_NT'){throw 'Native Windows is required.'}
$package=Join-Path $SourceRoot 'packaging\windows'
. (Join-Path $package 'File-Security.ps1')
. (Join-Path $package 'Write-PrivateState.ps1')
. (Join-Path $package 'Dtls.Common.ps1')
$work=Join-Path ([IO.Path]::GetTempPath()) ('openweb-dtls-native-'+[Guid]::NewGuid().ToString('N'))
New-OpenWebDtlsPrivate $work
$checks=0
function Check([bool]$Value){if(!$Value){throw ('The native DTLS preservation control failed at check '+$script:checks+'.')};$script:checks++}
function Refuse([scriptblock]$Action){$failed=$false;try{& $Action|Out-Null}catch{$failed=$true};Check $failed}
$script:service=[ordered]@{account='LocalSystem';sid='S-1-5-18';path='fictional-stopped-engine';start_mode='Disabled'}
$realService=${function:Get-OpenWebDtlsService}
$script:cimFixture=@{State='Stopped';StartMode='Disabled';StartName='LocalSystem';PathName='"C:\Program Files\FreeSWITCH\FreeSwitchConsole.exe"  -service '}
function Get-CimInstance {param([string]$ClassName,[string]$Filter);return [pscustomobject]$script:cimFixture}
Check ((& $realService).sid -ceq 'S-1-5-18')
$script:cimFixture.State='Running';Refuse {& $realService};$script:cimFixture.State='Stopped'
$script:cimFixture.PathName='"C:\foreign.exe" -service';Refuse {& $realService};$script:cimFixture.PathName='"C:\Program Files\FreeSWITCH\FreeSwitchConsole.exe"  -service '
$script:cimFixture.StartMode='Unknown';Refuse {& $realService};$script:cimFixture.StartMode='Disabled'
Remove-Item Function:\Get-CimInstance
$tokens=$null;$errors=$null;$installAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $package 'Install-Dtls.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The actual DTLS entry guard does not parse.'}
$guards=@($installAst.EndBlock.Statements|Where-Object {$_.Extent.Text.StartsWith('if(!$MaintenanceLock') -or $_.Extent.Text.StartsWith('$exclusive=') -or $_.Extent.Text.StartsWith('foreach($access') -or $_.Extent.Text.StartsWith('if(!$exclusive)')})
if($guards.Count -ne 4){throw 'The exact native DTLS maintenance guard is missing.'}
$guard=[scriptblock]::Create(($guards|ForEach-Object {$_.Extent.Text}) -join "`n")
$state=Join-Path $work 'lock-case';[void][IO.Directory]::CreateDirectory($state);$lockPath=Join-Path $state 'upgrade.lock'
foreach($share in 'None','Read','Write','ReadWrite'){
 $MaintenanceLock=[IO.File]::Open($lockPath,'OpenOrCreate','ReadWrite',$share)
 try{if($share -ceq 'None'){& $guard;Check $true}else{Refuse {& $guard}}}finally{$MaintenanceLock.Dispose()}
}
function Get-OpenWebDtlsService {return @{account=$script:service.account;sid=$script:service.sid;path=$script:service.path;start_mode=$script:service.start_mode}}
$sourceHash=Get-OpenWebDtlsHash (Join-Path $package 'Dtls.Common.ps1')
$certificate=Join-Path $work 'cert\dtls-srtp.pem';$state=Join-Path $work 'state';[void][IO.Directory]::CreateDirectory((Split-Path $certificate));[void][IO.Directory]::CreateDirectory($state)
$certDirectoryAcl=(Get-Acl -LiteralPath (Split-Path $certificate)).Sddl
$unrelated=Join-Path (Split-Path $certificate) 'custom-other.pem';[IO.File]::WriteAllText($unrelated,'unrelated private identity');$unrelatedHash=Get-OpenWebDtlsHash $unrelated
$fixture=Join-Path $work 'crypto'
try{
 $crypto=& (Join-Path $PhpRoot 'php\php.exe') (Join-Path $SourceRoot 'tests\windows_dtls_certificate.php') $fixture
 if($LASTEXITCODE -ne 0){throw 'Native OpenSSL fixture setup failed.'};$crypto=$crypto|ConvertFrom-Json;Check ($crypto.state -ceq 'passed' -and $crypto.checks -ge 12 -and $crypto.actual_openssl -is [bool] -and $crypto.actual_openssl)
 function Install {Install-OpenWebDtls -PackageRoot $package -Root $PhpRoot -State $state -Certificate $certificate|Out-Null}
 function LastTransaction {return @(Get-ChildItem (Join-Path $state 'dtls-setup') -Directory|Sort-Object CreationTimeUtc)[-1].FullName}
 function Validate([string]$Path){$value=& (Join-Path $PhpRoot 'php\php.exe') (Join-Path $package 'configure-dtls.php') inspect $Path;if($LASTEXITCODE){throw 'Native DTLS inspection failed.'};return ($value|ConvertFrom-Json).state}
 Install;Check ((Validate $certificate) -ceq 'valid');$firstHash=Get-OpenWebDtlsHash $certificate;$firstAcl=(Get-Acl -LiteralPath $certificate).Sddl
 Assert-OpenWebDtlsPrivate $certificate;$checks++
 $transaction=LastTransaction;$journal=Read-OpenWebDtlsJournal $transaction $certificate;Check ($journal.state -ceq 'committed' -and !$journal.before_exists)
 Install;Check ((Get-OpenWebDtlsHash $certificate) -ceq $firstHash -and (Get-Acl -LiteralPath $certificate).Sddl -ceq $firstAcl -and @(Get-ChildItem (Join-Path $state 'dtls-setup') -Directory).Count -eq 1)
 function Remove-Item {
  param([string]$LiteralPath,[switch]$Force,[switch]$Recurse,[string]$ErrorAction)
  if($LiteralPath -ceq $certificate){return}
  Microsoft.PowerShell.Management\Remove-Item @PSBoundParameters
 }
 if($LegacyCommon){
  $legacyAst=[Management.Automation.Language.Parser]::ParseFile($LegacyCommon,[ref]$tokens,[ref]$errors);if($errors.Count){throw 'The exact old DTLS helper must parse.'}
  $legacy=@($legacyAst.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Undo-OpenWebDtls'},$true));if($legacy.Count -ne 1){throw 'The exact old recovery function is required.'}
  Invoke-Expression ($legacy[0].Extent.Text.Replace('function Undo-OpenWebDtls(','function Undo-LegacyOpenWebDtls('));Undo-LegacyOpenWebDtls $transaction $certificate
  Check ((Test-Path -LiteralPath $certificate) -and (Read-OpenWebDtlsJournal $transaction $certificate).state -ceq 'recovered')
 }
 Refuse {Undo-OpenWebDtls $transaction $certificate}
 Check ((Test-Path -LiteralPath $certificate) -and (Read-OpenWebDtlsJournal $transaction $certificate).state -ceq 'recovering')
 Remove-Item Function:\Remove-Item
 Undo-OpenWebDtls $transaction $certificate;Check (!(Test-Path -LiteralPath $certificate))
 # A valid customer certificate, including its existing permissions, is untouched.
 Copy-Item (Join-Path $fixture 'valid.pem') $certificate
 $customAcl=New-OpenWebDtlsAcl;$customAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]'S-1-5-32-545','Read','Allow'));Set-Acl $certificate $customAcl
 $validHash=Get-OpenWebDtlsHash $certificate;$validAcl=(Get-Acl $certificate).Sddl
 Install;Check ((Get-OpenWebDtlsHash $certificate) -ceq $validHash -and (Get-Acl $certificate).Sddl -ceq $validAcl)
 foreach($name in 'custom.pem','expired.pem','adjacent.pem','malformed.pem'){
  Copy-Item (Join-Path $fixture $name) $certificate -Force;$hash=Get-OpenWebDtlsHash $certificate;$acl=(Get-Acl $certificate).Sddl
  Refuse {Install};Check ((Get-OpenWebDtlsHash $certificate) -ceq $hash -and (Get-Acl $certificate).Sddl -ceq $acl)
 }
 Copy-Item (Join-Path $fixture 'stock.pem') $certificate -Force;Set-Acl $certificate $customAcl
 $stockHash=Get-OpenWebDtlsHash $certificate;$stockAcl=(Get-Acl $certificate).Sddl
 Check ((Validate $certificate) -ceq 'stock_overflow');Install;Check ((Validate $certificate) -ceq 'valid')
 $transaction=LastTransaction;$journal=Read-OpenWebDtlsJournal $transaction $certificate
 Check ($journal.before_exists -and $journal.before_sha256 -ceq $stockHash -and $journal.before_sddl -ceq $stockAcl)
 # Simulate process loss after replacement but before the committed journal.
 $journal.state='applying';Write-OpenWebPrivateState (Join-Path $transaction 'journal.json') $journal
 Refuse {Install};Undo-OpenWebDtls $transaction $certificate
 Check ((Get-OpenWebDtlsHash $certificate) -ceq $stockHash -and (Get-Acl $certificate).Sddl -ceq $stockAcl)
 Install;$transaction=LastTransaction;$journal=Read-OpenWebDtlsJournal $transaction $certificate;$installed=[IO.File]::ReadAllBytes($certificate);$installedAcl=(Get-Acl $certificate).Sddl
 # Refuse foreign bytes, foreign ACL, changed service identity and tampered backup.
 [IO.File]::WriteAllText($certificate,'foreign identity');Refuse {Undo-OpenWebDtls $transaction $certificate};Check ([IO.File]::ReadAllText($certificate) -ceq 'foreign identity')
 Set-OpenWebDtlsCertificate $certificate $installed $installedAcl
 $foreign=New-OpenWebDtlsAcl;$foreign.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]'S-1-5-11','Read','Allow'));Set-Acl $certificate $foreign;$foreignAcl=(Get-Acl $certificate).Sddl;Refuse {Undo-OpenWebDtls $transaction $certificate};Check ((Get-Acl $certificate).Sddl -ceq $foreignAcl)
 Set-OpenWebFileSddl -LiteralPath $certificate -Sddl $installedAcl
 $script:service.start_mode='Manual';Refuse {Undo-OpenWebDtls $transaction $certificate};$script:service.start_mode='Disabled'
 $before=Join-Path $transaction 'before.pem';$beforeBytes=[IO.File]::ReadAllBytes($before);[IO.File]::WriteAllText($before,'tampered private backup');Refuse {Undo-OpenWebDtls $transaction $certificate};[IO.File]::WriteAllBytes($before,$beforeBytes)
 $journal.before_exists='true';Write-OpenWebPrivateState (Join-Path $transaction 'journal.json') $journal;Refuse {Undo-OpenWebDtls $transaction $certificate};$journal.before_exists=$true;Write-OpenWebPrivateState (Join-Path $transaction 'journal.json') $journal
 Undo-OpenWebDtls $transaction $certificate;Check ((Get-OpenWebDtlsHash $certificate) -ceq $stockHash -and (Get-Acl $certificate).Sddl -ceq $stockAcl)
 # Actual failure after MoveFileEx must restore exact original identity/ACL.
 $realMove=${function:Move-OpenWebDtlsFile};$script:failOnce=$true
 function Move-OpenWebDtlsFile([string]$Source,[string]$Target){& $realMove $Source $Target;if($script:failOnce -and $Target -ceq $certificate){$script:failOnce=$false;throw 'Owned native post-replacement fault.'}}
 Refuse {Install};Check ((Get-OpenWebDtlsHash $certificate) -ceq $stockHash -and (Get-Acl $certificate).Sddl -ceq $stockAcl)
 # Pre-journal process loss never reaches the installed identity. Recovery
 # retires strict private staging evidence rather than guessing or deleting it.
 foreach($kind in 'empty','generation','desired','partial_journal'){
  $identity=[Guid]::NewGuid().ToString('N');$staging=Join-Path (Join-Path $state 'dtls-setup') ('staging-'+$identity);New-OpenWebDtlsPrivate $staging
  if($kind -ceq 'generation'){Write-OpenWebDtlsNew (Join-Path $staging 'generation.cnf') ([Text.Encoding]::UTF8.GetBytes('[req]'))}
  if($kind -ceq 'desired'){[IO.File]::WriteAllBytes((Join-Path $staging 'desired.pem'),$installed)}
  if($kind -ceq 'partial_journal'){Write-OpenWebDtlsNew (Join-Path $staging ('journal.json.'+[Guid]::NewGuid().ToString('N')+'.new')) ([Text.Encoding]::UTF8.GetBytes('{'))}
  Refuse {Install}
  Install-OpenWebDtls -PackageRoot $package -Root $PhpRoot -State $state -Certificate $certificate -Recover|Out-Null
  Check (!(Test-Path -LiteralPath $staging) -and (Test-Path -LiteralPath (Join-Path (Join-Path $state 'dtls-setup') ('abandoned-'+$identity))) -and (Get-OpenWebDtlsHash $certificate) -ceq $stockHash -and (Get-Acl $certificate).Sddl -ceq $stockAcl)
 }
 $foreignStage=Join-Path (Join-Path $state 'dtls-setup') ('staging-'+[Guid]::NewGuid().ToString('N'));New-OpenWebDtlsPrivate $foreignStage;Write-OpenWebDtlsNew (Join-Path $foreignStage 'foreign.key') ([Text.Encoding]::UTF8.GetBytes('foreign material'))
 Refuse {Install-OpenWebDtls -PackageRoot $package -Root $PhpRoot -State $state -Certificate $certificate -Recover};Check (Test-Path -LiteralPath (Join-Path $foreignStage 'foreign.key'))
 Check ((Get-Acl -LiteralPath (Split-Path $certificate)).Sddl -ceq $certDirectoryAcl -and (Get-OpenWebDtlsHash $unrelated) -ceq $unrelatedHash)
 Check ($script:service.start_mode -ceq 'Disabled' -and (Get-OpenWebDtlsHash (Join-Path $package 'Dtls.Common.ps1')) -ceq $sourceHash)
 # Stock MSI has not yet created cert/ before the first engine start.
 $state=Join-Path $work 'fresh-state';[void][IO.Directory]::CreateDirectory($state);$certificate=Join-Path $work 'fresh-cert\dtls-srtp.pem';$parent=Split-Path $certificate
 Check (!(Test-Path -LiteralPath $parent));Install
 Check ((Validate $certificate) -ceq 'valid' -and (Test-Path -LiteralPath $parent -PathType Container))
 $transaction=LastTransaction;$journal=Read-OpenWebDtlsJournal $transaction $certificate
 Check (!$journal.parent_before_exists -and $journal.parent_create_intent -and $journal.parent_created -and $journal.parent_path -ceq $parent -and (Get-Acl -LiteralPath $parent).Sddl -ceq $journal.parent_desired_sddl)
 Refuse {New-OpenWebDtlsCertificateDirectory $parent $journal.parent_desired_sddl}
 $foreign=Join-Path $parent 'customer-key.pem';[IO.File]::WriteAllText($foreign,'unrelated key');$hash=Get-OpenWebDtlsHash $certificate
 Refuse {Undo-OpenWebDtls $transaction $certificate};Check ((Get-OpenWebDtlsHash $certificate) -ceq $hash -and [IO.File]::ReadAllText($foreign) -ceq 'unrelated key')
 Remove-Item -LiteralPath $foreign -Force
 $changed=New-OpenWebDtlsAcl -Directory;$changed.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]'S-1-5-32-545','ReadAndExecute','Allow'));Set-Acl -LiteralPath $parent -AclObject $changed
 Refuse {Undo-OpenWebDtls $transaction $certificate};Check ((Get-OpenWebDtlsHash $certificate) -ceq $hash)
 Set-OpenWebFileSddl -LiteralPath $parent -Sddl $journal.parent_desired_sddl
 Undo-OpenWebDtls $transaction $certificate;Check (!(Test-Path -LiteralPath $parent))
 # Actual interrupted state immediately after atomic parent creation, before
 # parent_created is flushed and before any installed certificate bytes exist.
 $journal.state='applying';$journal.parent_created=$false;Write-OpenWebDtlsJournal (Join-Path $transaction 'journal.json') $journal
 New-OpenWebDtlsCertificateDirectory $parent $journal.parent_desired_sddl
 Undo-OpenWebDtls $transaction $certificate;Check (!(Test-Path -LiteralPath $parent) -and (Read-OpenWebDtlsJournal $transaction $certificate).state -ceq 'recovered')
 $report=[ordered]@{schema=1;producer='windows_dtls_native.ps1';state='passed';actual_native_windows=$true;actual_openssl=$true;native_ntfs_transactions=$true;service_adapter_double=$true;calling_engine_started=$false;firewall_or_trust_modified=$false;checks=$checks;crypto_checks=[int]$crypto.checks}
 if($ReportPath){$report|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $ReportPath -Encoding UTF8};$report|ConvertTo-Json -Compress
}finally{if(Test-Path -LiteralPath $work){Remove-Item -LiteralPath $work -Recurse -Force}}
