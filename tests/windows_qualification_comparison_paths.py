#!/usr/bin/env python3
"""Exact comparator diagnostic controls; fictional private snapshots only."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('windows-compare-json.py')
SPEC = importlib.util.spec_from_file_location('comparison', SCRIPT)
comparison = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(comparison)
SENSITIVE = 'PRIVATE_SENTINEL_customer_password_SDDL_S-1-5-21'


def entry():
    return {'acl': SENSITIVE, 'sha256': SENSITIVE, 'bytes': 10, 'directory': False}


class DiagnosticChecks(unittest.TestCase):
    def run_comparator(self, before, after):
        with tempfile.TemporaryDirectory(prefix='comparison-private-') as temporary:
            paths = [Path(temporary) / name for name in ('before.json', 'after.json')]
            for path, value in zip(paths, (before, after)):
                path.write_text(json.dumps(value), encoding='utf-8')
            original = [path.read_bytes() for path in paths]
            result = subprocess.run([sys.executable, '-I', '-B', str(SCRIPT), *map(str, paths)],
                                    capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0 if before == after else 1)
            self.assertEqual([path.read_bytes() for path in paths], original)
            self.assertEqual(result.stderr, '')
            self.assertNotIn(SENSITIVE, result.stdout)
            return json.loads(result.stdout)

    def test_runtime_added_kinds_are_closed_exact_and_keep_inequality(self):
        base = {'C:/ProgramData/OpenWebPBX/runtime.json': entry()}
        additions = {
            'C:/OpenWebPBX/backup-runtime/Lib/' + SENSITIVE + '/__pycache__': {'acl': SENSITIVE, 'directory': True},
            'C:/OpenWebPBX/backup-runtime/Lib/' + SENSITIVE + '/__pycache__/private.cpython-314.pyc': entry(),
            'C:/OpenWebPBX/backup-runtime/Lib/' + SENSITIVE + '/second.pyo': entry(),
            'C:/OpenWebPBX/backup-runtime/private.dll': entry(),
            'C:/OpenWebPBX/backup-runtime/private.pyd': entry(),
            'C:/OpenWebPBX/backup-runtime/private.txt': entry(),
            'C:/OpenWebPBX/backup-runtime/directory': {'acl': SENSITIVE, 'directory': True},
            'C:/OpenWebPBX/backup-runtime/invalid.pyc': 'private-shape',
            'C:/OpenWebPBX/acme/private.dll': entry(),
        }
        result = self.run_comparator(base, base | additions)
        self.assertEqual(result['comparison_changed_file_entry_count'], 9)
        self.assertEqual(result['comparison_file_category_counts'], {'backup_runtime': 8, 'acme_runtime': 1})
        self.assertEqual(result['comparison_file_category_added_kind_counts'], {
            'backup_runtime': {'python_bytecode': 2, 'dll': 1, 'pyd': 1, 'other_file': 1,
                               'python_cache_directory': 1, 'other_directory': 1, 'shape': 1},
            'acme_runtime': {'dll': 1}})
        for near in ('C:/OpenWebPBX/backup-runtime-foreign/private.pyc', 'C:/OpenWebPBX/acme-foreign/private.dll'):
            result = self.run_comparator(base, base | {near: entry()})
            self.assertEqual(result['comparison_file_category_counts'], {'other': 1})
        changed = copy.deepcopy(base); changed[next(iter(base))]['acl'] = 'changed'
        self.assertEqual(self.run_comparator(base, changed)['comparison_file_category_added_kind_counts'], {})

    def test_equal_keeps_original_minimal_report(self):
        value = {'C:/ProgramData/OpenWebPBX/installation.json': entry()}
        row = self.run_comparator(value, copy.deepcopy(value))
        self.assertEqual(set(row), {'schema', 'producer', 'comparison_result', 'comparison_stage'})
        self.assertEqual(row['comparison_result'], 'equal')

    def test_removed_control_request_kinds_are_closed_and_do_not_ignore_loss(self):
        root='C:/ProgramData/OpenWebPBX/backup-control/'
        keep={'C:/ProgramData/OpenWebPBX/runtime.json':entry()}
        removed={root+'tmpabc_1234.json':entry(),root+'tmpabc_1234.json-child':entry(),
                 root+'nested/tmpabc_1234.json':entry(),root+'tmpabc_123.json':entry(),
                 root+'tmpabc_12345.json':entry(),root+'tmpabc_1234.json/child':entry(),
                 root+'tmpfolder.json':{'acl':SENSITIVE,'directory':True},
                 root+'tmp_shape.json':SENSITIVE,
                 'C:/ProgramData/OpenWebPBX/phone-tls/tmpabc_1234.json':entry()}
        result=self.run_comparator(keep|removed,keep)
        self.assertEqual(result['comparison_result'],'different')
        self.assertEqual(result['comparison_changed_file_entry_count'],len(removed))
        self.assertEqual(result['comparison_config_scope_removed_kind_counts'],{
            'phone_tls':{'other_file':1},'backup_control':{'temporary_control_request_json':1,'other_file':5,'directory':1,'shape':1}})
        self.assertEqual(result['comparison_file_category_added_kind_counts'],{})
        for path in (root+'tmpabc_1234.json',root.upper().replace('/','\\')+'TMPABC_1234.JSON'):
            self.assertEqual(self.run_comparator(keep|{path:entry()},keep)['comparison_config_scope_removed_kind_counts'],{'backup_control':{'temporary_control_request_json':1}})
        for path in ('C:/ProgramData/OpenWebPBX/backup-control-foreign/tmpabc_1234.json','C:/foreign/backup-control/tmpabc_1234.json'):
            self.assertEqual(self.run_comparator(keep|{path:entry()},keep)['comparison_config_scope_removed_kind_counts'],{})
        changed=copy.deepcopy(keep);changed[next(iter(keep))]['bytes']=11
        self.assertEqual(self.run_comparator(keep,changed)['comparison_config_scope_removed_kind_counts'],{})

    def test_same_marginals_different_cross_tabs(self):
        tracks = [f'C:/ProgramData/OpenWebPBX/storage/openweb-music/{rate}/lofi-beat-loop-schmoop.wav'
                  for rate in (8000, 16000, 32000, 48000)]
        installation = 'C:/ProgramData/OpenWebPBX/installation.json'
        updater = 'C:/ProgramData/OpenWebPBX/updater-install.json'
        left_a = {path: entry() for path in [*tracks, installation]}
        right_a = copy.deepcopy(left_a)
        for row in right_a.values(): row['acl'] = 'changed'
        right_a['C:/ProgramData/OpenWebPBX/automatic-backups/' + SENSITIVE] = entry()
        left_b = {path: entry() for path in [*tracks[:3], installation, updater]}
        right_b = copy.deepcopy(left_b)
        for row in right_b.values(): row['acl'] = 'changed'
        right_b['C:/ProgramData/OpenWebPBX/storage/' + SENSITIVE] = entry()
        a, b = self.run_comparator(left_a, right_a), self.run_comparator(left_b, right_b)
        for key in ('comparison_file_field_counts', 'comparison_file_category_counts'):
            self.assertEqual(a[key], b[key])
        self.assertEqual(a['comparison_file_field_counts'], {'acl': 5, 'added': 1})
        self.assertEqual(a['comparison_file_category_counts'], {'config': 2, 'media': 4})
        self.assertEqual(a['comparison_file_category_field_counts'],
                         {'config': {'acl': 1, 'added': 1}, 'media': {'acl': 4}})
        self.assertEqual(b['comparison_file_category_field_counts'],
                         {'config': {'acl': 2}, 'media': {'acl': 3, 'added': 1}})
        self.assertEqual(a['comparison_unknown_file_entry_count'], 1)
        self.assertEqual(b['comparison_unknown_file_entry_count'], 1)

    def test_all_thirty_nine_labels_accept_only_exact_known_paths(self):
        self.assertEqual(len(set(comparison.KNOWN_FILE_LABELS)), 39)
        for path, label in comparison.KNOWN_FILE_PATHS.items():
            with self.subTest(label=label):
                native_path = path.upper().replace('/', '\\')
                before = {native_path: entry()}
                after = copy.deepcopy(before); after[native_path]['acl'] = 'changed'
                row = self.run_comparator(before, after)
                self.assertEqual(row['comparison_known_file_field_counts'], {label: {'acl': 1}})
                self.assertEqual(row['comparison_unknown_file_entry_count'], 0)
        path = 'C:/ProgramData/OpenWebPBX/storage/' + SENSITIVE + '/installation.json'
        row = self.run_comparator({path: entry()}, {})
        self.assertEqual(row['comparison_known_file_field_counts'], {})
        self.assertEqual(row['comparison_unknown_file_entry_count'], 1)
        self.assertEqual(row['comparison_file_category_field_counts'], {'media': {'removed': 1}})

    def test_seven_support_labels_have_exact_path_and_privacy_boundaries(self):
        expected = {
            'c:/openwebpbx': 'program_root',
            'c:/openwebpbx/php/php.ini': 'php_ini',
            'c:/openwebpbx/php/extras/ssl/openssl.cnf': 'php_openssl',
            'c:/openwebpbx/php/extras/ssl/cacert.pem': 'php_cacert',
            'c:/programdata/openwebpbx/mobile-notifications': 'notification_store',
            'c:/programdata/openwebpbx/mobile-notifications/config.json': 'notification_config',
            'c:/programdata/openwebpbx/mobile-notifications/config.json.lock': 'notification_lock',
        }
        for path, label in expected.items():
            with self.subTest(label=label):
                self.assertEqual(comparison.KNOWN_FILE_PATHS[path], label)
                for near in (path + '-' + SENSITIVE, path + '/' + SENSITIVE,
                             path + '/../' + SENSITIVE,
                             'C:/foreign/' + SENSITIVE + '/' + path.rsplit('/', 1)[-1]):
                    baseline = {'C:/ProgramData/OpenWebPBX/runtime.json': entry()}
                    row = self.run_comparator(baseline | {near: entry()}, baseline)
                    self.assertEqual(row['comparison_known_file_field_counts'], {})
                    self.assertEqual(row['comparison_unknown_file_entry_count'], 1)
        self.assertEqual(len(comparison.CONFIG_SCOPES), 9)

    def test_residual_added_lock_and_closed_subroots_keep_exact_refusal(self):
        baseline = {'C:/ProgramData/OpenWebPBX/runtime.json': entry()}
        path = 'C:/ProgramData/OpenWebPBX/automatic-backups/worker.lock'
        after = baseline | {path: entry()}
        row = self.run_comparator(baseline, after)
        self.assertEqual(row['comparison_file_field_counts'], {'added': 1})
        self.assertEqual(row['comparison_known_file_field_counts'], {'automatic_backups_worker_lock': {'added': 1}})
        self.assertEqual(row['comparison_config_scope_field_counts'], {'automatic_backups': {'added': 1}})
        self.assertEqual(row['comparison_unknown_file_entry_count'], 0)
        for prefix, label in comparison.CONFIG_SCOPES.items():
            with self.subTest(scope=label):
                row = self.run_comparator(baseline, baseline | {prefix + '/' + SENSITIVE: entry()})
                self.assertEqual(row['comparison_config_scope_field_counts'], {label: {'added': 1}})
                self.assertEqual(row['comparison_known_file_field_counts'], {})
                self.assertEqual(row['comparison_unknown_file_entry_count'], 1)
                for name in (prefix + '-foreign/' + SENSITIVE, prefix + 'x/' + SENSITIVE):
                    self.assertEqual(self.run_comparator(baseline, baseline | {name: entry()})['comparison_config_scope_field_counts'], {})

    def test_every_field_is_associated_with_its_actual_category(self):
        path = 'C:/ProgramData/OpenWebPBX/runtime.json'
        for field, value in (('acl', 'changed'), ('sha256', 'changed'), ('bytes', 11),
                             ('directory', True), (SENSITIVE, SENSITIVE)):
            with self.subTest(field=field):
                before = {path: entry()}; after = copy.deepcopy(before); after[path][field] = value
                row = self.run_comparator(before, after); expected = field if field != SENSITIVE else 'other'
                self.assertEqual(row['comparison_file_category_field_counts'], {'config': {expected: 1}})
                self.assertEqual(row['comparison_known_file_field_counts'], {'runtime': {expected: 1}})
        row = self.run_comparator({path: entry()}, {path: SENSITIVE})
        self.assertEqual(row['comparison_known_file_field_counts'], {'runtime': {'shape': 1}})

    def test_null_and_case_changes_still_refuse_exact_equality(self):
        path = 'C:/ProgramData/OpenWebPBX/runtime.json'
        before = {path: entry()}; after = copy.deepcopy(before); after[path]['missing'] = None
        self.assertEqual(self.run_comparator(before, after)['comparison_result'], 'different')
        row = self.run_comparator(before, {path.lower(): entry()})
        self.assertEqual(row['comparison_file_field_counts'], {'added': 1, 'removed': 1})
        self.assertEqual(row['comparison_known_file_field_counts'], {'runtime': {'added': 1, 'removed': 1}})

    def test_bounded_counts_and_no_path_normalization(self):
        original = comparison.LIMIT
        try:
            comparison.LIMIT = 1
            before = {f'C:/OpenWebPBX/web/{SENSITIVE}/{i}': entry() for i in range(3)}
            after = copy.deepcopy(before)
            for row in after.values(): row['acl'] = 'changed'
            result = comparison.file_difference(before, after, comparison.changed_keys(before, after))
            self.assertTrue(result['comparison_file_counts_capped'])
            self.assertEqual(result['comparison_file_category_field_counts'], {'web': {'acl': 1}})
            self.assertEqual(result['comparison_unknown_file_entry_count'], 1)
            self.assertNotIn(SENSITIVE, json.dumps(result))
        finally:
            comparison.LIMIT = original
        path = 'C:/ProgramData/OpenWebPBX/other/../runtime.json'
        row = self.run_comparator({path: entry()}, {})
        self.assertEqual(row['comparison_known_file_field_counts'], {})
        self.assertEqual(row['comparison_result'], 'different')


if __name__ == '__main__':
    unittest.main()
