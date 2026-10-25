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
    def test_installer_new_directories_allow_service_traversal_with_private_umask(self):
        source=self.root/'source.wav';source.write_bytes(b'owned audio fixture')
        target=self.root/'new/voice/8000/prompt.wav'
        original=os.umask(0o077)
        try:i.copy_files({target:source})
        finally:os.umask(original)
        for directory in [target.parent,target.parent.parent,target.parent.parent.parent]:
            self.assertEqual(directory.stat().st_mode&0o777,0o755)
        self.assertEqual(target.read_bytes(),source.read_bytes())

    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='openweb-voice-tests-')
        self.root=Path(self.temp.name)
        self.catalog=v.load_catalog(v.DEFAULT_CATALOG)
        self.small=copy.deepcopy(self.catalog)
        self.small['prompts']=[copy.deepcopy(self.catalog['prompts'][0]),copy.deepcopy(self.catalog['prompts'][-1])]
        names={t['path'] for p in self.small['prompts'] for t in p['targets']}
        self.small['stock_original_sha256']={k:s for k,s in self.catalog['stock_original_sha256'].items() if k in names}
        self.small['previous_system_sha256']={k:s for k,s in self.catalog.get('previous_system_sha256',{}).items() if k in names}
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
        self.assertEqual(len(self.catalog['stock_original_sha256']),4890)
        self.assertEqual(sum(len(p['targets']) for p in self.catalog['prompts']),4915)
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

    def test_only_catalogue_authenticated_previous_system_bytes_can_transition(self):
        sounds=self.root/'sounds';name=self.small['prompts'][0]['targets'][0]['path']
        target=sounds/name;target.parent.mkdir(parents=True);old=b'owned prior system prompt fixture';target.write_bytes(old)
        self.small['previous_system_sha256'][name]=v.digest(old)
        self.seal['catalog_sha256']=v.digest(v.canonical(self.small))
        (self.pack/'catalog.json').write_bytes(v.canonical(self.small));(self.pack/'pack.json').write_bytes(v.canonical(self.seal))
        self.assertIn(target,d.deployment_files(self.pack,self.small,sounds,fresh=True))
        before={str(i.SOUNDS/name):{'exists':True,'sha256':v.digest(old)}}
        i.verify_original_snapshot({name:self.small['stock_original_sha256'][name]},self.seal['files'],before,
            previous_system_sha256=self.small['previous_system_sha256'])
        target.write_bytes(old+b'customer edit')
        with self.assertRaises(d.PackError):d.deployment_files(self.pack,self.small,sounds,fresh=True)
        before[str(i.SOUNDS/name)]['sha256']=v.digest(target.read_bytes())
        with self.assertRaises(ValueError):i.verify_original_snapshot({name:self.small['stock_original_sha256'][name]},self.seal['files'],before,
            previous_system_sha256=self.small['previous_system_sha256'])

    def test_foreign_previous_voice_requires_exact_prior_pack_identity(self):
        sounds=self.root/'sounds';prior={'provider':'ElevenLabs','voice_id':'7S3KNdLDL7aRgBVRQb1z','files':{}}
        with self.assertRaises(d.PackError):d.deployment_files(self.pack,self.small,sounds,fresh=True,previous_manifest=prior)
        self.small['previous_pack_sha256']=v.digest(v.canonical(prior))
        self.seal['catalog_sha256']=v.digest(v.canonical(self.small))
        (self.pack/'catalog.json').write_bytes(v.canonical(self.small));(self.pack/'pack.json').write_bytes(v.canonical(self.seal))
        self.assertGreater(len(d.deployment_files(self.pack,self.small,sounds,fresh=True,previous_manifest=prior)),1)
        prior['files']['unexpected']={'sha256':'a'*64}
        with self.assertRaises(d.PackError):d.deployment_files(self.pack,self.small,sounds,fresh=True,previous_manifest=prior)

    def test_installed_missing_stock_refuses(self):
        with self.assertRaises(d.PackError):d.deployment_files(self.pack,self.small,self.root/'sounds')

    def sparse_package(self):
        package=self.root/'package';base=package/'voices/1.0.2';base.parent.mkdir(parents=True);shutil.copytree(self.pack,base)
        helper=package/'voice-tools';helper.mkdir()
        for name in ['voicepack.py','deployment.py']:shutil.copyfile(ROOT/'packaging/voices'/name,helper/name)
        name=next(t['path']for t in self.small['prompts'][0]['targets']if t['rate']==8000)
        archive=package/'engine.tar.gz'
        with tarfile.open(archive,'w:gz')as tar:
            entry=tarfile.TarInfo('usr/share/freeswitch/sounds/'+name);data=(self.pack/'files'/name).read_bytes();entry.size=len(data);tar.addfile(entry,io.BytesIO(data))
        manifest={'files':{p.relative_to(package).as_posix():d.file_digest(p)for p in package.rglob('*')if p.is_file()}}
        sounds=self.root/'sparse-sounds';target=sounds/name;target.parent.mkdir(parents=True);shutil.copyfile(self.pack/'files'/name,target)
        return package,manifest,sounds,name

    def test_known_sparse_engine_allows_only_its_absent_stock_rates(self):
        package,manifest,sounds,name=self.sparse_package()
        with patch.object(i,'KNOWN_ENGINE_SHA256',manifest['files']['engine.tar.gz']):
            self.assertEqual(i.required_stock_paths(package,manifest),frozenset([name]))
            mappings=i.payload(package,manifest,sounds_root=sounds)
            self.assertEqual(len(mappings),len(self.seal['files'])+1)
            self.assertTrue(any('/16000/'in str(p)for p in mappings))
            # Default remains strict, even with the same valid pack.
            with self.assertRaises(d.PackError):d.deployment_files(self.pack,self.small,sounds)
            (sounds/name).unlink()
            with self.assertRaises((ValueError,RuntimeError)):i.payload(package,manifest,sounds_root=sounds)

    def test_unknown_sparse_engine_and_manifest_mismatch_keep_refusal(self):
        package,manifest,sounds,name=self.sparse_package()
        self.assertIsNone(i.required_stock_paths(package,manifest))
        with self.assertRaises((ValueError,RuntimeError)):i.payload(package,manifest,sounds_root=sounds)
        altered=copy.deepcopy(manifest);altered['files']['engine.tar.gz']='0'*64
        with patch.object(i,'KNOWN_ENGINE_SHA256',manifest['files']['engine.tar.gz']):
            with self.assertRaises((ValueError,RuntimeError)):i.payload(package,altered,sounds_root=sounds)
        # Fresh install behavior does not use a sparse historical exception.
        self.assertEqual(len(i.payload(package,manifest,sounds_root=self.root/'fresh',fresh=True)),len(self.seal['files'])+1)

    def test_sparse_exception_never_overwrites_existing_custom_prompt(self):
        package,manifest,sounds,name=self.sparse_package()
        optional=next(t['path']for t in self.small['prompts'][0]['targets']if t['rate']==16000)
        target=sounds/optional;target.parent.mkdir(parents=True);target.write_bytes(b'private customer higher-rate replacement')
        with patch.object(i,'KNOWN_ENGINE_SHA256',manifest['files']['engine.tar.gz']):
            with self.assertRaises((ValueError,RuntimeError)):i.payload(package,manifest,sounds_root=sounds)
        self.assertEqual(target.read_bytes(),b'private customer higher-rate replacement')

    def test_sparse_engine_inventory_refuses_ambiguous_or_linked_members(self):
        for kind in ['duplicate','link','traversal','empty']:
            with self.subTest(kind=kind):
                package=self.root/('invalid-'+kind);package.mkdir();archive=package/'engine.tar.gz'
                with tarfile.open(archive,'w:gz')as tar:
                    path='usr/share/freeswitch/sounds/en/8000/prompt.wav'
                    if kind=='traversal':path='usr/share/freeswitch/sounds/../outside.wav'
                    entry=tarfile.TarInfo(path)
                    if kind=='link':entry.type=tarfile.SYMTYPE;entry.linkname='/outside';tar.addfile(entry)
                    elif kind!='empty':
                        entry.size=3;tar.addfile(entry,io.BytesIO(b'wav'))
                        if kind=='duplicate':tar.addfile(entry,io.BytesIO(b'wav'))
                sha=d.file_digest(archive)
                with patch.object(i,'KNOWN_ENGINE_SHA256',sha):
                    with self.assertRaises(ValueError):i.required_stock_paths(package,{'files':{'engine.tar.gz':sha}})

    def test_sparse_snapshot_requires_captured_absence_and_preserves_required_hash_checks(self):
        originals=self.small['stock_original_sha256'];required=next(t['path']for t in self.small['prompts'][0]['targets']if t['rate']==8000)
        before={str(i.SOUNDS/name):{'exists':False}for name in originals}
        before[str(i.SOUNDS/required)]={'exists':True,'sha256':originals[required]}
        i.verify_original_snapshot(originals,self.seal['files'],before,{required})
        with self.assertRaises(ValueError):i.verify_original_snapshot(originals,self.seal['files'],before)
        wrong=copy.deepcopy(before);wrong[str(i.SOUNDS/required)]['exists']=False
        with self.assertRaises(ValueError):i.verify_original_snapshot(originals,self.seal['files'],wrong,{required})
        optional=next(name for name in originals if name!=required)
        wrong=copy.deepcopy(before);wrong[str(i.SOUNDS/optional)]={'exists':True,'sha256':'0'*64}
        with self.assertRaises(ValueError):i.verify_original_snapshot(originals,self.seal['files'],wrong,{required})
        wrong=copy.deepcopy(before);del wrong[str(i.SOUNDS/optional)]
        with self.assertRaises(ValueError):i.verify_original_snapshot(originals,self.seal['files'],wrong,{required})
        wrong=copy.deepcopy(before);wrong[str(i.SOUNDS/optional)]={}
        with self.assertRaises(ValueError):i.verify_original_snapshot(originals,self.seal['files'],wrong,{required})

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
        self.assertEqual(json.loads((sounds/'openwebpbx/voice-pack.json').read_text())['version'],'1.0.2')
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
