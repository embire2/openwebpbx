#!/usr/bin/env python3
"""Actual source URL generation, encrypted archives and isolated PostgreSQL restore.

Native Windows service/ACL operations use the existing explicit fixture adapter.
This does not qualify a Windows release or change production configuration.
"""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import unittest
import uuid
from unittest.mock import patch

import pbx_windows_backups as base

b=base.b


class DefaultPortRestore(base.WindowsBackups):
    @classmethod
    def setUpClass(cls):
        powershell=os.environ['OPENWEB_TEST_PWSH']
        child=subprocess.run([powershell,'-NoProfile','-NonInteractive','-File',
            str(Path(__file__).with_name('windows_restore_https_sources.ps1'))],
            text=True,capture_output=True,timeout=30,check=True)
        cls.urls=json.loads(child.stdout)
        if cls.urls!={'installer443':'https://pbx.fixture.invalid:443','automatic443':'https://pbx.fixture.invalid','installer8443':'https://pbx.fixture.invalid:8443'}:
            raise AssertionError('The actual source-generated forms differ from the intended reproduction.')
        original=Path(os.environ['OPENWEB_ORIGINAL_BACKUPS'])
        spec=importlib.util.spec_from_file_location('original_windows_restore',original)
        cls.old=importlib.util.module_from_spec(spec);spec.loader.exec_module(cls.old)
        super().setUpClass()

    def prepare_urls(self,source_url,target_url,*,source_host=None,version='1.0.13',layout=None):
        source=self.source|{'openweb.public_url':source_url}
        if source_host is not None:source['openweb.public_host']=source_host
        self.target=self.target|{'openweb.public_url':target_url}
        (self.target_roots['fusionpbx-config']/'config.conf').write_text('\n'.join(k+' = '+v for k,v in self.target.items())+'\n')
        path=self.source_roots['fusionpbx-config']/'config.conf';previous=path.read_bytes()
        destination=self.target_state/('default-port-'+uuid.uuid4().hex+'.owpbx')
        try:
            path.write_text('\n'.join(k+' = '+v for k,v in source.items())+'\n')
            with patch.object(b,'installation_layout',return_value=layout or self.manifest['installation_layout']):
                manifest=b.create_archive(source,destination,self.password,roots=self.source_roots,version=version)
        finally:path.write_bytes(previous)
        self.archive=destination
        return manifest

    def assert_original_refuses_actual_archive(self):
        names=('ROOTS','MEDIA','STATE','STORE','RESTORE','UPGRADE_LOCK','LOCAL_DATABASE','WEB_VERSION','control','installation_layout')
        with patch.multiple(self.old,**{name:getattr(b,name) for name in names}):
            with self.assertRaisesRegex(self.old.BackupError,'original HTTPS address and port'):
                self.old.restore(self.archive,self.password,self.target,dry_run=True)
        self.assertFalse((b.RESTORE/'journal.json').exists())
        self.assertFalse(any(op in ('hold','start-web') for op,_ in self.native_calls))

    def complete_case(self,source_key,target_key):
        self.prepare_urls(self.urls[source_key],self.urls[target_key])
        self.assert_original_refuses_actual_archive()
        before=(self.target_roots['fusionpbx-config']/'config.conf').read_bytes()
        b.restore(self.archive,self.password,self.target,dry_run=True)
        self.assertEqual((self.target_roots['fusionpbx-config']/'config.conf').read_bytes(),before)
        self.assertFalse((b.RESTORE/'journal.json').exists())
        # Execute all existing real DB/credential/certificate/media/hold checks
        # against the new pair, without changing their assertions.
        base.WindowsBackups.test_06_complete_restore_keeps_database_identity_and_tls_hold(self)

    def test_auto_source_to_explicit_443_target(self):
        self.complete_case('automatic443','installer443')

    def test_explicit_443_source_to_auto_target(self):
        self.complete_case('installer443','automatic443')

    def test_narrow_equivalence_and_unchanged_exact_string_compatibility(self):
        clean='https://pbx.fixture.invalid'
        self.assertTrue(b.same_restore_https_address(clean,clean+':443'))
        self.assertTrue(b.same_restore_https_address(clean+':443',clean))
        changes=['http://pbx.fixture.invalid','HTTPS://pbx.fixture.invalid',clean+':8443',clean+':80',clean+':0443',
            clean+':4430',clean+':+443',clean+':443/',clean+'/',clean+'/admin',clean+':443/admin',
            clean+'?x=1',clean+':443?x=1',clean+'#part',clean+':443#part',
            'https://user@pbx.fixture.invalid','https://user:secret@pbx.fixture.invalid:443',
            'https://pbx.fixture.invalid.evil','https://PBX.fixture.invalid:443',clean+'.:443',
            clean+'\n',clean+'\r',clean+'\t',' '+clean,clean+' ',clean+'\\admin',
            'https://[::1]:443','https://pbx%2efixture.invalid:443',clean+':',None,True,443]
        for changed in changes:
            for first,second in ((clean,changed),(changed,clean)):
                with self.subTest(first=first,second=second):self.assertFalse(b.same_restore_https_address(first,second))
        # Exact legacy values are still compared exactly; they are NOT newly
        # validated or newly admitted as default-port equivalents.
        for same in (clean,clean+':443',clean+':8443',clean+'/admin',clean+'?x=1','https://user@pbx.fixture.invalid'):
            self.assertTrue(b.same_restore_https_address(same,same))
        for first,second in ((clean+'/admin',clean+':443/admin'),(clean+'?x=1',clean+':443?x=1'),
                             (clean+'#part',clean+':443#part'),('https://user@pbx.fixture.invalid','https://user@pbx.fixture.invalid:443')):
            with self.subTest(first=first,second=second):
                self.assertFalse(b.same_restore_https_address(first,second));self.assertFalse(b.same_restore_https_address(second,first))

    def test_actual_preflight_rejects_other_address_changes_before_holds(self):
        clean=self.urls['automatic443'];self.prepare_urls(clean,self.urls['installer443'])
        wrong=[self.urls['installer8443'],'http://pbx.fixture.invalid',clean+'/admin',clean+':443/admin',
            clean+'?x=1',clean+':443?x=1',clean+'#part',clean+':443#part',
            'https://user@pbx.fixture.invalid:443','https://other.fixture.invalid:443',
            'https://PBX.fixture.invalid:443',clean+':0443',clean+'/',clean+':443/']
        original=(self.target_roots['fusionpbx-config']/'config.conf').read_bytes()
        for address in wrong:
            with self.subTest(address=address),self.assertRaisesRegex(b.BackupError,'original HTTPS address and port'):
                b.restore(self.archive,self.password,self.target|{'openweb.public_url':address},dry_run=True)
            self.assertEqual((self.target_roots['fusionpbx-config']/'config.conf').read_bytes(),original)
            self.assertFalse((b.RESTORE/'journal.json').exists())
        self.assertFalse(any(op in ('hold','start-web') for op,_ in self.native_calls))

    def test_equivalent_urls_do_not_bypass_host_version_layout_confirmation_or_credentials(self):
        for kind in ('hostname','version','layout'):
            options={}
            if kind=='hostname':options['source_host']='other.fixture.invalid'
            elif kind=='version':options['version']='1.0.12'
            else:options['layout']=self.manifest['installation_layout']|{'state':'d:\\ProgramData\\OpenWebPBX'}
            self.prepare_urls(self.urls['automatic443'],self.urls['installer443'],**options)
            message={'hostname':'original public server name','version':'same application','layout':'original application and ProgramData layout'}[kind]
            with self.subTest(kind=kind),self.assertRaisesRegex(b.BackupError,message):b.restore(self.archive,self.password,self.target,dry_run=True)
        self.prepare_urls(self.urls['automatic443'],self.urls['installer443'])
        with self.assertRaisesRegex(b.BackupError,'Confirm the fresh target database name'):
            b.restore(self.archive,self.password,self.target,confirm_database='wrong_database')
        with patch.object(b,'query',wraps=b.query) as observed_query:
            with self.assertRaisesRegex(b.BackupError,'A required backup operation failed'):
                b.restore(self.archive,self.password,self.target|{'database.0.password':'incorrect-synthetic-password'},dry_run=True)
            self.assertEqual(observed_query.call_count,1)
            self.assertEqual(observed_query.call_args.args[1],'show server_version_num')
        b.query(self.target,'insert into v_extensions values(gen_random_uuid())')
        with self.assertRaisesRegex(b.BackupError,'fresh installation'):
            b.restore(self.archive,self.password,self.target,dry_run=True)
        b.query(self.target,'delete from v_extensions')
        self.assertFalse((b.RESTORE/'journal.json').exists())
        self.assertFalse(any(op in ('hold','start-web') for op,_ in self.native_calls))


def load_tests(loader,tests,pattern):
    # Reuse the independent actual DB fixture, not all inherited baseline cases.
    return unittest.TestSuite(DefaultPortRestore(name) for name in DefaultPortRestore.__dict__ if name.startswith('test_'))


if __name__=='__main__':unittest.main()
