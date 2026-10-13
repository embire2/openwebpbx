#!/usr/bin/env python3
"""Real-file registrar replacement and compatibility with the legacy rollback."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
def load(name,path):
    spec=importlib.util.spec_from_file_location(name,ROOT/path);result=importlib.util.module_from_spec(spec);spec.loader.exec_module(result);return result
sofia=load('restore_sofia','packaging/debian/restore-sofia.py')
support=load('sofia_support','packaging/debian/install-support.py')
upgrade=load('sofia_upgrade','packaging/debian/upgrade.py')

class Registrar(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='.sofia-test-',dir=ROOT);self.root=Path(self.temp.name);self.target=self.root/'mod_sofia.so';self.target.write_bytes(b'previous-module');self.target.chmod(0o640)
        self.library=self.root/'libfreeswitch.so.1.0.0';self.library.write_bytes(b'pinned-library')
        self.module=b'reviewed-module'*256;self.archive=self.root/'engine.tar.gz';self.state='inactive';self.write_archive()
        self.patches=[patch.object(sofia,'TARGET',self.target),patch.object(sofia,'LIBRARY',self.library),patch.object(sofia,'MODULE_SHA256',hashlib.sha256(self.module).hexdigest()),patch.object(sofia,'LIBRARY_SHA256',hashlib.sha256(self.library.read_bytes()).hexdigest()),patch.object(sofia.subprocess,'run',side_effect=self.systemctl)]
        for p in self.patches:p.start()
    def tearDown(self):
        for p in reversed(self.patches):p.stop()
        self.temp.cleanup()
    def systemctl(self,command,**kwargs):
        self.assertEqual(command,['systemctl','show','freeswitch','--property=ActiveState','--value'])
        class Result:stdout=self.state+'\n'
        return Result()
    def write_archive(self,content=None,duplicate=False):
        content=self.module if content is None else content
        with tarfile.open(self.archive,'w:gz') as out:
            for _ in range(2 if duplicate else 1):
                member=tarfile.TarInfo(sofia.ENTRY);member.size=len(content);member.mode=0o755;out.addfile(member,io.BytesIO(content))
        self.manifest={'files':{'engine.tar.gz':hashlib.sha256(self.archive.read_bytes()).hexdigest()}}
    def test_replacement_and_repeat(self):
        content=sofia.payload(self.root,self.manifest);self.assertTrue(sofia.install(content));self.assertEqual(self.target.read_bytes(),self.module);self.assertEqual(self.target.stat().st_mode&0o777,0o755);self.assertIsNone(sofia.payload(self.root,self.manifest));self.assertFalse(sofia.install(None))
    def test_signed_archive_checksum_required(self):
        self.archive.write_bytes(b'damaged')
        with self.assertRaises(ValueError):sofia.payload(self.root,self.manifest)
        self.assertEqual(self.target.read_bytes(),b'previous-module')
    def test_reviewed_module_bytes_required(self):
        self.write_archive(content=b'wrong-module'*256)
        with self.assertRaises(ValueError):sofia.payload(self.root,self.manifest)
    def test_duplicate_module_refused(self):
        self.write_archive(duplicate=True)
        with self.assertRaises(ValueError):sofia.payload(self.root,self.manifest)
    def test_other_engine_refused(self):
        self.library.write_bytes(b'other-engine')
        with self.assertRaises(ValueError):sofia.payload(self.root,self.manifest)
        self.assertEqual(self.target.read_bytes(),b'previous-module')
    def test_running_or_starting_engine_refused(self):
        for self.state in ('active','activating','deactivating','unknown'):
            with self.assertRaises(RuntimeError):sofia.payload(self.root,self.manifest)
        self.assertEqual(self.target.read_bytes(),b'previous-module')
    def test_start_between_validation_and_install_refused(self):
        content=sofia.payload(self.root,self.manifest);self.state='active'
        with self.assertRaises(RuntimeError):sofia.install(content)
        self.assertEqual(self.target.read_bytes(),b'previous-module')
    def test_symlink_refused(self):
        previous=self.root/'previous';self.target.rename(previous);self.target.symlink_to(previous)
        with self.assertRaises(ValueError):sofia.payload(self.root,self.manifest)
        self.assertEqual(previous.read_bytes(),b'previous-module')
    def test_atomic_swap_failure_preserves_original(self):
        content=sofia.payload(self.root,self.manifest)
        with patch.object(sofia.os,'replace',side_effect=OSError('fixture interruption')),self.assertRaises(OSError):sofia.install(content)
        self.assertEqual(self.target.read_bytes(),b'previous-module');self.assertEqual(list(self.root.glob('.openweb-sofia-*')),[])
    def test_legacy_rollback_recovers_bytes_and_permissions(self):
        backup=self.root/'upgrade-fixture';backup.mkdir(mode=0o700);(backup/'files').mkdir(mode=0o700)
        for name in ('files.json','database-layout.json','private-configuration.tar.gz','database.dump'):
            f=backup/name;f.write_text('[]' if name=='files.json' else '{}');f.chmod(0o600)
        upgrade.refresh_backup_integrity(backup);support.augment_snapshot(backup,[self.target]);upgrade.validate_backup(backup)
        sofia.install(sofia.payload(self.root,self.manifest));upgrade.restore_files(backup)
        self.assertEqual(self.target.read_bytes(),b'previous-module');self.assertEqual(self.target.stat().st_mode&0o777,0o640)

if __name__=='__main__':unittest.main()
