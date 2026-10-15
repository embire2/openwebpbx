#Requires -Version 5.1
# Actual cleanup source with fictional IIS objects; no Windows/IIS operations.
$ErrorActionPreference='Stop';$checks=0
function Verify([bool]$Value){$script:checks++;if(!$Value){throw ('IIS cleanup control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)}}
function Check([bool]$Value,[string]$Message){if(!$Value){throw $Message}}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'windows-updater-qualification.ps1'),[ref]$tokens,[ref]$errors)
Verify (@($errors).Count -eq 0)
$nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'StopQualificationIis'},$true))
Verify ($nodes.Count -eq 1);. ([ScriptBlock]::Create($nodes[0].Extent.Text))
function Start-Sleep([int]$Milliseconds){Verify ($Milliseconds -eq 250);$script:sleeps++}
function IisObject([string]$Initial,[int]$StopAfter=0,[string]$Later='Stopped'){
 $item=[pscustomobject]@{current=$Initial;reads=0;stops=0;stop_after=$StopAfter;later=$Later}
 $item|Add-Member ScriptProperty State {$this.reads++;if($this.stop_after -gt 0 -and $this.reads -gt $this.stop_after){$this.current=$this.later};return $this.current}
 $item|Add-Member ScriptMethod Stop {if($this.current -ne 'Started'){throw 'Native-like refusal of redundant Stop.'};$this.stops++;$this.current='Stopping'}
 return $item
}
$site=IisObject 'Stopped';$pool=IisObject 'Stopped';$script:sleeps=0
StopQualificationIis $site $pool;Verify ($site.stops -eq 0 -and $pool.stops -eq 0 -and $sleeps -eq 0)
$site=IisObject 'Started' 4;$pool=IisObject 'Started' 5;$script:sleeps=0
StopQualificationIis $site $pool;Verify ($site.stops -eq 1 -and $pool.stops -eq 1 -and $site.current -eq 'Stopped' -and $pool.current -eq 'Stopped' -and $sleeps -eq 7)
$pool=IisObject 'Stopping' 4;$script:sleeps=0
StopQualificationIis $null $pool;Verify ($pool.stops -eq 0 -and $pool.current -eq 'Stopped' -and $sleeps -eq 3)
$script:sleeps=0;StopQualificationIis $null $null;Verify ($sleeps -eq 0)
foreach($initial in 'Starting','Unknown'){
 $pool=IisObject $initial;$script:sleeps=0;$refused=$false
 try{StopQualificationIis $null $pool}catch{$refused=$_.Exception.Message -ceq 'Owned IIS cleanup found an unexpected state.'}
 Verify ($refused -and $pool.stops -eq 0 -and $sleeps -eq 0)
}
$pool=IisObject 'Stopping' 3 'Unknown';$script:sleeps=0;$refused=$false
try{StopQualificationIis $null $pool}catch{$refused=$_.Exception.Message -ceq 'Owned IIS cleanup found an unexpected state.'}
Verify ($refused -and $pool.stops -eq 0 -and $sleeps -eq 2)
$pool=IisObject 'Stopping';$script:sleeps=0;$refused=$false
try{StopQualificationIis $null $pool}catch{$refused=$_.Exception.Message -ceq 'Owned IIS cleanup did not stop.'}
Verify ($refused -and $pool.stops -eq 0 -and $sleeps -eq 160)
$pool=IisObject 'Started';$script:sleeps=0;$refused=$false
try{StopQualificationIis $null $pool}catch{$refused=$_.Exception.Message -ceq 'Owned IIS cleanup did not stop.'}
Verify ($refused -and $pool.stops -eq 1 -and $sleeps -eq 160)
# The restore caller imports this one function without running updater entrypoint.
$restore=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'windows-restore-qualification.ps1'))
Verify ($restore.Contains("'NativeVersions','StopQualificationIis'"))
Verify ($restore.Contains("try{StopQualificationIis `$manager.Sites['OpenWebPBX'] `$manager.ApplicationPools['OpenWebPBX']}finally{`$manager.Dispose()}"))
Verify ($ast.Extent.Text.Contains('StopQualificationIis $site $pool'))
$manager=[pscustomobject]@{Sites=@{OpenWebPBX=(IisObject 'Stopped')};ApplicationPools=@{OpenWebPBX=(IisObject 'Stopping' 3)}}
$script:sleeps=0;StopQualificationIis $manager.Sites['OpenWebPBX'] $manager.ApplicationPools['OpenWebPBX']
Verify ($manager.Sites['OpenWebPBX'].stops -eq 0 -and $manager.ApplicationPools['OpenWebPBX'].stops -eq 0 -and $manager.ApplicationPools['OpenWebPBX'].current -eq 'Stopped' -and $sleeps -eq 2)
@{schema=1;state='passed';actual_source_controls=$checks;native_iis_executed=$false;deadline_milliseconds=40000}|ConvertTo-Json -Compress
