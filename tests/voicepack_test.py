#!/usr/bin/env python3
"""Offline filesystem/audio controls for versioned system voices. No API calls."""
import copy
import hashlib
import importlib.util
import io
import json
import math
import os
from pathlib import Path
import shutil
import struct
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import wave

ROOT = Path(__file__).resolve().parents[1]


def module(name,path):
    spec=importlib.util.spec_from_file_location(name,ROOT/path)
    value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value)
    return value


v=module('voice_unit','packaging/voices/voicepack.py')
d=module('voice_deploy_unit','packaging/voices/deployment.py')
i=module('voice_install_unit','packaging/debian/install-voices.py')
u=module('voice_recovery_unit','packaging/debian/upgrade.py')
s=module('voice_support_unit','packaging/debian/install-support.py')


def sound(rate=8000,channels=1,silent=False):
    raw=b''.join(struct.pack('<h',0 if silent else int(7000*math.sin(2*math.pi*440*n/rate)))*channels for n in range(rate//4))
    out=io.BytesIO()
    with wave.open(out,'wb') as wav:
        wav.setnchannels(channels);wav.setsampwidth(2);wav.setframerate(rate);wav.writeframes(raw)
    return out.getvalue()


def fixture_pack(destination):
    """Create a full synthetic inventory for offline packaging controls only."""
    destination=Path(destination);destination.mkdir()
    catalog=v.load_catalog(v.DEFAULT_CATALOG);records={};audio={rate:sound(rate) for rate in v.RATES}
    stats={rate:v.audio_info(data,rate) for rate,data in audio.items()}
    for prompt in catalog['prompts']:
        binding={k:catalog[k] for k in ['voice_id','model_id','voice_settings','provider_output_format']}
        binding.update(text=prompt.get('spoken_text',prompt['text']),seed=101)
        for target in prompt['targets']:
            path=destination/'files'/target['path'];path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(audio[target['rate']])
            records[target['path']]=stats[target['rate']]|{'prompt_id':prompt['id'],
                'synthesis_binding_sha256':v.digest(v.canonical(binding)),'provider_master_sha256':'a'*64}
    (destination/'catalog.json').write_bytes(v.canonical(catalog))
    license=v.DEFAULT_CATALOG.with_name('LICENSE-FreeSWITCH.txt').read_bytes()
    (destination/'LICENSE-FreeSWITCH.txt').write_bytes(license)
    seal={k:catalog[k] for k in ['version','provider','voice_id','locale','model_id']}
    seal.update(schema=1,catalog_sha256=v.digest(v.canonical(catalog)),license_sha256=v.digest(license),files=records,
        audio_processing='Synthetic test tones only; this fixture is never a release or voice qualification.')
    (destination/'pack.json').write_bytes(v.canonical(seal))
    return destination


class Voices(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='openweb-voice-tests-')
        self.root=Path(self.temp.name)
        self.catalog=v.load_catalog(v.DEFAULT_CATALOG)
        self.small=copy.deepcopy(self.catalog)
        self.small['prompts']=[copy.deepcopy(self.catalog['prompts'][0]),copy.deepcopy(self.catalog['prompts'][-1])]
        names={t['path'] for p in self.small['prompts'] for t in p['targets']}
        self.small['stock_original_sha256']={k:s for k,s in self.catalog['stock_original_sha256'].items() if k in names}
        self.pack=self.root/'pack';self.pack.mkdir()
        records={}
        for p in self.small['prompts']:
            binding={k:self.small[k] for k in ['voice_id','model_id','voice_settings','provider_output_format']}
            binding.update(text=p.get('spoken_text',p['text']),seed=101)
            for t in p['targets']:
                data=sound(t['rate']);path=self.pack/'files'/t['path'];path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(data)
                records[t['path']]=v.audio_info(data,t['rate'])|{'prompt_id':p['id'],
                    'synthesis_binding_sha256':v.digest(v.canonical(binding)),'provider_master_sha256':'a'*64}
        (self.pack/'catalog.json').write_bytes(v.canonical(self.small))
        (self.pack/'LICENSE-FreeSWITCH.txt').write_text('Fictional fixture licence.\n')
        self.seal={k:self.small[k] for k in ['version','provider','voice_id','locale','model_id']}
        self.seal.update(schema=1,catalog_sha256=v.digest(v.canonical(self.small)),license_sha256=v.digest((self.pack/'LICENSE-FreeSWITCH.txt').read_bytes()),files=records)
        (self.pack/'pack.json').write_bytes(v.canonical(self.seal))

    def tearDown(self):
        self.temp.cleanup()

    def tar(self,extra=None):
        destination=self.root/'voices.tar.gz'
        with tarfile.open(destination,'w:gz') as archive:
            for path in self.pack.rglob('*'):
                if path.is_file():archive.add(path,arcname=path.relative_to(self.pack).as_posix())
            if extra:
                item=tarfile.TarInfo(extra);item.size=3;archive.addfile(item,io.BytesIO(b'bad'))
        return destination

    def test_full_coverage(self):
        stock=[p for p in self.catalog['prompts'] if p['id'].startswith('stock/')]
        self.assertEqual(len(stock),1219)
        self.assertTrue(all({t['rate'] for t in p['targets']}==v.RATES for p in stock))
        self.assertEqual(len(self.catalog['stock_original_sha256']),4880)
        self.assertEqual(sum(len(p['targets']) for p in self.catalog['prompts']),4888)
        self.assertEqual(len([p for p in self.catalog['prompts'] if p['id'].startswith('call-me-back/')]),8)

    def test_all_scripts_are_nonempty_and_tenant_id_not_rendered(self):
        self.assertTrue(all(p['text'].strip() for p in self.catalog['prompts']))
        self.assertTrue(all('{tenant' not in p['text'] for p in self.catalog['prompts']))

    def test_valid_wave_and_conversion_at_all_rates(self):
        data=sound(44100)
        for rate in v.RATES:
            with self.subTest(rate=rate):
                out=v.convert_audio(data,rate);self.assertEqual(v.audio_info(out,rate)['rate'],rate)

    def test_stereo_refused(self):
        with self.assertRaises(v.PackError):v.audio_info(sound(channels=2))

    def test_silence_refused(self):
        with self.assertRaises(v.PackError):v.audio_info(sound(silent=True))

    def test_truncated_wave_refused(self):
        with self.assertRaises(v.PackError):v.audio_info(sound()[:-300])

    def test_wrong_rate_refused(self):
        with self.assertRaises(v.PackError):v.audio_info(sound(8000),48000)

    def test_path_escape_refused(self):
        for name in ['../secret.wav','/tmp/out.wav','openwebpbx/../bad.wav','openwebpbx\\bad.wav','music/default/8000/a.wav','openwebpbx/.env.wav']:
            with self.subTest(name=name),self.assertRaises(v.PackError):v.relative(name)

    def test_complete_pack_verified(self):
        self.assertEqual(len(v.verify(self.small,self.pack)['files']),5)

    def test_tampered_audio_refused(self):
        path=next((self.pack/'files').rglob('*.wav'));data=bytearray(path.read_bytes());data[-10]^=1;path.write_bytes(data)
        with self.assertRaises(v.PackError):v.verify(self.small,self.pack)

    def test_missing_voice_refused(self):
        next((self.pack/'files').rglob('*.wav')).unlink()
        with self.assertRaises(v.PackError):v.verify(self.small,self.pack)

    def test_unlisted_voice_refused(self):
        (self.pack/'files/unlisted.wav').write_bytes(sound())
        with self.assertRaises(v.PackError):v.verify(self.small,self.pack)

    def test_changed_license_refused(self):
        (self.pack/'LICENSE-FreeSWITCH.txt').write_text('changed')
        with self.assertRaises(v.PackError):v.verify(self.small,self.pack)

    def test_wrong_voice_refused(self):
        self.seal['voice_id']='x'*20;(self.pack/'pack.json').write_bytes(v.canonical(self.seal))
        with self.assertRaises(v.PackError):v.verify(self.small,self.pack)

    def test_pack_symlink_refused(self):
        path=next((self.pack/'files').rglob('*.wav'));copy=self.root/'outside.wav';shutil.move(path,copy);path.symlink_to(copy)
        with self.assertRaises(v.PackError):v.verify(self.small,self.pack)

    def test_archive_stage_has_no_live_effect(self):
        archive=self.tar();target=self.root/'staged'
        d.stage(archive,d.file_digest(archive),target,self.small)
        self.assertEqual(v.verify(self.small,target)['files'],self.seal['files'])
        self.assertFalse((self.root/'sounds').exists())

    def test_archive_bad_pin_refused_without_staging(self):
        archive=self.tar();target=self.root/'staged'
        with self.assertRaises(d.PackError):d.stage(archive,'0'*64,target,self.small)
        self.assertFalse(target.exists())

    def test_archive_escape_refused_and_cleaned(self):
        archive=self.tar('../escaped.wav');target=self.root/'staged'
        with self.assertRaises(d.PackError):d.stage(archive,d.file_digest(archive),target,self.small)
        self.assertFalse(target.exists());self.assertFalse((self.root/'escaped.wav').exists())
        self.assertEqual(list(self.root.glob('.voice-stage-*')),[])

    def test_archive_duplicate_refuses_and_cleans(self):
        duplicate='catalog.json';archive=self.tar(duplicate);target=self.root/'staged'
        with self.assertRaises(d.PackError):d.stage(archive,d.file_digest(archive),target,self.small)
        self.assertFalse(target.exists());self.assertEqual(list(self.root.glob('.voice-stage-*')),[])

    def test_archive_link_refused(self):
        archive=self.root/'link.tar.gz'
        with tarfile.open(archive,'w:gz') as bundle:
            item=tarfile.TarInfo('catalog.json');item.type=tarfile.SYMTYPE;item.linkname='/etc/passwd';bundle.addfile(item)
        with self.assertRaises(d.PackError):d.stage(archive,d.file_digest(archive),self.root/'staged',self.small)

    def test_archive_existing_destination_preserved(self):
        archive=self.tar();target=self.root/'staged';target.mkdir();(target/'keep').write_text('preserve')
        with self.assertRaises(d.PackError):d.stage(archive,d.file_digest(archive),target,self.small)
        self.assertEqual((target/'keep').read_text(),'preserve')

    def test_changed_synthesis_binding_refused(self):
        name=next(iter(self.seal['files']));self.seal['files'][name]['synthesis_binding_sha256']='0'*64
        (self.pack/'pack.json').write_bytes(v.canonical(self.seal))
        with self.assertRaises(v.PackError):v.verify(self.small,self.pack)

    def test_custom_prompt_refuses_all_deployment(self):
        sounds=self.root/'sounds';target=sounds/self.small['prompts'][0]['targets'][0]['path'];target.parent.mkdir(parents=True);target.write_bytes(b'private customer replacement')
        with self.assertRaises(d.PackError):d.deployment_files(self.pack,self.small,sounds,fresh=True)
        self.assertEqual(target.read_bytes(),b'private customer replacement')

    def test_installed_missing_stock_refuses(self):
        with self.assertRaises(d.PackError):d.deployment_files(self.pack,self.small,self.root/'sounds')

    def test_installed_parent_link_refuses_without_writing(self):
        sounds=self.root/'sounds';sounds.mkdir();outside=self.root/'outside';outside.mkdir();(sounds/'en').symlink_to(outside)
        with self.assertRaises(d.PackError):d.deployment_files(self.pack,self.small,sounds,fresh=True)
        self.assertEqual(list(outside.iterdir()),[])

    def test_unexpected_installed_directory_refuses(self):
        target=self.root/'sounds'/self.small['prompts'][0]['targets'][0]['path'];target.mkdir(parents=True)
        with self.assertRaises(d.PackError):d.deployment_files(self.pack,self.small,self.root/'sounds',fresh=True)

    def test_new_files_and_existing_metadata_recover_exactly(self):
        sounds=self.root/'sounds'
        existing=sounds/self.small['prompts'][0]['targets'][0]['path'];existing.parent.mkdir(parents=True)
        existing.write_bytes(b'original stock fixture');existing.chmod(0o600)
        self.small['stock_original_sha256'][existing.relative_to(sounds).as_posix()]=v.digest(existing.read_bytes())
        self.seal['catalog_sha256']=v.digest(v.canonical(self.small));(self.pack/'catalog.json').write_bytes(v.canonical(self.small));(self.pack/'pack.json').write_bytes(v.canonical(self.seal))
        # Real customer files outside the default-prompt namespace remain exact.
        private=sounds/'tenant/custom/greeting.wav';private.parent.mkdir(parents=True);private.write_bytes(b'customer greeting')
        music=sounds/'music/default/8000/song.wav';music.parent.mkdir(parents=True);music.write_bytes(b'hold song')
        mappings=d.deployment_files(self.pack,self.small,sounds,fresh=True)
        backup=self.root/'backup';backup.mkdir();entries=[]
        for target in mappings:
            row={'path':str(target),'exists':target.exists()}
            if target.exists():
                st=target.stat();saved=backup/'files'/target.relative_to('/');saved.parent.mkdir(parents=True);shutil.copyfile(target,saved)
                row.update(sha256=v.digest(saved.read_bytes()),mode=st.st_mode&0o777,uid=st.st_uid,gid=st.st_gid)
            entries.append(row)
        (backup/'files.json').write_text(json.dumps(entries))
        i.copy_files(mappings)
        self.assertNotEqual(existing.read_bytes(),b'original stock fixture')
        self.assertEqual(existing.stat().st_mode&0o777,0o600)
        self.assertEqual(json.loads((sounds/'openwebpbx/voice-pack.json').read_text())['version'],'1.0.1')
        # Execute the actual updater's recovery writer, not a test substitute.
        u.restore_files(backup)
        self.assertEqual(existing.read_bytes(),b'original stock fixture')
        self.assertEqual(existing.stat().st_mode&0o777,0o600)
        self.assertFalse((sounds/'openwebpbx/voice-pack.json').exists())
        self.assertTrue(all(target==existing or not target.exists() for target in mappings))
        self.assertEqual(private.read_bytes(),b'customer greeting');self.assertEqual(music.read_bytes(),b'hold song')

    def test_unsafe_tenant_name_refused_before_network(self):
        for name in ['', 'x\nprivate', '<speak>secret</speak>', 'A'*101, '../../tenant']:
            with self.subTest(name=name),self.assertRaises(v.PackError):v.tenant_greeting(self.catalog,name,self.root/'a.wav','fictional-key')

    @unittest.skipUnless(os.geteuid()==0,'Root ownership control requires an isolated privileged fixture.')
    def test_callback_storage_is_private_and_preserves_parent(self):
        before=self.root.stat();target=self.root/'storage/openwebpbx/call-me-back'
        with patch.object(s,'CALL_ME_BACK_ROOT',target):s.ensure_call_me_back_storage()
        self.assertEqual(target.stat().st_uid,33);self.assertEqual(target.stat().st_gid,33)
        self.assertEqual(target.stat().st_mode&0o777,0o750)
        self.assertEqual(self.root.stat().st_uid,before.st_uid)
        self.assertEqual(self.root.stat().st_mode,before.st_mode)

    def test_callback_storage_link_refuses_without_modifying_target(self):
        outside=self.root/'outside';outside.mkdir();link=self.root/'linked';link.symlink_to(outside)
        with patch.object(s,'CALL_ME_BACK_ROOT',link/'call-me-back'):
            with self.assertRaises(ValueError):s.ensure_call_me_back_storage()
        self.assertEqual(list(outside.iterdir()),[])


if __name__=='__main__':unittest.main()
