#!/usr/bin/env python3
"""Offline challenge ownership/lifecycle checks; no external DNS or mail changes."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('cpanel_hook',ROOT/'packaging/debian/cpanel-acme-hook.py')
hook=importlib.util.module_from_spec(spec);spec.loader.exec_module(hook)

class Challenges(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory();self.root=Path(self.temporary.name)
        self.settings={'endpoint':'https://panel.example.invalid:2083','username':'fixture','token':'not-a-live-token','zone':'example.invalid','dns_domains':['sip.example.invalid'],'http_domains':['call.example.invalid'],'webroot':str(self.root/'webroot'),'nameservers':['ns1.example.invalid','ns2.example.invalid']}
        self.config=self.root/'config.json';self.config.write_text(json.dumps(self.settings));self.config.chmod(0o600)
        self.rows=[{'name':'preserved.example.invalid.','type':'TXT','txtdata':'unchanged','line':7}]
        self.validation='A'*43;self.calls=[]
        self.patches=[patch.object(hook,'CONFIG',self.config),patch.object(hook,'STATE',self.root/'state'),patch.object(hook,'api',side_effect=self.api),patch.object(hook.subprocess,'run',side_effect=self.dig),patch.dict(os.environ,{'CERTBOT_DOMAIN':'*.sip.example.invalid','CERTBOT_VALIDATION':self.validation,'CERTBOT_TOKEN':''})]
        for p in self.patches:p.start()
    def tearDown(self):
        for p in reversed(self.patches):p.stop()
        self.temporary.cleanup()
    def api(self,settings,operation,**values):
        self.calls.append(operation)
        if operation=='fetchzone_records':return list(self.rows)
        if operation=='add_zone_record':self.rows.append({'name':values['name'],'type':'TXT','txtdata':values['txtdata'],'line':max(r['line'] for r in self.rows)+1});return []
        if operation=='remove_zone_record':self.rows=[r for r in self.rows if r['line']!=values['line']];return []
        raise AssertionError('Unexpected DNS action')
    def dig(self,command,**kwargs):
        class Result:returncode=0;stdout='"'+self.validation+'"\n'
        self.assertIn(command[4],['@ns1.example.invalid','@ns2.example.invalid']);return Result()
    def test_created_challenge_removed_and_other_records_preserved(self):
        hook.run('auth');self.assertEqual(len(self.rows),2);hook.run('cleanup');self.assertEqual(self.rows,[{'name':'preserved.example.invalid.','type':'TXT','txtdata':'unchanged','line':7}]);self.assertEqual(list(hook.STATE.iterdir()),[])
    def test_repeat_auth_and_cleanup(self):
        hook.run('auth');hook.run('auth');self.assertEqual(self.calls.count('add_zone_record'),1);hook.run('cleanup');hook.run('cleanup');self.assertEqual(self.calls.count('remove_zone_record'),1)
    def test_preexisting_challenge_not_owned(self):
        self.rows.append({'name':'_acme-challenge.sip.example.invalid.','type':'TXT','txtdata':self.validation,'line':8});hook.run('auth');hook.run('cleanup');self.assertEqual(len(self.rows),2);self.assertNotIn('remove_zone_record',self.calls)
    def test_unknown_namespace_refused_before_api(self):
        for domain in ['example.invalid','other.example.invalid','sip.foreign.invalid']:
            with patch.dict(os.environ,{'CERTBOT_DOMAIN':domain}),self.assertRaises(ValueError):hook.run('auth')
        self.assertEqual(self.calls,[])
    def test_insecure_configuration_refused(self):
        self.config.chmod(0o644)
        with self.assertRaises(ValueError):hook.run('auth')
        self.assertEqual(self.calls,[])
    def test_config_symlink_refused(self):
        target=self.root/'original.json';self.config.rename(target);self.config.symlink_to(target)
        with self.assertRaises(ValueError):hook.run('auth')
        self.assertEqual(self.calls,[])
    def test_state_symlink_refused(self):
        target=self.root/'original-state';target.mkdir();hook.STATE.symlink_to(target)
        with self.assertRaises(ValueError):hook.run('auth')
        self.assertEqual(self.calls,[])
    def test_ownership_symlink_refused(self):
        hook.run('auth');record=next(hook.STATE.iterdir());record.unlink();record.symlink_to(self.config)
        with self.assertRaises(ValueError):hook.run('cleanup')
        self.assertNotIn('remove_zone_record',self.calls)
    def test_http_lifecycle(self):
        with patch.dict(os.environ,{'CERTBOT_DOMAIN':'call.example.invalid','CERTBOT_TOKEN':'B'*43}):
            hook.run('auth');target=Path(self.settings['webroot'])/'.well-known/acme-challenge'/('B'*43);self.assertEqual(target.read_text(),self.validation);hook.run('cleanup');self.assertFalse(target.exists())
        self.assertEqual(self.calls,[])
    def test_http_different_owner_preserved(self):
        folder=Path(self.settings['webroot'])/'.well-known/acme-challenge';folder.mkdir(parents=True);target=folder/('B'*43);target.write_text('another owner')
        with patch.dict(os.environ,{'CERTBOT_DOMAIN':'call.example.invalid','CERTBOT_TOKEN':'B'*43}):
            with self.assertRaises(ValueError):hook.run('auth')
            hook.run('cleanup');self.assertEqual(target.read_text(),'another owner')
    def test_http_target_symlink_refused(self):
        folder=Path(self.settings['webroot'])/'.well-known/acme-challenge';folder.mkdir(parents=True);target=folder/('B'*43);target.symlink_to(self.config)
        with patch.dict(os.environ,{'CERTBOT_DOMAIN':'call.example.invalid','CERTBOT_TOKEN':'B'*43}),self.assertRaises(ValueError):hook.run('auth')
    def test_invalid_token_or_action_refused(self):
        for action in ['unknown','auth']:
            with patch.dict(os.environ,{'CERTBOT_VALIDATION':'../outside'}),self.assertRaises(ValueError):hook.run(action)
        self.assertEqual(self.calls,[])

if __name__=='__main__':unittest.main()
