"""Actual startup-probe journal lifecycle and Backup-Control AST, with SCM/IIS doubles.

Only the installed path/Windows guard and unused crypto imports are adapted.
Python locking/atomic journal writes and actual PowerShell operation bodies stay real. No
installed PBX, database, service, Scheduler, ACL or customer data is touched.
"""
import ast
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'tests/windows-upgrade-acceptance.ps1'
PWSH = os.environ.get('OPENWEB_TEST_PWSH') or shutil.which('pwsh')


class RestoreHolds(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not PWSH:
            raise RuntimeError('Pass OPENWEB_TEST_PWSH for the actual PowerShell AST controls.')
        protocol = ast.parse((ROOT / 'tests/windows_backup_control_protocol.py').read_text())
        harness = [node.value for node in protocol.body if isinstance(node, ast.Assign)
                   and any(isinstance(target, ast.Name) and target.id == 'HARNESS' for target in node.targets)]
        if len(harness) != 1:
            raise RuntimeError('One actual protocol AST adapter is required.')
        cls.harness = ast.literal_eval(harness[0])
        cls.embedded = SOURCE.read_text().split("$code=@'\n", 1)[1].split("\n'@", 1)[0]

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='openweb-upgrade-restore-holds-')
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.state = self.work / 'state'
        self.restore = self.state / 'backup-restore'
        self.restore.mkdir(parents=True)
        (self.state / 'backup-control').mkdir()
        self.marker = self.state / 'call-records.hold'
        self.journal = self.restore / 'journal.json'
        self.plan = self.work / 'gate-plan.json'
        self.events = self.work / 'events.jsonl'
        self.env = os.environ | {'OPENWEB_HOLD_WORK': str(self.work), 'OPENWEB_HOLD_PWSH': PWSH,
                                 'OPENWEB_HOLD_ROOT': str(ROOT), 'GITHUB_ACTIONS': 'true'}
        harness = self.harness.replace(
            "[ValidateSet('resume-factory','plan','start-web','recover-startup')]",
            "[ValidateSet('resume-factory','plan','start-web','recover-startup','hold')]")
        binding = '$root=Split-Path -Parent $Request;$private=$root;$control=$root;$restore=$root;$backupEngineRoot=$root'
        self.assertEqual(harness.count(binding), 1)
        harness = harness.replace(binding, "$root=Join-Path $env:OPENWEB_HOLD_WORK 'state';$private=$root;$control=Join-Path $root 'backup-control';$restore=Join-Path $root 'backup-restore';$backupEngineRoot=$root")
        insertion = 'try{. ([scriptblock]::Create($code))}'
        self.assertEqual(harness.count(insertion), 1)
        harness = harness.replace(insertion, ADAPTERS + '\n' + insertion)
        (self.work / 'control.ps1').write_text(harness)
        (self.work / 'backups.py').write_text(SHIM)
        self.probe = self.write_probe(self.embedded, 'private-probe.py')

    def write_probe(self, embedded, name):
        tree = ast.parse(embedded)
        self.assertIsInstance(tree.body[2], ast.If)
        self.assertIn("os.name != 'nt'", ast.unparse(tree.body[2].test))
        del tree.body[2]
        replaced = 0
        for node in ast.walk(tree):
            if isinstance(node, ast.Constant) and node.value == 'C:/OpenWebPBX/tools/backups.py':
                node.value = str(self.work / 'backups.py')
                replaced += 1
        self.assertEqual(replaced, 1)
        target = self.work / name
        target.write_text(ast.unparse(ast.fix_missing_locations(tree)))
        return target

    def run_probe(self, action, *, probe=None, fault=''):
        return subprocess.run([sys.executable, '-I', '-B', '-S', str(probe or self.probe), action, str(self.plan), str(ROOT), str(ROOT), str(self.work)],
                              env=self.env | {'OPENWEB_HOLD_FAULT': fault}, capture_output=True, timeout=60)

    def observed(self):
        return [json.loads(line) for line in self.events.read_text().splitlines()] if self.events.exists() else []

    def held(self):
        result = self.run_probe('holds')
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertTrue(self.marker.is_file())
        self.assertEqual(json.loads(self.marker.read_text()), json.loads(self.plan.read_text())['call_records_hold'])
        self.assertEqual(json.loads(self.journal.read_text())['state'], 'restored')
        self.assertTrue(all((self.restore / ('hold-' + name)).is_file() for name in ('calls', 'jobs', 'updates', 'backups')))

    def test_old_no_journal_refuses_actual_product_before_hold_side_effects(self):
        start = self.embedded.index("elif action=='holds':")
        end = self.embedded.index("elif action=='pending':", start)
        legacy = self.embedded[:start] + LEGACY + self.embedded[end:]
        result = self.run_probe('holds', probe=self.write_probe(legacy, 'old-probe.py'))
        self.assertNotEqual(result.returncode, 0)
        failure = json.loads((self.work / 'probe-failure.json').read_text())
        self.assertEqual((failure['active_case'], failure['error_type'], failure['source_basename']),
                         ('restore_holds', 'BackupError', 'backups.py'))
        self.assertFalse(self.journal.exists())
        self.assertFalse(self.marker.exists())
        events = self.observed()
        self.assertEqual([event['operation'] for event in events], ['plan', 'hold'])
        self.assertTrue(all(event['maintenance_lock_held'] for event in events))
        trace = json.loads(Path(events[-1]['trace']).read_text())
        self.assertEqual(trace['calls'], [])  # Get-Item journal refusal precedes hold/SCM calls.

    def test_current_holds_and_release_preserve_actual_journal_marker_order(self):
        self.held()
        result = self.run_probe('release')
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertFalse(self.journal.exists())
        self.assertFalse(self.marker.exists())
        self.assertFalse(any((self.restore / ('hold-' + name)).exists() for name in ('calls', 'jobs', 'updates', 'backups')))
        self.assertTrue(self.plan.is_file())  # Retain the exact startup/nonce evidence.
        events = self.observed()
        self.assertEqual([event['operation'] for event in events], ['plan', 'hold', 'recover-startup', 'resume-factory'])
        self.assertTrue(all(event['maintenance_lock_held'] for event in events))
        self.assertEqual([event['journal_state'] for event in events], [None, 'prepared', 'restored', 'recovered'])
        trace = json.loads(Path(events[-1]['trace']).read_text())
        clear = [call for call in trace['calls'] if call['name'] == 'RemoveCallRecordHold']
        self.assertEqual(len(clear), 1)
        self.assertEqual(clear[0]['arguments']['journal_state'], 'recovered')

    def test_unrelated_journal_or_any_hold_refuses_before_control_and_preserves_bytes(self):
        for target in (self.journal, self.marker, self.restore / 'hold-calls'):
            with self.subTest(target=target.name):
                raw = b'PRIVATE_FOREIGN_STATE_PRESERVE'
                target.write_bytes(raw)
                result = self.run_probe('holds')
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(target.read_bytes(), raw)
                self.assertFalse(self.plan.exists())
                self.assertEqual(self.observed(), [])
                target.unlink()

    def test_changed_journal_or_fixture_refuses_release_without_mutation(self):
        self.held()
        original = self.journal.read_bytes()
        plan = self.plan.read_bytes()
        for kind in ('foreign_transaction', 'wrong_qualification', 'unexpected_journal_field',
                     'journal_boolean_schema', 'hold_boolean_schema', 'invalid_fixture_schema'):
            with self.subTest(kind=kind):
                self.journal.write_bytes(original)
                self.plan.write_bytes(plan)
                journal = json.loads(original)
                if kind == 'foreign_transaction': journal['call_records_hold']['transaction'] = 'f' * 32
                elif kind == 'wrong_qualification': journal['qualification'] = 'foreign'
                elif kind == 'unexpected_journal_field': journal['foreign'] = 'PRIVATE'
                elif kind == 'journal_boolean_schema': journal['schema'] = True
                elif kind == 'hold_boolean_schema': journal['call_records_hold']['schema'] = True
                else:
                    fixture = json.loads(plan); fixture['schema'] = True
                    self.plan.write_text(json.dumps(fixture))
                self.journal.write_text(json.dumps(journal))
                before = self.journal.read_bytes(), self.marker.read_bytes(), len(self.observed())
                result = self.run_probe('release')
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((self.journal.read_bytes(), self.marker.read_bytes(), len(self.observed())), before)

    def test_failed_hold_retains_owned_journal_and_can_release_without_fake_success(self):
        result = self.run_probe('holds', fault='hold')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(self.journal.read_text())['state'], 'prepared')
        self.assertTrue(self.plan.is_file())
        self.assertTrue((self.restore / 'hold-calls').is_file())
        result = self.run_probe('release')
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertFalse(self.journal.exists())
        self.assertFalse(self.marker.exists())

    def test_failed_resume_retains_recovered_journal_marker_then_exact_retry(self):
        self.held()
        marker = self.marker.read_bytes()
        result = self.run_probe('release', fault='resume')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(self.journal.read_text())['state'], 'recovered')
        self.assertEqual(self.marker.read_bytes(), marker)
        result = self.run_probe('release')
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertFalse(self.journal.exists())
        self.assertFalse(self.marker.exists())

    def test_foreign_marker_is_not_deleted_or_promoted_to_released(self):
        self.held()
        foreign = {'schema': 1, 'owner': 'restore', 'transaction': 'e' * 32}
        self.marker.write_text(json.dumps(foreign))
        raw = self.marker.read_bytes()
        journal = self.journal.read_bytes()
        events = len(self.observed())
        result = self.run_probe('release')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.marker.read_bytes(), raw)
        self.assertEqual(self.journal.read_bytes(), journal)
        self.assertEqual(len(self.observed()), events)
        self.assertTrue(all((self.restore / ('hold-' + name)).is_file() for name in ('calls', 'jobs', 'updates', 'backups')))
        self.assertEqual(json.loads((self.work / 'probe-failure.json').read_text())['active_case'], 'restore_release')


LEGACY = '''elif action=='holds':
 stage='restore_holds'
 if (b.RESTORE/'journal.json').exists():raise RuntimeError('An unrelated restore journal exists')
 with b.exclusive_guard(b.UPGRADE_LOCK):
  plan=b.control('plan');save(plan);b.install_service_holds(plan)
elif action=='release':
 stage='restore_release'
 plan=json.loads(path.read_text());b.control('recover-startup',plan)
 for name in b.HELD_UNITS:(b.RESTORE/('hold-'+name)).unlink(missing_ok=True)
 b.control('resume-factory',plan)
'''

# Reuse the actual backup implementation, changing only owned paths and the
# Windows process bridge. Real Python lock/journal/hold writers remain intact.
SHIM = r'''
import ast,json,os,subprocess,tempfile,types
from pathlib import Path
source=Path(os.environ['OPENWEB_HOLD_ROOT'])/'packaging/windows/backups.py'
tree=ast.parse(source.read_text());crypto=[node for node in tree.body if isinstance(node,ast.ImportFrom) and node.module.startswith('cryptography.')]
if len(crypto)!=2:raise RuntimeError('The actual unused crypto-import adapter changed')
tree.body=[node for node in tree.body if node not in crypto]
b=types.ModuleType('actual_backups');b.__file__=str(source);exec(compile(tree,str(source),'exec'),b.__dict__)
work=Path(os.environ['OPENWEB_HOLD_WORK']);b.STATE=work/'state';b.RESTORE=b.STATE/'backup-restore';b.UPGRADE_LOCK=b.STATE/'upgrade.lock'
b.read_settings=lambda: {'database.0.type':'pgsql'}
def control(operation,value=None):
 locked=False
 try:
  with b.exclusive_guard(b.UPGRADE_LOCK):pass
 except b.BackupBusy:locked=True
 entry={'operation':operation,'maintenance_lock_held':locked,'journal_state':json.loads((b.RESTORE/'journal.json').read_text()).get('state') if (b.RESTORE/'journal.json').exists() else None}
 request=work/'state/backup-control'/('request-'+str(len(list((work/'state/backup-control').glob('request-*'))))+'.json');request.write_text(json.dumps(value or {}))
 trace=request.with_suffix('.trace.json');entry['trace']=str(trace)
 with (work/'events.jsonl').open('a') as stream:stream.write(json.dumps(entry)+'\n')
 raw=b.run([os.environ['OPENWEB_HOLD_PWSH'],'-NoProfile','-NonInteractive','-File',str(work/'control.ps1'),'-Product',str(Path(os.environ['OPENWEB_HOLD_ROOT'])/'packaging/windows/Backup-Control.ps1'),'-Operation',operation,'-Request',str(request),'-Trace',str(trace)],timeout=30)
 return json.loads(raw.decode('utf-8-sig'))
b.control=control
globals().update({name:getattr(b,name) for name in ('STATE','RESTORE','UPGRADE_LOCK','HELD_UNITS','read_settings','ordinary','reparse','atomic_json','exclusive_guard','install_service_holds')})
'''

ADAPTERS = r'''
$common=[Management.Automation.Language.Parser]::ParseFile((Join-Path $env:OPENWEB_HOLD_ROOT 'packaging/windows/CallRecords.Common.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Actual hold identity source did not parse.'}
$assertion=@($common.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Assert-OpenWebCallRecordHold'},$true))
if($assertion.Count -ne 1){throw 'An exact hold identity validator is required.'}
. ([scriptblock]::Create($assertion[0].Extent.Text))
function Set-OpenWebCallRecordHold {
 param($StateRoot,$Hold,[switch]$ExternalLockHeld)
 Assert-OpenWebCallRecordHold $Hold
 if(!$ExternalLockHeld){throw 'Parent lock was not declared.'}
 Record 'SetCallRecordHold' @{owner=$Hold.owner;transaction=$Hold.transaction;journal_state=(Get-Content (Join-Path $restore 'journal.json') -Raw|ConvertFrom-Json).state}
 if($env:OPENWEB_HOLD_FAULT -ceq 'hold'){throw 'Fictional native marker refusal.'}
 [IO.File]::WriteAllText((Join-Path $StateRoot 'call-records.hold'),($Hold|ConvertTo-Json -Compress))
}
function Remove-OpenWebCallRecordHold {
 param($StateRoot,$Hold,[switch]$ExternalLockHeld)
 Assert-OpenWebCallRecordHold $Hold
 if(!$ExternalLockHeld){throw 'Parent lock was not declared.'}
 $marker=Join-Path $StateRoot 'call-records.hold'
 Record 'RemoveCallRecordHold' @{owner=$Hold.owner;transaction=$Hold.transaction;journal_state=(Get-Content (Join-Path $restore 'journal.json') -Raw|ConvertFrom-Json).state}
 if($env:OPENWEB_HOLD_FAULT -ceq 'resume'){throw 'Fictional native release refusal.'}
 if(Test-Path -LiteralPath $marker){
  $current=Get-Content -LiteralPath $marker -Raw|ConvertFrom-Json
  Assert-OpenWebCallRecordHold $current
  if($current.owner -cne $Hold.owner -or $current.transaction -cne $Hold.transaction){throw 'Foreign marker preserved.'}
  Remove-Item -LiteralPath $marker -ErrorAction Stop
 }
}
'''

if __name__ == '__main__':
    unittest.main()
