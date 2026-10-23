# SPDX-License-Identifier: AGPL-3.0-or-later
# Portable actual journal/tree consumers, no process action or native ACL claim.
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$tool=Join-Path $PSScriptRoot '../../tools/Test-ClientMedia.ps1';$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile([IO.Path]::GetFullPath($tool),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The actual media wrapper does not parse.'}
foreach($name in @('ClosedKeys','JsonShape','ReadOwnedRows','NoLinks')){$found=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true));if($found.Count -ne 1){throw 'Exactly one actual consumer function required.'};. ([scriptblock]::Create($found[0].Extent.Text))}
$root=Join-Path ([IO.Path]::GetTempPath()) ('phone-media-ownership-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($root);$checks=0
function Check([bool]$Value){if(!$Value){throw 'An actual journal/tree consumer control failed.'};$script:checks++}
function Refuse([scriptblock]$Action){$refused=$false;try{$null=& $Action}catch{$refused=$true};Check $refused}
function WriteRow($Value){$path=Join-Path $root ([Guid]::NewGuid().ToString('N')+'.jsonl');[IO.File]::WriteAllText($path,($Value|ConvertTo-Json -Compress)+"`n",[Text.UTF8Encoding]::new($false));$path}
function Row{[ordered]@{role='peer';pid=12345;created_utc_ticks=[DateTime]::UtcNow.AddSeconds(-5).Ticks;executable_sha256='a'*64}}
try{
 $valid=WriteRow (Row);Check (@(ReadOwnedRows $valid).Count -eq 1)
 $r=Row;$r.pid=0;$path=WriteRow $r;Refuse {ReadOwnedRows $path}
 $r=Row;$r.pid=-1;$path=WriteRow $r;Refuse {ReadOwnedRows $path}
 $r=Row;$r.pid=2147483648;$path=WriteRow $r;Refuse {ReadOwnedRows $path}
 $r=Row;$r.pid=12.5;$path=WriteRow $r;Refuse {ReadOwnedRows $path}
 $r=Row;$r.pid='12345';$path=WriteRow $r;Refuse {ReadOwnedRows $path}
 $r=Row;$r.role='other';$path=WriteRow $r;Refuse {ReadOwnedRows $path}
 $r=Row;$r.created_utc_ticks=0;$path=WriteRow $r;Refuse {ReadOwnedRows $path}
 $r=Row;$r.created_utc_ticks=[DateTime]::UtcNow.AddMinutes(1).Ticks;$path=WriteRow $r;Refuse {ReadOwnedRows $path}
 $r=Row;$r.executable_sha256='A'*64;$path=WriteRow $r;Refuse {ReadOwnedRows $path}
 $r=Row;$r['private']='refuse';$path=WriteRow $r;Refuse {ReadOwnedRows $path}
 $row=(Row|ConvertTo-Json -Compress)+"`n";$path=Join-Path $root 'duplicate.jsonl';[IO.File]::WriteAllText($path,$row+$row);Refuse {ReadOwnedRows $path}
 $path=Join-Path $root 'duplicate-key.jsonl';[IO.File]::WriteAllText($path,$row.Replace('"pid":12345','"pid":12345,"pid":12345'));Refuse {ReadOwnedRows $path}
 $path=Join-Path $root 'partial.jsonl';[IO.File]::WriteAllText($path,$row+'{"role":');Check (@(ReadOwnedRows $path -AllowIncomplete).Count -eq 1);Refuse {ReadOwnedRows $path}
 $path=Join-Path $root 'incomplete-only.jsonl';[IO.File]::WriteAllText($path,'{"role":');Check (@(ReadOwnedRows $path -AllowIncomplete).Count -eq 0);Refuse {ReadOwnedRows $path}
 $path=Join-Path $root 'oversize.jsonl';[IO.File]::WriteAllText($path,(' '*32769));Refuse {ReadOwnedRows $path}
 $path=Join-Path $root 'many.jsonl';$many=@();for($i=0;$i -lt 65;$i++){$r=Row;$r.pid=1000+$i;$many+=($r|ConvertTo-Json -Compress)};[IO.File]::WriteAllText($path,($many -join "`n")+"`n");Refuse {ReadOwnedRows $path}
 $tree=Join-Path $root 'tree';$target=Join-Path $root 'sentinel-target';[void][IO.Directory]::CreateDirectory($tree);[void][IO.Directory]::CreateDirectory($target);$sentinel=Join-Path $target 'sentinel';[IO.File]::WriteAllText($sentinel,'unchanged');$null=NoLinks $tree;Check $true
 $link=Join-Path $tree 'linked';[void][IO.Directory]::CreateSymbolicLink($link,$target);Refuse {NoLinks $tree};Check ((Get-Content -LiteralPath $sentinel -Raw) -ceq 'unchanged');[IO.Directory]::Delete($link)
 [ordered]@{schema=1;state='passed_pure_actual_ownership_consumers';checks=$checks;modelled_process_rows_only=$true;processes_queried_or_changed=$false;native_acl_qualified=$false;actual_native_calling=$false}|ConvertTo-Json -Compress
}finally{Remove-Item -LiteralPath $root -Recurse -Force}
