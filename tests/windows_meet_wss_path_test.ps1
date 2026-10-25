# Portable actual-AST guards/projection/C# controls; no listener or installed service.
[CmdletBinding()]
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$script:checks=0
function Check([bool]$Value){if(!$Value){throw ('A WSS path control failed at test line '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
function Refuses([scriptblock]$Action){$refused=$false;try{& $Action|Out-Null}catch{$refused=$true};Check $refused}
$path=Join-Path $SourceRoot 'tests/windows-meet-wss-path.ps1';$source=[IO.File]::ReadAllText($path);$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors);Check ($errors.Count -eq 0)
Check (($ast.ParamBlock.Parameters.Name.VariablePath.UserPath -join '|') -ceq 'Hostname|Port|ReportPath|DisposableHostedRunner')
foreach($name in 'Assert-MeetWssPathRunner','Assert-MeetWssPathTarget','Assert-MeetWssPathReport','Assert-MeetWssPathHosts','Assert-MeetWssPathProxy','Get-MeetWssPathFields'){
 $nodes=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true));Check ($nodes.Count -eq 1);Invoke-Expression $nodes[0].Extent.Text
}
$code=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value.Contains('public static class OpenWebMeetWssPathProbe')},$true));Check ($code.Count -eq 1)
Add-Type -TypeDefinition $code[0].Value
Check ($source -cnotmatch 'RemoteCertificateValidationCallback|ServerCertificateValidationCallback|SkipCertificateCheck|Import-Certificate|New-SelfSignedCertificate|CommitChanges|Start-Process|Start-Job|Start-ThreadJob|Set-Acl|icacls')
foreach($fence in 'CancelAfter(4500)','4500-(int)clock.ElapsedMilliseconds','5000-(int)clock.ElapsedMilliseconds','socket.Abort()','socket.Dispose()','cancel.Dispose()','pending.IsCompleted','new byte[8192]','body.Length+result.Count>16384','socket.Options.Proxy=null','socket.Options.UseDefaultCredentials=false','FileMode]::CreateNew','Assert-MeetWssPathPrivate $parent',"state='observed'",'WebSocketMessageType.Text,true') {Check ($source.Contains($fence))}
foreach($fence in 'ProbeCore(target,false)','ProbeCore(target,true)','new ArraySegment<byte>(request,0,4096),WebSocketMessageType.Text,false','Task.Delay(100,cancel.Token)','new ArraySegment<byte>(request,4096,4096),WebSocketMessageType.Text,true') {Check ($source.Contains($fence))}
$facts=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$facts'},$true));Check ($facts.Count -eq 1)
$fake=@{observed=$true};$backend=$fake;$frontend=$fake;$fragmentedBackend=$fake;$fragmentedFrontend=$fake
Invoke-Expression $facts[0].Extent.Text
Check (($facts.Keys -join '|') -ceq 'schema|state|backend|frontend|fragmented_backend|fragmented_frontend' -and $facts.schema -eq 1 -and $facts.state -ceq 'observed')
foreach($name in 'backend','frontend','fragmented_backend','fragmented_frontend'){Check ([object]::ReferenceEquals($facts[$name],$fake))}
$public=@([OpenWebMeetWssPathProbe].GetMethods([Reflection.BindingFlags]'Public,Static,DeclaredOnly'))
Check ($public.Count -eq 2 -and (($public.Name|Sort-Object)-join '|') -ceq 'Probe|ProbeFragmented')
foreach($method in $public){Check ($method.GetParameters().Count -eq 1 -and $method.GetParameters()[0].ParameterType -eq [bool])}
$environment=@{GITHUB_ACTIONS='true';RUNNER_ENVIRONMENT='github-hosted';RUNNER_OS='Windows';GITHUB_REPOSITORY='embire2/openwebpbx';GITHUB_EVENT_NAME='workflow_dispatch'}
$os=@{ProductType=3;Caption='Microsoft Windows Server 2025 Datacenter'}
Check (@(Assert-MeetWssPathRunner $true $environment 'Desktop' 5 26100 $true $os).Count -eq 0)
foreach($key in @($environment.Keys)){
 $old=$environment[$key]
 foreach($bad in $null,'','PRIVATE_FIXTURE',$old.ToUpperInvariant()){
  if($bad -ceq $old){continue};$environment[$key]=$bad;Refuses {Assert-MeetWssPathRunner $true $environment 'Desktop' 5 26100 $true $os}
 }
 $environment[$key]=$old
}
Refuses {Assert-MeetWssPathRunner $false $environment 'Desktop' 5 26100 $true $os}
Refuses {Assert-MeetWssPathRunner $true $environment 'Core' 5 26100 $true $os}
Refuses {Assert-MeetWssPathRunner $true $environment 'Desktop' 7 26100 $true $os}
Refuses {Assert-MeetWssPathRunner $true $environment 'Desktop' 5 26099 $true $os}
Refuses {Assert-MeetWssPathRunner $true $environment 'Desktop' 5 26100 $false $os}
foreach($bad in @(@{},@{ProductType=1;Caption=$os.Caption},@{ProductType=3;Caption='Microsoft Windows Server 2022'},@{Caption=$os.Caption})){
 Refuses {Assert-MeetWssPathRunner $true $environment 'Desktop' 5 26100 $true $bad}
}
Check (@(Assert-MeetWssPathTarget 'windowsqa.example.invalid' 8443).Count -eq 0)
foreach($name in '','localhost','WINDOWSQA.EXAMPLE.INVALID','windowsqa.example.invalid/meet-sip/','https://windowsqa.example.invalid'){Refuses {Assert-MeetWssPathTarget $name 8443}}
foreach($number in 0,443,7444,8444){Refuses {Assert-MeetWssPathTarget 'windowsqa.example.invalid' $number}}
$root='C:\ProgramData\OpenWebPBX\native-qualification';$scope='0123456789abcdef01234567'
foreach($position in 'before','after'){Check (@(Assert-MeetWssPathReport ($root+'\'+$scope+'\evidence\meeting-wss-'+$position+'.safe.json') $root).Count -eq 0)}
foreach($bad in ($root+'\short\evidence\meeting-wss-before.safe.json'),($root+'\'+$scope+'\evidence\other.json'),($root+'\'+$scope+'\other\meeting-wss-before.safe.json'),($root+'\'+$scope+'\evidence\meeting-wss-before.safe.json\extra'),($root+'-foreign\'+$scope+'\evidence\meeting-wss-before.safe.json'),($root+'\'+$scope.ToUpperInvariant()+'\evidence\meeting-wss-before.safe.json'),('C:\Temp\'+$scope+'\evidence\meeting-wss-before.safe.json')){Refuses {Assert-MeetWssPathReport $bad $root}}
$hosts="127.0.0.1 openweb-meet.internal`r`n127.0.0.1 windowsqa.example.invalid # owned`r`n"
Check (@(Assert-MeetWssPathHosts ([Text.Encoding]::ASCII.GetBytes($hosts))).Count -eq 0)
foreach($bad in '',$hosts.Replace('127.0.0.1','192.0.2.1'),($hosts+"127.0.0.1 openweb-meet.internal`n"),($hosts+"::1 windowsqa.example.invalid`n"),($hosts+[char]0)){
 Refuses {Assert-MeetWssPathHosts ([Text.Encoding]::ASCII.GetBytes($bad))}
}
$xml='<configuration><system.webServer><rewrite><rules><rule name="OpenWebPBX Meet"><match url="^meet-sip/$"/><action url="https://openweb-meet.internal:7444/" appendQueryString="false"/></rule></rules></rewrite></system.webServer></configuration>'
Check (@(Assert-MeetWssPathProxy ([xml]$xml) $true $false 0).Count -eq 0)
Refuses {Assert-MeetWssPathProxy ([xml]$xml) $false $false 0};Refuses {Assert-MeetWssPathProxy ([xml]$xml) $true $true 0};Refuses {Assert-MeetWssPathProxy ([xml]$xml) $true $false 1}
foreach($bad in $xml.Replace('7444','7445'),$xml.Replace('appendQueryString="false"','appendQueryString="true"'),$xml.Replace('OpenWebPBX Meet','Foreign'),$xml.Replace('^meet-sip/$','^.*$')){Refuses {Assert-MeetWssPathProxy ([xml]$bad) $true $false 0}}
function Good {return @{observed=$true;connected=$true;sent=$true;response_received=$true;large_sent=$true;large_response_received=$true;status_code=200;large_status_code=200;phase='complete';error_kind='none';closed_exact=$true;elapsed_ms=31}}
foreach($object in $false,$true){
 $good=Good;$record=if($object){[pscustomobject]$good}else{$good};$safe=Get-MeetWssPathFields $record;Check ($safe.Count -eq 12)
 foreach($key in $good.Keys){
  $copy=Good;$null=$copy.Remove($key);if($object){$copy=[pscustomobject]$copy};Check ($null -eq (Get-MeetWssPathFields $copy))
 }
 foreach($key in 'uri','headers','body','cookie','user_agent','error'){$copy=Good;$copy[$key]='PRIVATE_FIXTURE';if($object){$copy=[pscustomobject]$copy};Check ($null -eq (Get-MeetWssPathFields $copy))}
 foreach($key in 'observed','connected','sent','response_received','large_sent','large_response_received','closed_exact'){
  foreach($value in @($false,$true)){$copy=Good;$copy[$key]=$value;if($object){$copy=[pscustomobject]$copy};Check ($null -ne (Get-MeetWssPathFields $copy))}
  foreach($value in @($null,0,1,'true',@($true),@{})){$copy=Good;$copy[$key]=$value;if($object){$copy=[pscustomobject]$copy};Check ($null -eq (Get-MeetWssPathFields $copy))}
 }
 foreach($key in 'status_code','large_status_code','elapsed_ms'){
  $maximum=if($key -ceq 'elapsed_ms'){6000}else{699}
  foreach($value in @([int]0,[long]0,[int]$maximum,[long]$maximum)){$copy=Good;$copy[$key]=$value;if($object){$copy=[pscustomobject]$copy};Check ($null -ne (Get-MeetWssPathFields $copy))}
  foreach($value in @($null,$true,'200',-1,($maximum+1),[double]1,@(200),@{})){$copy=Good;$copy[$key]=$value;if($object){$copy=[pscustomobject]$copy};Check ($null -eq (Get-MeetWssPathFields $copy))}
 }
 foreach($pair in @(@('phase',@('connect','send','receive','complete','unavailable')),@('error_kind',@('none','timeout','tls','websocket','other','unavailable')))){
  foreach($value in $pair[1]){$copy=Good;$copy[$pair[0]]=$value;if($object){$copy=[pscustomobject]$copy};Check ($null -ne (Get-MeetWssPathFields $copy))}
  foreach($value in @($null,$true,0,'PRIVATE_FIXTURE','NONE',@('none'),@{})){$copy=Good;$copy[$pair[0]]=$value;if($object){$copy=[pscustomobject]$copy};Check ($null -eq (Get-MeetWssPathFields $copy))}
 }
}
$flags=[Reflection.BindingFlags]'NonPublic,Static';$type=[OpenWebMeetWssPathProbe]
$request=$type.GetMethod('Request',$flags);$status=$type.GetMethod('Status',$flags);$errorKind=$type.GetMethod('ErrorKind',$flags)
$id='fictional-private-call-id@invalid.invalid'
$small=$request.Invoke($null,@($id,$false));$large=$request.Invoke($null,@($id,$true))
Check ([Text.Encoding]::ASCII.GetByteCount($small) -lt 2048 -and [Text.Encoding]::ASCII.GetByteCount($large) -eq 8192)
Check ($small.StartsWith('OPTIONS sip:openweb-meet.internal SIP/2.0') -and $large.Contains('X-OpenWeb-Test: ') -and $small.EndsWith("Content-Length: 0`r`n`r`n") -and $large.EndsWith("Content-Length: 0`r`n`r`n"))
Check (($small+$large) -cnotmatch 'Authorization:|INVITE|REGISTER|password|token')
$wire="SIP/2.0 200 OK`r`nCall-ID: $id`r`nCSeq: 1 OPTIONS`r`nContent-Length: 0`r`n`r`n"
foreach($code in 100,200,699){Check ($status.Invoke($null,@($wire.Replace('200 OK',([string]$code+' Test')),$id)) -eq $code)}
Check ($status.Invoke($null,@($wire.Replace('Call-ID:','i:'),$id)) -eq 200)
foreach($bad in $wire.Replace('200 OK','99 Bad'),$wire.Replace('200 OK','700 Bad'),$wire.Replace($id,'PRIVATE_FIXTURE'),$wire.Replace('1 OPTIONS','1 INVITE'),$wire.Replace('1 OPTIONS','2 OPTIONS'),$wire.Replace("Call-ID: $id`r`n",''),$wire.Replace("CSeq: 1 OPTIONS`r`n",''),$wire.Replace("Content-Length:","Call-ID: $id`r`nContent-Length:"),$wire.Replace("Content-Length:","CSeq: 1 OPTIONS`r`nContent-Length:"),$wire.TrimEnd()){
 Check ($status.Invoke($null,@($bad,$id)) -eq 0)
}
Check ($errorKind.Invoke($null,@([Security.Authentication.AuthenticationException]::new('PRIVATE_FIXTURE'),$false)) -ceq 'tls')
Check ($errorKind.Invoke($null,@([Net.WebSockets.WebSocketException]::new(),$false)) -ceq 'websocket')
Check ($errorKind.Invoke($null,@([TimeoutException]::new(),$false)) -ceq 'timeout')
Check ($errorKind.Invoke($null,@([InvalidOperationException]::new('PRIVATE_FIXTURE'),$false)) -ceq 'other')
Check ($errorKind.Invoke($null,@([InvalidOperationException]::new('PRIVATE_FIXTURE'),$true)) -ceq 'timeout')
Write-Output "PASS $script:checks actual AST WSS path guards/projection/protocol/C# controls; no listener or installed service invoked"
& (Join-Path $PSScriptRoot 'windows_meet_wss_stock_bootstrap_test.ps1') -SourceRoot $SourceRoot
