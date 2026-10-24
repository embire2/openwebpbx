# Actual signed-updater snapshot AST with temporary files and explicit ACL/COM
# doubles. Retained old code proves omitted nodes/tasks caused false equality.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$script:checks=0
function Assert([bool]$Value){if(!$Value){throw ('Signed-updater inventory control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
function Check([bool]$Value,[string]$Message){if(!$Value){throw $Message}}
function Native([string]$Path){return $Path.Replace('\',[string][IO.Path]::DirectorySeparatorChar)}
function Fingerprint($Map){
 $rows=@(foreach($key in ($Map.Keys|Sort-Object -CaseSensitive)){
  $values=@(foreach($field in ($Map[$key].Keys|Sort-Object -CaseSensitive)){[ordered]@{name=$field;value=$Map[$key][$field]}})
  [ordered]@{name=$key;values=$values}
 });return ConvertTo-Json -InputObject $rows -Depth 12 -Compress
}
function Get-Acl {param([string]$LiteralPath) $key=Native $LiteralPath;if($script:acls.ContainsKey($key)){return [pscustomobject]@{Sddl=$script:acls[$key]}};return [pscustomobject]@{Sddl='FICTIONAL_OWNED_ACL'}}
function SnapshotHash([string]$Path,[string]$Stage){Check ($Stage -cin 'unobserved','before_fault_full','before_fault_protected','after_fault_full','after_normal_protected') 'Unexpected snapshot stage';return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Parse([string]$Path){$tokens=$null;$errors=$null;$node=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors);Assert ($errors.Count -eq 0);return $node}
$sourcePath=Join-Path $SourceRoot 'tests/windows-updater-qualification.ps1';$ast=Parse $sourcePath
foreach($name in 'FileSnapshot','TaskSnapshot','NormalTaskPreservation'){
 $node=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));Assert ($node.Count -eq 1);Invoke-Expression $node[0].Extent.Text
}
. (Join-Path $SourceRoot 'tests/fixtures/windows-updater-snapshot-before-modern.ps1')
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('openweb-updater-inventory-'+[Guid]::NewGuid().ToString('N'));$oldSystemRoot=$env:SystemRoot
try{
 $work=$temporary
 $root=Join-Path $temporary 'root';$state=Join-Path $temporary 'state';$engine=Join-Path $temporary 'engine';$configuration=Join-Path $temporary 'configuration';$env:SystemRoot=Join-Path $temporary 'Windows';$script:acls=@{}
 # Explicit configured-CDR-path adapter; this inventory component does not run
 # Windows PHP/native path protection. The returned spool is real owned files.
 $PackageRoot=Join-Path $temporary 'package';$null=[IO.Directory]::CreateDirectory($PackageRoot)
 [IO.File]::WriteAllText((Join-Path $PackageRoot 'CallRecords.Common.ps1'),'function Get-OpenWebCallRecordPlan {param($PackageRoot,$Root,$EngineRoot) return @{Path=(Join-Path $EngineRoot "log/xml_cdr")}}')
 $privateDirectories=@("$root\php",$configuration,"$state\storage","$state\mobile-notifications","$state\mail","$state\phone-tls","$state\public-access","$state\meet-proxy","$state\tenant-domains","$state\automatic-backups","$state\backup-restore","$state\backup-control","$state\backup-downloads","$state\codec-compiler-cache","$state\codec-build","$state\phone-health-runtime","$state\stun-setup","$state\dtls-setup",(Join-Path $engine 'log/xml_cdr'))
 $programDirectories=@("$root\web","$root\server","$root\desktop","$root\tools","$root\backup-runtime","$root\acme","$root\updater\slots","$engine\conf","$engine\scripts","$engine\mod","$engine\sounds")
 $parents=@($root,"$root\updater",$state,$engine,"$engine\cert")
 $fixed=@("$state\runtime.json","$state\phone-tls.json","$state\phone-health-instance.json","$state\stun.json","$state\native-engine.json","$state\local-codec.json","$state\meet-ca.pem","$state\meet-proxy.json","$engine\cert\dtls-srtp.pem","$engine\libbcg729.dll")
 $fullOnly=@("$state\installation.json","$state\updater-install.json")
 foreach($directory in $privateDirectories+$programDirectories+$parents){$null=[IO.Directory]::CreateDirectory((Native $directory))}
 foreach($directory in $privateDirectories+$programDirectories){[IO.File]::WriteAllText((Join-Path (Native $directory) 'owned.bin'),'FICTIONAL_'+$directory)}
 foreach($path in $fixed+$fullOnly+@("$root\php\php.ini","$root\php\ext\custom.dll","$root\php\php.exe","$root\php\extras\ssl\openssl.cnf","$root\php\extras\ssl\cacert.pem")){$native=Native $path;$null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($native));[IO.File]::WriteAllText($native,'FICTIONAL_FIXED_'+$path)}
 $full=FileSnapshot -Stage before_fault_full;$protected=FileSnapshot -Protected -Stage before_fault_protected
 foreach($dir in $privateDirectories+$programDirectories){Assert ($full.ContainsKey((Native $dir)) -and $full.ContainsKey((Join-Path (Native $dir) 'owned.bin')))}
 foreach($dir in $privateDirectories){Assert ($protected.ContainsKey((Native $dir)) -and $protected.ContainsKey((Join-Path (Native $dir) 'owned.bin')))}
 foreach($dir in $programDirectories){Assert (!$protected.ContainsKey((Native $dir)))}
 foreach($path in $fixed){Assert ($full.ContainsKey($path) -and $protected.ContainsKey($path))}
 foreach($path in $fullOnly){Assert ($full.ContainsKey($path) -and !$protected.ContainsKey($path))}
 foreach($path in $parents){Assert ($full.ContainsKey($path) -and $protected.ContainsKey($path) -and $full[$path].directory)}
 # Every newly covered private tree and fixed key detects bytes, additions,
 # removals and descriptors; no normalization of heartbeat/request files.
 $newTrees=@("$root\php","$state\mail","$state\meet-proxy","$state\tenant-domains","$state\phone-health-runtime","$state\stun-setup","$state\dtls-setup")
 $newFiles=@("$state\phone-health-instance.json","$state\stun.json","$state\meet-ca.pem","$state\meet-proxy.json","$engine\cert\dtls-srtp.pem")
 foreach($scope in $newTrees+$newFiles){
  $path=if($scope -cin $newTrees){Join-Path (Native $scope) 'owned.bin'}else{Native $scope};$original=[IO.File]::ReadAllBytes($path)
  $old=Fingerprint (OldFileSnapshot);$before=Fingerprint (FileSnapshot);$beforeProtected=Fingerprint (FileSnapshot -Protected)
  [IO.File]::WriteAllText($path,'CHANGED_'+$scope)
  Assert ((Fingerprint (OldFileSnapshot)) -ceq $old)
  Assert ((Fingerprint (FileSnapshot)) -cne $before -and (Fingerprint (FileSnapshot -Protected)) -cne $beforeProtected)
  [IO.File]::WriteAllBytes($path,$original)
  $script:acls[$path]='CHANGED_DESCRIPTOR'
  Assert ((Fingerprint (FileSnapshot)) -cne $before -and (Fingerprint (FileSnapshot -Protected)) -cne $beforeProtected)
  $null=$script:acls.Remove($path)
  [IO.File]::Delete($path)
  Assert ((Fingerprint (FileSnapshot)) -cne $before -and (Fingerprint (FileSnapshot -Protected)) -cne $beforeProtected)
  [IO.File]::WriteAllBytes($path,$original)
  Assert ((Fingerprint (FileSnapshot)) -ceq $before -and (Fingerprint (FileSnapshot -Protected)) -ceq $beforeProtected)
 }
 foreach($dir in $newTrees){
  $before=Fingerprint (FileSnapshot);$beforeProtected=Fingerprint (FileSnapshot -Protected);$added=Join-Path (Native $dir) 'new-private-request.json';[IO.File]::WriteAllText($added,'PENDING')
  Assert ((Fingerprint (FileSnapshot)) -cne $before -and (Fingerprint (FileSnapshot -Protected)) -cne $beforeProtected)
  [IO.File]::Delete($added)
  $script:acls[(Native $dir)]='CHANGED_PARENT_DESCRIPTOR'
  Assert ((Fingerprint (FileSnapshot)) -cne $before -and (Fingerprint (FileSnapshot -Protected)) -cne $beforeProtected)
  $null=$script:acls.Remove((Native $dir))
 }
 $certParent=Native "$engine\cert";$baseline=Fingerprint (FileSnapshot);$script:acls[$certParent]='CHANGED_CERT_PARENT'
 Assert ((Fingerprint (FileSnapshot)) -cne $baseline);$null=$script:acls.Remove($certParent)
 # Absence is a distinct inventory. Replacing any protected root/file with a
 # directory/file or symlink must refuse rather than silently omit it.
 $refused=$false;$fixedPath=Native "$state\stun.json";$bytes=[IO.File]::ReadAllBytes($fixedPath);[IO.File]::Delete($fixedPath);$null=[IO.Directory]::CreateDirectory($fixedPath)
 try{FileSnapshot|Out-Null}catch{$refused=$true};Assert $refused;[IO.Directory]::Delete($fixedPath);[IO.File]::WriteAllBytes($fixedPath,$bytes)
 $tree=Native "$state\stun-setup";$moved=$tree+'-owned-moved';[IO.Directory]::Move($tree,$moved);[IO.File]::WriteAllText($tree,'FILE_REPLACES_DIRECTORY');$refused=$false
 try{FileSnapshot|Out-Null}catch{$refused=$true};Assert $refused;[IO.File]::Delete($tree);[IO.Directory]::Move($moved,$tree)
 $link=Join-Path (Native "$state\phone-health-runtime") 'redirect';$null=New-Item -ItemType SymbolicLink -Path $link -Target (Native "$state\mail");$refused=$false
 try{FileSnapshot|Out-Null}catch{$refused=$true};Assert $refused;Remove-Item -LiteralPath $link -Force
 $newAbsent=Native "$state\dtls-setup";$moved=$newAbsent+'-owned-moved';[IO.Directory]::Move($newAbsent,$moved);$absent=Fingerprint (FileSnapshot);[IO.Directory]::Move($moved,$newAbsent);Assert ((Fingerprint (FileSnapshot)) -cne $absent)
 # Execute actual task capture against an explicit Scheduler double, including
 # new task absence/enabled/XML/security/descriptor state.
 $script:tasks=@{};$script:taskSecurity=@{};$script:taskXml=@{}
 $names=@('OpenWebPBX-Backups','OpenWebPBX-Cleanup','OpenWebPBX-Updater-Restart','OpenWebPBX Outgoing Mail','OpenWebPBX-TenantDomains','OpenWebPBX-PhoneHealth','OpenWebPBX Certificate Renewal','OpenWebPBX Pending Phone Certificate')
 foreach($name in $names){$tasks[$name]=[pscustomobject]@{Settings=[pscustomobject]@{Enabled=$true}};$taskSecurity[$name]='TASK_SECURITY';$taskXml[$name]='<Task><Settings><Enabled>true</Enabled></Settings></Task>'}
 function Get-ScheduledTask {[CmdletBinding()]param([string]$TaskName) return $script:tasks[$TaskName]}
 function Export-ScheduledTask([string]$TaskName){return $script:taskXml[$TaskName]}
 function New-Object {param([string]$ComObject)
  Assert ($ComObject -ceq 'Schedule.Service');$object=[pscustomobject]@{}
  $object|Add-Member ScriptMethod Connect {}
  $object|Add-Member ScriptMethod GetFolder {param($Path) Assert ($Path -ceq '\');$folder=[pscustomobject]@{};$folder|Add-Member ScriptMethod GetTask {param($Name) $task=[pscustomobject]@{Name=$Name};$task|Add-Member ScriptMethod GetSecurityDescriptor {param($Flags) Assert ($Flags -eq 7);return $script:taskSecurity[$this.Name]};return $task};return $folder}
  return $object
 }
 $taskBefore=TaskSnapshot;Assert ($taskBefore.Count -eq 8)
 foreach($name in 'OpenWebPBX-TenantDomains','OpenWebPBX-PhoneHealth'){
  Assert ($taskBefore.ContainsKey($name) -and $taskBefore[$name].exists -and $taskBefore[$name].enabled)
  $old=Fingerprint (OldTaskSnapshot);$original=$tasks[$name]
  $tasks[$name].Settings.Enabled=$false;Assert (!(TaskSnapshot)[$name].enabled -and (Fingerprint (TaskSnapshot)) -cne (Fingerprint $taskBefore));Assert ((Fingerprint (OldTaskSnapshot)) -ceq $old);$tasks[$name].Settings.Enabled=$true
  $taskXml[$name]='<Task><CHANGED/></Task>';Assert ((Fingerprint (TaskSnapshot)) -cne (Fingerprint $taskBefore));$taskXml[$name]='<Task><Settings><Enabled>true</Enabled></Settings></Task>'
  $taskSecurity[$name]='CHANGED';Assert ((Fingerprint (TaskSnapshot)) -cne (Fingerprint $taskBefore));$taskSecurity[$name]='TASK_SECURITY'
  $taskPath=Native (Join-Path $env:SystemRoot ('System32/Tasks/'+$name));$acls[$taskPath]='CHANGED';Assert ((Fingerprint (TaskSnapshot)) -cne (Fingerprint $taskBefore));$null=$acls.Remove($taskPath)
  $null=$tasks.Remove($name);Assert (!(TaskSnapshot)[$name].exists -and (Fingerprint (TaskSnapshot)) -cne (Fingerprint $taskBefore));$tasks[$name]=$original
 }
 Assert ((Fingerprint (TaskSnapshot)) -ceq (Fingerprint $taskBefore))
 # Execute the actual renewal normalizer for all four owned repeating
 # workers. TenantDomains has one startup plus one repeating trigger; only
 # its freshly registered boundary and descriptive author/date may advance.
 function WriteJson([string]$Path,$Value){}
 function EqualTaskSnapshots($Before,$After,[string]$Label){Check ($Label -ceq 'normal-task-contract-security') 'Unexpected task comparison label';Check ((Fingerprint $Before) -ceq (Fingerprint $After)) 'Changed task contract/security'}
 function TaskRecord([string]$Xml){return @{exists=$true;enabled=$true;xml=$Xml;acl='ORIGINAL_ACL';security='ORIGINAL_SECURITY'}}
 $started=[DateTime]::UtcNow.AddSeconds(-5);$boundary=[DateTime]::UtcNow.AddMinutes(1).ToString('o')
 $xml='<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><RegistrationInfo><Date>2026-01-01T00:00:00</Date><Author>Administrator</Author></RegistrationInfo><Triggers><BootTrigger/><TimeTrigger><StartBoundary>2026-01-01T00:00:00</StartBoundary><Repetition><Interval>PT2M</Interval></Repetition></TimeTrigger></Triggers><Actions><Exec><Command>owned.exe</Command></Exec></Actions><Principals><Principal><UserId>S-1-5-18</UserId></Principal></Principals><Settings><Enabled>true</Enabled></Settings></Task>'
 foreach($name in 'OpenWebPBX-Backups','OpenWebPBX Outgoing Mail','OpenWebPBX-TenantDomains','OpenWebPBX-PhoneHealth'){
  $beforeTask=@{($name)=(TaskRecord $xml)};$changed=$xml.Replace('2026-01-01T00:00:00',$boundary).Replace('Administrator','SYSTEM')
  NormalTaskPreservation $beforeTask @{($name)=(TaskRecord $changed)} $started;Assert $true
  foreach($case in 'action','file_acl','com_acl','enabled','future_schedule','extra_trigger','interval','principal','setting'){
   $record=TaskRecord $changed
   switch($case){
    'action'{$record.xml=$record.xml.Replace('owned.exe','foreign.exe')}
    'file_acl'{$record.acl='CHANGED'} 'com_acl'{$record.security='CHANGED'} 'enabled'{$record.enabled=$false}
    'future_schedule'{$record.xml=$record.xml.Replace($boundary,[DateTime]::UtcNow.AddDays(1).ToString('o'))}
    'extra_trigger'{$record.xml=$record.xml.Replace('</Triggers>','<TimeTrigger><StartBoundary>'+$boundary+'</StartBoundary></TimeTrigger></Triggers>')}
    'interval'{$record.xml=$record.xml.Replace('PT2M','PT1S')}
    'principal'{$record.xml=$record.xml.Replace('S-1-5-18','S-1-5-21-123')}
    'setting'{$record.xml=$record.xml.Replace('<Enabled>true</Enabled>','<Enabled>false</Enabled>')}
   }
   $refused=$false;try{NormalTaskPreservation $beforeTask @{($name)=$record} $started}catch{$refused=$true};Assert $refused
  }
 }
 # Phone Health re-registers its one-minute trigger too. The complete remaining
 # XML/security contract still compares exactly; native Scheduler is separate.
 $healthBefore=@{'OpenWebPBX-PhoneHealth'=(TaskRecord $xml)}
 NormalTaskPreservation $healthBefore @{'OpenWebPBX-PhoneHealth'=(TaskRecord ($xml.Replace('2026-01-01T00:00:00',$boundary)))} $started;Assert $true
 # Prove quiescence occurs once before all preservation baselines, original
 # choices resume under cleanup lock only after comparisons, then exact stop.
 $commands=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst]},$true))
 $suspend=@($commands|Where-Object {$_.GetCommandName() -ceq 'Suspend-OpenWebQualificationHealth'});$resume=@($commands|Where-Object {$_.GetCommandName() -ceq 'Resume-OpenWebQualificationHealth'})
 Assert ($suspend.Count -eq 2 -and $resume.Count -eq 1)
 $baselines=@($commands|Where-Object {$_.GetCommandName() -cin 'DatabaseSnapshot','FileSnapshot','TaskSnapshot' -and $_.Extent.StartOffset -gt $suspend[0].Extent.EndOffset -and $_.Extent.StartOffset -lt $resume[0].Extent.StartOffset})
 Assert ($baselines.Count -ge 9)
 $beforeDb=@($commands|Where-Object {$_.GetCommandName() -ceq 'DatabaseSnapshot' -and $_.Extent.Text -ceq "DatabaseSnapshot 'before-fault'"});Assert ($beforeDb.Count -eq 1 -and $suspend[0].Extent.EndOffset -lt $beforeDb[0].Extent.StartOffset)
 $comparisons=@($commands|Where-Object {$_.GetCommandName() -cin 'Equal','EqualTaskSnapshots','NormalTaskPreservation' -and $_.Extent.StartOffset -gt $beforeDb[0].Extent.StartOffset});Assert ($comparisons.Count -ge 7)
 foreach($node in $comparisons){Assert ($node.Extent.EndOffset -lt $resume[0].Extent.StartOffset)}
 $outerTry=@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})[-1]
 Assert ($resume[0].Extent.StartOffset -gt $outerTry.Finally.Extent.StartOffset -and $resume[0].Extent.EndOffset -lt $suspend[1].Extent.StartOffset)
 $locks=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$lock'},$true));Assert ($locks.Count -eq 1 -and $locks[0].Extent.EndOffset -lt $resume[0].Extent.StartOffset)
 $fixtureCleanup=@($commands|Where-Object {$_.GetCommandName() -ceq 'Fixture' -and $_.Extent.Text -ceq "Fixture 'cleanup'"});Assert ($fixtureCleanup.Count -eq 1 -and $suspend[1].Extent.EndOffset -lt $fixtureCleanup[0].Extent.StartOffset)
 Write-Output ('PASS '+$checks+' actual signed-updater full/protected inventory, old-source omission negatives, task state/security, typed-node refusal and strict Health quiescence ordering controls')
}finally{$env:SystemRoot=$oldSystemRoot;Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue}
