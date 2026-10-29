"""Real archive/hash/FS controls; the ISO executable is an explicit adapter."""
from pathlib import Path
import hashlib
import importlib.util
import io
import json
import os
import shutil
import tarfile
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('image_media',ROOT/'packaging/debian/image-media.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)


class ImageMedia(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='pbx-installer-media-');self.root=Path(self.tmp.name);self.archive=self.root/'openwebpbx-1.0.22-debian13-amd64.tar.gz'
        self.payload={name:b'Public installer '+name.encode()for name in ['install.sh','configure.py','bootstrap.php','engine.tar.gz','server/OpenWebPbx.Server','updater/OpenWebPbx.Updater','onboarding.py','onboarding.php','webhotel-onboarding.py','web/resources/keys/installation-authority.pem']}
        self.write()
    def tearDown(self):self.tmp.cleanup()
    def write(self,version='1.0.22',extra=None,bad_digest=False):
        prefix='openwebpbx-'+version+'-debian13-amd64';manifest={'version':version,'files':{k:hashlib.sha256(v).hexdigest()for k,v in self.payload.items()}}
        if bad_digest:manifest['files']['install.sh']='a'*64
        values={**self.payload,'release-manifest.json':json.dumps(manifest).encode()}
        with tarfile.open(self.archive,'w:gz')as tar:
            directory=tarfile.TarInfo(prefix);directory.type=tarfile.DIRTYPE;directory.mode=0o755;tar.addfile(directory)
            for name,content in values.items():
                item=tarfile.TarInfo(prefix+'/'+name);item.mode=0o644;item.size=len(content);tar.addfile(item,io.BytesIO(content))
            if extra:tar.addfile(extra)
        self.archive.chmod(0o600);self.sha=m.digest(self.archive)
    def test_complete_archive_identity_and_all_payload_hashes(self):
        value=m.inspect_archive(self.archive,self.sha);self.assertEqual(value['version'],'1.0.22');self.assertEqual(value['payload_files'],len(self.payload));self.assertEqual(value['volume_label'],'OPENWEBPBX1022');self.assertEqual(value['archive_sha256'],self.sha)
        self.write(bad_digest=True)
        with self.assertRaises(ValueError):m.inspect_archive(self.archive,self.sha)
    def test_wrong_outer_digest_and_incomplete_or_foreign_version_refuse(self):
        with self.assertRaises(ValueError):m.inspect_archive(self.archive,'0'*64)
        self.archive.chmod(0o666)
        with self.assertRaises(ValueError):m.inspect_archive(self.archive,self.sha)
        self.archive.chmod(0o600);self.payload.pop('web/resources/keys/installation-authority.pem');self.write()
        with self.assertRaises(ValueError):m.inspect_archive(self.archive,self.sha)
        self.write(version='1.0.21')
        with self.assertRaises(ValueError):m.inspect_archive(self.archive,self.sha)
    def test_unsafe_member_never_reaches_iso_tool(self):
        prefix='openwebpbx-1.0.22-debian13-amd64'
        for name,kind,mode in [('/etc/shadow',tarfile.REGTYPE,0o644),(prefix+'/../secret',tarfile.REGTYPE,0o644),(prefix+'/./alias',tarfile.REGTYPE,0o644),(prefix+'/link',tarfile.SYMTYPE,0o777),(prefix+'/hard',tarfile.LNKTYPE,0o644),(prefix+'/suid',tarfile.REGTYPE,0o4755)]:
            with self.subTest(name=name):
                item=tarfile.TarInfo(name);item.type=kind;item.mode=mode;self.write(extra=item)
                with self.assertRaises(ValueError):m.inspect_archive(self.archive,self.sha)
    def test_publish_create_new_reuses_exact_output_and_rejects_changed_media(self):
        tool=self.root/'genisoimage';tool.write_text('''#!/usr/bin/env python3
import hashlib,json,pathlib,sys
a=sys.argv;out=pathlib.Path(a[a.index('-o')+1]);source=pathlib.Path(a[-1]);names=sorted(p.name for p in source.iterdir())
assert names==['README.txt','manifest.json','openwebpbx-1.0.22-debian13-amd64.tar.gz']
manifest=json.loads((source/'manifest.json').read_text());assert manifest['volume_label']=='OPENWEBPBX1022'
out.write_bytes(b'Explicit ISO adapter fixture '+hashlib.sha256((source/manifest['archive']).read_bytes()).digest())
''');tool.chmod(0o700)
        target=self.root/'installer.iso';value=m.build(self.archive,self.sha,target,tool);self.assertEqual(m.digest(target),value['iso_sha256']);self.assertTrue(target.with_suffix('.iso.manifest.json').is_file());self.assertEqual(target.stat().st_mode&0o777,0o644)
        second=m.build(self.archive,self.sha,target,tool);self.assertEqual(second,value)
        target.write_bytes(b'changed')
        with self.assertRaises(ValueError):m.build(self.archive,self.sha,target,tool)
    def test_unowned_output_and_link_refuse_without_overwriting(self):
        target=self.root/'installer.iso';target.write_bytes(b'unowned')
        with self.assertRaises(ValueError):m.build(self.archive,self.sha,target,'/nonexistent')
        self.assertEqual(target.read_bytes(),b'unowned');link=self.root/'archive-link';link.symlink_to(self.archive)
        with self.assertRaises(ValueError):m.inspect_archive(link,self.sha)


if __name__=='__main__':unittest.main()
