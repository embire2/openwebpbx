#!/usr/bin/env python3
"""Real exact-JSON children, actual snapshot producer and AST privacy controls."""
import argparse
import ast
import copy
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--powershell', default='pwsh')
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
helper = root / 'tests/windows-compare-json.py'
checks = 0


def check(value):
    global checks
    assert value
    checks += 1


def run(*paths):
    result = subprocess.run([sys.executable, '-I', '-B', str(helper), *map(str, paths)],
                            capture_output=True, text=True)
    check(not result.stderr and 'PRIVATE_' not in result.stdout)
    record = json.loads(result.stdout)
    check(record['schema'] == 1 and record['producer'] == 'windows-exact-json-comparison')
    check(result.returncode == {'equal': 0, 'different': 1, 'error': 2}[record['comparison_result']])
    return result.returncode, record


with tempfile.TemporaryDirectory(prefix="openweb exact Ω's ") as temporary:
    work = Path(temporary)
    left, right = work / "before Ω's snapshot.json", work / 'after space.json'
    records = []
    pairs = [
        ({'private-path': 'PRIVATE_VALUE_Ω', 'a': [1, None]}, {'a': [1, None], 'private-path': 'PRIVATE_VALUE_Ω'}),
        ({'x': True}, {'x': 1}), ({'x': 1}, {'x': 1.0}),
        ({'x': None}, {}), ([1, 2], [2, 1]), (None, None), ([], {}),
        ({'identity': 'PRIVATE_OLD', 'values': {'v_vars': 'PRIVATE_OLD', 'PRIVATE_TABLE': 'PRIVATE_OLD'}},
         {'identity': 'PRIVATE_NEW', 'values': {'v_vars': 'PRIVATE_NEW', 'PRIVATE_TABLE': 'PRIVATE_NEW'}}),
        ({'PRIVATE_PATH': None}, {'PRIVATE_OTHER_PATH': None}),
        ({'values': {'v_vars': None}}, {'values': {}}),
    ]
    for before, after in pairs:
        left.write_text(json.dumps(before, ensure_ascii=False), encoding='utf-8-sig')
        right.write_text(json.dumps(after, ensure_ascii=False), encoding='utf-8')
        before_bytes, after_bytes = left.read_bytes(), right.read_bytes()
        code, row = run(left, right)
        check(code == (0 if before == after else 1))
        check(left.read_bytes() == before_bytes and right.read_bytes() == after_bytes)
        records.append(row)
    mismatch = records[7]
    check(mismatch['comparison_changed_sections'] == ['identity', 'values'])
    check(mismatch['comparison_changed_values_table_count'] == 2)
    check(mismatch['comparison_critical_tables'] == ['v_vars'] and mismatch['comparison_other_table_count'] == 1)
    check(records[8]['comparison_unknown_section_count'] == 2)
    check(records[9]['comparison_changed_values_table_count'] == 1)
    for invalid, stage in ((b'{"PRIVATE_BAD":', 'parse_before'), (b'\xff', 'parse_before')):
        left.write_bytes(invalid)
        code, row = run(left, right)
        check(code == 2 and row['comparison_stage'] == stage)
        records.append(row)
    left.write_text('{}');right.write_text('PRIVATE_INVALID')
    code, row = run(left, right)
    check(code == 2 and row['comparison_stage'] == 'parse_after')
    records.append(row)
    for paths, stage in (((work / 'PRIVATE_MISSING', right), 'read_before'),
                         ((left, work / 'PRIVATE_MISSING'), 'read_after'), ((), 'usage'), ((left,), 'usage')):
        code, row = run(*paths)
        check(code == 2 and row['comparison_stage'] == stage)
        records.append(row)

    # Execute the exact embedded snapshot producer, changing only its Windows
    # guard and installed dependency location. The old/new SQL and protected
    # snapshot bytes must be identical with the same private audit key.
    source = (root / 'tests/windows-upgrade-acceptance.ps1').read_text()
    # Immutable pre-diagnostic source, rather than a moving HEAD which would
    # silently turn the preservation regression into a self-comparison.
    baseline = 'f2b7b6f34c1db4d00759d962013bb5609637c14e'
    old = subprocess.run(['git', 'show', baseline + ':tests/windows-upgrade-acceptance.ps1'],
                         cwd=root, capture_output=True, text=True, check=True).stdout
    backup = work / 'backups.py'
    backup.write_text('''import json,os
from pathlib import Path
STATE=Path(__file__).parent
def read_settings(): return {'database.0.name':'PRIVATE_DB'}
def query(settings,sql,*,json_result=False):
 with (STATE/'sql.private').open('a') as stream:stream.write(sql+'\\n')
 if 'c.relname name' in sql:return [{'name':'v_vars'},{'name':'PRIVATE_TABLE'}]
 if 'information_schema.columns' in sql:return [{'table_name':'v_vars','column_name':'update_date'},{'table_name':'v_vars','column_name':'var_value'},{'table_name':'PRIVATE_TABLE','column_name':'PRIVATE_COLUMN'}]
 if 'from "v_vars" t' in sql:
  rows=[{'update_date':os.environ.get('JSON_COMPARE_DATE','PRIVATE_OLD'),'var_value':'PRIVATE_SIP_PASSWORD'},{'update_date':os.environ.get('JSON_COMPARE_DATE','PRIVATE_OLD'),'var_value':'PRIVATE_SECOND_PASSWORD'}]
  return rows[::-1] if os.environ.get('JSON_COMPARE_REVERSE')=='true' else rows
 if 'from "PRIVATE_TABLE" t' in sql:return [{'PRIVATE_COLUMN':'PRIVATE_COLUMN_VALUE'}]
 return []
''')
    (work / 'installation.json').write_text(json.dumps({'PostgresPassword': 'PRIVATE_PASSWORD'}))
    (work / 'audit.key').write_bytes(bytes(range(32)))

    def snapshot(text, name, changed=False, reverse=False):
        embedded = text.split("$code=@'\n", 1)[1].split("\n'@", 1)[0]
        tree = ast.parse(embedded)
        check(isinstance(tree.body[2], ast.If) and "os.name != 'nt'" in ast.unparse(tree.body[2].test))
        del tree.body[2]
        substitutions = 0
        for node in ast.walk(tree):
            if isinstance(node, ast.Constant) and node.value == 'C:/OpenWebPBX/tools/backups.py':
                node.value = str(backup);substitutions += 1
        check(substitutions == 1)
        probe = work / 'private-probe.py'
        probe.write_text(ast.unparse(ast.fix_missing_locations(tree)))
        output = work / name
        (work / 'sql.private').unlink(missing_ok=True)
        result = subprocess.run([sys.executable, '-I', '-B', str(probe), 'database', str(output)],
                                capture_output=True, env=os.environ | {'JSON_COMPARE_DATE': 'PRIVATE_NEW' if changed else 'PRIVATE_OLD', 'JSON_COMPARE_REVERSE': 'true' if reverse else 'false'})
        check(result.returncode == 0 and not result.stdout and not result.stderr)
        return output, (work / 'sql.private').read_bytes()

    old_path, old_sql = snapshot(old, 'old.json')
    new_path, new_sql = snapshot(source, 'new.json')
    check(old_path.read_bytes() == new_path.read_bytes() and old_sql == new_sql)
    before_sidecar = Path(str(new_path) + '.columns-private.json')
    check(before_sidecar.exists() and 'PRIVATE_SIP_PASSWORD' not in before_sidecar.read_text())
    reverse_path, reverse_sql = snapshot(source, 'reverse.json', reverse=True)
    check(reverse_sql == old_sql and reverse_path.read_bytes() != new_path.read_bytes())
    check(Path(str(reverse_path) + '.columns-private.json').read_bytes() == before_sidecar.read_bytes())
    changed_path, changed_sql = snapshot(source, 'changed.json', True)
    check(changed_sql == old_sql)
    after_sidecar = Path(str(changed_path) + '.columns-private.json')
    code, row = run(new_path, changed_path, before_sidecar, after_sidecar)
    check(code == 1 and row['comparison_columns_observed'])
    check(row['comparison_changed_column_count'] == 1 and row['comparison_critical_columns'] == ['v_vars.update_date'])
    check(row['comparison_other_column_count'] == 0)
    records.append(row)
    expected = json.loads(new_path.read_text()) == json.loads(changed_path.read_text())
    for sidecar in (work / 'PRIVATE_MISSING', work / 'bad-sidecar.json'):
        sidecar.write_text('PRIVATE_BAD') if sidecar.name == 'bad-sidecar.json' else None
        code, row = run(new_path, changed_path, sidecar, after_sidecar)
        check(code == int(not expected) and not row['comparison_columns_observed'])
    code, row = run(new_path, new_path, work / 'PRIVATE_MISSING', work / 'PRIVATE_MISSING')
    check(code == 0 and set(row) == {'schema', 'producer', 'comparison_result', 'comparison_stage'})
    # A multiset HMAC deliberately ignores row ordering only in the auxiliary
    # evidence; the protected original table-row digest remains unchanged.
    check('sorted(json.dumps(row[name]' in source)
    side = json.loads(before_sidecar.read_text())
    for columns in side['tables'].values():
        check(all(len(value) == 64 and set(value) <= set('0123456789abcdef') for value in columns.values()))
    # Real FilesSnapshot-shaped JSON retains exact bytes/equality while the
    # public report carries only field/category counts, never path fragments.
    base_files = {
        r'C:\OpenWebPBX\web\PRIVATE_USER\file.php':
            {'acl': 'PRIVATE_ACL_OLD', 'sha256': '0' * 64, 'bytes': 10, 'directory': False},
        r'C:\OpenWebPBX\server\PRIVATE.dll':
            {'acl': 'PRIVATE_ACL_OLD', 'sha256': '1' * 64, 'bytes': 20, 'directory': False},
    }
    web_path = next(iter(base_files))

    def file_case(before, after, fields, categories):
        left.write_text(json.dumps(before), encoding='utf-8-sig')
        right.write_text(json.dumps(after), encoding='utf-8')
        original = (left.read_bytes(), right.read_bytes())
        code, record = run(left, right)
        check(code == 1 and record['comparison_files_observed'] is True)
        check(record['comparison_file_field_counts'] == fields)
        check(record['comparison_file_category_counts'] == categories)
        check(record['comparison_changed_file_entry_count'] == sum(categories.values()))
        check(record['comparison_file_counts_capped'] is False)
        check((left.read_bytes(), right.read_bytes()) == original)
        check('0' * 64 not in json.dumps(record) and '1' * 64 not in json.dumps(record))
        records.append(record)

    for field, value in [('acl', 'PRIVATE_ACL_NEW'), ('sha256', '2' * 64),
                         ('bytes', 11), ('directory', True)]:
        changed_files = copy.deepcopy(base_files);changed_files[web_path][field] = value
        file_case(base_files, changed_files, {field: 1}, {'web': 1})
    added_files = copy.deepcopy(base_files)
    added_files[r'C:\OpenWebPBX\tools\PRIVATE_NEW.py'] = copy.deepcopy(base_files[web_path])
    file_case(base_files, added_files, {'added': 1}, {'tools': 1})
    file_case(added_files, base_files, {'removed': 1}, {'tools': 1})
    changed_files = copy.deepcopy(base_files);changed_files[web_path] = 'PRIVATE_NONOBJECT'
    file_case(base_files, changed_files, {'shape': 1}, {'web': 1})
    changed_files = copy.deepcopy(base_files);changed_files[web_path]['PRIVATE_FIELD'] = 'PRIVATE_VALUE'
    file_case(base_files, changed_files, {'other': 1}, {'web': 1})
    categories = {
        'web': r'C:\OpenWebPBX\web\PRIVATE_MORE.php',
        'server': r'C:\OpenWebPBX\server\PRIVATE_MORE.dll',
        'desktop': r'C:\OpenWebPBX\desktop\PRIVATE_MORE.dll',
        'tools': r'C:\OpenWebPBX\tools\PRIVATE_MORE.ps1',
        'updater': r'C:\OpenWebPBX\updater\PRIVATE_MORE.dll',
        'config': r'C:\ProgramData\fusionpbx\PRIVATE_MORE.conf',
        'notifications': r'C:\ProgramData\OpenWebPBX\mobile-notifications\PRIVATE_MORE.json',
        'media': r'C:\ProgramData\OpenWebPBX\storage\PRIVATE_USER\PRIVATE_MORE.wav',
        'native': r'C:\Program Files\FreeSWITCH\conf\PRIVATE_MORE.xml',
        'backup_runtime': r'C:\OpenWebPBX\backup-runtime\PRIVATE_MORE.pyc',
        'acme_runtime': r'C:\OpenWebPBX\acme\PRIVATE_MORE.dll',
        'other': r'C:\PRIVATE_ROOT\PRIVATE_USER\PRIVATE_MORE',
    }
    for category, private_path in categories.items():
        before_files = copy.deepcopy(base_files);before_files[private_path] = copy.deepcopy(base_files[web_path])
        after_files = copy.deepcopy(before_files);after_files[private_path]['acl'] = 'PRIVATE_ACL_NEW'
        file_case(before_files, after_files, {'acl': 1}, {category: 1})
    # Exercise the actual cap branch on three genuine entries with a bounded
    # control limit, without constructing hundreds of thousands of files.
    namespace = {'__name__': 'exact_file_comparison_controls'}
    exec(compile(helper.read_text(), str(helper), 'exec'), namespace)
    namespace['LIMIT'] = 2
    before_files = {r'C:\OpenWebPBX\web\PRIVATE_' + str(i): copy.deepcopy(base_files[web_path]) for i in range(3)}
    after_files = copy.deepcopy(before_files)
    for entry in after_files.values():entry['acl'] = 'PRIVATE_CHANGED'
    capped = namespace['file_difference'](before_files, after_files, namespace['changed_keys'](before_files, after_files))
    check(capped['comparison_changed_file_entry_count'] == 2 and capped['comparison_file_counts_capped'] is True)
    check(capped['comparison_file_field_counts'] == {'acl': 2} and capped['comparison_file_category_counts'] == {'web': 2})
    namespace['file_category'] = lambda value: (_ for _ in ()).throw(ValueError('PRIVATE_DIAGNOSTIC_FAILURE'))
    unavailable = namespace['difference'](before_files, after_files)
    check(unavailable['comparison_unknown_section_count'] == 2 and 'comparison_files_observed' not in unavailable)
    check('comparison_files_observed' not in records[7])
    records_path = work / 'records.json'
    records_path.write_text(json.dumps(records))
    stubs = []
    for output in ('PRIVATE_SENTINEL', json.dumps({'schema': 1, 'producer': 'PRIVATE_PRODUCER'}),
                   json.dumps({'schema': 1, 'producer': 'windows-exact-json-comparison',
                               'comparison_result': 'equal', 'comparison_stage': 'compare', 'private': 'PRIVATE_PASSWORD'}),
                   json.dumps(records[7])):
        stubs.append({'source': 'print(' + repr(output) + ')', 'result': 'unavailable', 'stage': 'report_validation', 'exit': 0})
    for side, mode in ((1, 'missing'), (1, 'invalid'), (2, 'invalid')):
        action = f'Path(sys.argv[{side}]).unlink()' if mode == 'missing' else f'Path(sys.argv[{side}]).write_bytes(b"PRIVATE_INVALID_JSON")'
        stubs.append({'source': 'import runpy,sys\nfrom pathlib import Path\n' + action + '\nrunpy.run_path(' + repr(str(helper)) + ',run_name="__main__")',
                      'result': 'error', 'stage': ('read_' if mode == 'missing' else 'parse_') + ('before' if side == 1 else 'after'), 'exit': 2})
    (work / 'stub-cases.json').write_text(json.dumps(stubs))
    shutil.copyfile(helper, work / helper.name)
    control = work / 'windows-upgrade-acceptance.ps1'
    control.write_text(r'''
param([string]$SourceRoot,[string]$Work,[string]$PythonPath,[string]$RecordsPath)
$ErrorActionPreference='Stop';$t=$null;$e=$null
$source=Join-Path $SourceRoot 'tests/windows-upgrade-acceptance.ps1'
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$t,[ref]$e)
if($e.Count){throw 'The actual upgrade hook must parse.'}
$functions=@()
foreach($name in 'ComparisonFields','Check','WriteJson','Equal','DatabaseSnapshot'){
 $nodes=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name},$true))
 if($nodes.Count -ne 1){throw 'The actual comparison functions must be unique.'};$functions+=$nodes[0].Extent.Text
}
$functionsDirectory=Join-Path $Work 'exact-function-source';[void](New-Item -ItemType Directory -Path $functionsDirectory)
$functionsPath=Join-Path $functionsDirectory 'windows-upgrade-acceptance.ps1';[IO.File]::WriteAllText($functionsPath,($functions -join "`n"),[Text.UTF8Encoding]::new($false));Copy-Item -LiteralPath (Join-Path $Work 'windows-compare-json.py') -Destination $functionsDirectory;. $functionsPath
$project=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.IfStatementAst] -and $n.Extent.Text.StartsWith('if($comparisonFailure -and $checkFailure){')},$true))
if($project.Count -ne 1){throw 'The actual comparison projection must be unique.'}
$suite=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/windows-suite.ps1'),[ref]$t,[ref]$e)
if($e.Count){throw 'The actual caller must parse.'}
foreach($node in $suite.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -like 'Safe*'},$true)){Invoke-Expression $node.Extent.Text}
$count=0
function AssertControl([bool]$Value){if(!$Value){throw ('Exact JSON control failed at '+(@(Get-PSCallStack)[1].ScriptLineNumber))};$script:count++}
AssertControl (${function:ComparisonFields}.ToString() -ceq ${function:SafeComparisonFields}.ToString())
foreach($record in (Get-Content -LiteralPath $RecordsPath -Raw|ConvertFrom-Json)){
 $filtered=ComparisonFields $record
 AssertControl ($null -ne $filtered -and $filtered.comparison_result -ceq $record.comparison_result)
 AssertControl (@($record.PSObject.Properties).Count -eq ($filtered.Count+2))
 $report=[ordered]@{active_case='direct_reapply_database_preserved';source_basename='windows-upgrade-acceptance.ps1';source_line=291;command_basename='windows-compare-json.py';command_exit=@{equal=0;different=1;error=2}[$record.comparison_result]}
 foreach($entry in $filtered.GetEnumerator()){$report[$entry.Key]=$entry.Value}
 $safe=SafeFailureFields ([pscustomobject]$report)
 AssertControl ($safe.comparison_result -ceq $record.comparison_result -and $safe.source_line -eq 291 -and $safe.active_case -ceq 'direct_reapply_database_preserved')
 AssertControl (($safe|ConvertTo-Json -Depth 10) -notmatch 'PRIVATE_|audit.key|HMAC|[a-f0-9]{64}')
 $report.command_basename='other.py';AssertControl (!(SafeFailureFields ([pscustomobject]$report)).ContainsKey('comparison_result'))
 $copy=$record.PSObject.Copy();$copy|Add-Member raw_private 'PRIVATE_PASSWORD';AssertControl (((ComparisonFields $copy)|ConvertTo-Json -Depth 10) -notmatch 'PRIVATE_')
 foreach($bad in @(@('comparison_result','PRIVATE_PASSWORD'),@('comparison_result',$true),@('comparison_stage','PRIVATE_PATH'),@('comparison_stage',42))){$copy=$record.PSObject.Copy();$copy.($bad[0])=$bad[1];AssertControl ($null -eq (ComparisonFields $copy))}
 if($record.comparison_result -ceq 'different'){
  foreach($field in 'comparison_changed_sections','comparison_critical_tables','comparison_critical_columns'){
   foreach($bad in 'PRIVATE_SECRET',@('PRIVATE_SECRET'),@('values','PRIVATE_SECRET'),$true,42){$copy=$record.PSObject.Copy();$copy.$field=$bad;AssertControl ($null -eq (ComparisonFields $copy))}
   if($record.$field.Count){$copy=$record.PSObject.Copy();$copy.$field=@($record.$field[0],$record.$field[0]);AssertControl ($null -eq (ComparisonFields $copy))}
  }
  foreach($field in 'comparison_unknown_section_count','comparison_changed_values_table_count','comparison_other_table_count','comparison_changed_column_count','comparison_other_column_count'){
   foreach($bad in '1',$true,-1,100001,1.5,[double]::NaN,[double]::PositiveInfinity){$copy=$record.PSObject.Copy();$copy.$field=$bad;AssertControl ($null -eq (ComparisonFields $copy))}
  }
  foreach($field in 'comparison_values_observed','comparison_counts_capped','comparison_columns_observed','comparison_column_counts_capped'){
   foreach($bad in 'true',1,$null){$copy=$record.PSObject.Copy();$copy.$field=$bad;AssertControl ($null -eq (ComparisonFields $copy))}
  }
  if(@($record.PSObject.Properties.Name) -ccontains 'comparison_files_observed'){
   foreach($field in 'comparison_files_observed','comparison_file_counts_capped'){
    foreach($bad in 'true',1,$null){$copy=$record.PSObject.Copy();$copy.$field=$bad;AssertControl ($null -eq (ComparisonFields $copy))}
   }
   foreach($bad in '1',$true,-1,100001,1.5,[double]::NaN,[double]::PositiveInfinity){$copy=$record.PSObject.Copy();$copy.comparison_changed_file_entry_count=$bad;AssertControl ($null -eq (ComparisonFields $copy))}
   foreach($field in 'comparison_files_observed','comparison_changed_file_entry_count','comparison_file_counts_capped','comparison_file_field_counts','comparison_file_category_counts','comparison_file_category_field_counts','comparison_known_file_field_counts','comparison_unknown_file_entry_count','comparison_config_scope_field_counts','comparison_file_category_added_kind_counts'){
    $copy=$record.PSObject.Copy();$copy.PSObject.Properties.Remove($field);AssertControl ($null -eq (ComparisonFields $copy))
   }
   foreach($field in 'comparison_file_field_counts','comparison_file_category_counts'){
    $validKey=if($field -ceq 'comparison_file_field_counts'){'acl'}else{'web'}
    foreach($bad in 'PRIVATE_SDDL',@('acl'),$true,42,$null){$copy=$record.PSObject.Copy();$copy.$field=$bad;AssertControl ($null -eq (ComparisonFields $copy))}
    foreach($bad in '1',$true,-1,100001,1.5,[double]::NaN,[double]::PositiveInfinity){$copy=$record.PSObject.Copy();$copy.$field=[pscustomobject]@{};$copy.$field|Add-Member -NotePropertyName $validKey -NotePropertyValue $bad;AssertControl ($null -eq (ComparisonFields $copy))}
    foreach($key in 'PRIVATE_PATH','O:SYG:BAD','C:/PRIVATE_ROOT','ACL','other PRIVATE_VALUE'){$copy=$record.PSObject.Copy();$copy.$field=[pscustomobject]@{};$copy.$field|Add-Member -NotePropertyName $key -NotePropertyValue 1;AssertControl ($null -eq (ComparisonFields $copy))}
   }
   foreach($bad in '1',$true,-1,100001,1.5,[double]::NaN,[double]::PositiveInfinity){$copy=$record.PSObject.Copy();$copy.comparison_unknown_file_entry_count=$bad;AssertControl ($null -eq (ComparisonFields $copy))}
   foreach($field in 'comparison_file_category_field_counts','comparison_known_file_field_counts','comparison_config_scope_field_counts','comparison_file_category_added_kind_counts'){
    $validKey=switch($field){'comparison_file_category_field_counts'{'config'};'comparison_known_file_field_counts'{'runtime'};'comparison_config_scope_field_counts'{'automatic_backups'};default{'backup_runtime'}}
    $validColumn=if($field -ceq 'comparison_file_category_added_kind_counts'){'python_bytecode'}else{'acl'}
    foreach($bad in 'PRIVATE_SDDL',@('acl'),$true,42,$null){$copy=$record.PSObject.Copy();$copy.$field=$bad;AssertControl ($null -eq (ComparisonFields $copy))}
    foreach($bad in '1',$true,-1,100001,1.5,[double]::NaN,[double]::PositiveInfinity){$copy=$record.PSObject.Copy();$copy.$field=[pscustomobject]@{};$copy.$field|Add-Member -NotePropertyName $validKey -NotePropertyValue ([pscustomobject]@{$validColumn=$bad});AssertControl ($null -eq (ComparisonFields $copy))}
    foreach($key in 'PRIVATE_PATH','C:/PRIVATE_ROOT','ACL','other PRIVATE_VALUE'){$copy=$record.PSObject.Copy();$copy.$field=[pscustomobject]@{};$copy.$field|Add-Member -NotePropertyName $key -NotePropertyValue ([pscustomobject]@{acl=1});AssertControl ($null -eq (ComparisonFields $copy))}
    $copy=$record.PSObject.Copy();$copy.$field=[pscustomobject]@{};$copy.$field|Add-Member -NotePropertyName $validKey -NotePropertyValue ([pscustomobject]@{PRIVATE_FIELD=1});AssertControl ($null -eq (ComparisonFields $copy))
   }
  }
 }
 if($record.comparison_result -ceq 'error'){$copy=$record.PSObject.Copy();$copy.comparison_error_type='PRIVATE_MESSAGE';AssertControl ($null -eq (ComparisonFields $copy))}
}
$python=$PythonPath;$fixtureRoot=$Work;$work=Join-Path $fixtureRoot "actual Ω's comparison";[void](New-Item -ItemType Directory -Path $work)
$databaseSidecars=@();$message='Direct reapply changed preserved database/security/routing data.'
foreach($mode in 'Standard','Legacy'){
 $PSNativeCommandArgumentPassing=$mode
 $before=@{private='PRIVATE_VALUE_Ω';values=@{v_vars='PRIVATE_OLD'}}
 $same=@{values=@{v_vars='PRIVATE_OLD'};private='PRIVATE_VALUE_Ω'}
 $emitted=@(Equal $before $same $message)
 AssertControl ($emitted.Count -eq 0 -and $null -eq $comparisonFailure)
 $after=@{private='PRIVATE_VALUE_Ω';values=@{v_vars='PRIVATE_NEW'}}
 $refused=$false
 try{Equal $before $after $message}catch{$refused=$_.Exception.Message -ceq $message}
 AssertControl ($refused -and $comparisonFailure.comparison_result -ceq 'different' -and $comparisonFailure.command_exit -eq 1)
 AssertControl (($comparisonFailure.comparison_critical_tables -join '|') -ceq 'v_vars' -and $comparisonFailure.comparison_changed_values_table_count -eq 1)
 AssertControl ($checkFailure.active_case -ceq 'direct_reapply_database_preserved' -and $checkFailure.source_line -gt 0)
 $report=@{active_case=$checkFailure.active_case;source_line=$checkFailure.source_line};Invoke-Expression $project[0].Extent.Text
 AssertControl ($report.comparison_result -ceq 'different' -and $report.command_basename -ceq 'windows-compare-json.py' -and (($report|ConvertTo-Json -Depth 10) -notmatch 'PRIVATE_'))
 Check $true 'An expected strict refusal was accepted.'
 AssertControl ($null -eq $comparisonFailure)
 # Exact file inequality used to become unavailable: the actual Python child
 # emitted four closed diagnostics missing from the direct/Suite validators.
 $fileBefore=@{'C:\ProgramData\OpenWebPBX\runtime.json'=@{acl='PRIVATE_ACL';sha256='PRIVATE_HASH';bytes=10;directory=$false}}
 $fileSame=$fileBefore|ConvertTo-Json -Depth 10|ConvertFrom-Json -AsHashtable
 $emitted=@(Equal $fileBefore $fileSame 'The real rollback changed file bytes, original/new-file inventory or owner/DACL.')
 AssertControl ($emitted.Count -eq 0 -and $null -eq $comparisonFailure)
 $fileAfter=$fileBefore|ConvertTo-Json -Depth 10|ConvertFrom-Json -AsHashtable
 $fileAfter['C:\ProgramData\OpenWebPBX\runtime.json'].acl='PRIVATE_CHANGED'
 $fileAfter['C:\ProgramData\OpenWebPBX\automatic-backups\PRIVATE_LOCK']=@{acl='PRIVATE_ACL';sha256='PRIVATE_HASH';bytes=0;directory=$false}
 $fileAfter['C:\OpenWebPBX\backup-runtime\Lib\PRIVATE_USER\__pycache__']=@{acl='PRIVATE_ACL';directory=$true}
 $fileAfter['C:\OpenWebPBX\backup-runtime\Lib\PRIVATE_USER\__pycache__\PRIVATE_SOURCE.cpython-314.pyc']=@{acl='PRIVATE_ACL';sha256='PRIVATE_HASH';bytes=0;directory=$false}
 $refused=$false;try{Equal $fileBefore $fileAfter 'The real rollback changed file bytes, original/new-file inventory or owner/DACL.'}catch{$refused=$true}
 AssertControl ($refused -and $comparisonFailure.comparison_result -ceq 'different' -and $comparisonFailure.comparison_stage -ceq 'compare' -and $comparisonFailure.command_exit -eq 1)
 AssertControl ($comparisonFailure.comparison_changed_file_entry_count -eq 4 -and $comparisonFailure.comparison_unknown_file_entry_count -eq 3)
 AssertControl ($comparisonFailure.comparison_file_category_field_counts.config.acl -eq 1 -and $comparisonFailure.comparison_file_category_field_counts.config.added -eq 1)
 AssertControl ($comparisonFailure.comparison_known_file_field_counts.runtime.acl -eq 1 -and $comparisonFailure.comparison_config_scope_field_counts.automatic_backups.added -eq 1)
 AssertControl ($comparisonFailure.comparison_file_category_added_kind_counts.backup_runtime.python_bytecode -eq 1 -and $comparisonFailure.comparison_file_category_added_kind_counts.backup_runtime.python_cache_directory -eq 1 -and $comparisonFailure.comparison_file_category_added_kind_counts.config.other_file -eq 1)
 AssertControl (($comparisonFailure|ConvertTo-Json -Depth 10) -notmatch 'PRIVATE_|S-1-5-21')
 $projected=SafeComparisonFields ([pscustomobject]$comparisonFailure)
 AssertControl ($projected.comparison_known_file_field_counts.runtime.acl -eq 1 -and $projected.comparison_config_scope_field_counts.automatic_backups.added -eq 1)
 Check $true 'Expected file refusal retained exact evidence.'
 try{Check $false 'The helper did not automatically reopen a responsive installed desktop in its original owner/session.'}catch{}
 $report=@{active_case=$checkFailure.active_case};Invoke-Expression $project[0].Extent.Text
 AssertControl ($report.active_case -ceq 'manager_reopened' -and !$report.ContainsKey('comparison_result'))
}
# Reference-only sidecar association does not add fields to original snapshots.
$before=@{values=@{v_vars='PRIVATE_OLD'}};$after=@{values=@{v_vars='PRIVATE_NEW'}}
$columnBefore=Join-Path $fixtureRoot 'new.json.columns-private.json';$columnAfter=Join-Path $fixtureRoot 'changed.json.columns-private.json'
$databaseSidecars=@(@{snapshot=$before;path=$columnBefore},@{snapshot=$after;path=$columnAfter})
try{Equal $before $after $message}catch{}
AssertControl ($comparisonFailure.comparison_columns_observed -and ($comparisonFailure.comparison_critical_columns -join '|') -ceq 'v_vars.update_date')
AssertControl ($before.Count -eq 1 -and $after.Count -eq 1)
# Exercise the actual DatabaseSnapshot association, retaining its return shape.
$probe=Join-Path $fixtureRoot 'private-probe.py'
function Python([string[]]$Arguments){& $python -I -B @Arguments;if($LASTEXITCODE){throw 'Controlled snapshot producer failed.'}}
$priorDate=$env:JSON_COMPARE_DATE;$priorReverse=$env:JSON_COMPARE_REVERSE
try{
 $env:JSON_COMPARE_REVERSE='false';$env:JSON_COMPARE_DATE='PRIVATE_OLD';$databaseSidecars=@()
 $dbBefore=DatabaseSnapshot 'association-before'
 $env:JSON_COMPARE_DATE='PRIVATE_NEW';$dbAfter=DatabaseSnapshot 'association-after'
 AssertControl ($databaseSidecars.Count -eq 2 -and $dbBefore.Count -eq 8 -and $dbAfter.Count -eq 8)
 try{Equal $dbBefore $dbAfter $message}catch{}
 AssertControl ($comparisonFailure.comparison_columns_observed -and ($comparisonFailure.comparison_critical_columns -join '|') -ceq 'v_vars.update_date')
}finally{$env:JSON_COMPARE_DATE=$priorDate;$env:JSON_COMPARE_REVERSE=$priorReverse}
# Exact helper report identity/shape is mandatory: malformed/private output
# remains a strict assertion failure without leaking it into public fields.
$helper=Join-Path $functionsDirectory 'windows-compare-json.py';$original=[IO.File]::ReadAllBytes($helper)
try{
 foreach($stub in (Get-Content -LiteralPath (Join-Path $fixtureRoot 'stub-cases.json') -Raw|ConvertFrom-Json)){
  [IO.File]::WriteAllText($helper,$stub.source,[Text.UTF8Encoding]::new($false));$refused=$false
  try{Equal $before $before $message}catch{$refused=$_.Exception.Message -ceq $message}
  AssertControl ($refused -and $comparisonFailure.comparison_result -ceq $stub.result -and $comparisonFailure.comparison_stage -ceq $stub.stage -and $comparisonFailure.command_exit -eq $stub.exit)
  AssertControl (($comparisonFailure|ConvertTo-Json -Depth 10) -notmatch 'PRIVATE_')
 }
}finally{[IO.File]::WriteAllBytes($helper,$original)}
Write-Output ('PASS '+$count+' actual AST/Standard+Legacy/exact-child/closed-field/privacy/stale-attribution controls')
''')
    result = subprocess.run([args.powershell, '-NoProfile', '-NonInteractive', '-File', str(control),
                             '-SourceRoot', str(root), '-Work', str(work), '-PythonPath', sys.executable,
                             '-RecordsPath', str(records_path)], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr + result.stdout
    print(result.stdout.strip())
print(f'PASS {checks} real Python equality/error/sidecar/actual-producer preservation controls; no PBX/database accessed')
