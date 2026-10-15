[CmdletBinding()]
param([string]$SourceRoot,[switch]$SourceOnly,[switch]$DisposableHostedRunner)
# Stage observation only: exact file equality remains the product acceptance
# contract. No installed files, IIS, services, tasks or database are accessed.
$ErrorActionPreference='Stop';$checks=0
if(!$SourceRoot){$SourceRoot=Split-Path $PSScriptRoot -Parent}
function Require([bool]$Value){$script:checks++;if(!$Value){throw 'The owned PHP stage control refused its source or fixture.'}}
function Parse([string]$Path){$tokens=$null;$errors=$null;$node=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors);Require ($errors.Count -eq 0);return $node}
function FunctionNode($Ast,[string]$Name){$nodes=@($Ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $Name},$true));Require ($nodes.Count -eq 1);return $nodes[0]}
$windows=Join-Path $SourceRoot 'packaging/windows';$pins=@{}
foreach($relative in 'packaging/windows/Install-OpenWebPBX.ps1','packaging/windows/Upgrade-OpenWebPBX.ps1','packaging/windows/Support-Recovery.ps1','packaging/windows/File-Security.ps1','packaging/windows/Configure-PHP.ps1','packaging/windows/cacert.pem','packaging/windows/openssl.cnf','tests/windows-backup-sddl.ps1'){$pins[$relative]=(Get-FileHash -LiteralPath (Join-Path $SourceRoot $relative) -Algorithm SHA256).Hash.ToLowerInvariant()}
$install=Parse (Join-Path $windows 'Install-OpenWebPBX.ps1');$upgrade=Parse (Join-Path $windows 'Upgrade-OpenWebPBX.ps1');$support=Parse (Join-Path $windows 'Support-Recovery.ps1');$configure=Parse (Join-Path $windows 'Configure-PHP.ps1')
$initial=@($install.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'icacls' -and $n.Extent.Text.StartsWith('icacls $root /inheritance:r /grant:r ')},$true))
$hardening=@($upgrade.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Run' -and $n.Extent.Text.StartsWith('Run icacls.exe @($root,')},$true))
Require ($initial.Count -eq 1 -and $hardening.Count -eq 1)
$guard=$hardening[0].Parent
while($guard -and $guard -isnot [Management.Automation.Language.IfStatementAst]){$guard=$guard.Parent}
Require ($guard -and $guard.Extent.Text.Contains('if(!(Test-OpenWebProgramRootPolicy -Root $root))'))
$initialPolicy=[scriptblock]::Create($initial[0].Extent.Text+"`nRequire (`$LASTEXITCODE -eq 0)");$hardenPolicy=[scriptblock]::Create($guard.Extent.Text)
$statements=@($configure.EndBlock.Statements);$end=@(0..($statements.Count-1)|Where-Object {$statements[$_].Extent.Text -ceq 'Import-Module WebAdministration'})
Require ($end.Count -eq 1 -and $end[0] -gt 4)
$fileWriters=[scriptblock]::Create(($statements[0..($end[0]-1)]|ForEach-Object {$_.Extent.Text}) -join "`n")
Require ($fileWriters.ToString().Contains('Copy-Item -LiteralPath') -and $fileWriters.ToString().Contains('[IO.File]::WriteAllText') -and !$fileWriters.ToString().Contains('WebConfiguration'))
$restore=FunctionNode $support 'Restore-OpenWebSupport';$statements=@($restore.Body.EndBlock.Statements)
$begin=@(0..($statements.Count-1)|Where-Object {$statements[$_].Extent.Text -ceq "`$permissions=New-Object 'Collections.Generic.List[object]'"})
Require ($begin.Count -eq 1)
$rawReplay=[scriptblock]::Create(($statements[$begin[0]..($begin[0]+2)]|ForEach-Object {$_.Extent.Text}) -join "`n")
Require ($rawReplay.ToString().Contains('foreach($entry in $record.Acls.PSObject.Properties)') -and $rawReplay.ToString().Contains('Set-OpenWebFileSddl -LiteralPath $permission.Path -Sddl $permission.Sddl') -and !$rawReplay.ToString().Contains('ScheduledTask'))
$metadata=Parse (Join-Path $SourceRoot 'tests/windows-backup-sddl.ps1')
foreach($name in 'EqualBytes','BinaryForm','AclMetadata','DescriptorObjects'){Invoke-Expression ((FunctionNode $metadata $name).Extent.Text)}
$protected={param($descriptor)([int]$descriptor.ControlFlags -band [int][Security.AccessControl.ControlFlags]::DiscretionaryAclProtected) -ne 0}
$inherited={param($ace)([int]$ace.AceFlags -band [int][Security.AccessControl.AceFlags]::Inherited) -ne 0}
foreach($value in 0,4096,4097,32768){Require ((& $protected ([pscustomobject]@{ControlFlags=[Security.AccessControl.ControlFlags]$value})) -eq (($value -band 4096) -ne 0))}
foreach($value in 0,16,17,1){Require ((& $inherited ([pscustomobject]@{AceFlags=[Security.AccessControl.AceFlags]$value})) -eq (($value -band 16) -ne 0))}
$bindings=@{installer_root_sha256=(Get-FileHash -LiteralPath (Join-Path $windows 'Install-OpenWebPBX.ps1') -Algorithm SHA256).Hash.ToLowerInvariant();source_sha256=$pins;raw_replay='exact three production ACL statements; owned path guard and upfront sibling helper binding';php_writer_scope='exact Configure-PHP file statements before Import-Module; IIS statements omitted';principal_scope='same invoking principal for creation and every stage; Administrator-to-SYSTEM transition unqualified'}
if($SourceOnly){@{schema=1;state='source_bound_native_pending';checks=$checks;bindings=$bindings;native_file_security_executed=$false}|ConvertTo-Json -Depth 8 -Compress;exit 0}
Require ($DisposableHostedRunner -and $env:GITHUB_ACTIONS -eq 'true' -and $env:RUNNER_ENVIRONMENT -eq 'github-hosted' -and $env:RUNNER_OS -eq 'Windows' -and $env:GITHUB_REPOSITORY -eq 'embire2/openwebpbx' -and $PSVersionTable.PSEdition -eq 'Desktop' -and $PSVersionTable.PSVersion.Major -eq 5)
$os=Get-CimInstance Win32_OperatingSystem;Require ($os.ProductType -ne 1 -and $os.Caption -match 'Windows Server 2025')
. (Join-Path $windows 'Support-Recovery.ps1');. (Join-Path $windows 'File-Security.ps1')
$identity=[Security.Principal.WindowsIdentity]::GetCurrent();$principal=New-Object Security.Principal.WindowsPrincipal($identity)
$report=@{schema=1;state='running';bindings=$bindings;is_system=[bool]$identity.IsSystem;elevated=[bool]$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator);cases=@();cleanup='pending';product_acceptance_qualified=$false}
Require $report.elevated
$parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\');$parentSddl=(Get-Acl -LiteralPath $parent).Sddl
$outer=Join-Path $parent ('openweb-php-stage-'+[Guid]::NewGuid().ToString('N'));Require (!(Test-Path -LiteralPath $outer))
$privileges=(& whoami.exe /priv|Out-String);Require ($LASTEXITCODE -eq 0);$stage='fixture_creation';$failed=$false
function Run([string]$Executable,[string[]]$Arguments){Require ($Executable -ceq 'icacls.exe' -and $Arguments[0] -ceq $root);& $Executable @Arguments|Out-Null;Require ($LASTEXITCODE -eq 0)}
function Check-SupportPath([string]$Path){$full=[IO.Path]::GetFullPath($Path);Require ($full.Equals($root,[StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase));return $full}
function Snapshot {
 $value=@{}
 foreach($label in $paths.Keys){
  $item=Get-Item -LiteralPath $paths[$label] -Force;Require (!([int]$item.Attributes -band [int][IO.FileAttributes]::ReparsePoint))
  $acl=Get-Acl -LiteralPath $item.FullName;$bytes=$acl.GetSecurityDescriptorBinaryForm();$descriptor=[Security.AccessControl.RawSecurityDescriptor]::new($bytes,0)
  Require ($bytes.Length -le 4096 -and $descriptor.DiscretionaryAcl.Count -le 16)
  $value[$label]=@{Sddl=$acl.Sddl;Descriptor=$descriptor;Directory=[bool]$item.PSIsContainer;Hash=if($item.PSIsContainer){''}else{(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash};Length=if($item.PSIsContainer){0L}else{[long]$item.Length}}
 };return $value
}
function CompareStages($Left,$Right){
 $values=@()
 foreach($label in 'program_root','php_ini','php_openssl','php_cacert'){
  $a=$Left[$label];$b=$Right[$label]
  $values+=@{file_label=$label;strict_sddl_equal=($a.Sddl -ceq $b.Sddl);file_bytes_equal=($a.Hash -ceq $b.Hash -and $a.Length -eq $b.Length);directory_equal=($a.Directory -eq $b.Directory);descriptor=(DescriptorObjects $a.Descriptor $b.Descriptor)}
 };return ,$values
}
try{
 $null=New-Item -ItemType Directory -Path $outer
 & icacls.exe $outer /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F'|Out-Null;Require ($LASTEXITCODE -eq 0)
 foreach($case in 'fresh','after_raw_rollback'){
  $caseFacts=@{case=$case;prior_raw_replay_performed=($case -ceq 'after_raw_rollback')};$report.cases+=,$caseFacts
  $stage='fixture_creation';$root=Join-Path $outer ($case+'\program');$state=Join-Path $outer ($case+'\state');$engine=Join-Path $outer ($case+'\engine')
  $null=New-Item -ItemType Directory -Force $root,$state,$engine
  & $initialPolicy|Out-Null;Require ($LASTEXITCODE -eq 0)
  $paths=@{program_root=$root;php_ini=(Join-Path $root 'php\php.ini');php_openssl=(Join-Path $root 'php\extras\ssl\openssl.cnf');php_cacert=(Join-Path $root 'php\extras\ssl\cacert.pem')}
  $null=New-Item -ItemType Directory -Force (Join-Path $root 'php\extras\ssl')
  [IO.File]::WriteAllText($paths.php_ini,"memory_limit=512M`r`n",[Text.UTF8Encoding]::new($false))
  $PackageRoot=$windows;& $fileWriters|Out-Null
  $baseline=Snapshot
  Require ((& $protected $baseline.program_root.Descriptor) -and $baseline.program_root.Descriptor.DiscretionaryAcl.Count -eq 3)
  foreach($label in 'php_ini','php_openssl','php_cacert'){
   Require (!(& $protected $baseline[$label].Descriptor) -and $baseline[$label].Descriptor.DiscretionaryAcl.Count -eq 3)
   foreach($ace in $baseline[$label].Descriptor.DiscretionaryAcl){Require (& $inherited $ace)}
  }
  $stage='prior_raw_rollback'
  if($case -ceq 'after_raw_rollback'){
   $acls=@{};foreach($label in $paths.Keys){$acls[$paths[$label]]=$baseline[$label].Sddl};$record=@{Acls=[pscustomobject]$acls};& $rawReplay
  }
  $beforeHardening=Snapshot
  $caseFacts.baseline_to_before_hardening=CompareStages $baseline $beforeHardening
  foreach($label in $paths.Keys){Require ($baseline[$label].Sddl -ceq $beforeHardening[$label].Sddl -and (EqualBytes (BinaryForm $baseline[$label].Descriptor) (BinaryForm $beforeHardening[$label].Descriptor)))}
  $stage='root_hardening';& $hardenPolicy;$hardened=Snapshot;$caseFacts.before_to_after_hardening=CompareStages $beforeHardening $hardened
  $stage='permission_capture';$permissions=@(Get-OpenWebUpgradePermissions -Root $root -StateRoot $state -EngineRoot $engine);Require ($permissions.Count -eq 3)
  foreach($permission in $permissions){$label=@($paths.Keys|Where-Object {$paths[$_] -ceq $permission.Path});Require ($label.Count -eq 1 -and $permission.Sddl -ceq $hardened[$label[0]].Sddl)}
  $stage='php_file_writers';& $fileWriters|Out-Null;$written=Snapshot;$caseFacts.after_hardening_to_writers=CompareStages $hardened $written
  $stage='permission_replay';Restore-OpenWebUpgradePermissions -Permissions $permissions -Root $root -StateRoot $state -EngineRoot $engine;$replayed=Snapshot
  $caseFacts.writers_to_replay=CompareStages $written $replayed;$caseFacts.posthardening_to_final=CompareStages $hardened $replayed;$caseFacts.original_to_final=CompareStages $baseline $replayed
  foreach($label in $paths.Keys){Require ($baseline[$label].Sddl -ceq $replayed[$label].Sddl -and (EqualBytes (BinaryForm $baseline[$label].Descriptor) (BinaryForm $replayed[$label].Descriptor)))}
  foreach($permission in $permissions){Require ((Get-Acl -LiteralPath $permission.Path).Sddl -ceq $permission.Sddl)}
  foreach($label in $paths.Keys){Require ($baseline[$label].Hash -ceq $replayed[$label].Hash -and $baseline[$label].Length -eq $replayed[$label].Length)}
  Require ((& whoami.exe /priv|Out-String) -ceq $privileges -and $LASTEXITCODE -eq 0)
 }
 $report.state='observed'
}catch{
 $failed=$true;$report.state='failed';$report.failed_stage=$stage;$report.error_type=if($_.Exception.GetType().Name -in 'RuntimeException','InvalidOperationException','Win32Exception','UnauthorizedAccessException','IOException'){$_.Exception.GetType().Name}else{'other'}
 $report.source_line=[int]$_.InvocationInfo.ScriptLineNumber
 try{if($baseline -and $caseFacts){$caseFacts.failure_vs_original=CompareStages $baseline (Snapshot)}}catch{$report.failure_comparison_unavailable=$true}
}finally{
 try{
  if(Test-Path -LiteralPath $outer){Require ([IO.Path]::GetDirectoryName($outer) -ceq $parent -and !([int](Get-Item -LiteralPath $outer -Force).Attributes -band [int][IO.FileAttributes]::ReparsePoint));Remove-Item -LiteralPath $outer -Recurse -Force}
  Require (!(Test-Path -LiteralPath $outer) -and (Get-Acl -LiteralPath $parent).Sddl -ceq $parentSddl -and (& whoami.exe /priv|Out-String) -ceq $privileges -and $LASTEXITCODE -eq 0)
  $report.cleanup='owned_tree_removed_parent_sddl_and_process_privileges_exact'
 }catch{$failed=$true;$report.cleanup='failed'}
}
$report.checks=$checks;[Console]::Out.WriteLine(($report|ConvertTo-Json -Depth 16 -Compress));if($failed){exit 1}
