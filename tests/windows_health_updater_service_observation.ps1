param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$script:checks=0;$script:records=@();$script:writerFails=$false
function Check([bool]$Value){if(!$Value){throw ('Service observation control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
. (Join-Path $SourceRoot 'tests/windows-health-updater-quiescence.ps1')
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-health-updater-quiescence.ps1'),[ref]$tokens,[ref]$errors);Check ($errors.Count -eq 0)
$function=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Get-HealthUpdaterQualificationState'},$true));Check ($function.Count -eq 1)
$guards=@($function[0].FindAll({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.Contains("throw 'The updater qualification refuses an unexpected service.'")},$true));Check ($guards.Count -eq 1)
$guard=[scriptblock]::Create($guards[0].Extent.Text)
$observed=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Write-HealthUpdaterServiceRefusal'},$true));Check ($observed.Count -eq 1)
$commands=@($observed[0].FindAll({param($n)$n -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object {$_.GetCommandName()}|Sort-Object -Unique)
Check ($commands.Count -eq 4 -and $commands -ccontains 'ConvertTo-Json' -and $commands -ccontains 'Write-Host' -and $commands -ccontains 'Test-HealthUpdaterServiceImage' -and $commands -ccontains 'Get-HealthUpdaterImageRelation')
function Write-Host($Object){if($script:writerFails){throw 'PRIVATE_WRITER'};$script:records+=,[string]$Object}
$expected='C:\PRIVATE_EXPECTED\OpenWebPbx.Updater.exe'
function Row {return @{Name='OpenWebPBXUpdater';PathName=('"'+$expected+'"');StartName='LocalSystem';StartMode='Auto';State='Running'}}
function Invoke-Guard($Rows,[bool]$Refused){
 $service=@($Rows);$script:records=@();$caught=$null
 try{& $guard}catch{$caught=$_}
 Check (($null -ne $caught) -eq $Refused)
 if($Refused){Check ($caught.Exception.GetType().Name -ceq 'RuntimeException' -and $caught.Exception.Message -ceq 'The updater qualification refuses an unexpected service.')}
 if(!$Refused -or $script:writerFails){Check ($script:records.Count -eq 0);return}
 Check ($script:records.Count -eq 1)
 $raw=$script:records[0];Check ($raw.Length -le 2081 -and $raw.StartsWith('OPENWEB_UPDATER_SERVICE_REFUSAL ') -and !$raw.Contains('PRIVATE_'))
 $q=$raw.Substring('OPENWEB_UPDATER_SERVICE_REFUSAL '.Length)|ConvertFrom-Json
 Check ((@($q.PSObject.Properties.Name)|Sort-Object) -join ',' -ceq 'account_allowed,count,image_matches,image_relation,kind,name_matches,schema,service_state,startup_allowed,state_allowed')
 Check ($q.image_relation -cin 'quoted_expected','unquoted_expected','canonical_slash_expected','wrong_known_slot','other','unavailable')
 Check ($q.schema -eq 1 -and $q.kind -ceq 'qualification_service_shape_refusal' -and $q.count -cin 'absent','single','multiple')
 foreach($name in 'name_matches','image_matches','account_allowed','startup_allowed','state_allowed'){Check ($q.$name -is [bool])}
 return $q
}
foreach($state in 'Running','Stopped'){$row=Row;$row.State=$state;Invoke-Guard @($row) $false}
foreach($field in 'Name','PathName','StartName','StartMode','State'){
 $row=Row;$row[$field]='PRIVATE_FIELD';$q=Invoke-Guard @($row) $true
 $label=@{Name='name_matches';PathName='image_matches';StartName='account_allowed';StartMode='startup_allowed';State='state_allowed'}[$field]
 Check (!$q.$label)
 foreach($other in 'name_matches','image_matches','account_allowed','startup_allowed','state_allowed'){if($other -cne $label){Check $q.$other}}
}
$q=Invoke-Guard @() $true;Check ($q.count -ceq 'absent' -and $q.service_state -ceq 'unavailable')
$q=Invoke-Guard @((Row),(Row)) $true;Check ($q.count -ceq 'multiple' -and $q.service_state -ceq 'unavailable')
foreach($state in 'Start Pending','Stop Pending','Continue Pending','Pause Pending','Paused','Unknown','PRIVATE_STATE'){
 $row=Row;$row.State=$state;$q=Invoke-Guard @($row) $true
 Check (!$q.state_allowed -and $q.service_state -ceq $(if($state -ceq 'PRIVATE_STATE'){'other'}else{$state}))
}
foreach($identity in 'LocalSystem','NT AUTHORITY\SYSTEM'){$row=Row;$row.StartName=$identity;Invoke-Guard @($row) $false}
foreach($mode in 'Auto','Manual','Disabled'){$row=Row;$row.StartMode=$mode;Invoke-Guard @($row) $false}
$script:writerFails=$true;$row=Row;$row.PathName='PRIVATE_IMAGE';Invoke-Guard @($row) $true;$script:writerFails=$false
$script:records=@();$row=[pscustomobject]@{};$row|Add-Member -MemberType ScriptProperty -Name Name -Value {throw 'PRIVATE_GETTER'}
Write-HealthUpdaterServiceRefusal @($row) $expected;Check ($script:records.Count -le 1);foreach($raw in $script:records){Check ($raw.Length -le 2081 -and !$raw.Contains('PRIVATE_'))}
# Finite accepted representations; all remaining image forms refuse.
foreach($image in @($expected,('"'+$expected+'"'))){$row=Row;$row.PathName=$image;Invoke-Guard @($row) $false}
$spaced='C:\Owned Space\OpenWebPbx.Updater.exe'
Check (Test-HealthUpdaterServiceImage ('"'+$spaced+'"') $spaced)
Check (!(Test-HealthUpdaterServiceImage $spaced $spaced))
foreach($bad in @($null,1,'',('""'+$expected+'""'),('"'+$expected),($expected+'"'),($expected+' --flag'),('"'+$expected+'" --flag'),$expected.Replace('\','/'),$expected.Replace('Updater.exe','Other.exe'),($expected+' '),(' '+$expected))){
 Check (!(Test-HealthUpdaterServiceImage $bad $expected));$row=Row;$row.PathName=$bad;Invoke-Guard @($row) $true
}
$canonical='C:\OpenWebPBX\updater\slots\1.0.21\OpenWebPbx.Updater.exe'
foreach($case in @(@(('"'+$canonical+'"'),'quoted_expected'),@($canonical,'unquoted_expected'),@($canonical.Replace('\','/'),'canonical_slash_expected'),@($canonical.Replace('1.0.21','1.0.20'),'wrong_known_slot'),@('C:\foreign\Updater.exe','other'))){Check ((Get-HealthUpdaterImageRelation $case[0] $canonical) -ceq $case[1])}
Write-Output ('PASS '+$checks+' exact service-guard/failure-only projection controls; sampled rows are doubles, no native service or acceptance claim')
