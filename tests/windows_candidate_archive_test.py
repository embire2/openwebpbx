#!/usr/bin/env python3
"""Candidate ZIP integrity and private-data exclusion; no installed machine data."""
import hashlib
import importlib.util
import json
from pathlib import Path
import stat
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location('candidate', Path(__file__).with_name('windows_candidate_archive.py'))
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)


class CandidateArchive(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name)/'candidate.zip'
        self.root = 'openwebpbx-1.0.13-windows-x64/'

    def archive(self, files=None, *, extra=None, hashes=None, version='1.0.13', symlink=None):
        files = files if files is not None else {'web/index.php': b'public source'}
        hashes = hashes if hashes is not None else {name: hashlib.sha256(data).hexdigest() for name, data in files.items()}
        with zipfile.ZipFile(self.path, 'w') as archive:
            archive.writestr(self.root+'release-manifest.json', json.dumps({'version': version, 'files': hashes}))
            for name, data in files.items():
                if name == symlink:
                    item = zipfile.ZipInfo(self.root+name)
                    item.create_system = 3
                    item.external_attr = (stat.S_IFLNK | 0o777) << 16
                    archive.writestr(item, data)
                else:
                    archive.writestr(self.root+name, data)
            for name, data in (extra or {}).items():
                archive.writestr(self.root+name, data)

    def reject(self):
        with self.assertRaises((ValueError, zipfile.BadZipFile)):
            c.verify(self.path, '1.0.13')

    def test_exact_original_archive_and_legitimate_windows_flag_names(self):
        files = {"web/flags/Bolivia, Plurinational State of.png": b'public',
                 'web/flags/Cocos (Keeling) Islands.png': b'public',
                 "web/flags/Côte d'Ivoire.png": b'public'}
        self.archive(files)
        expected = hashlib.sha256(self.path.read_bytes()).hexdigest()
        result = c.verify(self.path, '1.0.13', expected)
        self.assertEqual(result['files'], 3)
        self.assertEqual(result['sha256'], expected)

    def test_original_zip_hash_cannot_change(self):
        self.archive()
        with self.assertRaises(ValueError): c.verify(self.path, '1.0.13', '0'*64)

    def test_unlisted_file(self):
        self.archive(extra={'web/unlisted.txt': b'not inventoried'})
        self.reject()

    def test_file_hash_corruption(self):
        self.archive(hashes={'web/index.php': '0'*64})
        self.reject()

    def test_case_collisions(self):
        self.archive({'web/index.php': b'one', 'web/INDEX.php': b'two'})
        self.reject()

    def test_link(self):
        self.archive({'web/index.php': b'outside'}, symlink='web/index.php')
        self.reject()

    def test_encryption_flag(self):
        self.archive()
        data = bytearray(self.path.read_bytes())
        at = data.index(b'PK\x01\x02')
        data[at+8] |= 1
        self.path.write_bytes(data)
        self.reject()

    def test_runtime_private_names(self):
        for name in ('web/.env', 'config.conf', 'runtime.json', 'installation.json',
                     'setup-secrets.json', 'phone-tls.json', 'phone.key', 'phone.pfx',
                     'database.dump', 'original.owpbx'):
            with self.subTest(name=name):
                self.archive({name: b'private fixture'})
                self.reject()

    def test_private_pem_under_unexpected_name(self):
        self.archive({'unusual.pem': b'-----BEGIN PRIVATE KEY-----\nfictional fixture\n'})
        self.reject()

    def test_public_upstream_source_fixture_is_scoped(self):
        self.archive({'codec-source/tests/example.key': b'public upstream source fixture'})
        self.assertEqual(c.verify(self.path, '1.0.13')['files'], 1)

    def test_windows_forbidden_or_traversing_paths(self):
        for name in ('../private', 'web/../private', 'web/COM1.txt', 'web/LPT¹.txt',
                     'web/name.', 'web/name ', 'web/alternate:stream', 'web/back\\slash'):
            with self.subTest(name=name):
                self.archive({name: b'fixture'})
                self.reject()

    def test_generated_codec_binary_is_not_exported(self):
        self.archive({'engine/mod/mod_bcg729.dll': b'local build only'})
        self.reject()

    def test_version_mismatch(self):
        self.archive(version='1.0.12')
        self.reject()

    def test_unexpected_root(self):
        self.root = 'untrusted-root/'
        self.archive()
        self.reject()


if __name__ == '__main__': unittest.main()
