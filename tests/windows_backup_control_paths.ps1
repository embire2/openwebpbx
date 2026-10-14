# Exercise the actual path guard within a real PowerShell switch statement.
# File/ACL recovery itself requires the separate real Windows qualification.
param([string]$SourceFile=(Join-Path $PSScriptRoot '../packaging/windows/Backup-Control.ps1'),[switch]$ExpectHistoricalFailure)
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($SourceFile,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The exact product helper does not parse.'}
$functions=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'OrdinaryPath'},$true))
if($functions.Count -ne 1){throw 'One actual product path guard is required.'}
. ([ScriptBlock]::Create($functions[0].Extent.Text))
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('openweb-backup-path-'+[Guid]::NewGuid().ToString('N'))
$private=Join-Path $testRoot 'state';$config=Join-Path $testRoot 'configuration';$control=Join-Path $private 'backup-control';$backupEngineRoot=Join-Path $testRoot 'engine'
$switch=$backupEngineRoot # Historical helper's conflicting variable name.
$testPaths=@($private,$config,(Join-Path $backupEngineRoot 'conf'))
$checks=0
function Check([bool]$Value,[string]$Message){if(!$Value){throw $Message};$script:checks++}
try{
 foreach($directory in @($control)+$testPaths){New-Item -ItemType Directory -Path $directory -Force|Out-Null}
 $request=Join-Path $control 'request.json';[IO.File]::WriteAllText($request,'{}')
 $controlProbe=if([IO.Path]::DirectorySeparatorChar -eq [char]92){$request}else{$control}
 Check ((OrdinaryPath $controlProbe -ControlOnly) -eq $controlProbe) 'The exact control scope was refused.'
 $historical=$false
 switch('acl-read'){
  'acl-read'{
   foreach($path in $testPaths){
    try{Check ((OrdinaryPath $path) -eq $path) 'The dispatched path escaped its bound.'}
    catch{if($ExpectHistoricalFailure -and $_.Exception.Message -like '*empty string*'){$historical=$true;break};throw}
   }
  }
 }
 if($ExpectHistoricalFailure){Check $historical 'The historical automatic-switch-variable defect was not reproduced.';Write-Output 'Reproduced the historical path failure inside actual PowerShell switch dispatch.';return}
 foreach($case in @(@{path=(Join-Path $testRoot 'foreign');control=$false},@{path=$config;control=$true})){
  $refused=$false
  try{OrdinaryPath $case.path -ControlOnly:$case.control|Out-Null}catch{$refused=$true}
  Check $refused 'An out-of-scope private/control path was accepted.'
 }
 $file=Join-Path $private 'ordinary.txt';[IO.File]::WriteAllText($file,'Owned portable path fixture')
 $restoreProbe=if([IO.Path]::DirectorySeparatorChar -eq [char]92){$file}else{$private}
 switch('acl-restore'){'acl-restore'{Check ((OrdinaryPath $restoreProbe) -eq $restoreProbe) 'The actual restore dispatch lost the ordinary path.'}}
 Check ((Get-Content -LiteralPath $file -Raw) -eq 'Owned portable path fixture') 'The read-only guard changed fixture bytes.'
 Write-Output ('PASS '+$checks+' actual dispatch/path-scope controls; Windows NTFS recovery remains a separate check.')
}finally{Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue}
