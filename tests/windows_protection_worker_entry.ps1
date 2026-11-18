[CmdletBinding()]
param([string]$SourceRoot='', [string]$Python='', [string]$Receipt='')
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or $PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1){throw 'Run on actual Windows PowerShell 5.1.'}
if(!$SourceRoot){$SourceRoot=Split-Path $PSScriptRoot -Parent}
if(!$Python){$Python=(Get-Command python.exe -CommandType Application -ErrorAction Stop).Source}
$source=Join-Path $SourceRoot 'packaging/windows/Protection-Worker.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Recovery worker source must parse.'}
$native=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'C:\OpenWebPBX\backup-runtime\python.exe'},$true))
if($native.Count -ne 1){throw 'Exactly one protected native Python entry is required.'}
$parts=$native[0].CommandElements
if($parts.Count -ne 4 -or $parts[1].Extent.Text -cne '-I' -or $parts[2].Extent.Text -cne '-c' -or $parts[3] -isnot [Management.Automation.Language.StringConstantExpressionAst]){throw 'The isolated Python invocation changed.'}
$fixed=$parts[3].Value
$old='import runpy,sys;sys.path.insert(0,r"C:\OpenWebPBX\tools");sys.argv=[r"C:\OpenWebPBX\tools\protection.py","worker"];runpy.run_path(sys.argv[0],run_name="__main__")'
if($fixed.Contains('"') -or $fixed.Replace("'",'"') -cne $old){throw 'Preserve the original fixed root, argv and runpy body; only native quote spelling may differ.'}
$checks=0;$results=@();$previousPythonPath=$env:PYTHONPATH;$previousExit=$env:OWPBX_ENTRY_TEST_EXIT
function Check([bool]$Value,[string]$Message){if(!$Value){throw $Message};$script:checks++}
$work=Join-Path ([IO.Path]::GetTempPath()) ('openweb protection entry '+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work|Out-Null
try{
 foreach($case in @(@{name='old';payload=$old;exit=0},@{name='fixed';payload=$fixed;exit=0},@{name='fixed-failure';payload=$fixed;exit=7})){
  $leaf=Join-Path $work $case.name;$tools=Join-Path $leaf 'protected tools';$poison=Join-Path $leaf 'untrusted-pythonpath'
  New-Item -ItemType Directory -Path $tools,$poison|Out-Null
  $entry=Join-Path $tools 'protection.py';$body=Join-Path $tools 'result.json';$count=Join-Path $tools 'body-count.txt';$poisoned=Join-Path $poison 'imported.txt'
  # Only these source-only fixture paths replace the two fixed installed paths.
  # The product script, its SYSTEM/ACL guards, services and SQL are never run.
  $payload=$case.payload.Replace('C:\OpenWebPBX\tools\protection.py',$entry).Replace('C:\OpenWebPBX\tools',$tools)
  $fixture=@'
import json,os,sys
from pathlib import Path
import entry_dependency
root=Path(__file__).parent
counter=root/'body-count.txt'
counter.write_text(str(int(counter.read_text())+1 if counter.exists() else 1))
(root/'result.json').write_text(json.dumps({'argv':sys.argv,'isolated':sys.flags.isolated,'name':__name__,'path0':sys.path[0],'dependency':entry_dependency.VALUE}))
raise SystemExit(int(os.environ['OWPBX_ENTRY_TEST_EXIT']))
'@
  [IO.File]::WriteAllText($entry,$fixture,[Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText((Join-Path $tools 'entry_dependency.py'),"VALUE='protected-fixture'",[Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText((Join-Path $poison 'runpy.py'),('from pathlib import Path;Path('+"r'"+$poisoned+"').write_text('bad')"),[Text.UTF8Encoding]::new($false))
  $env:PYTHONPATH=$poison;$env:OWPBX_ENTRY_TEST_EXIT=[string]$case.exit;$stderr=Join-Path $leaf 'stderr.private.txt'
  $prior=$ErrorActionPreference
  try{$ErrorActionPreference='Continue';$global:LASTEXITCODE=$null;$stdout=@(& $Python -I -c $payload 2>$stderr);$actual=$global:LASTEXITCODE}
  finally{$ErrorActionPreference=$prior}
  Check ($null -ne $actual) 'Native Python exit status is required.'
  if($case.name -ceq 'old'){
   Check ($actual -ne 0) 'Original embedded double quotes must reproduce the native failure.'
   Check (!(Test-Path $body) -and !(Test-Path $count)) 'The broken original must never enter the fixture body.'
   Check ([IO.File]::ReadAllText($stderr) -match 'SyntaxError|NameError') 'The old failure must be Python quote parsing or a stripped literal.'
  }else{
   Check ($actual -eq $case.exit) 'Corrected entry must preserve the exact native exit status.'
   Check (Test-Path $body) 'Corrected native entry must execute the source-only fixture.'
   $result=[IO.File]::ReadAllText($body)|ConvertFrom-Json
   Check ($result.argv.Count -eq 2 -and $result.argv[0] -ceq $entry -and $result.argv[1] -ceq 'worker') 'runpy must retain the exact entry and worker argv.'
   Check ($result.isolated -eq 1) 'Python -I must remain enabled.'
   Check ($result.name -ceq '__main__') 'runpy must retain the main-module entry.'
   Check ($result.path0 -ceq $tools -and $result.dependency -ceq 'protected-fixture') 'Only the fixed selected tools directory is explicitly added.'
   Check ([IO.File]::ReadAllText($count) -ceq '1') 'Success and failure bodies must each run exactly once.'
  }
  Check (!(Test-Path $poisoned)) 'Isolated Python must ignore the untrusted PYTHONPATH runpy module.'
  $results+=@{mode=$case.name;expected_exit=$case.exit;native_exit=$actual;body_entered=[bool](Test-Path $body)}
 }
 $receiptBody=@{passed=$true;checks=$checks;actual_ps_version=$PSVersionTable.PSVersion.ToString();old_native_quote_failure_reproduced=$true;source_native_command_extracted_by_ast=$true;fixed_root_translation_only_in_fixture=$true;isolated_worker_argv_and_runpy_preserved=$true;native_failure_body_once=$true;product_worker_imported=$false;product_services_sql_or_data_written=$false;source_worker_sha256=(Get-FileHash $source -Algorithm SHA256).Hash.ToLowerInvariant();outcomes=$results}
 if($Receipt){[IO.File]::WriteAllText($Receipt,($receiptBody|ConvertTo-Json -Depth 7))}
 Write-Host ('Windows protection worker entry: '+$checks+' controls passed.')
}finally{
 if($null -eq $previousPythonPath){Remove-Item Env:\PYTHONPATH -ErrorAction SilentlyContinue}else{$env:PYTHONPATH=$previousPythonPath}
 if($null -eq $previousExit){Remove-Item Env:\OWPBX_ENTRY_TEST_EXIT -ErrorAction SilentlyContinue}else{$env:OWPBX_ENTRY_TEST_EXIT=$previousExit}
 Remove-Item -LiteralPath $work -Recurse -Force
}
exit 0
