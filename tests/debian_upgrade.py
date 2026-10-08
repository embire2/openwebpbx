#!/usr/bin/env python3
"""Offline regression checks for release validation and rollback-safe file copying."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'packaging/debian/upgrade.py'
spec = importlib.util.spec_from_file_location('openweb_upgrade', SOURCE)
upgrade = importlib.util.module_from_spec(spec)
spec.loader.exec_module(upgrade)


class UpgradeChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.files = [
            'VERSION', 'web/resources/require.php', 'server/OpenWebPbx.Server', 'bootstrap.php',
            'web/app/switch/resources/scripts/app/xml_handler/resources/scripts/configuration/acl.conf.lua',
            'web/app/switch/resources/scripts/app/xml_handler/resources/scripts/dialplan/dialplan.lua',
        ]
        for name in self.files:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('1.0.3\n' if name == 'VERSION' else 'fixture\n')
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


if __name__ == '__main__':
    unittest.main()
