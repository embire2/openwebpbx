#!/usr/bin/env python3
"""Real RSA envelope and hostile archive checks without touching an installed PBX."""
import base64
import copy
import datetime as dt
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value
feed=module('feed',ROOT/'packaging/updates/verify_feed.py')
upgrade=module('upgrade',ROOT/'packaging/debian/upgrade.py')

class SignedReleaseChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory();cls.root=Path(cls.temp.name)
        cls.key=cls.root/'key.pem';cls.pub=cls.root/'public.pem'
        subprocess.run(['openssl','genpkey','-algorithm','RSA','-pkeyopt','rsa_keygen_bits:2048','-out',str(cls.key)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        subprocess.run(['openssl','pkey','-in',str(cls.key),'-pubout','-out',str(cls.pub)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    @classmethod
    def tearDownClass(cls):cls.temp.cleanup()
    def setUp(self):
        self.now=dt.datetime(2026,10,9,tzinfo=dt.timezone.utc)
        self.payload={'schema':1,'product':'openwebpbx','channel':'stable','sequence':104,'version':'1.0.4',
            'published_at':'2026-10-09T00:00:00Z','expires_at':'2027-04-07T00:00:00Z','assets':[{
                'platform':'debian13-amd64','name':'openwebpbx-1.0.4-debian13-amd64.tar.gz',
                'url':'https://github.com/embire2/openwebpbx/releases/download/v1.0.4/openwebpbx-1.0.4-debian13-amd64.tar.gz',
                'bytes':1,'sha256':'0'*64,'minimum_version':'1.0.3'}]}
    def signed(self,payload=None):
        raw=json.dumps(payload or self.payload,separators=(',',':')).encode()
        return self.sign_bytes(raw)
    def sign_bytes(self,raw):
        result=subprocess.run(['openssl','dgst','-sha256','-sign',str(self.key)],input=raw,check=True,stdout=subprocess.PIPE)
        return json.dumps({'key_id':feed.KEY_ID,'payload':base64.b64encode(raw).decode(),'signature':base64.b64encode(result.stdout).decode()}).encode()
    def verify(self,envelope=None,**kwargs):return feed.verify(envelope or self.signed(),self.pub,now=self.now,**kwargs)
    def test_real_signature_and_version_contract(self):
        value,digest=self.verify();self.assertEqual(feed.select_asset(value,'debian13-amd64','1.0.3')['bytes'],1)
        self.assertEqual(len(digest),64)
    def test_payload_tampering_is_refused_before_use(self):
        envelope=json.loads(self.signed());envelope['payload']=base64.b64encode(b'{}').decode()
        with self.assertRaisesRegex(ValueError,'signature'):self.verify(json.dumps(envelope).encode())
    def test_unknown_key_id_is_refused(self):
        envelope=json.loads(self.signed());envelope['key_id']='remote-key'
        with self.assertRaises(ValueError):self.verify(json.dumps(envelope).encode())
    def test_signed_duplicate_fields_are_refused(self):
        with self.assertRaises(ValueError):self.verify(self.sign_bytes(b'{"schema":1,"schema":2}'))
    def test_expired_and_future_feeds_are_refused(self):
        for field,value in [('expires_at','2026-10-08T00:00:00Z'),('published_at','2026-10-10T00:00:00Z')]:
            with self.subTest(field=field):
                p=copy.deepcopy(self.payload);p[field]=value
                with self.assertRaises(ValueError):self.verify(self.signed(p))
    def test_monotonic_sequence_and_payload_digest(self):
        value,digest=self.verify();self.verify(previous={'sequence':104,'payload_sha256':digest})
        for previous in [{'sequence':105,'payload_sha256':digest},{'sequence':104,'payload_sha256':'0'*64}]:
            with self.assertRaises(ValueError):self.verify(previous=previous)
    def test_foreign_repository_url_is_refused_even_when_signed(self):
        self.payload['assets'][0]['url']=self.payload['assets'][0]['url'].replace('embire2','attacker')
        with self.assertRaises(ValueError):self.verify()
    def test_duplicate_platform_is_refused(self):
        self.payload['assets']*=2
        with self.assertRaises(ValueError):self.verify()
    def test_version_downgrade_and_wrong_target_are_refused(self):
        value,_=self.verify()
        for installed,target in [('1.0.4',None),('2.0.0',None),('1.0.3','1.0.5'),('1.0.2',None)]:
            with self.assertRaises(ValueError):feed.select_asset(value,'debian13-amd64',installed,target)
    def test_noncanonical_and_boolean_fields_are_refused(self):
        for field,value in [('schema',True),('sequence',True),('version','01.0.4')]:
            with self.subTest(field=field):
                p=copy.deepcopy(self.payload);p[field]=value
                with self.assertRaises(ValueError):self.verify(self.signed(p))
    def test_archive_traversal_links_and_duplicates_are_refused(self):
        prefix='openwebpbx-1.0.4-debian13-amd64'
        cases=[[(prefix+'/../outside',tarfile.REGTYPE)],[(prefix+'/link',tarfile.SYMTYPE)],[(prefix+'/a',tarfile.REGTYPE),(prefix+'/./a',tarfile.REGTYPE)]]
        for number,entries in enumerate(cases):
            archive=self.root/f'bad-{number}.tar.gz'
            with tarfile.open(archive,'w:gz') as output:
                for name,kind in entries:
                    item=tarfile.TarInfo(name);item.type=kind;item.linkname='/etc/passwd';item.size=0
                    output.addfile(item,io.BytesIO())
            self.payload['assets'][0].update(bytes=archive.stat().st_size,sha256=hashlib.sha256(archive.read_bytes()).hexdigest())
            envelope=self.root/'feed.json';envelope.write_bytes(self.signed())
            with patch.object(upgrade,'UPDATES',self.root/'updates'),patch.object(upgrade,'PUBLIC_KEY',self.pub),patch.object(upgrade,'trusted_file',lambda p:Path(p)):
                with self.assertRaises(ValueError):upgrade.prepare_candidate(archive,envelope,'1.0.4','1.0.3')
                self.assertEqual(list((self.root/'updates/staging').iterdir()),[])
    def test_archive_hash_failure_does_not_extract(self):
        archive=self.root/'bad-hash.tar.gz';archive.write_bytes(b'x')
        envelope=self.root/'feed.json';envelope.write_bytes(self.signed())
        with patch.object(upgrade,'UPDATES',self.root/'unused'),patch.object(upgrade,'PUBLIC_KEY',self.pub),patch.object(upgrade,'trusted_file',lambda p:Path(p)):
            with self.assertRaisesRegex(ValueError,'checksum'):upgrade.prepare_candidate(archive,envelope,'1.0.4','1.0.3')
            self.assertFalse((self.root/'unused').exists())

if __name__=='__main__':unittest.main()
