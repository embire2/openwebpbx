#!/usr/bin/env python3
"""Real files, real locks and private subprocesses; no installed PBX mutation."""
import contextlib
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


installer = load('phone_health_installer', 'packaging/debian/install-phone-health.py')
worker = load('phone_health_worker', 'packaging/debian/phone-health.py')
support = load('phone_health_support', 'packaging/debian/install-support.py')
upgrade = load('phone_health_upgrade', 'packaging/debian/upgrade.py')


class PhoneHealthInstall(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='.health-install-', dir=ROOT)
        self.root = Path(self.tmp.name)
        self.package = self.root / 'package'
        self.package.mkdir()
        self.tools = self.root / 'tools'
        self.units = self.root / 'units'
        self.calls = []
        self.enabled = True
        self.loaded = 'not-found'
        for name in (*installer.PROGRAMS, installer.UNIT.name, installer.TIMER.name):
            (self.package / name).write_bytes((ROOT / 'packaging/debian' / name).read_bytes())
        self.manifest()
        self.patches = [patch.object(installer, 'PACKAGE', self.package),
                        patch.object(installer, 'TOOLS', self.tools),
                        patch.object(installer, 'UNIT', self.units / installer.UNIT.name),
                        patch.object(installer, 'TIMER', self.units / installer.TIMER.name),
                        patch.object(installer, 'LINKS', [self.units / 'timers.target.wants' / installer.TIMER.name,
                                                          self.units / 'openwebpbx-updater.service.wants' / installer.TIMER.name]),
                        patch.object(installer, 'MAINTENANCE', self.root / 'maintenance'),
                        patch.object(installer, 'RESTORE_HOLD', self.root / 'restore-hold'),
                        patch.object(installer.subprocess, 'run', side_effect=self.command),
                        patch.object(installer.subprocess, 'check_output', side_effect=lambda *a, **k: self.loaded)]
        for item in self.patches:
            item.start()

    def manifest(self):
        (self.package / 'release-manifest.json').write_text(json.dumps({'files': {
            path.name: hashlib.sha256(path.read_bytes()).hexdigest()
            for path in self.package.iterdir() if path.name != 'release-manifest.json'}}))

    def command(self, args, **kwargs):
        self.calls.append(args)
        if 'enable' in args:
            for link in installer.LINKS:
                link.parent.mkdir(parents=True, exist_ok=True)
                link.symlink_to(installer.TIMER)
        return SimpleNamespace(returncode=0 if 'is-enabled' not in args or self.enabled else 1)

    def tearDown(self):
        for item in reversed(self.patches):
            item.stop()
        self.tmp.cleanup()

    def test_stages_no_start_with_complete_absent_recovery_inventory(self):
        targets = installer.targets()
        self.assertEqual(len(targets), 7)
        backup = self.root / 'backup'
        backup.mkdir(mode=0o700)
        (backup / 'files').mkdir(mode=0o700)
        for name in ('files.json', 'database-layout.json', 'private-configuration.tar.gz', 'database.dump'):
            path = backup / name
            path.write_text('[]' if name == 'files.json' else '{}')
            path.chmod(0o600)
        upgrade.refresh_backup_integrity(backup)
        support.augment_snapshot(backup, targets)
        upgrade.validate_backup(backup)
        self.assertEqual(installer.install(), 'managed')
        for name in installer.PROGRAMS:
            self.assertEqual((self.tools / name).read_bytes(), (self.package / name).read_bytes())
            self.assertEqual((self.tools / name).stat().st_mode & 0o777, 0o644)
        self.assertTrue(all(link.is_symlink() for link in installer.LINKS))
        self.assertFalse(any('start' in call for call in self.calls))
        # Rollback removes exactly the new programs, units and links.
        upgrade.restore_files(backup)
        self.assertTrue(all(not path.exists() and not path.is_symlink() for path in targets))

    def test_only_enabled_timer_starts_after_activation(self):
        installer.install()
        self.calls.clear()
        installer.install(True)
        self.assertIn(['systemctl', 'start', installer.TIMER.name], self.calls)
        self.assertFalse(any('enable' in call for call in self.calls))
        self.assertFalse(any(installer.UNIT.name in call and 'start' in call for call in self.calls))

    def test_both_restore_and_update_holds_defer_activation(self):
        installer.install()
        for hold in (installer.RESTORE_HOLD, installer.MAINTENANCE):
            hold.touch()
            self.calls.clear()
            installer.install(True)
            self.assertFalse(any('start' in call for call in self.calls))
            hold.unlink()

    def test_disabled_choice_and_idempotent_files_preserved(self):
        installer.install()
        self.enabled = False
        before = {path: path.stat().st_mtime_ns for path in installer.targets() if path.is_file()}
        for link in installer.LINKS:
            link.unlink()
        self.calls.clear()
        installer.install(True)
        self.assertFalse(any('enable' in call or 'start' in call for call in self.calls))
        self.assertEqual(before, {path: path.stat().st_mtime_ns for path in before})

    def test_custom_etc_unit_preserved_before_any_mutation(self):
        installer.UNIT.parent.mkdir()
        installer.UNIT.write_text('operator configuration')
        self.assertEqual(installer.install(True), 'custom')
        self.assertEqual(installer.UNIT.read_text(), 'operator configuration')
        self.assertFalse(self.tools.exists())
        self.assertEqual(self.calls, [])

    def test_vendor_unit_preserved_before_any_mutation(self):
        self.loaded = 'loaded'
        self.assertEqual(installer.install(True), 'custom')
        self.assertFalse(self.tools.exists())
        self.assertEqual(self.calls, [])

    def test_linked_unit_or_foreign_enablement_refused(self):
        installer.UNIT.parent.mkdir()
        foreign = self.root / 'foreign'
        foreign.write_text('foreign')
        installer.UNIT.symlink_to(foreign)
        with self.assertRaises(ValueError):
            installer.install()
        self.assertEqual(foreign.read_text(), 'foreign')
        installer.UNIT.unlink()
        link = installer.LINKS[0]
        link.parent.mkdir()
        link.symlink_to(foreign)
        with self.assertRaises(ValueError):
            installer.install()
        self.assertFalse(self.tools.exists())

    def test_invalid_manifest_refused(self):
        (self.package / 'phone-health.php').write_text('changed')
        with self.assertRaises(ValueError):
            installer.install()
        self.assertFalse(self.tools.exists())

    def test_installed_activation_uses_no_absent_package_manifest(self):
        installer.install()
        self.calls.clear()
        with patch.object(installer, 'PACKAGE', self.tools):
            installer.install(True)
        self.assertIn(['systemctl', 'start', installer.TIMER.name], self.calls)
        self.assertFalse((self.tools / 'release-manifest.json').exists())

    def test_changed_installed_helper_permissions_refused(self):
        installer.install()
        (self.tools / 'phone-health.php').chmod(0o666)
        self.calls.clear()
        with patch.object(installer, 'PACKAGE', self.tools), self.assertRaises(ValueError):
            installer.install(True)
        self.assertEqual(self.calls, [])


class PhoneHealthWorker(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='.health-worker-', dir=ROOT)
        self.root = Path(self.tmp.name)
        self.entry = self.root / 'phone-health.php'
        self.entry.write_text('private fixture')
        self.php = self.root / 'php-fixture'
        self.php.write_text('''#!/usr/bin/python3
import json,sys
if sys.argv[-1]=='registrations':
 print(json.dumps({'row_count':1,'rows':[{'sip_auth_user':'PRIVATE_AUTH_DO_NOT_LOG','network_ip':'192.0.2.44'}]}))
else:
 raw=json.load(sys.stdin)
 print(json.dumps({'available':raw is not None,'observed_contacts':1 if raw else 0,'checked_domains':1,'open':1,'new':1,'resolved':0,'queued':0,'private_do_not_log':'PRIVATE_AUTH_DO_NOT_LOG'}))
''')
        self.php.chmod(0o755)
        self.patches = [patch.object(worker, 'LOCK', self.root / 'upgrade.lock'),
                        patch.object(worker, 'MAINTENANCE', self.root / 'maintenance'),
                        patch.object(worker, 'RESTORE_HOLD', self.root / 'restore-hold'),
                        patch.object(worker, 'ENTRY', self.entry), patch.object(worker, 'PHP', self.php),
                        # Synthetic protocol fixtures live below the private root
                        # workspace. Native credential/sandbox checks have their
                        # own real subprocess and systemd controls below.
                        patch.object(worker, 'unprivileged_child', return_value=None)]
        for item in self.patches:
            item.start()

    def tearDown(self):
        for item in reversed(self.patches):
            item.stop()
        self.tmp.cleanup()

    def test_real_private_subprocess_only_returns_allowlisted_aggregates(self):
        result = worker.observe()
        self.assertTrue(result['available'])
        self.assertEqual(result['observed_contacts'], 1)
        self.assertNotIn('PRIVATE_AUTH', json.dumps(result))
        self.assertNotIn('192.0.2.44', json.dumps(result))
        self.assertNotIn('private_do_not_log', result)
        self.assertEqual(worker.LOCK.stat().st_mode & 0o777, 0o600)

    def test_real_lock_busy_deferred_without_child(self):
        with worker.LOCK.open('w') as stream:
            worker.LOCK.chmod(0o600)
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with patch.object(worker.subprocess, 'run', side_effect=AssertionError('Child must not run')):
                self.assertEqual(worker.observe()['reason'], 'upgrade_or_restore')

    def test_maintenance_and_restore_hold_prevent_children(self):
        for path in (worker.MAINTENANCE, worker.RESTORE_HOLD):
            path.touch()
            with patch.object(worker.subprocess, 'run', side_effect=AssertionError('Child must not run')):
                self.assertEqual(worker.observe()['reason'], 'maintenance_or_restore_hold')
            path.unlink()

    def test_native_timeout_still_runs_unknown_observation(self):
        actual = subprocess.run
        def child(args, **kwargs):
            if args[-1] == 'registrations':
                self.assertEqual(kwargs['timeout'], 7)
                raise subprocess.TimeoutExpired(args, 7)
            self.assertEqual(kwargs['input'], b'null')
            self.assertEqual(kwargs['timeout'], 21)
            return actual(args, **kwargs)
        with patch.object(worker.subprocess, 'run', side_effect=child):
            result = worker.observe()
        self.assertFalse(result['available'])
        self.assertEqual(result['observed_contacts'], 0)

    def test_bad_native_json_still_means_unknown(self):
        actual = subprocess.run
        def child(args, **kwargs):
            if args[-1] == 'registrations':
                return SimpleNamespace(returncode=0, stdout=b'private non-json failure')
            return actual(args, **kwargs)
        with patch.object(worker.subprocess, 'run', side_effect=child):
            self.assertFalse(worker.observe()['available'])

    def test_linked_or_writable_entry_refused_before_children(self):
        self.entry.chmod(0o666)
        with self.assertRaises(ValueError):
            worker.observe()
        self.entry.unlink()
        self.entry.symlink_to(self.php)
        with self.assertRaises(ValueError):
            worker.observe()

    def test_unknown_and_private_result_values_refused(self):
        for raw in (b'[]', b'{"available":"false"}', b'{"available":true,"open":-1}',
                    b'{"available":true,"new":true}', b'{"available":true,"queued":2000001}'):
            with self.assertRaises(ValueError):
                worker.aggregate(raw)


class PhoneHealthSchema(unittest.TestCase):
    def test_actual_bootstrap_hooks_preserve_original_and_health_rows(self):
        result = subprocess.run(['php', str(ROOT / 'tests/debian_phone_health_schema.php')], cwd=ROOT,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True, timeout=30)
        receipt = json.loads(result.stdout)
        self.assertEqual(result.stderr, b'')
        self.assertEqual(receipt['branches'], ['fresh_admin', 'upgrade_migrate'])
        self.assertTrue(receipt['actual_isolated_postgresql'])
        self.assertTrue(receipt['all_original_and_health_rows_preserved'])
        self.assertFalse(receipt['full_installer_executed'])

    def test_real_child_is_www_data_without_capabilities_and_cannot_gain_privilege(self):
        code = '$s=file_get_contents("/proc/self/status");echo json_encode(["uid"=>posix_geteuid(),"gid"=>posix_getegid(),"groups"=>posix_getgroups(),"nnp"=>preg_match("/^NoNewPrivs:\\\\s+1$/m",$s)===1,"no_caps"=>preg_match("/^CapEff:\\\\s+0+$/m",$s)===1,"cannot_regain_root"=>!@posix_setuid(0)]);'
        result = subprocess.run(['/usr/bin/php', '-r', code], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                preexec_fn=worker.unprivileged_child, check=True, timeout=5)
        self.assertEqual(result.stderr, b'')
        self.assertEqual(json.loads(result.stdout), {'uid':33, 'gid':33, 'groups':[], 'nnp':True,
                                                     'no_caps':True, 'cannot_regain_root':True})


if __name__ == '__main__':
    unittest.main()
