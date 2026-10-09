#!/usr/bin/env python3
"""Real signer checks for optional approved Play publication metadata."""
import base64
import copy
import datetime as dt
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'packaging/updates'))
from play_metadata import validate
from verify_feed import verify


class PlayPublicationChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='openweb-play-feed-')
        cls.folder = Path(cls.temp.name)
        cls.private = cls.folder/'key.pem'; cls.public = cls.folder/'public.pem'
        subprocess.run(['openssl','genpkey','-algorithm','RSA','-pkeyopt','rsa_keygen_bits:2048','-out',str(cls.private)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        cls.private.chmod(0o600)
        subprocess.run(['openssl','pkey','-in',str(cls.private),'-pubout','-out',str(cls.public)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        cls.apk=cls.folder/'openwebpbx-1.0.8-android.apk';cls.apk.write_bytes(b'bounded fixture artifact')
    @classmethod
    def tearDownClass(cls):cls.temp.cleanup()
    def setUp(self):
        self.now=dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
        self.published=self.now.strftime('%Y-%m-%dT%H:%M:%SZ')
        self.play={'status':'published','track':'production','rollout':'complete','package_id':'com.openweb.pbx',
                   'version':'1.0.7','version_code':107,'minimum_server_version':'1.0.6','min_sdk':28,
                   'published_at':(self.now-dt.timedelta(seconds=1)).strftime('%Y-%m-%dT%H:%M:%SZ')}
    def sign(self,metadata=None):
        output=self.folder/'signed.json';output.unlink(missing_ok=True)
        args=[sys.executable,str(ROOT/'packaging/updates/sign-feed.py'),'--private-key',str(self.private),'--public-key',str(self.public),
              '--version','1.0.8','--sequence','108','--android',str(self.apk),'--android-version-code','108',
              '--android-certificate-sha256','4'*64,'--published-at',self.published,'--output',str(output)]
        if metadata is not None:
            reviewed=self.folder/'reviewed.json';reviewed.write_text(json.dumps(metadata))
            args += ['--play-published-metadata',str(reviewed)]
        result=subprocess.run(args,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        return result,output
    def test_initial_release_omits_play_availability(self):
        result,path=self.sign();self.assertEqual(result.returncode,0,result.stderr)
        payload,_=verify(path.read_bytes(),self.public)
        self.assertNotIn('android_play',payload)
    def test_actual_signer_includes_reviewed_metadata_under_signature(self):
        result,path=self.sign(self.play);self.assertEqual(result.returncode,0,result.stderr)
        payload,_=verify(path.read_bytes(),self.public)
        self.assertEqual(payload['android_play'],self.play)
        wrapper=json.loads(path.read_bytes());payload['android_play']['version_code']=999
        wrapper['payload']=base64.b64encode(json.dumps(payload).encode()).decode()
        with self.assertRaisesRegex(ValueError,'signature'):verify(json.dumps(wrapper).encode(),self.public)
    def test_review_test_track_and_incomplete_rollout_are_refused(self):
        for field,value in [('status','pending'),('track','internal'),('rollout','staged'),('package_id','other.app')]:
            with self.subTest(field=field):
                bad={**self.play,field:value};result,path=self.sign(bad)
                self.assertNotEqual(result.returncode,0);self.assertFalse(path.exists())
    def test_future_or_higher_play_publication_is_refused(self):
        for field,value in [('version','1.0.9'),('published_at',(self.now+dt.timedelta(seconds=1)).strftime('%Y-%m-%dT%H:%M:%SZ'))]:
            with self.subTest(field=field):
                with self.assertRaises(ValueError):validate({**self.play,field:value},'1.0.8',self.published,self.now)
    def test_numeric_fields_and_version_components_are_bounded(self):
        for field,value in [('version_code',True),('version_code',0),('version_code',2147483648),('min_sdk',27),('min_sdk',101),('min_sdk','28'),('version','1000000.0.0'),('minimum_server_version','01.0.0')]:
            with self.subTest(field=field,value=value):
                with self.assertRaises(ValueError):validate({**self.play,field:value},'1.0.8',self.published,self.now)
    def test_missing_and_unknown_fields_are_refused(self):
        missing=copy.deepcopy(self.play);missing.pop('rollout')
        for bad in [missing,{**self.play,'url':'https://untrusted.invalid'},None]:
            with self.assertRaises(ValueError):validate(bad,'1.0.8',self.published,self.now)
    def test_approval_changes_require_a_new_sequence(self):
        _,without=self.sign();first=without.read_bytes();_,digest=verify(first,self.public)
        _,with_play=self.sign(self.play)
        with self.assertRaisesRegex(ValueError,'conflicting'):verify(with_play.read_bytes(),self.public,previous={'sequence':108,'payload_sha256':digest})


if __name__=='__main__':unittest.main()
