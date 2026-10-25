#!/usr/bin/env python3
"""A private build must still produce traversable, readable installed program trees."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from voicepack_test import fixture_pack

ROOT=Path(__file__).resolve().parents[1]

class PrivateBuildPackaging(unittest.TestCase):
    def test_restrictive_private_build_modes_are_normalized_in_archive(self):
        with tempfile.TemporaryDirectory(prefix='openweb-package-modes-') as temporary:
            work=Path(temporary)
            for name,executable in [('server','OpenWebPbx.Server'),('updater','OpenWebPbx.Updater')]:
                directory=work/name;directory.mkdir(mode=0o700)
                (directory/executable).write_text('Private build executable fixture\n');(directory/executable).chmod(0o700)
                (directory/'runtime.data').write_text('Private build ordinary fixture\n');(directory/'runtime.data').chmod(0o600)
            engine=work/'engine.tar.gz'
            with tarfile.open(engine,'w:gz'):pass
            output=work/'release'
            voices=fixture_pack(work/'voices')
            subprocess.run([sys.executable,str(ROOT/'packaging/build-release.py'),'--target','debian',
                '--server',str(work/'server'),'--updater',str(work/'updater'),'--engine',str(engine),
                '--voices',str(voices),'--output',str(output)],
                check=True,cwd=ROOT,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE,umask=0o077)
            archive=next(output.glob('*.tar.gz'))
            with tarfile.open(archive) as packed:
                prefix=archive.name.removesuffix('.tar.gz')
                manifest=json.load(packed.extractfile(prefix+'/release-manifest.json'))
                self.assertIn('voices/1.0.2/pack.json',manifest['files'])
                self.assertIn('voice-tools/deployment.py',manifest['files'])
                self.assertIn('install-voices.py',manifest['files'])
                self.assertEqual(sum(name.startswith('voices/1.0.2/files/') for name in manifest['files']),4915)
                for name,executable in [('server','OpenWebPbx.Server'),('updater','OpenWebPbx.Updater')]:
                    self.assertEqual(packed.getmember(prefix+'/'+name).mode,0o755)
                    self.assertEqual(packed.getmember(prefix+'/'+name+'/'+executable).mode,0o755)
                    self.assertEqual(packed.getmember(prefix+'/'+name+'/runtime.data').mode,0o644)
                    self.assertIn(name+'/'+executable,manifest['files'])
                    self.assertEqual((work/name).stat().st_mode&0o777,0o700)
                    self.assertEqual((work/name/'runtime.data').stat().st_mode&0o777,0o600)

if __name__=='__main__':unittest.main()
