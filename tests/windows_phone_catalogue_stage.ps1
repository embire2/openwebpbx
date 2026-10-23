param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$errors=$null;$tokens=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'packaging/windows/WindowsPhoneCatalogue.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The catalogue wrapper syntax is invalid.'}
$functions=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Read-CataloguePreparedStage'},$true))
if($functions.Count -ne 1){throw 'The actual read-only stage consumer is ambiguous.'}
. ([scriptblock]::Create($functions[0].Extent.Text))
$script:checks=0
function Check($Ok,[string]$Why){if(!$Ok){throw $Why};$script:checks++}
function Deny($Value,[string]$Why){$refused=$false;try{$null=Read-CataloguePreparedStage $Value}catch{$refused=$true};Check $refused $Why}
$stage='.accepted-'+('a'*64)+'.new'
Check ($null -eq (Read-CataloguePreparedStage ([pscustomobject]@{schema=1;state='ready';stage=$null}))) 'Ready returns no stage.'
Check ((Read-CataloguePreparedStage ([pscustomobject]@{schema=1L;state='prepared_stage';stage=$stage})) -ceq $stage) 'Exact stage accepts actual int64 schema.'
foreach($value in @($null,@(),@([pscustomobject]@{schema=1;state='ready';stage=$null}),@{schema=1;state='ready';stage=$null},'ready',$true,1)){Deny $value 'Non-object preflight refuses.'}
foreach($schema in @($true,1.0,'1',0,2,$null)){Deny ([pscustomobject]@{schema=$schema;state='ready';stage=$null}) 'Mistyped or unsupported schema refuses.'}
Deny ([pscustomobject]@{schema=1;state='ready';unknown=$null}) 'Unknown field cannot substitute for omitted stage.'
Deny ([pscustomobject]@{schema=1;state='ready';stage=$null;extra=$true}) 'Extra field refuses.'
foreach($state in @('READY','failed','deferred','prepared',$null,$true)){Deny ([pscustomobject]@{schema=1;state=$state;stage=$null}) 'Noncanonical state refuses.'}
foreach($name in @($null,'',('.accepted-'+('a'*32)+'.new'),('.accepted-'+('A'*64)+'.new'),('.publication-'+('a'*32)+'.new'),('../'+$stage),('C:/'+$stage),($stage+'.extra'),@($stage))){Deny ([pscustomobject]@{schema=1;state='prepared_stage';stage=$name}) 'Stage type/name/path refuses.'}
Deny ([pscustomobject]@{schema=1;state='ready';stage=$stage}) 'Ready cannot smuggle a stage.'
Write-Output ('PASS '+$script:checks+' actual read-only catalogue stage consumer controls; no native/task/filesystem action')
