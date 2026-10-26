# Source-only checks of the actual required native Greetings receipt and caller.
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent))
$ErrorActionPreference='Stop';$checks=0
function Check([bool]$Value){if(!$Value){throw ('Windows Greetings receipt/source control refused at '+(Get-PSCallStack)[1].ScriptLineNumber)};$script:checks++}
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-native-acceptance.ps1'),[ref]$tokens,[ref]$errors);Check ($errors.Count -eq 0)
foreach($name in 'AssertGreetingsNativeCase','CompletedMediaCases'){$node=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true));Check ($node.Count -eq 1);. ([scriptblock]::Create($node[0].Extent.Text))}
$body=(Get-Command AssertGreetingsNativeCase).ScriptBlock.ToString()
$flags=@([regex]::Matches([regex]::Match($body,'\$flags=@\(([^\r\n]+)\)').Groups[1].Value,"'([a-z0-9_]+)'")|ForEach-Object {$_.Groups[1].Value});Check ($flags.Count -eq 19)
function Good{$v=@{case='native_greetings_installed_worker_wire_record_replay_save';passed=$true;state='passed';recording_sha256=('a'*64);instruction_decoded_ratio=.99;replay_decoded_ratio=.99;recording_decoded_ratio=.99};foreach($flag in $flags){$v[$flag]=$true};return($v|ConvertTo-Json|ConvertFrom-Json)}
function Refuses($Rows){$refused=$false;try{AssertGreetingsNativeCase $Rows}catch{$refused=$true};Check $refused}
$good=Good;AssertGreetingsNativeCase @($good);Check (@(CompletedMediaCases @($good)) -ccontains $good.case)
Refuses @();Refuses @($good,$good)
foreach($key in @($good.PSObject.Properties.Name)){$copy=Good;$copy.PSObject.Properties.Remove($key);Refuses @($copy)}
foreach($flag in @('passed')+$flags){foreach($bad in $false,'true',1,$null){$copy=Good;$copy.$flag=$bad;Refuses @($copy);Check (@(CompletedMediaCases @($copy)).Count -eq 0)}}
foreach($key in 'instruction_decoded_ratio','replay_decoded_ratio','recording_decoded_ratio'){
 foreach($bad in '0.99',$true,$null,.79,2.1,[double]::NaN,[double]::PositiveInfinity,[double]::NegativeInfinity){$copy=Good;$copy.$key=$bad;Refuses @($copy)}
 foreach($valid in .8,1,2,[single]0.99,[long]1){$copy=Good;$copy.$key=$valid;AssertGreetingsNativeCase @($copy);Check $true}
}
foreach($bad in '',('a'*63),('A'*64),'PRIVATE',$null,1){$copy=Good;$copy.recording_sha256=$bad;Refuses @($copy)}
$copy=Good;$copy|Add-Member -NotePropertyName raw_file -NotePropertyValue 'PRIVATE';Refuses @($copy)
$copy=Good;$copy.state='failed';Refuses @($copy)
# Require the one new proof after the unchanged original four proofs, directly
# in the full-normal branch and before any native_sip_audio pass assignment.
$branches=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.ElseClause -and $n.ElseClause.Extent.Text.Contains('AssertWelcomeNativeCase $native.checks')},$true));Check ($branches.Count -eq 1)
function ValidBranch($Branch){
 $full=@($Branch.ElseClause.Statements);$proofs=@('AssertExtendedNativeCases $native.checks','AssertWelcomeNativeCase $native.checks','AssertVoicemailDeleteNativeCase $native.checks','AssertCdrBackgroundNativeCase $native.checks','AssertGreetingsNativeCase $native.checks')
 if($full.Count -lt $proofs.Count){return $false}
 for($i=0;$i -lt $proofs.Count;$i++){if($full[$i] -isnot [Management.Automation.Language.PipelineAst] -or $full[$i].Extent.Text -cne $proofs[$i]){return $false}}
 $calls=@($Branch.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'AssertGreetingsNativeCase'},$true))
 return $calls.Count -eq 1 -and $calls[0].Parent.Parent -eq $Branch.ElseClause
}
Check (ValidBranch $branches[0]);$branch=$branches[0].Extent.Text
foreach($replacement in '', 'AssertGreetingsNativeCase $other.checks','if($optional){AssertGreetingsNativeCase $native.checks}','try{AssertGreetingsNativeCase $native.checks}catch{}','AssertGreetingsNativeCase $native.checks;AssertGreetingsNativeCase $native.checks'){
 $changed=$branch.Replace('AssertGreetingsNativeCase $native.checks',$replacement);Check ($changed -cne $branch)
 $t=$null;$e=$null;$parsed=[Management.Automation.Language.Parser]::ParseInput($changed,[ref]$t,[ref]$e);Check ($e.Count -eq 0);Check (!(ValidBranch $parsed.EndBlock.Statements[0]))
}
Write-Output ('PASS '+$checks+' required Windows Greetings receipt/source controls; native Windows remains unqualified')
