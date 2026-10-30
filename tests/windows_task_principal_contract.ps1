# Actual QA validator/diagnostics on synthetic task snapshots. No registration,
# installed task, service or filesystem-security mutation is performed.
[CmdletBinding()]param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$checks=0
function Verify([bool]$Value,[string]$Label){if(!$Value){throw ('Task principal control refused: '+$Label)};$script:checks++}
. (Join-Path $SourceRoot 'tests/windows-task-preservation-diagnostics.ps1')
function Parse([string]$Name){$t=$null;$e=$null;$a=[Management.Automation.Language.Parser]::ParseFile((Join-Path "$SourceRoot/tests" $Name),[ref]$t,[ref]$e);Verify (!$e.Count) ('parse '+$Name);return $a}
function Definition($Ast,[string]$Name){$n=@($Ast.FindAll({param($x)$x-is [Management.Automation.Language.FunctionDefinitionAst] -and $x.Name-ceq $Name},$true));Verify ($n.Count-eq 1) ('unique '+$Name);return $n[0]}
$source=Parse 'windows-updater-qualification.ps1';$manual=Parse 'windows-upgrade-acceptance.ps1';$suite=Parse 'windows-suite.ps1'
Invoke-Expression (Definition $source 'Check').Extent.Text
Invoke-Expression (Definition $source 'QualificationFailureObservation').Extent.Text
$validator=Definition $source 'AssertNewOnboardingTaskSnapshot'
Invoke-Expression $validator.Extent.Text
$native=([Environment]::OSVersion.Platform-eq [PlatformID]::Win32NT)
if($native){$validate=${function:AssertNewOnboardingTaskSnapshot}}else{
 # Portable controls execute the complete principal/action/schedule prefix.
 # The unchanged RawSecurityDescriptor loop requires actual Windows below.
 $body=@($validator.Body.EndBlock.Statements);Verify ($body[-1]-is [Management.Automation.Language.ForEachStatementAst] -and $body[-1].Condition.Extent.Text-ceq '$Record.acl,$Record.security') 'native descriptor boundary explicit'
 $validate=[scriptblock]::Create('param($Record,[DateTime]$Started)'+[Environment]::NewLine+((@($body|Select-Object -SkipLast 1|ForEach-Object {$_.Extent.Text}))-join [Environment]::NewLine))
}
$started=[DateTime]::UtcNow.AddSeconds(-5);$boundary=[DateTime]::Now.ToString('s')
$xml=@"
<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><RegistrationInfo><Description>OpenWeb PBX owned installation registration and activation worker</Description></RegistrationInfo><Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals><Triggers><BootTrigger/><TimeTrigger><StartBoundary>$boundary</StartBoundary><Repetition><Interval>PT1M</Interval></Repetition></TimeTrigger></Triggers><Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><ExecutionTimeLimit>PT20M</ExecutionTimeLimit><StartWhenAvailable>true</StartWhenAvailable></Settings><Actions><Exec><Command>C:\OpenWebPBX\backup-runtime\python.exe</Command><Arguments>-I -B "C:\OpenWebPBX\tools\onboarding.py" --tick</Arguments><WorkingDirectory>C:\OpenWebPBX\tools</WorkingDirectory></Exec></Actions></Task>
"@
function Fresh{return @{exists=$true;enabled=$true;xml=$xml;acl='O:BAG:SYD:P(A;;FA;;;BA)(A;;FA;;;SY)';security='O:BAG:SYD:P(A;;FA;;;BA)(A;;FA;;;SY)';native_principal=@{user='SYSTEM';logon='ServiceAccount';level='Highest'}}}
function Refuse($Record,[string]$Stage){$caught=$null;try{& $validate $Record $started}catch{$caught=$_};Verify ($null-ne $caught) ('refuse '+$Stage);$detail=Read-QualificationTaskFailure $caught.Exception.Data['openweb_qa_task_failure'];Verify ($detail.stage-ceq $Stage -and $detail.task-ceq 'OpenWebPBX-Onboarding') ('closed stage '+$Stage);return $caught}
$r=Fresh;& $validate $r $started;Verify $true 'ordinary omitted SYSTEM XML logon accepted'
$r=Fresh;$r.native_principal.user='S-1-5-18';& $validate $r $started;Verify $true 'native SYSTEM SID accepted'
$r=Fresh;$r.xml=$r.xml.Replace('<RunLevel>','<LogonType>ServiceAccount</LogonType><RunLevel>');& $validate $r $started;Verify $true 'explicit compatible SYSTEM representation accepted'
foreach($value in $null,$false,@{},@{user='SYSTEM';logon='Password';level='Highest'},@{user='S-1-5-20';logon='ServiceAccount';level='Highest'},@{user='SYSTEM';logon=5;level='Highest'},@{user='SYSTEM';logon='ServiceAccount';level='Limited'},@{user='SYSTEM';logon='ServiceAccount';level='Highest';extra='private'}){$r=Fresh;$r.native_principal=$value;$null=Refuse $r 'native_principal'}
foreach($case in 'wrong_logon','duplicate_logon','duplicate_user','duplicate_principal','group','foreign_user'){
 $r=Fresh
 switch($case){
  wrong_logon{$r.xml=$r.xml.Replace('<RunLevel>','<LogonType>Password</LogonType><RunLevel>')}
  duplicate_logon{$r.xml=$r.xml.Replace('<RunLevel>','<LogonType>ServiceAccount</LogonType><LogonType>ServiceAccount</LogonType><RunLevel>')}
  duplicate_user{$r.xml=$r.xml.Replace('</UserId>','</UserId><UserId>S-1-5-18</UserId>')}
  duplicate_principal{$r.xml=$r.xml.Replace('</Principals>','<Principal><UserId>S-1-5-18</UserId></Principal></Principals>')}
  group{$r.xml=$r.xml.Replace('</UserId>','</UserId><GroupId>S-1-5-32-544</GroupId>')}
  foreign_user{$r.xml=$r.xml.Replace('<UserId>S-1-5-18</UserId>','<UserId>S-1-5-20</UserId>')}
 }
 $null=Refuse $r 'xml_principal'
}
foreach($case in 'enabled','action','schedule','boundary'){
 $r=Fresh;$stage=switch($case){enabled{$r.enabled=$false;'new_enabled'};action{$r.xml=$r.xml.Replace('onboarding.py','foreign.py');'new_action'};schedule{$r.xml=$r.xml.Replace('PT1M','PT2M');'new_schedule'};boundary{$r.xml=$r.xml.Replace($boundary,'2000-01-01T00:00:00');'new_boundary'}}
 $null=Refuse $r $stage
}
if($native){$r=Fresh;$r.acl='O:BAG:SYD:P(A;;FA;;;BA)(A;;FA;;;SY)(A;;FA;;;WD)';$null=Refuse $r 'new_mutation_rights'}
foreach($ast in $source,$manual){
 $snapshot=Definition $ast 'TaskSnapshot'
 $proof=@($snapshot.FindAll({param($n)$n-is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text.EndsWith('.native_principal')},$true));Verify ($proof.Count-eq 1 -and $proof[0].Parent-is [Management.Automation.Language.StatementBlockAst] -and $proof[0].Parent.Parent-is [Management.Automation.Language.IfStatementAst]) 'one native proof capture'
 Verify (($proof[0].Parent.Parent.Clauses[0].Item1.Extent.Text-replace '\s','')-ceq "`$name-ceq'OpenWebPBX-Onboarding'") 'all other task snapshot records unchanged'
}
$private='PRIVATE_SENTINEL_XML_ARGUMENTS_SID'
$failed=Refuse @{exists=$true;enabled=$true;xml=$xml;acl='unused';security='unused';native_principal=$null} 'native_principal'
$task=Read-QualificationTaskFailure $failed.Exception.Data['openweb_qa_task_failure']
$report=@{};$_=$failed
$attach=@($manual.FindAll({param($n)$n-is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text-ceq "`$_.Exception.Data.Contains('openweb_qa_task_failure')"},$true));Verify ($attach.Count-eq 1) 'manual closed propagation exists';Invoke-Expression $attach[0].Extent.Text
Verify ($report.task_failure.stage-ceq 'native_principal') 'manual stage propagated'
$signed=QualificationFailureObservation 'at AssertNewOnboardingTaskSnapshot, C:\private\windows-updater-qualification.ps1: line 1' $null $null $null $null $task
Verify ($signed.task_failure.stage-ceq 'native_principal' -and ($signed|ConvertTo-Json -Depth 12 -Compress)-cnotmatch $private) 'signed closed propagation'
$outer=Definition $suite 'SafeFailureFields';$branch=@($outer.FindAll({param($n)$n-is [Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text-ceq '$Record.task_failure'},$true));Verify ($branch.Count-eq 1) 'outer closed propagation exists'
$Record=$report|ConvertTo-Json -Depth 8|ConvertFrom-Json;$safe=@{};Invoke-Expression $branch[0].Extent.Text;Verify ($safe.task_failure.stage-ceq 'native_principal') 'outer JSON transport'
foreach($bad in @{schema=$true;stage='native_principal';task='OpenWebPBX-Onboarding'},@{schema=1;stage=$private;task='OpenWebPBX-Onboarding'},@{schema=1;stage='native_principal';task=$private},@{schema=1;stage='native_principal';task='OpenWebPBX-Onboarding';xml=$private}){Verify ($null-eq (Read-QualificationTaskFailure $bad)) 'untrusted task metadata denied'}
[ordered]@{schema=1;state='passed';checks=$checks;actual_source_validator=$true;native_security_loop_executed=$native;principal_records_are_explicit_test_adapters=$true;manual_outer_signed_diagnostics=$true;registered_task_or_service_changed=$false}|ConvertTo-Json -Compress
