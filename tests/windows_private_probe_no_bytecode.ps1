[CmdletBinding()]
param([string]$SourceRoot=(Split-Path $PSScriptRoot -Parent),[string]$Python='')
$ErrorActionPreference='Stop';$checks=0
function Check([bool]$Value,[string]$Message){if(!$Value){throw $Message};$script:checks++}
if(!$Python){$Python=if($env:OS -eq 'Windows_NT'){(Get-Command python.exe -CommandType Application -ErrorAction Stop|Select-Object -First 1).Source}else{(Get-Command python3 -CommandType Application -ErrorAction Stop|Select-Object -First 1).Source}}
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-upgrade-acceptance.ps1'),[ref]$t,[ref]$e)
Check (!$e.Count) 'The actual private snapshot source must parse.'
$nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Python'},$true))
Check ($nodes.Count -eq 1) 'One actual private snapshot wrapper is required.'
$actual=$nodes[0].Extent.Text;$needle=' & $python -I -B @Arguments'
Check ($actual.Contains($needle)) 'The observer must explicitly isolate imports and suppress bytecode.'
$legacy=$actual.Replace($needle,' & $python -I @Arguments')
Check ($actual -cne $legacy) 'The differential must change only the missing bytecode flag.'
$import=Join-Path ([IO.Path]::GetTempPath()) ('openweb-private-probe-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($import)
$prior=$env:PYTHONDONTWRITEBYTECODE;$env:PYTHONDONTWRITEBYTECODE='1'
try{
 $driver=Join-Path $import 'import-source.py'
 [IO.File]::WriteAllText($driver,@'
import importlib.util,json,sys
from pathlib import Path
source=Path(sys.argv[1])
spec=importlib.util.spec_from_file_location('backup',source)
b=importlib.util.module_from_spec(spec);spec.loader.exec_module(b)
Path(sys.argv[2]).write_text(json.dumps({'isolated':sys.flags.isolated,'no_bytecode':sys.dont_write_bytecode,'value':b.SNAPSHOT_VALUE,'cache_tag':sys.implementation.cache_tag}))
'@,[Text.UTF8Encoding]::new($false))
 $observed=@{}
 foreach($case in 'old','new'){
  $work=Join-Path $import $case;[void][IO.Directory]::CreateDirectory($work)
  $tools=Join-Path $work 'tools';[void][IO.Directory]::CreateDirectory($tools)
  $module=Join-Path $tools 'backups.py';[IO.File]::WriteAllText($module,'SNAPSHOT_VALUE = 42',[Text.UTF8Encoding]::new($false))
  $beforeHash=(Get-FileHash $module -Algorithm SHA256).Hash;$report=Join-Path $work 'flags.json';$probe=$null;$python=$Python
  . ([scriptblock]::Create($(if($case -ceq 'old'){$legacy}else{$actual})))
  Python @($driver,$module,$report)
  $record=Get-Content $report -Raw|ConvertFrom-Json
  Check ($record.isolated -eq 1 -and $record.value -eq 42) 'Both actual wrapper variants must perform the same isolated source import.'
  Check ((Get-FileHash $module -Algorithm SHA256).Hash -ceq $beforeHash) 'The observer changed the observed source bytes.'
  $added=@(Get-ChildItem $tools -Recurse -Force|Where-Object FullName -ne $module|ForEach-Object {[IO.Path]::GetRelativePath($tools,$_.FullName).Replace('\','/')}|Sort-Object)
  if($case -ceq 'old'){
   Check (!$record.no_bytecode) 'Isolation must reproduce ignoring PYTHONDONTWRITEBYTECODE in the old wrapper.'
   Check ($added.Count -eq 2 -and $added -ccontains '__pycache__' -and $added -ccontains ('__pycache__/backups.'+$record.cache_tag+'.pyc')) 'The old observer must reproduce exactly a cache directory and compiled backup observer.'
  }else{
   Check $record.no_bytecode 'The corrected actual wrapper must suppress compilation.'
   Check ($added.Count -eq 0) 'The corrected observer changed the package/tool inventory.'
  }
  $observed[$case]=@{isolated=[int]$record.isolated;bytecode_disabled=[bool]$record.no_bytecode;added_entries=$added}
 }
 # The other interpreter launch in this source is the existing exact comparer;
 # it already uses both flags and is intentionally unchanged.
 Check ($ast.Extent.Text.Contains("`$arguments=@('-I','-B',(Join-Path `$PSScriptRoot 'windows-compare-json.py')")) 'The independent comparator must retain both flags.'
 $imports=@($ast.Extent.Text.Split("`n")|Where-Object {$_ -match 'spec_from_file_location|exec_module'})
 Check ($imports.Count -eq 3) 'Review every private probe loader: backups plus the two source-only hold observers.'
 [pscustomobject]@{schema=1;state='passed';checks=$checks;scope='Actual wrapper differential with a synthetic source in isolated temporary directories; no installed PBX or main suite';observed=$observed}|ConvertTo-Json -Depth 6
}finally{
 if($null -eq $prior){Remove-Item Env:\PYTHONDONTWRITEBYTECODE -ErrorAction SilentlyContinue}else{$env:PYTHONDONTWRITEBYTECODE=$prior}
 if(Test-Path $import){Remove-Item $import -Recurse -Force}
}
