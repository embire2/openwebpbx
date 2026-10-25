"""Checked-at-only preservation controls; no Windows/installed runtime is used."""
import ast
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
TABLE = 'v_pbx_greeting_status'


def load_restore():
    path = ROOT/'tests/windows-restore-qualification.py'
    spec = importlib.util.spec_from_file_location('owned_greeting_restore', path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def upgrade_projection():
    source = (ROOT/'tests/windows-upgrade-acceptance.ps1').read_text()
    code = source.split("$code=@'\n", 1)[1].split("\n'@", 1)[0]
    functions = [node for node in ast.parse(code).body if isinstance(node, ast.FunctionDef)
                 and node.name == 'greeting_heartbeat_projection']
    if len(functions) != 1:
        raise AssertionError('One exact upgrade heartbeat projection is required.')
    namespace = {}
    exec(compile(ast.Module(body=functions, type_ignores=[]), 'actual-upgrade-heartbeat', 'exec'), namespace)
    return namespace['greeting_heartbeat_projection']


def rows(stamp='2026-10-25T15:01:02.123456+00:00', provider=False):
    return [dict(singleton=1, provider_configured=provider, checked_at=stamp)]


@unittest.skipUnless(shutil.which('php'), 'Actual PHP is required')
class Heartbeat(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.restore = load_restore()
        cls.project = staticmethod(upgrade_projection())

    def receipt(self, value, *, refuse=False):
        code = ("define('OPENWEB_RESTORE_FIXTURE_LIBRARY_ONLY',true);require " +
                json.dumps(str(ROOT/'tests/windows-restore-qualification.php')) +
                ";$rows=json_decode(stream_get_contents(STDIN),false,64,JSON_THROW_ON_ERROR);"
                "try{echo json_encode(restore_fixture_greeting_heartbeat($rows,str_repeat('K',32)),JSON_THROW_ON_ERROR);}"
                "catch(Throwable $e){fwrite(STDERR,get_class($e));exit(7);}")
        child = subprocess.run(['php','-r',code], input=json.dumps(value), capture_output=True, text=True, timeout=10)
        if refuse:
            self.assertEqual(child.returncode,7)
            return None
        self.assertEqual(child.returncode,0,child.stderr)
        return json.loads(child.stdout)

    def snapshot(self, value):
        proof = self.receipt(value)
        return {'schema_metadata': {'schema':'same','tables':'same','columns':'same'},
                'target_owned': {'identity':'same'}, 'source_phone_tuples':'same', 'label':'owned', 'restore_projections':{},
                'all_table_values': {TABLE: {'rows':proof['rows'],'hmac':proof['raw_hmac']},
                    'v_pbx_greetings': {'rows':1,'hmac':'a'*64},
                    'v_pbx_greeting_uses': {'rows':1,'hmac':'b'*64},
                    'v_pbx_media': {'rows':1,'hmac':'c'*64},
                    'v_extensions': {'rows':1,'hmac':'d'*64}},
                'greeting_heartbeat':proof}

    def test_only_real_timestamp_changes_are_projected(self):
        before=rows();after=rows('2026-10-25T15:01:07+00:00')
        a,b=self.receipt(before),self.receipt(after)
        self.assertNotEqual(a['raw_hmac'],b['raw_hmac'])
        self.assertEqual(a['hmac'],b['hmac'])
        self.assertEqual(self.project(before),self.project(after))
        self.assertEqual(before,rows(), 'The projection mutated original row evidence.')
        self.assertEqual(self.project(before),[dict(singleton=1,provider_configured=False,checked_at='__openweb_worker_heartbeat__')])

    def test_empty_inventory_remains_empty(self):
        proof=self.receipt([])
        self.assertEqual(proof['rows'],0)
        self.assertEqual(proof['hmac'],proof['raw_hmac'])
        self.assertEqual(self.project([]),[])

    def test_bad_rows_refuse_in_both_actual_projections(self):
        malformed=[None, {}, [None], [1], rows()*2, [dict(singleton=2,provider_configured=False,checked_at=rows()[0]['checked_at'])],
            [dict(singleton=True,provider_configured=False,checked_at=rows()[0]['checked_at'])],
            [dict(singleton=1,provider_configured='false',checked_at=rows()[0]['checked_at'])],
            [dict(singleton=1,provider_configured=0,checked_at=rows()[0]['checked_at'])],
            [dict(singleton=1,provider_configured=False)],
            [dict(rows()[0],customer_setting='must not hide')],
            [dict(rows()[0],checked_at=None)], [dict(rows()[0],checked_at=0)],
            rows('PRIVATE_NOT_A_TIME'), rows('2026-13-25T15:00:00+00:00'),
            rows('2026-02-31T15:00:00+00:00'), rows('2026-10-25T25:00:00+00:00'),
            rows('2026-10-25T15:00:00'), rows('2026-10-25T15:00:00+00:00\n')]
        for value in malformed:
            with self.subTest(value=value):
                self.receipt(value,refuse=True)
                with self.assertRaises((RuntimeError,ValueError,TypeError)):
                    self.project(value)

    def test_real_provider_state_is_never_projected(self):
        self.assertNotEqual(self.receipt(rows())['hmac'],self.receipt(rows(provider=True))['hmac'])
        self.assertNotEqual(self.project(rows()),self.project(rows(provider=True)))

    def test_both_comparison_modes_admit_only_timestamp_change(self):
        before=self.snapshot(rows());after=self.snapshot(rows('2026-10-25T15:01:07+00:00'))
        for mode in ('factory-recovery','source-restored'):
            self.restore.compare_snapshots(before,after,mode)
        self.assertNotEqual(before['all_table_values'][TABLE]['hmac'],after['all_table_values'][TABLE]['hmac'])

    def test_provider_inventory_and_all_greeting_media_phone_rows_remain_exact(self):
        before=self.snapshot(rows())
        variants=[self.snapshot(rows(provider=True)), self.snapshot([])]
        for table in ('v_pbx_greetings','v_pbx_greeting_uses','v_pbx_media','v_extensions'):
            changed=copy.deepcopy(before);changed['all_table_values'][table]['hmac']='e'*64;variants.append(changed)
        for field in ('schema','tables','columns'):
            changed=copy.deepcopy(before);changed['schema_metadata'][field]='changed';variants.append(changed)
        for after in variants:
            for mode in ('factory-recovery','source-restored'):
                with self.subTest(mode=mode,after=after),self.assertRaises(ValueError):
                    self.restore.compare_snapshots(before,after,mode)

    def test_malformed_or_unbound_receipts_never_substitute_for_raw_rows(self):
        before=self.snapshot(rows())
        changes=[None,{},dict(before['greeting_heartbeat'],rows='1'),dict(before['greeting_heartbeat'],rows=True),
            dict(before['greeting_heartbeat'],rows=0),dict(before['greeting_heartbeat'],rows=2),
            dict(before['greeting_heartbeat'],raw_hmac='f'*64),dict(before['greeting_heartbeat'],hmac='invalid'),
            dict(before['greeting_heartbeat'],unexpected=True)]
        for proof in changes:
            after=copy.deepcopy(before);after['greeting_heartbeat']=proof
            for mode in ('factory-recovery','source-restored'):
                with self.subTest(mode=mode,proof=proof),self.assertRaises(ValueError):
                    self.restore.compare_snapshots(before,after,mode)
        after=copy.deepcopy(before);del after['all_table_values'][TABLE]
        with self.assertRaises(ValueError):self.restore.compare_snapshots(before,after,'factory-recovery')

    def test_whole_table_exclusions_and_original_welcome_fingerprint_stay_exact(self):
        self.assertNotIn(TABLE,self.restore.OPERATIONAL_TABLES)
        self.assertNotIn(TABLE,self.restore.RESTORE_TRANSFORMED_TABLES)
        source=(ROOT/'tests/windows-upgrade-acceptance.ps1').read_text()
        code=source.split("$code=@'\n",1)[1].split("\n'@",1)[0]
        assignments=[node for node in ast.walk(ast.parse(code)) if isinstance(node,ast.Assign)
                     and any(isinstance(target,ast.Name) and target.id=='volatile' for target in node.targets)]
        self.assertEqual(len(assignments),1)
        self.assertNotIn(TABLE,ast.literal_eval(assignments[0].value))
        current=(ROOT/'tests/windows_welcome_native.php').read_bytes()
        self.assertEqual(hashlib.sha256(current).hexdigest(), '48e853e4baf9374ee8f05c604f94821a5f89d9f5a01912371540d5c1f1d9b0b1', 'The original welcome guard was weakened.')
        self.assertIn("$out['all_table_values'][$table]=['rows'=>count($rows),'hmac'=>restore_fixture_rows_digest($rows,$key)];",
                      (ROOT/'tests/windows-restore-qualification.php').read_text())


if __name__=='__main__':unittest.main()
