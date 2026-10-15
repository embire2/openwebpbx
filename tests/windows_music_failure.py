#!/usr/bin/env python3
"""Real PHP helper failure/unchanged success plus exact AST consumer privacy controls."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--powershell', default='pwsh')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
checks = 0


def check(value):
    global checks
    assert value
    checks += 1


source = (root/'packaging/windows/configure-music.php').read_text()
guard = "PHP_OS_FAMILY!=='Windows'"
check(source.count(guard) == 1)
with tempfile.TemporaryDirectory(prefix='openweb-music-failure-') as temporary:
    work = Path(temporary)
    helper = work/'configure-music.php'
    # Only the OS guard is adapted; the actual stages/handler/rethrow execute.
    helper.write_text(source.replace(guard, 'false'))
    web = work/'web'
    (web/'resources').mkdir(parents=True)
    (web/'resources/require.php').write_text('''<?php
if(getenv('MUSIC_TEST_STAGE')==='bootstrap')throw new RuntimeException('PRIVATE_BOOTSTRAP_PATH_PASSWORD');
class config {static function load(){return new self;}function get($name,$default){return 'PRIVATE_CONFIG_PATH';}}
class pbx_music {
 static function install($db,$bundle){if(getenv('MUSIC_TEST_STAGE')==='music_install')throw new RuntimeException('PRIVATE_MUSIC_PASSWORD');}
 static function nativeDefault($vars,$conf){if(getenv('MUSIC_TEST_STAGE')==='native_default')throw new TypeError('PRIVATE_VARS_PATH');return false;}
}
''')
    records = []
    for stage in ('bootstrap','music_install','native_default','success'):
        result = subprocess.run(['php', '-n', str(helper), 'owned-bundle', str(web), 'owned-vars'],
                                env=os.environ|{'MUSIC_TEST_STAGE': stage}, capture_output=True, text=True)
        lines = [line for line in result.stderr.splitlines() if line.startswith('OPENWEB_MUSIC_FAILURE ')]
        if stage == 'success':
            check(result.returncode == 0 and not lines and not result.stderr)
            check(json.loads(result.stdout) == {'prepared_music_rates':4,'stock_native_default_updated':False,'explicit_custom_music_preserved':True})
        else:
            check(result.returncode == 255 and len(lines) == 1)
            row = json.loads(lines[0].split(' ',1)[1])
            check(row['stage'] == stage and row['schema'] == 1 and row['source_basename'] == 'require.php')
            check(row['error_type'] == ('TypeError' if stage == 'native_default' else 'RuntimeException'))
            check(type(row['source_line']) is int and 0 < row['source_line'] < 100000)
            check('PRIVATE_' not in lines[0] and 'PRIVATE_' in result.stderr+result.stdout)
            records.append({'text':result.stderr,'expected':row})
    data = work/'records.json'
    data.write_text(json.dumps(records))
    controls = work/'controls.ps1'
    controls.write_text(r'''
param([string]$SourceRoot,[string]$InputPath)
$ErrorActionPreference='Stop';$t=$null;$e=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-upgrade-acceptance.ps1'),[ref]$t,[ref]$e)
if($e.Count){throw 'Actual upgrade hook must parse.'}
foreach($name in 'MusicFailure','Check'){$nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true));if($nodes.Count -ne 1){throw 'Actual functions must be unique.'};Invoke-Expression $nodes[0].Extent.Text}
$project=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.StartsWith("if(`$checkFailure.active_case -ceq 'direct_reapply_complete' -and `$musicFailure){")},$true))
if($project.Count -ne 1){throw 'Actual music projection must be unique.'}
$count=0
function AssertControl([bool]$Value){if(!$Value){throw ('Music failure control failed at '+(@(Get-PSCallStack)[1].ScriptLineNumber))};$script:count++}
foreach($record in (Get-Content -LiteralPath $InputPath -Raw|ConvertFrom-Json)){
 $safe=MusicFailure $record.text
 AssertControl ($safe.Count -eq 4 -and $safe.music_stage -ceq $record.expected.stage -and $safe.source_basename -ceq 'require.php' -and $safe.source_line -eq $record.expected.source_line)
 AssertControl ($safe.error_type -ceq $record.expected.error_type -and (($safe|ConvertTo-Json) -notmatch 'PRIVATE_'))
 $row=$record.expected;$raw='OPENWEB_MUSIC_FAILURE '+($row|ConvertTo-Json -Compress)
 foreach($prefix in '', 'php.exe : ', 'C:\OpenWebPBX\php\php.exe : '){AssertControl ((MusicFailure ($prefix+$raw)).music_stage -ceq $row.stage)}
 foreach($bad in @(@('schema','1'),@('schema',$true),@('schema',2),@('stage','PRIVATE_PASSWORD'),@('stage','MUSIC_INSTALL'),@('error_type','PrivateException'),@('error_type','RuntimeException PRIVATE_PASSWORD'),@('source_basename','C:/PRIVATE/require.php'),@('source_basename','secret.php'),@('source_line','2'),@('source_line',$true),@('source_line',0),@('source_line',100000))){
  $copy=$row.PSObject.Copy();$copy.($bad[0])=$bad[1];AssertControl ($null -eq (MusicFailure ('OPENWEB_MUSIC_FAILURE '+($copy|ConvertTo-Json -Compress))))
 }
 $copy=$row.PSObject.Copy();$copy|Add-Member password 'PRIVATE_PASSWORD';AssertControl ($null -eq (MusicFailure ('OPENWEB_MUSIC_FAILURE '+($copy|ConvertTo-Json -Compress))))
 foreach($bad in '', 'PRIVATE_PASSWORD',('OPENWEB_MUSIC_FAILURE '+('x'*2049)),($raw+"`n"+$raw),('unknown.exe : '+$raw),('C:\PRIVATE\php.exe : '+$raw),('OPENWEB_MUSIC_FAILURE '+(@($row,$row)|ConvertTo-Json -Compress)),('x'*(4MB+1))){AssertControl ($null -eq (MusicFailure $bad))}
 $musicFailure=$safe;$checkFailure=@{active_case='direct_reapply_complete'}
 $report=@{active_case='direct_reapply_complete';caller_basename='windows-upgrade-acceptance.ps1';caller_line=448;command_basename='php.exe';command_exit=255;source_basename='Upgrade-OpenWebPBX.ps1';source_line=400}
 Invoke-Expression $project[0].Extent.Text
 AssertControl ($report.active_case -ceq 'direct_reapply_complete' -and $report.caller_line -eq 448 -and $report.command_exit -eq 255 -and $report.source_basename -ceq 'require.php' -and $report.music_stage -ceq $row.stage)
 $checkFailure.active_case='manager_reopened';$report=@{active_case='manager_reopened'};Invoke-Expression $project[0].Extent.Text;AssertControl (!$report.ContainsKey('music_stage'))
 $script:musicFailure=$safe;$script:helperFailure=@{error_type='ExpectedFailure'};Check $true 'Expected child failure accepted'
 AssertControl ($null -eq $script:musicFailure -and $null -eq $script:helperFailure)
}
Write-Output ('PASS '+$count+' actual music parser/projection/stale-attribution privacy controls')
''')
    result = subprocess.run([args.powershell,'-NoProfile','-NonInteractive','-File',str(controls),
                             '-SourceRoot',str(root),'-InputPath',str(data)], capture_output=True,text=True)
    assert result.returncode == 0, result.stderr
    print(result.stdout.strip())
print(f'PASS {checks} real PHP helper success/Throwable/stage/rethrow/privacy controls; no PBX/database accessed')
