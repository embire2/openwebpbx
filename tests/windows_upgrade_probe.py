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
    control = work / 'controls.ps1'
    control.write_text(r'''
param([string]$SourceRoot,[string]$Work,[string]$PythonPath)
$ErrorActionPreference='Stop';$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-upgrade-acceptance.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'The actual hook must parse.'}
foreach($name in 'ProbeFailure','Python'){
 $nodes=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true))
 if($nodes.Count -ne 1){throw 'Actual probe functions must be unique.'};Invoke-Expression $nodes[0].Extent.Text
}
$projection=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith('if($probeFailure){')},$true))
if($projection.Count -ne 1){throw 'The actual first-error projection must be unique.'}
$script:count=0
function Check([bool]$Value){if(!$Value){throw 'Upgrade probe control failed.'};$script:count++}
$good=[pscustomobject]@{schema=[long]1;active_case='database_roles';error_type='BackupError';source_basename='backups.py';source_line=[long]291;password='PRIVATE_TOKEN_DO_NOT_PUBLISH';message='PRIVATE_TOKEN_DO_NOT_PUBLISH'}
$safe=ProbeFailure $good
Check ($safe.Count -eq 4 -and $safe.active_case -ceq 'database_roles' -and $safe.source_line -eq 291)
Check (!(($safe|ConvertTo-Json) -match 'PRIVATE_'))
foreach($mutation in @(@('schema','1'),@('schema',$true),@('schema',2),@('active_case','database_roles_PRIVATE_TOKEN'),@('active_case','DATABASE_ROLES'),@('active_case',$true),@('error_type','PRIVATE_TOKEN'),@('error_type','RuntimeError PRIVATE_TOKEN'),@('source_basename','private-secret.py'),@('source_basename','C:/private/backups.py'),@('source_line','291'),@('source_line',$true),@('source_line',0),@('source_line',100000))){
 $copy=$good.PSObject.Copy();$copy.($mutation[0])=$mutation[1];Check ($null -eq (ProbeFailure $copy))
}
$python=$PythonPath;$probe=Join-Path $Work 'private-probe.py';$target=Join-Path $Work 'snapshot.json';$work=$Work
$env:PROBE_FAIL='';$script:probeFailure=$null;$script:probeExit=$null
$emitted=@(Python @($probe,'database',$target));Check ($emitted.Count -eq 0 -and (Test-Path -LiteralPath $target))
Remove-Item -LiteralPath $target
$env:PROBE_FAIL='2'
try{Python @($probe,'database',$target);throw 'The failing probe incorrectly returned.'}catch{
 Check ($_.Exception.Message -ceq 'A private database or restore-gate qualification operation failed.')
 Check ($probeFailure.active_case -ceq 'database_roles' -and $probeFailure.error_type -ceq 'BackupError' -and $probeExit -ne 0)
 $report=[ordered]@{failed_phase='actual direct helper reapply';error_type='RuntimeException';source_basename='windows-upgrade-acceptance.ps1';source_line=23}
 Invoke-Expression $projection[0].Extent.Text
 Check ($report.failed_phase -ceq 'actual direct helper reapply' -and $report.active_case -ceq 'database_roles' -and $report.error_type -ceq 'BackupError')
 Check ($report.source_basename -ceq 'backups.py' -and $report.caller_basename -ceq 'windows-upgrade-acceptance.ps1' -and $report.caller_line -eq 23 -and $report.command_basename -ceq 'private-probe.py' -and $report.command_exit -ne 0)
 Check (!(($report|ConvertTo-Json) -match 'PRIVATE_'))
}
Remove-Item Env:\PROBE_FAIL
Write-Output ('PASS '+$count+' actual AST/filter/wrapper/report controls')
''')
    result = subprocess.run([args.powershell, '-NoProfile', '-NonInteractive', '-File', str(control),
                             '-SourceRoot', str(root), '-Work', str(work), '-PythonPath', sys.executable],
                            check=True, capture_output=True, text=True)
    print(result.stdout.strip())
print(f'PASS {checks} actual embedded-probe stage/privacy/snapshot controls; no installed PBX accessed')
