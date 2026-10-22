# Exercise the exact caller observer with synthetic Windows event records.
# No service, event log, network listener, or installed PBX is changed.
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot 'windows-suite.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Suite source does not parse.'}
$function=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'NativeStartupFailure'},$true)
if(!$function){throw 'Native startup observer missing.'}
foreach($name in 'SafeNativeMeetingRuntimeFields','NativeMeetingLogCategories'){$helper=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true);if(!$helper){throw 'Native media helper missing.'};Invoke-Expression $helper.Extent.Text}
Invoke-Expression $function.Extent.Text
$failureFunction=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'SafeFailureFields'},$true)
if(!$failureFunction){throw 'Caller failure filter missing.'};foreach($name in 'SafeQueueFailureFields','SafeVoicemailFailureFields','SafeMailboxFailureFields','SafeHotelFailureFields','SafeSmtpFailureFields','SafeMeetingOwnerPageFields','SafeMeetingMediaFields','SafeMeetingSignalingFields','SafeMeetingPathFields','SafeNativeCleanupFields'){$helper=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true);if(!$helper){throw 'Failure projection dependency missing.'};Invoke-Expression $helper.Extent.Text};Invoke-Expression $failureFunction.Extent.Text
$private=Join-Path ([IO.Path]::GetTempPath()) ('openweb-startup-test-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $private|Out-Null
$state=$private;$started=[DateTime]::UtcNow
$old=@{};foreach($name in 'GITHUB_ACTIONS','RUNNER_ENVIRONMENT','RUNNER_OS','GITHUB_REPOSITORY'){$old[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
$script:sampleState='Stopped';$script:sampleEvents=@()
function Get-CimInstance {param($ClassName,$Filter,$ErrorAction)if($ClassName -ne 'Win32_Service' -or $Filter -ne "Name='FreeSWITCH'"){throw 'Unexpected service query.'};return [pscustomobject]@{Name='FreeSWITCH';State=$script:sampleState;ProcessId=123;ExitCode=1067;ServiceSpecificExitCode=0}}
function Get-WinEvent {param($FilterHashtable,$MaxEvents,$ErrorAction)if($FilterHashtable.Id -ne 1000 -or $FilterHashtable.ProviderName -ne 'Application Error' -or $FilterHashtable.LogName -ne 'Application' -or $MaxEvents -ne 64){throw 'Unscoped event query.'};return $script:sampleEvents}
function Event([string]$App,[string]$Module,[DateTime]$Time,[string]$Code='c0000005',[string]$Offset='000000000000abcd'){
 $xml='<Event><EventData><Data Name="AppName">'+$App+'</Data><Data Name="ModuleName">'+$Module+'</Data><Data Name="ExceptionCode">'+$Code+'</Data><Data Name="FaultingOffset">'+$Offset+'</Data><Data Name="PrivateMarker">private-token-never-public</Data></EventData></Event>'
 $record=[pscustomobject]@{TimeCreated=$Time;Xml=$xml}
 $record|Add-Member -MemberType ScriptMethod -Name ToXml -Value {$this.Xml}
 return $record
}
$count=0
function Check([bool]$Value,[string]$Label){if(!$Value){throw $Label};$script:count++}
try{
 $filtered=SafeFailureFields ([pscustomobject]@{active_case='native_media_peer_tls_registration_0';sip_response_code=401;digest_challenge_count=3;response='private-token-never-public'})
 Check ($filtered.sip_response_code -eq 401 -and $filtered.digest_challenge_count -eq 3) 'Exact media registration numeric fields were lost.'
 Check (($filtered|ConvertTo-Json) -notmatch 'private-token|"response"') 'Private SIP reply escaped the filter.'
 $filtered=SafeFailureFields ([pscustomobject]@{active_case='normal_admin_https_csrf_setup';sip_response_code=401;digest_challenge_count=3})
 Check (!$filtered.ContainsKey('sip_response_code') -and !$filtered.ContainsKey('digest_challenge_count')) 'SIP fields escaped their exact case scope.'
 foreach($values in @(@('401','3'),@(700,4),@(199,-1))){
  $filtered=SafeFailureFields ([pscustomobject]@{active_case='native_media_peer_udp_registration_2';sip_response_code=$values[0];digest_challenge_count=$values[1]})
  Check (!$filtered.ContainsKey('sip_response_code') -and !$filtered.ContainsKey('digest_challenge_count')) 'Malformed numeric SIP fields escaped.'
 }
 $env:GITHUB_ACTIONS='true';$env:RUNNER_ENVIRONMENT='github-hosted';$env:RUNNER_OS='Windows';$env:GITHUB_REPOSITORY='embire2/openwebpbx'
 $script:sampleEvents=@((Event 'FreeSwitchConsole.exe' 'mod_sofia.dll' $started),(Event 'unrelated.exe' 'FreeSwitch.dll' $started),(Event 'FreeSwitchConsole.exe' 'other-private-library.dll' $started),(Event 'FreeSwitchConsole.exe' 'libapr.dll' $started.AddHours(-1)))
 $result=NativeStartupFailure -StartedAt $started -PrivateDirectory $private
 Check ($result.service_observed -and $result.service_state -eq 'Stopped' -and $result.process_id -eq 123 -and $result.win32_exit_code -eq 1067) 'Actual service fields not bounded.'
 Check ($result.events.Count -eq 2 -and $result.events[0].module_basename -eq 'mod_sofia.dll' -and $result.events[1].module_basename -eq 'external_component') 'Application/window/module filtering failed.'
 Check ($result.events[0].exception_code -eq 'c0000005' -and $result.events[0].fault_offset -eq '000000000000abcd') 'Typed exception fields missing.'
 Check (($result|ConvertTo-Json -Depth 8) -notmatch 'private-token|other-private-library|unrelated.exe|PrivateMarker') 'Private event data leaked into facts.'
 Check ((Get-Content (Join-Path $private 'native-event-1.xml') -Raw) -match 'private-token-never-public') 'Raw event was not kept only privately.'
 Check (!$result.native_queries.attempted) 'Stopped service unexpectedly queried.'
 $script:sampleState='Running';$script:sampleEvents=@((Event 'FreeSwitchConsole.exe' 'mod_lua.dll' $started 'bad-secret-code' 'bad-secret-offset'))
 [IO.File]::WriteAllText((Join-Path $private 'installation.json'),'{"SwitchPassword":"invalid"}')
 $result=NativeStartupFailure -StartedAt $started -PrivateDirectory $private
 Check ($result.native_queries.attempted -and !$result.native_queries.authenticated) 'Missing credentials did not fail closed before network.'
 Check (!$result.events[0].Contains('exception_code') -and !$result.events[0].Contains('fault_offset')) 'Invalid typed crash fields escaped.'
 $script:sampleEvents=@(1..20|ForEach-Object {Event 'FreeSwitchConsole.exe' 'FreeSwitch.dll' $started})
 $result=NativeStartupFailure -StartedAt $started -PrivateDirectory $private
 Check ($result.events.Count -eq 8) 'Crash evidence cap failed.'
 $env:GITHUB_ACTIONS='false';$refused=$false
 try{NativeStartupFailure -StartedAt $started -PrivateDirectory $private|Out-Null}catch{$refused=$true}
 Check $refused 'Observer allowed a non-disposable caller.'
 Write-Host ('PASS '+$count+' startup diagnostic checks; no Windows runtime qualification implied.')
}finally{
 foreach($name in $old.Keys){[Environment]::SetEnvironmentVariable($name,$old[$name],'Process')}
 Remove-Item -LiteralPath $private -Recurse -Force
}
