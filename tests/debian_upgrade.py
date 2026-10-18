#!/usr/bin/env python3
"""Offline regression checks for release validation and rollback-safe file copying."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace
import io
import sys

SOURCE = Path(__file__).resolve().parents[1] / 'packaging/debian/upgrade.py'
spec = importlib.util.spec_from_file_location('openweb_upgrade', SOURCE)
upgrade = importlib.util.module_from_spec(spec)
spec.loader.exec_module(upgrade)


class UpgradeChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.files = [
            'VERSION', 'web/VERSION', 'web/resources/require.php', 'server/OpenWebPbx.Server', 'bootstrap.php',
            'web/app/switch/resources/scripts/app/xml_handler/resources/scripts/configuration/acl.conf.lua',
            'web/app/switch/resources/scripts/app/xml_handler/resources/scripts/dialplan/dialplan.lua',
        ]
        for name in self.files:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('1.0.3\n' if Path(name).name == 'VERSION' else 'fixture\n')
        self.manifest = {'version': '1.0.3', 'files': {
            name: hashlib.sha256((self.root / name).read_bytes()).hexdigest() for name in self.files}}
        self.save()

    def save(self):
        (self.root / 'release-manifest.json').write_text(json.dumps(self.manifest))

    def tearDown(self):
        self.temporary.cleanup()

    def test_valid_complete_release(self):
        self.assertEqual(upgrade.validate_manifest(self.root)['version'], '1.0.3')

    def test_tampered_payload_refused(self):
        (self.root / 'bootstrap.php').write_text('changed')
        with self.assertRaises(ValueError):
            upgrade.validate_manifest(self.root)

    def test_unlisted_configuration_refused(self):
        (self.root / 'server/runtime.json').write_text('{}')
        with self.assertRaises(ValueError):
            upgrade.validate_manifest(self.root)

    def test_parent_escape_refused(self):
        self.manifest['files']['../outside.php'] = '0' * 64
        self.save()
        with self.assertRaises(ValueError):
            upgrade.validate_manifest(self.root)

    def test_symlink_payload_refused(self):
        path = self.root / 'bootstrap.php'
        path.unlink()
        path.symlink_to(self.root / 'web/resources/require.php')
        with self.assertRaises(ValueError):
            upgrade.validate_manifest(self.root)

    def test_missing_native_handler_refused(self):
        del self.manifest['files'][self.files[-1]]
        self.save()
        with self.assertRaises(ValueError):
            upgrade.validate_manifest(self.root)

    def test_mismatched_version_refused(self):
        self.manifest['version'] = '1.0.2'
        self.save()
        with self.assertRaises(ValueError):
            upgrade.validate_manifest(self.root)

    def test_mixed_web_version_refused(self):
        (self.root/'web/VERSION').write_text('1.0.2\n')
        self.manifest['files']['web/VERSION']=hashlib.sha256((self.root/'web/VERSION').read_bytes()).hexdigest()
        self.save()
        with self.assertRaises(ValueError):upgrade.validate_manifest(self.root)

    def test_replacement_preserves_existing_permissions(self):
        target = self.root / 'installed.php'
        target.write_text('previous')
        target.chmod(0o640)
        upgrade.atomic_copy(self.root / 'bootstrap.php', target)
        self.assertEqual(target.read_text(), 'fixture\n')
        self.assertEqual(target.stat().st_mode & 0o777, 0o640)
        self.assertEqual(list(self.root.glob('.openweb-update-*')), [])

    def test_new_app_directories_remain_readable_under_private_umask(self):
        before = os.umask(0o077)
        try:
            target = self.root / 'app/mobile/index.php'
            upgrade.atomic_copy(self.root / 'bootstrap.php', target)
            self.assertEqual(target.parent.stat().st_mode & 0o777, 0o755)
            self.assertEqual(target.stat().st_mode & 0o777, 0o644)
        finally:
            os.umask(before)

    def test_proxy_reload_validates_before_touching_active_runtime(self):
        commands=[]
        with patch.object(upgrade.subprocess,'run',return_value=SimpleNamespace(returncode=0)):
            upgrade.reload_web_proxy(lambda command:commands.append(command))
        self.assertEqual(commands,[['nginx','-t'],['systemctl','reload','nginx']])

    def test_boot_recovery_leaves_inactive_proxy_for_normal_start(self):
        commands=[]
        with patch.object(upgrade.subprocess,'run',return_value=SimpleNamespace(returncode=3)):
            upgrade.reload_web_proxy(lambda command:commands.append(command))
        self.assertEqual(commands,[['nginx','-t']])

    def test_invalid_proxy_never_reloads(self):
        commands=[]
        def fail(command):
            commands.append(command)
            raise RuntimeError('Invalid fixture configuration')
        with self.assertRaises(RuntimeError):upgrade.reload_web_proxy(fail)
        self.assertEqual(commands,[['nginx','-t']])

    def test_uncommitted_or_finalized_update_cannot_retire_legacy_importer(self):
        with patch.object(upgrade.subprocess,'run',side_effect=AssertionError('Unexpected service mutation')):
            for state in ['migrating','validating','rolled_back','recovery_required']:
                upgrade.finalize_completed({'state':state})
            upgrade.finalize_completed({'state':'completed','finalization':'completed'})
            upgrade.finalize_completed(None)

    def test_committed_version_mismatch_refuses_before_service_mutation(self):
        web=self.root/'web';web.mkdir(exist_ok=True);(web/'VERSION').write_text('1.0.16')
        with patch.object(upgrade,'WEB',web),self.assertRaises(upgrade.RecoveryRequired):
            upgrade.finalize_completed({'state':'completed','version':'1.0.15'})

    def test_committed_upgrade_finalizes_only_after_healthy_version_and_backup(self):
        web=self.root/'web';web.mkdir(exist_ok=True);(web/'VERSION').write_text('1.0.16')
        backups=self.root/'backups';backups.mkdir();backup=backups/'upgrade-fixture';backup.mkdir()
        journal={'state':'completed','version':'1.0.16','backup_path':str(backup)}
        commands=[];saved=[];validated=[]
        response=io.BytesIO(json.dumps({'state':'Running','version':'1.0.16'}).encode())
        with patch.object(upgrade,'WEB',web),patch.object(upgrade,'BACKUPS',backups),patch.object(upgrade.urllib.request,'urlopen',return_value=response),patch.object(upgrade,'validate_backup',side_effect=lambda value:validated.append(value)),patch.object(upgrade.subprocess,'run',side_effect=lambda command,**kwargs:commands.append(command) or SimpleNamespace(returncode=0)),patch.object(upgrade.subprocess,'check_output',return_value='loaded\n'),patch.object(upgrade,'save_journal',side_effect=lambda *args,**kwargs:saved.append((args,kwargs))):
            upgrade.finalize_completed(journal)
        self.assertEqual(validated,[backup])
        self.assertLess(commands.index(['nginx','-t']),commands.index(['systemctl','reload','nginx']))
        self.assertLess(commands.index(['systemctl','reload','nginx']),commands.index(['systemctl','stop','xml_cdr.service']))
        self.assertIn(['systemctl','disable','xml_cdr.service'],commands)
        self.assertEqual(saved[0][1],{'finalization':'completed'})

    def test_completed_boot_recovery_defers_health_until_worker_can_start(self):
        updates=self.root/'updates';updates.mkdir()
        journal=updates/'journal.json';journal.write_text(json.dumps({'state':'completed','version':'1.0.16'}))
        maintenance=updates/'maintenance';maintenance.write_text('{}')
        original_path=Path
        def isolated_path(value):
            return self.root/'isolated.lock' if value=='/run/openwebpbx-upgrade.lock' else original_path(value)
        before=os.umask(0o077)
        try:
            with patch.object(upgrade,'UPDATES',updates),patch.object(upgrade,'JOURNAL',journal),patch.object(upgrade,'MAINTENANCE',maintenance),patch.object(upgrade,'Path',side_effect=isolated_path),patch.object(upgrade.os,'geteuid',return_value=0),patch.object(sys,'argv',['upgrade.py','--recover','--boot']),patch.object(upgrade,'finalize_completed',side_effect=AssertionError('Boot cannot require pre-service health')):
                upgrade.main()
            self.assertFalse(maintenance.exists())
        finally:os.umask(before)


if __name__ == '__main__':
    unittest.main()
