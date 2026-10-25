#!/usr/bin/env python3
import importlib.util
import tempfile
from pathlib import Path
import unittest
import warnings
import zipfile

spec=importlib.util.spec_from_file_location('qualified',Path(__file__).with_name('verify-qualified-apk.py'))
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)

class PayloadTests(unittest.TestCase):
    def archives(self,changed=None):
        directory=tempfile.TemporaryDirectory();self.addCleanup(directory.cleanup)
        base={'AndroidManifest.xml':b'release manifest','classes.dex':b'actual calling code','lib/x86_64/liblinphone.so':b'native SDK','META-INF/library.kotlin_module':b'library metadata'}
        first=Path(directory.name)/'unsigned.apk';second=Path(directory.name)/'qualified.apk'
        def write(path,items):
            with zipfile.ZipFile(path,'w') as archive:
                for name,data in items.items():archive.writestr(name,data)
        write(first,base)
        values=base|{'META-INF/ANDROIDD.SF':b'qualification signature','META-INF/ANDROIDD.RSA':b'public qualification certificate','META-INF/MANIFEST.MF':b'signature entry digests'}
        if changed is not None:values.update(changed)
        write(second,values);return first,second
    def test_only_signature_entries_may_differ(self):
        first,second=self.archives();self.assertEqual(4,module.verify(first,second)['non_signature_entries'])
    def test_manifest_dex_native_and_non_signature_metadata_are_protected(self):
        for name in ['AndroidManifest.xml','classes.dex','lib/x86_64/liblinphone.so','META-INF/library.kotlin_module']:
            first,second=self.archives({name:b'changed'})
            with self.subTest(name=name),self.assertRaises(ValueError):module.verify(first,second)
    def test_extra_payload_entry_is_refused(self):
        first,second=self.archives({'unexpected.dat':b'extra'})
        with self.assertRaises(ValueError):module.verify(first,second)
    def test_duplicate_and_unsafe_zip_paths_are_refused(self):
        for name in ['classes.dex','../outside','/absolute','lib\\outside']:
            first,second=self.archives()
            with warnings.catch_warnings():
                warnings.simplefilter('ignore',UserWarning)
                with zipfile.ZipFile(second,'a') as archive:archive.writestr(name,b'bad')
            with self.subTest(name=name),self.assertRaises(ValueError):module.verify(first,second)

if __name__=='__main__':unittest.main()
