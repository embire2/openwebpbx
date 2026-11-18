param([Parameter(Mandatory)][ValidateSet('Hold','Acquire')][string]$Mode,[Parameter(Mandatory)][string]$Directory,[string]$Source,[int]$AcquisitionSeconds=5,[switch]$BodyFailure)
$ErrorActionPreference='Stop'
$parent=Split-Path -Parent $Directory
if((Split-Path -Leaf $parent) -cnotmatch '^openweb-registration-wait-[a-zA-Z0-9_-]+$' -or !(Test-Path -LiteralPath (Join-Path $parent 'fixture-owner.json') -PathType Leaf)){throw 'Owned test directory required'}
$owner=Get-Content -LiteralPath (Join-Path $parent 'fixture-owner.json') -Raw|ConvertFrom-Json
if($owner.scope -cne 'openweb-registration-wait-fixture'){throw 'Unknown fixture owner'}
if((Split-Path -Leaf $Directory) -cnotmatch '^[a-z-]{1,40}$'){throw 'Owned case directory required'}
if($Mode -ceq 'Hold'){
$lock=[IO.File]::Open((Join-Path $Directory 'upgrade.lock'),'Open','ReadWrite','None')
try{[IO.File]::WriteAllText((Join-Path $Directory 'holder.ready'),'ready');$clock=[Diagnostics.Stopwatch]::StartNew();while(!(Test-Path (Join-Path $Directory 'holder.release')) -and $clock.Elapsed.TotalSeconds -lt 15){Start-Sleep -Milliseconds 10}}finally{$lock.Dispose()}

 return
}
$code=[IO.File]::ReadAllText($Source);$first=$code.IndexOf(' $acquisitionClock=');$end=$code.IndexOf(' $acquisitionClock.Stop()')
if($first -lt 0 -or $end -le $first){throw 'Exact proposed native acquisition block required'}
$actual=$code.Substring($first,$end+' $acquisitionClock.Stop()'.Length-$first)
$global:FixtureBodyCount=0;$state=$Directory;$lock=$null;$watch=[Diagnostics.Stopwatch]::StartNew()
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($code,[ref]$tokens,[ref]$errors);if($errors.Count -or $ast.ParamBlock.Parameters.Count-ne1){throw 'Exact bounded source parameter required'};$sourceParameter=$ast.ParamBlock.Parameters[0].Extent.Text
$script='param($state,'+$sourceParameter+',[switch]$bodyFailure)$lock=$null;try{'+$actual+';$global:FixtureBodyCount++;if($bodyFailure){throw [IO.IOException]::new("private body sharing failure",-2147024864)};@{state="acquired"}}finally{if($lock){$lock.Dispose()}}'
try{
 $result=& ([ScriptBlock]::Create($script)) -state $Directory -AcquisitionSeconds $AcquisitionSeconds -bodyFailure:$BodyFailure
 if($result -is [string]){$result=$result|ConvertFrom-Json}
 $safe=[ordered]@{state=$result.state;bodyCount=$global:FixtureBodyCount;elapsedSeconds=$watch.Elapsed.TotalSeconds}
 if($result.PSObject.Properties['reason']){$safe.reason=$result.reason}
}catch{
 $native=$_.Exception.GetBaseException()
 $safe=[ordered]@{state='error';bodyCount=$global:FixtureBodyCount;elapsedSeconds=$watch.Elapsed.TotalSeconds;errorType=$native.GetType().Name;nativeCode=($native.HResult -band 65535)}
}
[IO.File]::WriteAllText((Join-Path $Directory 'native-result.safe.json'),($safe|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
