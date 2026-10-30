#!/usr/bin/env python3
"""Synthetic actual-candidate transport/pair refusals; no native Windows claim.

The tiny baseline ZIP's digest/size replace only the public-byte constants within
this fixture. Production constants and full ZIP validators remain independent.
"""
import base64
import copy
from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import zipfile
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa

HERE = Path(__file__).resolve().parent

def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec); spec.loader.exec_module(value); return value

p = module('actual_candidate_preparation_tested', HERE/'windows-actual-candidate-preparation.py')
f = module('actual_candidate_fixture_tested', HERE/'windows-updater-fixture.py')

class ActualCandidatePair(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(); self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.base, self.target = self.root/'base.zip', self.root/'target.zip'
        self.zip(self.base, p.BASE, {'VERSION':b'1.0.21\n', 'web/VERSION':b'1.0.21\n'})
        self.zip(self.target, p.TARGET, {'VERSION':b'1.0.22\n', 'web/VERSION':b'1.0.22\n',
            'Install-PhoneHealth.ps1':b'param([switch]$DeferStart,[IO.FileStream]$MaintenanceLock)\n# original installer\n',
            'server/OpenWebPbx.Server.dll':b'fictional22; not a DLL', 'public.txt':b'unchanged'})
        self.base_facts = self.facts(p.BASE, self.base, p.PUBLIC21['source'], '101')
        self.target_facts = self.facts(p.TARGET, self.target, 'a'*40, '102')
        self.base_path, self.target_path = self.root/'base-facts.json', self.root/'target-facts.json'
        self.save_facts()
        self.output = self.root/'output'

    def zip(self, path, version, files):
        prefix = 'openwebpbx-'+version+'-windows-x64/'
        with zipfile.ZipFile(path, 'w') as archive:
            for name, data in files.items(): archive.writestr(prefix+name, data)
            archive.writestr(prefix+'release-manifest.json', json.dumps({'version':version,'files':{
                name:hashlib.sha256(data).hexdigest() for name,data in files.items()}}))

    def facts(self, version, archive, commit, run):
        sha = p.legacy.digest(archive)
        value = {'schema':1,'state':'partial','source_commit':commit,'run_id':run,
            'gates':{gate:'passed' for gate in (*p.legacy.ESSENTIAL_GATES,*p.MODERN)},
            'candidate_artifact':{'filename':f'openwebpbx-{version}-windows-x64.zip','sha256':sha,'product_source_commit':commit,'private_exclusions':'passed'},
            'artifacts':{'candidate_sha256':sha}}
        if version == p.TARGET:
            value.update(mode='public21_to_actual_candidate22',public21_transition={'state':'passed',
                'candidate_source_commit':commit,'candidate_qualification_source_commit':commit,'candidate_sha256':sha,'upgrade_mechanism':'candidate22_manual_helper',
                'gates':{'public21_to_candidate22':'passed','public21_rollback':'passed'}})
        return value

    def save_facts(self):
        self.base_path.write_text(json.dumps(self.base_facts)); self.target_path.write_text(json.dumps(self.target_facts))

    def prepare(self):
        self.save_facts()
        with mock.patch.dict(p.PUBLIC21, sha256=p.legacy.digest(self.base), bytes=self.base.stat().st_size):
            return p.prepare(self.base,self.base_path,self.target,self.target_path,self.output,source_commit='b'*40,run_id='103')

    def test_public_baseline_pins_are_real_and_not_target_overlays(self):
        self.assertEqual(p.PUBLIC21, {'source':'cab93b390ba2e8f33c184f2f085740c2862031a6',
            'sha256':'ce811ae1eaeb17b46f81bdfc0f12b0baa13409bded8f4df6788f8772d0ea855d','bytes':643070428})
        with self.assertRaises(ValueError):
            p.prepare(self.base,self.base_path,self.target,self.target_path,self.output,source_commit='b'*40,run_id='103')

    def test_untouched_normal_and_exact_last_payload_fault(self):
        provenance = self.prepare()
        normal, fault = [self.output/k/(p.NAME+'.zip') for k in ('normal','fault')]
        self.assertEqual(normal.read_bytes(), self.target.read_bytes())
        result = p.verify_pair(normal,fault,self.target_facts,provenance)
        self.assertEqual(set(result['changed_files']),p.FAULT_FILES|{'release-manifest.json'})
        self.assertNotEqual(provenance['normal']['sha256'],provenance['fault']['sha256'])
        self.assertEqual(provenance['normal']['bytes'],normal.stat().st_size)
        self.assertEqual(provenance['target_facts_sha256'],p.legacy.digest(self.target_path))
        self.assertIn('onboarding_absent_precommit=$true',p.fault_source())
        self.assertNotIn('1.0.13',p.fault_source()); self.assertNotIn('1.0.14',p.fault_source())

    def test_all_original_gates_and_explicit_scope_refuse_incomplete(self):
        for gate in (*p.legacy.ESSENTIAL_GATES,*p.MODERN):
            for bad in (None,True,'Passed','unqualified'):
                value = copy.deepcopy(self.target_facts); value['gates'][gate]=bad
                with self.subTest(gate=gate,bad=bad), self.assertRaises(ValueError): p.eligible(value,p.TARGET)
        for key,bad in [('state','failed'),('upgrade_mechanism','original21_signed_wrapper'),('candidate_source_commit','c'*40),('candidate_sha256','c'*64)]:
            value=copy.deepcopy(self.target_facts);value['public21_transition'][key]=bad
            with self.subTest(key=key),self.assertRaises(ValueError):p.eligible(value,p.TARGET)

    def test_wrong_base_and_mutated_target_refused_before_outputs(self):
        self.base_facts['source_commit']='c'*40
        with self.assertRaises(ValueError):self.prepare()
        self.assertFalse(self.output.exists())
        self.base_facts['source_commit']=p.PUBLIC21['source'];self.target.write_bytes(b'changed original ZIP')
        with self.assertRaises(ValueError):self.prepare()

    def test_unrelated_payload_change_rejected_even_with_refreshed_manifest(self):
        provenance=self.prepare();normal=self.output/'normal'/(p.NAME+'.zip');fault=self.output/'fault'/(p.NAME+'.zip')
        with zipfile.ZipFile(fault) as archive:files={n.removeprefix(p.NAME+'/'):archive.read(n) for n in archive.namelist()}
        files.pop('release-manifest.json');files['public.txt']=b'undeclared change';self.zip(fault,p.TARGET,files)
        provenance['fault']['sha256']=p.legacy.digest(fault)
        with self.assertRaisesRegex(ValueError,'undeclared'):p.verify_pair(normal,fault,self.target_facts,provenance)

    def test_fault_witness_change_refused_even_with_refreshed_manifest(self):
        provenance=self.prepare();normal=self.output/'normal'/(p.NAME+'.zip');fault=self.output/'fault'/(p.NAME+'.zip')
        with zipfile.ZipFile(fault) as archive:files={n.removeprefix(p.NAME+'/'):archive.read(n) for n in archive.namelist()}
        files.pop('release-manifest.json');files['canary-fault.ps1']+=b'\n# unauthorized witness change';self.zip(fault,p.TARGET,files)
        provenance['fault']['sha256']=p.legacy.digest(fault)
        with self.assertRaisesRegex(ValueError,'witness'):p.verify_pair(normal,fault,self.target_facts,provenance)

    def test_existing_output_and_invalid_preparation_identity_refused(self):
        self.output.mkdir();(self.output/'keep').write_bytes(b'preserve')
        with self.assertRaises(ValueError):self.prepare()
        self.assertEqual((self.output/'keep').read_bytes(),b'preserve')
        with self.assertRaises(ValueError):p.prepare(self.base,self.base_path,self.target,self.target_path,self.output,source_commit='main',run_id='103')

    def test_replay_retains_product_and_distinct_qualification_source(self):
        self.target_facts['source_commit']='c'*40
        self.target_facts['product_source_commit']='a'*40
        self.target_facts['public21_transition']['candidate_qualification_source_commit']='c'*40
        self.target_facts['replay']={'schema':1,'original_run':'99','original_product_source':'a'*40,
            'qualification_source':'c'*40,'exact_zip_sha256':p.legacy.digest(self.target),
            'windows_runtime_source_identical':True,'runtime_overlays':False}
        self.assertEqual(p.eligible(self.target_facts,p.TARGET),p.legacy.digest(self.target))
        provenance=self.prepare()
        self.assertEqual(provenance['target_source_commit'],'a'*40)
        self.assertEqual(provenance['target_qualification_source_commit'],'c'*40)
        self.assertEqual((self.output/'normal'/(p.NAME+'.zip')).read_bytes(),self.target.read_bytes())
        for field,value in [('original_product_source','d'*40),('qualification_source','d'*40),('runtime_overlays',True),('exact_zip_sha256','d'*64)]:
            facts=copy.deepcopy(self.target_facts);facts['replay'][field]=value
            with self.subTest(field=field),self.assertRaises(ValueError):p.eligible(facts,p.TARGET)

    def test_actual_signed_packets_preserve_crypto_and_target_binding(self):
        provenance=self.prepare();archives={k:self.output/k/(p.NAME+'.zip') for k in ('normal','fault')}
        key=rsa.generate_private_key(public_exponent=65537,key_size=2048);public=self.root/'public.pem'
        public.write_bytes(key.public_key().public_bytes(serialization.Encoding.PEM,serialization.PublicFormat.SubjectPublicKeyInfo))
        now=datetime.now(timezone.utc)
        packet={'schema':1,'repository':'embire2/openwebpbx','base_suite_run_id':'101','canary_run_id':'103',
            'base_source_commit':p.PUBLIC21['source'],'base_archive_sha256':p.PUBLIC21['sha256'],'qualification_kind':'actual_candidate',
            'target_suite_run_id':'102','target_source_commit':'a'*40,'target_qualification_source_commit':'a'*40,'target_facts_sha256':provenance['target_facts_sha256']}
        # This test's tiny baseline is explicit; the packet verifier still pins
        # the genuine public21 digest, independently of the pair test fixture.
        provenance['base_archive_sha256']=p.PUBLIC21['sha256']
        for mode,seq in (('fault',100),('normal',101)):
            payload={'schema':1,'product':'openwebpbx','channel':'stable','version':p.TARGET,'sequence':seq,
                'published_at':(now-timedelta(minutes=1)).isoformat(),'expires_at':(now+timedelta(days=1)).isoformat(),
                'assets':[{'platform':'windows-x64','name':p.NAME+'.zip','url':f'https://github.com/embire2/openwebpbx/releases/download/v{p.TARGET}/{p.NAME}.zip',
                    'minimum_version':p.BASE,'bytes':archives[mode].stat().st_size,'sha256':p.legacy.digest(archives[mode])}]}
            raw=json.dumps(payload,separators=(',',':')).encode()
            packet[mode]={'archive_sha256':p.legacy.digest(archives[mode]),'envelope':{'key_id':'release-2026-a',
                'payload':base64.b64encode(raw).decode(),'signature':base64.b64encode(key.sign(raw,padding.PKCS1v15(),hashes.SHA256())).decode()}}
        def verify():return f.verify_packets(packet,self.base_facts,provenance,archives,public,now=now,base_version=p.BASE,target_version=p.TARGET,actual_candidate=True,target_facts=self.target_facts)
        self.assertEqual(len(verify()),2)
        # Same real signed ZIPs, new actual qualification identity: the original
        # product source remains a. Both distinct identities must be bound.
        self.target_facts['source_commit']='c'*40;self.target_facts['product_source_commit']='a'*40
        self.target_facts['public21_transition']['candidate_qualification_source_commit']='c'*40
        self.target_facts['replay']={'schema':1,'original_run':'99','original_product_source':'a'*40,
            'qualification_source':'c'*40,'exact_zip_sha256':p.legacy.digest(self.target),
            'windows_runtime_source_identical':True,'runtime_overlays':False}
        self.target_path.write_text(json.dumps(self.target_facts))
        provenance.update(target_qualification_source_commit='c'*40,target_facts_sha256=p.legacy.digest(self.target_path))
        packet.update(target_qualification_source_commit='c'*40,target_facts_sha256=p.legacy.digest(self.target_path))
        self.assertEqual(len(verify()),2)
        for keyname,value in [('target_source_commit','d'*40),('target_qualification_source_commit','d'*40),('target_facts_sha256','d'*64),('qualification_kind','canary')]:
            original=packet[keyname];packet[keyname]=value
            with self.subTest(key=keyname),self.assertRaises(ValueError):verify()
            packet[keyname]=original
        packet['normal']['envelope']['signature']=packet['fault']['envelope']['signature']
        with self.assertRaises(Exception):verify()

if __name__=='__main__':unittest.main()
