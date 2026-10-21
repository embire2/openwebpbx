#!/usr/bin/env python3
"""Real filesystem preflight/copy controls; no generated or real caller audio."""
import copy
import importlib.util
import io
import json
import math
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import wave

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('windows_voicepack_fixture', ROOT/'packaging/voices/voicepack.py')
voices = importlib.util.module_from_spec(spec)
spec.loader.exec_module(voices)

spec = importlib.util.spec_from_file_location('windows_voice_install_test', ROOT/'packaging/windows/install-voices.py')
install = importlib.util.module_from_spec(spec)
spec.loader.exec_module(install)
spec = importlib.util.spec_from_file_location('windows_voice_stage_test', ROOT/'packaging/windows/stage-public-voices.py')
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)


class WindowsVoices(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='openweb-windows-voice-controls-')
        self.root = Path(self.temporary.name)
        self.package = self.root/'package'
        self.package.mkdir()
        (self.package/'voices').mkdir()
        base = self.package/'voices/1.0.1'
        base.mkdir()
        catalog = copy.deepcopy(voices.load_catalog(voices.DEFAULT_CATALOG))
        catalog['prompts'] = [catalog['prompts'][0], catalog['prompts'][-1]]
        names = {t['path'] for p in catalog['prompts'] for t in p['targets']}
        catalog['stock_original_sha256'] = {k:v for k,v in catalog['stock_original_sha256'].items() if k in names}
        records = {}
        for prompt in catalog['prompts']:
            binding = {k:catalog[k] for k in ['voice_id','model_id','voice_settings','provider_output_format']}
            binding.update(text=prompt.get('spoken_text',prompt['text']), seed=101)
            for target in prompt['targets']:
                rate=target['rate'];stream=io.BytesIO()
                with wave.open(stream,'wb') as wav:
                    wav.setnchannels(1);wav.setsampwidth(2);wav.setframerate(rate)
                    wav.writeframes(b''.join(struct.pack('<h',int(7000*math.sin(2*math.pi*440*n/rate))) for n in range(rate//4)))
                data=stream.getvalue();path=base/'files'/target['path'];path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(data)
                records[target['path']]=voices.audio_info(data,rate)|{'prompt_id':prompt['id'],'synthesis_binding_sha256':voices.digest(voices.canonical(binding)),'provider_master_sha256':'a'*64}
        license=voices.DEFAULT_CATALOG.with_name('LICENSE-FreeSWITCH.txt').read_bytes()
        (base/'LICENSE-FreeSWITCH.txt').write_bytes(license)
        (base/'catalog.json').write_bytes(voices.canonical(catalog))
        seal={k:catalog[k] for k in ['version','provider','voice_id','locale','model_id']}
        seal.update(schema=1,catalog_sha256=voices.digest(voices.canonical(catalog)),license_sha256=voices.digest(license),files=records)
        (base/'pack.json').write_bytes(voices.canonical(seal))
        shutil.copytree(ROOT/'packaging/voices', self.package/'voice-tools', ignore=shutil.ignore_patterns('__pycache__'))
        self.sounds = self.root/'sounds'
        self.sounds.mkdir()
        self.seal()

    def tearDown(self):
        self.temporary.cleanup()

    def seal(self):
        files = {p.relative_to(self.package).as_posix(): install.digest(p)
                 for p in self.package.rglob('*') if p.is_file() and p.name != 'release-manifest.json'}
        (self.package/'release-manifest.json').write_text(json.dumps({'version': '1.0.20', 'files': files}))

    def test_fresh_complete_copy_idempotence_and_customer_media_preserved(self):
        greeting = self.sounds/'recordings/owned-custom-greeting.wav'
        greeting.parent.mkdir()
        greeting.write_bytes(b'private user recording fixture')
        before = greeting.read_bytes()
        plan = install.payload(self.package, self.sounds)
        self.assertGreater(len(plan), 1)
        self.assertFalse(any(target == greeting for target, _, _ in plan))
        install.copy_files(plan)
        first = {str(target): install.digest(target) for target, _, _ in plan}
        install.copy_files(install.payload(self.package, self.sounds))
        self.assertEqual(first, {str(target): install.digest(target) for target, _, _ in plan})
        self.assertEqual(greeting.read_bytes(), before)

    def test_custom_system_prompt_refuses_before_any_write(self):
        plan = install.payload(self.package, self.sounds)
        target = plan[0][0]
        target.parent.mkdir(parents=True)
        target.write_bytes(b'custom replacement fixture')
        with self.assertRaises(RuntimeError):
            install.payload(self.package, self.sounds)
        self.assertEqual(target.read_bytes(), b'custom replacement fixture')
        self.assertFalse(plan[-1][0].exists())

    def test_tampered_pack_and_helper_refuse(self):
        helper = self.package/'voice-tools/deployment.py'
        helper.write_text(helper.read_text()+'\n# changed fixture\n')
        with self.assertRaisesRegex(ValueError, 'differs'):
            install.payload(self.package, self.sounds)
        self.assertEqual(list(self.sounds.iterdir()), [])
        self.seal()
        pack = self.package/'voices/1.0.1/pack.json'
        pack.write_bytes(pack.read_bytes()+b' ')
        with self.assertRaisesRegex(ValueError, 'differs'):
            install.payload(self.package, self.sounds)

    def test_post_preflight_change_refuses_preserves_bytes(self):
        plan = install.payload(self.package, self.sounds)
        target = plan[0][0]
        target.parent.mkdir(parents=True)
        target.write_bytes(b'concurrent owned fixture')
        with self.assertRaisesRegex(ValueError, 'changed after'):
            install.copy_files(plan)
        self.assertEqual(target.read_bytes(), b'concurrent owned fixture')
        self.assertFalse(plan[-1][0].exists())

    def test_exact_existing_file_security_preserved(self):
        plan = install.payload(self.package, self.sounds)
        target, source, _ = plan[0]
        target.parent.mkdir(parents=True)
        target.write_bytes(b'original fixture')
        if sys.platform == 'win32':
            def security():
                code="(Get-Acl -LiteralPath '"+str(target).replace("'","''")+"').Sddl"
                return subprocess.check_output(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command',
                    code], text=True).strip()
        else:
            target.chmod(0o640)
            def security():
                st = target.stat()
                return st.st_mode, st.st_uid, st.st_gid, st.st_ino
        before = security()
        install.copy_files([(target, source, install.digest(target))])
        self.assertEqual(before, security())
        self.assertEqual(target.read_bytes(), source.read_bytes())

    def test_public_archive_hash_refusal(self):
        archive = self.root/'fictional.tar.gz'
        archive.write_bytes(b'not the immutable public archive')
        with self.assertRaisesRegex(ValueError, 'immutable public'):
            stage.stage(archive, self.root/'output')
        self.assertFalse((self.root/'output').exists())


if __name__ == '__main__':
    unittest.main()
