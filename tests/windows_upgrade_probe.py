#!/usr/bin/env python3
"""Exercise the actual upgrade probe and AST failure filter without an installed PBX."""
import argparse
import ast
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--powershell', default='pwsh')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
source = (root / 'tests/windows-upgrade-acceptance.ps1').read_text()
embedded = source.split("$code=@'\n", 1)[1].split("\n'@", 1)[0]
checks = 0


def check(value):
    global checks
    assert value
    checks += 1


with tempfile.TemporaryDirectory(prefix='openweb-upgrade-probe-') as temporary:
    work = Path(temporary)
    backup = work / 'backups.py'
    backup.write_text('''import json, os
from pathlib import Path
STATE = Path(__file__).parent
class BackupError(Exception): pass
def read_settings():
 if os.environ.get('PROBE_FAIL') == 'settings': raise PermissionError('PRIVATE_TOKEN_DO_NOT_PUBLISH')
 return {'database.0.name':'owned_fixture', 'database.0.password':'PRIVATE_TOKEN_DO_NOT_PUBLISH'}
calls = 0
def query(settings, sql, *, json_result=False):
 global calls
 calls += 1
 if os.environ.get('PROBE_FAIL') == str(calls): raise BackupError('PRIVATE_SQL_PASSWORD_DO_NOT_PUBLISH')
 if calls == 5: return [{'name':'owned_fixture'}]
 return []
''')
    (work / 'installation.json').write_text(json.dumps({'PostgresPassword': 'PRIVATE_TOKEN_DO_NOT_PUBLISH'}))
    # Isolate only the Windows host guard and installed module location. All
    # diagnostics, snapshot SQL selection and HMAC code remain actual source.
    tree = ast.parse(embedded)
    check(isinstance(tree.body[2], ast.If) and "os.name != 'nt'" in ast.unparse(tree.body[2].test))
    del tree.body[2]
    substitutions = 0
    for node in ast.walk(tree):
        if isinstance(node, ast.Constant) and node.value == 'C:/OpenWebPBX/tools/backups.py':
            node.value = str(backup)
            substitutions += 1
    check(substitutions == 1)
    probe = work / 'private-probe.py'
    probe.write_text(ast.unparse(ast.fix_missing_locations(tree)))
    output = work / 'snapshot.json'
    failure = work / 'probe-failure.json'
    stages = ['database_identity', 'database_roles', 'database_memberships', 'database_schema',
              'database_tables', 'database_columns', 'database_values']
    for fail, stage, kind in [('settings', 'probe_settings', 'PermissionError')] + [
            (str(index), stage, 'BackupError') for index, stage in enumerate(stages, 1)]:
        result = subprocess.run([sys.executable, '-I', str(probe), 'database', str(output)],
                                env=os.environ | {'PROBE_FAIL': fail}, capture_output=True)
        check(result.returncode != 0 and not output.exists())
        record = json.loads(failure.read_text())
        check(record['schema'] == 1 and record['active_case'] == stage and record['error_type'] == kind)
        check(record['source_basename'] == 'backups.py' and 0 < record['source_line'] < 100000)
        check(set(record) == {'schema', 'active_case', 'error_type', 'source_basename', 'source_line'})
        check('PRIVATE_' not in failure.read_text() and 'PRIVATE_' in result.stderr.decode())
        failure.unlink()
    result = subprocess.run([sys.executable, '-I', str(probe), 'database', str(output)],
                            env=os.environ | {'PROBE_FAIL': ''}, capture_output=True)
    check(result.returncode == 0 and not failure.exists())
    value = json.loads(output.read_text())
    check(value['table_count'] == 1 and set(value['values']) == {'owned_fixture'})
    check('PRIVATE_' not in output.read_text() and result.stdout == b'')
    output.unlink()
    (work / 'installation.json').write_text('{}')
    result = subprocess.run([sys.executable, '-I', str(probe), 'database', str(output)], capture_output=True)
    record = json.loads(failure.read_text())
    check(result.returncode != 0 and record['active_case'] == 'database_installation' and record['error_type'] == 'KeyError')
    check(record['source_basename'] == 'private-probe.py' and 'PostgresPassword' not in failure.read_text())
    failure.unlink()
    (work / 'installation.json').write_text(json.dumps({'PostgresPassword': 'PRIVATE_TOKEN_DO_NOT_PUBLISH'}))

    # Load the actual PowerShell functions plus the exact report projection.
    control = work / 'windows-upgrade-acceptance.ps1'
    control.write_text(r'''
param([string]$SourceRoot,[string]$Work,[string]$PythonPath)
$ErrorActionPreference='Stop';$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-upgrade-acceptance.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The actual hook must parse.'}
foreach($name in 'ProbeFailure','Python','Check','HelperFailure','HelperLauncher'){
 $nodes=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true))
 if($nodes.Count -ne 1){throw 'Actual probe functions must be unique.'};Invoke-Expression $nodes[0].Extent.Text
}
$projection=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith('if($probeFailure){')},$true))
if($projection.Count -ne 1){throw 'The actual first-error projection must be unique.'}
$checkProjection=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith('if($checkFailure){')},$true))
if($checkProjection.Count -ne 1){throw 'The actual assertion projection must be unique.'}
$helperProjection=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith('if($helperFailure -and $checkFailure){')},$true))
if($helperProjection.Count -ne 1){throw 'The actual child projection must be unique.'}
$script:count=0
function AssertControl([bool]$Value){if(!$Value){throw ('Upgrade probe control failed at line '+(@(Get-PSCallStack)[1].ScriptLineNumber)+', control '+($script:count+1))};$script:count++}
$good=[pscustomobject]@{schema=[long]1;active_case='database_roles';error_type='BackupError';source_basename='backups.py';source_line=[long]291;password='PRIVATE_TOKEN_DO_NOT_PUBLISH';message='PRIVATE_TOKEN_DO_NOT_PUBLISH'}
$safe=ProbeFailure $good
AssertControl ($safe.Count -eq 4 -and $safe.active_case -ceq 'database_roles' -and $safe.source_line -eq 291)
AssertControl (!(($safe|ConvertTo-Json) -match 'PRIVATE_'))
foreach($mutation in @(@('schema','1'),@('schema',$true),@('schema',2),@('active_case','database_roles_PRIVATE_TOKEN'),@('active_case','DATABASE_ROLES'),@('active_case',$true),@('error_type','PRIVATE_TOKEN'),@('error_type','RuntimeError PRIVATE_TOKEN'),@('source_basename','private-secret.py'),@('source_basename','C:/private/backups.py'),@('source_line','291'),@('source_line',$true),@('source_line',0),@('source_line',100000))){
 $copy=$good.PSObject.Copy();$copy.($mutation[0])=$mutation[1];AssertControl ($null -eq (ProbeFailure $copy))
}
$python=$PythonPath;$probe=Join-Path $Work 'private-probe.py';$target=Join-Path $Work 'snapshot.json';$work=$Work
$env:PROBE_FAIL='';$script:probeFailure=$null;$script:probeExit=$null
$emitted=@(Python @($probe,'database',$target));AssertControl ($emitted.Count -eq 0 -and (Test-Path -LiteralPath $target))
Remove-Item -LiteralPath $target
$env:PROBE_FAIL='2'
try{Python @($probe,'database',$target);throw 'The failing probe incorrectly returned.'}catch{
 AssertControl ($_.Exception.Message -ceq 'A private database or restore-gate qualification operation failed.')
 AssertControl ($probeFailure.active_case -ceq 'database_roles' -and $probeFailure.error_type -ceq 'BackupError' -and $probeExit -ne 0)
 $report=[ordered]@{failed_phase='actual direct helper reapply';error_type='RuntimeException';source_basename='windows-upgrade-acceptance.ps1';source_line=23}
 Invoke-Expression $projection[0].Extent.Text
 AssertControl ($report.failed_phase -ceq 'actual direct helper reapply' -and $report.active_case -ceq 'database_roles' -and $report.error_type -ceq 'BackupError')
 AssertControl ($report.source_basename -ceq 'backups.py' -and $report.caller_basename -ceq 'windows-upgrade-acceptance.ps1' -and $report.caller_line -eq 23 -and $report.command_basename -ceq 'private-probe.py' -and $report.command_exit -ne 0)
 AssertControl (!(($report|ConvertTo-Json) -match 'PRIVATE_'))
}
Remove-Item Env:\PROBE_FAIL
$script:checkFailure=$null;Check $true 'PRIVATE_TOKEN_DO_NOT_PUBLISH'
AssertControl ($null -eq $checkFailure)
foreach($case in @(
 @('The installed helper bytes did not pass native preflight.','direct_reapply_preflight'),
 @('The direct same-version helper reapply did not complete.','direct_reapply_complete'),
 @('Direct reapply changed preserved database/security/routing data.','direct_reapply_database_preserved'),
 @('Direct reapply changed protected credentials, keys, TLS or notification bytes/ACLs.','direct_reapply_private_files_preserved'),
 @('PRIVATE_TOKEN_DO_NOT_PUBLISH','qualification_assertion'))){
 $script:checkFailure=$null
 try{Check $false $case[0];throw 'A failed assertion incorrectly returned.'}catch{
  AssertControl ($_.Exception.Message -ceq $case[0])
  AssertControl ($checkFailure.active_case -ceq $case[1] -and $checkFailure.source_basename -ceq 'windows-upgrade-acceptance.ps1')
  AssertControl ($checkFailure.source_line -gt 0 -and ([IO.File]::ReadAllLines($PSCommandPath)[$checkFailure.source_line-1]).Contains('Check $false'))
  $report=[ordered]@{failed_phase='actual direct helper reapply';error_type='System.Management.Automation.RuntimeException';source_basename='windows-upgrade-acceptance.ps1';source_line=23}
  Invoke-Expression $checkProjection[0].Extent.Text
  AssertControl ($report.caller_line -eq 23 -and $report.source_line -eq $checkFailure.source_line -and $report.active_case -ceq $case[1])
  AssertControl ($report.failed_phase -ceq 'actual direct helper reapply' -and !(($report|ConvertTo-Json) -match 'PRIVATE_TOKEN_DO_NOT_PUBLISH'))
 }
}
$helperRecord=[pscustomobject]@{error_type='System.InvalidOperationException';source_basename='Upgrade-OpenWebPBX.ps1';source_line=[long]90;caller_basename='Upgrade-OpenWebPBX.ps1';caller_line=[long]400;command_basename='php.exe';command_exit=[long]74;password='PRIVATE_TOKEN_DO_NOT_PUBLISH'}
$helperFailure=HelperFailure $helperRecord
AssertControl ($helperFailure.Count -eq 7 -and !(($helperFailure|ConvertTo-Json) -match 'PRIVATE_TOKEN_DO_NOT_PUBLISH'))
foreach($bad in @(@('error_type','PRIVATE_TOKEN_DO_NOT_PUBLISH'),@('source_basename','private-secret.ps1'),@('source_line','90'),@('source_line',$true),@('source_line',0),@('source_line',100000),@('caller_basename','C:/private/Upgrade-OpenWebPBX.ps1'),@('caller_line','400'),@('caller_line',$true),@('caller_line',100000),@('command_basename','unknown-secret.exe'),@('command_exit','74'),@('command_exit',$true))){
 $copy=$helperRecord.PSObject.Copy();$copy.($bad[0])=$bad[1];$filtered=HelperFailure $copy
 AssertControl (!$filtered.ContainsKey($bad[0]))
}
$helperFailure=HelperFailure $helperRecord
Invoke-Expression $helperProjection[0].Extent.Text
AssertControl ($report.active_case -ceq 'qualification_assertion' -and $report.caller_line -eq $checkFailure.source_line)
AssertControl ($report.source_basename -ceq 'Upgrade-OpenWebPBX.ps1' -and $report.source_line -eq 400 -and $report.command_basename -ceq 'php.exe' -and $report.command_exit -eq 74 -and $report.error_type -ceq 'System.InvalidOperationException')
AssertControl (!(($report|ConvertTo-Json) -match 'PRIVATE_TOKEN_DO_NOT_PUBLISH'))
$helperRecord.PSObject.Properties.Remove('caller_basename');$helperRecord.PSObject.Properties.Remove('caller_line')
$helperFailure=HelperFailure $helperRecord;Invoke-Expression $helperProjection[0].Extent.Text
AssertControl ($report.source_line -eq 90 -and $report.caller_line -eq $checkFailure.source_line)
$script:helperFailure=HelperFailure $helperRecord
Check $true 'The verified signed failure did not finish exact rollback.'
AssertControl ($null -eq $helperFailure)
try{Check $false 'The helper did not automatically reopen a responsive installed desktop in its original owner/session.';throw 'Manager assertion returned.'}catch{
 $report=[ordered]@{failed_phase='actual direct post-deploy rollback';error_type='System.Management.Automation.RuntimeException';source_basename='windows-upgrade-acceptance.ps1';source_line=23}
 Invoke-Expression $checkProjection[0].Extent.Text
 Invoke-Expression $helperProjection[0].Extent.Text
 AssertControl ($report.active_case -ceq 'manager_reopened' -and $report.source_basename -ceq 'windows-upgrade-acceptance.ps1' -and $report.source_line -eq $checkFailure.source_line)
 AssertControl (!$report.Contains('command_basename') -and $report.error_type -ceq 'System.Management.Automation.RuntimeException')
}
Write-Output ('PASS '+$count+' actual AST/filter/wrapper/report controls')
''')
    result = subprocess.run([args.powershell, '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', str(control),
                             '-SourceRoot', str(root), '-Work', str(work), '-PythonPath', sys.executable],
                            check=True, capture_output=True, text=True)
    print(result.stdout.strip())
    helper_directory = work / "original helper's path"
    helper_directory.mkdir()
    helper = helper_directory / 'Upgrade-OpenWebPBX.ps1'
    helper.write_text(r'''
param([switch]$Check,[switch]$Recover,[switch]$Automatic,[string]$Archive,[string]$FeedEnvelope,[string]$TargetVersion,[string]$CertificateThumbprint,[string]$RestoreBackup)
[IO.File]::WriteAllText($env:UPGRADE_PROBE_OBSERVATION,(@{root=$PSScriptRoot;path=$PSCommandPath;check=[bool]$Check;recover=[bool]$Recover;automatic=[bool]$Automatic;archive=$Archive;feed=$FeedEnvelope;version=$TargetVersion;certificate=$CertificateThumbprint;restore=$RestoreBackup}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
if($env:UPGRADE_PROBE_MODE -eq 'throw'){
 $failure=[InvalidOperationException]::new('PRIVATE_TOKEN_DO_NOT_PUBLISH')
 $failure.Data['command_basename']='php.exe';$failure.Data['command_exit']=74
 $failure.Data['caller_basename']='Upgrade-OpenWebPBX.ps1';$failure.Data['caller_line']=400
 $failure.Data['password']='PRIVATE_TOKEN_DO_NOT_PUBLISH'
 throw $failure
}
if($env:UPGRADE_PROBE_MODE -eq 'exit75'){exit 75}
if($env:UPGRADE_PROBE_MODE -eq 'exit2'){exit 2}
if($env:OS -eq 'Windows_NT'){& "$env:SystemRoot\System32\cmd.exe" /d /c 'exit 19'}else{& /bin/sh -c 'exit 19'}
[IO.File]::WriteAllText(($env:UPGRADE_PROBE_OBSERVATION+'.native'),[string]$LASTEXITCODE)
Write-Output 'fixture helper completed'
''')
    argument_value = "literal quote' __CALL__ __FAILURE__ $(not-a-command);"
    cases = [([], 'success', 0), (['-Check'], 'success', 0),
             (['-Recover'], 'exit75', 75),
             (['-Recover'], 'exit2', 2),
             (['-Archive', argument_value], 'exit75', 75),
             (['-Archive', argument_value], 'exit2', 2),
             (['-Archive', argument_value, '-FeedEnvelope', argument_value, '-TargetVersion', '1.0.14', '-Check'], 'success', 0),
             (['-CertificateThumbprint', argument_value], 'success', 0),
             ([], 'throw', 1)]
    inputs = []
    for index, (arguments, mode, code) in enumerate(cases):
        inputs.append({'path': str(helper), 'arguments': arguments,
                       'failure': str(work / f'helper-{index}-failure.json'),
                       'launcher': str(work / f'helper-{index}-launcher.ps1')})
    launcher_input = work / 'launchers.json'
    launcher_input.write_text(json.dumps(inputs))
    generator = work / 'generate.ps1'
    generator.write_text(r'''
param([string]$SourceRoot,[string]$InputPath)
$ErrorActionPreference='Stop';$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-upgrade-acceptance.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The actual helper launcher must parse.'}
foreach($name in 'HelperFailure','HelperLauncher'){
 $nodes=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true))
 if($nodes.Count -ne 1){throw 'Actual launcher functions must be unique.'};Invoke-Expression $nodes[0].Extent.Text
}
foreach($record in (Get-Content -LiteralPath $InputPath -Raw|ConvertFrom-Json)){
 [IO.File]::WriteAllText($record.launcher,(HelperLauncher $record.path @($record.arguments) $record.failure),[Text.UTF8Encoding]::new($false))
}
''')
    subprocess.run([args.powershell, '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', str(generator),
                    '-SourceRoot', str(root), '-InputPath', str(launcher_input)], check=True, capture_output=True)
    for index, (arguments, mode, code) in enumerate(cases):
        observation = work / f'helper-{index}-observation.json'
        result = subprocess.run([args.powershell, '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', inputs[index]['launcher']],
                                env=os.environ | {'UPGRADE_PROBE_MODE': mode, 'UPGRADE_PROBE_OBSERVATION': str(observation)},
                                capture_output=True)
        check(result.returncode == code)
        actual = json.loads(observation.read_text(encoding='utf-8-sig'))
        check(actual['root'] == str(helper_directory) and actual['path'] == str(helper))
        check(actual['check'] == ('-Check' in arguments) and actual['recover'] == ('-Recover' in arguments))
        for flag, field in [('-Archive', 'archive'), ('-FeedEnvelope', 'feed'), ('-TargetVersion', 'version'), ('-CertificateThumbprint', 'certificate')]:
            check(actual[field] == (arguments[arguments.index(flag) + 1] if flag in arguments else ''))
        failure = Path(inputs[index]['failure'])
        if mode == 'throw':
            record = json.loads(failure.read_text(encoding='utf-8-sig'))
            check(record['error_type'] == 'System.InvalidOperationException')
            check(record['source_basename'] == helper.name and 0 < record['source_line'] < 100000)
            check(record['command_basename'] == 'php.exe' and record['command_exit'] == 74)
            check(record['caller_basename'] == helper.name and record['caller_line'] == 400)
            check('PRIVATE_TOKEN_DO_NOT_PUBLISH' not in failure.read_text() and 'PRIVATE_TOKEN_DO_NOT_PUBLISH' in result.stderr.decode())
        else:
            check(not failure.exists())
            if mode == 'success':
                check(Path(str(observation) + '.native').read_text() == '19')
print(f'PASS {checks} actual embedded-probe/helper-launcher stage/privacy/snapshot controls; no installed PBX accessed')
