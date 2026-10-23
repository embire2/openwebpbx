# Actual FinishPhp + real PHP output; no catalogue/Windows native primitives.
param([Parameter(Mandatory)][string]$Php,[string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
. (Join-Path $SourceRoot 'tests/windows_phone_catalogue_proof.ps1')
. (Join-Path $SourceRoot 'tests/windows_phone_catalogue_sealed_output.ps1')
$checks=0
function Check([bool]$Ok){if(!$Ok){throw ('Catalogue output control '+($script:checks+1)+' refused.')};$script:checks++}
function Refuse([scriptblock]$Action){$failed=$false;try{&$Action|Out-Null}catch{$failed=$true};Check $failed}
$Php=[IO.Path]::GetFullPath($Php);Check ([IO.File]::Exists($Php) -and !([IO.File]::GetAttributes($Php) -band [IO.FileAttributes]::ReparsePoint))
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows_phone_catalogue_native.ps1'),[ref]$t,[ref]$e);Check (!$e)
$finish=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'FinishPhp'},$true));Check ($finish.Count -eq 1);.([scriptblock]::Create($finish[0].Extent.Text))
foreach($entry in @(@('', 'empty'),@('  ', 'empty'),@('{"a":1}', 'json_object'),@('[1,2]', 'json_array'),@('1','json_scalar'),@('PRIVATE','non_json'),@("Warning: PRIVATE`n{}",'non_json'))){$r=Get-WindowsPhoneCatalogueChildOutput '--refresh' $false $entry[0] '';Check ($r.stdout_shape -ceq $entry[1]);Check (($r|ConvertTo-Json -Compress) -notmatch 'PRIVATE')}
$r=Get-WindowsPhoneCatalogueChildOutput 'PRIVATE_ACTION' $false 'PRIVATE' 'PRIVATE';Check ($r.action -ceq 'unrecognised' -and $r.stdout_characters -eq 7 -and $r.stderr_characters -eq 7)
Refuse {Get-WindowsPhoneCatalogueChildOutput '--read' $true ('x'*32769) ''}
$good=Get-WindowsPhoneCatalogueChildOutput '--refresh' $false 'PRIVATE' ''
foreach($key in @($good.Keys)){$copy=[ordered]@{};foreach($name in $good.Keys){if($name -cne $key){$copy[$name]=$good[$name]}};Refuse {Read-WindowsPhoneCatalogueChildOutput $copy}}
foreach($change in @(@('action','PRIVATE'),@('expected_success','false'),@('stdout_characters',-1),@('stdout_characters',32769),@('stderr_characters',$true),@('stdout_shape','PRIVATE'),@('php_warning_prefix',1))){$copy=[ordered]@{};foreach($name in $good.Keys){$copy[$name]=$good[$name]};$copy[$change[0]]=$change[1];Refuse {Read-WindowsPhoneCatalogueChildOutput $copy}}
$copy=[ordered]@{};foreach($name in $good.Keys){$copy[$name]=$good[$name]};$copy.raw='PRIVATE';Refuse {Read-WindowsPhoneCatalogueChildOutput $copy}
$work=Join-Path ([IO.Path]::GetTempPath()) ('catalogue-output-'+[Guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($work);$children=[Collections.Generic.List[object]]::new()
function PrivateFile([string]$Path,[string]$Text){[IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))}
# Explicit protected-path adapter; actual original file creation/framing remains real.
function Set-OpenWebRecoveryPrivate {param([string]$Path)if(![IO.File]::Exists($Path)){throw 'Fixture private file absent.'}}
function Assert-OpenWebRecoveryProtected {param([string]$Path,[switch]$Directory,[switch]$Private)if(!(Test-Path -LiteralPath $Path)){throw 'Fixture path absent.'}}
function Launch([string]$Mode){
 $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$Php;$start.Arguments='-n -d display_errors=stdout -d log_errors=0 "'+(Join-Path $work 'output.php')+'" '+$Mode;$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $process=[Diagnostics.Process]::Start($start);$row=[pscustomobject]@{Process=$process;Action='--refresh';ErrorTask=$process.StandardError.ReadToEndAsync()};$children.Add($row);return $row
}
try{
 PrivateFile (Join-Path $work 'output.php') @'
<?php
$mode=$argv[1];
if($mode==='warning'){trigger_error('PRIVATE_WARNING',E_USER_WARNING);echo '{"state":"deferred"}';exit(23);}
if($mode==='invalid'){echo 'PRIVATE_INVALID_JSON';exit(0);}
if($mode==='diagnostic'){echo 'PRIVATE_INVALID_JSON';fwrite(STDERR,'{"schema":1,"producer":"windows_phone_catalogue_native.php","state":"failed","source_basename":"external_component","source_line":7,"error_type":"RuntimeException"}');exit(23);}
echo '{"state":"deferred"}';
'@
 foreach($expected in $true,$false){$r=FinishPhp (Launch 'valid') $expected;Check ($r.Exit -eq 0 -and $r.Record.state -ceq 'deferred')}
 foreach($mode in 'warning','invalid','diagnostic'){
  $capture=Join-Path $work ('OpenWebPBX-Catalogue-Qualification-'+[Guid]::NewGuid().ToString('N'));$null=[IO.Directory]::CreateDirectory($capture);$ReportPath=Join-Path $capture 'native-Core.original.json'
  $child=Launch $mode;$caught=$null;try{$null=FinishPhp $child $false}catch{$caught=$_};Check ($null -ne $caught)
  $observation=Read-WindowsPhoneCatalogueChildOutput $caught.Exception.Data['catalogue_php_output'];Check ($observation.action -ceq '--refresh' -and !$observation.expected_success -and $observation.stdout_shape -ceq 'non_json');Check ($caught.Exception.Data['catalogue_php_child_exit'] -eq $child.Process.ExitCode)
  $originalBinding=Read-WindowsPhoneCatalogueOriginalBinding $caught.Exception.Data['catalogue_php_original'];Check ($originalBinding.stdout_characters-eq $observation.stdout_characters -and $originalBinding.stderr_characters-eq $observation.stderr_characters)
  $raw=[IO.File]::ReadAllBytes((Get-WindowsPhoneCatalogueOriginalPath $ReportPath));$hash=([BitConverter]::ToString([Security.Cryptography.SHA256]::HashData($raw))).Replace('-','').ToLowerInvariant();Check ($hash-ceq $originalBinding.sha256 -and $raw.Length-eq $originalBinding.bytes)
  $index=$children.IndexOf($child);Check ([Text.Encoding]::Unicode.GetString($raw,4,2*$observation.stdout_characters)-ceq [IO.File]::ReadAllText((Join-Path $work ('child-'+$index+'.private.out'))))
  Check ($observation.php_warning_prefix -eq ($mode -ceq 'warning'));Check (($observation|ConvertTo-Json -Compress) -notmatch 'PRIVATE')
  if($mode -ceq 'diagnostic'){Check ((Read-WindowsPhoneCataloguePhpFailure ($caught.Exception.Data['catalogue_php_failure']|ConvertTo-Json|ConvertFrom-Json)).source_line -eq 7)}
 }
 # The exact catch block preserves the original exception when observation fails.
 $catches=@($finish[0].FindAll({param($n)$n -is [Management.Automation.Language.CatchClauseAst] -and $n.Body.Extent.Text.Contains('$original=$_;')},$true));Check ($catches.Count -eq 1)
 $saved=${function:Get-WindowsPhoneCatalogueChildOutput};function Get-WindowsPhoneCatalogueChildOutput {throw 'PRIVATE_OBSERVATION_FAILURE'}
 try{
  $originalError=[InvalidOperationException]::new('PRIVATE_ORIGINAL');$p=[pscustomobject]@{ExitCode=0};$Child=[pscustomobject]@{Action='--refresh';ErrorTask=[pscustomobject]@{Result=''}};$Success=$false;$out=[pscustomobject]@{Result='PRIVATE'};$caught=$null
  try{&([scriptblock]::Create('try{throw $originalError}'+$catches[0].Extent.Text))}catch{$caught=$_}
  Check ($caught.Exception -eq $originalError -and $originalError.Data['catalogue_php_output_observation_refused'] -ceq $true)
  Check ($originalError.Data['catalogue_php_original_observation_refused'] -ceq $true) # CreateNew collision cannot replace the primary.
 }finally{Set-Item -Path function:Get-WindowsPhoneCatalogueChildOutput -Value $saved}
}finally{
 foreach($row in $children){if(!$row.Process.HasExited){$row.Process.Kill();if(!$row.Process.WaitForExit(10000)){throw 'The owned output child did not end.'}};$row.Process.Dispose()}
 [IO.Directory]::Delete($work,$true)
}
Write-Output ('PASS '+$checks+' actual PHP output/FinishPhp/closed metadata/primary preservation controls; no native catalogue pass')
