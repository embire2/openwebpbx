#!/usr/bin/env python3
"""Exercise the legacy-updater recovery boundary using actual Linux files."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
def module(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT/relative)
    result = importlib.util.module_from_spec(spec); spec.loader.exec_module(result)
    return result
support = module('install_support', 'packaging/debian/install-support.py')
upgrade = module('recovery_upgrade', 'packaging/debian/upgrade.py')

class SupportRecovery(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='.support-test-',dir=ROOT)
        self.root = Path(self.temporary.name)
        self.backup = self.root/'upgrade-fixture';self.backup.mkdir(mode=0o700)
        (self.backup/'files').mkdir(mode=0o700)
        for name in ['files.json','database-layout.json','private-configuration.tar.gz','database.dump']:
            p=self.backup/name;p.write_text('[]' if name=='files.json' else '{}');p.chmod(0o600)
        upgrade.refresh_backup_integrity(self.backup)
        self.target=self.root/'tools/backups.py';self.target.parent.mkdir()
    def tearDown(self):self.temporary.cleanup()
    def test_previous_file_and_permissions_restore(self):
        self.target.write_text('previous helper');self.target.chmod(0o640)
        support.augment_snapshot(self.backup,[self.target])
        upgrade.validate_backup(self.backup)
        self.target.write_text('candidate helper');self.target.chmod(0o644)
        upgrade.restore_files(self.backup)
        self.assertEqual(self.target.read_text(),'previous helper')
        self.assertEqual(self.target.stat().st_mode&0o777,0o640)
    def test_new_helper_and_enablement_link_removed_on_rollback(self):
        link=self.root/'timer.wants/new.timer'
        support.augment_snapshot(self.backup,[self.target,link])
        self.target.write_text('candidate');link.parent.mkdir();link.symlink_to(self.target)
        upgrade.validate_backup(self.backup);upgrade.restore_files(self.backup)
        self.assertFalse(self.target.exists());self.assertFalse(link.is_symlink())
    def test_interruption_before_atomic_swap_keeps_original_recoverable(self):
        old=(self.backup/'files.json').read_bytes()
        self.target.write_text('previous')
        with patch.object(support,'exchange_directories',side_effect=OSError('Interrupted')):
            with self.assertRaises(OSError):support.augment_snapshot(self.backup,[self.target])
        self.assertEqual((self.backup/'files.json').read_bytes(),old)
        upgrade.validate_backup(self.backup);self.assertEqual(self.target.read_text(),'previous')
        self.assertEqual(list(self.root.glob('.support-snapshot-*')),[])
    def test_double_install_retains_original_snapshot(self):
        self.target.write_text('previous')
        support.augment_snapshot(self.backup,[self.target])
        self.target.write_text('candidate')
        support.augment_snapshot(self.backup,[self.target])
        upgrade.validate_backup(self.backup);upgrade.restore_files(self.backup)
        self.assertEqual(self.target.read_text(),'previous')
    def test_unknown_symbolic_link_refused_before_change(self):
        source=self.root/'private';source.write_text('keep')
        self.target.symlink_to(source)
        with self.assertRaises(ValueError):support.augment_snapshot(self.backup,[self.target])
        upgrade.validate_backup(self.backup);self.assertEqual(source.read_text(),'keep')
    def test_existing_updater_file_inventory_is_retained(self):
        old_target=self.root/'original.php';old_target.write_text('old')
        support.augment_snapshot(self.backup,[old_target])
        first=json.loads((self.backup/'files.json').read_text())
        support.augment_snapshot(self.backup,[self.target])
        self.assertEqual(json.loads((self.backup/'files.json').read_text())[0],first[0])
        upgrade.validate_backup(self.backup)

if __name__=='__main__':unittest.main()
