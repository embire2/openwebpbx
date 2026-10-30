#!/usr/bin/env python3
"""Focused synthetic raw-policy projection and actual PHP/HMAC compatibility."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import unittest

spec=importlib.util.spec_from_file_location('operator_policy',Path(__file__).with_name('windows-operator-rollback-policy.py'))
p=importlib.util.module_from_spec(spec);spec.loader.exec_module(p)

class OperatorPolicy(unittest.TestCase):
    def setUp(self):
        self.start='2026-10-30T17:00:00+00:00';self.end='2026-10-30T17:05:00+00:00'
        self.instance={'scope_key':'instance','mode':'download','channel':'stable','maintenance_hour':2,'maintenance_duration':2,'updated_by':None,'updated_at':'2026-10-29T17:00:00+00:00','android_minimum_version':'1.0.19'}
        self.tenant=self.instance|{'scope_key':'tenant:12345678-1234-1234-1234-123456789abc','mode':'required'}
        self.before=[self.row(self.instance),self.row(self.tenant)]
        self.after=[self.row(self.instance|{'mode':'notify','updated_at':'2026-10-30T17:01:00+00:00'}),self.row(self.tenant)]
    def row(self,value):return json.dumps(value,separators=(',',':'))
    def check(self,after=None):return p.project(self.before,self.after if after is None else after,self.start,self.end)
    def test_exact_source_reset_preserves_all_other_bytes(self):
        self.assertEqual(self.check(),sorted(self.before))
        self.assertEqual(p.digest(self.check(),b'k'*32),p.digest(self.before,b'k'*32))
    def test_each_other_instance_field_is_strict(self):
        for key,value in [('channel','beta'),('maintenance_hour',3),('maintenance_duration',3),('updated_by','87654321-1234-1234-1234-123456789abc'),('android_minimum_version','1.0.20')]:
            with self.subTest(key=key),self.assertRaises(ValueError):self.check([self.row(self.instance|{'mode':'notify','updated_at':'2026-10-30T17:01:00+00:00',key:value}),self.after[1]])
    def test_tenant_policy_is_strict(self):
        for key,value in [('mode','notify'),('updated_at','2026-10-30T17:01:00+00:00')]:
            with self.subTest(key=key),self.assertRaises(ValueError):self.check([self.after[0],self.row(self.tenant|{key:value})])
    def test_exact_inventory_and_source_schema(self):
        for rows in [[],self.after[:1],self.after+[self.after[1]],[self.after[0],self.after[0]]]:
            with self.subTest(rows=len(rows)),self.assertRaises(ValueError):self.check(rows)
        for key in self.instance:
            value=json.loads(self.after[0]);value.pop(key)
            with self.subTest(missing=key),self.assertRaises(ValueError):self.check([self.row(value),self.after[1]])
        value=json.loads(self.after[0]);value['extra']='no'
        with self.assertRaises(ValueError):self.check([self.row(value),self.after[1]])
    def test_only_notify_and_actual_aware_window(self):
        for mode,stamp in [('automatic','2026-10-30T17:01:00+00:00'),('notify','2026-10-30T16:59:59+00:00'),('notify','2026-10-30T17:05:01+00:00'),('notify','2026-10-30T17:01:00')]:
            with self.subTest(mode=mode,stamp=stamp),self.assertRaises(ValueError):self.check([self.row(self.instance|{'mode':mode,'updated_at':stamp}),self.after[1]])
        with self.assertRaises(ValueError):p.project(self.before,self.after,self.end,self.start)
    def test_nonmodeled_json_tokens_and_formatting_remain_exact(self):
        for raw in [self.after[0].replace('"maintenance_hour":2','"maintenance_hour":2.0'),self.after[0].replace('"channel":"stable"','"channel": "stable"')]:
            with self.subTest(raw_hash=hashlib.sha256(raw.encode()).hexdigest()),self.assertRaises(ValueError):self.check([raw,self.after[1]])
    def test_duplicate_fields_and_invalid_scopes_refused(self):
        for raw in [self.after[0].replace('"scope_key":"instance"','"scope_key":"instance","scope_key":"instance"'),self.after[0].replace('"instance"','"other"')]:
            with self.assertRaises(ValueError):self.check([raw,self.after[1]])
    def test_original_php_snapshot_digest_compatibility(self):
        php=shutil.which('php')
        if not php:self.skipTest('PHP CLI unavailable; native qualifier still checks exact original snapshot HMAC')
        code="echo hash_hmac('sha256',json_encode(json_decode($argv[1],true,512,JSON_THROW_ON_ERROR),JSON_THROW_ON_ERROR|JSON_UNESCAPED_SLASHES),hex2bin($argv[2]));"
        expected=subprocess.run([php,'-r',code,json.dumps([json.loads(v)for v in sorted(self.before)]),(b'k'*32).hex()],check=True,capture_output=True,text=True).stdout
        self.assertEqual(p.digest(self.before,b'k'*32),expected)
    def test_source_reset_exists_once_in_current_product_helper(self):
        source=(Path(__file__).resolve().parents[1]/'packaging/windows/Upgrade-OpenWebPBX.ps1').read_text()
        self.assertEqual(source.count(p.RESET),1)

if __name__=='__main__':unittest.main()
