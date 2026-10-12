#!/usr/bin/env python3
"""Exercise the legacy-updater recovery boundary using actual Linux files."""
import importlib.util
import json
import os
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
notifications = module('notification_storage', 'packaging/debian/install-mobile-notifications.py')

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

class NotificationStorage(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='.notification-test-', dir=ROOT)
        self.state = Path(self.temporary.name)
        self.directory = self.state/'mobile-notifications'
        self.current = self.directory/'config.json'
        self.lock = self.directory/'config.json.lock'
        self.legacy = self.state/'mobile-push.json'
        self.before = (self.state.stat().st_mode, self.state.stat().st_uid, self.state.stat().st_gid)
    def tearDown(self):self.temporary.cleanup()
    def test_fresh_private_child_does_not_change_state_parent(self):
        notifications.install(self.state)
        st=self.directory.stat()
        self.assertEqual((st.st_mode&0o777,st.st_uid,st.st_gid),(0o700,33,33))
        self.assertEqual((self.state.stat().st_mode,self.state.stat().st_uid,self.state.stat().st_gid),self.before)
        self.assertFalse(self.current.exists());self.assertFalse(self.lock.exists())
    def test_legacy_bytes_and_identity_preserved_and_repeat_is_safe(self):
        value=b'{ "vapid_private_key": "private fixture", "vapid_public_key": "public fixture" }\n'
        self.legacy.write_bytes(value);self.legacy.chmod(0o600)
        before=self.legacy.stat()
        notifications.install(self.state);notifications.install(self.state)
        self.assertEqual(self.current.read_bytes(),value);self.assertEqual(self.legacy.read_bytes(),value)
        st=self.current.stat();self.assertEqual((st.st_mode&0o777,st.st_uid,st.st_gid),(0o600,33,33))
        after=self.legacy.stat();self.assertEqual((before.st_mode,before.st_uid,before.st_gid),(after.st_mode,after.st_uid,after.st_gid))
    def test_current_config_wins_and_existing_file_permissions_recover(self):
        notifications.ensure_directory(self.directory)
        self.current.write_bytes(b'current fixture');self.current.chmod(0o640)
        self.lock.write_bytes(b'lock fixture');self.lock.chmod(0o644)
        self.legacy.write_bytes(b'older fixture')
        backup=self.state/'upgrade-fixture';backup.mkdir(mode=0o700);(backup/'files').mkdir()
        for name in ['files.json','database-layout.json','private-configuration.tar.gz','database.dump']:
            p=backup/name;p.write_text('[]' if name=='files.json' else '{}');p.chmod(0o600)
        upgrade.refresh_backup_integrity(backup)
        support.augment_snapshot(backup,[self.current,self.lock])
        notifications.install(self.state)
        self.assertEqual(self.current.read_bytes(),b'current fixture')
        upgrade.validate_backup(backup);upgrade.restore_files(backup)
        self.assertEqual((self.current.stat().st_mode&0o777,self.current.stat().st_uid,self.current.stat().st_gid),(0o640,0,0))
        self.assertEqual((self.lock.stat().st_mode&0o777,self.lock.stat().st_uid,self.lock.stat().st_gid),(0o644,0,0))
        self.assertEqual(self.lock.read_bytes(),b'lock fixture')
    def test_new_config_lock_and_helper_are_removed_by_legacy_recovery(self):
        backup=self.state/'upgrade-fixture';backup.mkdir(mode=0o700);(backup/'files').mkdir()
        for name in ['files.json','database-layout.json','private-configuration.tar.gz','database.dump']:
            p=backup/name;p.write_text('[]' if name=='files.json' else '{}');p.chmod(0o600)
        upgrade.refresh_backup_integrity(backup)
        helper=self.state/'notification-helper.py'
        support.augment_snapshot(backup,[self.current,self.lock,helper])
        self.legacy.write_bytes(b'private legacy fixture')
        notifications.install(self.state);self.lock.write_bytes(b'');helper.write_bytes(b'new helper')
        upgrade.validate_backup(backup);upgrade.restore_files(backup)
        self.assertFalse(self.current.exists());self.assertFalse(self.lock.exists());self.assertFalse(helper.exists())
        self.assertTrue(self.directory.is_dir());self.assertEqual(list(self.directory.iterdir()),[])
        self.assertEqual(self.legacy.read_bytes(),b'private legacy fixture')
    def test_unexpected_directory_permissions_refused_before_change(self):
        self.directory.mkdir(mode=0o755)
        self.legacy.write_bytes(b'keep fixture')
        with self.assertRaises(ValueError):notifications.install(self.state)
        self.assertFalse(self.current.exists());self.assertEqual(self.legacy.read_bytes(),b'keep fixture')
    def test_writable_state_parent_refused(self):
        self.state.chmod(0o770)
        with self.assertRaises(ValueError):notifications.install(self.state)
        self.assertFalse(self.directory.exists())
    def test_symlink_and_hardlinked_legacy_refused(self):
        source=self.state/'source';source.write_bytes(b'keep fixture')
        self.legacy.symlink_to(source)
        with self.assertRaises(ValueError):notifications.install(self.state)
        self.legacy.unlink();os.link(source,self.legacy)
        with self.assertRaises(ValueError):notifications.install(self.state)
        self.assertFalse(self.directory.exists());self.assertEqual(source.read_bytes(),b'keep fixture')
    def test_oversized_legacy_refused(self):
        self.legacy.write_bytes(b'x'*(notifications.MAX_CONFIG+1))
        with self.assertRaises(ValueError):notifications.install(self.state)
        self.assertFalse(self.directory.exists())
    def test_interrupted_copy_does_not_publish_config(self):
        self.legacy.write_bytes(b'keep fixture')
        with patch.object(notifications.os,'replace',side_effect=OSError('Interrupted')):
            with self.assertRaises(OSError):notifications.install(self.state)
        self.assertFalse(self.current.exists());self.assertEqual(list(self.directory.iterdir()),[])
        self.assertEqual(self.legacy.read_bytes(),b'keep fixture')

if __name__=='__main__':unittest.main()
