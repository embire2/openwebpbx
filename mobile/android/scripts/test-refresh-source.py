#!/usr/bin/env python3
"""Exercise actual source-refresher safety/admission functions without external writes."""
import importlib.util
import io
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('source_refresh',Path(__file__).with_name('refresh-source.py'))
refresh=importlib.util.module_from_spec(spec);spec.loader.exec_module(refresh)

class SourceRefreshTests(unittest.TestCase):
    def member(self,name,kind=tarfile.REGTYPE,target=''):
        item=tarfile.TarInfo(name);item.type=kind;item.linkname=target;return item
    def test_ordinary_file_directory_and_owned_symlink(self):
        for item in [self.member('openwebpbx-android/linphone-sdk-5.5.23/a.c'),self.member('openwebpbx-android/linphone-sdk-5.5.23/',tarfile.DIRTYPE),self.member('openwebpbx-android/linphone-sdk-5.5.23/include/a',tarfile.SYMTYPE,'../a.c')]:
            self.assertTrue(refresh.safe(item).startswith(refresh.PREFIX))
    def test_unsafe_paths_and_member_kinds_refused(self):
        for name in ['/absolute','../outside','openwebpbx-android/../outside','openwebpbx-android//file','openwebpbx-android/a\\b','openwebpbx-android/a\n']:
            with self.subTest(name=name),self.assertRaises(ValueError):refresh.safe(self.member(name))
        for kind in [tarfile.LNKTYPE,tarfile.CHRTYPE,tarfile.BLKTYPE,tarfile.FIFOTYPE]:
            with self.subTest(kind=kind),self.assertRaises(ValueError):refresh.safe(self.member('openwebpbx-android/a',kind))
    def test_symlink_escape_and_oversized_members_refused(self):
        for target in ['/etc/passwd','../../../outside','a\\b']:
            with self.subTest(target=target),self.assertRaises(ValueError):refresh.safe(self.member('openwebpbx-android/sdk/a',tarfile.SYMTYPE,target))
        item=self.member('openwebpbx-android/a');item.size=256*1024*1024+1
        with self.assertRaises(ValueError):refresh.safe(item)
    def test_actual_archive_scan_refuses_duplicate_members(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'duplicate.tar.gz'
            with tarfile.open(path,'w:gz') as archive:
                for _ in range(2):archive.addfile(self.member('openwebpbx-android/same'))
            with self.assertRaises(ValueError):refresh.scan_baseline(path)
    def test_actual_archive_scan_returns_exact_dependency_and_version_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'owned.tar.gz'
            with tarfile.open(path,'w:gz') as archive:
                for name,data in [('dependency-sources/RUNTIME-DEPENDENCIES.txt',b'one:runtime:1\n'),('VERSION',b'1.0.18\n'),('linphone-sdk-5.5.23/a.c',b'original SDK')]:
                    item=self.member(refresh.PREFIX+name);item.size=len(data);archive.addfile(item,io.BytesIO(data))
            self.assertEqual((b'one:runtime:1\n',b'1.0.18\n',1),refresh.scan_baseline(path))
    def test_runtime_version_and_sdk_inventory_changes_refused(self):
        refresh.require_compatible(b'exact',b'1.0.18\n',1000,b'exact')
        for values in [(b'changed',b'1.0.18\n',1000,b'exact'),(b'exact',b'1.0.17\n',1000,b'exact'),(b'exact',b'1.0.18\n',999,b'exact'),(None,b'1.0.18\n',1000,b'exact')]:
            with self.subTest(values=values),self.assertRaises(ValueError):refresh.require_compatible(*values)
    def test_main_rejects_foreign_archive_before_creating_output(self):
        with tempfile.TemporaryDirectory() as directory:
            base=Path(directory)/'foreign';base.write_bytes(b'not the original published source')
            inventory=Path(directory)/'runtime';inventory.write_bytes(b'exact');output=Path(directory)/'output.tar.gz'
            with patch.object(sys,'argv',['refresh-source','--base-source',str(base),'--runtime-inventory',str(inventory),'--output',str(output)]),self.assertRaises(ValueError):refresh.main()
            self.assertFalse(output.exists())
    def test_existing_or_symlink_output_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            output=Path(directory)/'original';output.write_bytes(b'original evidence')
            link=Path(directory)/'output';link.symlink_to(output)
            for path in [output,link]:
                with patch.object(sys,'argv',['refresh-source','--base-source','unused','--runtime-inventory','unused','--output',str(path)]),self.assertRaises(FileExistsError):refresh.main()
            self.assertEqual(b'original evidence',output.read_bytes())

if __name__=='__main__':unittest.main()
