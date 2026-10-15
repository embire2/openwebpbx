#!/usr/bin/env python3
"""Actual worker/lock/comparator controls on owned files; no Windows acceptance."""
import contextlib
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('backup_warmup_source', ROOT/'packaging/windows/backups.py')
b = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(b)


class WorkerBaselineChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='owned-backup-baseline-')
        self.addCleanup(self.temporary.cleanup)
        self.state = Path(self.temporary.name)
        self.store, self.downloads = self.state/'automatic-backups', self.state/'backup-downloads'
        self.store.mkdir(mode=0o700); self.downloads.mkdir(mode=0o750)
        self.calls = []
        patches = mock.patch.multiple(b, STATE=self.state, RESTORE=self.state/'backup-restore',
                                      UPGRADE_LOCK=self.state/'upgrade.lock')
        patches.start(); self.addCleanup(patches.stop)
        query = mock.patch.object(b, 'query', side_effect=self.query)
        query.start(); self.addCleanup(query.stop)
        for name in ('run', 'create_archive'):
            patch = mock.patch.object(b, name, side_effect=AssertionError('No external child or backup is permitted.'))
            patch.start(); self.addCleanup(patch.stop)

    def query(self, settings, sql, **kwargs):
        self.calls.append(sql)
        if sql.startswith('select row_to_json(t) from v_pbx_backup_settings'):
            return {'enabled': False, 'passphrase_secret': ''}
        if sql.startswith(('update v_pbx_backup_commands set status=', 'update v_pbx_backups set status=',
                           'with next as ', 'update v_pbx_backup_status set state=')):
            return ''
        raise AssertionError('Unexpected query outside the no-command worker branch.')

    def worker(self):
        b.worker({}, store=self.store, downloads=self.downloads)

    def snapshot(self):
        values = {}
        for directory in (self.store, self.downloads):
            for path in (directory, *sorted(directory.rglob('*'))):
                row = {'directory': path.is_dir(), 'acl': 'portable-mode-'+oct(path.stat().st_mode & 0o777)}
                if path.is_file():
                    row |= {'bytes': path.stat().st_size, 'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
                values['C:/ProgramData/OpenWebPBX/'+path.relative_to(self.state).as_posix()] = row
        return values

    def compare(self, before, after):
        paths = [self.state/'before.json', self.state/'after.json']
        for path, value in zip(paths, (before, after)):
            path.write_text(json.dumps(value), encoding='utf-8')
        original = [path.read_bytes() for path in paths]
        result = subprocess.run([sys.executable, '-I', '-B', str(ROOT/'tests/windows-compare-json.py'),
                                 *map(str, paths)], capture_output=True, text=True, timeout=15)
        self.assertEqual(original, [path.read_bytes() for path in paths])
        self.assertEqual(result.stderr, '')
        return result.returncode, json.loads(result.stdout)

    def test_first_actual_worker_creates_lock_and_second_run_keeps_exact_baseline(self):
        before = self.snapshot()
        self.assertFalse((self.store/'worker.lock').exists())
        self.worker()
        initialized = self.snapshot()
        self.assertTrue((self.store/'worker.lock').is_file())
        self.assertEqual((self.store/'worker.lock').read_bytes(), b'')
        code, report = self.compare(before, initialized)
        self.assertEqual(code, 1)
        self.assertEqual(report['comparison_known_file_field_counts'], {'automatic_backups_worker_lock': {'added': 1}})
        self.worker()
        self.assertEqual(initialized, self.snapshot())
        self.assertEqual(self.compare(initialized, self.snapshot())[0], 0)
        self.assertEqual(len(self.calls), 10)

    def test_actual_restore_holds_prevent_normal_initialization(self):
        for hold in b.HELD_UNITS:
            with self.subTest(hold=hold):
                marker = b.RESTORE/('hold-'+hold)
                marker.parent.mkdir(exist_ok=True); marker.write_text('owned hold')
                try:
                    self.worker()
                    self.assertFalse((self.store/'worker.lock').exists())
                    self.assertEqual(self.calls, [])
                finally:
                    marker.unlink()

    def test_actual_maintenance_prevents_normal_initialization(self):
        marker = self.state/'updates/maintenance'; marker.parent.mkdir(); marker.write_text('owned maintenance')
        self.worker()
        self.assertFalse((self.store/'worker.lock').exists())
        self.assertEqual(self.calls, [])

    def test_upgrade_guard_precedes_all_worker_file_creation(self):
        calls = []
        @contextlib.contextmanager
        def refused(path):
            calls.append(path)
            raise b.BackupError('owned upgrade lock refusal')
            yield
        with mock.patch.object(b, 'exclusive_guard', refused):
            with self.assertRaises(b.BackupError):
                self.worker()
        self.assertEqual(calls, [self.state/'upgrade.lock'])
        self.assertFalse((self.store/'worker.lock').exists())
        self.assertEqual(self.calls, [])


if __name__ == '__main__':
    if os.name == 'nt':
        raise SystemExit('These portable worker controls run offline; the actual installed task is qualified separately.')
    unittest.main()
