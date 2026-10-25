# Exact required parent receipt; no service/database/engine operations.
$ErrorActionPreference='Stop';$checks=0
function Check([bool]$value){if(!$value){throw ('Voicemail delete receipt control failed at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'windows-native-acceptance.ps1'),[ref]$tokens,[ref]$errors);Check ($errors.Count -eq 0)
foreach($name in 'AssertVoicemailDeleteNativeCase','CompletedMediaCases'){$node=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));Check ($node.Count -eq 1);. ([scriptblock]::Create($node[0].Extent.Text))}
$function=(Get-Command AssertVoicemailDeleteNativeCase).ScriptBlock.ToString()
$flags=[regex]::Match($function,'\$flags=@\(([^\r\n]+)\)').Groups[1].Value
$flags=@([regex]::Matches($flags,"'([a-z0-9_]+)'")|ForEach-Object {$_.Groups[1].Value});Check ($flags.Count -eq 22)
function Good{$x=@{case='native_voicemail_attach_delete_smtp250_durable_purge';passed=$true;state='passed';attachment_sha256=('a'*64)};foreach($flag in $flags){$x[$flag]=$true};return($x|ConvertTo-Json|ConvertFrom-Json)}
function Refuses($rows){$refused=$false;try{AssertVoicemailDeleteNativeCase $rows}catch{$refused=$true};Check $refused}
$good=Good;AssertVoicemailDeleteNativeCase @($good);Check (@(CompletedMediaCases @($good)) -ccontains $good.case)
Refuses @();Refuses @($good,$good)
foreach($key in @($good.PSObject.Properties.Name)){$copy=Good;$copy.PSObject.Properties.Remove($key);Refuses @($copy)}
foreach($flag in @('passed')+$flags){foreach($bad in $false,'true',1,$null){$copy=Good;$copy.$flag=$bad;Refuses @($copy);Check (@(CompletedMediaCases @($copy)).Count -eq 0)}}
foreach($bad in '',('a'*63),('A'*64),'PRIVATE',$null,1){$copy=Good;$copy.attachment_sha256=$bad;Refuses @($copy)}
$copy=Good;$copy|Add-Member -NotePropertyName private_data -NotePropertyValue 'PRIVATE';Refuses @($copy)
$copy=Good;$copy.case='other';Refuses @($copy)
$copy=Good;$copy.state='failed';Refuses @($copy)
Write-Output ('PASS '+$checks+' actual-parent required Windows voicemail delete receipt controls; no native acceptance inferred')
